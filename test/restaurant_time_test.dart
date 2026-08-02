import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/services/tz_offsets.dart';

/// The formatter every screen renders timestamps through. The point of these
/// tests is the DST claim: the offset is resolved *per instant* from the
/// checked-in transition table, so the same zone renders differently in January
/// and July. Nothing here may depend on the machine's own timezone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RestaurantTime.adopt(RestaurantTime.defaultZone);
  });

  test('renders an instant in the restaurant zone, not the device zone', () {
    RestaurantTime.adopt('Asia/Kolkata');
    // 14:36 UTC + 05:30
    expect(RestaurantTime.short('2026-07-28T14:36:07.942Z'), 'Jul 28, 20:06');
    expect(RestaurantTime.clock('2026-07-28T14:36:07.942Z'), '20:06');
    expect(RestaurantTime.offsetLabel(), 'UTC+05:30');

    RestaurantTime.adopt('UTC');
    expect(RestaurantTime.short('2026-07-28T14:36:07.942Z'), 'Jul 28, 14:36');
    expect(RestaurantTime.offsetLabel(), 'UTC+00:00');
  });

  test('the same zone changes offset across a DST boundary', () {
    RestaurantTime.adopt('America/New_York');
    // EST (UTC-5) in January, EDT (UTC-4) in July — a fixed offset would put one
    // of these an hour out, which is the failure this whole table exists to stop.
    expect(RestaurantTime.short('2026-01-15T12:00:00Z'), 'Jan 15, 07:00');
    expect(RestaurantTime.short('2026-07-15T12:00:00Z'), 'Jul 15, 08:00');
    expect(RestaurantTime.offsetLabelOf('America/New_York', DateTime.utc(2026, 1, 15)), 'UTC-05:00');
    expect(RestaurantTime.offsetLabelOf('America/New_York', DateTime.utc(2026, 7, 15)), 'UTC-04:00');
  });

  test('half-hour and 30-minute-DST zones survive the round trip', () {
    // Lord Howe shifts by 30 minutes, not 60 — the classic off-by-half-hour trap.
    expect(RestaurantTime.offsetLabelOf('Australia/Lord_Howe', DateTime.utc(2026, 1, 15)), 'UTC+11:00');
    expect(RestaurantTime.offsetLabelOf('Australia/Lord_Howe', DateTime.utc(2026, 7, 15)), 'UTC+10:30');
    expect(RestaurantTime.offsetLabelOf('Asia/Kathmandu', DateTime.utc(2026, 7, 15)), 'UTC+05:45');
  });

  test('a bare date is a calendar date and never slides a day', () {
    for (final zone in ['Pacific/Kiritimati', 'Asia/Kolkata', 'Pacific/Midway']) {
      RestaurantTime.adopt(zone);
      expect(RestaurantTime.day('2026-07-28'), 'Jul 28', reason: zone);
      expect(RestaurantTime.dmy('2026-07-28'), '28/07/26 · 00:00', reason: zone);
    }
  });

  test('a bare wall-clock string is already restaurant-local', () {
    // What the backend stores for a booking slot: no Z, no offset. Re-anchoring
    // it to an instant would move a 20:00 reservation by the zone difference.
    for (final zone in ['Asia/Kolkata', 'America/New_York', 'UTC']) {
      RestaurantTime.adopt(zone);
      expect(RestaurantTime.short('2026-07-28T20:00'), 'Jul 28, 20:00', reason: zone);
    }
  });

  test('stamp carries the offset so an exported figure is unambiguous', () {
    RestaurantTime.adopt('Asia/Kolkata');
    expect(RestaurantTime.stamp('2026-07-28T14:36:07.942Z'), '28 Jul 2026, 20:06:07 UTC+05:30');
  });

  test('empty and junk input degrade instead of throwing', () {
    RestaurantTime.adopt('Asia/Kolkata');
    expect(RestaurantTime.short(''), '');
    expect(RestaurantTime.short('   '), '   ');
    expect(RestaurantTime.short('not a date'), 'not a date');
    expect(RestaurantTime.wallOf(''), isNull);
  });

  test('an uncovered zone is reported, not silently faked', () {
    RestaurantTime.adopt('Mars/Olympus_Mons');
    expect(RestaurantTime.zoneCovered, isFalse);
    expect(RestaurantTime.offsetLabel(), 'device time');
    expect(RestaurantTime.nowIn('Mars/Olympus_Mons'), isNull);
    expect(tzZoneKnown('Mars/Olympus_Mons'), isFalse);
  });

  test('the bundled table covers the zones the picker offers', () {
    expect(tzZoneCount, greaterThan(400));
    expect(tzZoneNames, contains('Asia/Kolkata'));
    expect(tzZoneNames, contains('UTC'));
    // Canonical-alias trap the backend documents: both ids must resolve.
    expect(tzZoneKnown('Asia/Calcutta'), isTrue);
    expect(RestaurantTime.offsetLabelOf('Asia/Calcutta'), 'UTC+05:30');
  });
}
