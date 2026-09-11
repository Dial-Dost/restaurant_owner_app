/// THE SERVICE CLOCK, AS THE SERVER MEASURED IT — the client half of
/// service_clock.ts, and deliberately nothing more than a parser.
///
/// WHAT THIS FILE IS NOT. It is not a duration calculator. There is no
/// subtraction in it that involves this device's idea of what time it is, and
/// there must never be one, because the two failures it exists to prevent are
/// both failures of local arithmetic:
///
///   1. TWO CLIENTS, TWO ANSWERS. The owner app and the dashboard each used to
///      pick their own start (created_at? barked_at? the bill's created_at?) and
///      their own end (closed_at? admin_approved_at? waiter_confirmed_at?) and
///      subtract them. This app's table sheet stopped the clock at the ADMIN
///      APPROVAL; the server stops it at the CLOSE, on the stated grounds that a
///      bill whose payment method has been recorded is not a bill that has been
///      paid. Two screens, one table, one manager, two numbers. The server ships
///      the answer precisely so that cannot happen, and a client that keeps its
///      own subtraction has simply declined to accept it.
///
///   2. A TILL'S WALL CLOCK IS NOT EVIDENCE. A Windows till ten minutes fast
///      turns `now - created_at` into "this table has been waiting 10 minutes"
///      the instant the order lands, and a guest is then chased for food that
///      was ordered thirty seconds ago. So the elapsed figure arrives as a
///      NUMBER OF MILLISECONDS measured against the SERVER's clock, together
///      with the server instant it was measured at ([asOf]).
///
/// HOW A TICKING DISPLAY IS BUILT OUT OF IT, and this is the whole contract:
/// take [elapsedMs] and ADD the time this device's own MONOTONIC timer has run
/// since the response arrived. Never `DateTime.now() - startedAt`. A monotonic
/// delta measures a length of time, which every clock agrees on; a wall-clock
/// subtraction measures a difference between two clocks, which is only as good
/// as the worse of them. See `_LiveElapsed` in modules.dart, which is the only
/// widget allowed to do it.
///
/// ABSENT IS NOT ZERO. A row with no placed-at comes back with [startedAt] null,
/// `elapsed_ms: 0` and `running: false` — [hasStart] is then false and the
/// caller renders NOTHING. "0m" on a table that has been open two hours is a
/// claim; an empty space is the truth.
class ServiceClock {
  const ServiceClock({
    required this.startedAt,
    required this.endedAt,
    required this.elapsedMs,
    required this.running,
    required this.asOf,
  });

  /// The server instant service began, or null when the row carries no
  /// placed-at. See [hasStart].
  final DateTime? startedAt;

  /// The server instant the bill settled, or null while it is still in service.
  final DateTime? endedAt;

  /// The server's duration, in milliseconds, as at [asOf]. Frozen once
  /// [running] is false.
  final int elapsedMs;

  /// True while the clock is still moving — the ONLY reason to tick locally.
  /// A client that keeps ticking a stopped clock is reporting a table that is
  /// not there any more.
  final bool running;

  /// The server instant [elapsedMs] was measured at. Carried so a reader can see
  /// that the tick is a delta since a response, not a reading of a wall clock.
  final DateTime? asOf;

  /// False for the "no clock" case — nothing should be drawn.
  bool get hasStart => startedAt != null;

  /// The `service` block off an order, a table bill or a closed bill, or null
  /// when this backend does not send one (in which case the caller keeps
  /// whatever it did before — the field is additive and an older server simply
  /// omits it).
  ///
  /// A block that is present but unreadable is also null: a duration invented
  /// out of a malformed payload is worse than no duration at all.
  static ServiceClock? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final ms = raw['elapsed_ms'];
    final elapsed = ms is num
        ? ms.round()
        : ms is String
            ? (num.tryParse(ms)?.round() ?? -1)
            : -1;
    if (elapsed < 0) return null;
    final running = raw['running'];
    if (running is! bool) return null;
    return ServiceClock(
      startedAt: _instant(raw['started_at']),
      endedAt: _instant(raw['ended_at']),
      elapsedMs: elapsed,
      running: running,
      asOf: _instant(raw['as_of']),
    );
  }

  /// THIS CLOCK, RESTARTED AT A LATER INSTANT ON THE SAME CLOCK — how the
  /// table's "latest order" figure is built without a second subtraction.
  ///
  /// [laterIso] must be another timestamp from the SAME server response (the
  /// bill's `last_order_at` against its `service`, whose start is
  /// `first_order_at`). Both ends are then server instants and the shortening is
  /// a difference between two of the server's own timestamps — no device clock
  /// enters it, which is the only property that matters here.
  ///
  /// Null when there is nothing sane to return: no start, an unparseable
  /// [laterIso], or one that precedes this clock's own start.
  ServiceClock? rebasedTo(String laterIso) {
    final start = startedAt;
    final later = _instant(laterIso);
    if (start == null || later == null) return null;
    final gap = later.difference(start).inMilliseconds;
    if (gap < 0 || gap > elapsedMs) return null;
    return ServiceClock(
      startedAt: later,
      endedAt: endedAt,
      elapsedMs: elapsedMs - gap,
      running: running,
      asOf: asOf,
    );
  }

  /// THE DISPLAYED NUMBER: this reading, plus the time a MONOTONIC source has
  /// observed passing since it arrived. The one piece of arithmetic a client is
  /// allowed to do with a service clock, and it is here rather than inside a
  /// widget so it can be stated and tested as a rule.
  ///
  ///   * A STOPPED CLOCK ADDS NOTHING, however long ago the reading was taken.
  ///     A settled bill's duration is a fact about a finished service, and a
  ///     client that keeps ticking one is reporting a table that went home.
  ///   * A NEGATIVE DELTA ADDS NOTHING either. A monotonic source cannot go
  ///     backwards, so this can only be a caller passing something that is not
  ///     one — and the answer to that is to ignore it, not to print a duration
  ///     that shrinks while somebody is looking at it.
  int tickedBy(int monotonicDeltaMs) =>
      elapsedMs + (running && monotonicDeltaMs > 0 ? monotonicDeltaMs : 0);

  static DateTime? _instant(dynamic v) {
    if (v is DateTime) return v.toUtc();
    if (v is! String) return null;
    final t = v.trim();
    if (t.isEmpty) return null;
    return DateTime.tryParse(t)?.toUtc();
  }

  /// Value equality, and it is load-bearing rather than decorative: the ticking
  /// widget restarts its monotonic timer when the clock it is given CHANGES, so
  /// a poll that returns the identical reading must compare equal or every
  /// refresh would silently discard the seconds counted since the last one.
  @override
  bool operator ==(Object other) =>
      other is ServiceClock &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt &&
      other.elapsedMs == elapsedMs &&
      other.running == running &&
      other.asOf == asOf;

  @override
  int get hashCode => Object.hash(startedAt, endedAt, elapsedMs, running, asOf);

  @override
  String toString() =>
      'ServiceClock(${startedAt?.toIso8601String()} -> ${endedAt?.toIso8601String()}, '
      '${elapsedMs}ms, running: $running, as_of: ${asOf?.toIso8601String()})';
}
