import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/live_gross.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// 6.4 — the live-gross box above the Tables grid, the app's twin of the web's
/// `LiveGrossBar`.
///
/// THE REPORTED BUG, which the web fixed and the app must not reintroduce: with
/// T1–T3 holding sent KOTs and no bill generated yet, an open-BILL figure read
/// "₹0 · No tables are running". The box reads `running_tables` /
/// `running_total`, which count a table with orders and no bill.
///
/// And the three states stay three: an amount, a count with the amount
/// withheld (a waiter), and "unavailable". Zero is never a stand-in for either
/// of the other two.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.role = 'admin'});

  final Map<String, dynamic> routes;
  final String role;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Live Gross Test',
          'restaurantUsername': 'livegross',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'ravi',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'actions_set': role == 'admin' ? const ['*'] : const ['a1'],
          'action_names': const ['View Orders', 'View Tables', 'View Bills'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    final hit = routes[path];
    if (hit is Exception) throw hit;
    if (routes.containsKey(path)) return hit;
    throw ApiException('No fake route for $path', 404);
  }
}

// ---------------------------------------------------------------- fixtures --

Map<String, dynamic> _table(String name) => {
      'table_name': name,
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': true,
      'reserved': false,
      'num_covers': 2,
    };

/// The envelope `/bills/open?limit=1` sends. No bills generated (`total: 0`),
/// three tables running — the bug's own shape.
Map<String, dynamic> _page({int running = 3, double? runningTotal = 5890.25}) => {
      'bills': <dynamic>[],
      'total': 0,
      'outstanding_total': 0,
      'running_tables': running,
      'running_total': ?runningTotal,
    };

Map<String, dynamic> _routes(Object? openBills) => {
      '/get-tables': [_table('T1'), _table('T2'), _table('T3')],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bills/open?limit=1': openBills,
    };

Widget _host(Widget child, {ThemeData? theme}) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: theme ?? AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<(_FakeApi, RestClient)> _mount(
  WidgetTester tester, {
  required Object? openBills,
  String role = 'admin',
  bool plan = false,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(_routes(openBills), role: role);
  final auth = AuthController(api: api);
  await auth.login('Live Gross Test', 'ravi', 'pw');
  final rest = RestClient(auth);
  final p = rest.auth.profile!;
  await tester.pumpWidget(
      _host(plan ? m.floorPlanModule(rest, p) : m.tablesModule(rest, p), theme: theme));
  await tester.pumpAndSettle();
  return (api, rest);
}

/// The text painted inside the box, and nothing else on the page.
String _boxText(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byKey(const ValueKey('live-gross')), matching: find.byType(Text))))
        t.data ?? '',
    ].join(' | ');

