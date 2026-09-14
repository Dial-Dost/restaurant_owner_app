import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import 'api_client.dart';
import 'auth_controller.dart';
import 'net_raw_printer.dart';
import 'restaurant_time.dart';
import 'win_raw_printer.dart';

/// How the raw ESC/POS bytes reach the spooler. Indirected only so a test can
/// drive the queue without a real winspool handle — production always uses
/// [WinRawPrinter.sendBytes].
typedef SpoolerWrite = bool Function(String printerName, List<int> bytes);

/// How the same bytes reach a printer over the network. Returns null on success
/// or the reason it failed — a STRING rather than a bool because a docket the
/// kitchen never saw has to be able to say why. Production always uses
/// [NetworkPrinter.send].
typedef NetworkWrite = Future<String?> Function(String host, int port, List<int> bytes);

/// The four things the agent does with its realtime connection.
///
/// Indirected so a test can play the SERVER — withhold `joinedOutlet`, send
/// `joinRejected`, drop the transport — without a Socket.IO server behind it.
/// That is the only way the subscription watchdog below can be driven at all,
/// and the watchdog is what stands between a till that is connected-but-deaf
/// and a till that gets closed and reopened by staff. Production always uses
/// [PrinterService.ioSocketFactory].
abstract class AgentSocket {
  void on(String event, void Function(dynamic data) handler);
  void emit(String event, [dynamic data]);
  void connect();
  void dispose();
}

/// Builds one connection from the url and the options map
/// [PrinterService.socketOptions] produced.
typedef AgentSocketFactory = AgentSocket Function(String url, Map<String, dynamic> options);

class _IoAgentSocket implements AgentSocket {
  _IoAgentSocket(this._socket);
  final io.Socket _socket;

  @override
  void on(String event, void Function(dynamic data) handler) => _socket.on(event, handler);
  @override
  void emit(String event, [dynamic data]) => _socket.emit(event, data);
  @override
  void connect() => _socket.connect();
  @override
  void dispose() => _socket.dispose();
}

/// What the printer screen can truthfully say about the realtime link.
///
/// TWO FACTS, NOT ONE. "The transport is up" and "the server put this device in
/// its outlet's room" used to be reported as the same green "Connected", and the
/// gap between them is exactly the state in which a till printed nothing all
/// lunch while looking healthy: a socket that handshook with a dead session, or
/// whose join the server never heard. Only a `joinedOutlet` answer earns
/// [listening].
enum PrinterLink { offline, joining, listening }

/// WHERE THE BYTES GO — one printer, named in a way that survives being stored.
///
/// There are two transports and a role has to be able to point at either:
///
///   * a WINDOWS SPOOLER QUEUE, named by the queue name winspool reports
///     ("EPSON TM-T82 Receipt"). Stored bare, exactly as it always was, so every
///     device that already has rules keeps them without a migration.
///   * a NETWORK PRINTER, named `tcp://<host>:<port>` — the port 9100 raw
///     socket that lets a PHONE print (see [NetworkPrinter]).
///
/// A bare string with a scheme prefix rather than a sealed class because these
/// values live in SharedPreferences and in the `<role>=<target>` route entries
/// that were written before network printing existed. Anything without the
/// prefix is a spooler name, which is precisely what those old entries are.
abstract final class PrintTarget {
  static const String _scheme = 'tcp://';

  /// The stored form of a network printer.
  static String network(String host, int port) => NetworkPrinter.target(host, port);

  static bool isNetwork(String target) => target.startsWith(_scheme);

  /// The host and port of a network target, or null if this is a spooler name.
  static ({String host, int port})? parse(String target) {
    if (!isNetwork(target)) return null;
    final rest = target.substring(_scheme.length);
    final colon = rest.lastIndexOf(':');
    if (colon <= 0) return null;
    final host = rest.substring(0, colon).trim();
    final port = int.tryParse(rest.substring(colon + 1).trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host: host, port: port);
  }

  /// How a target reads on screen: `192.168.1.50:9100`, or the queue name.
  static String label(String target) =>
      isNetwork(target) ? target.substring(_scheme.length) : target;
}

/// WHAT A PRINTER IS FOR, in this outlet.
///
/// A real restaurant has more than one thermal printer and each prints a
/// different thing: a KOT printer at the pass, a second in the bar, a bill
/// printer at the till. Every `bill:print` event already carries everything
/// needed to tell them apart — `kind` ('bill' or 'kot') and, on a kitchen
/// docket, the `station` buildKotBase64 split it by — so routing is a lookup,
/// not a new concept. escpos.ts has said so since the split was written: "a
/// printer agent that maps station -> printer routes each ticket to its zone".
///
/// A role is a STRING so a station role can name any station the menu uses
/// without this file holding a copy of the station list:
///   * `bill`          — customer bills
///   * `kot`           — every kitchen docket, whatever its station
///   * `kot:<STATION>` — dockets for that one station (case-insensitively)
abstract final class PrintRole {
  static const String bill = 'bill';
  static const String anyKot = 'kot';

  /// The role that routes ONE station's dockets. Upper-cased and trimmed so the
  /// same station typed "Bar", "bar " and "BAR" is one rule, matching the way
  /// groupKotItemsByStation keys its buckets.
  static String kotStation(String station) => 'kot:${station.trim().toUpperCase()}';

  /// The station a `kot:<STATION>` role names, or null for any other role.
  static String? stationOf(String role) {
    if (!role.startsWith('kot:')) return null;
    final s = role.substring(4).trim();
    return s.isEmpty ? null : s;
  }

  /// How a role reads in the UI and the activity log.
  static String label(String role) {
    if (role == bill) return 'Bills';
    if (role == anyKot) return 'All kitchen dockets';
    final station = stationOf(role);
    return station == null ? role : 'Kitchen: $station';
  }
}

class PrintJob {
  final String billId;
  final List<int> bytes;

  /// The server's "PrintJobs".id — THE identity of this job, and the only thing
  /// dedup and acknowledgement may key on.
  ///
  /// Not billId, which is deliberately unsuitable twice over: it is STABLE
  /// across reprints (so keying on it would swallow the second copy a waiter
  /// asked for) and it is SHARED by every station ticket of one KOT (so keying
  /// on it would print the first kitchen's docket and silently drop the rest).
  ///
  /// Null when the backend could not persist the job — an older build, or one
  /// running ahead of migration 027. Such a job still prints; it simply has no
  /// durable identity, so it is never deduplicated and never acknowledged.
  final String? jobId;

  /// 'bill' or 'kot'. Carried for the queue display and the log only.
  final String kind;

  /// Kitchen station, on KOT tickets only.
  final String? station;

  /// True when the server re-sent this job because it was never acknowledged,
  /// rather than it being a fresh print.
  final bool replay;

  int attempts = 0;

  /// Why the last attempt failed, in words — "No answer from 192.168.1.50:9100"
  /// rather than a bare false. Shown on the queue card and written to the log so
  /// a docket that did not come out is a thing someone can act on rather than a
  /// thing they discover from an angry table.
  String? lastError;

  PrintJob(
    this.billId,
    this.bytes, {
    this.jobId,
    this.kind = 'bill',
    this.station,
    this.replay = false,
  });
}

