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

/// `GET /me/scorecard` — the ONE read a waiter's Overview makes.
///
/// The shape is the route's, and the redaction is the route's too: there is no
/// `benchmark` key on any component and no `benchmarks` block on the payload,
/// because the server strips the house APC and the house turnaround BEFORE the
/// answer leaves the process. The notes below are the shipped notes with their
/// ", against a house …" tail already cut — which is exactly what an identity
/// without the analytics action must never be able to read.
const _scorecard = {
  '/me/scorecard': {
    'window_days': 30,
    'from': '2026-08-10',
    'to': '2026-09-09',
    'timezone': 'Asia/Kolkata',
    'generated_at': '2026-09-09T12:00:00.000Z',
    'weights': {'apc': 0.35, 'rating': 0.30, 'attendance': 0.20, 'tat': 0.15},
    'employee_id': 'emp-uuid-1',
    'employee_name': 'Ravi K',
    'role': 'waiter',
    'score': 78.4,
    'components_available': 4,
    'effective_weights': {'apc': 0.35, 'rating': 0.30, 'attendance': 0.20, 'tat': 0.15},
    'components': {
      'apc': {
        'value': 612.5,
        'score': 88.0,
        'available': true,
        'unit': 'currency per cover',
        'sample': 12,
        'note': 'Pre-tax spend per cover across 12 settled bills (31 covers).',
      },
      'rating': {
        'value': 4.6,
        'score': 90.0,
        'available': true,
        'unit': 'stars (1-5)',
        'sample': 9,
        'note': 'Average of 9 guest ratings.',
      },
      'attendance': {
        'value': 92.0,
        'score': 92.0,
        'available': true,
        'unit': '% presence/punctuality',
        'sample': 25,
        'note': 'Present on 23 of 25 open days (1 excused by approved leave); 2 late starts.',
      },
      'tat': {
        'value': 46.5,
        'score': 71.0,
        'available': true,
        'unit': 'minutes per table',
        'sample': 9,
        'note': 'Median seated-to-released time over 9 tables.',
      },
    },
    'attendance_now': {
      'clocked_in': true,
      'since': '2026-09-09T04:30:00.000Z',
      'today_minutes': 195,
      'pending_approval': false,
    },
  },
};

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

