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

/// Four changes are pinned here:
///   * the numbered run behind "Add table · how many", which must step OVER
///     names the floor already has rather than collide with them,
///   * a portrait phone keeping at least two table cards per row,
///   * the outlet and attendance cards opening a detail sheet instead of
///     swallowing the tap,
///   * Inventory grouped into its category sections, empty ones included.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// Every write the tests provoke, in order: `'POST /add-table T2'`.
  final List<String> calls = [];

  /// Table name the fake server refuses, to exercise a batch that dies midway.
  String failOnTable = '';

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
    if (method != 'GET') {
      final table = (body is Map && body['table'] is Map) ? '${(body['table'] as Map)['name']}' : '';
      calls.add('$method $path${table.isEmpty ? '' : ' $table'}');
      if (table.isNotEmpty && table == failOnTable) throw ApiException('Table exists', 400);
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Tables', 'Outlets', 'Attendance', 'Inventory'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _size(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<_FakeApi> _mount(
    WidgetTester tester, Widget Function(RestClient) module, Map<String, dynamic> routes) async {
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(module(rest)));
  await tester.pumpAndSettle();
  return api;
}

Map<String, dynamic> _table(String name, {String section = 'Main', int capacity = 4}) => {
      'table_name': name,
      'capacity': capacity,
      'max_capacity': capacity,
      'section': section,
      'occupied': false,
      'reserved': false,
    };

Map<String, dynamic> _tableRoutes(List<Map<String, dynamic>> tables) => {
      '/get-tables': tables,
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
    };

