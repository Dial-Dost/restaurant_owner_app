/// The reporting window, as one value every reporting screen in the app agrees
/// on.
///
/// WHY THIS EXISTS
/// ---------------
/// Every screen that shows money used to carry its own idea of "the period":
/// Accounting had a Day/Week/Month/Quarter/Half-year/Year tab row, Analytics had
/// `?days=30` hardcoded into eight separate requests, Cash had no filter at all.
/// So the same figure could be cut three different ways in three modules, none
/// of them said which, and none of them could express "1-15 August" — the
/// question this whole feature exists to answer.
///
/// This file is the one definition of a window; [DateRangeChip] is the one
/// control that edits it, and [DateRange.label] is the one sentence that states
/// it. It mirrors the web dashboard's `src/lib/date-range.ts` deliberately:
/// same presets, same inclusive-both-ends rule, same label grammar, same wire
/// parameters — so an owner reading "1-15 Aug" on the desktop app and on the
/// dashboard is looking at the same rows.
///
/// PURE: no Flutter, no HTTP. The only outside call is [RestaurantTime], which
/// is what makes "today" the RESTAURANT's today rather than the laptop's — a
/// device in another state must not shift the books a day. `now` is injectable
/// so the unit tests pin a date instead of racing midnight.
///
/// DAY KEYS, NOT DateTimes
/// -----------------------
/// A window is a pair of INCLUSIVE `YYYY-MM-DD` calendar days. Never a DateTime:
/// a DateTime is a point on a timeline and would have to be re-anchored to a
/// zone at every use, which is precisely the bug that files an IST restaurant's
/// 01:00 covers under yesterday.
library;

import 'restaurant_time.dart';

/// The windows people actually ask for, plus the escape hatch.
enum RangePreset { today, yesterday, last7, last30, thisMonth, lastMonth, custom }

const List<RangePreset> kRangePresets = [
  RangePreset.today,
  RangePreset.yesterday,
  RangePreset.last7,
  RangePreset.last30,
  RangePreset.thisMonth,
  RangePreset.lastMonth,
];

