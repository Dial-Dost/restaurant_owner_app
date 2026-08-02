import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tz_offsets.dart';

/// The one place the app turns a backend timestamp into something a human reads.
///
/// WHY IT IS NOT `DateTime.toLocal()`
/// ----------------------------------
/// Every screen used to call `toLocal()`, which renders in the timezone of the
/// *machine the app is running on*. For a restaurant that is the wrong anchor:
/// the books close on the restaurant's day, not the owner's laptop's day, and an
/// owner opening the app from another state (or a till whose clock zone was
/// never set) would read a different time for the same order than the kitchen
/// tablet standing next to it. The restaurant's own timezone is a per-tenant
/// setting (`timezone` on `GET /restaurant/settings`, editable in Settings), and
/// that is what every timestamp in this app is now rendered in.
///
/// HOW THE OFFSET IS RESOLVED (stated plainly)
/// -------------------------------------------
/// Dart ships **no IANA timezone database** — `DateTime` knows UTC and the
/// device zone and nothing else — and the backend hands out the zone *id* only
/// (`GET /restaurant/timezones` returns `{timezones, current, default}`; no
/// offset, no pre-formatted strings). So this app resolves offsets itself, from
/// [tzOffsetMinutes] in `tz_offsets.dart`: a checked-in table of **UTC-offset
/// transitions** generated from Node's full-ICU database — the same database the
/// backend validates zones against — by `tool/gen_tz_offsets.mjs`.
///
/// It is a transition list, not a fixed number, so it is **correct across DST**:
/// a January instant in America/New_York renders UTC-05:00 and a July one
/// UTC-04:00, and Asia/Kolkata is +05:30 because the table says so, not because
/// anything is hardcoded. No pub dependency is added.
///
/// The table covers [tzDataFromYear]..[tzDataToYear]; outside that range the
/// first/last known offset is assumed, and for a zone the table does not carry
/// (a newer backend offering a zone this build predates) [wallOf] falls back to
/// the device zone — the settings picker refuses to select such a zone rather
/// than let the fallback happen silently.
class RestaurantTime {
  RestaurantTime._();

  /// Matches the backend's own default (`sanitizeTimezone`).
  static const String defaultZone = 'Asia/Kolkata';

  static const String _prefsKey = 'restaurant_timezone';

  /// The zone in force. Listenable so a screen showing a live clock (the
  /// settings card) and every list rebuilt after a zone change agree instantly.
  static final ValueNotifier<String> zoneNotifier = ValueNotifier<String>(defaultZone);

  static String get zone => zoneNotifier.value;

  /// False when the offset table cannot render [zone] — the app is then falling
  /// back to device time and says so instead of quietly lying.
  static bool get zoneCovered => tzZoneKnown(zone);

