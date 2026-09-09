import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/simulation_params.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The what-if simulator: levers in, CURRENT | SIMULATED | DELTA out.
///
/// Two families of promise are pinned here.
///
/// THE OLD ONES. The reference implementation of this screen rendered ₹NaN in
/// every delta cell, so: every rendered number is finite, a zero delta reads
/// "₹0", signed deltas carry their colour, and "NaN" never appears.
///
/// THE NEW ONE, and it is the whole reason the lever picker is safe: an INACTIVE
/// lever is OMITTED from the POST body — never sent as zero. The server resolves
/// a missing field to this tenant's own neutral value, so a removed lever
/// contributes their headcount, their measured TAT, their wage. Sending 0
/// instead would simulate a restaurant with no staff. The value is kept in
/// widget state while the lever is out, so re-adding restores it.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// Every write the module made, so the test can check what was submitted.
  final List<({String path, Object? body})> posts = [];

  /// When set, POSTs fail the way an unreachable server does: an ApiException
  /// with NO status. That is what RestClient reads as "never reached anyone",
  /// and what turns into the outbox's refusal for a non-queueable route.
  bool offline = false;

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
      if (offline) throw ApiException('Failed host lookup', null);
      // The speculative second-outlet model is the one run that comes back with
      // a loud warning and the wider set of money lines.
      if (path == '/simulation/run' && body is Map && body['second_outlet'] == true) {
        return _runWithWarning;
      }
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
// Note the 18 tables — fewer than the table_count slider's own minimum of 20,
// which is exactly the case the widened domain exists for.
const _baseline = <String, dynamic>{
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
};

// A run where a 10% price rise trades covers for APC: revenue and profit dip,
// labour rises (an expediter was added), and food cost lands on a delta of
// exactly 0 — the case the reference implementation rendered as ₹NaN.
const _runResult = <String, dynamic>{
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
};

const _runWithWarning = <String, dynamic>{
  'current': {
    'covers': 100, 'apc': 400, 'revenue': 40000, 'labour_cost': 6000,
    'food_cost': 12800, 'marketing_per_day': 0, 'net_profit': 16200, 'tat_min': 42,
    'fixed_cost': 5000,
  },
  'simulated': {
    'covers': 160, 'apc': 400, 'revenue': 64000, 'labour_cost': 12000,
    'food_cost': 20480, 'marketing_per_day': 0, 'net_profit': 21387, 'tat_min': 42,
    'fixed_cost': 10133,
  },
  'delta': {
    'covers': 60, 'apc': 0, 'revenue': 24000, 'labour_cost': 6000,
    'food_cost': 7680, 'marketing_per_day': 0, 'net_profit': 5187, 'tat_min': 0,
    'fixed_cost': 5133,
  },
  'notes': ['Second outlet: +60% of this site\'s covers.'],
  'warnings': [
    'SPECULATIVE: the second-outlet model has never been validated end to end.',
  ],
  'breakeven_days': null,
};

const _routes = <String, dynamic>{
  '/simulation/baseline': _baseline,
  'POST /simulation/run': _runResult,
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
  tester.view.physicalSize = Size(width, 6000);
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

Map _lastBody(_FakeApi api) =>
    api.posts.lastWhere((p) => p.path == '/simulation/run').body! as Map;

// --------------------------------------------------------------- picker ----

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('Add a lever'));
  await tester.pumpAndSettle();
}

Future<void> _searchPicker(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('sim-pick-search')), query);
  await tester.pumpAndSettle();
}

