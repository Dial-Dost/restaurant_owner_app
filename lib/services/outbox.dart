import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Thrown to the caller when a mutating request could not reach the server and
/// was appended to the [Outbox] instead.
///
/// It is deliberately an ERROR and not a value. Every one of the ~128 write call
/// sites already wraps its write in a try/catch that surfaces the message, so
/// throwing is the only way to say "saved, but the kitchen has NOT seen this"
/// at all of them without editing all of them — and returning a synthetic
/// success would make each of those screens print "Saved" for work that has not
/// happened yet. The message is the honest sentence the user reads.
class OfflineQueued implements Exception {
  const OfflineQueued(this.entryId, this.what);

  /// The queued entry's idempotency key — the id shown in the outbox sheet.
  final String entryId;

  /// The human description of the queued action ("Order for T4 · 3 items").
  final String what;

  @override
  String toString() =>
      "Saved on this device — it will send when the connection returns. "
      "The kitchen has not seen it yet.";
}

/// Thrown when a mutating request could not reach the server and must NOT be
/// queued: bill settlement and anything that mints a bill or KOT number.
///
/// An invoice number cannot be minted on a device. Indian GST expects a
/// sequential, gap-free series per outlet, and the numbers come from the cloud
/// (`update "Outlets" set bill_seq = …` and AllocateKotNumber's row lock), so a
/// queued settle would either duplicate or gap a real tax document. Refusing
/// loudly is the only honest answer.
class OfflineUnavailable implements Exception {
  const OfflineUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the [OutboxPolicy] decided about one (method, path).
class OutboxDecision {
  const OutboxDecision.queue()
      : queueable = true,
        refusal = '';
  const OutboxDecision.refuse(this.refusal) : queueable = false;

  final bool queueable;

  /// The sentence shown when this path is attempted with no connection.
  final String refusal;
}

/// Which offline writes may be saved for later, and what the others say instead.
///
/// AN ALLOW-LIST, and deliberately so. Queuing a write means it may be sent
/// twice, which is only safe where the server deduplicates — and there
/// `idempotent()` is a per-route opt-in, not global middleware. A deny-list
/// would fail OPEN: every route added later would queue, gain an automatic
/// retry it never had, and double-apply against a server that never looks for
/// the key.
///
/// Two layers, in order. The DENIED prefixes come first, not because the
/// allow-list would let them through, but because they deserve a specific
/// sentence: a request whose effect is a number or an amount of money only the
/// server may issue. Everything not then named in `_allowed` is refused with a
/// generic line — for most of the app, "reconnect" is the honest answer.
abstract final class OutboxPolicy {
  /// Bill settlement and every sibling that runs through nextBillNo():
  /// /bills/order/:id/waiter-confirm-payment, /admin-approve-payment, /close,
  /// /bills, /bills/replace, /bills/merge, /bills/split, /bills/discount,
  /// /bills/apply-coupon, /bills/refund, /bills/remove-item, /bills/move-item,
  /// /bills/item-note, /bills/:id/reopen.
  static const String billing =
      'Billing needs a connection — orders are saved, but a bill number can '
      'only be issued by the server. Reconnect to settle.';

  /// /print/bill and /publish/bill allocate the day's KOT number
  /// (AllocateKotNumber, per-outlet, per-business-day, gapless). A ticket
  /// printed from a queue would also print stale.
  static const String printing =
      'Printing needs a connection — the kitchen ticket number is issued by '
      'the server, and a docket must not print late.';

  /// Payroll disbursement and the cash-drawer session. Not a minted number, but
  /// the same hazard: replaying money movement into a later shift is worse than
  /// refusing it now.
  static const String money =
      'This needs a connection — money movements are never saved to send later.';

  /// Path prefixes that are never queued, longest-specific first.
  static const List<(String, String)> _denied = [
    ('/bills', billing),
    ('/billing', money),
    ('/print', printing),
    ('/publish', printing),
    ('/payroll/pay', money),
    ('/cash', money),
  ];

  /// Said when a write is simply not one of the deduplicated few. Deliberately
  /// not an apology for a bug — for most of the app, "reconnect" is the honest
  /// and correct answer.
  static const String unsupported =
      "This isn't saved offline — reconnect and try again.";