/// Built-in thermal printer agent: subscribes to the backend's `bill:print`
/// realtime events and sends the raw ESC/POS bytes to the selected Windows
/// printer — so the owner app prints bills itself, with no separate .exe.
///
/// Singleton because the socket + print queue are device-wide and must keep
/// running in the background regardless of which module screen is open.
///
/// DURABLE PRINTING — the till half of the contract
/// ------------------------------------------------
/// Printing used to be fire-and-forget in both directions. The backend emitted
/// `bill:print` into a room and answered {success:true} whether or not anything
/// was listening (an emit into an empty room is a successful no-op), and this
/// service held its queue in memory and cleared it on stop(). A bill emitted
/// while the till's socket was down was simply gone: no retry, no error, and a
/// green tick for the waiter.
///
/// The backend now writes every job to "PrintJobs" BEFORE it emits, and replays
/// whatever is still outstanding when an agent (re)joins its outlet. Three
/// things are required of this side, and each one is load-bearing:
///
///   1. ADVERTISE A VERSION on joinOutlet. The server replays only to an agent
///      that names one, because a build that predates this change can neither
///      deduplicate nor acknowledge — replaying to it would reprint the whole
///      backlog on every socket flap, forever. Sending the version is this
///      agent asserting "I can be replayed to safely".
///   2. ACKNOWLEDGE AFTER THE SPOOLER ACCEPTS THE BYTES, never on receipt. An
///      ack means the paper came out; acking on receipt would settle a job this
///      till then failed to print, and the receipt would be lost with the
///      server believing it delivered.
///   3. DEDUPLICATE LOCALLY AND PERSISTENTLY. An ack can be lost after the
///      paper is out (the HTTP call fails, or the app dies), and the server
///      will then quite correctly re-send the job. Only this till knows it
///      already printed it.
///
/// The three compose into the property that matters: every job either prints
/// exactly once or is recorded as never having printed.
class PrinterService extends ChangeNotifier {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  /// Sent as `agentVersion` on joinOutlet. A PROTOCOL capability, not the app's
  /// release number: it says "this build acknowledges jobs and deduplicates
  /// them by jobId", which is exactly what the server's replay interlock is
  /// asking. Bump it only if that contract changes.
  static const String agentVersion = 'flutter-owner/1';

  static const _printerKey = 'selected_printer';

  /// The role -> printer map, as `<role>=<printer name>` entries.
  ///
  /// STORED ON THE DEVICE, NOT ON THE SERVER, and that is a decision rather than
  /// an omission. The values are WINDOWS SPOOLER NAMES — "EPSON TM-T82 (Bar)" —
  /// which are facts about ONE machine. A till only ever prints to printers
  /// installed on itself, and the outlet's second till has different ones. A
  /// per-outlet copy on the backend would therefore be authoritative nonsense on
  /// every device but the one that wrote it: the bar till would be told to send
  /// bar dockets to a queue that does not exist on it, and the docket would fail
  /// three times and settle as 'failed'.
  ///
  /// Keyed per outlet, because one machine can be signed into more than one, and
  /// the printers it should use differ between them.
  static const _routesKeyPrefix = 'printer_routes_';

  /// The network printers configured on this device, as `tcp://host:port`.
  ///
  /// PER OUTLET AND ON THE DEVICE, for the same reason the routing map is: a
  /// printer's address is a fact about the LAN this device is standing on. The
  /// tablet in the bar and the till at the front desk of a second branch see
  /// different 192.168.x.x networks, and an address copied between them points
  /// at whatever happens to hold that lease — which is either nothing or, worse,
  /// somebody else's printer.
  static const _netKeyPrefix = 'printer_net_';

  /// Jobs this till has already dealt with, persisted so a restart cannot
  /// reprint them. Entries are `<jobId>|printed` or `<jobId>|failed`.
  static const _settledKey = 'printer_settled_jobs';

  /// FIFO cap on that set. It only has to outlive the server's longest replay
  /// TTL (12h for a bill, 30m for a kitchen docket) — past that a job is never
  /// re-sent, so remembering it buys nothing. 500 comfortably exceeds one
  /// outlet's half-day receipt volume while keeping the prefs write small,
  /// since the whole list is rewritten each time a job settles.
  static const _settledCap = 500;

  /// Hard stop on the "give me the next window" loop below, so a pathological
  /// backlog can never turn into an unbounded request loop.
  static const _maxReplayRounds = 25;

  // Comfortably longer than the server's ~2 minute claim lease, so a retry
  // lands after a dead connection's hold has lapsed rather than bouncing off it.
  static const _replayRetryDelay = Duration(seconds: 150);

  /// Longest wait between unanswered joinOutlet re-asks. The ladder starts at
  /// [_joinAnswerTimeout] and doubles to here, so a server that is genuinely
  /// failing costs one small socket event a minute per till — never a tight loop,
  /// and never a database transaction, because an unanswered join ran none.
  static const _joinRetryCap = Duration(seconds: 60);

  /// How many unanswered joins before the agent stops guessing and asks the
  /// server whether its session is still alive — then again every few after,
  /// so a till left deaf all afternoon keeps checking without hammering /auth/me.
  static const _missesBeforeProbe = 2;
  static const _missesBetweenProbes = 4;

  /// The re-ask ladder for an unanswered joinOutlet: 5s, 10s, 20s, 40s, then
  /// [_joinRetryCap] for as long as it stays unanswered. [misses] is how many
  /// have already gone unanswered on this subscription attempt.
  @visibleForTesting
  static Duration joinRetryDelay(int misses, {Duration first = const Duration(seconds: 5)}) {
    var d = first;
    for (var i = 0; i < misses && d < _joinRetryCap; i++) {
      d *= 2;
    }
    return d > _joinRetryCap ? _joinRetryCap : d;
  }

  /// How long to wait before trying [target] again.
  ///
  /// A NETWORK printer gets a longer breath than a spooler does. A queue that
  /// refuses a job refuses it now; a printer that is rebooting, roaming between
  /// access points or renewing a DHCP lease is simply not there YET, and three
  /// tries two seconds apart would write it off while it was still coming up.
  ///
  /// Derived from [_retryDelay] rather than being a constant of its own, so a
  /// test that asks for instant retries gets them on both transports — an
  /// 8-second sleep in a widget test is a flake waiting to be blamed on
  /// something else.
  @visibleForTesting
  Duration retryDelayFor(String target) =>
      PrintTarget.isNetwork(target) ? _retryDelay * 4 : _retryDelay;

  AgentSocket? _socket;
  AuthController? _auth;
  Timer? _keepAlive;

  // SUBSCRIPTION LIVENESS. [_connected] is the transport; [_subscribed] is the
  // server's word that this socket is in the outlet room, and it is set by a
  // matching `joinedOutlet` and nothing else. While the first is true and the
  // second is not, [_joinWatchdog] keeps re-asking on a capped ladder.
  bool _subscribed = false;
  Timer? _joinWatchdog;
  int _joinMisses = 0;
  bool _probingSession = false;

  // The token this connection last introduced itself with — read at handshake
  // time, so a rejection can be checked against the session we hold NOW before
  // anybody is signed out over it.
  String? _handshakeToken;

  // Latched once this start() has handed the user back to sign-in, so a
  // rejection, a watchdog probe and a keepalive that all notice the same dead
  // session produce one sign-out between them, not three.
  bool _sessionEnded = false;

  // Bumped by every start() that proceeds and every stop(), so a start() still
  // awaiting prefs can tell it has been superseded.
  int _lifecycle = 0;

  AgentSocketFactory _socketFactory = ioSocketFactory;
  Duration _joinAnswerTimeout = const Duration(seconds: 5);
  Duration _keepAliveEvery = const Duration(minutes: 25);

  // Re-ask timer. A window can legitimately come back EMPTY while the previous
  // connection's lease is still held, so an empty window must not end the
  // conversation — it has to be retried, or a job stranded by a crash-restart
  // waits for a reconnect that may never come and expires unprinted.
  Timer? _replayRetry;
  bool _processing = false;
  bool _started = false;

  bool _connected = false;
  bool _paused = false;
  String? _selectedPrinter;
  List<String> _printers = const [];

  /// role -> printer name, for the outlet this agent joined. Empty is the
  /// shipped state and means "everything goes to the default printer" — which
  /// is exactly what this app did before routing existed.
  Map<String, String> _routes = <String, String>{};

  /// The `tcp://host:port` printers this device can reach. Empty is the shipped
  /// state on every platform: a Windows till prints through the spooler and
  /// needs none of these, and a phone that has not been given one cannot print
  /// at all — which is exactly what [canClaimJobs] reports.
  List<String> _netTargets = <String>[];
  final List<PrintJob> _queue = [];
  final List<String> _logs = [];
  final List<String> _seenStations = <String>[];

  /// The tenant + the CONCRETE outlet this agent joined. Held because the ack
  /// and the follow-up replay request both need them long after start() ran.
  String? _resId;
  String? _outletId;

