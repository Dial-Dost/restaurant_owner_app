import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// ROLE SCOPING — who sees which module, what their Overview is made of, and
/// which tab they open the app on.
///
/// The case that drives this file: `Roles.actions_performable` is per-tenant
/// JSON, so "waiters cannot see revenue" is NOT a thing the permission gate can
/// promise on its own — a restaurant that ticked "View Order APC" for its
/// waiters has genuinely granted the action, and the server will serve it. So
/// every gating test below is run TWICE, once for a waiter who holds that action
/// and once for a waiter who does not, and both must come out with no money on
/// the screen.

class _FakeApi extends ApiClient {
  _FakeApi(this.profile, [this.routes = const {}]);

  final Map<String, dynamic> profile;
  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult('test-token', Profile.fromJson(profile));

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

// ---- profiles ---------------------------------------------------------------

/// The action names a floor waiter really carries at a tenant that has not
/// granted them anything special. Every one of these is a substring the module
/// registry's keyword lists match on — 'View Menu' matches Menu's ['menu'],
/// 'View Orders' matches Waitlist's ['table', 'order', 'waitlist'] — which is
/// exactly why the keyword gate never hid those three from a waiter.
const _waiterActions = [
  'View Orders',
  'Create Order',
  'View Tables',
  'Occupy Table',
  'View Menu',
  'View Bills',
  'View Bookings',
];

Map<String, dynamic> _profileJson({
  required String role,
  List<String>? roleAll,
  List<String> actionNames = _waiterActions,
  List<String> actions = const ['a1'],
  Map<String, dynamic> features = const {},
  String username = 'ravi',
}) =>
    <String, dynamic>{
      'employeeId': 'emp-uuid-1',
      'employeeUsername': username,
      'restaurantName': 'Gaia Test',
      'emp_Fname': 'Ravi',
      'role': role,
      'role_all': roleAll ?? [role],
      'actions_set': actions,
      'action_names': actionNames,
      'features': features,
      'limits': const {'outlets': 2},
    };

/// A waiter who does NOT hold the analytics action.
final _waiter = Profile.fromJson(_profileJson(role: 'waiter'));

/// The same waiter at a tenant that ticked "View Order APC" for the role. The
/// server WILL serve this identity /orders/apc, /orders/daily-revenue and
/// /analytics/overview — the permission gate is doing what it was told.
final _waiterWithApc = Profile.fromJson(_profileJson(
  role: 'waiter',
  actionNames: [..._waiterActions, 'View Order APC'],
));

final _admin = Profile.fromJson(_profileJson(
  role: 'admin',
  actionNames: const <String>[],
  actions: const ['*'],
));

// ---- hosts ------------------------------------------------------------------

Future<AuthController> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
  return auth;
}

Future<void> _pumpShell(WidgetTester tester, AuthController auth) async {
  // Wide enough for the fixed sidebar (the shell falls back to a drawer < 700).
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump();
}

/// The tab the shell is showing, read off the AppBar (the sidebar carries every
/// label, so it cannot answer "which one is open").
String _activeTab(WidgetTester tester) {
  final titles = find.descendant(of: find.byType(AppBar), matching: find.byType(Text));
  return tester.widgetList<Text>(titles).first.data!;
}

Widget _host(
  Widget child, {
  required List<String> visible,
  OpenModuleCallback? openModule,
  DesignSystem system = DesignSystem.rustic,
}) =>
    GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: openModule ?? (_, {Map<String, dynamic>? target}) {},
          visibleLabels: visible,
          clearFocus: () {},
          child: child,
        ),
      ),
    );

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Every glyph actually painted, drill-downs included. RichText catches plain
/// Text as well as the StatCard's spans.
List<String> _screenText(WidgetTester tester) => [
      for (final rt in tester.widgetList<RichText>(find.byType(RichText)))
        rt.text.toPlainText(includeSemanticsLabels: false, includePlaceholders: false),
    ];

// The floor a waiter is working: four tables, two of them theirs.
const _tables = [
  {'table_name': 'T1', 'occupied': true, 'covers': 4, 'table_total': 1200, 'apc_status': 'red'},
  {'table_name': 'T2', 'occupied': true, 'covers': 2, 'table_total': 800},
  {'table_name': 'T3', 'occupied': false},
  {'table_name': 'T4', 'occupied': false},
];