String presetLabel(RangePreset p) {
  switch (p) {
    case RangePreset.today:
      return 'Today';
    case RangePreset.yesterday:
      return 'Yesterday';
    case RangePreset.last7:
      return 'Last 7 days';
    case RangePreset.last30:
      return 'Last 30 days';
    case RangePreset.thisMonth:
      return 'This month';
    case RangePreset.lastMonth:
      return 'Last month';
    case RangePreset.custom:
      return 'Custom range';
  }
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

final RegExp _dayKey = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

bool isDayKey(String? v) => v != null && _dayKey.hasMatch(v);

String _two(int n) => n.toString().padLeft(2, '0');

/// A day key from calendar parts. Built through `DateTime.utc` so an
/// out-of-range day (month 13, day 0, day 32) normalises the way a calendar
/// does instead of producing a nonsense string.
String _keyOf(int y, int m, int d) {
  final utc = DateTime.utc(y, m, d);
  return '${utc.year.toString().padLeft(4, '0')}-${_two(utc.month)}-${_two(utc.day)}';
}

List<int> _parts(String key) {
  final m = _dayKey.firstMatch(key);
  if (m == null) return const [0, 0, 0];
  return [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
}

/// Add whole days to a day key. UTC-anchored because a key already NAMES a day;
/// no zone is involved in moving to the next one, and doing it with a local
/// DateTime would let a DST night turn "+1 day" into the same day again.
String addDaysToKey(String key, int days) {
  final p = _parts(key);
  if (p[0] == 0) return key;
  return _keyOf(p[0], p[1], p[2] + days);
}

/// First day of the month `key` falls in.
String startOfMonthKey(String key) {
  final p = _parts(key);
  return p[0] == 0 ? key : _keyOf(p[0], p[1], 1);
}

/// Last day of the month `key` falls in — day 0 of the next month.
String endOfMonthKey(String key) {
  final p = _parts(key);
  return p[0] == 0 ? key : _keyOf(p[0], p[1] + 1, 0);
}

/// INCLUSIVE day count: 1-15 Aug is 15 days, not 14. This is how an owner
/// counts, and it is the number the backend's rolling `days` parameter has to
/// receive for a custom span to cover the same ground.
int daysBetweenKeys(String from, String to) {
  final a = _parts(from), b = _parts(to);
  if (a[0] == 0 || b[0] == 0) return 0;
  final diff = DateTime.utc(b[0], b[1], b[2]).difference(DateTime.utc(a[0], a[1], a[2]));
  return diff.inDays + 1;
}

/// Today on the RESTAURANT's calendar. Not `DateTime.now()`: a till in another
/// zone would otherwise pull a window shifted by a day, which is exactly the
/// silent mismatch that breaks a tally.
String todayKey({DateTime? now}) => RestaurantTime.isoDate(now ?? RestaurantTime.nowWall());

/// Whole calendar months a range touches, inclusive at both ends.
///
/// Some series are MONTH-granular (the APC trend, the History table): they take
/// a month count, not a day range, so the window is converted rather than
/// ignored. Floored at 3 because a single point is not a trend, and capped at
/// 24, which is the trend endpoint's own ceiling.
int monthsSpanned(DateRange r, {int min = 3, int max = 24}) {
  final f = _parts(r.from), t = _parts(r.to);
  if (f[0] == 0 || t[0] == 0) return 12;
  final n = (t[0] - f[0]) * 12 + (t[1] - f[1]) + 1;
  return n < min ? min : (n > max ? max : n);
}

/// One reporting window: two inclusive calendar days plus the intent behind them.
class DateRange {
  const DateRange({required this.from, required this.to, required this.preset});

  /// Inclusive first day, `YYYY-MM-DD` in the restaurant's zone.
  final String from;

  /// Inclusive last day.
  final String to;

  /// Which preset produced this, or [RangePreset.custom]. Carried WITH the dates
  /// rather than re-derived, because "Last 7 days" and "22-28 Aug" are the same
  /// seven days today and different windows tomorrow — only the stored intent
  /// can tell a reopened screen which of the two the owner meant.
  final RangePreset preset;

  /// The concrete days a preset means RIGHT NOW.
  factory DateRange.fromPreset(RangePreset preset, {DateTime? now}) {
    final today = todayKey(now: now);
    switch (preset) {
      case RangePreset.today:
        return DateRange(from: today, to: today, preset: preset);
      case RangePreset.yesterday:
        final y = addDaysToKey(today, -1);
        return DateRange(from: y, to: y, preset: preset);
      case RangePreset.last7:
        // INCLUSIVE of today: seven days on the calendar, which is what "last 7
        // days" means to the person asking. -7 would be an eight-day window.
        return DateRange(from: addDaysToKey(today, -6), to: today, preset: preset);
      case RangePreset.last30:
        return DateRange(from: addDaysToKey(today, -29), to: today, preset: preset);
      case RangePreset.thisMonth:
        // Ends TODAY, not at month end: month-to-date is the only honest figure
        // mid-month, and a window running into the future renders as zeros that
        // read like missing data.
        return DateRange(from: startOfMonthKey(today), to: today, preset: preset);
      case RangePreset.lastMonth:
        final prev = addDaysToKey(startOfMonthKey(today), -1);
        return DateRange(from: startOfMonthKey(prev), to: endOfMonthKey(prev), preset: preset);
      case RangePreset.custom:
        return DateRange(from: addDaysToKey(today, -29), to: today, preset: RangePreset.custom);
    }
  }

  /// What a screen opens on before anyone has chosen anything.
  factory DateRange.initial({DateTime? now}) => DateRange.fromPreset(RangePreset.last30, now: now);

  /// Coerce any two keys into a legal window: swap a reversed pair, clamp a
  /// future end back to today, fall back to the default when either is junk.
  ///
  /// Swapping matters because picking an end date before the start is a normal
  /// slip on a calendar; returning an empty report for it would look like the
  /// restaurant had no trade that fortnight.
  factory DateRange.normalized(String? from, String? to,
      {RangePreset preset = RangePreset.custom, DateTime? now}) {
    final today = todayKey(now: now);
    var f = isDayKey(from) ? from! : '';
    var t = isDayKey(to) ? to! : '';
    if (f.isEmpty && t.isEmpty) return DateRange.initial(now: now);
    if (t.isEmpty) t = f;
    if (f.isEmpty) f = t;
    if (f.compareTo(t) > 0) {
      final swap = f;
      f = t;
      t = swap;
    }
    // There is no trade after today; a future window comes back as zeros, which
    // an owner reads as data loss rather than as "not yet".
    if (t.compareTo(today) > 0) t = today;
    if (f.compareTo(t) > 0) f = t;
    return DateRange(from: f, to: t, preset: preset);
  }

  int get days {
    final n = daysBetweenKeys(from, to);
    return n < 1 ? 1 : n;
  }

  /// The chip: `1-15 Aug`, `15 Aug`, `28 Jul - 3 Sep`, `28 Jul 2025 - 3 Jan 2026`.
  ///
  /// Always CONCRETE dates, never "last 30 days". Every screen showing money
  /// renders this somewhere permanent, so a filtered figure can never be
  /// mistaken for the all-time number — which is the whole reason the control
  /// exists.
  ///
  /// The year appears only when it is not the current one, or when the two ends
  /// straddle a year boundary: printing it on every chip costs the width that
  /// makes `1-15 Aug` fit beside a heading on a 320dp phone, and tells the owner
  /// nothing they do not already know.
  String label({DateTime? now}) {
    if (!isDayKey(from) || !isDayKey(to)) return '--';
    final f = _parts(from), t = _parts(to);
    final thisYear = _parts(todayKey(now: now))[0];
    final showYear = f[0] != thisYear || t[0] != thisYear;
    String mon(List<int> p) => _months[(p[1] - 1).clamp(0, 11)];

    if (from == to) {
      return '${f[2]} ${mon(f)}${showYear ? ' ${f[0]}' : ''}';
    }
    if (f[0] == t[0]) {
      if (f[1] == t[1]) {
        // Same month: name it once. The form the owner asked for.
        return '${f[2]}–${t[2]} ${mon(t)}${showYear ? ' ${t[0]}' : ''}';
      }
      return '${f[2]} ${mon(f)} – ${t[2]} ${mon(t)}${showYear ? ' ${t[0]}' : ''}';
    }
    return '${f[2]} ${mon(f)} ${f[0]} – ${t[2]} ${mon(t)} ${t[0]}';
  }

  /// The unambiguous form, for tooltips and anything that leaves the screen:
  /// names the zone, because "1st to 15th" is meaningless without knowing whose
  /// midnight closed each day.
  String get tooltip =>
      '${presetLabel(preset)}: $from to $to ($days day${days == 1 ? '' : 's'}), '
      "counted on the restaurant's calendar in ${RestaurantTime.zone}";

  /// The query parameters every reporting endpoint is called with.
  ///
  /// `days` rides along beside `from`/`to` on purpose. /reports/* has always
  /// taken `from`/`to`; the /analytics/* routes were built around a rolling
  /// `days` count ending today, which cannot express "1-15 August" at all.
  /// Sending all three means one control drives both families: a route that
  /// understands the range uses it, and one that only knows `days` still
  /// receives a window of the RIGHT LENGTH instead of silently answering for its
  /// own 30-day default. `days` is the inclusive span of the same range, so the
  /// two readings can never differ in length.
  String get query =>
      'from=${Uri.encodeQueryComponent(from)}&to=${Uri.encodeQueryComponent(to)}&days=$days';

  /// Just the calendar pair, for the /reports/* routes that take no `days`.
  String get reportQuery =>
      'from=${Uri.encodeQueryComponent(from)}&to=${Uri.encodeQueryComponent(to)}';

  /// A filename-safe stamp, so an exported file self-identifies once it is
  /// sitting in a Downloads folder next to another export of a different window.
  String get fileStamp => '$from-to-$to';

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.from == from && other.to == to && other.preset == preset;

  @override
  int get hashCode => Object.hash(from, to, preset);

  @override
  String toString() => 'DateRange($from..$to, ${preset.name})';
}

/// Per-screen window memory, for the life of the app session.
///
/// In memory, not SharedPreferences, and that is the point: the window an owner
/// reasoned about this afternoon should survive a hop to Menu and back, but
/// tomorrow morning's first look should start from a fresh, honest default
/// rather than a stale fortnight they have forgotten choosing.
///
/// Keyed per SCREEN because Accounting and Analytics are genuinely separate
/// questions; forcing them to share one window would make each module silently
/// move the other.
abstract final class DateRangeMemory {
  static final Map<String, DateRange> _byScreen = {};

  /// This screen's window, or [fallback] (default: last 30 days) on first visit.
  static DateRange of(String screen, {DateRange? fallback, DateTime? now}) {
    final saved = _byScreen[screen];
    if (saved == null) return fallback ?? DateRange.initial(now: now);
    // A stored PRESET is re-resolved rather than replayed: coming back to a
    // screen after midnight must move "Today" to the new today, or it would show
    // yesterday's takings under a label that says Today.
    if (saved.preset != RangePreset.custom) {
      return DateRange.fromPreset(saved.preset, now: now);
    }
    return saved;
  }

  static void remember(String screen, DateRange range) => _byScreen[screen] = range;

  /// True once this screen has been given a window in this session. Screens
  /// whose natural opening window is not the 30-day default need this: without
  /// it, [of]'s fallback could not tell "nothing chosen" from "chose the
  /// default", and would overrule a real choice.
  static bool has(String screen) => _byScreen.containsKey(screen);

  /// Test seam — a suite must not inherit the previous test's windows.
  static void reset() => _byScreen.clear();
}
