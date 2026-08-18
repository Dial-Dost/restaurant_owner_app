import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import 'api_client.dart';
import 'auth_controller.dart';
import 'restaurant_time.dart';
import 'win_raw_printer.dart';

/// How the raw ESC/POS bytes reach the spooler. Indirected only so a test can
/// drive the queue without a real winspool handle — production always uses
/// [WinRawPrinter.sendBytes].
typedef SpoolerWrite = bool Function(String printerName, List<int> bytes);

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

  io.Socket? _socket;
  AuthController? _auth;
  Timer? _keepAlive;

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
  final List<PrintJob> _queue = [];
  final List<String> _logs = [];

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

  SpoolerWrite _write = WinRawPrinter.sendBytes;
  bool? _supportedOverride;
  Duration _retryDelay = const Duration(seconds: 2);

  /// A service instance isolated from the app-wide singleton, with the spooler
  /// and the platform gate injected. Tests only.
  @visibleForTesting
  factory PrinterService.forTest({
    required AuthController auth,
    required SpoolerWrite write,
    bool supported = true,
    String? printer = 'Test Printer',
    String? outletId = 'outlet-1',
    Duration retryDelay = Duration.zero,
  }) {
    final s = PrinterService._();
    s._auth = auth;
    s._write = write;
    s._supportedOverride = supported;
    s._selectedPrinter = printer;
    s._outletId = outletId;
    s._resId = 'res-1';
    s._retryDelay = retryDelay;
    return s;
  }

  bool get supported => _supportedOverride ?? WinRawPrinter.supported;
  bool get connected => _connected;
  bool get paused => _paused;
  String? get selectedPrinter => _selectedPrinter;
  List<String> get printers => _printers;
  List<PrintJob> get queue => List.unmodifiable(_queue);
  List<String> get logs => List.unmodifiable(_logs);

  /// Whether this device may be handed the outlet's outstanding backlog.
  ///
  /// Tied to the ability to actually PRINT, not to being signed in. The app also
  /// runs on Android, where winspool does not exist and [WinRawPrinter.sendBytes]
  /// can only ever return false — an Android instance that claimed jobs would
  /// take them off the queue that the outlet's real till is waiting on and then
  /// fail to print every one of them. It therefore never advertises a version,
  /// and the server's interlock hands it nothing. (start() already refuses to
  /// open the socket at all off Windows; this is the same rule stated where the
  /// claim is actually made, so it cannot be lost to a refactor.)
  bool get canClaimJobs => supported;

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
      _log('Printing is only supported on Windows.');
      return;
    }
    if (_started) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    _selectedPrinter = prefs.getString(_printerKey);
    // Before the socket opens, so the first replayed job already has the
    // "already printed here" set to check itself against.
    await _ensureSettledLoaded();
    discoverPrinters();

    final token = auth.token;
    final profile = auth.profile;
    if (token == null || profile == null) {
      _log('Not signed in — cannot start printer.');
      return;
    }
    final resId = profile.resId;
    final outletId = resolveOutletId(auth.selectedOutletId, profile.outletId);
    _resId = resId;
    _outletId = outletId;

    _log('Connecting to realtime…');
    try {
      final opts = io.OptionBuilder()
          // websocket first, polling fallback (matches the backend's accepted
          // transports) so it still connects behind proxies that block WS upgrade.
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .enableReconnection()
          .setAuth({'token': token, 'restaurantId': resId})
          .build();
      final socket = io.io(AppConfig.backendUrl, opts);
      _socket = socket;

      socket.onConnect((_) {
        _connected = true;
        _log('Connected to realtime');
        // Fires on every RECONNECT too, which is what makes this the resume
        // hook: the server replays the outlet's outstanding jobs in response.
        _replayRounds = 0;
        _replayPrinted = 0;
        socket.emit('joinOutlet', joinPayload(resId, outletId));
        notifyListeners();
        // Anything held over from before the drop (the queue is no longer
        // discarded) goes out now.
        unawaited(_processQueue());
      });
      socket.onDisconnect((_) {
        _connected = false;
        _log('Disconnected from realtime');
        notifyListeners();
      });
      socket.onConnectError((e) => _log('Connect error: $e'));
      socket.onError((e) => _log('Socket error: $e'));
      socket.on('joinedOutlet', (_) => _log('Subscribed to outlet $outletId'));
      socket.on('bill:print', onPrintEvent);

      socket.connect();
    } catch (e) {
      _log('Failed to connect: $e');
    }

    // Keep the session warm so a long-idle till still prints after a reconnect.
    _keepAlive?.cancel();
    _replayRetry?.cancel();
    _keepAlive = Timer.periodic(const Duration(minutes: 25), (_) async {
      final t = _auth?.token;
      if (t == null) return;
      try {
        await _auth!.api.me(t);
      } catch (_) {/* surfaced elsewhere if the session is truly gone */}
    });
  }

  Future<void> stop() async {
    _started = false;
    _connected = false;
    _keepAlive?.cancel();
    _replayRetry?.cancel();
    _keepAlive = null;
    try {
      _socket?.dispose();
    } catch (_) {/* ignore */}
    _socket = null;
    _replayRounds = 0;
    _replayPrinted = 0;
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
      final previous = _settled[jobId];
      if (previous != null) {
        // ALREADY DEALT WITH HERE. The server only re-sends what it has no ack
        // for, so arriving here means our ack never landed — not that the job
        // needs printing. Print it again and the customer gets a second copy of
        // a bill they have already been handed.
        _log('Skipped $billId — job already $previous on this till');
        unawaited(_ack(jobId, previous));
        return;
      }
      if (_queue.any((j) => j.jobId == jobId)) {
        // In flight: a live emit and a replay of the same job crossing, or two
        // deliveries on a flapping socket. It has not printed yet, so there is
        // nothing to re-confirm — just don't queue it twice.
        _log('Skipped $billId — job already queued');
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
        final printer = _selectedPrinter;
        if (printer == null || printer.isEmpty) {
          _log('No printer selected — ${_queue.length} job(s) waiting.');
          break; // leave jobs queued until a printer is chosen
        }
        final job = _queue.first;
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
        final ok = _write(printer, job.bytes);
        if (ok) {
          _queue.removeAt(0);
          _log('Printed ${job.billId}');
          if (job.replay) _replayPrinted++;
          // ONLY NOW. The ack is the claim that paper came out of this printer,
          // so it follows the spooler accepting the bytes and nothing else.
          if (jobId != null) unawaited(_ack(jobId, 'printed'));
        } else {
          job.attempts++;
          if (job.attempts >= 3) {
            _queue.removeAt(0);
            _log('Gave up on ${job.billId} after ${job.attempts} attempts');
            if (jobId != null) {
              // Told to the server as a FAILURE, not left silent. An unacked job
              // would be replayed to this same broken printer on every
              // reconnect; a job acked 'failed' is a settled, queryable record
              // that this receipt never printed.
              await _remember(jobId, 'failed');
              unawaited(_ack(jobId, 'failed'));
            }
          } else {
            _log('Print failed for ${job.billId} (attempt ${job.attempts}) — retrying');
            notifyListeners();
            await Future.delayed(_retryDelay);
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

  void discoverPrinters() {
    _printers = WinRawPrinter.listPrinters();
    // Auto-pick when there's exactly one, or keep a still-valid saved choice.
    if (_selectedPrinter != null && !_printers.contains(_selectedPrinter)) {
      // saved printer no longer present; keep the name but warn
      _log('Saved printer "$_selectedPrinter" not found among installed printers.');
    }
    if ((_selectedPrinter == null || _selectedPrinter!.isEmpty) && _printers.length == 1) {
      setSelectedPrinter(_printers.first);
    }
    _log('Discovered ${_printers.length} printer(s)');
    notifyListeners();
  }

  Future<void> setSelectedPrinter(String name) async {
    _selectedPrinter = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_printerKey, name);
    _log('Default printer set to "$name"');
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

  /// Print a tiny ESC/POS test slip to verify the selected printer works.
  bool testPrint() {
    final printer = _selectedPrinter;
    if (printer == null || printer.isEmpty) {
      _log('Select a printer first.');
      return false;
    }
    // ESC @ (init), centered text, feed, full cut.
    final bytes = <int>[
      0x1b, 0x40,
      0x1b, 0x61, 0x01,
      ...utf8.encode('Restaurant Dash\n'),
      ...utf8.encode('Printer test OK\n'),
      ...utf8.encode('${RestaurantTime.stampNow()}\n'),
      0x0a, 0x0a, 0x0a,
      0x1d, 0x56, 0x00,
    ];
    final ok = _write(printer, bytes);
    _log(ok ? 'Test slip sent to "$printer"' : 'Test print failed on "$printer"');
    notifyListeners();
    return ok;
  }
}
