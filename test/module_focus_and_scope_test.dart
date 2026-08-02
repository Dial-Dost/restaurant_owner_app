import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Serves canned responses in place of the network, so a module can be pumped
/// exactly as the shell builds it. Payloads below are copied from live
/// csrorganics responses.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

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
    calls.add('$method $path');
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

// Live shape of GET /orders/scope while viewing CSR Organics - Branch 2.
const _branch2Scope = <String, dynamic>{
  'outlet': {'id': '58373382', 'name': 'CSR Organics - Branch 2'},
  'is_all_outlets': false,
  'live_orders': 0,
  'other_outlet_orders': 46,
  'outlets': [
    {'outlet_id': 'a5390f5a', 'outlet_name': 'CSR Organics Main Outlet', 'live_orders': 46, 'tables': 16, 'is_current': false},
    {'outlet_id': '58373382', 'outlet_name': 'CSR Organics - Branch 2', 'live_orders': 0, 'tables': 0, 'is_current': true},
  ],
  'live_window_days': 3,
  'current_outlet_has_tables': false,
};

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(
  Widget child, {
  List<String> visible = const ['Orders', 'Bookings', 'Waitlist', 'Tables', 'History'],
  ModuleFocusRequest? focus,
  void Function(String)? switchOutlet,
  OpenModuleCallback? openModule,
  VoidCallback? clearFocus,
}) =>
    MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: openModule ?? (_, {Map<String, dynamic>? target}) {},
        visibleLabels: visible,
        clearFocus: clearFocus ?? () {},
        focus: focus,
        switchOutlet: switchOutlet,
        child: child,
      ),
    );