  /// THE QUEUEABLE SET, AND WHY IT IS AN ALLOWLIST.
  ///
  /// Queuing a write means it may be sent TWICE (the first attempt's response
  /// can be lost after the server applied it), so a route may only be queued if
  /// the SERVER deduplicates it. On the backend `idempotent()` is a per-route
  /// opt-in mounted on exactly these 27 endpoints — not global middleware — so
  /// this list is the client-side mirror of that opt-in and nothing else.
  ///
  /// A deny-list here would fail OPEN: every one of the ~34 other route files
  /// would queue, be retried automatically, and double-apply, because the
  /// server ignores the key it does not look for. `PUT /menu` is the sharpest
  /// example — a bulk menu save once wiped 56 items' images, sections and
  /// recipes, and this would have given that write an automatic retry it never
  /// had before.
  ///
  /// `:x` matches exactly one non-empty segment. Keep in step with
  /// `scripts/route_manifest.baseline.txt`, which is CI-enforced and is the
  /// authoritative list of what carries the guard.
  static const List<(String, String)> _allowed = [
    // orders.ts — 14
    ('POST', '/orders'),
    ('POST', '/orders/takeaway'),
    ('PATCH', '/orders/:id/status'),
    ('POST', '/orders/:id/items'),
    ('DELETE', '/orders/:id/items/:itemId'),
    ('DELETE', '/orders/:id'),
    ('POST', '/orders/:id/pause'),
    ('POST', '/orders/:id/resume'),
    ('POST', '/orders/:id/fire'),
    ('POST', '/orders/:id/bark'),
    ('POST', '/orders/:id/items/:itemId/serve'),
    ('POST', '/orders/:id/items/:itemId/unserve'),
    ('POST', '/orders/:id/items/:itemId/pause'),
    ('POST', '/orders/:id/items/:itemId/resume'),
    // tables.ts — 3
    ('POST', '/occupy-table'),
    ('PATCH', '/table-covers'),
    ('POST', '/release-table'),
    // waitlist.ts — 5
    ('POST', '/waitlist/:id/call'),
    ('POST', '/waitlist/:id/seat'),
    ('POST', '/waitlist/:id/preorder/confirm'),
    ('POST', '/waitlist/:id/preorder/decline'),
    ('POST', '/waitlist/:id/cancel'),
    // inventory.ts — 3
    ('POST', '/inventory/receive'),
    ('POST', '/inventory/wastage'),
    ('POST', '/inventory/issue'),
    // attendance.ts — 2
    ('POST', '/attendance/clock-in'),
    ('POST', '/attendance/clock-out'),
  ];

  static OutboxDecision decide(String method, String path) {
    if (method == 'GET') return const OutboxDecision.refuse('');
    final clean = _stripQuery(path);
    // The hazardous families first, so a waiter gets the sentence that explains
    // WHY billing or printing needs the line, rather than the generic refusal
    // the allowlist would otherwise hand them.
    for (final (prefix, why) in _denied) {
      if (_underPrefix(clean, prefix)) return OutboxDecision.refuse(why);
    }
    for (final (m, pattern) in _allowed) {
      if (m == method && _matches(clean, pattern)) {
        return const OutboxDecision.queue();
      }
    }
    return const OutboxDecision.refuse(unsupported);
  }