void main() {
  // --- 1. The allocator ------------------------------------------------------
  // Pure logic and the whole point of the feature ("keep assigning whatever next
  // number is free"), so it is tested directly rather than through the dialog.

  group('allocateTableNames', () {
    test('numbers straight on from the seed when nothing is taken', () {
      final run = m.allocateTableNames('T1', 3, const []);
      expect(run.names, ['T1', 'T2', 'T3']);
      expect(run.skipped, isEmpty);
    });

    test('skips the numbers already on the floor and keeps going', () {
      // The explicit requirement: T1 and T3 exist, so five from T1 must be
      // T2, T4, T5, T6, T7 — not five collisions and not a short run.
      final run = m.allocateTableNames('T1', 5, const ['T1', 'T3']);
      expect(run.names, ['T2', 'T4', 'T5', 'T6', 'T7']);
      expect(run.skipped, ['T1', 'T3'], reason: 'what was stepped over has to be reportable');
    });

    test('matches existing names case-insensitively, the way the backend does', () {
      final run = m.allocateTableNames('t1', 2, const ['T1']);
      expect(run.names, ['t2', 't3']);
      expect(run.skipped, ['t1']);
    });

    test('splits a multi-word prefix and keeps its spacing', () {
      final run = m.allocateTableNames('Patio 4', 3, const ['Patio 5']);
      expect(run.names, ['Patio 4', 'Patio 6', 'Patio 7']);
    });

    test('appends a number when the seed has none', () {
      expect(m.allocateTableNames('Bar', 3, const []).names, ['Bar1', 'Bar2', 'Bar3']);
    });

    test('keeps zero padding, and does not truncate when the run outgrows it', () {
      expect(m.allocateTableNames('T08', 4, const []).names, ['T08', 'T09', 'T10', 'T11']);
    });

    test('a run of one is just that one name', () {
      expect(m.allocateTableNames('T9', 1, const ['T9', 'T10']).names, ['T11']);
    });

    test('a blank seed or a non-positive count allocates nothing', () {
      expect(m.allocateTableNames('   ', 3, const []).names, isEmpty);
      expect(m.allocateTableNames('T1', 0, const []).names, isEmpty);
    });

    test('a duplicate inside the run itself cannot be issued twice', () {
      // Two identical seeds would collide on the server; the allocator's own
      // bookkeeping has to treat a name it just issued as taken.
      final run = m.allocateTableNames('T1', 3, const ['T2', 't2']);
      expect(run.names, ['T1', 'T3', 'T4']);
      expect(run.skipped, ['T2']);
    });
  });

  // --- 2. The run, end to end ------------------------------------------------

  testWidgets('Add table: the dialog previews the run and POSTs only the free names',
      (tester) async {
    _size(tester, 1400, 1000);
    final api = await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!),
        _tableRoutes([_table('T1'), _table('T3')]));

    await tester.tap(find.text('Add table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Table name (e.g. T7)'), 'T1');
    await tester.enterText(find.widgetWithText(TextField, 'How many'), '3');
    await tester.pumpAndSettle();

    // The preview answers "why did I get T4 when I typed T1?" before any write.
    expect(find.text('Creates T2, T4, T5'), findsOneWidget);
    expect(find.text('Skips T1, T3 — already on the floor'), findsOneWidget);

    await tester.tap(find.text('Add 3 tables'));
    await tester.pumpAndSettle();

    expect(api.calls, ['POST /add-table T2', 'POST /add-table T4', 'POST /add-table T5']);
    // And the run reports itself rather than leaving the owner to count.
    expect(find.text('Added 3 tables'), findsOneWidget);
    expect(find.text('T2, T4, T5'), findsOneWidget);
    expect(find.text('T1, T3 — already on the floor'), findsOneWidget);
  });

  testWidgets('Add table: one table still creates exactly the name typed', (tester) async {
    _size(tester, 1400, 1000);
    final api = await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!), _tableRoutes([_table('T1')]));

    await tester.tap(find.text('Add table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Table name (e.g. T7)'), 'Patio');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // Not "Patio1": a single add is the old path, untouched.
    expect(api.calls, ['POST /add-table Patio']);
  });

  testWidgets('Add table: a batch the server rejects midway says what got through',
      (tester) async {
    _size(tester, 1400, 1000);
    final api = await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!), _tableRoutes([_table('T1')]));
    api.failOnTable = 'T4';

    await tester.tap(find.text('Add table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Table name (e.g. T7)'), 'T2');
    await tester.enterText(find.widgetWithText(TextField, 'How many'), '4');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 4 tables'));
    await tester.pumpAndSettle();

    // Stopped at the rejection instead of firing the rest at a server that just
    // refused, and every name is accounted for on screen.
    expect(api.calls, ['POST /add-table T2', 'POST /add-table T3', 'POST /add-table T4']);
    expect(find.text('Added 2 tables'), findsOneWidget);
    expect(find.text('T2, T3'), findsOneWidget);
    expect(find.textContaining('T4 — '), findsOneWidget);
    expect(find.text('T5'), findsOneWidget); // not attempted
  });

  // --- 3. Portrait phone -----------------------------------------------------

  testWidgets('Tables: a portrait phone puts two cards side by side, still legible',
      (tester) async {
    _size(tester, 390, 844); // a real phone in portrait
    await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!),
        _tableRoutes([_table('T1'), _table('T2'), _table('T3'), _table('T4')]));

    expect(tester.takeException(), isNull, reason: 'the floor plan must not overflow at 390px');

    final first = tester.getRect(find.text('T1'));
    final second = tester.getRect(find.text('T2'));
    final third = tester.getRect(find.text('T3'));
    expect(second.top, first.top, reason: 'T2 must sit beside T1, not underneath it');
    expect(second.left, greaterThan(first.right));
    // Two across, not three squeezed in.
    expect(third.top, greaterThan(first.top));

    // Legible: the name, the seat count and the status are all still on the card.
    expect(find.text('Free'), findsNWidgets(4));
    expect(find.text('4 seats'), findsNWidgets(4));

    // And the card's actions are still reachable — the tap opens the table sheet.
    await tester.tap(find.text('T1'));
    await tester.pumpAndSettle();
    expect(find.text('Delete table'), findsOneWidget);
  });

  testWidgets('Tables: a desktop window keeps the 168px design width', (tester) async {
    _size(tester, 1400, 1000);
    await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!),
        _tableRoutes([_table('T1'), _table('T2')]));

    final first = tester.getRect(find.text('T1'));
    final second = tester.getRect(find.text('T2'));
    // 168 wide + 12 of Wrap spacing between the two cards.
    expect(second.left - first.left, closeTo(180, 0.5));
  });

  // --- 4. Outlet + attendance cards ------------------------------------------

  testWidgets('Outlets: the card opens the outlet detail with its own actions', (tester) async {
    _size(tester, 1400, 1000);
    await _mount(tester, (r) => m.outletsModule(r, r.auth.profile!), {
      '/outlets': {
        'outlets': [
          {
            'id': 'o1',
            'outlet_name': 'Riverside',
            'outlet_add': '14 Marine Drive',
            'outlet_phone': '9812345678',
            'outlet_hours': '11:00 – 23:00',
            'is_default': false,
            'is_active': true,
          },
          {'id': 'o0', 'outlet_name': 'Harbour Main', 'is_default': true, 'is_active': true},
        ],
      },
      '/outlets/rollup?days=30': {
        'totals': {'outlets': 2, 'revenue': 90000, 'orders': 120},
        'outlets': [
          {'name': 'Riverside', 'revenue': 90000},
        ],
      },
    });

    await tester.tap(find.text('Riverside'));
    await tester.pumpAndSettle();

    expect(find.text('MULTI-OUTLET'), findsOneWidget);
    expect(find.text('14 Marine Drive'), findsWidgets);
    expect(find.text('11:00 – 23:00'), findsWidgets);
    // Only actions the backend actually has, and switching stays a named button.
    expect(find.text('Switch to this outlet'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // The outlet being viewed had NO tap at all before; it opens too, and the
    // main outlet still cannot be deleted or deactivated from here.
    await tester.tap(find.text('Harbour Main'));
    await tester.pumpAndSettle();
    expect(find.text('Viewing now'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Deactivate'), findsNothing);
    expect(find.text('Switch to this outlet'), findsNothing);
  });

  testWidgets('Attendance: pending and team cards both open their record', (tester) async {
    _size(tester, 1400, 1000);
    await _mount(tester, (r) => m.attendanceModule(r, r.auth.profile!), {
      '/attendance/me': {'clocked_in': false, 'today_minutes': 0, 'pending_approval': false},
      '/attendance': {
        'from': '2026-07-04',
        'to': '2026-08-03',
        'rows': [
          {'emp_id': 'e2', 'name': 'Rhea Kapoor', 'minutes': 615, 'shifts': 5, 'open': true},
        ],
        'pending': [
          {
            'id': 'a1',
            'emp_id': 'e3',
            'name': 'Sunil Rao',
            'clock_in': '2026-08-03T04:30:00Z',
            'clock_out': null,
          },
        ],
      },
    });

    // The pending shift: full timestamps and the review actions.
    await tester.tap(find.text('Sunil Rao'));
    await tester.pumpAndSettle();
    expect(find.text('ATTENDANCE · PENDING APPROVAL'), findsOneWidget);
    // 04:30 UTC read in the restaurant's zone (Asia/Kolkata) is 10:00.
    expect(find.textContaining('3 Aug 2026, 10:00:00'), findsOneWidget);
    expect(find.text('Still on shift'), findsOneWidget);
    expect(find.text('Approve'), findsWidgets);
    expect(find.text('Reject'), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // The team roll-up: what the server summarised, and the window it covers.
    await tester.tap(find.text('Rhea Kapoor'));
    await tester.pumpAndSettle();
    expect(find.text('ATTENDANCE · TEAM HOURS'), findsOneWidget);
    expect(find.text('10h 15m'), findsWidgets);
    expect(find.text('2h 3m'), findsOneWidget); // average of 5 shifts
    expect(find.text('Jul 4 – Aug 3'), findsOneWidget);
  });

  // --- 5. Inventory sections -------------------------------------------------

  testWidgets('Inventory: items sit under their category, empty categories included',
      (tester) async {
    _size(tester, 1400, 1000);
    await _mount(tester, (r) => m.inventoryModule(r, r.auth.profile!), {
      '/inventory': [
        {'id': 'i1', 'name': 'Tomatoes', 'category': 'Produce', 'stock': 12, 'unit': 'kg', 'status': 'In Stock'},
        {'id': 'i2', 'name': 'Basil', 'category': 'produce', 'stock': 0, 'unit': 'kg', 'status': 'Out of Stock'},
        {'id': 'i3', 'name': 'Napkins', 'stock': 300, 'unit': 'pcs', 'status': 'In Stock'},
      ],
      '/restaurant/settings': {
        'inventory_categories': ['Produce', 'Cleaning'],
      },
    });

    // One heading per category — the differently-cased "produce" is the SAME
    // section, not a second look-alike one.
    expect(find.text('Produce'), findsOneWidget);
    expect(find.text('Tomatoes'), findsOneWidget);
    expect(find.text('Basil'), findsOneWidget);
    // A category on the roster with nothing in it still gets its heading.
    expect(find.text('Cleaning'), findsOneWidget);
    expect(find.text('Nothing in this section yet.'), findsOneWidget);
    // An item with no category is not hidden.
    expect(find.text('Uncategorised'), findsOneWidget);
    expect(find.text('Napkins'), findsOneWidget);
    // Out-of-stock is called out on the section it belongs to.
    expect(find.text('1 needs restocking'), findsOneWidget);
  });
}
