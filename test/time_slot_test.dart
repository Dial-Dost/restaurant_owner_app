import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/services/report_export.dart';
import 'package:restaurant_owner_app/services/time_slot.dart';

/// SESSION-WISE REPORTS — the pure half: what the app sends and says about a
/// time slot.
///
/// The server slices; nothing here can prove its arithmetic. What is pinned is
/// every way THIS client could tell an owner something false about which hours
/// a figure covers — a pick that never reaches the request, an all-day URL that
/// changed, a list-shaped clamp read as a boolean, a filename or preamble naming
/// a slot the server did not apply — and the WORDS, because the web dashboard
/// prints the same ones (src/lib/__tests__/report-time-slots.test.ts pins its
/// copy of each). If a string here changes, that file changes with it.

const _defaults = [
  TimeSlotPreset(id: 'lunch', label: 'Lunch', start: '12:00', end: '17:00'),
  TimeSlotPreset(id: 'dinner', label: 'Dinner', start: '18:00', end: '24:00'),
];

const _lunch = AppliedTimeSlot(
    id: 'lunch', label: 'Lunch', start: '12:00', end: '17:00', crossesMidnight: false, source: 'preset');
const _late = AppliedTimeSlot(
    id: null, label: 'Custom', start: '22:00', end: '02:00', crossesMidnight: true, source: 'custom');