  /// Segment-wise match where a `:name` segment stands for exactly one
  /// non-empty segment. Not a prefix match: `/orders/:id` must not swallow
  /// `/orders/:id/split`, which the server does not deduplicate.
  static bool _matches(String path, String pattern) {
    final p = path.split('/');
    final q = pattern.split('/');
    if (p.length != q.length) return false;
    for (var i = 0; i < q.length; i++) {
      if (q[i].startsWith(':')) {
        if (p[i].isEmpty) return false;
      } else if (p[i] != q[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _underPrefix(String path, String prefix) =>
      path == prefix || path.startsWith('$prefix/');

  static String _stripQuery(String path) {
    final q = path.indexOf('?');
    return q < 0 ? path : path.substring(0, q);
  }

  /// A sentence a waiter can read, derived from the request itself — the seam
  /// only knows method, path and body, and "POST /orders" tells nobody what is
  /// waiting. Unknown paths degrade to the raw request rather than a lie.
  static String describe(String method, String path, Object? body) {
    final clean = _stripQuery(path);
    final map = body is Map ? body : const {};
    final table = _str(map['table']).isNotEmpty
        ? _str(map['table'])
        : _str(map['table_name']);
    final items = map['items'];
    final n = items is List ? items.length : 0;
    final plural = n == 1 ? 'item' : 'items';
    if (clean == '/orders') {
      return table.isEmpty ? 'Order · $n $plural' : 'Order for $table · $n $plural';
    }
    if (clean == '/orders/takeaway') {
      final type = _str(map['order_type']);
      final label = type == 'delivery' ? 'Delivery order' : 'Takeaway order';
      return '$label · $n $plural';
    }
    if (clean == '/occupy-table') {
      final covers = map['num_covers'];
      return covers == null ? 'Seat $table' : 'Seat $table · $covers covers';
    }
    if (clean == '/release-table') return 'Free $table';
    if (clean.startsWith('/orders/') && clean.endsWith('/status')) {
      return 'Order → ${_str(map['status'])}'.trim();
    }
    if (clean.startsWith('/orders/') && clean.endsWith('/bark')) {
      return 'Bark order to the kitchen';
    }
    if (clean.startsWith('/orders/') && clean.endsWith('/fire')) {
      return 'Fire held course';
    }
    if (clean == '/table-assignments/assign') return 'Assign waiter to $table';
    if (clean == '/table-assignments/unassign') return 'Unassign waiter on $table';
    return '$method $clean';
  }

  /// The per-item grouping key, so a screen can ask "what is still waiting for
  /// THIS table" instead of only "how many actions are waiting overall".
  static String? tagFor(String path, Object? body) {
    final map = body is Map ? body : const {};
    for (final k in const ['table', 'table_name', 'to_table', 'from_table']) {
      final v = _str(map[k]);
      if (v.isNotEmpty) return 'table:$v';
    }
    return null;
  }

  static String _str(Object? v) => v == null ? '' : v.toString().trim();
}

/// One mutating request saved for later, with the client-generated idempotency
/// key it will be replayed under.
class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.method,
    required this.path,
    required this.body,
    required this.outletHeader,
    required this.what,
    required this.tag,
    required this.queuedAt,
    this.attempts = 0,
    this.failed = false,
    this.failureMessage,
    this.failureStatus,
    this.failedAt,
  });

  /// ULID — the idempotency key sent as `Idempotency-Key`, and the sort key
  /// that makes replay happen in the order the waiter did the work.
  final String id;
  final String method;
  final String path;
  final Object? body;

  /// The X-Outlet-Id in force when the action was taken. Replay must use THIS,
  /// not whatever outlet is selected when the line returns.
  final String? outletHeader;

  /// Human description, resolved at queue time (see [OutboxPolicy.describe]).
  final String what;

  /// Grouping key for per-item pending badges ('table:T4'), or null.
  final String? tag;

  final DateTime queuedAt;

  int attempts;

  /// True once replay hit something that will never succeed. A failed entry is
  /// PARKED, never dropped: silent loss is the failure mode this design exists
  /// to prevent.
  bool failed;
  String? failureMessage;
  int? failureStatus;
  DateTime? failedAt;

  bool get pending => !failed;

  Map<String, Object?> toJson() => {
        'i': id,
        'm': method,
        'p': path,
        if (body != null) 'b': body,
        if (outletHeader != null && outletHeader!.isNotEmpty) 'o': outletHeader,
        'w': what,
        if (tag != null) 'g': tag,
        'q': queuedAt.millisecondsSinceEpoch,
        'a': attempts,
        if (failed) 'f': true,
        if (failureMessage != null) 'e': failureMessage,
        if (failureStatus != null) 'c': failureStatus,
        if (failedAt != null) 'x': failedAt!.millisecondsSinceEpoch,
      };

  /// Returns null for anything that is not a well-formed entry — a half-written
  /// or hand-edited store degrades to fewer entries, never to a crash.
  static OutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['i'];
    final method = raw['m'];
    final path = raw['p'];
    if (id is! String || id.isEmpty) return null;
    if (method is! String || method.isEmpty) return null;
    if (path is! String || path.isEmpty) return null;
    final q = raw['q'];
    return OutboxEntry(
      id: id,
      method: method,
      path: path,
      body: raw['b'],
      outletHeader: raw['o'] is String ? raw['o'] as String : null,
      what: raw['w'] is String ? raw['w'] as String : '$method $path',
      tag: raw['g'] is String ? raw['g'] as String : null,
      queuedAt: DateTime.fromMillisecondsSinceEpoch(q is int ? q : 0),
      attempts: raw['a'] is int ? raw['a'] as int : 0,
      failed: raw['f'] == true,
      failureMessage: raw['e'] is String ? raw['e'] as String : null,
      failureStatus: raw['c'] is int ? raw['c'] as int : null,
      failedAt:
          raw['x'] is int ? DateTime.fromMillisecondsSinceEpoch(raw['x'] as int) : null,
    );
  }
}

/// Why a drain stopped. The chip and the sheet say this out loud.
enum OutboxDrainOutcome {
  /// Nothing was waiting.
  idle,