void main() {
  setUp(PrintedBills.instance.resetForTest);
  tearDown(() {
    PrintedBills.instance.resetForTest();
    AppearanceController.instance.debugReset();
  });

  // ================================================================ the rule

  group('readLiveGross — the web\'s cases, one for one', () {
    test('THE BUG: no bills yet, three running tables — the running figures win', () {
      expect(readLiveGross(_page()), const LiveGrossFloor(tables: 3, total: 5890.25));
    });

    test('an unreachable backend is "unavailable", never ₹0', () {
      expect(readLiveGross(null), isA<LiveGrossUnavailable>());
    });

    test('a withheld amount keeps the count and shows NO figure, not 0', () {
      expect(readLiveGross(_page(runningTotal: null)), const LiveGrossFloor(tables: 3, total: null));
    });

    test('the app\'s own role gate withholds it too, even if a server sent it', () {
      expect(readLiveGross(_page(), showMoney: false), const LiveGrossFloor(tables: 3, total: null));
    });

    test('a genuinely empty floor is zero tables at ₹0', () {
      expect(readLiveGross(_page(running: 0, runningTotal: 0)), const LiveGrossFloor(tables: 0, total: 0));
    });

    test('a backend older than 6.4 falls back to the open-bill figures', () {
      expect(readLiveGross({'total': 2, 'outstanding_total': 2604}), const LiveGrossFloor(tables: 2, total: 2604));
    });

    test('a refusal hides the box; anything else says unavailable', () {
      expect(liveGrossFailure(ApiException('Forbidden', 403)), liveGrossRefused);
      expect(liveGrossFailure(ApiException('No route', 404)), liveGrossRefused);
      expect(liveGrossFailure(ApiException('Server error', 500)), liveGrossUnreachable);
      expect(liveGrossFailure(ApiException('Connection refused')), liveGrossUnreachable);
    });

    test('the headline figure is grouped the en-IN way, like the web', () {
      expect(liveGrossMoney(0), '₹0.00');
      expect(liveGrossMoney(5890.25), '₹5,890.25');
      expect(liveGrossMoney(125890.5), '₹1,25,890.50');
      expect(liveGrossMoney(12345678.9), '₹1,23,45,678.90');
      expect(liveGrossMoney(999), '₹999.00');
    });
  });

  // ============================================================= on screen

  group('the box on the Tables screen', () {
    testWidgets('an admin sees the ₹ total across the running tables, ABOVE the grid',
        (tester) async {
      final (api, _) = await _mount(tester, openBills: _page());

      expect(api.calls, contains('GET /bills/open?limit=1'));
      final box = _boxText(tester);
      expect(box, contains('On the floor now'));
      expect(box, contains('₹5,890.25'));
      expect(box, contains('Across 3 running tables · not yet paid, and before any discount at settlement.'));

      // Above the tables, which is where the requirement puts it.
      final boxRect = tester.getRect(find.byKey(const ValueKey('live-gross')));
      final tile = tester.getRect(find.text('T1').first);
      expect(boxRect.bottom, lessThanOrEqualTo(tile.top));
    });

    testWidgets('a waiter sees how many tables are running — no ₹, and never ₹0.00',
        (tester) async {
      // What the server sends a waiter-only session: running_total stripped.
      await _mount(tester, openBills: _page(runningTotal: null), role: 'waiter');

      final box = _boxText(tester);
      expect(box, contains('3 running'));
      expect(box, contains('tables with orders on them · amounts are not shown for your role.'));
      expect(box, isNot(contains('₹')));
    });

    testWidgets('a waiter on a backend that still sends the amount sees the count only',
        (tester) async {
      await _mount(tester, openBills: _page(), role: 'waiter');

      final box = _boxText(tester);
      expect(box, contains('3 running'));
      expect(box, isNot(contains('₹')));
      expect(box, isNot(contains('5,890')));
    });

    testWidgets('zero running tables: ₹0.00 for an admin, "0 running" for a waiter',
        (tester) async {
      await _mount(tester, openBills: _page(running: 0, runningTotal: 0));
      expect(_boxText(tester), contains('₹0.00'));
      expect(_boxText(tester), contains('No tables are running.'));

      await tester.pumpWidget(const SizedBox());
      await _mount(tester, openBills: _page(running: 0, runningTotal: null), role: 'waiter');
      expect(_boxText(tester), contains('0 running'));
      expect(_boxText(tester), contains('No tables are running.'));
      expect(_boxText(tester), isNot(contains('₹')));
    });

    testWidgets('the line down: "Unavailable just now", never ₹0.00 — and the floor still renders',
        (tester) async {
      await _mount(tester, openBills: ApiException('Connection refused'));

      expect(_boxText(tester), contains('Unavailable just now'));
      expect(_boxText(tester), isNot(contains('₹')));
      expect(find.text('T1'), findsWidgets);
    });

    testWidgets('a user the server refuses the read gets no box at all', (tester) async {
      await _mount(tester, openBills: ApiException('Forbidden', 403));

      expect(find.byKey(const ValueKey('live-gross')), findsNothing);
      expect(find.text('T1'), findsWidgets);
    });

    testWidgets('it refreshes with the tables: a reload re-reads the running figures',
        (tester) async {
      final (api, rest) = await _mount(tester, openBills: _page());
      expect(_boxText(tester), contains('₹5,890.25'));

      // A fourth table sat down. The shell's refresh (and an outlet switch)
      // re-keys the module, which re-runs the Tables loader.
      api.routes['/bills/open?limit=1'] = _page(running: 4, runningTotal: 7120);
      await tester.pumpWidget(_host(KeyedSubtree(
          key: const ValueKey('refresh-1'), child: m.tablesModule(rest, rest.auth.profile!))));
      await tester.pumpAndSettle();

      expect(_boxText(tester), contains('₹7,120.00'));
      expect(_boxText(tester), contains('Across 4 running tables'));
      expect(api.calls.where((c) => c == 'GET /bills/open?limit=1').length, greaterThanOrEqualTo(2));
    });

    testWidgets('the Floor plan neither shows the box nor asks for the figure (2.1)',
        (tester) async {
      final (api, _) = await _mount(tester, openBills: _page(), plan: true);

      expect(find.byKey(const ValueKey('live-gross')), findsNothing);
      expect(api.calls, isNot(contains('GET /bills/open?limit=1')));
    });

    testWidgets('its colours come from the theme, so a light palette repaints it',
        (tester) async {
      AppColors.applyShell(AppLightPalettes.beige);
      final theme = AppTheme.light();
      await _mount(tester, openBills: _page(), theme: theme);

      final box = tester.widget<Container>(find.byKey(const ValueKey('live-gross')));
      final deco = box.decoration! as BoxDecoration;
      expect((deco.border! as Border).top.color, theme.colorScheme.primary.withValues(alpha: 0.3));
      final figure = tester.widget<Text>(find.byKey(const ValueKey('live-gross-figure')));
      expect(figure.style?.color, theme.colorScheme.onSurface);
      expect(figure.style?.color, AppLightPalettes.beige.textPrimary);
    });
  });
}
