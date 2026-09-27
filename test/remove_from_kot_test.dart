// ROUND 4 ITEM 2 — "'Remove from bill' makes it sound like the item is going to
// be served but only removed from bill."
//
// THE WORDS, and the reason they are worth a test: the floor reads the label
// and nothing else, and "remove from bill" is an exact description of a COMP,
// which this app also has ("Make non-chargeable", mis_capture.dart) and which
// does the opposite — the dish is cooked and carried out, and the house eats
// the cost. Tapping the wrong one of those two is not recoverable: a CANCELLED
// slip is at the pass before anybody notices, and the guest never gets the dish.
//
// PARITY. Every sentence below is pinned character for character in the web's
// src/lib/__tests__/remove-from-kot-wording.test.ts, so a restaurant that
// removes a dish on the till and on the laptop is told the same thing twice.

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/remove_from_kot.dart';

void main() {
  group('the question', () {
    test('names the dish and the KOT, not the bill', () {
      expect(removeFromKotTitle('Tandoori Roti'), 'Remove "Tandoori Roti" from this KOT?');
      expect(removeFromKotTitle('Tandoori Roti'), isNot(contains('bill?')));
    });

    test('says the kitchen is told and nobody is served', () {
      expect(removeFromKotWarning, contains('CANCELLED'));
      expect(removeFromKotWarning, contains('will not be cooked or served'));
    });

    test('points at the comp, which is the act somebody reaching for this may actually want', () {
      expect(removeFromKotWarning, contains('non-chargeable'));
    });
  });

  group('what the person is told afterwards', () {
    test('the slip and its number, when the pass was handed one', () {
      expect(
        removedFromKotSentence('Tandoori Roti', {'success': true, 'kot_cancelled': true, 'kot_no': 3}),
        'Removed Tandoori Roti from KOT-3. The slip is printing as CANCELLED — tell the pass.',
      );
    });

    test('a number the server sent as a string is still a number to the floor', () {
      expect(
        removedFromKotSentence('Dal', {'kot_cancelled': true, 'kot_no': '12'}),
        contains('from KOT-12.'),
      );
    });

    test('nothing reached the pass: no docket is announced, and the outcome still is', () {
      // A pending order, or a tenant that prints on demand. Naming a docket
      // that does not exist sends someone to the rail to look for paper that
      // is not there.
      for (final answer in <Object?>[
        {'success': true, 'kot_cancelled': false, 'kot_no': null, 'kot_skipped': 'never_ticketed'},
        {'success': true},
        {'kot_cancelled': true, 'kot_no': ''},
        null,
        'not a map',
      ]) {
        expect(
          removedFromKotSentence('Dal', answer),
          'Removed Dal from the KOT. It will not be cooked.',
        );
      }
    });

    test('never says "removed from the bill" — the reading the client asked us to stop inviting', () {
      for (final answer in <Object?>[{'kot_cancelled': true, 'kot_no': 3}, null]) {
        expect(removedFromKotSentence('Dal', answer).toLowerCase(), isNot(contains('bill')));
      }
    });
  });
}
