import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/order_draft.dart';

/// ITEM 5 — the pure half of "View order": the draft as lines, and the payload
/// the send posts from those same lines.
///
/// The one property everything else leans on is that the payload did NOT
/// change. The review is a new way to LOOK at the order; if building it had
/// quietly altered what POST /orders receives, a waiter who never opens the
/// review would still be sending something different from what shipped. So the
/// legacy builder is kept below, verbatim, and the new one is held to it.

/// What `_send` built before item 5, copied from order_entry.dart unchanged
/// (the `!` included — it is the defect the new builder removes).
List<Map<String, Object?>> _legacyItems(
  Map<String, int> cart,
  Map<String, String> notes,
  Set<String> hold,
  Map<String, Map> itemsById,
) =>
    cart.entries.map((e) {
      final m = itemsById[e.key]!;
      final note = (notes[e.key] ?? '').trim();
      return {
        'id': e.key,
        'name': m['name'],
        'price': m['price'],
        'quantity': e.value,
        if (note.isNotEmpty) 'note': note,
        if (hold.contains(e.key)) 'course_hold': true,
      };
    }).toList();

/// And the Send button's total before item 5.
double _legacyTotal(Map<String, int> cart, Map<String, Map> itemsById) => cart.entries
    .fold(0.0, (s, e) => s + ((itemsById[e.key]?['price'] as num?)?.toDouble() ?? 0) * e.value);

final Map<String, Map> _menu = {
  'mi-1': {'id': 'mi-1', 'name': 'Paneer Tikka', 'price': 320.0},
  'mi-2': {'id': 'mi-2', 'name': 'Dal Makhani', 'price': 285},
  'mi-3': {'id': 'mi-3', 'name': 'Butter Naan', 'price': 45.5},
  'mi-4': {'id': 'mi-4', 'name': 'Lassi', 'price': null},
};

List<OrderDraftLine> _lines(Map<String, int> cart,
        {Map<String, String> notes = const {},
        Set<String> held = const {},
        Map<String, Map>? menu,
        Map<String, String> knownNames = const {}}) =>
    orderDraftLines(cart: cart, notes: notes, held: held, itemsById: menu ?? _menu, knownNames: knownNames);

void main() {
  group('orderDraftLines', () {
    test('keeps the order the dishes were ADDED in, not the menu order', () {
      final lines = _lines({'mi-3': 2, 'mi-1': 1, 'mi-2': 1});
      expect(lines.map((l) => l.menuId), ['mi-3', 'mi-1', 'mi-2']);
      expect(lines.map((l) => l.quantity), [2, 1, 1]);
      expect(lines.first.name, 'Butter Naan');
    });

    test('skips a quantity that is not a positive count', () {
      final lines = _lines({'mi-1': 0, 'mi-2': -1, 'mi-3': 1}, held: {'mi-1'});
      expect(lines.map((l) => l.menuId), ['mi-3']);
    });

    test('trims the note, and an all-space note is no note', () {
      final lines = _lines({'mi-1': 1, 'mi-2': 1}, notes: {'mi-1': '  no onions  ', 'mi-2': '   '});
      expect(lines[0].note, 'no onions');
      expect(lines[1].note, '');
    });

    test('prices a line the way the Send button does — a missing price is 0', () {
      final lines = _lines({'mi-2': 2, 'mi-4': 3});
      expect(lines[0].unitPrice, 285.0);
      expect(lines[0].amount, 570.0);
      expect(lines[1].unitPrice, 0.0);
      expect(lines[1].amount, 0.0);
      expect(lines.every((l) => l.onMenu), isTrue);
    });

    test('a dish the menu dropped is KEPT, flagged, named, and priced at nothing', () {
      final menu = Map<String, Map>.of(_menu)..remove('mi-2');
      final lines = _lines({'mi-1': 1, 'mi-2': 2}, menu: menu, knownNames: {'mi-2': 'Dal Makhani'});
      expect(lines, hasLength(2), reason: 'dropping it would send a shorter order than the one read back');
      expect(lines[1].onMenu, isFalse);
      expect(lines[1].name, 'Dal Makhani');
      expect(lines[1].quantity, 2);
      expect(lines[1].unitPrice, isNull);
      expect(lines[1].amount, isNull);
    });
  });

  group('orderDraftPayload — byte-for-byte what the pad always sent', () {
    test('the same maps, keys, values and order as the legacy builder', () {
      final cart = {'mi-3': 2, 'mi-1': 1, 'mi-2': 1, 'mi-4': 4};
      final notes = {'mi-1': ' extra spicy ', 'mi-3': '', 'mi-4': 'no ice'};
      final held = {'mi-2', 'mi-4'};
      final lines = orderDraftLines(cart: cart, notes: notes, held: held, itemsById: _menu);
      final now = orderDraftPayload(lines);
      final before = _legacyItems(cart, notes, held, _menu);
      expect(now, equals(before));
      // `equals` is order-insensitive on map KEYS; the wire is not, so compare the
      // key sequence too.
      for (var i = 0; i < now.length; i++) {
        expect(now[i].keys.toList(), before[i].keys.toList());
      }
      // The raw menu values travel untouched — an int price stays an int.
      expect(now[2]['price'], isA<int>());
      expect(now[3]['price'], isNull);
    });

    test('no note key without a note, no course_hold key unless held', () {
      final payload = orderDraftPayload(_lines({'mi-1': 1}));
      expect(payload.single.containsKey('note'), isFalse);
      expect(payload.single.containsKey('course_hold'), isFalse);
    });

    test('the total is the legacy fold, term for term', () {
      final cart = {'mi-3': 3, 'mi-1': 1, 'mi-2': 7, 'mi-4': 2};
      expect(orderDraftTotal(_lines(cart)), _legacyTotal(cart, _menu));
      // ...including with a dish off the menu, which both count as nothing.
      final menu = Map<String, Map>.of(_menu)..remove('mi-1');
      expect(orderDraftTotal(_lines(cart, menu: menu)), _legacyTotal(cart, menu));
    });
  });

  group('the read-out and the refusal', () {
    test('"N items · M dishes", singular where it is one', () {
      expect(orderDraftSummary(_lines({'mi-1': 2, 'mi-2': 1, 'mi-3': 1})), '4 items · 3 dishes');
      expect(orderDraftSummary(_lines({'mi-1': 1})), '1 item · 1 dish');
      expect(orderDraftSummary(_lines({'mi-1': 2})), '2 items · 1 dish');
      expect(orderDraftItemCount(_lines({'mi-1': 2, 'mi-2': 5})), 7);
    });

    test('a sendable draft is not blocked', () {
      expect(orderDraftBlock(_lines({'mi-1': 1})), isNull);
    });

    test('an off-menu dish blocks the send, by name', () {
      final menu = Map<String, Map>.of(_menu)..remove('mi-2');
      final lines = _lines({'mi-1': 1, 'mi-2': 1}, menu: menu, knownNames: {'mi-2': 'Dal Makhani'});
      expect(orderDraftBlock(lines), 'Dal Makhani is no longer on the menu — remove it to send');
    });

    test('a bad phone number is reported first, as the pad always has', () {
      final menu = Map<String, Map>.of(_menu)..remove('mi-2');
      final lines = _lines({'mi-2': 1}, menu: menu);
      expect(orderDraftBlock(lines, phoneError: 'Enter a 10-digit mobile'), 'Enter a 10-digit mobile');
    });

    test('an empty draft is blocked', () {
      expect(orderDraftBlock(const []), isNotNull);
    });
  });
}