  /// jobId -> 'printed' | 'failed', with insertion order kept for the FIFO cap.
  final Map<String, String> _settled = <String, String>{};
  final List<String> _settledOrder = <String>[];
  Future<void>? _settledLoad;

  /// Replayed jobs that actually reached the spooler since the last resume
  /// request, and how many resume requests this connection has made.
  int _replayPrinted = 0;
  int _replayRounds = 0;

  /// Whether a backlog catch-up stopped at [_maxReplayRounds] with output still
  /// coming. NOT the same as the round count being at the cap: the empty-window
  /// retry spends rounds too, so an ordinary till with no backlog reaches the cap
  /// after a couple of dozen quiet gaps between live dockets. Only this flag
  /// means there is a paused catch-up for [onResume] to continue.
  bool _replayPaused = false;

  SpoolerWrite _write = WinRawPrinter.sendBytes;
  NetworkWrite _netWrite = NetworkPrinter.send;
  bool? _supportedOverride;
  bool? _spoolerOverride;
  Duration _retryDelay = const Duration(seconds: 2);

  /// A service instance isolated from the app-wide singleton, with the spooler
  /// and the platform gate injected. Tests only.
  @visibleForTesting
  factory PrinterService.forTest({
    required AuthController auth,
    required SpoolerWrite write,
    NetworkWrite? netWrite,
    bool supported = true,
    /// Whether this device has a Windows spooler. Defaults to [supported] so
    /// every test written before network printing existed describes the same
    /// Windows till it always did.
    bool? spooler,
    String? printer = 'Test Printer',
    String? outletId = 'outlet-1',
    Duration retryDelay = Duration.zero,
    List<String> networkPrinters = const <String>[],
    /// The realtime connection. Omitted, start() would dial the real backend.
    AgentSocketFactory? socketFactory,
    Duration joinAnswerTimeout = const Duration(seconds: 5),
    Duration keepAliveEvery = const Duration(minutes: 25),
  }) {
    final s = PrinterService._();
    s._auth = auth;
    s._write = write;
    if (netWrite != null) s._netWrite = netWrite;
    if (socketFactory != null) s._socketFactory = socketFactory;
    s._joinAnswerTimeout = joinAnswerTimeout;
    s._keepAliveEvery = keepAliveEvery;
    s._supportedOverride = supported;
    s._spoolerOverride = spooler ?? supported;
    s._selectedPrinter = printer;
    s._outletId = outletId;
    s._resId = 'res-1';
    s._retryDelay = retryDelay;
    s._netTargets = List<String>.from(networkPrinters);
    return s;
  }

  /// Seed the routing map and the installed-printer list without touching
  /// prefs or winspool. Tests only.
  @visibleForTesting
  void debugSetRouting({Map<String, String>? routes, List<String>? installed}) {
    if (routes != null) _routes = Map<String, String>.from(routes);
    if (installed != null) _printers = List<String>.from(installed);
  }

  /// Whether this device can print AT ALL, by either transport.
  ///
  /// This used to be `WinRawPrinter.supported` — i.e. "is this Windows" — and
  /// the service logged "Printing is only supported on Windows." on everything
  /// else. That was a statement about the SPOOLER, not about printing: the
  /// backend has always pushed finished ESC/POS bytes down `bill:print`, and a
  /// phone can put those on a socket (see [NetworkPrinter]) just as a till puts
  /// them on a spooler queue. So the platform question is now [hasSpooler], and
  /// this one is about capability.
  bool get supported => _supportedOverride ?? (WinRawPrinter.supported || NetworkPrinter.supported);

  /// Whether the WINDOWS spooler exists here. Gates every control that names a
  /// Windows printer queue, because those controls are inert anywhere else.
  bool get hasSpooler => _spoolerOverride ?? WinRawPrinter.supported;

  bool get connected => _connected;

  /// Whether the server has confirmed this device is in its outlet's room — the
  /// only state in which a `bill:print` can actually arrive.
  bool get subscribed => _subscribed;

  PrinterLink get linkState => !_connected
      ? PrinterLink.offline
      : _subscribed
          ? PrinterLink.listening
          : PrinterLink.joining;

  bool get paused => _paused;
  String? get selectedPrinter => _selectedPrinter;
  List<String> get printers => _printers;

  /// The `tcp://host:port` printers configured on this device.
  List<String> get networkPrinters => List.unmodifiable(_netTargets);

  /// Everything a role can be pointed at, spooler queues first.
  List<String> get targets => List.unmodifiable(<String>[..._printers, ..._netTargets]);

  /// Whether [target] is something this device can actually reach right now — a
  /// currently-installed spooler queue, or a configured network address.
  bool knowsTarget(String target) =>
      PrintTarget.isNetwork(target) ? _netTargets.contains(target) : _printers.contains(target);

  /// The configured role -> printer rules. Unmodifiable: every change goes
  /// through setRoute/clearRoute so it is persisted and logged.
  Map<String, String> get routes => Map.unmodifiable(_routes);

  /// Stations this till has actually been asked to print for, newest last.
  ///
  /// Learned from the dockets that arrive rather than fetched, deliberately: the
  /// station list lives in the menu (Restaurant.kitchen_sections) and the
  /// printer screen has no business holding a second copy of it that can be
  /// stale. A station the kitchen never sends a docket for does not need a rule.
  List<String> get seenStations => List.unmodifiable(_seenStations);
  List<PrintJob> get queue => List.unmodifiable(_queue);
  List<String> get logs => List.unmodifiable(_logs);

  /// Whether this device may be handed the outlet's outstanding backlog.
  ///
  /// TIED TO THE ABILITY TO ACTUALLY PRINT, not to being signed in and not to
  /// the platform. A device that claims jobs takes them off the queue the
  /// outlet's real till is waiting on; if it then cannot print them, every one
  /// of those receipts is lost. So the rule is capability, stated per transport:
  ///
  ///   * A WINDOWS TILL always qualifies. It has a spooler, and a till with no
  ///     printer selected yet holds its jobs and prints them the moment one is
  ///     chosen — which is what it has always done.
  ///   * ANYTHING ELSE qualifies only once it has a network printer configured.
  ///     A phone with no printer address is a VIEWER: it cannot put a docket on
  ///     paper by any route, so it must never be handed one. Add an address and
  ///     it becomes a first-class print client on the next connect.
  ///
  /// start() refuses to open the socket at all when this is false, so a viewer
  /// is not even in the room to receive a live emit — but the rule is restated
  /// here, where the claim is actually made, so it cannot be lost to a refactor.
  bool get canClaimJobs {
    if (!supported) return false;
    if (hasSpooler) return true;
    return _netTargets.isNotEmpty;
  }

  void _log(String msg) {
    // Restaurant time, like every other timestamp the app shows — a print log
    // read against an order list has to line up with it.
    _logs.insert(0, '[${RestaurantTime.clockNow()}] $msg');
    if (_logs.length > 200) _logs.removeRange(200, _logs.length);
    notifyListeners();
  }

  /// The outlet an agent subscribes to: the selected one, unless that is the
  /// "all outlets" aggregate sentinel.
  ///
  /// "all" is a READ-ONLY view the backend expands across every outlet; it is
  /// not a real outlet id. Joining `restaurant:<res>:outlet:all` subscribes to a
  /// room nothing ever emits into, so an admin who switched to the combined view
  /// used to silently stop printing — and it would now also make every ack a 400,
  /// because the backend rejects any write while that sentinel is active.
  @visibleForTesting
  static String resolveOutletId(String? selected, String sessionOutletId) {
    final s = (selected ?? '').trim();
    final lowered = s.toLowerCase();
    if (s.isEmpty || lowered == 'all' || lowered == '__all__') return sessionOutletId;
    return s;
  }

  /// The joinOutlet payload. `agentVersion` is present only when this device can
  /// print — see [canClaimJobs].
  @visibleForTesting
  Map<String, dynamic> joinPayload(String resId, String outletId) => <String, dynamic>{
        'restaurantId': resId,
        'outletId': outletId,
        if (canClaimJobs) 'agentVersion': agentVersion,
      };