// GetTableAssignments returns the LOGIN USERNAME in `employee_id`
// (`l.emp_username`), not the Employees.id UUID — the shape this fixture pins.
const _assignments = [
  {'id': 'a1', 'table_name': 'T1', 'employee_id': 'ravi', 'employee_name': 'Ravi K'},
  {'id': 'a2', 'table_name': 'T3', 'employee_id': 'ravi', 'employee_name': 'Ravi K'},
  {'id': 'a3', 'table_name': 'T2', 'employee_id': 'sunil', 'employee_name': 'Sunil M'},
];

const _orders = [
  {'id': 'o1', 'table': 'T1', 'status': 'Preparing', 'items': <dynamic>[], 'total': 900},
  {'id': 'o2', 'table': 'T1', 'status': 'Pending', 'items': <dynamic>[], 'total': 300},
  {'id': 'o3', 'table': 'T2', 'status': 'Preparing', 'items': <dynamic>[], 'total': 800},
  {'id': 'o4', 'table': 'T3', 'status': 'Paid', 'items': <dynamic>[], 'total': 500},
];

const _money = {
  '/orders/apc': {
    'total_revenue': 184320.5,
    'monthly_apc': 156.2,
    'total_covers': 1180,
    'orders': [1, 2, 3],
    'month': 'August 2026',
  },
  '/orders/daily-revenue?days=14': {
    'series': [
      {'date': '2026-08-01', 'revenue': 9000, 'orders': 10},
      {'date': '2026-08-02', 'revenue': 9500, 'orders': 12},
    ],
  },
  '/analytics/overview?days=30': {
    'headline': {
      'revenue': {'value': 184320.5, 'pct_change': 22.9, 'direction': 'up', 'compared_to': 'previous 30 days'},
      'today_revenue': 8420,
    },
    'top_dishes_by_revenue': [
      {'name': 'Paneer Tikka', 'category': 'Starters', 'quantity': 214, 'revenue': 42800, 'share_pct': 23.2},
    ],
    'needs_attention': <dynamic>[],
  },
  '/feedback/summary': {'averageRating': 4.35, 'totalResponses': 1284, 'last30DaysResponses': 96},
  '/bills/open?limit=1': {'total': 3, 'outstanding_total': 4200, 'bills': <dynamic>[]},
};

Map<String, dynamic> _floorRoutes({bool withAssignments = true}) => <String, dynamic>{
      ..._money,
      '/get-tables': _tables,
      '/orders': _orders,
      if (withAssignments) '/table-assignments': _assignments,
    };

