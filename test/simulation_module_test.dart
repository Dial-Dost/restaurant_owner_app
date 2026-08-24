import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The what-if simulator: levers in, CURRENT | SIMULATED | DELTA out.
///
/// The reference implementation of this screen rendered ₹NaN in every delta
/// cell, so the tests here pin the two promises the module actually makes: the
/// body POSTed to /simulation/run is the levers as labelled (seeded from the
/// LIVE baseline), and every rendered number is finite — a zero delta reads
/// "₹0", signed deltas carry their colour, and "NaN" never appears anywhere.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// Every write the module made, so the test can check what was submitted.
  final List<({String path, Object? body})> posts = [];

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
    if (method == 'POST') {
      posts.add((path: path, body: body));
      final canned = routes['POST $path'];
      if (canned != null) return canned;
      return <String, dynamic>{};
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

// A healthy 30-day baseline: 100 covers at APC ₹400, with the fixed-costs
// figure the one field the backend could not measure (sources it "default").
const _routes = <String, dynamic>{
  '/simulation/baseline': {
    'window_days': 30,
    'covers_per_day': 100,
    'apc': 400,
    'revenue_per_day': 40000,
    'food_cost_pct': 32,
    'labour_cost_per_day': 6000,
    'staff_count': 12,
    'avg_tat_min': 42,
    'table_count': 18,
    'fixed_costs_per_day': 5000,
    'net_profit_per_day': 16200,
    'sources': {
      'covers_per_day': 'measured',
      'apc': 'measured',
      'revenue_per_day': 'measured',
      'food_cost_pct': 'measured',
      'labour_cost_per_day': 'measured',
      'staff_count': 'measured',
      'avg_tat_min': 'measured',
      'table_count': 'measured',
      'fixed_costs_per_day': 'default',
      'net_profit_per_day': 'measured',
    },
  },
  // A run where a 10% price rise trades covers for APC: revenue and profit dip,
  // labour rises (an expediter was added), and food cost lands on a delta of
  // exactly 0 — the case the reference implementation rendered as ₹NaN.
  'POST /simulation/run': {
    'current': {
      'covers': 100, 'apc': 400, 'revenue': 40000, 'labour_cost': 6000,
      'food_cost': 12800, 'marketing_per_day': 0, 'net_profit': 16200, 'tat_min': 42,
    },
    'simulated': {
      'covers': 89.9, 'apc': 440, 'revenue': 39539, 'labour_cost': 8100,
      'food_cost': 12800, 'marketing_per_day': 0, 'net_profit': 13787, 'tat_min': 39,
    },
    'delta': {
      'covers': -10.1, 'apc': 40, 'revenue': -461, 'labour_cost': 2100,
      'food_cost': 0, 'marketing_per_day': 0, 'net_profit': -2413, 'tat_min': -3,
    },
    'notes': [
      'Price increase of 10%: APC ₹400 → ₹440; demand responds ×0.87 (elasticity -1.3).',
    ],
    'breakeven_days': null,
  },
};

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Simulation'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<_FakeApi> _mount(WidgetTester tester, {double width = 390}) async {
  await tester.pumpWidget(const SizedBox());
  // Tall enough that the levers, the baseline card AND the results table are
  // all mounted — a ListView does not build what it cannot show.
  tester.view.physicalSize = Size(width, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(_routes);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.simulationModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _run(WidgetTester tester) async {
  await tester.tap(find.text('Run Simulation'));
  await tester.pumpAndSettle();
}

const _leverKeys = [
  'sim-price', 'sim-elasticity', 'sim-staff', 'sim-wage',
  'sim-tat', 'sim-expediters', 'sim-marketing', 'sim-food',
];

void main() {
  testWidgets('every lever exists, and the live baseline card says its basis', (tester) async {
    await _mount(tester);

    expect(find.text('What-If Simulator'), findsOneWidget);
    expect(find.text('Run Simulation'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(8));
    for (final k in _leverKeys) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '$k slider missing');
    }

    // The live numbers, and the one field the backend had to estimate.
    expect(find.text('Current Performance'), findsOneWidget);
    expect(find.text('₹40000'), findsOneWidget, reason: 'revenue/day');
    expect(find.text('₹16200'), findsOneWidget, reason: 'net profit/day');
    expect(find.text('42 min'), findsWidgets, reason: 'measured TAT (card and lever label)');
    expect(find.text('estimated'), findsOneWidget, reason: 'only fixed costs is sourced "default"');
    // Every ₹ figure is on ONE stated basis — the card must say which.
    expect(find.textContaining('pre-tax'), findsOneWidget);
  });

  testWidgets('running posts every lever, seeded from the live baseline', (tester) async {
    final api = await _mount(tester);
    await _run(tester);

    final runs = api.posts.where((p) => p.path == '/simulation/run').toList();
    expect(runs.length, 1);
    final body = runs.single.body as Map;
    expect(body.keys.toSet(), {
      'price_adjust_pct', 'elasticity', 'staff_count', 'avg_wage_per_shift',
      'tat_target_min', 'extra_expediters', 'marketing_spend', 'food_cost_pct',
    });
    for (final e in body.entries) {
      expect(e.value, isA<num>(), reason: '${e.key} must be a number');
      expect((e.value as num).isFinite, isTrue, reason: '${e.key} must be finite');
    }
    // Untouched levers reproduce today: model defaults where the baseline has
    // no lever (price 0, elasticity -1.3), live numbers where it does — staff
    // and TAT straight off the card, wage derived as labour ÷ heads (6000/12).
    expect(body['price_adjust_pct'], 0);
    expect(body['elasticity'], -1.3);
    expect(body['staff_count'], 12);
    expect(body['avg_wage_per_shift'], 500);
    expect(body['tat_target_min'], 42);
    expect(body['extra_expediters'], 0);
    expect(body['marketing_spend'], 0);
    expect(body['food_cost_pct'], 32);
  });

  testWidgets('the results table renders CURRENT | SIMULATED | DELTA, signed and coloured', (tester) async {
    await _mount(tester);
    await _run(tester);

    expect(find.text('CURRENT'), findsOneWidget);
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(find.text('DELTA'), findsOneWidget);

    Color colorOf(String t) => tester.widget<Text>(find.text(t)).style!.color!;
    // Good deltas are green, bad are red — and "bad" flips for a cost or TAT.
    expect(find.text('+₹40'), findsOneWidget, reason: 'APC delta, signed');
    expect(colorOf('+₹40'), AppColors.success);
    expect(find.text('-₹461'), findsOneWidget, reason: 'revenue delta, signed');
    expect(colorOf('-₹461'), AppColors.danger);
    expect(colorOf('+₹2100'), AppColors.danger, reason: 'labour going UP is bad');
    expect(colorOf('-₹2413'), AppColors.danger, reason: 'net profit going DOWN is bad');
    expect(colorOf('-3 min'), AppColors.success, reason: 'TAT going DOWN is good');
    expect(find.text('-10.1'), findsOneWidget, reason: 'covers delta keeps its 0.1 precision');

    // The model's own explanation of what it applied.
    expect(find.textContaining('elasticity -1.3'), findsOneWidget);
  });

  testWidgets('a delta of zero renders as ₹0 — never NaN, never signed', (tester) async {
    await _mount(tester);
    await _run(tester);

    // food_cost delta is exactly 0, and the marketing row is 0 across all three
    // columns: current ₹0, simulated ₹0, delta ₹0. With the marketing lever's
    // own "₹0" value label that is five ₹0s on screen — and no ₹NaN.
    expect(find.text('₹0'), findsNWidgets(5));
    expect(find.text('+₹0'), findsNothing);
    expect(find.text('-₹0'), findsNothing);
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    // A zero delta is neutral — neither the good green nor the bad red.
    final zeroDeltas = tester
        .widgetList<Text>(find.text('₹0'))
        .where((t) => t.style!.color == AppColors.success || t.style!.color == AppColors.danger);
    expect(zeroDeltas, isEmpty);
  });

  testWidgets('levers, baseline and results all lay out on a 320dp phone', (tester) async {
    await _mount(tester, width: 320);
    await _run(tester);

    expect(find.text('DELTA'), findsOneWidget);
    expect(find.text('+₹40'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
