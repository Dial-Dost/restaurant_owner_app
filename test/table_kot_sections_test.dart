// REQUIREMENTS 1.8 AND 1.3 on the table preview.
//
//   1.8 — a table with several KOTs shows them as separated blocks, each under a
//     "KOT n · hh:mm" header, instead of one long list of the bill's lines. The
//     rule lives in [m.tableKotGroups] and is pinned here without a screen:
//     which orders (exactly the bill's `order_ids`, in the server's order), where
//     un-numbered lines go (one trailing group), and when NOT to split at all
//     (the orders feed cannot account for the whole bill — the flat list is
//     drawn rather than a preview that silently under-states the table).
//
//   1.3 — each numbered block carries "Cancel KOT", and it is the app's ONE
//     cancel underneath: the mandatory reason (1.2), the void-or-plain route
//     decision, and nothing new on the wire. Hidden from somebody who can take
//     neither route, and never on the trailing group, which is not a ticket.
//
//   CLIENT ITEM 3 (2026-09-17) — "On the waiter dashboard, Cancel KOT option
//     should be removed." Hidden from a waiter-only login, whatever it holds
//     (the server's `cancel_kot`, and the same answer worked out against an
//     older backend); every other role keeps it exactly as before.
//
//   CLIENT ITEM 4 — a ticket moved here from another table says so in its
//     header: "KOT 65 · 16:27 · from 12".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

const String _addOrders = '4ad474d4-5230-449c-874f-6a238b833bca';

// ------------------------------------------------------------------ fixtures

Map<String, dynamic> _order(String id, {List<int>? kotNos, String at = '2026-09-13T09:27:00Z',
        String status = 'Preparing', List<Map<String, dynamic>> items = const []}) =>
    {
      'id': id,
      'table': 'T1',
      'status': status,
      'created_at': at,
      'total': 500,
      'kot_nos': ?kotNos,
      'items': items,
    };

Map<String, dynamic> _line(String name, {int qty = 1, num price = 100, String? note}) =>
    {'name': name, 'quantity': qty, 'price': price, 'note': note};

final List<Map<String, dynamic>> _threeOrders = [
  _order('o-1', kotNos: [5], at: '2026-09-13T09:27:00Z', items: [
    _line('Gin & Tonic', price: 699),
    _line('Tandoori Roti', price: 129, note: 'less spicy'),
  ]),
  // Not sent to the kitchen yet — no number.
  _order('o-2', at: '2026-09-13T09:31:00Z', items: [_line('Subz Tehri', price: 599)]),
  _order('o-3', kotNos: [7, 9], at: '2026-09-13T09:40:00Z', items: [_line('Jackfruit Biryani', price: 649)]),
];

Map<String, dynamic> _bill(List<String> orderIds) => {
      'bill_id': 'bill-1',
      'total_amt': 2076.0,
      'subtotal': 2076.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'tax_total': 0.0,
      'grand_total': 2076.0,
      'nc_total': 0.0,
      'covers': 2,
      'apc': 1038.0,
      'target_apc': 500.0,
      'apc_status': 'green',
      'order_ids': orderIds,
      'items': const [
        {'name': 'Gin & Tonic', 'price': 699.0, 'quantity': 1},
        {'name': 'Tandoori Roti', 'price': 129.0, 'quantity': 1, 'note': 'less spicy'},
        {'name': 'Subz Tehri', 'price': 599.0, 'quantity': 1},
        {'name': 'Jackfruit Biryani', 'price': 649.0, 'quantity': 1},
      ],
      'first_order_at': '2026-09-13T09:27:00Z',
      'last_order_at': '2026-09-13T09:40:00Z',
    };

// ---------------------------------------------------------------- the harness

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {required this.actions, this.role = 'admin', this.waiterOnly, this.cancelKot});

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;
  final bool? waiterOnly;
  /// The server's `scope.cancel_kot`, when the fake backend sends one.
  final bool? cancelKot;
  final List<String> calls = [];
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'manager01',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          if (waiterOnly != null || cancelKot != null)
            'scope': <String, dynamic>{'waiter_only': ?waiterOnly, 'cancel_kot': ?cancelKot},
          'actions_set': actions,
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