void main() {
  // ---------------------------------------------------------------- the role --

  group('RoleScope.isWaiterOnly', () {
    test('a plain waiter is a waiter', () {
      expect(RoleScope.isWaiterOnly(_waiter), isTrue);
      expect(RoleScope.isWaiterOnly(_waiterWithApc), isTrue,
          reason: 'granting an action changes what they may READ, not what they ARE');
    });

    test('a waiter who is also something else is not narrowed', () {
      for (final other in ['manager', 'captain', 'cashier', 'admin']) {
        final p = Profile.fromJson(_profileJson(role: 'waiter', roleAll: ['waiter', other]));
        expect(RoleScope.isWaiterOnly(p), isFalse, reason: 'waiter + $other keeps every screen');
      }
    });

    test('a tenant custom role (a UUID in role_all) is never narrowed on a guess', () {
      final p = Profile.fromJson(_profileJson(
        role: 'waiter',
        roleAll: const ['waiter', '3f2b7c10-9b1e-4a55-9c4e-2c0f6a1d77aa'],
      ));
      expect(RoleScope.isWaiterOnly(p), isFalse);
    });

    test('nobody else is narrowed, and neither is an empty role set', () {
      for (final role in ['admin', 'manager', 'cashier', 'captain', 'employee', 'valet']) {
        expect(RoleScope.isWaiterOnly(Profile.fromJson(_profileJson(role: role))), isFalse,
            reason: '$role must be untouched by this file');
      }
      expect(RoleScope.isWaiterOnly(Profile.fromJson(const {})), isFalse);
    });

    test('the action wildcard is never a floor role', () {
      final p = Profile.fromJson(_profileJson(role: 'waiter', actions: const ['*']));
      expect(RoleScope.isWaiterOnly(p), isFalse);
    });
  });

  // ------------------------------------------------------------------- nav ---

  group('the nav a role is given', () {
    test('an owner still sees every module, Feedback directly under Valet', () {
      expect(visibleModuleLabelsFor(_admin), const [
        'Overview', 'Concerns', 'Orders', 'Kitchen', 'Tables', 'Waitlist', 'Bookings', 'Menu',
        'Inventory', 'Purchase Orders',
        'Attendance', 'Employees', 'Roles', 'Valet',
        'Feedback', 'Customers',
        'Analytics', 'Simulation', 'History', 'Reports',
        'Accounting', 'Cash register', 'Billing',
        'Outlets', 'Printer', 'Audit Log', 'Settings',
      ]);
    });

    test('a waiter loses Menu, Waitlist and Bookings — and keeps the floor', () {
      final nav = visibleModuleLabelsFor(_waiter);
      expect(nav, isNot(contains('Menu')));
      expect(nav, isNot(contains('Waitlist')));
      expect(nav, isNot(contains('Bookings')));
      expect(nav, containsAll(<String>['Tables', 'Orders', 'Kitchen']));
    });

    // The scouted hole: Waitlist's keywords are ['table', 'order', 'waitlist']
    // and every waiter holds an order action, so no grant could have hidden it.
    test('the three stay hidden even for a waiter granted the analytics action', () {
      final nav = visibleModuleLabelsFor(_waiterWithApc);
      expect(nav, isNot(contains('Menu')));
      expect(nav, isNot(contains('Waitlist')));
      expect(nav, isNot(contains('Bookings')));
    });

    // SCOPE DISCIPLINE. Only the role the owner named is narrowed; anyone else
    // holding the same action names keeps exactly what they had.
    test('a cashier, captain or manager with the same actions keeps all three', () {
      for (final role in ['cashier', 'captain', 'manager', 'employee']) {
        final nav = visibleModuleLabelsFor(Profile.fromJson(_profileJson(role: role)));
        expect(nav, containsAll(<String>['Menu', 'Waitlist', 'Bookings']),
            reason: '$role was not part of the request and must not be narrowed');
      }
    });
  });

  // --------------------------------------------------------------- landing ---

  group('the tab a role lands on', () {
    test('an owner still lands on Overview', () {
      expect(landingModuleLabelFor(_admin), 'Overview');
    });

    test('a waiter lands on the floor plan', () {
      expect(landingModuleLabelFor(_waiter), 'Tables');
      expect(landingModuleLabelFor(_waiterWithApc), 'Tables');
    });

    // The rule has to survive its own landing module being gated away, or it
    // parks someone on a screen that is not in their nav at all.
    test('a waiter whose Tables module is hidden lands on one they DO have', () {
      final noTables = Profile.fromJson(_profileJson(
        role: 'waiter',
        actionNames: const ['View Orders'], // nothing matching Tables' ['table']
      ));
      final nav = visibleModuleLabelsFor(noTables);
      expect(nav, isNot(contains('Tables')));
      expect(landingModuleLabelFor(noTables), nav.first);
      expect(nav, contains(landingModuleLabelFor(noTables)));
    });

    testWidgets('the shell really opens a waiter on Tables', (tester) async {
      final auth = await _signIn(_FakeApi(_profileJson(role: 'waiter')));
      await _pumpShell(tester, auth);
      expect(_activeTab(tester), 'Tables');
      // Landing is a starting position, not a hop: there is nothing behind it.
      final back = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back));
      expect(back.onPressed, isNull, reason: 'Back on the landing tab has nowhere to go');
    });

    testWidgets('the shell still opens an owner on Overview', (tester) async {
      final auth = await _signIn(_FakeApi(_profileJson(
        role: 'admin',
        actionNames: const <String>[],
        actions: const ['*'],
      )));
      await _pumpShell(tester, auth);
      expect(_activeTab(tester), 'Overview');
    });

    // The landing choice runs once, before anything can have navigated, so it
    // must not re-assert itself over the back trail or a deep link.
    testWidgets('landing does not fight the back trail', (tester) async {
      final auth = await _signIn(_FakeApi(_profileJson(role: 'waiter')));
      await _pumpShell(tester, auth);
      expect(_activeTab(tester), 'Tables');

      await tester.tap(find.descendant(
        of: find.byType(ListView).first,
        matching: find.text('Orders'),
      ));
      await tester.pump();
      expect(_activeTab(tester), 'Orders');

      final back = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back));
      expect(back.onPressed, isNotNull);
      back.onPressed!();
      await tester.pump();
      expect(_activeTab(tester), 'Tables', reason: 'Back walks the trail, landing does not re-fire');
    });
  });

  // -------------------------------------------------------------- overview ---

  group('OverviewScope', () {
    test("an owner's Overview is unchanged", () {
      final s = OverviewScope.of(_admin);
      expect([s.money, s.insights, s.rating, s.floor, s.billValue, s.planLimits],
          everyElement(isTrue));
      expect(s.ownSection, isFalse);
    });

    test('a waiter gets no money, granted the analytics action or not', () {
      for (final p in [_waiter, _waiterWithApc]) {
        final s = OverviewScope.of(p);
        expect(s.money, isFalse);
        expect(s.insights, isFalse);
        expect(s.rating, isFalse);
        expect(s.billValue, isFalse);
        expect(s.planLimits, isFalse);
        // What they DO get.
        expect(s.floor, isTrue);
        expect(s.ownSection, isTrue);
      }
    });

    // The 403-as-an-empty-card case, for everyone. This is not narrowing a role:
    // the figure was never there, it was a refused request rendered as ₹0.00.
    test('a non-waiter without the analytics action loses the money blocks too', () {
      final cashier = Profile.fromJson(_profileJson(role: 'cashier'));
      final s = OverviewScope.of(cashier);
      expect(s.money, isFalse);
      expect(s.insights, isFalse);
      expect(s.floor, isTrue);
      expect(s.billValue, isTrue, reason: 'a cashier collects money — that is the job');
      expect(s.ownSection, isFalse, reason: 'nobody else grows a waiter section');
    });

    // /orders/apc and /orders/daily-revenue are NOT under the /analytics prefix
    // FEATURE_BY_PREFIX gates, so a lean plan must not take an owner's own
    // revenue off their own dashboard.
    test('a plan without analytics keeps the revenue cards and drops only the insight read', () {
      final lean = Profile.fromJson(_profileJson(
        role: 'manager',
        actionNames: const ['View Order APC'],
        features: const {'analytics': false},
      ));
      final s = OverviewScope.of(lean);
      expect(s.money, isTrue);
      expect(s.insights, isFalse);
    });
  });

  group('the Overview a role is given', () {
    testWidgets("an owner's Overview still asks for everything and shows it", (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'admin', actionNames: const <String>[], actions: const ['*']),
          _floorRoutes());
      final auth = await _signIn(api);
      final rest = RestClient(auth);

      await tester.pumpWidget(_host(
        m.overviewModule(rest, auth.profile!),
        visible: visibleModuleLabelsFor(auth.profile!),
      ));
      await tester.pumpAndSettle();

      expect(api.calls, contains('GET /orders/apc'));
      expect(api.calls, contains('GET /analytics/overview?days=30'));
      expect(api.calls, contains('GET /feedback/summary'));
      expect(find.text('Revenue this month — all channels'), findsOneWidget);
      expect(find.text('Average per cover (APC), pre-tax'), findsOneWidget);
      expect(find.text('Average guest rating'), findsOneWidget);
      expect(find.text('Tables occupied right now'), findsOneWidget);
      expect(find.text('Operations'), findsOneWidget);
      expect(find.textContaining('₹4200.00 uncollected'), findsOneWidget);
      // An owner still gets the waiter section's absence.
      expect(find.text('Your section'), findsNothing);
      expect(api.calls, isNot(contains('GET /table-assignments')));
    });

    for (final granted in [false, true]) {
      final label = granted ? 'WITH the analytics action' : 'without the analytics action';

      testWidgets("a waiter $label is never shown the restaurant's money", (tester) async {
        _wide(tester);
        final p = granted ? _waiterWithApc : _waiter;
        final api = _FakeApi(
          _profileJson(
            role: 'waiter',
            actionNames: granted ? [..._waiterActions, 'View Order APC'] : _waiterActions,
          ),
          _floorRoutes(),
        );
        final auth = await _signIn(api);
        final rest = RestClient(auth);

        await tester.pumpWidget(_host(
          m.overviewModule(rest, auth.profile!),
          visible: visibleModuleLabelsFor(p),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // 1. The requests are never made — composed, not filtered.
        for (final route in const [
          'GET /orders/apc',
          'GET /orders/daily-revenue?days=14',
          'GET /analytics/overview?days=30',
          'GET /feedback/summary',
        ]) {
          expect(api.calls, isNot(contains(route)),
              reason: '$route feeds a block this reader may not see');
        }

        // 2. Nothing money-shaped is on the screen, at all.
        for (final shown in _screenText(tester)) {
          expect(shown.contains('₹'), isFalse, reason: 'a rupee figure leaked into "$shown"');
        }
        expect(find.text('Revenue this month — all channels'), findsNothing);
        expect(find.text('Average per cover (APC), pre-tax'), findsNothing);
        expect(find.text('Average guest rating'), findsNothing);
        expect(find.text('Tables below target'), findsNothing);
        expect(find.textContaining('Plan limits'), findsNothing);

        // 3. And what they DO get is their own floor.
        expect(find.text('Your section'), findsOneWidget);
        expect(find.text('Tables occupied right now'), findsOneWidget);
        expect(find.text('YOUR TABLES'), findsOneWidget);
        expect(find.text('COVERS SEATED'), findsOneWidget);
      });
    }

    testWidgets('the waiter section names their own tables and counts their own covers',
        (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      // T1 and T3 are Ravi's; T2 is Sunil's and must not be counted.
      expect(find.text('T1 · T3'), findsOneWidget);
      expect(find.text('1 of your 2 table(s) occupied'), findsOneWidget);
      // Only T1 is occupied of theirs, with 4 covers — not the floor's 6.
      final coversTile = find.ancestor(
        of: find.text('COVERS SEATED'),
        matching: find.byType(Column),
      );
      expect(find.descendant(of: coversTile.first, matching: find.text('4')), findsOneWidget);

      // Their open tickets: o1 + o2 on T1 (o3 is Sunil's table, o4 is paid).
      expect(find.text('OPEN ON YOUR TABLES'), findsOneWidget);
      expect(find.text('1 waiting to be accepted'), findsOneWidget);
    });

    // /table-assignments carries its own action. Without it the block must say
    // it is reporting the whole floor rather than claim none of it is theirs.
    testWidgets('no assignment roster degrades to the floor, it does not lie', (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes(withAssignments: false));
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      expect(find.text('YOUR TABLES'), findsNothing);
      expect(find.text('COVERS SEATED'), findsOneWidget);
      expect(find.textContaining('across the floor'), findsOneWidget);
      expect(find.text('OPEN TICKETS'), findsOneWidget);
    });

    testWidgets('the open-bills tile keeps its count for a waiter and drops its price',
        (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      expect(find.text('OPEN BILLS'), findsOneWidget);
      expect(find.text('still to settle'), findsOneWidget);
      expect(find.textContaining('uncollected'), findsNothing);
    });

    // The occupancy drill-down is a floor sheet, and it used to headline every
    // row with what that table is worth.
    testWidgets('the occupancy drill-down shows a waiter covers, not table totals',
        (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tables occupied right now'));
      await tester.pumpAndSettle();

      expect(find.text('Occupied right now'), findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('4 cover(s)'), findsOneWidget);
      for (final shown in _screenText(tester)) {
        expect(shown.contains('₹'), isFalse, reason: 'the sheet priced a table: "$shown"');
      }
    });

    // Both design systems ship in this release, so every screen this agent
    // touched has to render under each of them.
    for (final system in DesignSystem.values) {
      testWidgets("a waiter's Overview renders under ${system.name}", (tester) async {
        _wide(tester);
        final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
        final auth = await _signIn(api);

        await tester.pumpWidget(_host(
          m.overviewModule(RestClient(auth), auth.profile!),
          visible: visibleModuleLabelsFor(_waiter),
          system: system,
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Read off the painted glyphs rather than find.text: Gaia's section
        // header is a RichText carrying an UPPERCASED title, so a Text finder
        // would pass on Rustic and quietly skip the design system it is here
        // to cover.
        final painted = _screenText(tester);
        expect(painted.map((s) => s.toLowerCase()), contains('your section'));
        for (final shown in painted) {
          expect(shown.contains('₹'), isFalse, reason: '${system.name} leaked money: "$shown"');
          expect(shown.contains('NaN'), isFalse);
        }
      });
    }

    // A restaurant that has never taken an order still has to render.
    testWidgets("a waiter's Overview survives an empty restaurant", (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), const <String, dynamic>{});
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Welcome'), findsOneWidget);
      for (final shown in _screenText(tester)) {
        expect(shown.toLowerCase().contains('null'), isFalse, reason: 'null leaked into "$shown"');
        expect(shown.contains('NaN'), isFalse);
      }
    });
  });
}
