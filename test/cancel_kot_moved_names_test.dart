// CLIENT ITEMS 3 AND 4 (2026-09-17), on the screens a floor actually uses.
//
// ITEM 3 — "On the waiter dashboard, Cancel KOT option should be removed."
//   A waiter-only login: no Cancel KOT on the table sheet, no "Cancelled" on a
//   ticketed order's stage sheet — and still "Decline" on a Pending (QR) order,
//   on the plain route even when the tenant granted it Void Orders. A senior
//   role loses nothing. If the server refuses anyway (a role changed mid-shift),
//   its sentence is what the person sees.
//
// ITEM 4 — "…no item names visible when an order is moved from one table to
//   another." The Move-an-order picker, confirm and result name the ticket and
//   its dishes; a move between two printed bills offers BOTH reprints; a dish
//   move names the dish and its docket, and a comp is refused in the server's
//   words; the Orders screen says what a move took off a ticket and where a
//   ticket came from; the table sheet heads a moved ticket "· from 12".
//
// Every widget case runs on TargetPlatform.windows AND android, in BOTH design
// systems (Rustic Fork and Gaia); the phone cases at 360dp.

import 'dart:io';

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
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

const _addOrders = '4ad474d4-5230-449c-874f-6a238b833bca';
const _tableOcc = '090ea8d4-e348-4e1b-9723-11131a73a085';
const _voidOrder = 'c1f83b26-5a97-4e40-b8d3-7e02a9c4f156';
// database_supabase.ts CORE_ROLES.waiter — the stock waiter's resolved actions.
const _waiterActions = [
  _addOrders, _tableOcc, 'c7699d46-0e2f-4448-b325-8ca490a5296b', 'b7f78d0f-323d-4622-8d05-aa2f82d54b2e',
  'f4177b38-77fa-4d8c-9fbd-c4f06bf28610', '98b10bde-802d-4a5b-a726-53a826424f79',
];

Map<String, dynamic> _login({
  required String role,
  required List<String> actions,
  Map<String, dynamic>? scope,
}) =>
    {
      'employeeId': 'emp-$role',
      'restaurantName': 'Gaia Global Vegetarian',
      'restaurantUsername': 'ggv',
      'res_id': 'res-1',
      'outlet_id': 'out-1',
      'employeeUsername': role,
      'emp_Fname': role,
      'role': role,
      'role_all': [role],
      'scope': ?scope,
      'actions_set': actions,
      'action_names': const <String>[],
    };

/// What /auth/employee-login sends a stock waiter from 2.0.2 (sessionCapabilities).
Map<String, dynamic> _waiter({List<String> actions = _waiterActions, bool voidGranted = false}) => _login(
      role: 'waiter',
      actions: [...actions, if (voidGranted) _voidOrder],
      scope: {
        'waiter_only': true, 'settle_bill': false, 'delete_table': false, 'edit_table': false,
        'manage_table_sections': false, 'comp_item': false, 'waive_service_charge': false,
        'void_order': voidGranted, 'view_roles': false, 'manage_roles': false, 'cancel_kot': false,
      },
    );

Map<String, dynamic> _admin() => _login(role: 'admin', actions: const ['*']);

/// A captain the server still says may cancel — whose cancel the server then refuses.
Map<String, dynamic> _captain() => _login(
      role: 'captain',
      actions: const [_addOrders],
      scope: {'waiter_only': false, 'void_order': false, 'cancel_kot': true},
    );

typedef _Refusal = ({int status, Map<String, dynamic> body});

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, this.profileJson);
  final Map<String, dynamic> routes;
  final Map<String, dynamic> profileJson;
  final List<({String method, String path, Object? body})> writes = [];
  final Map<String, dynamic> writeReplies = {};
  final Map<String, _Refusal> refusals = {};

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult('test-token', Profile.fromJson(profileJson));

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      for (final entry in refusals.entries) {
        if (path.contains(entry.key)) throw ApiException.fromBody(entry.value.body, entry.value.status);
      }
      return writeReplies[path] ?? <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