  /// Connect + subscribe for the signed-in session. Idempotent.
  Future<void> start(AuthController auth) async {
    _auth = auth;
    if (!supported) {
      _log('This build cannot print — no printer transport is available.');
      return;
    }
    if (_started) return;
    _started = true;
    _sessionEnded = false;
    _joinMisses = 0;
    final generation = ++_lifecycle;

    final prefs = await SharedPreferences.getInstance();
    _selectedPrinter = prefs.getString(_printerKey);
    // Before the socket opens, so the first replayed job already has the
    // "already printed here" set to check itself against.
    await _ensureSettledLoaded();
    discoverPrinters();

    final token = auth.token;
    final profile = auth.profile;
    if (token == null || profile == null) {
      // _started is released, not left set: this is a start that did not happen,
      // and leaving the latch on would make the next one — the one after the
      // session arrives — a silent no-op.
      _started = false;
      _log('Not signed in — cannot start printer.');
      return;
    }
    final resId = profile.resId;
    final outletId = resolveOutletId(auth.selectedOutletId, profile.outletId);
    _resId = resId;
    _outletId = outletId;
    // AFTER the outlet is resolved, because both are per outlet — and before the
    // socket opens, so the first job that arrives is already routed and
    // canClaimJobs below is answered from the real configuration.
    await _loadNetworkPrinters();
    await _loadRoutes();

    // A DEVICE THAT CANNOT PRINT DOES NOT JOIN THE ROOM.
    //
    // canClaimJobs already stops the server REPLAYING a backlog here, but a live
    // `bill:print` goes to everyone in the outlet room regardless. A phone with
    // no printer configured would therefore sit collecting dockets it can only
    // report as 'No printer selected', growing a queue in memory for a service
    // it will never print — so it stays out of the room entirely until it has
    // somewhere to send them. addNetworkPrinter() starts it the moment it does.
    if (!canClaimJobs) {
      _started = false;
      _log('No printer set up on this device yet — add one and printing starts.');
      notifyListeners();
      return;
    }

    // A stop() — or a stop() and a newer start() — that landed while this one
    // was awaiting prefs owns the agent now. The usual one is a logout, which
    // destroyed the token this start() read; opening a socket for it here would
    // leave a connection nobody owns.
    if (generation != _lifecycle || !_started) return;

    _log('Connecting to realtime…');
    _openSocket(token);

    // Keep the session warm so a long-idle till still prints after a reconnect —
    // and HEAR the answer. This used to swallow every failure, a 401 included,
    // so a till whose session had died kept its green light and printed nothing.
    _keepAlive?.cancel();
    _replayRetry?.cancel();
    _keepAlive = Timer.periodic(_keepAliveEvery, (_) async {
      final auth = _auth;
      final t = auth?.token;
      if (auth == null || t == null) return;
      try {
        await auth.api.me(t);
      } on ApiException catch (e) {
        if (e.status == 401) {
          await _endExpiredSession();
          return;
        }
      } catch (_) {/* transport: says nothing about the session */}
      // A backstop for the watchdog, not a second loop: only ever re-asks while
      // the server has not confirmed the room.
      if (_connected && !_subscribed) _emitJoin();
    });
  }

  /// The Socket.IO options for one agent connection.
  ///
  /// `forceNew` IS THE FIX FOR "CLOSE AND REOPEN THE APP TO PRINT". Without it,
  /// socket_io_client 3.1.6 caches a Manager per host for the life of the
  /// process, and its same-namespace test compares the url's path ('' for
  /// https://api.dialdost.com) against '/', so it never matches and the cache is
  /// always reused. Manager.socket('/') then hands back the FIRST Socket this
  /// process ever made — with the auth it captured in its constructor — and
  /// ignores the options passed now. dispose() does not evict it. So every
  /// start() after the first reused the first sign-in's token: sign out and back
  /// in, or be signed out by an expired session, and the agent handshook with a
  /// destroyed token, the server ignored it, and nothing printed until a restart
  /// gave the process a fresh cache. (`disableMultiplex()` would express the same
  /// intent, but is itself broken in that release.)
  ///
  /// The auth is a FUNCTION, read on every connect and reconnect, so a transport
  /// that comes back after the session has changed introduces itself as the
  /// session this device holds now rather than the one it held at start().
  @visibleForTesting
  static Map<String, dynamic> socketOptions({required String? Function() token, required String resId}) =>
      io.OptionBuilder()
          // websocket first, polling fallback (matches the backend's accepted
          // transports) so it still connects behind proxies that block WS upgrade.
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .enableReconnection()
          .enableForceNew()
          .setAuthFn((send) => send(<String, dynamic>{'token': token(), 'restaurantId': resId}))
          .build();

  /// The production connection: a real Socket.IO client.
  static AgentSocket ioSocketFactory(String url, Map<String, dynamic> options) =>
      _IoAgentSocket(io.io(url, options));

  /// Replace the realtime connection with a fresh one.
  ///
  /// THE PREVIOUS SOCKET IS DISPOSED FIRST, ALWAYS. With `forceNew` every call
  /// really is a new connection, so one left alive would still be in the outlet
  /// room and every broadcast would arrive twice. jobId dedup absorbs that for
  /// persisted jobs, but a job with no jobId (a payload over the size cap, or a
  /// backend without migration 027) would print twice. Every handler below also
  /// checks it still belongs to the CURRENT socket, so a late event from a
  /// replaced one can change nothing.
  void _openSocket(String startToken) {
    final resId = _resId;
    final outletId = _outletId;
    if (resId == null || outletId == null) return;
    final previous = _socket;
    _socket = null;
    _connected = false;
    _subscribed = false;
    _joinWatchdog?.cancel();
    if (previous != null) {
      try {
        previous.dispose();
      } catch (_) {/* already gone */}
    }

    final AgentSocket socket;
    try {
      socket = _socketFactory(
        AppConfig.backendUrl,
        socketOptions(
          token: () => _handshakeToken = _auth?.token ?? startToken,
          resId: resId,
        ),
      );
    } catch (e) {
      _log('Failed to connect: $e');
      return;
    }
    _socket = socket;
    bool current() => identical(_socket, socket);

    socket.on('connect', (_) {
      if (!current()) return;
      _connected = true;
      // A new connection is a new server-side socket in no rooms at all,
      // whatever the last one had.
      _subscribed = false;
      _log('Connected to realtime');
      // Fires on every RECONNECT too, which is what makes this the resume
      // hook: the server replays the outlet's outstanding jobs in response.
      _replayRounds = 0;
      _replayPrinted = 0;
      _replayPaused = false;
      _emitJoin();
      notifyListeners();
      // Anything held over from before the drop (the queue is no longer
      // discarded) goes out now.
      unawaited(_processQueue());
    });
    socket.on('disconnect', (_) {
      if (!current()) return;
      _connected = false;
      _subscribed = false;
      _joinWatchdog?.cancel();
      _log('Disconnected from realtime');
      notifyListeners();
    });
    socket.on('connect_error', (e) {
      if (current()) _log('Connect error: $e');
    });
    socket.on('error', (e) {
      if (current()) _log('Socket error: $e');
    });
    socket.on('joinedOutlet', (data) {
      if (current()) _onJoinedOutlet(data);
    });
    socket.on('joinRejected', (data) {
      if (current()) _onJoinRejected(data);
    });
    socket.on('bill:print', (data) {
      // A replaced connection prints nothing, even if an event slips out of it.
      if (current()) unawaited(onPrintEvent(data));
    });

    socket.connect();
    notifyListeners();
  }

  /// Ask the server for this outlet's room, and start listening for the answer.
  void _emitJoin() {
    final socket = _socket;
    final resId = _resId;
    final outletId = _outletId;
    if (socket == null || resId == null || outletId == null || !_connected) return;
    socket.emit('joinOutlet', joinPayload(resId, outletId));
    if (!_subscribed) _armJoinWatchdog();
  }