void main() {
  group('clock text', () {
    test('reads HH:mm, and 24:00 only as an END', () {
      expect(parseClock('12:00'), 720);
      expect(parseClock('9:30'), 570);
      expect(parseClock('00:00'), 0);
      expect(parseClock('23:59'), 1439);
      expect(parseClock('24:00'), isNull);
      expect(parseClock('24:00', allow24: true), 1440);
      for (final junk in ['25:00', '12:60', '1200', '', 'noon', '24:01', ' 12:3 ']) {
        expect(parseClock(junk, allow24: true), isNull, reason: junk);
      }
      // An END of 00:00 is midnight, as the server reads it.
      expect(parseEndClock('00:00'), 1440);
      expect(parseEndClock('02:00'), 120);
      expect(formatClock(570), '09:30');
      expect(formatClock(1440), '24:00');
    });

    test('validates a custom pair in the words the form shows', () {
      expect(validateCustomSlot('12:00', '17:00'), isNull);
      expect(validateCustomSlot('22:00', '02:00'), isNull);
      expect(validateCustomSlot('18:00', '24:00'), isNull);
      expect(validateCustomSlot('24:00', '02:00'), 'Start time must be a 24-hour time between 00:00 and 23:59.');
      expect(validateCustomSlot('12:00', '25:00'), 'End time must be a 24-hour time between 00:00 and 24:00.');
      expect(validateCustomSlot('13:00', '13:00'), 'Start and end are the same time — choose two different times.');
      expect(crossesMidnight('22:00', '02:00'), isTrue);
      expect(crossesMidnight('18:00', '24:00'), isFalse);
      expect(crossesMidnight('18:00', '00:00'), isFalse);
    });

    test('00:00–24:00 is exactly all day, and junk is all day rather than a clamp', () {
      expect(TimeSlotSelection.custom('00:00', '24:00'), TimeSlotSelection.allDay);
      final c = TimeSlotSelection.custom('9:00', '13:30');
      expect((c.from, c.to), ('09:00', '13:30'));
      expect(TimeSlotSelection.custom('x', '13:30').isAllDay, isTrue);
      // "12:00 to 00:00" is until midnight, sent as 24:00; 00:00 to 00:00 is the whole day.
      expect(TimeSlotSelection.custom('12:00', '00:00').key, 'custom:12:00-24:00');
      expect(TimeSlotSelection.custom('00:00', '00:00'), TimeSlotSelection.allDay);
      expect(TimeSlotSelection.preset('all').isAllDay, isTrue);
      expect(TimeSlotSelection.preset(' ').isAllDay, isTrue);
    });
  });

  group('what goes on the wire', () {
    test('all day adds NOTHING, so the URL and its cache entry are unchanged', () {
      expect(TimeSlotSelection.allDay.queryParts, isEmpty);
    });

    test('a preset is slot=, custom times are time_from/time_to', () {
      expect(TimeSlotSelection.preset('dinner').queryParts, ['slot=dinner']);
      expect(TimeSlotSelection.custom('22:00', '02:00').queryParts, ['time_from=22%3A00', 'time_to=02%3A00']);
    });

    test('keys are stable, so an equal pick does not remount the pane', () {
      expect(TimeSlotSelection.allDay.key, 'all');
      expect(TimeSlotSelection.preset('lunch').key, 'preset:lunch');
      expect(TimeSlotSelection.custom('22:00', '02:00').key, 'custom:22:00-02:00');
      expect(TimeSlotSelection.preset('lunch'), TimeSlotSelection.preset('lunch'));
    });
  });

  group('the words — identical on the web', () {
    test('labels presets and the chip', () {
      expect(_defaults.first.optionLabel, 'Lunch · 12:00–17:00');
      expect(TimeSlotSelection.allDay.label(_defaults), 'All day');
      expect(TimeSlotSelection.preset('dinner').label(_defaults), 'Dinner · 18:00–24:00');
      expect(TimeSlotSelection.custom('22:00', '02:00').label(_defaults), 'Custom · 22:00–02:00');
      // A deleted preset never keeps its old name on the chip.
      expect(TimeSlotSelection.preset('brunch').label(_defaults), 'All day');
    });

    test('phrases the slot the same way from a pick and from the server', () {
      expect(TimeSlotSelection.preset('lunch').phrase(_defaults), 'Lunch (12:00–17:00)');
      expect(TimeSlotSelection.custom('22:00', '02:00').phrase(_defaults), '22:00–02:00');
      expect(TimeSlotSelection.allDay.phrase(_defaults), isNull);
      expect(_lunch.phrase, 'Lunch (12:00–17:00)');
      expect(_late.phrase, '22:00–02:00');
    });

    test('provenance says where a crossing night is counted', () {
      expect(timeSlotProvenance(null), 'All day');
      expect(timeSlotProvenance(_lunch), 'Lunch (12:00–17:00) restaurant time, on each day of the range');
      expect(
        timeSlotProvenance(_late),
        '22:00–02:00 restaurant time, on each day of the range — crosses midnight, so each night is counted on the day it starts',
      );
    });

    test('offers the two new segments only where the presets route answered', () {
      expect([for (final b in timeWiseOptions(true)) b.$2], ['Day-wise', 'Hour-wise', 'By hour of day', 'By session']);
      expect([for (final b in timeWiseOptions(true)) b.$1], ['day', 'hour', 'hour_of_day', 'session']);
      expect([for (final b in timeWiseOptions(false)) b.$1], ['day', 'hour']);
    });
  });

  group('the server\'s answer', () {
    test('meta.time_slot is read, and its absence is all day', () {
      final got = AppliedTimeSlot.fromMeta({
        'time_slot': {'id': 'lunch', 'label': 'Lunch', 'start': '12:00', 'end': '17:00', 'crosses_midnight': false, 'source': 'preset'},
      });
      expect(got?.phrase, 'Lunch (12:00–17:00)');
      expect(AppliedTimeSlot.fromMeta({'time_slot': null}), isNull);
      expect(AppliedTimeSlot.fromMeta(const {}), isNull);
      expect(AppliedTimeSlot.fromMeta({'time_slot': {'start': 'noon', 'end': '17:00'}}), isNull);
    });

    test('the presets route is read defensively', () {
      final cat = TimeSlotCatalogue.fromJson({
        'slots': [
          {'id': 'lunch', 'label': 'Lunch', 'start': '12:00', 'end': '17:00', 'crosses_midnight': false},
          {'id': 'dinner', 'label': 'Dinner', 'start': '18:00', 'end': '24:00', 'crosses_midnight': false},
          {'id': 'x', 'label': 'Broken', 'start': 'noon', 'end': '17:00'},
          null,
        ],
        'can_edit': true,
        'is_default': true,
      });
      expect([for (final s in cat!.slots) s.id], ['lunch', 'dinner']);
      expect(cat.canEdit, isTrue);
      expect(TimeSlotCatalogue.fromJson({'error': 'Forbidden'}), isNull);
    });

    test('a deleted preset falls back to all day', () {
      expect(TimeSlotSelection.preset('brunch').reconcile(_defaults), TimeSlotSelection.allDay);
      expect(TimeSlotSelection.preset('lunch').reconcile(_defaults), TimeSlotSelection.preset('lunch'));
      expect(TimeSlotSelection.custom('22:00', '02:00').reconcile(const []).key, 'custom:22:00-02:00');
    });
  });

  group('clamps: a list, not a flag', () {
    test('an empty list shortens nothing; `clamped == true` could never see a real one', () {
      expect(clampNotices(const <String>[]), (range: false, slot: null));
      expect(clampNotices(null), (range: false, slot: null));
      expect(clampNotices(false), (range: false, slot: null));
    });

    test('a date clamp shortens the range; a slot clamp says the slot was dropped', () {
      expect(clampNotices(['span_capped']), (range: true, slot: null));
      expect(clampNotices(['slot_unknown']), (range: false, slot: 'That session no longer exists — showing all day'));
      expect(clampNotices(['time_unparseable']).slot, 'Those times could not be read — showing all day');
      expect(clampNotices(['future_to', 'time_empty']), (range: true, slot: 'Start and end were the same — showing all day'));
    });
  });

  group('tapping a row into a slot', () {
    test('an hour-of-day row is that hour as a custom slot', () {
      expect(hourOfDaySlot('13:00-14:00')?.key, 'custom:13:00-14:00');
      expect(hourOfDaySlot('23:00-24:00')?.key, 'custom:23:00-24:00');
      expect(hourOfDaySlot('2026-08-01T13'), isNull);
      expect(hourOfDaySlot('2026-08-01'), isNull);
    });

    test('a session row is that saved session; Outside sessions is none', () {
      expect(sessionRowPreset('Lunch (12:00-17:00)', _defaults)?.id, 'lunch');
      expect(sessionRowPreset('Dinner (18:00-24:00)', _defaults)?.id, 'dinner');
      expect(sessionRowPreset('Outside sessions', _defaults), isNull);
      // Renamed since the report was built: not silently matched to the wrong one.
      expect(sessionRowPreset('Supper (18:00-24:00)', _defaults), isNull);
    });
  });

  group('the editor', () {
    test('catches format mistakes before a round trip, and allows what the server allows', () {
      expect(
          validateSlotDrafts(const [
            TimeSlotDraft(label: 'Lunch', start: '12:00', end: '17:00'),
            TimeSlotDraft(label: 'Late', start: '22:00', end: '02:00'),
          ]),
          isNull);
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Dinner', start: '18:00', end: '24:00')]), isNull);
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Whole day', start: '00:00', end: '24:00')]), isNull);
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Evening', start: '18:00', end: '00:00')]), isNull);
      expect(validateSlotDrafts(const [TimeSlotDraft(label: '  ', start: '12:00', end: '17:00')]),
          'Session 1: a session needs a name of 1 to 24 characters.');
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Lunch', start: '25:00', end: '17:00')]),
          'Lunch: start time must be between 00:00 and 23:59.');
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Lunch', start: '12:00', end: '24:30')]),
          'Lunch: end time must be between 00:00 and 24:00.');
      expect(validateSlotDrafts(const [TimeSlotDraft(label: 'Lunch', start: '12:00', end: '12:00')]),
          'Lunch: start and end cannot be the same time.');
      final nine = [
        for (var i = 0; i < kMaxTimeSlots + 1; i++)
          TimeSlotDraft(label: 'S$i', start: '${i.toString().padLeft(2, '0')}:00', end: '${i.toString().padLeft(2, '0')}:30'),
      ];
      expect(validateSlotDrafts(nine), 'A restaurant can keep at most 8 sessions.');
    });

    test('sends the whole list, keeping ids of renamed rows and normalising times', () {
      expect(
        slotDraftsBody(const [
          TimeSlotDraft(id: 'lunch', label: ' Brunch ', start: '11:00', end: '15:00'),
          TimeSlotDraft(label: 'Late', start: '9:05', end: '00:00'),
        ]),
        {
          'slots': [
            {'id': 'lunch', 'label': 'Brunch', 'start': '11:00', 'end': '15:00'},
            {'label': 'Late', 'start': '09:05', 'end': '24:00'},
          ],
        },
      );
      expect(slotDraftsBody(const []), {'slots': <Map<String, dynamic>>[]});
    });
  });

  group('the export', () {
    MisReportDoc doc({AppliedTimeSlot? slot}) => MisReportDoc(
          title: 'Sales Summary',
          columns: const [MisColumn(key: 'bucket', label: 'Period', type: 'text')],
          rows: const [
            {'bucket': '2026-08-01'},
          ],
          totals: null,
          from: '2026-08-01',
          to: '2026-08-15',
          timezone: 'Asia/Kolkata',
          outletLabel: 'Kalyani Nagar',
          notes: const [],
          timeSlot: slot,
        );

    test('the filename adds the slot ONLY when the server applied one — the old stem holds', () {
      expect(doc().fileStem, 'sales-summary_kalyani-nagar_2026-08-01_to_2026-08-15');
      expect(doc(slot: _lunch).fileStem, 'sales-summary_kalyani-nagar_2026-08-01_to_2026-08-15_lunch-1200-1700');
      expect(doc(slot: _late).fileStem, 'sales-summary_kalyani-nagar_2026-08-01_to_2026-08-15_custom-2200-0200');
      const dinner = AppliedTimeSlot(
          id: 'dinner', label: 'Dinner', start: '18:00', end: '24:00', crossesMidnight: false, source: 'preset');
      expect(dinner.fileSuffix, '_dinner-1800-2400');
      const odd = AppliedTimeSlot(
          id: 'x', label: 'Late / Night "Bar"', start: '12:00', end: '17:00', crossesMidnight: false, source: 'preset');
      expect(odd.fileSuffix, '_late-night-bar-1200-1700');
      // The server's slug rules: accents folded, and `slot` when nothing survives.
      const cafe = AppliedTimeSlot(
          id: 'x', label: 'Café', start: '12:00', end: '17:00', crossesMidnight: false, source: 'preset');
      expect(cafe.fileSuffix, '_cafe-1200-1700');
      const hindi = AppliedTimeSlot(
          id: 'x', label: 'दोपहर', start: '12:00', end: '17:00', crossesMidnight: false, source: 'preset');
      expect(hindi.fileSuffix, '_slot-1200-1700');
    });

    test('the file names its slot in the preamble and the heading', () {
      expect(misCsv(doc()), contains('Time slot,All day'));
      // Quoted: the sentence carries a comma, and a CSV must still parse.
      expect(misCsv(doc(slot: _lunch)), contains('Time slot,"Lunch (12:00–17:00) restaurant time, on each day of the range"'));
      expect(doc(slot: _lunch).displayTitle, 'Sales Summary — Lunch (12:00–17:00)');
      expect(doc().displayTitle, 'Sales Summary');
    });
  });
}
