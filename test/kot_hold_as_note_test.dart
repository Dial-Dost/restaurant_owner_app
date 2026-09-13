// ROUND 2 ITEMS 2 AND 3 — the KOT's hold prints UNDER the dish, like a note.
//
// Client, item 2: "Hold order should come after the name of the dish which is to
// be put on hold and not before. It should be in the same position like the way
// a note appears on the food order." Item 3: dish names bold, the rest of the
// KOT slightly larger.
//
// The thermal docket (escpos.ts, Restaurant_Backend#7) now prints a held dish in
// its own place in the numbered list with `[Hold] Do not cook until fired` on
// the indented line directly under it, then `[Note] <note>`; Total Qty counts
// what may be cooked now and Hold Qty sits under it. This pins the app's local
// PDF copy (via [kotDocket], the layout it prints) and the kitchen board's
// ticket to the same shape:
//   * a held dish keeps its number and position — no H1/H2, no second list;
//   * the hold line is AFTER the dish, never before, and before the note;
//   * notes are tagged `[Note]`, not `*`;
//   * no `** HOLD **` banner and no "DO NOT COOK UNTIL FIRED" line anywhere.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

Map<String, dynamic> _item(String name, {int qty = 1, bool held = false, String note = '', String? firedAt}) => {
      'id': 'i-$name',
      'name': name,
      'quantity': qty,
      if (held) 'course_hold': true,
      'fired_at': firedAt,
      if (note.isNotEmpty) 'note': note,
    };

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (!routes.containsKey(path)) throw ApiException('No fake route for $path', 404);
    return routes[path];
  }
}

void main() {
  group('kotDocket — the item block the PDF KOT prints', () {
    test('a held dish keeps its number and place; [Hold] hangs under it', () {
      final d = m.kotDocket([
        _item('Paneer Tikka', qty: 2),
        _item('Gulab Jamun', held: true),
        _item('Dal Makhani'),
      ]);
      expect(d.rows.map((r) => r.no), ['1', '2', '3'], reason: 'one numbering — no H1/H2');
      expect(d.rows.map((r) => r.name), ['Paneer Tikka', 'Gulab Jamun', 'Dal Makhani'],
          reason: 'the held dish stays where it was ordered, not lifted into a second list');
      expect(d.rows[1].held, isTrue);
      expect(d.rows[1].under, ['[Hold] Do not cook until fired']);
      expect(d.rows[0].under, isEmpty);
      expect(d.rows[2].under, isEmpty);
    });

    test('the hold comes AFTER the dish, never before it, and before the note', () {
      final d = m.kotDocket([_item('Gulab Jamun', held: true, note: 'Dessert course')]);
      // The dish is the row itself; everything in `under` prints below it.
      // Nothing about the hold is carried on a line ahead of the dish.
      expect(d.rows, hasLength(1));
      expect(d.rows.single.name, 'Gulab Jamun', reason: 'no "HOLD" prefix or banner row before the dish');
      expect(d.rows.single.under, ['[Hold] Do not cook until fired', '[Note] Dessert course']);
    });

    test('notes are tagged [Note], not "*"', () {
      final d = m.kotDocket([_item('Paneer Tikka', note: '  less spicy ')]);
      expect(d.rows.single.under, ['[Note] less spicy']);
      expect(m.kotNoteLine('no onion'), '[Note] no onion');
      expect(d.rows.single.under.any((l) => l.startsWith('*')), isFalse);
    });

    test('Total Qty counts what may be cooked now; Hold Qty sits under it', () {
      final d = m.kotDocket([
        _item('Paneer Tikka', qty: 2),
        _item('Gulab Jamun', qty: 3, held: true),
      ]);
      expect(d.totalQty, 2);
      expect(d.holdQty, 3);
      expect(d.showTotal, isTrue);
      expect(d.showHold, isTrue);
    });

    test('nothing held: Total Qty as always, no Hold Qty line', () {
      final d = m.kotDocket([_item('Paneer Tikka', qty: 2), _item('Naan', qty: 4)]);
      expect((d.totalQty, d.showTotal, d.showHold), (6, true, false));
      expect(d.rows.expand((r) => r.under), isEmpty);
    });

    test('everything held: no "Total Qty 0" over the hold total', () {
      final d = m.kotDocket([_item('Gulab Jamun', qty: 2, held: true)]);
      expect((d.showTotal, d.showHold, d.holdQty), (false, true, 2));
    });

    test('a FIRED course is no longer held', () {
      final d = m.kotDocket([_item('Gulab Jamun', held: true, firedAt: '2026-09-13T12:00:00Z')]);
      expect(d.rows.single.held, isFalse);
      expect(d.rows.single.under, isEmpty);
      expect((d.totalQty, d.showHold), (1, false));
    });

    test('the PDF builder carries no HOLD banner, H-numbering or "* note" any more', () {
      final src = File('lib/screens/modules.dart').readAsStringSync();
      final start = src.indexOf('Future<void> _printKot(String table, List items) async {');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n}\n', start));
      expect(body, isNot(contains('** HOLD **')));
      expect(body, isNot(contains('DO NOT COOK UNTIL FIRED')));
      expect(body, isNot(contains("'H\${")));
      expect(body, isNot(contains("'* \$")));
      // Dish names bold (item 3).
      expect(body, contains('pw.Text(r.name, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))'));
    });
  });

  group('the kitchen board ticket', () {
    Future<void> mountKds(WidgetTester tester, List<Map<String, dynamic>> items) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final api = _FakeApi({
        '/orders': [
          {
            'id': 'ord-1',
            'table': 'T1',
            'status': 'Preparing',
            'barked_at': '2026-08-01T10:00:00Z',
            'total': 500,
            'timing': {'order': {'started_at': '2026-08-01T10:00:00Z'}, 'items': <String, dynamic>{}},
            'items': items,
          },
        ],
        '/orders/scope': <String, dynamic>{},
        '/restaurant/settings': {'kitchen_sections': <String>[]},
        '/kds/expo': {'tables': <dynamic>[]},
      });
      final auth = AuthController(api: api);
      await auth.login('CSR Organics', 'admin', 'admin123');
      final rest = RestClient(auth);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Kitchen'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: m.kdsModule(rest, rest.auth.profile!)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a held dish shows [Hold] UNDER its name, above its note — no HOLD chip beside it', (tester) async {
      await mountKds(tester, [
        _item('Paneer Tikka', qty: 2),
        _item('Gulab Jamun', held: true, note: 'Dessert course'),
      ]);
      final dish = find.text('Gulab Jamun');
      final hold = find.text('[Hold] Do not cook until fired');
      final note = find.text('Dessert course');
      expect(dish, findsOneWidget);
      expect(hold, findsOneWidget);
      expect(note, findsOneWidget);
      expect(tester.getTopLeft(hold).dy, greaterThan(tester.getTopLeft(dish).dy), reason: 'after the dish, never before');
      expect(tester.getTopLeft(note).dy, greaterThan(tester.getTopLeft(hold).dy), reason: 'hold first, then note');
      expect(find.byWidgetPredicate((w) => w is StatusChip && w.label == 'HOLD'), findsNothing);
      // The held course is still fired from here.
      expect(find.text('Fire'), findsOneWidget);
    });

    testWidgets('nothing held, no hold line', (tester) async {
      await mountKds(tester, [_item('Paneer Tikka', qty: 2)]);
      expect(find.text('[Hold] Do not cook until fired'), findsNothing);
    });
  });
}
