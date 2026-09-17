// CLIENT ITEMS 3 AND 4 — the pure words (models/order_moves.dart and
// models/cancel_kot.dart), and the reprint parse a move's answer needs.
//
// PARITY. The sentences pinned under "the words both clients say" are pinned,
// character for character, in the dashboard's src/lib/__tests__/table-move.test.ts
// too: a restaurant that moves an order on the laptop and on the till is told
// the same thing both times.

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/cancel_kot.dart';
import 'package:restaurant_owner_app/models/next_party.dart';
import 'package:restaurant_owner_app/models/order_moves.dart';
import 'package:restaurant_owner_app/models/profile.dart';

const _kot65 = {
  'id': 'o-65',
  'kot_nos': [65],
  'total': 1427,
  'items': [
    {'name': 'KUNAFA BIRDS NEST', 'price': 489, 'quantity': 1},
    {'name': 'STIR FRIED WATERCHESTNUT', 'price': 419, 'quantity': 1},
    {'name': 'TRUFFLE CREAM CHEESE', 'price': 519, 'quantity': 1},
    {'name': 'Dal', 'variation': 'Half', 'price': 200, 'quantity': 2},
  ],
};

void main() {
  group('one dish', () {
    test('quantity × name (size) — never a price', () {
      expect(moveDishLine({'name': 'Dal', 'variation': 'Half', 'quantity': 2, 'price': 400}), '2 × Dal (Half)');
      expect(moveDishLine({'name': 'Dal', 'variation_name': 'Full', 'quantity': '3'}), '3 × Dal (Full)');
      expect(moveDishLine({'item_name': 'Lassi', 'qty': 2}), '2 × Lassi');
      expect(moveDishLine({'quantity': 0}), '1 × Item');
      expect(moveDishLine({'name': 'Chai', 'variation': null, 'quantity': 1.6}), '2 × Chai');
      expect(moveDishLine({'name': 'null', 'quantity': null}), '1 × Item');
    });

    test('an order\'s dishes: the row\'s items, else the nested food of an older row', () {
      expect(orderDishLines(_kot65), ['1 × KUNAFA BIRDS NEST', '1 × STIR FRIED WATERCHESTNUT', '1 × TRUFFLE CREAM CHEESE', '2 × Dal (Half)']);
      expect(orderDishLines({'food': {'items': [{'name': 'Roti', 'quantity': 4}]}}), ['4 × Roti']);
      expect(orderDishLines({'items': 'nope'}), isEmpty);
    });

    test('a summary names the first three and counts the rest', () {
      final lines = orderDishLines(_kot65);
      expect(moveDishSummary(lines), '1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE +1 more');
      expect(moveDishSummary(lines, max: null), lines.join(', '));
      expect(moveDishSummary(lines.take(3).toList()), lines.take(3).join(', '));
      expect(moveDishSummary(const []), '');
    });
  });

  group('the ticket', () {
    test('its handle: the KOT, cleaned, or "No KOT number"', () {
      expect(moveOrderTitle(_kot65), 'KOT 65');
      expect(moveOrderTitle({'kot_nos': [65, '66', 65, 0, -2, 'x']}), 'KOTs 65, 66');
      expect(moveOrderTitle({'kot_nos': null}), 'No KOT number');
      expect(moveOrderTitle(const {}), 'No KOT number');
      expect(moveKotNos({'kot_nos': [7.4, 7]}), [7]);
    });

    test('the picker row carries no money', () {
      final row = moveOrderPickerRow(_kot65);
      expect(row.title, 'KOT 65');
      expect(row.dishes, contains('KUNAFA'));
      expect('${row.title}${row.dishes}', isNot(contains('1427')));
      expect('${row.title}${row.dishes}', isNot(contains('₹')));
    });

    test('where it came from', () {
      expect(movedFromLabel({'moved_from': '12'}), 'from 12');
      expect(movedFromLabel({'moved_from': ' '}), isNull);
      expect(movedFromLabel(const {}), isNull);
    });

    test('what a dish move took off it, grouped by where each went', () {
      expect(movedAwayLine(const {}), isNull);
      expect(movedAwayLine({'moved_items': []}), isNull);
      expect(movedAwayLine({
        'moved_items': [
          {'name': 'NOT YOUR PUCHKA', 'quantity': 1, 'to_table': '31'},
        ],
      }), 'Moved to 31: 1 × NOT YOUR PUCHKA');
      expect(movedAwayLine({
        'moved_items': [
          {'name': 'A', 'quantity': 1, 'to_table': '31'},
          {'name': 'B', 'variation': 'Half', 'quantity': 2, 'to_table': '32'},
          {'name': 'C', 'quantity': 1, 'to_table': '31'},
          {'name': 'D', 'quantity': 1},
        ],
      }), 'Moved to 31: 1 × A, 1 × C; to 32: 2 × B (Half); to another table: 1 × D');
    });
  });

  group('the words both clients say', () {
    test('the confirm: WHAT moves, then what the kitchen sees', () {
      expect(
        moveOrderConfirmBody(order: {..._kot65, 'barked_at': '2026-09-14T10:57:16Z'}, fromTable: '12', toTable: '15'),
        'KOT 65: 1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE, 2 × Dal (Half).\n\n'
        'The kitchen already has a docket for 12, so a correction docket prints for 15 with the same KOT number. '
        '12 keeps its guests and its other orders.',
      );
      expect(
        moveOrderConfirmBody(order: {'items': [{'name': 'Dal', 'quantity': 2}], 'barked_at': null}, fromTable: '12', toTable: '15'),
        '2 × Dal.\n\nThe kitchen has not been sent this order yet, so nothing prints now — it will print for 15 when it is sent.',
      );
      expect(
        moveOrderConfirmBody(order: const {'barked_at': null}, fromTable: '12', toTable: '15'),
        'The kitchen has not been sent this order yet, so nothing prints now — it will print for 15 when it is sent.',
      );
    });

    // REVIEW FINDING — production barks almost no printed ticket (GGV: 79 of 80
    // in a fortnight). The same cases are pinned in the dashboard's
    // src/lib/__tests__/table-move.test.ts.
    test('the kitchen has a ticket when it carries a KOT number OR a bark — one rule on both clients', () {
      expect(moveOrderKitchenHas({'kot_nos': [65], 'barked_at': null}), isTrue);
      expect(moveOrderKitchenHas({'kot_nos': [], 'barked_at': '2026-09-14T10:57:16Z'}), isTrue);
      expect(moveOrderKitchenHas({'kot_nos': [65], 'barked_at': '2026-09-14T10:57:16Z'}), isTrue);
      expect(moveOrderKitchenHas({'kot_nos': [], 'barked_at': null}), isFalse);
      expect(moveOrderKitchenHas({'kot_nos': [0, -1, 'x'], 'barked_at': null}), isFalse);
      expect(moveOrderKitchenHas({'barked_at': null}), isFalse);
      // A backend older than both fields: read as barked, as the rest of the app reads it.
      expect(moveOrderKitchenHas(const {}), isTrue);
    });

    test('KOT 65, printed and never barked: the confirm says a correction prints — which is what the server does', () {
      final body = moveOrderConfirmBody(order: {..._kot65, 'barked_at': null}, fromTable: '12', toTable: '15');
      expect(body, startsWith('KOT 65: 1 × KUNAFA BIRDS NEST'));
      expect(body, contains('The kitchen already has a docket for 12, so a correction docket prints for 15 with the same KOT number.'));
      expect(body, isNot(contains('has not been sent')));
    });

    test('the kitchen sentence, alone (the dashboard puts it under each order)', () {
      expect(moveOrderKitchenSentence(fromTable: '12', toTable: 'the new table', barked: true),
          'The kitchen already has a docket for 12, so a correction docket prints for the new table with the same KOT number. '
          '12 keeps its guests and its other orders.');
      expect(moveOrderKitchenSentence(fromTable: '12', toTable: '15', barked: false),
          'The kitchen has not been sent this order yet, so nothing prints now — it will print for 15 when it is sent.');
    });

    test('the result names the dishes and the correction docket', () {
      final dishes = orderDishLines(_kot65);
      expect(movedOrderSentence(toTable: '15', printed: true, kotNo: 65, dishes: dishes),
          'Moved to 15: 1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE +1 more. '
          'Correction docket KOT-65 is printing — tell the pass.');
      expect(movedOrderSentence(toTable: '15', printed: false, dishes: const ['2 × Dal']),
          'Moved to 15: 2 × Dal. Nothing was on the pass for it, so no docket printed.');
      // No dishes and no number: the 2.0.1 sentences, word for word.
      expect(movedOrderSentence(toTable: '15', printed: true), 'Moved to 15. A correction docket is printing — tell the pass.');
      expect(movedOrderSentence(toTable: '15', printed: false), 'Moved to 15. Nothing was on the pass for it, so no docket printed.');
    });

    test('the server\'s `items` are read into the same lines', () {
      expect(movedDishesOf({'items': [{'name': 'Dal', 'variation': 'Half', 'quantity': 2}, 'junk']}), ['2 × Dal (Half)']);
      expect(movedDishesOf({'items': 'nope'}), isEmpty);
      expect(movedDishesOf(null), isEmpty);
    });

    test('one dish moved: the dish, and the docket printing for it', () {
      expect(
        movedItemSentence(toTable: '31', dishes: const ['1 × NOT YOUR PUCHKA'], fallbackName: 'x', response: {
          'prints': [{'printed': true, 'kot_no': 35}],
        }),
        'Moved 1 × NOT YOUR PUCHKA to Table 31. Docket KOT-35 is printing for 31 — tell the pass.',
      );
      expect(
        movedItemSentence(toTable: '31', dishes: const ['1 × A', '2 × A'], fallbackName: 'A', response: {
          'prints': [{'printed': true, 'kot_no': 35}, {'printed': true, 'kot_no': 40}, {'printed': false, 'kot_no': null}],
        }),
        'Moved 1 × A, 2 × A to Table 31. Docket KOT-35, KOT-40 are printing for 31 — tell the pass.',
      );
      expect(movedItemSentence(toTable: '31', dishes: const [], fallbackName: 'Dal', response: {'success': true}),
          'Moved Dal to Table 31.');
    });
  });

  group('client item 3 — the refusal, in the server\'s words', () {
    test('the sentence is cancel_authority.ts\'s, word for word', () {
      expect(cancelNeedsSeniorSentence(const [65]),
          'KOT-65 has gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.');
      expect(cancelNeedsSeniorSentence(const []),
          'This order has gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.');
      expect(cancelNeedsSeniorSentence(const [5, 5, 7, 0]),
          'KOT-5, KOT-7 have gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.');
      expect(cancelNeedsSeniorCode, 'cancel_needs_senior');
    });

    test('Pending is the only status a waiter may still decline', () {
      expect(orderIsPending('Pending'), isTrue);
      expect(orderIsPending(' pending '), isTrue);
      for (final s in ['Preparing', 'Served', 'Bill Verification', '', null]) {
        expect(orderIsPending(s), isFalse);
      }
    });

    test('the capability rides the session\'s scope, and survives the offline round trip', () {
      final p = Profile.fromJson({
        'role': 'waiter', 'role_all': ['waiter'], 'actions_set': ['a'],
        'scope': {'waiter_only': true, 'cancel_kot': false},
      });
      expect(Capability.cancelKot.wireKey, 'cancel_kot');
      expect(p.said(Capability.cancelKot), isFalse);
      expect(Profile.fromJson(p.toJson()).said(Capability.cancelKot), isFalse);
      expect(Profile.fromJson({'role': 'waiter'}).said(Capability.cancelKot), isNull);
    });
  });

  group('client item 4 — a move can ask for two reprints', () {
    test('both, destination first', () {
      final all = ReprintNeeded.parseAll({
        'reprint_needed': true, 'reprint_table': '15', 'reprint_message': 'fifteen',
        'also_reprint_needed': true, 'also_reprint_table': '12', 'also_reprint_message': 'twelve',
      }, fallbackTable: '15');
      expect(all.map((r) => '${r.table}:${r.message}').toList(), ['15:fifteen', '12:twelve']);
    });

    test('one, or none, and the fallback table only for the first', () {
      expect(ReprintNeeded.parseAll({'reprint_needed': true}, fallbackTable: '15').single.table, '15');
      expect(ReprintNeeded.parseAll({'also_reprint_needed': true}, fallbackTable: '15'), isEmpty);
      expect(ReprintNeeded.parseAll({'success': true}), isEmpty);
      expect(ReprintNeeded.parseAll(null), isEmpty);
      // The ordinary parse is unchanged.
      expect(ReprintNeeded.parse({'reprint_needed': true, 'reprint_table': '9'})!.message,
          reprintNeededMessage('9'));
    });
  });
}
