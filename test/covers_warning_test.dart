// WHAT THE PAD SAYS WHEN A PARTY IS BIGGER THAN THE TABLE.
//
// Client item 3: "More than the covers defined on the table, the KOT won't get
// punched." The pad seats before it sends — it must, because the seating is
// what every APC reading matches a bill against — and the seat call used to
// come back 400, so the send stopped there and the kitchen never saw the order.
//
// The backend now seats the party, records the TRUE head count and returns
// `covers_warning`. These tests pin the reading of that field, because the
// failure mode is not a crash: it is silence, and silence on this screen reads
// as "everything is normal".

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/models/covers_warning.dart';

void main() {
  group('CoversWarning.parse', () {
    test('reads the sentence the server wrote, verbatim', () {
      const sentence =
          'T1 seats up to 2. 6 covers were recorded. To seat 6 comfortably, '
          'raise this table\'s max seats or combine tables.';
      final w = CoversWarning.parse({'covers_warning': sentence});
      expect(w, isNotNull);
      expect(w!.message, sentence);
    });

    test('a party that fits says NOTHING', () {
      // The ordinary seating. Null here is the difference between a quiet
      // floor and a snackbar on every single seat.
      expect(CoversWarning.parse({'success': true}), isNull);
      expect(CoversWarning.parse({'covers_warning': null}), isNull);
      expect(CoversWarning.parse({'covers_warning': ''}), isNull);
      expect(CoversWarning.parse({'covers_warning': '   '}), isNull);
    });

    test('an older backend that has never heard of the field says nothing', () {
      // The field is additive: the fix ships to servers before it ships to
      // tills, and a till on 2.0.2 must not start narrating absence.
      expect(CoversWarning.parse({'assignment': {'assigned': true}}), isNull);
    });

    test('a response that is not a map says nothing', () {
      // What the outbox hands back when the seat was queued offline, and what a
      // 204 leaves behind.
      expect(CoversWarning.parse(null), isNull);
      expect(CoversWarning.parse('ok'), isNull);
      expect(CoversWarning.parse(<Object>[]), isNull);
    });

    test('the string "null" is not a sentence', () {
      // '${raw[...]}' on a null stringifies; without the guard the floor reads
      // a snackbar that says, in full, "null".
      expect(CoversWarning.parse({'covers_warning': 'null'}), isNull);
    });

    test('a non-string sentence is still read, and trimmed', () {
      expect(CoversWarning.parse({'covers_warning': ' T1 seats up to 2. '})!.message,
          'T1 seats up to 2.');
    });
  });
}