Widget _host(Widget child, DesignSystem system) => GaiaScope(
      system: system,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: AppColors.bg, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(WidgetTester tester, Map<String, dynamic> routes, Map<String, dynamic> who,
    {required DesignSystem system, required bool orders, Size size = const Size(1400, 3200)}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await AppearanceController.instance.setDesignSystem(system);
  final api = _FakeApi(routes, who);
  final auth = AuthController(api: api);
  await auth.login('GGV', 'x', 'pw');
  final rest = RestClient(auth);
  final p = rest.auth.profile!;
  await tester.pumpWidget(_host(orders ? m.ordersModule(rest, p) : m.tablesModule(rest, p), system));
  await tester.pumpAndSettle();
  return api;
}

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

List<String> _texts(Finder within) => find
    .descendant(of: within, matching: find.byType(Text))
    .evaluate()
    .map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '')
    .toList();

// ------------------------------------------------------------------ fixtures
// Table 12 at GGV on 2026-09-14: KOT-65 with three dishes, KOT-66 with one.
const _ggvLines = [
  {'id': 'a8fe0bc8', 'name': 'KUNAFA BIRDS NEST', 'price': 489, 'quantity': 1},
  {'id': 'fd41af86', 'name': 'STIR FRIED WATERCHESTNUT', 'price': 419, 'quantity': 1},
  {'id': '43ce3048', 'name': 'TRUFFLE CREAM CHEESE', 'price': 519, 'quantity': 1},
];

Map<String, dynamic> _kot65({String table = '12', String status = 'Preparing'}) => {
      'id': 'o-65',
      'table': table,
      'customer': 'Guest',
      'status': status,
      'created_at': '2026-09-14T10:57:16Z',
      'barked_at': '2026-09-14T10:57:16Z',
      'total': 1427,
      'kot_nos': [65],
      'taken_by_employee_name': 'Vineet Khanna',
      'items': _ggvLines,
    };

Map<String, dynamic> _kot66() => {
      'id': 'o-66',
      'table': '12',
      'customer': 'Guest',
      'status': 'Preparing',
      'created_at': '2026-09-14T11:03:43Z',
      'barked_at': '2026-09-14T11:03:43Z',
      'total': 2336,
      'kot_nos': [66],
      'items': [
        {'id': 'x1', 'name': 'MOCKTAIL DEAL', 'price': 1168, 'quantity': 2, 'note': '1 ares 1 helios'},
      ],
    };

Map<String, dynamic> _pendingQr() => {
      ..._kot66(),
      'id': 'qr-1',
      'table': '14',
      'status': 'Pending',
      'kot_nos': <int>[],
      'barked_at': null,
      'created_at': '2026-09-14T11:10:00Z',
    };

Map<String, dynamic> _table(String name, {bool occupied = true}) => {
      'table_name': name,
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Section A',
      'occupied': occupied,
      'seated': occupied,
      'has_order': occupied,
      'reserved': false,
      'covers': 2,
      'table_total': 0,
      'waiter_name': 'Atsu',
    };

Map<String, dynamic> _bill(List<String> orderIds, List<Map<String, dynamic>> items) => {
      'bill_id': 'bill-12',
      'total_amt': 3763.0,
      'subtotal': 3763.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'tax_total': 0.0,
      'grand_total': 3763.0,
      'covers': 2,
      'apc': 1881.5,
      'target_apc': 0,
      'order_ids': orderIds,
      'items': items,
      'print_count': 0,
    };

Map<String, dynamic> _tablesRoutes({
  required List<Map<String, dynamic>> orders,
  required Map<String, dynamic> bill,
  List<Map<String, dynamic>>? tables,
}) =>
    {
      '/get-tables': tables ?? [_table('12'), _table('15')],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {'sections': [{'section': 'Section A'}], 'unassigned': 0},
      '/bill-for-table': bill,
      '/orders': orders,
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': const <dynamic>[],
    };

/// An instant [minutes] ago — the Orders screen's live grid is about today.
String _ago(int minutes) => DateTime.now().toUtc().subtract(Duration(minutes: minutes)).toIso8601String();