  /// The queue emptied.
  drained,

  /// Still no connection — everything stays queued.
  offline,

  /// An entry hit a permanent failure and is parked for a human.
  blocked,

  /// A retryable failure (5xx / 408 / 429); the heartbeat will try again.
  retryLater,

  /// The session is not usable (no token, or a 401 during replay).
  signedOut,
}

class OutboxDrainResult {
  const OutboxDrainResult(this.outcome, this.sent);
  final OutboxDrainOutcome outcome;
  final int sent;
}

/// Sends one entry. Supplied by [RestClient] so this file never has to know
/// about auth or the HTTP client.
typedef OutboxSender = Future<void> Function(OutboxEntry entry);

/// Persisted write queue behind [RestClient] — the write-side twin of
/// [GetCache], sitting at the same seam and keeping the same discipline: a
/// versioned key prefix so a format change stops matching instead of
/// mis-parsing, every read treated as possibly corrupt, and hard caps so the
/// single SharedPreferences file cannot be bloated by it.
///
/// Scoped restaurant | outlet, exactly like the read cache, so branch A's
/// unsent work can never replay against branch B.
class Outbox extends ChangeNotifier {
  Outbox._();
  static final Outbox instance = Outbox._();

  /// Bump on any format change; entries under an older prefix are swept.
  static const String keyPrefix = 'rd_outbox_v1|';
  static const String _familyPrefix = 'rd_outbox_';

  /// Caps. Past these the queue REFUSES new work rather than evicting: an
  /// evicted order is silent loss, which is the one outcome this must never
  /// produce. A full outbox is a loud, fixable state.
  static const int maxEntries = 200;
  static const int maxBodyChars = 64000;

  /// A retryable failure (5xx, 408, 429) is tried this many times before the
  /// entry is parked for a human instead of spinning forever.
  static const int maxAttempts = 8;

  String? _scope;
  List<OutboxEntry> _entries = <OutboxEntry>[];
  bool _draining = false;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static String scopeKey(String res, String outlet) => '$res|$outlet';

  /// The entries in the currently loaded scope, oldest first.
  List<OutboxEntry> get entries => List.unmodifiable(_entries);

  int get pendingCount => _entries.where((e) => e.pending).length;
  int get failedCount => _entries.where((e) => e.failed).length;

  /// Cheap, synchronous, and the hot-path guard: with an empty queue this is
  /// false and a write goes straight to the network exactly as it does today.
  bool get hasPending => _entries.any((e) => e.pending);

  bool get isDraining => _draining;

  /// How many actions are still waiting for one tagged subject ('table:T4').
  int pendingForTag(String tag) =>
      _entries.where((e) => e.pending && e.tag == tag).length;

  int failedForTag(String tag) =>
      _entries.where((e) => e.failed && e.tag == tag).length;

  /// Loads [scope]'s queue if it is not already the loaded one. Cheap when the
  /// scope has not changed (the common case) — one prefs read per scope.
  Future<void> ensureScope(String res, String outlet) async {
    final key = scopeKey(res, outlet);
    if (_scope == key) return;
    _scope = key;
    _entries = await _read(key);
    notifyListeners();
  }