Map<String, dynamic> _floorRoutes({bool withAssignments = true, bool withScorecard = true}) =>
    <String, dynamic>{
      ..._money,
      if (withScorecard) ..._scorecard,
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

    // THIS TEST USED TO ASSERT THE OPPOSITE, AND THE OPPOSITE WAS A LIVE BUG.
    //
    // The original rule was "never narrow on a guess": a role this build cannot
    // read must not cost anybody a screen. That is a good instinct pointed in
    // the wrong direction, because the thing on the other side of this predicate
    // is MONEY — showsMoney is `!isWaiterOnly`, so "do not narrow" does not mean
    // "leave them alone", it means SHOW THEM THE DAY'S TAKINGS.
    //
    // And it did not fire on an exotic edge case. A custom role is stored as a
    // UUID in role_all, so the rule un-scoped every waiter at every tenant that
    // used the granular RBAC feature — the exact population it was written to
    // protect. It was reported from production: a waiter at csrorganics with the
    // full unscoped app.
    //
    // The rule is now "a waiter is scoped unless they also hold a role that
    // OUTRANKS a waiter", and outranking is a closed list. A custom role is a
    // permission bundle, not a rank, so it no longer lifts anything — and the
    // server decides this anyway (scope.waiter_only); this is only the fallback.
    test('a tenant custom role (a UUID in role_all) does NOT lift the scoping', () {
      final p = Profile.fromJson(_profileJson(
        role: 'waiter',
        roleAll: const ['waiter', '3f2b7c10-9b1e-4a55-9c4e-2c0f6a1d77aa'],
      ));
      expect(RoleScope.isWaiterOnly(p), isTrue);
      expect(RoleScope.showsMoney(p), isFalse,
          reason: 'granting a custom role must never be how a waiter starts seeing revenue');
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
        // 'Floor plan' is D5's layout half of what used to be the Tables
        // module, and it sits directly under Tables — where somebody will look
        // for the controls that left it.
        'Overview', 'Concerns', 'Orders', 'Kitchen', 'Tables', 'Floor plan', 'Waitlist', 'Bookings', 'Menu',
        'Inventory', 'Purchase Orders',
        'Attendance', 'Employees', 'Roles', 'Valet',
        'Feedback', 'Customers',
        'Analytics', 'Simulation', 'History', 'Reports',
        'Accounting', 'Cash register', 'Billing',
        'Outlets', 'Printer', 'Audit Log', 'Settings',
      ]);
    });

    test('a waiter loses Menu, Kitchen, Waitlist, Bookings and the layout editor', () {
      final nav = visibleModuleLabelsFor(_waiter);
      // D5 — 'Floor plan' is the layout EDITOR, and every control on it is
      // already false for this role. Left in the nav it would be a second copy
      // of the floor with every button removed.
      for (final gone in const ['Menu', 'Kitchen', 'Waitlist', 'Bookings', 'Floor plan']) {
        expect(nav, isNot(contains(gone)));
      }
      // What the shift is actually made of.
      expect(nav, containsAll(<String>['Tables', 'Orders', 'Overview', 'Attendance']));
    });

    // The scouted hole: Waitlist's keywords are ['table', 'order', 'waitlist']
    // and Kitchen's are ['order','kitchen','kot','kds'] — every waiter holds an
    // order action, so no grant could ever have hidden either of them.
    test('they stay hidden even for a waiter granted the analytics action', () {
      final nav = visibleModuleLabelsFor(_waiterWithApc);
      // 'Floor plan' carries ['table'] — the keyword EVERY waiter matches — so
      // like Waitlist and Kitchen it could never have been hidden by a grant.
      for (final gone in const ['Menu', 'Kitchen', 'Waitlist', 'Bookings', 'Floor plan']) {
        expect(nav, isNot(contains(gone)));
      }
    });

    // THE OTHER ROUTE TO THE MONEY, and the reason this list is not just the
    // four screens item 12 names.
    //
    // Taking the rupees off the floor plan is not "no money on a waiter's
    // screen" while Analytics, Reports, Accounting, Cash register, Concerns,
    // Simulation and History sit in the same nav — every one of them gated on
    // ['analytics','apc','report'], which a tenant satisfies the moment it ticks
    // "View Order APC" for the waiter role. That tenant is the case RoleScope
    // exists for.
    test('a waiter granted the analytics action still reaches no money module', () {
      final nav = visibleModuleLabelsFor(_waiterWithApc);
      for (final gone in const [
        'Concerns', 'Analytics', 'Simulation', 'History', 'Reports',
        'Accounting', 'Cash register', 'Billing',
      ]) {
        expect(nav, isNot(contains(gone)), reason: '$gone prices the restaurant');
      }
    });

    // SCOPE DISCIPLINE. Only the role the owner named is narrowed; anyone else
    // holding the same action names keeps exactly what they had.
    test('a cashier, captain or manager with the same actions keeps all four', () {
      for (final role in ['cashier', 'captain', 'manager', 'employee']) {
        final nav = visibleModuleLabelsFor(Profile.fromJson(_profileJson(role: role)));
        expect(nav, containsAll(<String>['Menu', 'Kitchen', 'Waitlist', 'Bookings']),
            reason: '$role was not part of the request and must not be narrowed');
      }
    });

    // … and the money modules go with them, on the same action.
    test('a non-waiter with the analytics action keeps every money module', () {
      final manager = Profile.fromJson(_profileJson(
        role: 'manager',
        actionNames: [..._waiterActions, 'View Order APC'],
      ));
      // History's keywords are ['analytics','report'] and this fixture's action
      // names contain neither word literally, so it is absent for a permission
      // reason that has nothing to do with the role. The four that DO match are
      // the point: the role never removes them from a non-waiter.
      expect(visibleModuleLabelsFor(manager),
          containsAll(<String>['Concerns', 'Analytics', 'Simulation', 'Reports']));
    });
  });

  // -------------------------------------------------------------- nav order --

  group('where the Overview sits in the nav', () {
    test("an owner's Overview is still the first thing in the nav", () {
      expect(visibleModuleLabelsFor(_admin).first, 'Overview');
    });

    // ITEM 13's second half. A waiter still HAS an Overview — it is their
    // scorecard — but it is the last section of the nav, not the first.
    test("a waiter's Overview is the LAST module in their nav", () {
      for (final p in [_waiter, _waiterWithApc]) {
        final nav = visibleModuleLabelsFor(p);
        expect(nav, contains('Overview'));
        expect(nav.last, 'Overview');
        expect(nav.first, isNot('Overview'));
      }
    });

    testWidgets('the sidebar draws it last, under its own heading', (tester) async {
      final auth = await _signIn(_FakeApi(_profileJson(role: 'waiter')));
      await _pumpShell(tester, auth);

      final rail = find.byType(ListView).first;
      double topOf(String label) => tester
          .getTopLeft(find.descendant(of: rail, matching: find.text(label)))
          .dy;

      // The group header exists, and Overview is inside it — below every other
      // nav row, which is what "the LAST section" means on screen.
      expect(find.descendant(of: rail, matching: find.text('YOUR SHIFT')), findsOneWidget);
      expect(topOf('Overview'), greaterThan(topOf('Tables')));
      expect(topOf('Overview'), greaterThan(topOf('Orders')));
      expect(topOf('Overview'), greaterThan(topOf('YOUR SHIFT') - 1));
      // OPERATIONS still leads, and it no longer contains the Overview.
      expect(topOf('OPERATIONS'), lessThan(topOf('YOUR SHIFT')));
    });

    testWidgets("an owner's sidebar is untouched — Overview under OPERATIONS, first",
        (tester) async {
      final auth = await _signIn(_FakeApi(_profileJson(
        role: 'admin',
        actionNames: const <String>[],
        actions: const ['*'],
      )));
      await _pumpShell(tester, auth);
      final rail = find.byType(ListView).first;
      expect(find.descendant(of: rail, matching: find.text('YOUR SHIFT')), findsNothing);
      final ops = tester.getTopLeft(
          find.descendant(of: rail, matching: find.text('OPERATIONS'))).dy;
      final overview = tester.getTopLeft(
          find.descendant(of: rail, matching: find.text('Overview'))).dy;
      expect(overview, greaterThan(ops));
      expect(overview, lessThan(tester
          .getTopLeft(find.descendant(of: rail, matching: find.text('Tables')))
          .dy));
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
      expect(s.scorecard, isFalse);
    });

    test('a waiter gets no money, granted the analytics action or not', () {
      for (final p in [_waiter, _waiterWithApc]) {
        final s = OverviewScope.of(p);
        expect(s.money, isFalse);
        expect(s.insights, isFalse);
        expect(s.rating, isFalse);
        expect(s.billValue, isFalse);
        expect(s.planLimits, isFalse);
        // ITEM 13's "no restaurant-wide anything" — the floor read went with the
        // money. How full the restaurant is, is the restaurant's business; the
        // floor PLAN is one tap away and is the tab they land on.
        expect(s.floor, isFalse);
        // What they DO get, and the whole of it.
        expect(s.scorecard, isTrue);
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
      expect(s.scorecard, isFalse, reason: 'nobody else grows a waiter scorecard');
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
      // An owner grows no scorecard, and never asks for one.
      expect(find.text('Your shift'), findsNothing);
      expect(api.calls, isNot(contains('GET /me/scorecard')));
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

        // 1. THE REQUESTS ARE NEVER MADE — composed, not filtered. The floor and
        //    open-bills reads join the money reads here: item 13 leaves a waiter
        //    ONE read, and it is the one about them.
        for (final route in const [
          'GET /orders/apc',
          'GET /orders/daily-revenue?days=14',
          'GET /analytics/overview?days=30',
          'GET /feedback/summary',
          'GET /get-tables',
          'GET /bills/open?limit=1',
          'GET /table-assignments',
        ]) {
          expect(api.calls, isNot(contains(route)),
              reason: '$route feeds a block this reader may not see');
        }
        expect(api.calls, contains('GET /me/scorecard'));

        // 2. Nothing restaurant-shaped is on the screen, at all.
        expect(find.text('Revenue this month — all channels'), findsNothing);
        expect(find.text('Average per cover (APC), pre-tax'), findsNothing);
        expect(find.text('Average guest rating'), findsNothing);
        expect(find.text('Tables occupied right now'), findsNothing);
        expect(find.text('Tables below target'), findsNothing);
        expect(find.text('Operations'), findsNothing);
        expect(find.text('OPEN BILLS'), findsNothing);
        expect(find.textContaining('uncollected'), findsNothing);
        expect(find.textContaining('Plan limits'), findsNothing);

        // 3. And what they DO get is themselves — item 13's four, and nothing
        //    else that carries a figure.
        expect(find.text('Your shift'), findsOneWidget);
        expect(find.text('Your performance score, last 30 days'), findsOneWidget);
        expect(find.text('YOUR APC'), findsOneWidget);
        expect(find.text('YOUR GUEST RATING'), findsOneWidget);
        expect(find.text('YOUR ATTENDANCE'), findsOneWidget);
        expect(find.text('ON SHIFT NOW'), findsOneWidget);
      });
    }

    // THE ONE RUPEE FIGURE A WAITER KEEPS, and the seam between items 13 and 19.
    //
    // Item 19 takes the per-table APC off their screen; item 13 asks for THEIR
    // APC by name. Those are different numbers: one is what the guests in front
    // of them owe right now, the other is a month of their own service. Only the
    // second survives, and only on this screen.
    testWidgets('their own APC is on the scorecard, and it is the only ₹ on the page',
        (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      final rupees = [for (final t in _screenText(tester)) if (t.contains('₹')) t];
      expect(rupees, hasLength(1), reason: 'exactly one money figure, and it is theirs: $rupees');
      expect(rupees.single, contains('612.50'));

      // The rest of the card, read off the payload rather than invented here.
      // The score is the StatCard's big value, which Gaia and Rustic both paint
      // as a RichText span — read it off the glyphs, not with a Text finder.
      expect(_screenText(tester).any((t) => t.startsWith('78')), isTrue,
          reason: 'the composite score');
      expect(find.text('4.60 / 5'), findsOneWidget);
      expect(find.text('92%'), findsOneWidget);
      expect(find.text('Clocked in'), findsOneWidget);
      expect(find.textContaining('today: 3h 15m'), findsOneWidget);
    });

    // The house figures the score was measured against are the restaurant's
    // money and its restaurant-wide turnaround. The ROUTE strips them; this is
    // the client half of the same promise — nothing on this screen can print a
    // benchmark, because the payload has none to print.
    testWidgets('the score explains itself without ever quoting the house', (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), _floorRoutes());
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Your performance score, last 30 days'));
      await tester.pumpAndSettle();

      expect(find.text('78 out of 100'), findsOneWidget);
      // Every component that built it, including the one with no tile.
      expect(find.text('Average per cover'), findsOneWidget);
      expect(find.text('Guest rating'), findsOneWidget);
      expect(find.text('Attendance'), findsOneWidget);
      expect(find.text('Table turnaround'), findsOneWidget);
      for (final shown in _screenText(tester)) {
        expect(shown.toLowerCase().contains('house'), isFalse,
            reason: 'a house benchmark reached the screen: "$shown"');
      }
    });

    // The score is the only figure that can be missing wholesale, and a missing
    // measure is NOT a zero — a waiter with no feedback is not a zero-rated
    // waiter, and the server says so component by component.
    testWidgets('an unscoreable waiter is told so, not scored nil', (tester) async {
      _wide(tester);
      final api = _FakeApi(_profileJson(role: 'waiter'), <String, dynamic>{
        '/me/scorecard': {
          'window_days': 30,
          'weights': {'apc': 0.35, 'rating': 0.30, 'attendance': 0.20, 'tat': 0.15},
          'score': null,
          'components_available': 0,
          'components': null,
          'attendance_now': {'clocked_in': false, 'today_minutes': 0},
        },
      });
      final auth = await _signIn(api);

      await tester.pumpWidget(_host(
        m.overviewModule(RestClient(auth), auth.profile!),
        visible: visibleModuleLabelsFor(_waiter),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('no measure could be taken yet'), findsOneWidget);
      expect(find.text('0'), findsNothing, reason: 'unmeasured is not zero');
      for (final shown in _screenText(tester)) {
        expect(shown.contains('NaN'), isFalse);
        expect(shown.toLowerCase().contains('null'), isFalse, reason: 'null leaked into "$shown"');
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
        expect(painted.map((s) => s.toLowerCase()), contains('your shift'));
        for (final shown in painted) {
          expect(shown.contains('NaN'), isFalse);
        }
        // One rupee figure under BOTH systems, and it is theirs.
        expect([for (final t in painted) if (t.contains('₹')) t], hasLength(1));
      });
    }

    // A restaurant with no scorecard yet (an older backend, a 500, an outlet the
    // roster has no row in) still has to render.
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
        expect(shown.contains('₹'), isFalse, reason: 'a rupee figure was invented: "$shown"');
      }
    });
  });
}