/// Every overflow reported while [body] runs, as "lib/…dart:line:col", sorted.
/// The reports are taken rather than left to fail the test: a phone case
/// compares the SET with and without its data (see the 360dp group).
Future<List<String>> _overflowSites(WidgetTester tester, Future<void> Function() body) async {
  final prior = FlutterError.onError;
  final sites = <String>[];
  FlutterError.onError = (details) {
    final text = details.toString();
    if (!text.contains('overflowed')) {
      prior?.call(details);
      return;
    }
    sites.add(RegExp(r'lib/[A-Za-z0-9_/]+\.dart:\d+:\d+').firstMatch(text)?.group(0) ?? 'unknown');
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  return sites..sort();
}

final _variants = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

const _refusal = <String, dynamic>{
  'error': 'Forbidden',
  'code': 'cancel_needs_senior',
  'details': 'KOT-65 has gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.',
  'allowed_roles': ['admin', 'manager', 'cashier', 'captain'],
  'order_id': 'o-65',
  'kot_nos': [65],
};

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());


  // ============================================================== the wiring
  test('the wiring: every order cancel is _cancelOrder, and only the Pending decline skips the rule', () {
    String read(String rel) => File(rel).readAsStringSync().replaceAll(String.fromCharCode(13), '');
    final mod = read('lib/screens/modules.dart');
    final kots = read('lib/screens/table_kots.dart');
    final capture = read('lib/screens/mis_capture.dart');
    // The rule, in the one cancel.
    expect(mod, contains('if (!pending && profile != null && !_mayCancelKot(profile)) {'));
    expect(mod, contains('if (profile != null && _mayCancelKot(profile) && _mayDo(profile, Capability.voidOrder, _permVoidOrder)) {'));
    // The flag is what decides, with the old answer only as the fallback.
    expect(kots, contains('bool _mayCancelKot(Profile p) => RoleScope.may(\n      p,\n      Capability.cancelKot,'));
    expect(kots, contains('fallback: !RoleScope.isWaiterOnly(p) &&'));
    // Exactly one caller claims "never ticketed": the Pending tile's Decline.
    expect(RegExp(r'pending: true').allMatches(mod).length, 1);
    expect(mod, contains('pending: isPending)'));
    expect(mod, contains("if (mayCancel) 'Cancelled',"));
    // No second writer of an order's Cancelled status, and the void form is
    // reached only through _cancelOrder.
    expect(RegExp(r"'status': 'Cancelled'").allMatches(mod).length, 1);
    expect(RegExp(r'misVoidOrder\(').allMatches(mod).length, 1);
    expect(capture, contains("rest.post('/orders/\$orderId/void'"));
  });

  for (final system in DesignSystem.values) {
    group('[${system.name}]', () {
      // ================================================================= ITEM 3
      testWidgets('ITEM 3 — a waiter-only table sheet shows every ticket and no Cancel KOT', (tester) async {
        final api = await _mount(
          tester,
          _tablesRoutes(orders: [_kot65(), _kot66()], bill: _bill(['o-65', 'o-66'], [..._ggvLines, ..._kot66()['items'] as List<Map<String, dynamic>>])),
          _waiter(voidGranted: true),
          system: system,
          orders: false,
        );
        await tester.tap(find.text('12').first);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('table-kot-header-65')), findsOneWidget);
        expect(find.byKey(const ValueKey('table-kot-header-66')), findsOneWidget);
        expect(find.text('1 × KUNAFA BIRDS NEST'), findsOneWidget);
        expect(find.byKey(const ValueKey('table-kot-cancel-65')), findsNothing);
        expect(find.byKey(const ValueKey('table-kot-cancel-66')), findsNothing);
        expect(_button('Cancel KOT'), findsNothing);
        // Still no money for the waiter.
        expect(find.text('TOTAL PAYABLE'), findsNothing);
        expect(api.writes, isEmpty);
      }, variant: _variants);

      testWidgets('ITEM 3 — waiter-only Orders screen: no "Cancelled" on a ticket\'s stage sheet; "Decline" on a Pending one, on the plain route',
          (tester) async {
        final api = await _mount(tester, {'/orders': [_kot65(), _pendingQr()], '/orders/scope': <String, dynamic>{}},
            _waiter(voidGranted: true), system: system, orders: true);
        // KOT-65's stage sheet.
        await tester.tap(find.text('Table 12').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_button('Change stage'));
        await tester.pumpAndSettle();
        await tester.tap(_button('Change stage'));
        await tester.pumpAndSettle();
        final stageChips = find
            .descendant(of: find.byType(Dialog).last, matching: find.byType(StatusChip))
            .evaluate()
            .map((e) => (e.widget as StatusChip).label)
            .toList();
        expect(stageChips, isNot(contains('Cancelled')));
        expect(stageChips, containsAll(<String>['Preparing', 'Served']));
        expect(find.text('Void this order'), findsNothing);
        await tester.tap(find.descendant(of: find.byType(Dialog).last, matching: _button('Cancel')));
        await tester.pumpAndSettle();
        expect(api.writes, isEmpty);

        // The Pending QR ticket: Decline stays, asks the reason, and goes on the
        // PLAIN route — not the void form, although Void Orders is granted.
        expect(_button('Decline'), findsOneWidget);
        await tester.ensureVisible(_button('Decline'));
        await tester.tap(_button('Decline'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('capture-authoriser')), findsNothing);
        await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'Guest left before approval');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('capture-confirm')));
        await tester.pumpAndSettle();
        expect(api.writes.map((w) => '${w.method} ${w.path}').toList(), ['PATCH /orders/qr-1/status']);
        expect((api.writes.single.body as Map)['status'], 'Cancelled');
      }, variant: _variants);

      testWidgets('ITEM 3 — a waiter-only login\'s Pending stage sheet still offers the decline', (tester) async {
        await _mount(tester, {'/orders': [_pendingQr()], '/orders/scope': <String, dynamic>{}},
            _waiter(), system: system, orders: true);
        await tester.tap(find.text('Table 14').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_button('Change stage'));
        await tester.tap(_button('Change stage'));
        await tester.pumpAndSettle();
        final chips = find
            .descendant(of: find.byType(Dialog).last, matching: find.byType(StatusChip))
            .evaluate()
            .map((e) => (e.widget as StatusChip).label)
            .toList();
        expect(chips, contains('Cancelled'));
      }, variant: _variants);

      testWidgets('ITEM 3 — a senior role keeps "Cancelled" and Cancel KOT', (tester) async {
        await _mount(tester, {'/orders': [_kot65()], '/orders/scope': <String, dynamic>{}}, _admin(),
            system: system, orders: true);
        await tester.tap(find.text('Table 12').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_button('Change stage'));
        await tester.tap(_button('Change stage'));
        await tester.pumpAndSettle();
        final chips = find
            .descendant(of: find.byType(Dialog).last, matching: find.byType(StatusChip))
            .evaluate()
            .map((e) => (e.widget as StatusChip).label)
            .toList();
        expect(chips, contains('Cancelled'));
      }, variant: _variants);

      testWidgets('ITEM 3 — when the server refuses anyway, its sentence is what the person reads', (tester) async {
        final api = await _mount(
          tester,
          _tablesRoutes(orders: [_kot65()], bill: _bill(['o-65'], _ggvLines)),
          _captain(),
          system: system,
          orders: false,
        );
        api.refusals['/orders/o-65/status'] = (status: 403, body: _refusal);
        await tester.tap(find.text('12').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('table-kot-cancel-65')));
        await tester.tap(find.byKey(const ValueKey('table-kot-cancel-65')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'Rang twice');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('capture-confirm')));
        await tester.pump();
        expect(find.text(_refusal['details'] as String), findsOneWidget);
        expect(find.text('Forbidden'), findsNothing);
        await tester.pumpAndSettle();
      }, variant: _variants);

      // ================================================================= ITEM 4
      testWidgets('ITEM 4 — "Move an order": the picker, the confirm and the result name the ticket and its dishes',
          (tester) async {
        final api = await _mount(
          tester,
          _tablesRoutes(orders: [_kot65(), _kot66()], bill: _bill(['o-65', 'o-66'], _ggvLines)),
          _admin(),
          system: system,
          orders: false,
        );
        api.writeReplies['/tables/move-order'] = {
          'success': true, 'order_id': 'o-65', 'from_table': '12', 'to_table': '15', 'kot_no': 65,
          'items': [
            {'name': 'KUNAFA BIRDS NEST', 'variation': null, 'quantity': 1},
            {'name': 'STIR FRIED WATERCHESTNUT', 'variation': null, 'quantity': 1},
            {'name': 'TRUFFLE CREAM CHEESE', 'variation': null, 'quantity': 1},
          ],
          'print': {'printed': true, 'kot_no': 65, 'tickets': 1},
        };
        await tester.tap(find.text('12').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_button('Move an order'));
        await tester.tap(_button('Move an order'));
        await tester.pumpAndSettle();
        expect(find.text('Which order on 12?'), findsOneWidget);
        final picker = _texts(find.byType(SimpleDialog));
        expect(picker, containsAll(<String>[
          'KOT 65 · ₹1427.00',
          '1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE\nThe kitchen has this one',
          'KOT 66 · ₹2336.00',
          '2 × MOCKTAIL DEAL\nThe kitchen has this one',
        ]));
        expect(picker.any((s) => s.contains('item')), isFalse, reason: 'no "3 items" any more');
        await tester.tap(find.byKey(const ValueKey('move-order-pick-o-65')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Table 15'));
        await tester.pumpAndSettle();
        final confirm = _texts(find.byType(AlertDialog).last).join(' | ');
        expect(confirm, contains('Move this order to 15?'));
        expect(confirm, contains('KOT 65: 1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE.'));
        expect(confirm, contains('a correction docket prints for 15 with the same KOT number'));
        await tester.tap(find.text('Confirm'));
        await tester.pump();
        expect(find.text('Moved to 15: 1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT, 1 × TRUFFLE CREAM CHEESE. '
            'Correction docket KOT-65 is printing — tell the pass.'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(api.writes.single.path, '/tables/move-order');
        expect(api.writes.single.body, {'order_id': 'o-65', 'to_table': '15'});
      }, variant: _variants);

      testWidgets('ITEM 4 — a move between two printed bills offers BOTH reprints, this table\'s with its own Print',
          (tester) async {
        final api = await _mount(
          tester,
          _tablesRoutes(orders: [_kot65()], bill: _bill(['o-65'], _ggvLines)),
          _admin(),
          system: system,
          orders: false,
        );
        api.writeReplies['/tables/move-order'] = {
          'success': true, 'items': const [{'name': 'KUNAFA BIRDS NEST', 'quantity': 1}],
          'print': {'printed': false, 'kot_no': null, 'reason': 'disabled'},
          'reprint_needed': true, 'reprint_table': '15',
          'reprint_message': "15's bill was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.",
          'also_reprint_needed': true, 'also_reprint_table': '12',
          'also_reprint_message': "12's bill was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.",
        };
        await tester.tap(find.text('12').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_button('Move an order'));
        await tester.tap(_button('Move an order'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Table 15'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        // First: the destination, with what happened in front of it.
        final first = _texts(find.byKey(const ValueKey('reprint-needed'))).join(' ');
        expect(first, contains('Moved to 15: 1 × KUNAFA BIRDS NEST.'));
        expect(first, contains("15's bill was already printed"));
        await tester.tap(find.byKey(const ValueKey('reprint-needed-action')));
        await tester.pumpAndSettle();
        // Then: this table's own paper.
        final second = _texts(find.byKey(const ValueKey('reprint-needed'))).join(' ');
        expect(second, contains("12's bill was already printed"));
        expect(second, isNot(contains('Moved to')));
        await tester.tap(find.byKey(const ValueKey('reprint-needed-action')));
        await tester.pumpAndSettle();
        final prints = api.writes.where((w) => w.path == '/print/bill').map((w) => (w.body as Map)['table_name']).toList();
        expect(prints, ['15', '12']);
      }, variant: _variants);

      testWidgets('ITEM 4 — "Move to another table" on a dish names it and its docket; a comp is refused in the server\'s words',
          (tester) async {
        final api = await _mount(
          tester,
          _tablesRoutes(
            orders: [
              {..._kot65(table: '31A'), 'items': const [{'id': 'l1', 'name': 'NOT YOUR PUCHKA', 'price': 469, 'quantity': 1}]},
            ],
            tables: [_table('31A'), _table('31')],
            bill: _bill(['o-65'], const [{'name': 'NOT YOUR PUCHKA', 'price': 469, 'quantity': 1}]),
          ),
          _admin(),
          system: system,
          orders: false,
        );
        api.writeReplies['/bills/move-item'] = {
          'success': true,
          'items': const [{'name': 'NOT YOUR PUCHKA', 'variation': null, 'quantity': 1}],
          'prints': const [{'order_id': 'new-1', 'printed': true, 'kot_no': 35, 'tickets': 1}],
          'kot_nos': const [35],
        };
        await tester.tap(find.text('31A').first);
        await tester.pumpAndSettle();
        Future<void> moveIt() async {
          await tester.ensureVisible(find.byTooltip('Edit item').first);
          await tester.tap(find.byTooltip('Edit item').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Move to another table'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Table 31'));
          await tester.pump();
        }

        await moveIt();
        expect(find.text('Moved 1 × NOT YOUR PUCHKA to Table 31. Docket KOT-35 is printing for 31 — tell the pass.'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(api.writes.last.path, '/bills/move-item');
        // Let that line time out, so the next one is not queued behind it.
        await tester.pump(const Duration(seconds: 12));
        await tester.pumpAndSettle();

        api.refusals['/bills/move-item'] = (
          status: 400,
          body: {'error': 'NOT YOUR PUCHKA is non-chargeable on 31A. Reverse the comp first, then move it.'},
        );
        await moveIt();
        expect(find.text('NOT YOUR PUCHKA is non-chargeable on 31A. Reverse the comp first, then move it.'), findsOneWidget);
        await tester.pumpAndSettle();
      }, variant: _variants);

      testWidgets('ITEM 4 — the Orders screen says what a move took off a ticket, and where a ticket came from',
          (tester) async {
        final orders = [
          {
            'id': 'src', 'table': '31A', 'customer': 'Guest', 'status': 'Cancelled', 'total': 0,
            'created_at': _ago(9), 'kot_nos': [35], 'items': <dynamic>[],
            'emptied_by': 'move',
            'moved_items': [
              {'name': 'NOT YOUR PUCHKA', 'variation': null, 'quantity': 1, 'to_table': '31', 'moved_at': '2026-09-14T09:46:31Z'},
            ],
          },
          {
            'id': 'dst', 'table': '31', 'customer': 'Guest', 'status': 'Preparing', 'total': 469,
            'created_at': _ago(3), 'barked_at': _ago(9), 'kot_nos': [35],
            'moved_from': '31A', 'moved_at': '2026-09-14T09:46:31Z',
            'items': [{'id': 'l1', 'name': 'NOT YOUR PUCHKA', 'price': 469, 'quantity': 1}],
          },
        ];
        await _mount(tester, {'/orders': orders, '/orders/scope': <String, dynamic>{}}, _admin(),
            system: system, orders: true);
        // The source: what left it and where — no longer "Guest · 0 item(s)".
        expect(find.byKey(const ValueKey('order-desc-src')), findsOneWidget);
        expect((tester.widget(find.byKey(const ValueKey('order-desc-src'))) as Text).data, 'Moved to 31: 1 × NOT YOUR PUCHKA');
        expect(find.text('Guest · 0 item(s)'), findsNothing);
        // The destination: where it came from.
        expect(find.byKey(const ValueKey('order-moved-from-dst')), findsOneWidget);
        expect(find.text('Moved from 31A'), findsOneWidget);
        expect((tester.widget(find.byKey(const ValueKey('order-desc-dst'))) as Text).data, 'Guest · 1 item(s)');
        // …and the source's sheet says it too.
        await tester.tap(find.text('Table 31A').first);
        await tester.pumpAndSettle();
        expect(find.text('Moved to 31: 1 × NOT YOUR PUCHKA'), findsNWidgets(2));
      }, variant: _variants);

      testWidgets('ITEM 4 — the destination sheet heads the moved dish under its KOT, "from 31A"', (tester) async {
        await _mount(
          tester,
          _tablesRoutes(
            orders: [
              {
                'id': 'dst', 'table': '31', 'customer': 'Guest', 'status': 'Preparing', 'total': 469,
                'created_at': '2026-09-14T09:46:31Z', 'kot_nos': [35], 'moved_from': '31A',
                'items': [{'id': 'l1', 'name': 'NOT YOUR PUCHKA', 'price': 469, 'quantity': 1}],
              },
            ],
            tables: [_table('31'), _table('31A')],
            bill: _bill(['dst'], const [{'name': 'NOT YOUR PUCHKA', 'price': 469, 'quantity': 1}]),
          ),
          _admin(),
          system: system,
          orders: false,
        );
        await tester.tap(find.text('31').first);
        await tester.pumpAndSettle();
        final header = tester.widget<Text>(find.byKey(const ValueKey('table-kot-header-35')));
        expect(header.data, 'KOT 35 · ${RestaurantTime.clock('2026-09-14T09:46:31Z')} · from 31A');
        expect(find.byKey(const ValueKey('table-kot-header-none')), findsNothing,
            reason: 'the moved dish is no longer "not sent to the kitchen"');
      }, variant: _variants);

      // ============================================================ 360dp phone
      //
      // WHAT IS MEASURED. Two screens here overflow at 360dp on origin/main
      // already, with no move anywhere (the Orders screen's section header with
      // a cancelled ticket; the Gaia table sheet's "Edit name / GSTIN" row for an
      // editor) — neither is this change's. So each phone case renders the SAME
      // screen twice, without and with the move data, and demands that the move
      // adds no overflow of its own: the same set of overflow sites, both times,
      // and none of them in a move widget.
      testWidgets('360dp — the "from" header, the picker and the confirm add no overflow', (tester) async {
        Future<List<String>> run({required bool moved}) async {
          final order = {
            ..._kot65(),
            if (moved) 'moved_from': 'Rooftop Terrace 12',
            'items': [
              for (var i = 0; i < 6; i++) {'id': 'l$i', 'name': 'VERY LONG DISH NAME NUMBER $i WITH A SIZE', 'variation': 'Half', 'price': 100, 'quantity': 2},
            ],
          };
          return _overflowSites(tester, () async {
            await _mount(
              tester,
              _tablesRoutes(orders: [order, _kot66()], bill: _bill(['o-65', 'o-66'], _ggvLines)),
              _admin(),
              system: system,
              orders: false,
              size: const Size(360, 3200),
            );
            await tester.tap(find.text('12').first);
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('table-kot-header-65')), findsOneWidget);
            await tester.ensureVisible(_button('Move an order'));
            await tester.tap(_button('Move an order'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('move-order-dishes-o-65')), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('move-order-pick-o-65')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Table 15'));
            await tester.pumpAndSettle();
            expect(find.text('Move this order to 15?'), findsOneWidget);
            await tester.tap(find.text('Cancel').last);
            await tester.pumpAndSettle();
          });
        }

        final plain = await run(moved: false);
        final moved = await run(moved: true);
        expect(moved, plain, reason: 'the move data adds no overflow site');
        expect(moved.where((s) => s.contains('table_kots.dart') || s.contains('order_moves.dart')), isEmpty);
      }, variant: _variants);

      testWidgets('360dp — the Orders screen\'s moved tiles add no overflow', (tester) async {
        Future<List<String>> run({required bool moved}) {
          final orders = [
            {
              'id': 'src', 'table': '31A', 'customer': 'Guest', 'status': 'Cancelled', 'total': 0,
              'created_at': _ago(9), 'items': <dynamic>[],
              if (moved) 'emptied_by': 'move',
              if (moved)
                'moved_items': [
                  for (var i = 0; i < 4; i++) {'name': 'A VERY LONG DISH NAME $i', 'quantity': 3, 'to_table': i.isEven ? '31' : 'Patio 40'},
                ],
            },
            {..._kot65(), 'id': 'dst', 'created_at': _ago(3), if (moved) 'moved_from': 'Rooftop Terrace 31A'},
          ];
          return _overflowSites(tester, () async {
            await _mount(tester, {'/orders': orders, '/orders/scope': <String, dynamic>{}}, _waiter(),
                system: system, orders: true, size: const Size(360, 3200));
            expect(find.byKey(const ValueKey('order-desc-src')), findsOneWidget);
            expect(find.byKey(const ValueKey('order-moved-from-dst')), moved ? findsOneWidget : findsNothing);
          });
        }

        final plain = await run(moved: false);
        final moved = await run(moved: true);
        expect(moved, plain, reason: 'the move data adds no overflow site');
      }, variant: _variants);
    });
  }
}
