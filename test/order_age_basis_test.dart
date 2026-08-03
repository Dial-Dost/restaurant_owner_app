import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/restaurant_time.dart';

/// The 24h live window is the one rule on the Orders screen that can make a
/// ticket vanish, and it is a subtraction of two timestamps taken at different
/// instants. It used to subtract two WALL CLOCKS built from different UTC
/// offsets — RestaurantTime.wallOf(created_at) carries the offset in force when
/// the order was placed, RestaurantTime.nowWall() the offset in force now — so
/// across a DST change the answer was out by an hour, right on the cut-off.
///
/// Neither the DST boundary nor the cut-off can be exercised against the real
/// clock (there is no transition within 24h of any given test run), so the age
/// is measured here with the clock passed in.
Map<String, dynamic> _order(String createdAt) => {
      'id': 'o1',
      'status': 'Paid',
      'created_at': createdAt,
    };

void main() {
  setUp(() => RestaurantTime.zoneNotifier.value = RestaurantTime.defaultZone);
  tearDown(() => RestaurantTime.zoneNotifier.value = RestaurantTime.defaultZone);

  // US DST ended at 06:00 UTC on 2025-11-02: America/New_York went from UTC-4
  // to UTC-5. An order placed 24.5 REAL hours before "now" straddles it.
  test('an age spanning a DST change is measured in real elapsed time', () {
    RestaurantTime.zoneNotifier.value = 'America/New_York';
    final now = DateTime.utc(2025, 11, 3, 5, 30);

    // Sanity: the zone really does change offset across this pair, which is the
    // whole reason the two-wall-clock subtraction was wrong.
    expect(RestaurantTime.offsetMinutesAt(DateTime.utc(2025, 11, 2, 5)), -240);
    expect(RestaurantTime.offsetMinutesAt(now), -300);

    final age = m.orderAgeHoursAt(_order('2025-11-02T05:00:00Z'), now);
    // 24.5 hours really elapsed. Read as wall clocks it came to 23.5 — under the
    // window — so a settled ticket stayed on the live page a day too long.
    expect(age, closeTo(24.5, 0.01));
  });

  test('a DST change cannot age a ticket out early either', () {
    RestaurantTime.zoneNotifier.value = 'America/New_York';
    // Spring forward: 07:00 UTC on 2025-03-09, UTC-5 -> UTC-4.
    final now = DateTime.utc(2025, 3, 9, 8, 0);
    expect(RestaurantTime.offsetMinutesAt(DateTime.utc(2025, 3, 8, 8)), -300);
    expect(RestaurantTime.offsetMinutesAt(now), -240);

    final age = m.orderAgeHoursAt(_order('2025-03-08T08:30:00Z'), now);
    // 23.5 real hours. Read as wall clocks it came to 24.5 and the ticket
    // disappeared off the page before the window was up.
    expect(age, closeTo(23.5, 0.01));
  });

  test('a zone with no DST is unaffected', () {
    // Asia/Kolkata is a flat UTC+05:30 — the basis change must not move it.
    final now = DateTime.utc(2026, 6, 1, 12, 0);
    expect(m.orderAgeHoursAt(_order('2026-05-31T12:00:00Z'), now), closeTo(24, 0.01));
    expect(m.orderAgeHoursAt(_order('2026-06-01T00:30:00Z'), now), closeTo(11.5, 0.01));
  });

  test('an offset written into the timestamp is the same instant, not a shift', () {
    final now = DateTime.utc(2026, 6, 1, 12, 0);
    // 17:30+05:30 IS 12:00Z the day before.
    expect(m.orderAgeHoursAt(_order('2026-05-31T17:30:00+05:30'), now), closeTo(24, 0.01));
  });

  // A created_at with no zone denotes no instant at all. The whole app reads
  // those as the restaurant's own wall clock (RestaurantTime.wallOf), and the
  // age has to be taken on that same basis rather than silently calling it UTC.
  test('a zone-less timestamp is aged against the restaurant wall clock', () {
    // 12:00Z is 17:30 in Kolkata, so a 15:30 wall reading is 2 hours old.
    final now = DateTime.utc(2026, 6, 1, 12, 0);
    expect(m.orderAgeHoursAt(_order('2026-06-01T15:30:00'), now), closeTo(2, 0.01));
  });

  test('an unparseable or missing created_at has no age at all', () {
    final now = DateTime.utc(2026, 6, 1, 12, 0);
    expect(m.orderAgeHoursAt(_order(''), now), isNull);
    expect(m.orderAgeHoursAt(_order('not a date'), now), isNull);
    expect(m.orderAgeHoursAt(const {'id': 'o1', 'status': 'Paid'}, now), isNull);
  });
}