  void _armJoinWatchdog() {
    _joinWatchdog?.cancel();
    final socket = _socket;
    _joinWatchdog = Timer(joinRetryDelay(_joinMisses, first: _joinAnswerTimeout), () {
      if (!identical(socket, _socket) || !_connected || _subscribed || _sessionEnded) return;
      _onJoinUnanswered();
    });
  }

  /// The server has not confirmed the room. Either the join was lost (the
  /// backend's old connect race), the server is struggling, or this connection's
  /// session is dead and an older backend is ignoring it in silence. Re-asking is
  /// right for the first two; only the server can say whether it is the third.
  void _onJoinUnanswered() {
    _joinMisses++;
    final probe = _joinMisses >= _missesBeforeProbe &&
        (_joinMisses - _missesBeforeProbe) % _missesBetweenProbes == 0;
    if (probe) {
      _log('Still not receiving print jobs — checking the sign-in');
      unawaited(_probeSession());
      return;
    }
    _log('No answer to the print subscription yet — asking again');
    _emitJoin();
  }

  /// Ask /auth/me whether this device's session is alive, and act on the answer.
  ///
  /// SIGN-OUT ONLY ON THE SERVER'S WORD. A 401 is the backend saying this token
  /// is dead, which is the same thing the rest of the app signs out on
  /// (RestClient). Anything else — no connection, a timeout, a 502 from a proxy
  /// while the backend restarts — is not evidence about the session, and a till
  /// on flaky Wi-Fi must never be signed out mid-service over it. Those get a
  /// fresh handshake instead, which is what a close-and-reopen was really doing.
  Future<void> _probeSession() async {
    final auth = _auth;
    final token = auth?.token;
    if (auth == null || token == null || _probingSession || _sessionEnded) return;
    final socket = _socket;
    _probingSession = true;
    try {
      await auth.api.me(token);
    } on ApiException catch (e) {
      if (e.status == 401) {
        _probingSession = false;
        await _endExpiredSession();
        return;
      }
    } catch (_) {
      // Transport failure: handled below exactly like a live session.
    }
    _probingSession = false;
    if (!identical(socket, _socket) || _subscribed || !_started || _sessionEnded) return;
    _log('Reconnecting to realtime to resume printing');
    _openSocket(token);
  }

  void _onJoinedOutlet(dynamic data) {
    final outletId = data is Map ? '${data['outletId'] ?? ''}' : '';
    // A confirmation for some OTHER outlet is not a confirmation. Every join this
    // socket sends names [_outletId], so a mismatch is stale, and trusting it
    // would light "Listening" over a room this device is not in.
    if (outletId.isEmpty || outletId != _outletId) return;
    _joinWatchdog?.cancel();
    _joinMisses = 0;
    if (_subscribed) return; // a replay window's re-join, already known
    _subscribed = true;
    _log('Subscribed to outlet $outletId');
    notifyListeners();
  }

  void _onJoinRejected(dynamic data) {
    final reason = data is Map ? data['reason'] : null;
    if (reason != 'session_invalid') {
      // Not a statement about the session, so it changes nothing here: the
      // watchdog keeps asking.
      _log('Print subscription refused${reason == null ? '' : ' ($reason)'}');
      return;
    }
    _joinWatchdog?.cancel();
    final held = _auth?.token;
    if (held == null) return; // already signed out by something else
    if (_handshakeToken != null && _handshakeToken != held) {
      // The server rejected the token this CONNECTION introduced itself with,
      // which is not the session this device holds now. Signing out would end a
      // perfectly good session; reconnecting as it is the whole fix.
      _log('Reconnecting to realtime with the current sign-in');
      _openSocket(held);
      return;
    }
    unawaited(_endExpiredSession());
  }

  /// The server has said this session is gone. Send the user back to sign in —
  /// once — exactly as a 401 anywhere else in the app does. HomeShell's teardown
  /// stops this agent, and the next sign-in starts a fresh connection with the
  /// fresh token.
  Future<void> _endExpiredSession() async {
    final auth = _auth;
    if (auth == null || auth.token == null || _sessionEnded) return;
    _sessionEnded = true;
    _joinWatchdog?.cancel();
    _log('Session expired — sign in again to resume printing');
    await auth.logout(expired: true);
  }

  /// The app came back to the foreground.
  ///
  /// Re-asks ONLY where something is wrong. A till that is connected and
  /// confirmed in its room is left alone: a joinOutlet costs the server a tenant
  /// transaction for the replay, and a desktop window regains focus far too often
  /// to pay that every time. The one exception is a backlog catch-up that really
  /// paused at its round cap ([_replayPaused]), which previously said "reconnect
  /// to continue" — coming back to the app is that reconnect. A round count that
  /// merely sits at the cap is not that: quiet gaps between live dockets spend
  /// rounds on every long-running till, and continuing on THAT would re-join a
  /// listening socket on every window focus.
  Future<void> onResume() async {
    if (!_started || _sessionEnded) return;
    final socket = _socket;
    if (socket == null) return;
    if (!_connected) {
      socket.connect();
      return;
    }
    if (!_subscribed) {
      _joinMisses = 0;
      _log('Back in the app — asking for print jobs again');
      _emitJoin();
      return;
    }
    if (_replayPaused) {
      _replayPaused = false;
      _replayRounds = 0;
      _replayPrinted = 1; // let the guard through; this IS the continue
      _requestNextReplayWindow();
    }
  }

  Future<void> stop() async {
    _lifecycle++;
    _started = false;
    _connected = false;
    _subscribed = false;
    _keepAlive?.cancel();
    _replayRetry?.cancel();
    _joinWatchdog?.cancel();
    _keepAlive = null;
    final socket = _socket;
    _socket = null;
    try {
      socket?.dispose();
    } catch (_) {/* ignore */}
    _replayRounds = 0;
    _replayPrinted = 0;
    _replayPaused = false;
    // THE QUEUE IS DELIBERATELY KEPT. stop() is a logout, an outlet switch or a
    // shell teardown — every one of which is normally followed by a start(), and
    // the pending jobs are receipts for tables at THIS printer either way.
    // Clearing them used to be the last silent drop on the path: an unacked job
    // is still outstanding on the server, so discarding it here either loses the
    // receipt outright (no jobId) or waits on a replay that only arrives once
    // this agent reconnects. Discarding on purpose is what clearQueue() is for.
    notifyListeners();
  }