  /// Restore the last known zone before the first frame, so timestamps are right
  /// on a cold start instead of flipping once the network answers.
  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && saved.isNotEmpty) zoneNotifier.value = saved;
    } catch (_) {/* no prefs yet — the default stands */}
  }

  /// Adopt the zone the backend reports (or the one just saved). Ignores empty
  /// input so a failed/partial read never resets a good value.
  static void adopt(String? tz) {
    final next = (tz ?? '').trim();
    if (next.isEmpty || next == zoneNotifier.value) return;
    zoneNotifier.value = next;
    SharedPreferences.getInstance().then((p) => p.setString(_prefsKey, next)).catchError((_) => false);
  }

  // ---------------------------------------------------------------- offsets

  /// UTC offset of [tz], in minutes, at [instant]; null when the offset table
  /// does not carry that zone.
  static int? offsetMinutesOf(String tz, DateTime instant) {
    final ms = instant.toUtc().millisecondsSinceEpoch;
    return tzOffsetMinutes(tz, (ms / 1000).floor());
  }

  /// UTC offset of the restaurant zone, in minutes, at [instant].
  static int? offsetMinutesAt(DateTime instant) => offsetMinutesOf(zone, instant);

  /// `UTC+05:30` / `UTC-04:00` for [tz] at [at] (now by default), or
  /// `unsupported` when this build's table cannot render the zone.
  static String offsetLabelOf(String tz, [DateTime? at]) {
    final off = offsetMinutesOf(tz, at ?? DateTime.now());
    if (off == null) return 'unsupported';
    final sign = off < 0 ? '-' : '+';
    final abs = off.abs();
    return 'UTC$sign${_two(abs ~/ 60)}:${_two(abs % 60)}';
  }

  /// [offsetLabelOf] for the restaurant zone; `device time` when the table does
  /// not carry it, because that is then what the app is really showing.
  /// Printed next to accounting-grade timestamps so an exported figure is
  /// unambiguous.
  static String offsetLabel([DateTime? at]) {
    final off = offsetMinutesAt(at ?? DateTime.now());
    return off == null ? 'device time' : offsetLabelOf(zone, at);
  }

  /// `Asia/Kolkata · UTC+05:30` — the zone as the settings screen states it.
  static String zoneLabel([DateTime? at]) => '$zone · ${offsetLabel(at)}';

  /// Wall clock right now in an arbitrary [tz] — the settings picker previews
  /// every zone's current local time. Null when the zone is not in the table.
  static DateTime? nowIn(String tz) {
    final utc = DateTime.now().toUtc();
    final off = offsetMinutesOf(tz, utc);
    return off == null ? null : utc.add(Duration(minutes: off));
  }

  /// `14:05` right now in [tz], or an empty string when unsupported.
  static String clockIn(String tz) {
    final d = nowIn(tz);
    return d == null ? '' : '${_two(d.hour)}:${_two(d.minute)}';
  }

  // ------------------------------------------------------------- conversion

  static final RegExp _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final RegExp _hasZone = RegExp(r'(?:[Zz]|[+-]\d{2}:?\d{2})$');

  /// The restaurant-zone wall clock for a backend timestamp, or null when the
  /// string is empty/unparseable.
  ///
  /// The returned [DateTime] is a *field carrier*: its `year`…`minute` read as
  /// the restaurant's wall clock. It is flagged UTC so nothing re-shifts it —
  /// never compare it against `DateTime.now()` or subtract it from another
  /// instant. Use the raw string for that.
  ///
  /// Three input shapes, matching what the backend actually emits:
  ///  * `2026-07-28` — a calendar date (an expense's `spent_on`, a report day).
  ///    Already a restaurant-side date; converting it would slide it a day.
  ///  * `2026-07-28T14:36:07.942Z` / `…+05:30` — an absolute instant. Converted.
  ///  * `2026-07-28T20:00` — a bare wall-clock string, which the backend writes
  ///    and reads back as restaurant-local (`parseWallClockInZone`). Its fields
  ///    are the answer; parsing it as an instant would re-anchor it to the
  ///    device zone, which is the bug this class exists to kill.
  static DateTime? wallOf(String iso) {
    final s = iso.trim();
    if (s.isEmpty) return null;
    if (_dateOnly.hasMatch(s)) {
      return DateTime.tryParse('${s}T00:00:00Z');
    }
    if (!_hasZone.hasMatch(s)) return DateTime.tryParse('${s}Z');
    final instant = DateTime.tryParse(s);
    if (instant == null) return null;
    final utc = instant.toUtc();
    final off = offsetMinutesAt(utc);
    // Unknown zone: the device zone is the only honest fallback left.
    if (off == null) return instant.toLocal();
    return utc.add(Duration(minutes: off));
  }

  /// Now, as the restaurant's wall clock. Use this — not `DateTime.now()` —
  /// wherever "today" decides something (report ranges, export filenames, the
  /// payroll month), so a device in another zone cannot shift the books a day.
  static DateTime nowWall() {
    final utc = DateTime.now().toUtc();
    final off = offsetMinutesAt(utc);
    if (off == null) return DateTime.now();
    return utc.add(Duration(minutes: off));
  }

  // ------------------------------------------------------------- formatting

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `Jun 26, 14:05` — the app's default timestamp.
  static String short(String iso) {
    final d = wallOf(iso);
    if (d == null) return iso;
    return '${_months[d.month - 1]} ${d.day}, ${_two(d.hour)}:${_two(d.minute)}';
  }

  /// `26/06/26 · 14:05` — reservations and other dense rows.
  static String dmy(String iso) {
    final d = wallOf(iso);
    if (d == null) return iso;
    return '${_two(d.day)}/${_two(d.month)}/${_two(d.year % 100)} · ${_two(d.hour)}:${_two(d.minute)}';
  }

  /// `Jun 26` — a day with no time of day.
  static String day(String iso) {
    final d = wallOf(iso);
    if (d == null) return iso;
    return '${_months[d.month - 1]} ${d.day}';
  }

  /// `14:05` — time of day only, for rows that already state the date.
  static String clock(String iso) {
    final d = wallOf(iso);
    if (d == null) return iso;
    return '${_two(d.hour)}:${_two(d.minute)}';
  }

  /// `26 Jun 2026, 14:05:07 UTC+05:30` — the unambiguous form for anything that
  /// leaves the screen (printed tickets, exported files, audit detail).
  static String stamp(String iso) {
    final d = wallOf(iso);
    if (d == null) return iso;
    final instant = DateTime.tryParse(iso.trim());
    return '${d.day} ${_months[d.month - 1]} ${d.year}, '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)} ${offsetLabel(instant)}';
  }

  /// [stamp] for the current moment.
  static String stampNow() {
    final d = nowWall();
    return '${d.day} ${_months[d.month - 1]} ${d.year}, '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)} ${offsetLabel()}';
  }

  /// `14:05:07` right now — the printer agent's log gutter.
  static String clockNow() {
    final d = nowWall();
    return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  /// Today in the restaurant zone as `YYYY-MM-DD` (report ranges, filenames).
  static String todayIso() => isoDate(nowWall());

  /// This month in the restaurant zone as `YYYY-MM` (payroll).
  static String thisMonthIso() {
    final d = nowWall();
    return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}';
  }

  /// `YYYY-MM-DD` for a wall-clock [d] (pair with [nowWall]).
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
}