  Future<List<OutboxEntry>> _read(String scope) async {
    try {
      final p = await _prefs;
      await _sweepOldVersions(p);
      final raw = p.getString('$keyPrefix$scope');
      if (raw == null) return <OutboxEntry>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        // Parseable but the wrong shape: drop it so it only ever costs once.
        unawaited(p.remove('$keyPrefix$scope'));
        return <OutboxEntry>[];
      }
      final out = <OutboxEntry>[];
      for (final e in decoded) {
        final entry = OutboxEntry.fromJson(e);
        if (entry != null) out.add(entry);
      }
      out.sort((a, b) => a.id.compareTo(b.id));
      return out;
    } catch (_) {
      // Corrupt store, missing plugin, anything at all: an unreadable outbox
      // degrades to an empty one. The app must still open and take orders.
      return <OutboxEntry>[];
    }
  }

  Future<void> _sweepOldVersions(SharedPreferences p) async {
    for (final k in p
        .getKeys()
        .where((k) => k.startsWith(_familyPrefix) && !k.startsWith(keyPrefix))
        .toList()) {
      await p.remove(k);
    }
  }

  Future<void> _persist() async {
    final scope = _scope;
    if (scope == null) return;
    try {
      final p = await _prefs;
      if (_entries.isEmpty) {
        await p.remove('$keyPrefix$scope');
      } else {
        await p.setString(
            '$keyPrefix$scope', jsonEncode(_entries.map((e) => e.toJson()).toList()));
      }
    } catch (_) {
      // The in-memory queue still drains this session; a failed persist costs
      // durability across a restart, never the work in hand.
    }
  }

  /// Appends one request. Throws [OfflineUnavailable] rather than dropping it
  /// when the queue cannot honestly hold it (full, or a body that will not
  /// serialise).
  Future<OutboxEntry> enqueue({
    required String res,
    required String outlet,
    required String method,
    required String path,
    required Object? body,
    required String? outletHeader,
    /// The idempotency key the online attempt already put on the wire, when
    /// there was one. It MUST be reused rather than replaced: if the server
    /// applied the write and only the response was lost, replaying under a
    /// fresh key reads as a brand-new write and applies it a second time.
    /// Null only for work that never made an attempt at all.
    String? id,
  }) async {
    await ensureScope(res, outlet);
    if (_entries.length >= maxEntries) {
      throw const OfflineUnavailable(
          'Too much is already waiting to send. Reconnect and let the queue '
          'clear before adding more.');
    }
    if (body != null) {
      String encoded;
      try {
        encoded = jsonEncode(body);
      } catch (_) {
        throw const OfflineUnavailable(
            "This action can't be saved offline. Reconnect and try again.");
      }
      if (encoded.length > maxBodyChars) {
        throw const OfflineUnavailable(
            'This is too large to save offline. Reconnect and try again.');
      }
    }
    final entry = OutboxEntry(
      id: id ?? newIdempotencyKey(),
      method: method,
      path: path,
      body: body,
      outletHeader: outletHeader,
      what: OutboxPolicy.describe(method, path, body),
      tag: OutboxPolicy.tagFor(path, body),
      queuedAt: DateTime.now(),
    );
    _entries.add(entry);
    await _persist();
    notifyListeners();
    return entry;
  }

  /// Replays the queue against the network, in order, one at a time.
  ///
  /// Stops — it never spins — on the first entry that cannot go through:
  ///   * transport failure  -> still offline; everything stays queued;
  ///   * 4xx (not 408/429)  -> permanent; the entry is PARKED as failed with
  ///     the server's own words, and the drain halts so the entries behind it
  ///     (which may depend on it) are not applied out of order;
  ///   * 401                -> the session, not the entry, is the problem: the
  ///     entry stays pending and the drain halts;
  ///   * 5xx / 408 / 429    -> retryable; attempts is bumped and the drain
  ///     halts until the next heartbeat, parking the entry after [maxAttempts].
  Future<OutboxDrainResult> drain(OutboxSender send) async {
    if (_draining) return const OutboxDrainResult(OutboxDrainOutcome.idle, 0);
    if (!hasPending) return const OutboxDrainResult(OutboxDrainOutcome.idle, 0);
    _draining = true;
    notifyListeners();
    var sent = 0;
    var outcome = OutboxDrainOutcome.drained;
    try {
      while (true) {
        final entry = _entries.cast<OutboxEntry?>().firstWhere(
              (e) => e!.pending,
              orElse: () => null,
            );
        if (entry == null) break;
        try {
          await send(entry);
          _entries.removeWhere((e) => e.id == entry.id);
          sent++;
          await _persist();
          notifyListeners();
        } catch (err) {
          final status = err is ApiException ? err.status : null;
          if (status == null) {
            outcome = OutboxDrainOutcome.offline;
            break;
          }
          if (status == 401) {
            outcome = OutboxDrainOutcome.signedOut;
            break;
          }
          // 409 is the server saying "this exact key is still in flight" —
          // idempotency.ts answers it with `retryable:true` and `Retry-After`.
          // It means the write is probably LANDING, so parking it as failed
          // would show a red chip for work that succeeded. Safe to retry
          // blindly because only allowlisted, server-deduplicated routes ever
          // reach this queue (see OutboxPolicy._allowed): on those, 409 has no
          // other meaning.
          final retryable =
              status >= 500 || status == 408 || status == 429 || status == 409;
          if (!retryable) {
            _park(entry, err, status);
            outcome = OutboxDrainOutcome.blocked;
            break;
          }
          entry.attempts++;
          if (entry.attempts >= maxAttempts) {
            _park(entry, err, status);
            outcome = OutboxDrainOutcome.blocked;
          } else {
            outcome = OutboxDrainOutcome.retryLater;
          }
          await _persist();
          notifyListeners();
          break;
        }
      }
    } finally {
      _draining = false;
      notifyListeners();
    }
    return OutboxDrainResult(outcome, sent);
  }

