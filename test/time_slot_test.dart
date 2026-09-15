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

    test("the pane is keyed on what a pick MEANS: a preset's hours and name, and every preset for By session", () {
      final lunch = TimeSlotSelection.preset('lunch');
      final moved = [const TimeSlotPreset(id: 'lunch', label: 'Lunch', start: '12:00', end: '15:00'), _defaults[1]];
      final renamed = [const TimeSlotPreset(id: 'lunch', label: 'Brunch', start: '12:00', end: '17:00'), _defaults[1]];
      final dinnerMoved = [_defaults[0], const TimeSlotPreset(id: 'dinner', label: 'Dinner', start: '19:00', end: '24:00')];
      // The URL cannot tell the old Lunch from the new one…
      expect(lunch.queryParts, ['slot=lunch']);
      expect(lunch.key, 'preset:lunch');
      // …so the key the pane remounts on carries the hours and the name.
      expect(slotDefinitionKey(lunch, _defaults), 'preset:lunch@12:00-17:00/Lunch');
      expect(slotDefinitionKey(lunch, moved), 'preset:lunch@12:00-15:00/Lunch');
      expect(slotDefinitionKey(lunch, renamed), 'preset:lunch@12:00-17:00/Brunch');
      expect(slotDefinitionKey(lunch, dinnerMoved), 'preset:lunch@12:00-17:00/Lunch',
          reason: "another session's edit is not this pick's question");
      expect(slotDefinitionKey(TimeSlotSelection.allDay, moved), 'all');
      expect(slotDefinitionKey(TimeSlotSelection.custom('22:00', '02:00'), moved), 'custom:22:00-02:00');

      // By session: its rows ARE the presets, so the whole list keys it — All
      // day included. The same string as the web's slotDefinitionKey.
      final all = slotDefinitionKey(TimeSlotSelection.allDay, _defaults, bucket: 'session');
      expect(all, 'all#[["lunch","Lunch","12:00","17:00"],["dinner","Dinner","18:00","24:00"]]');
      expect(slotDefinitionKey(TimeSlotSelection.allDay, moved, bucket: 'session'), isNot(all));
      expect(slotDefinitionKey(TimeSlotSelection.allDay, renamed, bucket: 'session'), isNot(all));
      expect(slotDefinitionKey(TimeSlotSelection.allDay, _defaults.sublist(0, 1), bucket: 'session'), isNot(all));
      final custom = TimeSlotSelection.custom('16:00', '19:00');
      expect(slotDefinitionKey(custom, dinnerMoved, bucket: 'session'),
          isNot(slotDefinitionKey(custom, _defaults, bucket: 'session')),
          reason: '16:00–19:00 by session carries a sliver of Dinner');
      for (final bucket in const ['day', 'hour', 'hour_of_day', null]) {
        expect(slotDefinitionKey(TimeSlotSelection.allDay, moved, bucket: bucket), 'all', reason: '$bucket');
      }
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

    test('a row opens only where its own slot counts exactly what the row did', () {
      AppliedTimeSlot custom(String from, String to) => AppliedTimeSlot(
          id: null, label: 'Custom', start: from, end: to, crossesMidnight: crossesMidnight(from, to), source: 'custom');

      // All day: any hour or session inside one day…
      expect(slotRowOpensExactly('13:00', '14:00', null), isTrue);
      expect(slotRowOpensExactly('23:00', '24:00', null), isTrue);
      expect(slotRowOpensExactly('12:00', '17:00', null), isTrue);
      // …but not a session crossing midnight: the row is cut on calendar days,
      // and that session on its own moves every small hour to the evening before.
      expect(slotRowOpensExactly('18:00', '02:00', null), isFalse);

      // A slot inside one day: rows inside it open, rows reaching past it do not.
      expect(slotRowOpensExactly('12:00', '17:00', _lunch), isTrue);
      expect(slotRowOpensExactly('13:00', '14:00', _lunch), isTrue);
      expect(slotRowOpensExactly('20:00', '21:00', _lunch), isFalse);
      expect(slotRowOpensExactly('16:00', '17:00', custom('16:00', '19:00')), isTrue);
      expect(slotRowOpensExactly('12:00', '17:00', custom('16:00', '19:00')), isFalse,
          reason: 'this Lunch row held only 16:00–17:00; all of Lunch is a bigger total');
      expect(slotRowOpensExactly('18:00', '24:00', custom('16:00', '19:00')), isFalse);
      expect(slotRowOpensExactly('23:00', '24:00', custom('18:00', '00:00')), isTrue, reason: 'an END of 00:00 is midnight');

      // Crossing midnight: the evening is on its own day under both, so it opens…
      expect(slotRowOpensExactly('22:00', '23:00', _late), isTrue);
      expect(slotRowOpensExactly('23:00', '24:00', _late), isTrue);
      // …the small hours are the day before's under the slot, the same day's alone.
      expect(slotRowOpensExactly('01:00', '02:00', _late), isFalse);
      expect(slotRowOpensExactly('00:00', '01:00', _late), isFalse);
      // A session crossing midnight inside it opens: both put a night on the day it starts.
      expect(slotRowOpensExactly('22:00', '02:00', _late), isTrue);
      expect(slotRowOpensExactly('23:00', '01:00', _late), isTrue);
      expect(slotRowOpensExactly('21:00', '01:00', _late), isFalse);
      expect(slotRowOpensExactly('23:00', '03:00', _late), isFalse);

      // Nothing unreadable is ever a control.
      expect(slotRowOpensExactly('noon', '14:00', null), isFalse);
      expect(slotRowOpensExactly('13:00', '13:00', null), isFalse);
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

    AppliedTimeSlot named(String label) => AppliedTimeSlot(
        id: 'x', label: label, start: '12:00', end: '15:00', crossesMidnight: false, source: 'preset');

    test('an accent in the MIDDLE of a label slugs as the server and the web do — the mark is a dash', () {
      // NFKD keeps the accent as a combining mark, which the slug turns into
      // `-`. Folding to the bare letter gave `dejeuner` here and
      // `de-jeuner` on the web, so one export had two names.
      expect(named('Déjeuner').fileSuffix, '_de-jeuner-1200-1500');
      expect(named('Mañana brunch').fileSuffix, '_man-ana-brunch-1200-1500');
      expect(named('Crème brûlée').fileSuffix, '_cre-me-bru-le-e-1200-1500');
      expect(named('Été').fileSuffix, '_e-te-1200-1500');
      expect(named('Café').fileSuffix, '_cafe-1200-1500');
      expect(named('ŁÓDŹ Śniadanie').fileSuffix, '_o-dz-s-niadanie-1200-1500');
      expect(named('İstanbul nights').fileSuffix, '_i-stanbul-nights-1200-1500');
      expect(named('Brunch ½ price').fileSuffix, '_brunch-1-2-price-1200-1500');
      // The mark counts toward the 32, then a trailing dash is trimmed.
      expect(named('abcdefghijklmnopqrstuvwxyz01234é').fileSuffix,
          '_abcdefghijklmnopqrstuvwxyz01234e-1200-1500');
      expect(named('abcdefghijklmnopqrstuvwxyz0123é5').fileSuffix,
          '_abcdefghijklmnopqrstuvwxyz0123e-1200-1500');
    });

    test('every Latin-1 and Latin Extended-A character slugs exactly as the server does', () {
      // Generated by running the server's rule (report_window.ts slugOf:
      // toLowerCase, normalize('NFKD'), [^a-z0-9]+ -> '-', trim, 32) over
      // 'a' + ch + 'b' for U+00A0..U+017F, in code point order.
      const server = 'a-b a-b a-b a-b a-b a-b a-b a-b a-b a-b aab a-b a-b a-b a-b a-b a-b '
          'a-b a2b a3b a-b a-b a-b a-b a-b a1b aob a-b a1-4b a1-2b a3-4b a-b aa-b '
          'aa-b aa-b aa-b aa-b aa-b a-b ac-b ae-b ae-b ae-b ae-b ai-b ai-b ai-b '
          'ai-b a-b an-b ao-b ao-b ao-b ao-b ao-b a-b a-b au-b au-b au-b au-b '
          'ay-b a-b a-b aa-b aa-b aa-b aa-b aa-b aa-b a-b ac-b ae-b ae-b ae-b '
          'ae-b ai-b ai-b ai-b ai-b a-b an-b ao-b ao-b ao-b ao-b ao-b a-b a-b '
          'au-b au-b au-b au-b ay-b a-b ay-b aa-b aa-b aa-b aa-b aa-b aa-b ac-b '
          'ac-b ac-b ac-b ac-b ac-b ac-b ac-b ad-b ad-b a-b a-b ae-b ae-b ae-b '
          'ae-b ae-b ae-b ae-b ae-b ae-b ae-b ag-b ag-b ag-b ag-b ag-b ag-b ag-b '
          'ag-b ah-b ah-b a-b a-b ai-b ai-b ai-b ai-b ai-b ai-b ai-b ai-b ai-b '
          'a-b aijb aijb aj-b aj-b ak-b ak-b a-b al-b al-b al-b al-b al-b al-b '
          'al-b al-b a-b a-b an-b an-b an-b an-b an-b an-b a-nb a-b a-b ao-b ao-b '
          'ao-b ao-b ao-b ao-b a-b a-b ar-b ar-b ar-b ar-b ar-b ar-b as-b as-b '
          'as-b as-b as-b as-b as-b as-b at-b at-b at-b at-b a-b a-b au-b au-b '
          'au-b au-b au-b au-b au-b au-b au-b au-b au-b au-b aw-b aw-b ay-b ay-b '
          'ay-b az-b az-b az-b az-b az-b az-b asb';
      final want = server.split(' ');
      expect(want, hasLength(0x180 - 0xA0));
      for (var cp = 0xA0; cp < 0x180; cp++) {
        expect(named('a${String.fromCharCode(cp)}b').fileSuffix, '_${want[cp - 0xA0]}-1200-1500',
            reason: 'U+${cp.toRadixString(16).toUpperCase()} ${String.fromCharCode(cp)}');
      }
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