/// Tap outside — the panel closes whichever presentation it is using.
Future<void> _closePicker(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

/// Check/uncheck one lever, narrowing the list by [query] first so the row is
/// built (a 34-row list does not mount what it cannot show) — which exercises
/// the search on the way past.
Future<void> _toggleInPicker(WidgetTester tester, String key, String query) async {
  await _searchPicker(tester, query);
  expect(find.byKey(ValueKey('sim-pick-$key')), findsOneWidget,
      reason: 'searching "$query" should surface $key');
  await tester.tap(find.byKey(ValueKey('sim-pick-$key')));
  await tester.pumpAndSettle();
}

/// Drive a slider through its real onChanged. Dragging by pixels would make
/// every assertion a function of the test window's width.
Future<void> _setLever(WidgetTester tester, String key, double value) async {
  final slider = tester.widget<Slider>(find.byKey(ValueKey('sim-$key')));
  slider.onChanged!(value);
  await tester.pumpAndSettle();
}

void main() {
  // The nav-rail gate, defined at the bottom of this file.
  _gateTests();

  testWidgets('the original eight start active, one header per non-empty category', (tester) async {
    await _mount(tester);

    expect(find.text('What-If Simulator'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(8));
    for (final k in kInitialActiveKeys) {
      expect(find.byKey(ValueKey('sim-$k')), findsOneWidget, reason: '$k slider missing');
    }
    expect(find.text('8 levers in this run.'), findsOneWidget);

    // A category header shows ONLY when one of its parameters is active. The
    // eight touch four of the six categories.
    expect(find.text('PRICING & DEMAND'), findsOneWidget);
    expect(find.text('STAFFING'), findsOneWidget);
    expect(find.text('OPERATIONS'), findsOneWidget);
    expect(find.text('MARKETING & GROWTH'), findsOneWidget);
    expect(find.text('OVERHEAD'), findsNothing, reason: 'nothing in Overhead is active');
    expect(find.text('SCALE'), findsNothing, reason: 'nothing in Scale is active');

    // The live numbers, and the one field the backend had to estimate.
    expect(find.text('Current Performance'), findsOneWidget);
    expect(find.text('₹40000'), findsOneWidget, reason: 'revenue/day');
    expect(find.text('₹16200'), findsOneWidget, reason: 'net profit/day');
    expect(find.text('42 min'), findsWidgets, reason: 'measured TAT (card and lever label)');
    expect(find.text('estimated'), findsOneWidget, reason: 'only fixed costs is sourced "default"');
    expect(find.textContaining('pre-tax'), findsOneWidget);
  });

  testWidgets('running posts exactly the active levers, seeded from the live baseline', (tester) async {
    final api = await _mount(tester);
    await _run(tester);

    final runs = api.posts.where((p) => p.path == '/simulation/run').toList();
    expect(runs.length, 1);
    final body = runs.single.body! as Map;
    expect(body.keys.toSet(), kInitialActiveKeys.toSet());
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

  testWidgets('adding levers across categories brings their headers with them', (tester) async {
    final api = await _mount(tester);

    await _openPicker(tester);
    // Overhead and Scale — two categories with nothing active yet.
    await _toggleInPicker(tester, 'utilities_per_day', 'utilities');
    await _toggleInPicker(tester, 'second_outlet', 'second outlet');
    // And one more inside a category that already has a header.
    await _toggleInPicker(tester, 'waste_pct', 'wastage');
    await _closePicker(tester);

    expect(find.text('OVERHEAD'), findsOneWidget);
    expect(find.text('SCALE'), findsOneWidget);
    expect(find.text('11 levers in this run.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-utilities_per_day')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-second_outlet')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-waste_pct')), findsOneWidget);
    // The speculative lever says so on its own row, not only in the picker.
    expect(find.text('speculative'), findsOneWidget);

    await _run(tester);
    final body = _lastBody(api);
    expect(body.keys.length, 11);
    expect(body['utilities_per_day'], 0);
    expect(body['waste_pct'], 3, reason: 'neutral wastage, mirroring BASELINE_WASTE_PCT');
    expect(body['second_outlet'], false);
  });

  testWidgets('a removed lever is ABSENT from the POST body — not zero', (tester) async {
    final api = await _mount(tester);

    // Remove one lever the tenant has a real measured value for, and one whose
    // neutral value happens to BE zero. Zero-vs-absent is invisible for the
    // second and catastrophic for the first: sending staff_count 0 would
    // simulate a restaurant with nobody in it.
    await tester.tap(find.byKey(const ValueKey('sim-remove-staff_count')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sim-remove-marketing_spend')));
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsNWidgets(6));
    expect(find.text('6 levers in this run.'), findsOneWidget);

    await _run(tester);
    final body = _lastBody(api);
    expect(body.containsKey('staff_count'), isFalse,
        reason: 'a removed lever must be OMITTED so the server resolves the tenant default');
    expect(body.containsKey('marketing_spend'), isFalse);
    expect(body['staff_count'], isNull);
    expect(body.keys.toSet(), {
      'price_adjust_pct', 'elasticity', 'avg_wage_per_shift',
      'tat_target_min', 'extra_expediters', 'food_cost_pct',
    });
  });

  testWidgets('re-adding a lever restores the value it was left at', (tester) async {
    final api = await _mount(tester);

    await _setLever(tester, 'marketing_spend', 25000);
    expect(find.text('₹25000'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sim-remove-marketing_spend')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sim-marketing_spend')), findsNothing);
    await _run(tester);
    expect(_lastBody(api).containsKey('marketing_spend'), isFalse);

    await _openPicker(tester);
    await _toggleInPicker(tester, 'marketing_spend', 'Marketing spend');
    await _closePicker(tester);

    // Back exactly where it was left — not back at the default.
    expect(find.text('₹25000'), findsOneWidget);
    await _run(tester);
    expect(_lastBody(api)['marketing_spend'], 25000);
  });

  testWidgets('the change dot and its reset appear only when the value differs from your default', (tester) async {
    await _mount(tester);

    // Nothing is changed on arrival: every lever sits on the value the server
    // would have resolved for this tenant anyway.
    expect(find.byKey(const ValueKey('sim-dot-price_adjust_pct')), findsNothing);
    expect(find.byKey(const ValueKey('sim-reset-price_adjust_pct')), findsNothing);
    for (final k in kInitialActiveKeys) {
      expect(find.byKey(ValueKey('sim-dot-$k')), findsNothing, reason: '$k should be unchanged');
    }
    // "Reset values" has nothing to do, and a ForkButton with a null onPressed
    // LOOKS disabled — this app's recurring bug is the control that does not.
    expect(find.text('Reset values'), findsOneWidget);

    await _setLever(tester, 'price_adjust_pct', 5);
    expect(find.byKey(const ValueKey('sim-dot-price_adjust_pct')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-reset-price_adjust_pct')), findsOneWidget);
    expect(find.text('+5%'), findsOneWidget);
    expect(find.text('Reset values (1)'), findsOneWidget);
    // Only that one lever wears it.
    expect(find.byKey(const ValueKey('sim-dot-elasticity')), findsNothing);

    // The per-lever reset puts back THAT lever and nothing else.
    await _setLever(tester, 'food_cost_pct', 40);
    expect(find.text('Reset values (2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sim-reset-price_adjust_pct')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sim-dot-price_adjust_pct')), findsNothing);
    expect(find.byKey(const ValueKey('sim-dot-food_cost_pct')), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('Reset values (1)'), findsOneWidget);
  });

  testWidgets('"Reset values" resets every parameter without changing which are active', (tester) async {
    final api = await _mount(tester);

    await _openPicker(tester);
    await _toggleInPicker(tester, 'waste_pct', 'wastage');
    await _closePicker(tester);

    await _setLever(tester, 'price_adjust_pct', 8);
    await _setLever(tester, 'waste_pct', 9);
    await _setLever(tester, 'staff_count', 20);
    expect(find.text('Reset values (3)'), findsOneWidget);

    await tester.tap(find.text('Reset values (3)'));
    await tester.pumpAndSettle();

    expect(find.text('Reset values'), findsOneWidget, reason: 'nothing changed any more');
    for (final k in [...kInitialActiveKeys, 'waste_pct']) {
      expect(find.byKey(ValueKey('sim-dot-$k')), findsNothing);
    }
    // The SELECTION is untouched — 9 levers still on screen, waste_pct included.
    expect(find.text('9 levers in this run.'), findsOneWidget);
    await _run(tester);
    final body = _lastBody(api);
    expect(body.keys.length, 9);
    expect(body['staff_count'], 12, reason: 'back to the tenant default, not to zero');
    expect(body['waste_pct'], 3);
  });

  testWidgets('with nothing active the screen says so and the run posts an empty body', (tester) async {
    final api = await _mount(tester);

    for (final k in kInitialActiveKeys) {
      await tester.tap(find.byKey(ValueKey('sim-remove-$k')));
      await tester.pumpAndSettle();
    }

    expect(find.byType(Slider), findsNothing);
    expect(find.text("Nothing active. Use '+ Add a lever' to pick what you want to test."),
        findsOneWidget);
    expect(find.text('No levers active — this runs your baseline unchanged.'), findsOneWidget);

    await _run(tester);
    // An empty body is a complete instruction: every field resolves to this
    // tenant's own neutral value, so this runs their baseline unchanged.
    expect(_lastBody(api), isEmpty);
  });

  testWidgets('the second outlet is gated on the Enterprise plan, and says why', (tester) async {
    final api = await _mount(tester);

    await _openPicker(tester);
    await _toggleInPicker(tester, 'second_outlet', 'second outlet');
    await _closePicker(tester);

    // No plan_tier lever on screen: the server would resolve the tier to
    // "starter", so the toggle must not pretend otherwise.
    Switch outlet() => tester.widget<Switch>(find.byKey(const ValueKey('sim-second_outlet')));
    expect(outlet().onChanged, isNull, reason: 'a Starter plan cannot switch it on');
    expect(find.textContaining('Add the "Subscription plan" lever'), findsOneWidget);

    await _openPicker(tester);
    await _toggleInPicker(tester, 'plan_tier', 'Subscription plan');
    await _closePicker(tester);

    // Now the lever exists but is on Starter, so the sentence changes to one
    // the owner can actually act on.
    expect(outlet().onChanged, isNull);
    expect(find.textContaining('Switch the "Subscription plan" lever'), findsOneWidget);

    await tester.tap(find.text('Enterprise'));
    await tester.pumpAndSettle();
    expect(outlet().onChanged, isNotNull, reason: 'Enterprise includes multi-outlet');
    expect(find.textContaining('Enterprise-plan capability'), findsNothing);
    // The segmented control and the toggle wear the same change-dot and the
    // same per-lever reset as the sliders do — they are levers, not settings.
    expect(find.byKey(const ValueKey('sim-dot-plan_tier')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-reset-plan_tier')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sim-second_outlet')));
    await tester.pumpAndSettle();
    expect(find.text('On'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-dot-second_outlet')), findsOneWidget);

    await _run(tester);
    final body = _lastBody(api);
    expect(body['plan_tier'], 'enterprise');
    expect(body['second_outlet'], true);
    // The speculative model announces itself above its own numbers.
    expect(find.textContaining('SPECULATIVE'), findsWidgets);
    expect(find.text('Fixed costs / day'), findsOneWidget,
        reason: 'the fixed-cost row appears once the run actually carries one');

    // Dropping back to Starter must NOT strand an owner with a lever they
    // cannot switch off again.
    await tester.tap(find.text('Starter'));
    await tester.pumpAndSettle();
    expect(outlet().onChanged, isNotNull, reason: 'still switchable OFF');
    expect(find.textContaining('Switched on, but the Starter plan'), findsOneWidget);

    // Removing the plan lever entirely is the same story: the server resolves a
    // missing tier to "starter", so the screen must not keep granting Enterprise.
    await tester.tap(find.byKey(const ValueKey('sim-remove-plan_tier')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Add the "Subscription plan" lever'), findsOneWidget);
    await _run(tester);
    expect(_lastBody(api).containsKey('plan_tier'), isFalse);
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

    // Rows the run carried no number for stay off the table entirely.
    expect(find.text('Service charge / day'), findsNothing);
    expect(find.text('Tax collected / day'), findsNothing);

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

  testWidgets('the picker searches the whole catalogue and reports what is active', (tester) async {
    await _mount(tester);
    await _openPicker(tester);

    // Unfiltered: all 34, under all six headers.
    expect(find.textContaining('8 of 34 levers active'), findsOneWidget);
    for (final g in kParamGroups) {
      expect(find.text(g.toUpperCase()), findsWidgets, reason: '$g header missing from the picker');
    }

    // The search crosses categories: "cost" hits Operations, Overhead and more.
    await _searchPicker(tester, 'cost');
    expect(find.byKey(const ValueKey('sim-pick-food_cost_pct')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-pick-fixed_costs_per_day')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-pick-elasticity')), findsNothing);

    await _searchPicker(tester, 'zzzz');
    expect(find.textContaining('No parameter matches'), findsOneWidget);

    // Checking updates the count live, without closing the panel — and the
    // SAME checkbox unchecks, which is how a lever comes back out.
    await _toggleInPicker(tester, 'table_count', 'Tables');
    expect(find.textContaining('9 of 34 levers active'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sim-pick-table_count')));
    await tester.pumpAndSettle();
    expect(find.textContaining('8 of 34 levers active'), findsOneWidget);
    await _toggleInPicker(tester, 'table_count', 'Tables');

    await _closePicker(tester);
    expect(find.byKey(const ValueKey('sim-table_count')), findsOneWidget);
  });

  testWidgets('a lever that overrides a measurement keeps that measurement as its default', (tester) async {
    final api = await _mount(tester);

    await _openPicker(tester);
    await _toggleInPicker(tester, 'table_count', 'Tables');
    await _closePicker(tester);

    // The tenant has 18 tables; the slider's own range starts at 20. The value
    // is NOT clamped up — that would silently simulate a bigger restaurant —
    // the domain widens instead, exactly as the backend's clampMeasured does.
    expect(find.text('18 tables'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-dot-table_count')), findsNothing,
        reason: '18 IS this tenant\'s default, so no change dot');
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('sim-table_count')));
    expect(slider.min, 18);
    expect(slider.max, 150);

    await _run(tester);
    expect(_lastBody(api)['table_count'], 18);
  });

  testWidgets('offline says the projection needs a line, not that work was lost', (tester) async {
    final api = await _mount(tester);
    api.offline = true;
    await _run(tester);

    // /simulation/run is a POST that stores nothing, and it is correctly NOT on
    // the outbox's 27-route allowlist. The generic refusal there ("This isn't
    // saved offline") describes a dropped write, which is not what happened.
    expect(find.textContaining("isn't saved offline"), findsNothing);
    expect(find.textContaining('The simulator needs a connection'), findsOneWidget);
    expect(find.textContaining('no work was lost'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    // The levers survived the failed run, so a retry needs no re-setup.
    api.offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('DELTA'), findsOneWidget);
    expect(_lastBody(api).keys.toSet(), kInitialActiveKeys.toSet());
  });

  testWidgets('the picker is a bottom sheet on a phone and an anchored popover on desktop', (tester) async {
    // PHONE: 34 rows and a search box do not fit under a button on a phone, so
    // the picker takes the sheet the rest of the app already uses.
    await _mount(tester, width: 390);
    await _openPicker(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await _closePicker(tester);
    expect(find.byKey(const ValueKey('sim-pick-search')), findsNothing);

    // DESKTOP: a popover under the button, where the eye already is.
    await _mount(tester, width: 1200);
    await _openPicker(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('sim-pick-search')), findsOneWidget);
    await _closePicker(tester);
    expect(find.byKey(const ValueKey('sim-pick-search')), findsNothing);
  });

  testWidgets('a short desktop window flips the popover up instead of off the bottom', (tester) async {
    // Wide enough for the desktop path (760dp), short enough that there is no
    // room for a 360-wide panel under the button.
    await tester.pumpWidget(const SizedBox());
    tester.view.physicalSize = const Size(1100, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi(_routes);
    final auth = AuthController(api: api);
    await auth.login('CSR Organics', 'admin', 'admin123');
    await tester.pumpWidget(_host(m.simulationModule(RestClient(auth), auth.profile!)));
    await tester.pumpAndSettle();

    await _openPicker(tester);
    final panel = tester.getRect(find.byKey(const ValueKey('sim-pick-search')));
    expect(panel.top, greaterThanOrEqualTo(0.0));
    expect(panel.bottom, lessThanOrEqualTo(420.0), reason: 'the panel must be on screen');
    // Still usable: the search box works and a lever can be added from it.
    await _toggleInPicker(tester, 'waste_pct', 'wastage');
    await _closePicker(tester);
    expect(find.byKey(const ValueKey('sim-waste_pct')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('levers, baseline and results all lay out on a 320dp phone', (tester) async {
    await _mount(tester, width: 320);
    await _openPicker(tester);
    await _toggleInPicker(tester, 'plan_tier', 'Subscription plan');
    await _toggleInPicker(tester, 'second_outlet', 'second outlet');
    await _closePicker(tester);
    await _run(tester);

    expect(find.text('DELTA'), findsOneWidget);
    expect(find.text('+₹40'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// THE PERMISSION GATE. This regressed once already and nothing was watching.
//
// home_shell.dart:96-99 records what happened: the tile was given the keyword
// list ['analytics','simulation','what-if'], which reads as obviously correct
// and is wrong. `Profile.can` substring-matches permitted ACTION NAMES, and the
// action that authorizes /simulation/* server-side is named "View Order APC" —
// it contains 'apc', not 'simulation'. So a manager holding exactly that action
// could open Simulation on the web and found no tile here. Keywords that match
// no action name are not harmless padding; they silently narrow the gate.
//
// The Reports twin of this test lives in reports_module_test.dart. This is the
// eight lines that would have caught it.
// ---------------------------------------------------------------------------

class _GateApi extends ApiClient {
  _GateApi({required this.actions, required this.actionNames, this.features = const {}, this.role});
  final List<String> actions;
  final List<String> actionNames;
  final Map<String, dynamic> features;

  /// The signed-in ROLE, for the cases that are about the role rather than the
  /// action. Null keeps the old shorthand (wildcard = admin, else waiter).
  final String? role;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': role ?? (actions.contains('*') ? 'admin' : 'waiter'),
          'actions_set': actions,
          'action_names': actionNames,
          'features': features,
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    throw ApiException('No fake route for $path', 404);
  }
}

Future<void> _pumpGateShell(
  WidgetTester tester, {
  required List<String> actions,
  required List<String> actionNames,
  Map<String, dynamic> features = const {},
  String? role,
}) async {
  await tester.pumpWidget(const SizedBox());
  // Tall on purpose: the nav rail is a lazy ListView, so a module below the
  // fold is not in the tree at all — and this is about WHERE Simulation is
  // registered, not about scrolling a sidebar.
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(
      api: _GateApi(
          actions: actions, actionNames: actionNames, features: features, role: role));
  await auth.login('CSR Organics', 'u', 'p');
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump();
  await tester.pump();
}

void _gateTests() {
  testWidgets('the shell lists Simulation under INSIGHTS, gated exactly as its routes are',
      (tester) async {
    // Admin sees it, beside the analytics it is computed from.
    await _pumpGateShell(tester, actions: const ['*'], actionNames: const []);
    expect(find.text('INSIGHTS'), findsOneWidget);
    expect(find.text('Simulation'), findsOneWidget);

    // THE REGRESSION CASE. A role granted only the action /simulation/* actually
    // validates — df75119b, whose NAME is "View Order APC". If someone ever
    // "tidies" the keyword list to mention simulation, this is the assertion
    // that fails.
    await _pumpGateShell(
        tester,
        actions: const ['df75119b'],
        actionNames: const ['View Order APC'],
        role: 'manager');
    expect(find.text('Simulation'), findsOneWidget,
        reason: 'the gate must mirror the server action, whose name says APC, not simulation');
    expect(find.text('Analytics'), findsOneWidget,
        reason: 'Simulation and Analytics share one gate; they must appear together');

    // A waiter does not. The gate is the server's, mirrored — not a wider one.
    await _pumpGateShell(tester, actions: const ['x'], actionNames: const ['Add Orders']);
    expect(find.text('Simulation'), findsNothing);

    // A WAITER WHOSE TENANT GRANTED THE ACTION STILL DOES NOT. The one
    // deliberate narrowing: what-if planning over the restaurant's revenue is
    // the restaurant's money, and RoleScope answers "what is this person here to
    // do" where the per-tenant action grant cannot. Analytics goes with it, for
    // the same reason and by the same rule.
    await _pumpGateShell(
        tester,
        actions: const ['df75119b'],
        actionNames: const ['View Orders', 'View Order APC']);
    expect(find.text('Simulation'), findsNothing);
    expect(find.text('Analytics'), findsNothing);

    // Nor does a tenant whose plan drops analytics: the projection is computed
    // from data that flag governs, so the tile goes with the 403.
    await _pumpGateShell(
      tester,
      actions: const ['*'],
      actionNames: const [],
      features: const {'analytics': false},
    );
    expect(find.text('Simulation'), findsNothing);
    expect(find.text('Analytics'), findsNothing, reason: 'both ride the same flag');
  });
}