  /// A `bill:print` event — live, or replayed by the server after a reconnect.
  /// Both arrive on this one handler and are deliberately indistinguishable
  /// apart from the `replay` flag, so there is a single path to reason about.
  @visibleForTesting
  Future<void> onPrintEvent(dynamic data) async {
    Map? payload;
    if (data is Map) {
      payload = data;
    } else if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) payload = d;
      } catch (_) {/* not JSON */}
    }
    final b64 = payload?['escBase64'];
    if (b64 is! String || b64.isEmpty) {
      _log('Received bill:print without escBase64');
      return;
    }
    final rawJobId = payload?['jobId'];
    final jobId = (rawJobId is String && rawJobId.trim().isNotEmpty) ? rawJobId.trim() : null;
    final billId = '${payload?['billId'] ?? 'bill_${DateTime.now().millisecondsSinceEpoch}'}';
    final kind = payload?['kind'] == 'kot' ? 'kot' : 'bill';
    final rawStation = payload?['station'];
    final station = rawStation is String && rawStation.isNotEmpty ? rawStation : null;
    final replay = payload?['replay'] == true;

    if (jobId != null) {
      await _ensureSettledLoaded();
      // STILL IN THE QUEUE IS CHECKED FIRST, AND THE ORDER IS THE WHOLE POINT.
      //
      // These two sets OVERLAP, which is not obvious and is what the original
      // order got wrong. `_remember(jobId, 'printed')` is written just before
      // the FIRST `_send` (see the block at the send site and its reasoning), so
      // from that moment until the job leaves the queue it is in `_settled` AND
      // in `_queue` at the same time — for as long as the retries run, which for
      // a network target is around a minute.
      //
      // Re-delivered inside that window — a socket flap, a replay crossing a
      // live emit — the settled test would fire first and ack 'printed' for
      // paper that has not come out. First-ack-wins makes that PERMANENT: the
      // truthful 'failed' that the retries eventually produce is discarded as a
      // duplicate, and the job is never re-offered to anybody.
      //
      // This does not contradict the optimism at the `_remember` site. That
      // optimism is about PROCESS DEATH, where the outcome is unknowable and
      // guessing "printed" risks only a reprint. A live retry is a different
      // state: the outcome is knowable, just not yet known, and the queue that
      // owns it will ack the truth in a moment. Nothing is lost by waiting —
      // and nothing prints twice, because we return without queueing.
      if (_queue.any((j) => j.jobId == jobId)) {
        // In flight: a live emit and a replay of the same job crossing, or two
        // deliveries on a flapping socket. It has not printed yet, so there is
        // nothing to re-confirm — just don't queue it twice.
        _log('Skipped $billId — job already queued');
        return;
      }
      final previous = _settled[jobId];
      if (previous != null) {
        // ALREADY DEALT WITH HERE, and no longer in flight. The server only
        // re-sends what it has no ack for, so arriving here means our ack never
        // landed — not that the job needs printing. Print it again and the
        // customer gets a second copy of a bill they have already been handed.
        _log('Skipped $billId — job already $previous on this till');
        unawaited(_ack(jobId, previous));
        return;
      }
    }

    List<int> bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      _log('Bad escBase64 for $billId');
      return;
    }
    if (kind == 'kot' && station != null) _rememberStation(station);
    _queue.add(PrintJob(billId, bytes, jobId: jobId, kind: kind, station: station, replay: replay));
    _log('Queued $billId (${bytes.length} bytes)${replay ? ' · re-sent by the server' : ''}');
    notifyListeners();
    await _processQueue();
  }

  Future<void> _processQueue() async {
    if (_processing || _paused) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty && !_paused) {
        final job = _queue.first;
        final printer = printerFor(job);
        if (printer == null || printer.isEmpty) {
          _log('No printer selected — ${_queue.length} job(s) waiting.');
          break; // leave jobs queued until a printer is chosen
        }
        final jobId = job.jobId;
        if (jobId != null && job.attempts == 0) {
          // RECORDED BEFORE THE BYTES GO OUT, on purpose. If the process dies
          // between handing the spooler a receipt and learning that it took it,
          // the truth is unknowable — and the two ways of being wrong are not
          // equal. Treating a maybe-printed job as printed risks a missing copy
          // the waiter can reprint on demand; treating it as unprinted risks
          // handing the customer a second charge slip. This is not the ack: the
          // server is told nothing until the write below actually succeeds.
          await _remember(jobId, 'printed');
        }
        final outcome = await _send(printer, job.bytes);
        if (outcome.ok) {
          _queue.removeAt(0);
          job.lastError = null;
          _log('Printed ${job.billId} on "${PrintTarget.label(printer)}"');
          if (job.replay) _replayPrinted++;
          // ONLY NOW. The ack is the claim that the bytes reached this printer,
          // so it follows the transport accepting them and nothing else.
          if (jobId != null) unawaited(_ack(jobId, 'printed'));
        } else {
          job.attempts++;
          // THE REASON IS KEPT, NOT DISCARDED. A network printer fails in ways
          // an owner can fix — wrong port, switched off, on the guest Wi-Fi —
          // and every one of those looks identical as a bare false.
          job.lastError = outcome.error;
          final why = outcome.error == null ? '' : ': ${outcome.error}';
          if (job.attempts >= 3) {
            _queue.removeAt(0);
            _log('Gave up on ${job.billId} after ${job.attempts} attempts$why');
            if (jobId != null) {
              // Told to the server as a FAILURE, not left silent. An unacked job
              // would be replayed to this same broken printer on every
              // reconnect; a job acked 'failed' is a settled, queryable record
              // that this receipt never printed.
              await _remember(jobId, 'failed');
              unawaited(_ack(jobId, 'failed'));
            }
          } else {
            _log('Print failed for ${job.billId} (attempt ${job.attempts})$why — retrying');
            notifyListeners();
            await Future.delayed(retryDelayFor(printer));
          }
        }
        notifyListeners();
      }
    } finally {
      _processing = false;
    }
    if (_queue.isEmpty) _requestNextReplayWindow();
  }

  /// Ask for the next slice of the backlog.
  ///
  /// The server hands over a BOUNDED window per resume (20 by default) so a
  /// fleet-wide reconnect cannot become a fleet-wide dump. Re-emitting
  /// joinOutlet is how the agent asks for the next one — the handler is
  /// idempotent, and the room join it repeats is a no-op.
  ///
  /// Only ever called after the queue has drained, and only when the last window
  /// actually produced printed output. A window that was entirely deduplicated
  /// means our acks are still catching up, so asking again would spin; the next
  /// reconnect picks it up instead. The round cap is the backstop.
  /// Whether a re-ask is pending. Test seam: an empty replay window must arm a
  /// retry rather than end the conversation, and that is otherwise invisible
  /// from outside because it happens on a timer with no socket in the harness.
  @visibleForTesting
  bool get replayRetryPending => _replayRetry?.isActive ?? false;

  /// Re-ask once the server-side lease can plausibly have expired.
  ///
  /// Bounded by the same [_maxReplayRounds] cap as a productive window, so a
  /// permanently-empty backlog costs a handful of no-op joins and then stops.
  void _scheduleReplayRetry() {
    _replayRetry?.cancel();
    if (_replayRounds >= _maxReplayRounds) return;
    _replayRetry = Timer(_replayRetryDelay, () {
      if (!_connected) return;
      _replayPrinted = 1; // let the guard through; this IS the retry
      _requestNextReplayWindow();
    });
  }

  void _requestNextReplayWindow() {
    // An empty window means the backlog is either genuinely drained or still
    // leased to a connection that has gone away. Those are indistinguishable
    // from here, so retry on a timer rather than giving up: the lease expires
    // in ~2 minutes and the round cap below bounds this either way.
    if (_replayPrinted == 0) {
      _scheduleReplayRetry();
      return;
    }
    _replayRetry?.cancel();
    _replayPrinted = 0;
    if (_replayRounds >= _maxReplayRounds) {
      // Reached only with output from the last window (the retry timer stops
      // arming at the cap, above), so this is a backlog genuinely cut short.
      _replayPaused = true;
      _log('Paused catching up after $_maxReplayRounds batches — reconnect to continue.');
      return;
    }
    final socket = _socket;
    final resId = _resId;
    final outletId = _outletId;
    if (socket == null || resId == null || outletId == null || !_connected) return;
    _replayRounds++;
    socket.emit('joinOutlet', joinPayload(resId, outletId));
  }

  /// Tell the server what happened to one job.
  ///
  /// POST rather than a Socket.IO ack callback because a socket ack is scoped to
  /// the connection that delivered the job — if it drops between delivery and
  /// acknowledgement, which is the exact failure this design exists to survive,
  /// the callback is discarded and can never be retried.
  ///
  /// Retried a few times, then given up on WITHOUT losing anything: an
  /// unacknowledged job is re-sent on the next reconnect, and [onPrintEvent]
  /// recognises it from [_settled] and re-acks it there instead of reprinting.
  /// That is the whole reason the local record is persisted rather than kept in
  /// memory beside the queue.
  Future<void> _ack(String jobId, String result) async {
    final auth = _auth;
    final token = auth?.token;
    if (auth == null || token == null) {
      _log('Cannot confirm job $jobId — not signed in.');
      return;
    }
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await auth.api.request(
          'POST',
          '/print/ack',
          token,
          <String, dynamic>{'jobId': jobId, 'result': result},
          // The CONCRETE outlet, never the "all" sentinel — the backend rejects
          // every write while that aggregate view is active.
          _outletId,
        );
        return;
      } on ApiException catch (e) {
        // A refusal of the request itself: a malformed id (400), a dead session
        // (401) or a role without the print permission (403). Repeating it just
        // repeats the refusal.
        if (e.status == 400 || e.status == 401 || e.status == 403) {
          _log('Print confirmation refused for job $jobId: ${e.message}');
          return;
        }
      } catch (_) {/* transport failure — worth another try */}
      if (attempt < 3) await Future.delayed(_retryDelay);
    }
    _log('Could not confirm job $jobId — the server will re-send it and it will be skipped.');
  }

  Future<void> _ensureSettledLoaded() => _settledLoad ??= _loadSettled();

  Future<void> _loadSettled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in prefs.getStringList(_settledKey) ?? const <String>[]) {
        final sep = entry.indexOf('|');
        if (sep <= 0) continue;
        final id = entry.substring(0, sep);
        if (id.isEmpty || _settled.containsKey(id)) continue;
        _settledOrder.add(id);
        _settled[id] = entry.substring(sep + 1) == 'failed' ? 'failed' : 'printed';
      }
    } catch (_) {
      // A device whose prefs cannot be read starts with an empty set: dedup
      // falls back to the in-flight check, which still stops the common case.
    }
  }

  Future<void> _remember(String jobId, String result) async {
    await _ensureSettledLoaded();
    if (!_settled.containsKey(jobId)) _settledOrder.add(jobId);
    _settled[jobId] = result;
    while (_settledOrder.length > _settledCap) {
      _settled.remove(_settledOrder.removeAt(0));
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _settledKey,
        [for (final id in _settledOrder) '$id|${_settled[id]}'],
      );
    } catch (_) {
      // In-memory dedup still holds for this session; only a restart loses it.
    }
  }

  /// WHICH PRINTER THIS JOB GOES TO.
  ///
  /// Most specific rule first, and the DEFAULT PRINTER IS ALWAYS THE LAST STEP.
  /// That ordering is the whole safety property of this feature: a docket for a
  /// station nobody wrote a rule for is not dropped, not held and not guessed
  /// at — it comes out of the same printer it came out of before routing
  /// existed. An owner who configures nothing has one printer that prints
  /// everything, which is the shipped behaviour and the right default for the
  /// small place this app mostly runs in.
  ///
  ///   1. `kot:<STATION>` for this docket's own station,
  ///   2. `kot` — every kitchen docket,
  ///   3. `bill` — customer bills,
  ///   4. the default printer.
  ///
  /// A rule naming a printer that is NOT INSTALLED falls through to the default
  /// too. A printer can be uninstalled, renamed or simply belong to the other
  /// till, and honouring a rule that points at nothing would hand the spooler a
  /// name it must refuse — three failed attempts and a 'failed' ack for a
  /// receipt that could have printed perfectly well downstairs.
  @visibleForTesting
  String? printerFor(PrintJob job) {
    for (final role in rolesFor(job)) {
      final name = _routes[role];
      if (name != null && name.isNotEmpty && knowsTarget(name)) return name;
    }
    final fallback = _selectedPrinter;
    // A DEFAULT THAT IS NOT REALLY THERE IS NOT A DEFAULT. On Windows this is
    // permissive on purpose — a spooler queue that is momentarily missing from
    // the enumeration is still worth trying, and that is the shipped behaviour.
    // A stale NETWORK default is different: it is an address this device no
    // longer has, so honouring it burns three attempts on a socket that cannot
    // exist and settles the docket as failed.
    if (fallback != null && PrintTarget.isNetwork(fallback) && !_netTargets.contains(fallback)) {
      return null;
    }
    return fallback;
  }

  /// Put the bytes on whichever transport [target] names.
  ///
  /// The two are deliberately the same shape to the queue above: it asks for a
  /// print and is told whether it happened and, if not, why. Everything the
  /// durability contract rests on — the ack following the write, the three
  /// attempts, the settled record — is written once and applies to both.
  Future<({bool ok, String? error})> _send(String target, List<int> bytes) async {
    final net = PrintTarget.parse(target);
    if (net != null) {
      final err = await _netWrite(net.host, net.port, bytes);
      return (ok: err == null, error: err);
    }
    if (PrintTarget.isNetwork(target)) {
      // An address that announces itself as one and cannot be read. Every path
      // that stores a target validates it, so this is a corrupted preference
      // rather than a live case — but falling through would hand the WINDOWS
      // SPOOLER the string "tcp://...", and a queue-not-found from winspool is
      // the least informative way this could possibly fail.
      return (ok: false, error: 'Saved printer address "$target" cannot be read. Remove it and add the printer again.');
    }
    if (!hasSpooler) {
      // Only reachable if a rule written on a Windows till were carried to a
      // phone — the routing map is per device, so it should not happen, but a
      // silent false here would look exactly like a printer that is switched off.
      return (ok: false, error: 'This device has no Windows printer queues. Point this at a network printer instead.');
    }
    final ok = _write(target, bytes);
    return (ok: ok, error: ok ? null : 'The Windows printer queue "$target" would not take the job.');
  }

  /// The roles that could route [job], most specific first.
  @visibleForTesting
  static List<String> rolesFor(PrintJob job) {
    if (job.kind != 'kot') return const [PrintRole.bill];
    final station = job.station?.trim() ?? '';
    return [
      if (station.isNotEmpty) PrintRole.kotStation(station),
      PrintRole.anyKot,
    ];
  }

  void _rememberStation(String station) {
    final s = station.trim();
    if (s.isEmpty) return;
    if (_seenStations.any((e) => e.toLowerCase() == s.toLowerCase())) return;
    _seenStations.add(s);
    notifyListeners();
  }

  String get _routesKey => '$_routesKeyPrefix${_outletId ?? ''}';

  Future<void> _loadRoutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = <String, String>{};
      for (final entry in prefs.getStringList(_routesKey) ?? const <String>[]) {
        final sep = entry.indexOf('=');
        if (sep <= 0) continue;
        final role = entry.substring(0, sep);
        final name = entry.substring(sep + 1);
        if (role.isEmpty || name.isEmpty) continue;
        next[role] = name;
        // A rule for a station is itself evidence the station exists, so the
        // screen can show a configured rule before the day's first docket for
        // it arrives.
        final station = PrintRole.stationOf(role);
        if (station != null) _rememberStation(station);
      }
      _routes = next;
      if (_routes.isNotEmpty) _log('Loaded ${_routes.length} printer rule(s)');
      notifyListeners();
    } catch (_) {
      // Unreadable prefs mean no rules, which means the default printer takes
      // everything — degraded, but never a dropped docket.
    }
  }

  Future<void> _saveRoutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _routesKey,
        [for (final e in _routes.entries) '${e.key}=${e.value}'],
      );
    } catch (_) {
      // The in-memory map still routes for this session.
    }
  }

  String get _netKey => '$_netKeyPrefix${_outletId ?? ''}';

  Future<void> _loadNetworkPrinters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _netTargets = [
        for (final entry in prefs.getStringList(_netKey) ?? const <String>[])
          if (PrintTarget.parse(entry) != null) entry,
      ];
      if (_netTargets.isNotEmpty) {
        _log('Loaded ${_netTargets.length} network printer(s)');
      }
      notifyListeners();
    } catch (_) {
      // Unreadable prefs mean no network printers. On a phone that means
      // canClaimJobs is false and this device stays a viewer — degraded, but it
      // never takes a docket it cannot print.
    }
  }

  Future<void> _saveNetworkPrinters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_netKey, _netTargets);
    } catch (_) {
      // The in-memory list still prints for this session.
    }
  }

  /// Add a printer this device reaches over the network, at [host]:[port].
  ///
  /// Returns null once it is saved, or the reason it was not. The address is NOT
  /// dialled here — a printer that is merely switched off has to be
  /// configurable, and the alternative is an owner who cannot set the kitchen up
  /// in the morning because the kitchen is not open yet. [testPrintTo] is how
  /// they prove it works, and it says exactly what went wrong when it does not.
  Future<String?> addNetworkPrinter(String host, int port) async {
    final invalid = NetworkPrinter.validate(host, port);
    if (invalid != null) return invalid;
    final target = PrintTarget.network(host, port);
    if (_netTargets.contains(target)) return 'That printer is already on the list.';
    _netTargets = <String>[..._netTargets, target];
    await _saveNetworkPrinters();
    _log('Network printer added: ${PrintTarget.label(target)}');
    // THE FIRST PRINTER ON A DEVICE THAT HAS NO OTHER BECOMES THE DEFAULT.
    //
    // Without this, adding a printer on a phone is a dead control: the address
    // is saved, the agent connects, and every docket sits in the queue reporting
    // "No printer selected" because nothing routes to it yet. It is the same
    // courtesy discoverPrinters() has always done for a Windows till with
    // exactly one installed queue.
    //
    // It never overrides a choice already made, and never fires on a machine
    // that has spooler queues of its own — a till whose default is a USB printer
    // must not silently start sending its bills across the network because
    // somebody added a kitchen printer.
    if ((_selectedPrinter == null || _selectedPrinter!.isEmpty) && _printers.isEmpty) {
      await setSelectedPrinter(target);
    }
    // A phone that had nowhere to print now has somewhere, so the agent that
    // declined to join the outlet room at start() can join it. On a Windows till
    // this is already running and start() is idempotent.
    final auth = _auth;
    if (!_started && auth != null) {
      unawaited(start(auth));
    } else {
      notifyListeners();
      unawaited(_processQueue()); // anything held for want of a printer goes now
    }
    return null;
  }

  /// Forget a network printer, and every rule that pointed at it.
  ///
  /// The rules go too, deliberately. A rule naming an address this device no
  /// longer has is a rule that silently falls through to the default printer,
  /// which is the shape of bug where the bar's dockets quietly start coming out
  /// at the till and nobody can see why from the screen.
  Future<void> removeNetworkPrinter(String target) async {
    if (!_netTargets.remove(target)) return;
    _netTargets = List<String>.from(_netTargets);
    await _saveNetworkPrinters();
    final orphaned = [for (final e in _routes.entries) if (e.value == target) e.key];
    if (orphaned.isNotEmpty) {
      for (final role in orphaned) {
        _routes.remove(role);
      }
      await _saveRoutes();
    }
    if (_selectedPrinter == target) {
      _selectedPrinter = null;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_printerKey);
      } catch (_) {/* the in-memory clear still holds for this session */}
    }
    _log('Network printer removed: ${PrintTarget.label(target)}'
        '${orphaned.isEmpty ? '' : ' (${orphaned.length} rule(s) back to default)'}');
    notifyListeners();
    // A device that has just lost its only way to print leaves the outlet room,
    // for the same reason it never joined one before it had a printer: a live
    // `bill:print` reaches every agent in the room regardless of what any of
    // them can claim, and a phone collecting dockets it cannot put on paper is
    // a queue that grows all service and prints nothing.
    if (!canClaimJobs && _started) {
      _log('No printer left on this device — printing stopped.');
      await stop();
    }
  }

  /// Point one role at one printer. A printer may hold as many roles as the
  /// owner gives it — the one-printer-does-everything shop is just every role
  /// naming the same device.
  Future<void> setRoute(String role, String printerName) async {
    final name = printerName.trim();
    if (role.isEmpty || name.isEmpty) return;
    _routes[role] = name;
    await _saveRoutes();
    _log('${PrintRole.label(role)} -> "$name"');
    notifyListeners();
    await _processQueue(); // anything held for want of this rule goes now
  }

  /// Drop a rule. What it used to route falls back to the next rule that matches
  /// and, in the end, to the default printer — never to nowhere.
  Future<void> clearRoute(String role) async {
    if (_routes.remove(role) == null) return;
    await _saveRoutes();
    _log('${PrintRole.label(role)} -> default printer');
    notifyListeners();
    await _processQueue();
  }

  void discoverPrinters() {
    // Enumerating winspool anywhere else returns an empty list and would log
    // "Discovered 0 printer(s)" at a phone that was never going to have any — a
    // true sentence that reads like a fault.
    if (!hasSpooler) return;
    _printers = WinRawPrinter.listPrinters();
    // Auto-pick when there's exactly one, or keep a still-valid saved choice.
    final saved = _selectedPrinter;
    if (saved != null && saved.isNotEmpty && !PrintTarget.isNetwork(saved) && !_printers.contains(saved)) {
      // saved printer no longer present; keep the name but warn
      _log('Saved printer "$saved" not found among installed printers.');
    }
    if ((saved == null || saved.isEmpty) && _printers.length == 1) {
      setSelectedPrinter(_printers.first);
    }
    _log('Discovered ${_printers.length} printer(s)');
    notifyListeners();
  }

  Future<void> setSelectedPrinter(String name) async {
    _selectedPrinter = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_printerKey, name);
    _log('Default printer set to "${PrintTarget.label(name)}"');
    notifyListeners();
    await _processQueue(); // flush anything that was waiting on a printer
  }

  void setPaused(bool value) {
    _paused = value;
    _log(value ? 'Printing paused' : 'Printing resumed');
    notifyListeners();
    if (!value) unawaited(_processQueue());
  }

  /// Discard the pending jobs — the one deliberate "do not print these".
  ///
  /// Each one is settled as failed rather than dropped, because the server still
  /// holds them as outstanding: left unacknowledged they would be re-sent on the
  /// next reconnect and print anyway, which is the opposite of what the button
  /// says. Recording it as a failure is also true — the receipt never came out.
  void clearQueue() {
    final discarded = List<PrintJob>.from(_queue);
    _queue.clear();
    _log('Queue cleared');
    notifyListeners();
    for (final job in discarded) {
      final id = job.jobId;
      if (id == null) continue;
      unawaited(_remember(id, 'failed').then((_) => _ack(id, 'failed')));
    }
  }

  /// The bytes of the test slip: ESC @ (init), centred text, feed, full cut.
  ///
  /// Deliberately the smallest thing a thermal printer can be asked to do, so a
  /// failure is a failure of the CONNECTION and not of the docket — a slip that
  /// exercised the renderer as well would leave two explanations for one blank
  /// piece of paper.
  static List<int> testSlipBytes() => <int>[
        0x1b, 0x40,
        0x1b, 0x61, 0x01,
        ...utf8.encode('Restaurant Dash\n'),
        ...utf8.encode('Printer test OK\n'),
        ...utf8.encode('${RestaurantTime.stampNow()}\n'),
        0x0a, 0x0a, 0x0a,
        0x1d, 0x56, 0x00,
      ];

  /// Print a test slip on the default printer. Null on success, else the reason.
  Future<String?> testPrint() {
    final printer = _selectedPrinter;
    if (printer == null || printer.isEmpty) {
      _log('Select a printer first.');
      return Future<String?>.value('Select a printer first.');
    }
    return testPrintTo(printer);
  }

  /// Print a test slip on ONE named target — a spooler queue or `tcp://host:port`.
  ///
  /// THE POINT OF THIS IS THAT AN OWNER CAN PROVE A PRINTER WORKS WITHOUT
  /// RINGING UP A REAL ORDER. It is also the only honest confirmation available
  /// for a network printer: port 9100 carries no application-level
  /// acknowledgement, so the software can report that the bytes left this device
  /// and nothing more. Paper coming out is the test.
  Future<String?> testPrintTo(String target) async {
    final outcome = await _send(target, testSlipBytes());
    final label = PrintTarget.label(target);
    _log(outcome.ok
        ? 'Test slip sent to "$label"'
        : 'Test print failed on "$label": ${outcome.error}');
    notifyListeners();
    return outcome.error;
  }

  /// Print a test slip at an address that has NOT been saved yet — the Test
  /// button inside the add-a-printer dialog, so a typo is caught while someone
  /// is still looking at it rather than becoming a rule that prints nowhere.
  Future<String?> testNetworkAddress(String host, int port) async {
    final invalid = NetworkPrinter.validate(host, port);
    if (invalid != null) return invalid;
    final err = await _netWrite(host.trim(), port, testSlipBytes());
    _log(err == null
        ? 'Test slip sent to $host:$port'
        : 'Test print failed at $host:$port: $err');
    notifyListeners();
    return err;
  }
}