void main() {
  testWidgets('BUG 3: an empty orders grid says where the orders actually are', (tester) async {
    final api = _FakeApi({'/orders': <dynamic>[], '/orders/scope': _branch2Scope});
    final rest = await _signIn(api);
    final switched = <String>[];

    await tester.pumpWidget(_host(
      m.ordersModule(rest, rest.auth.profile!),
      switchOutlet: switched.add,
    ));
    await tester.pumpAndSettle();

    // Never a bare empty list.
    expect(find.textContaining('No orders in CSR Organics - Branch 2'), findsOneWidget);
    expect(find.textContaining('46 live orders are in CSR Organics Main Outlet'), findsOneWidget);
    // The outlet with no tables can never receive a guest QR order — say so.
    expect(find.textContaining("no tables yet"), findsOneWidget);
    // Settled orders past the live window are in History, not lost.
    expect(find.textContaining('older than 3 days move to History'), findsOneWidget);

    // And the way out actually works.
    await tester.tap(find.text('Switch outlet'));
    await tester.pump();
    expect(switched, ['a5390f5a']);

    await tester.tap(find.text('View all outlets'));
    await tester.pump();
    expect(switched, ['a5390f5a', 'all']);

    expect(api.calls, contains('GET /orders/scope'));
  });

  testWidgets('BUG 3: single-outlet tenants see no outlet chrome', (tester) async {
    final api = _FakeApi({
      '/orders': <dynamic>[],
      '/orders/scope': <String, dynamic>{
        'outlet': {'id': 'a', 'name': 'Solo'},
        'is_all_outlets': false,
        'live_orders': 0,
        'other_outlet_orders': 0,
        'outlets': [
          {'outlet_id': 'a', 'outlet_name': 'Solo', 'live_orders': 0, 'tables': 4, 'is_current': true},
        ],
        'live_window_days': 3,
        'current_outlet_has_tables': true,
      },
    });
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.text('No orders yet'), findsOneWidget);
    expect(find.textContaining('No orders in'), findsNothing);
    expect(find.text('Switch outlet'), findsNothing);
  });

  testWidgets('BUG 6: an order notification focuses that order', (tester) async {
    final api = _FakeApi({
      '/orders': [
        {'id': 'ord-1', 'table': 'T1', 'customer': 'A', 'status': 'Preparing', 'items': [], 'total': 100, 'barked_at': '2026-07-26T10:00:00Z'},
        {'id': 'ord-2', 'table': 'T4', 'customer': 'B', 'status': 'Preparing', 'items': [], 'total': 200, 'barked_at': '2026-07-26T10:00:00Z'},
      ],
      '/orders/scope': _branch2Scope,
    });
    final rest = await _signIn(api);
    final opened = <String>[];

    await tester.pumpWidget(_host(
      m.ordersModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(
        moduleLabel: 'Orders',
        // Exactly what a live QR-order notification carries.
        target: {'table': 'T4', 'order_id': 'ord-2', 'needs_approval': false, 'entity_id': 'ord-2', 'entity_type': 'order'},
        serial: 1,
      ),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:${target?['table']}'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Showing the order from your notification.'), findsOneWidget);
    expect(find.text('From your notification'), findsOneWidget);
    // Focused order sorted to the top.
    final tables = tester.widgetList<Text>(find.textContaining('Table ')).map((t) => t.data).toList();
    expect(tables.first, 'Table T4');
    // One hop to the table that owns the bill.
    await tester.tap(find.text('Open T4'));
    await tester.pump();
    expect(opened, ['Tables:T4']);
  });

  testWidgets('BUG 6: an order that is not in the list says so instead of looking empty', (tester) async {
    final api = _FakeApi({
      '/orders': [
        {'id': 'ord-1', 'table': 'T1', 'customer': 'A', 'status': 'Preparing', 'items': [], 'total': 100, 'barked_at': 'x'},
      ],
      '/orders/scope': _branch2Scope,
    });
    final rest = await _signIn(api);
    final opened = <String>[];
    var cleared = 0;

    await tester.pumpWidget(_host(
      m.ordersModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(moduleLabel: 'Orders', target: {'order_id': 'gone'}, serial: 2),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add(label),
      clearFocus: () => cleared++,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("That order isn't in this list"), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pump();
    expect(opened, ['History']);
    // The banner is dismissible.
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('BUG 6: a past booking is reachable from its notification', (tester) async {
    // /get-bookings hides bookings whose slot has ended, so the default list
    // cannot contain the notification's booking.
    // The module sends the window as a query param; _FakeApi matches the path
    // EXACTLY, so stubbing the bare path silently missed and this test asserted
    // against an error state rather than the banner it was written for.
    final api = _FakeApi({'/get-bookings?window=upcoming': <dynamic>[]});
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(
      m.bookingsModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(moduleLabel: 'Bookings', target: {'booking_id': 'bk-past'}, serial: 3),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('time slot has already passed'), findsOneWidget);
    // The escape hatch out of the upcoming-only window. Asserted by its real
    // label -- the stale one this test carried ('Include past') never failed,
    // because the stub mismatch above meant the banner was never reached.
    expect(find.text('Show all bookings'), findsOneWidget);
  });

  testWidgets('BUG 6: a seated party explains that it left the queue', (tester) async {
    final api = _FakeApi({
      '/waitlist': {'entries': <dynamic>[]},
      '/get-tables': <dynamic>[],
    });
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(
      m.waitlistModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(moduleLabel: 'Waitlist', target: {'waitlist_id': 'wl-1'}, serial: 4),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('That party has left the queue'), findsOneWidget);
  });

  testWidgets('BUG 6: a table notification rings the right table box', (tester) async {
    final api = _FakeApi({
      // apc_status stays 'neutral': an occupied table that ALSO shows an APC tick
      // overflows its 168px box by ~49px — a pre-existing layout bug in
      // _TableBox, reproducible with no focus request at all, so it is left
      // alone here rather than silently absorbed into this change.
      '/get-tables': [
        {'table_name': 'T1', 'occupied': false},
        {'table_name': 'T4', 'occupied': true, 'covers': 2, 'table_total': 500, 'table_apc': 250, 'apc_status': 'neutral'},
      ],
      '/table-assignments': <dynamic>[],
    });
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(
      m.tablesModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(moduleLabel: 'Tables', target: {'table': 'T4'}, serial: 5),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Highlighted T4'), findsOneWidget);
  });

  // BUG 16/17: `focusId == null ? rows : [...rows]..sort(cmp)` parses as
  // `(focusId == null ? rows : [...rows])..sort(cmp)` — the cascade binds to the
  // WHOLE conditional. With nothing focused that sorted the server's own list in
  // place with a comparator returning 0 for every pair, and List.sort drops
  // stable insertion sort above 32 elements, so it permuted. Both lists arrive
  // already ordered by the server, so both must come back untouched.
  testWidgets('BUG 16: 40 unfocused bookings keep the order the server sent', (tester) async {
    final rows = [
      for (var i = 0; i < 40; i++)
        <String, dynamic>{
          'booking_id': 'bk-${i.toString().padLeft(2, '0')}',
          'customer_name': 'Guest ${i.toString().padLeft(2, '0')}',
          'status': 'Confirmed',
          'booking_date_time': '2026-08-0${(i % 9) + 1}T18:30:00Z',
          'number_of_people': 2,
        },
    ];
    // Snapshotted BEFORE pumping: the module is handed this very list, so an
    // in-place sort would permute the expectation alongside the rendering and
    // the assertion would pass against the bug.
    final expected = [for (final b in rows) b['customer_name'] as String];
    final api = _FakeApi({'/get-bookings?window=upcoming': rows});
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(m.bookingsModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    final shown = tester.widgetList<Text>(find.textContaining('Guest ')).map((t) => t.data).toList();
    expect(shown, expected);
  });

  testWidgets('BUG 17: 40 unfocused queue entries keep the order the server sent', (tester) async {
    final entries = [
      for (var i = 1; i <= 40; i++)
        <String, dynamic>{
          'id': 'wl-${i.toString().padLeft(2, '0')}',
          'name': 'Walkin ${i.toString().padLeft(2, '0')}',
          'position': i,
          'party_size': 2,
          'status': 'waiting',
        },
    ];
    // Snapshotted before pumping — `_entries` IS this list (see above).
    final expected = [for (final e in entries) e['name'] as String];
    final api = _FakeApi({
      '/waitlist': {'entries': entries},
      '/get-tables': <dynamic>[],
    });
    final rest = await _signIn(api);

    // Tall enough that the lazy ListView builds a meaningful slice of the queue.
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    final shown = tester.widgetList<Text>(find.textContaining('Walkin ')).map((t) => t.data).toList();
    // The queue is a lazy ListView, so only the built prefix is assertable —
    // but it must be the server's prefix, and position 1 must be at the head.
    expect(shown, isNotEmpty);
    expect(shown, expected.take(shown.length));
  });

  // BUG 18: the tile forwarded {'apc_status': 'below_target'}. The shell parks
  // ANY non-empty target as a focus request, and Tables resolves a table NAME,
  // so the tap landed on the floor plan under "That table is not on this floor
  // plan". A tile that filters nothing must navigate carrying nothing.
  testWidgets('BUG 18: the below-target tile opens Tables with no focus payload', (tester) async {
    final api = _FakeApi({
      '/get-tables': [
        {'table_name': 'T1', 'occupied': true, 'apc_status': 'red'},
        {'table_name': 'T2', 'occupied': false, 'apc_status': 'green'},
      ],
    });
    final rest = await _signIn(api);
    final opened = <String>[];

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:$target'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TABLES BELOW TARGET'));
    await tester.pump();
    expect(opened, ['Tables:null']);
  });

  testWidgets('a module ignores a focus request aimed at another module', (tester) async {
    final api = _FakeApi({'/orders': <dynamic>[], '/orders/scope': _branch2Scope});
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(
      m.ordersModule(rest, rest.auth.profile!),
      focus: const ModuleFocusRequest(moduleLabel: 'Bookings', target: {'booking_id': 'b1'}, serial: 6),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('from your notification'), findsNothing);
  });
}