Map<String, dynamic> _routes({List<Map<String, dynamic>>? orders, List<String>? orderIds}) => {
      '/get-tables': [
        {
          'table_name': 'T1',
          'capacity': 4,
          'max_capacity': 4,
          'section': 'Main',
          'occupied': true,
          'has_order': true,
          'reserved': false,
          'covers': 2,
          'table_total': 2076.0,
          'waiter_name': 'Ravi K',
        },
      ],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': _bill(orderIds ?? const ['o-1', 'o-2', 'o-3']),
      '/orders': ?orders,
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': const <dynamic>[],
    };

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<void> _openT1(WidgetTester tester, _FakeApi api, {Size size = const Size(1400, 3000)}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'ravi', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

Finder _header(Object key) => find.byKey(ValueKey('table-kot-header-$key'));
Finder _cancel(Object key) => find.byKey(ValueKey('table-kot-cancel-$key'));

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  // ======================================================== the grouping rule
  group('tableKotGroups — 1.8', () {
    test('one block per numbered order in bill order, un-numbered lines trail', () {
      final groups = m.tableKotGroups(_bill(['o-1', 'o-2', 'o-3']), _threeOrders)!;
      expect(groups.map((g) => g.label).toList(), ['KOT 5', 'KOTs 7, 9', 'No KOT number']);
      expect(groups.map((g) => g.numbered).toList(), [true, true, false]);
      expect(groups[0].orderIds, ['o-1']);
      expect(groups[0].items.map((i) => i['name']).toList(), ['Gin & Tonic', 'Tandoori Roti']);
      // The kitchen note travels with its line.
      expect(groups[0].items[1]['note'], 'less spicy');
      expect(groups[2].orderIds, ['o-2']);
      expect(groups[2].order, isNull, reason: 'the trailing group is not one ticket');
    });

    test('follows the SERVER\'s order_ids order, not the orders feed\'s', () {
      // /orders is newest-first on a live grid; the bill lists created_at asc.
      final groups = m.tableKotGroups(_bill(['o-3', 'o-1']), _threeOrders.reversed.toList())!;
      expect(groups.map((g) => g.label).toList(), ['KOTs 7, 9', 'KOT 5']);
    });

    test('several un-numbered orders share ONE trailing group, oldest time on it', () {
      final orders = [
        _order('a', at: '2026-09-13T09:10:00Z', items: [_line('Chai')]),
        _order('b', kotNos: [3], at: '2026-09-13T09:20:00Z', items: [_line('Dal')]),
        _order('c', at: '2026-09-13T09:30:00Z', items: [_line('Roti', qty: 2)]),
      ];
      final groups = m.tableKotGroups(_bill(['a', 'b', 'c']), orders)!;
      expect(groups.map((g) => g.label).toList(), ['KOT 3', 'No KOT number']);
      expect(groups.last.orderIds, ['a', 'c']);
      expect(groups.last.items.map((i) => i['name']).toList(), ['Chai', 'Roti']);
      expect(groups.last.placedAt, '2026-09-13T09:10:00Z');
    });

    test('orders the bill does not list are not drawn', () {
      final groups = m.tableKotGroups(_bill(['o-1']), _threeOrders)!;
      expect(groups, hasLength(1));
      expect(groups.single.label, 'KOT 5');
    });

    test('header is "KOT n · hh:mm" on the restaurant clock', () {
      final g = m.tableKotGroups(_bill(['o-1']), _threeOrders)!.single;
      expect(g.header, 'KOT 5 · ${RestaurantTime.clock('2026-09-13T09:27:00Z')}');
      final noTime = m.tableKotGroups(_bill(['x']), [_order('x', kotNos: [2], at: '')])!.single;
      expect(noTime.header, 'KOT 2');
    });

    test('CLIENT ITEM 4 — a moved ticket says where it came from, after the time', () {
      final moved = {..._order('o-1', kotNos: [65]), 'moved_from': '12', 'moved_at': '2026-09-13T09:30:00Z'};
      final g = m.tableKotGroups(_bill(['o-1']), [moved])!.single;
      expect(g.header, 'KOT 65 · ${RestaurantTime.clock('2026-09-13T09:27:00Z')} · from 12');
      expect(g.label, 'KOT 65', reason: 'the label stays the handle the pass quotes');
      final undated = m.tableKotGroups(_bill(['x']), [{..._order('x', kotNos: [2], at: ''), 'moved_from': '15'}])!.single;
      expect(undated.header, 'KOT 2 · from 15');
    });

    test('zero, negative and duplicate KOT numbers are not numbers', () {
      final groups = m.tableKotGroups(_bill(['a', 'b']), [
        {..._order('a'), 'kot_nos': [0, -1, 'x']},
        {..._order('b'), 'kot_nos': [4, 4]},
      ])!;
      expect(groups.map((g) => g.label).toList(), ['KOT 4', 'No KOT number']);
    });

    test('lines nested under `food` (older rows) are read too', () {
      final groups = m.tableKotGroups(_bill(['a']), [
        {
          'id': 'a',
          'kot_nos': [8],
          'food': {
            'items': [
              {'item_name': 'Lassi', 'qty': 3, 'price': 90},
            ],
          },
        },
      ])!;
      expect(groups.single.items.single['name'], 'Lassi');
      expect(groups.single.items.single['quantity'], 3);
    });

    test('NULL — draw the flat list — whenever the split cannot be complete', () {
      expect(m.tableKotGroups(null, _threeOrders), isNull);
      expect(m.tableKotGroups(_bill(['o-1']), null), isNull, reason: 'orders feed failed');
      expect(m.tableKotGroups({'items': const []}, _threeOrders), isNull, reason: 'older backend');
      expect(m.tableKotGroups(_bill(['o-1', 'o-404']), _threeOrders), isNull,
          reason: 'a bill order missing from the feed would silently drop its lines');
    });
  });

  // ======================================================== the preview itself
  group('the table preview — 1.8 headers and 1.3 Cancel KOT', () {
    testWidgets('separate KOT blocks with headers; Cancel KOT on numbered blocks only',
        (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders), actions: const ['*']);
      await _openT1(tester, api);

      expect(_header(5), findsOneWidget);
      expect(_header(7), findsOneWidget);
      expect(_header('none'), findsOneWidget);
      expect(find.text('KOT 5 · ${RestaurantTime.clock('2026-09-13T09:27:00Z')}'), findsOneWidget);
      expect(find.text('1 × Tandoori Roti'), findsOneWidget);
      expect(find.text('less spicy'), findsOneWidget);
      // Order of the blocks on screen: KOT 5, then KOTs 7, 9, then the trailing group.
      final y5 = tester.getTopLeft(_header(5)).dy;
      final y7 = tester.getTopLeft(_header(7)).dy;
      final yNone = tester.getTopLeft(_header('none')).dy;
      expect(y5 < y7 && y7 < yNone, isTrue);

      expect(_cancel(5), findsOneWidget);
      expect(_cancel(7), findsOneWidget);
      expect(_cancel('none'), findsNothing);
    });

    testWidgets('fits a phone: headers and Cancel KOT lay out without overflow at 390px',
        (tester) async {
      final routes = _routes(orders: _threeOrders);
      // Target APC off: the Bill card's covers / APC / target APC row under the
      // blocks is not part of this change and does not fit three four-digit
      // amounts at 390px on its own.
      (routes['/bill-for-table'] as Map)['target_apc'] = 0;
      final api = _FakeApi(routes, actions: const ['*']);
      await _openT1(tester, api, size: const Size(390, 3000));
      expect(_header(5), findsOneWidget);
      expect(_cancel(5), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cancel KOT asks for the reason, voids through the existing route, and refreshes',
        (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders), actions: const ['*']);
      await _openT1(tester, api);
      final billReadsBefore = api.calls.where((c) => c.startsWith('GET /bill-for-table')).length;

      await tester.ensureVisible(_cancel(5));
      await tester.tap(_cancel(5));
      await tester.pumpAndSettle();
      // 1.2 — nothing has been written before the reason is given.
      expect(find.byKey(const ValueKey('capture-reason')), findsOneWidget);
      expect(api.writes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('capture-kind-wrong_entry')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'Rung on the wrong table');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('capture-confirm')));
      await tester.pumpAndSettle();

      expect(api.writes.map((w) => '${w.method} ${w.path}').toList(), ['POST /orders/o-1/void']);
      final body = api.writes.single.body as Map;
      expect(body['reason'], 'Rung on the wrong table');
      expect(body['void_kind'], 'wrong_entry');
      expect(api.calls.where((c) => c.startsWith('GET /bill-for-table')).length,
          greaterThan(billReadsBefore), reason: 'the preview is re-read after a cancel');
    });

    testWidgets('dismissing the reason prompt cancels nothing', (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders), actions: const ['*']);
      await _openT1(tester, api);
      await tester.ensureVisible(_cancel(7));
      await tester.tap(_cancel(7));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-reason')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
    });

    testWidgets('CLIENT ITEM 3 — a waiter-only login sees the tickets and no Cancel KOT, whatever it holds',
        (tester) async {
      final setups = <({List<String> actions, bool? cancelKot})>[
        // The server's answer…
        (actions: const [_addOrders], cancelKot: false),
        // …and against a backend older than the flag, the same answer worked out.
        (actions: const [_addOrders], cancelKot: null),
        // A waiter granted Void Orders loses it too: the role, not the grant.
        (actions: const [_addOrders, 'c1f83b26-5a97-4e40-b8d3-7e02a9c4f156'], cancelKot: null),
      ];
      for (final setup in setups) {
        final api = _FakeApi(_routes(orders: _threeOrders),
            actions: setup.actions, role: 'waiter', waiterOnly: true, cancelKot: setup.cancelKot);
        await _openT1(tester, api);
        expect(_header(5), findsOneWidget);
        expect(_header(7), findsOneWidget);
        expect(_cancel(5), findsNothing);
        expect(_cancel(7), findsNothing);
        expect(find.text('Cancel KOT'), findsNothing);
        expect(api.writes, isEmpty);
      }
    });

    testWidgets('the server\'s cancel_kot is obeyed in both directions', (tester) async {
      final no = _FakeApi(_routes(orders: _threeOrders), actions: const [_addOrders],
          role: 'manager', waiterOnly: false, cancelKot: false);
      await _openT1(tester, no);
      expect(_cancel(5), findsNothing);
      final yes = _FakeApi(_routes(orders: _threeOrders), actions: const [_addOrders],
          role: 'captain', waiterOnly: false, cancelKot: true);
      await _openT1(tester, yes);
      expect(_cancel(5), findsOneWidget);
    });

    testWidgets('a floor role that is not a waiter-only login, holding Add Orders, cancels on the plain route, with the reason',
        (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders),
          actions: const [_addOrders], role: 'captain', waiterOnly: false);
      await _openT1(tester, api);
      expect(_cancel(5), findsOneWidget);

      await tester.ensureVisible(_cancel(5));
      await tester.tap(_cancel(5));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-authoriser')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'Guest left');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('capture-confirm')));
      await tester.pumpAndSettle();

      expect(api.writes.map((w) => '${w.method} ${w.path}').toList(), ['PATCH /orders/o-1/status']);
      final body = api.writes.single.body as Map;
      expect(body['status'], 'Cancelled');
      expect(body['reason'], 'Guest left');
    });

    testWidgets('somebody who can take neither cancel route sees the blocks but no Cancel KOT',
        (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders), actions: const ['view-only'], role: 'captain');
      await _openT1(tester, api);
      expect(_header(5), findsOneWidget);
      expect(_cancel(5), findsNothing);
      expect(_cancel(7), findsNothing);
    });

    testWidgets('an orders feed that cannot account for the bill draws the flat list', (tester) async {
      final api = _FakeApi(_routes(orders: _threeOrders, orderIds: const ['o-1', 'o-404']),
          actions: const ['*']);
      await _openT1(tester, api);
      expect(_header(5), findsNothing);
      expect(_cancel(5), findsNothing);
      // Every bill line is still there.
      expect(find.text('1 × Gin & Tonic'), findsOneWidget);
      expect(find.text('1 × Jackfruit Biryani'), findsOneWidget);
    });

    testWidgets('no orders feed at all (older backend / offline) draws the flat list', (tester) async {
      final api = _FakeApi(_routes(), actions: const ['*']);
      await _openT1(tester, api);
      expect(_header(5), findsNothing);
      expect(find.text('1 × Subz Tehri'), findsOneWidget);
    });
  });
}