  void _park(OutboxEntry entry, Object err, int status) {
    entry.failed = true;
    entry.failureStatus = status;
    entry.failureMessage = err is ApiException ? err.message : err.toString();
    entry.failedAt = DateTime.now();
  }

  /// Puts a parked entry back in the queue — the human said "try that again".
  Future<void> retry(String id) async {
    for (final e in _entries) {
      if (e.id == id && e.failed) {
        e.failed = false;
        e.attempts = 0;
        e.failureMessage = null;
        e.failureStatus = null;
        e.failedAt = null;
      }
    }
    await _persist();
    notifyListeners();
  }

  /// Removes an entry. Only ever called from an explicit human "discard" — the
  /// drain itself never deletes work it could not send.
  Future<void> discard(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  /// Wipes every outbox of every version. Used by tests; NOT wired to sign-out,
  /// because unsent work must outlive a sign-out (it is keyed per restaurant,
  /// so it cannot leak to the next tenant either).
  Future<void> clearAll() async {
    try {
      final p = await _prefs;
      for (final k in p.getKeys().where((k) => k.startsWith(_familyPrefix)).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
    _entries = <OutboxEntry>[];
    notifyListeners();
  }

  @visibleForTesting
  Future<void> debugReset() async {
    _scope = null;
    _entries = <OutboxEntry>[];
    _draining = false;
    notifyListeners();
  }
}

// --- Idempotency keys --------------------------------------------------------

const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final Random _rng = _secureRandom();

Random _secureRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

int _lastMs = 0;
List<int> _lastRandom = <int>[];

/// A ULID: 48 bits of millisecond timestamp then 80 bits of randomness, in
/// Crockford base32. Chosen over a UUIDv4 because it sorts lexicographically by
/// creation time — which is exactly the replay order the outbox needs, so the
/// key doubles as the queue's sort key. Monotonic inside a millisecond
/// (the random tail is incremented) so two orders taken in the same tick still
/// replay in the order they were taken.
String newIdempotencyKey([DateTime? now]) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (ms < 0) ms = 0;
  if (ms == _lastMs && _lastRandom.length == 16) {
    // Same millisecond: increment the random tail with carry rather than
    // drawing again, so the new key is guaranteed to sort after the last one.
    var i = 15;
    while (i >= 0) {
      if (_lastRandom[i] < 31) {
        _lastRandom[i]++;
        break;
      }
      _lastRandom[i] = 0;
      i--;
    }
  } else {
    _lastMs = ms;
    _lastRandom = List<int>.generate(16, (_) => _rng.nextInt(32));
  }
  final time = List<int>.filled(10, 0);
  var t = ms;
  for (var i = 9; i >= 0; i--) {
    time[i] = t & 31;
    t = t >> 5;
  }
  final buf = StringBuffer();
  for (final v in time) {
    buf.write(_crockford[v]);
  }
  for (final v in _lastRandom) {
    buf.write(_crockford[v]);
  }
  return buf.toString();
}
