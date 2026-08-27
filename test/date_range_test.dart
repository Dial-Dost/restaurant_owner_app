import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';

/// The reporting window contract, matched line for line against the web
/// dashboard's `src/lib/__tests__/date-range.test.ts`. If these two suites ever
/// disagree, an owner reading "1–15 Aug" on the desktop app and on the dashboard
/// is looking at different rows, and nothing on either screen would say so.
///
/// Four things are pinned because getting any of them wrong is invisible until
/// someone is looking at a wrong number and does not know it:
///
///  1. PRESETS ARE COUNTED ON THE RESTAURANT'S CALENDAR, not the device's. The
///     clock is pinned to an instant that is a DIFFERENT DAY in IST and in New
///     York, so a preset reading the wrong zone fails here instead of shipping.
///  2. BOTH ENDS ARE INCLUSIVE. "Last 7 days" is seven days including today, and
///     1–15 Aug is fifteen. An off-by-one drops a day's takings from every export.
///  3. THE LABEL SAYS WHAT WAS ACTUALLY CUT — the only thing standing between a
///     filtered figure and being read as the all-time number.
///  4. THE EXPORT CARRIES THE SAME RANGE AS THE SCREEN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2026-08-27T20:30:00Z: 02:00 on the 28th in IST, 16:30 on the 27th in New
  // York. `nowWall()` converts through the restaurant zone, so passing the
  // converted wall clock in is what the app itself does.
  final utcNow = DateTime.utc(2026, 8, 27, 20, 30);
  DateTime wallIn(String zone) {
    RestaurantTime.adopt(zone);
    final off = RestaurantTime.offsetMinutesOf(zone, utcNow)!;
    return utcNow.add(Duration(minutes: off));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RestaurantTime.adopt(RestaurantTime.defaultZone);
    DateRangeMemory.reset();
  });

  group('day-key arithmetic', () {
    test('crosses month and year boundaries', () {
      expect(addDaysToKey('2026-08-31', 1), '2026-09-01');
      expect(addDaysToKey('2026-01-01', -1), '2025-12-31');
      expect(addDaysToKey('2026-03-01', -1), '2026-02-28');
    });

    test('knows how long a month is, leap years included', () {
      expect(startOfMonthKey('2026-08-27'), '2026-08-01');
      expect(endOfMonthKey('2026-08-27'), '2026-08-31');
      expect(endOfMonthKey('2026-02-10'), '2026-02-28');
      expect(endOfMonthKey('2024-02-10'), '2024-02-29');
    });

    test('counts both ends: 1-15 Aug is fifteen days, not fourteen', () {
      expect(daysBetweenKeys('2026-08-01', '2026-08-15'), 15);
      expect(daysBetweenKeys('2026-08-15', '2026-08-15'), 1);
      expect(daysBetweenKeys('2026-01-01', '2026-12-31'), 365);
    });
  });

  group('presets map to the right window', () {
    test('counts today on the RESTAURANT calendar, not the device clock', () {
      final ist = DateRange.fromPreset(RangePreset.today, now: wallIn('Asia/Kolkata'));
      expect(ist.from, '2026-08-28');
      expect(ist.to, '2026-08-28');

      final ny = DateRange.fromPreset(RangePreset.today, now: wallIn('America/New_York'));
      expect(ny.from, '2026-08-27');
      expect(ny.to, '2026-08-27');
    });

    test('yesterday is one day, the one before the restaurant today', () {
      final r = DateRange.fromPreset(RangePreset.yesterday, now: wallIn('Asia/Kolkata'));
      expect(r.from, '2026-08-27');
      expect(r.to, '2026-08-27');
      expect(r.days, 1);
    });

    test('last 7 / last 30 include today and are exactly that many days', () {
      final now = wallIn('Asia/Kolkata');
      final seven = DateRange.fromPreset(RangePreset.last7, now: now);
      expect(seven.from, '2026-08-22');
      expect(seven.to, '2026-08-28');
      expect(seven.days, 7);

      final thirty = DateRange.fromPreset(RangePreset.last30, now: now);
      expect(thirty.from, '2026-07-30');
      expect(thirty.to, '2026-08-28');
      expect(thirty.days, 30);
    });

    test('this month runs to TODAY, never into the future', () {
      // A window ending 31 Aug would come back as zeros for the 29th-31st, which
      // reads to an owner as data loss rather than as "not yet".
      final r = DateRange.fromPreset(RangePreset.thisMonth, now: wallIn('Asia/Kolkata'));
      expect(r.from, '2026-08-01');
      expect(r.to, '2026-08-28');
    });

    test('last month is the whole previous calendar month', () {
      final r = DateRange.fromPreset(RangePreset.lastMonth, now: wallIn('Asia/Kolkata'));
      expect(r.from, '2026-07-01');
      expect(r.to, '2026-07-31');
      expect(r.days, 31);
    });

    test('last month crosses the year boundary correctly', () {
      final jan = DateTime(2026, 1, 10, 11, 30);
      expect(DateRange.fromPreset(RangePreset.lastMonth, now: jan).from, '2025-12-01');
      expect(DateRange.fromPreset(RangePreset.lastMonth, now: jan).to, '2025-12-31');
      expect(DateRange.fromPreset(RangePreset.thisMonth, now: jan).from, '2026-01-01');
      expect(DateRange.fromPreset(RangePreset.thisMonth, now: jan).to, '2026-01-10');
    });

    test('the default window is the last 30 days', () {
      final now = wallIn('Asia/Kolkata');
      expect(DateRange.initial(now: now), DateRange.fromPreset(RangePreset.last30, now: now));
    });
  });

  group('normalized', () {
    final now = DateTime(2026, 8, 28, 2, 0);

    test('swaps a reversed pair instead of returning nothing', () {
      final r = DateRange.normalized('2026-08-15', '2026-08-01', now: now);
      expect(r.from, '2026-08-01');
      expect(r.to, '2026-08-15');
    });

    test('clamps a future end back to the restaurant today', () {
      final r = DateRange.normalized('2026-08-01', '2027-01-01', now: now);
      expect(r.to, '2026-08-28');
    });

    test('treats one supplied end as a single day', () {
      final r = DateRange.normalized('2026-08-05', null, now: now);
      expect(r.from, '2026-08-05');
      expect(r.to, '2026-08-05');
      expect(r.days, 1);
    });

    test('falls back to the default when both ends are junk', () {
      expect(DateRange.normalized('yesterday', '', now: now), DateRange.initial(now: now));
      expect(DateRange.normalized('15/08/2026', null, now: now), DateRange.initial(now: now));
    });
  });

  group('the label renders the selected range', () {
    final now = DateTime(2026, 8, 28, 2, 0);
    DateRange r(String f, String t) => DateRange(from: f, to: t, preset: RangePreset.custom);

    test('collapses a same-month span to the form the owner asked for', () {
      expect(r('2026-08-01', '2026-08-15').label(now: now), '1–15 Aug');
    });

    test('names one day once', () {
      expect(r('2026-08-15', '2026-08-15').label(now: now), '15 Aug');
    });

    test('names both months when the span crosses one', () {
      expect(r('2026-07-28', '2026-09-03').label(now: now), '28 Jul – 3 Sep');
    });

    test('adds the year only when it is not the current one', () {
      expect(r('2025-08-01', '2025-08-15').label(now: now), '1–15 Aug 2025');
      expect(r('2025-12-28', '2026-01-03').label(now: now), '28 Dec 2025 – 3 Jan 2026');
    });

    test('never renders a half-built range as a number', () {
      expect(r('', '2026-08-15').label(now: now), '--');
    });

    test('the tooltip names the preset, the span and the zone', () {
      RestaurantTime.adopt('Asia/Kolkata');
      final tip = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom).tooltip;
      expect(tip, contains('2026-08-01 to 2026-08-15'));
      expect(tip, contains('15 days'));
      expect(tip, contains('Asia/Kolkata'));
    });

    test('says "1 day" rather than "1 days"', () {
      expect(DateRange(from: '2026-08-15', to: '2026-08-15', preset: RangePreset.today).tooltip,
          contains('(1 day)'));
    });
  });

  group('the wire contract', () {
    test('a custom span reaches the API as from/to, with a matching days', () {
      const custom = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);
      expect(custom.query, 'from=2026-08-01&to=2026-08-15&days=15');
    });

    test('a preset reaches the API as concrete dates too, so both route families agree', () {
      // /reports/* reads from/to; the older /analytics/* routes read days. One
      // control has to satisfy both or the two halves of a module disagree.
      final seven = DateRange.fromPreset(RangePreset.last7, now: wallIn('Asia/Kolkata'));
      expect(seven.query, 'from=2026-08-22&to=2026-08-28&days=7');
    });

    test('the report routes get the calendar pair with no days', () {
      const custom = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);
      expect(custom.reportQuery, 'from=2026-08-01&to=2026-08-15');
    });

    test('never emits days=0, which a backend reads as "use your default"', () {
      const oneDay = DateRange(from: '2026-08-15', to: '2026-08-15', preset: RangePreset.today);
      expect(oneDay.days, 1);
      expect(oneDay.query, endsWith('days=1'));
    });

    test('an export filename carries the SAME range the screen is showing', () {
      const custom = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);
      expect(custom.fileStamp, '2026-08-01-to-2026-08-15');
      expect('tally-${custom.fileStamp}.xml', 'tally-2026-08-01-to-2026-08-15.xml');
    });
  });

  group('per-screen session memory', () {
    test('keeps two screens apart, so Accounting cannot move Analytics', () {
      final now = wallIn('Asia/Kolkata');
      const chosen = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);
      DateRangeMemory.remember('accounting', chosen);

      expect(DateRangeMemory.of('accounting', now: now), chosen);
      expect(DateRangeMemory.of('analytics', now: now), DateRange.initial(now: now));
    });

    test('RE-RESOLVES a stored preset rather than replaying its old dates', () {
      // Chosen yesterday, revisited today: "Today" has to mean today, or the
      // module shows yesterday's takings under a label that says Today.
      DateRangeMemory.remember(
        'analytics',
        const DateRange(from: '2026-08-20', to: '2026-08-20', preset: RangePreset.today),
      );
      final again = DateRangeMemory.of('analytics', now: wallIn('Asia/Kolkata'));
      expect(again.from, '2026-08-28');
      expect(again.to, '2026-08-28');
    });

    test('replays a CUSTOM range verbatim — it named days, not a rule', () {
      const chosen = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);
      DateRangeMemory.remember('accounting', chosen);
      expect(DateRangeMemory.of('accounting', now: wallIn('Asia/Kolkata')), chosen);
    });

    test('a screen with its own opening window keeps a real choice', () {
      final now = wallIn('Asia/Kolkata');
      final wide = DateRange.normalized('2025-09-01', '2026-08-28', now: now);
      // First visit: the screen's own default.
      expect(DateRangeMemory.of('history', fallback: wide, now: now), wide);
      // After a real choice, the choice wins — `has` is what tells them apart.
      DateRangeMemory.remember('history', DateRange.fromPreset(RangePreset.last30, now: now));
      expect(DateRangeMemory.has('history'), isTrue);
      expect(DateRangeMemory.of('history', fallback: wide, now: now),
          DateRange.fromPreset(RangePreset.last30, now: now));
    });
  });
}
