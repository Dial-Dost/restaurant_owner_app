// The three ALLOCATED screens, mounted in both design systems.
//
// The unit tests next door prove the primitives are honest. This file proves
// two things about the application of them:
//
//   1. Rustic Fork is untouched. Every one of these screens, with the design
//      system at its default, renders exactly the shipped widgets and none of
//      the new ones. Abandoning this work has to cost a setting.
//   2. The restyle is a RESTYLE. Simulation's contract — an inactive lever is
//      omitted from the POST body so the server resolves it to this tenant's
//      own neutral value — is byte-for-byte identical on the champagne slab as
//      it is on the dark card. That contract is the reason the picker is safe,
//      and a visual pass is exactly the kind of change that would break it
//      without anyone noticing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/simulation_params.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/date_range_picker.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_tabs.dart';
import 'package:restaurant_owner_app/ui/widgets/section_header.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  final List<({String path, Object? body})> posts = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
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
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method == 'POST') {
      posts.add((path: path, body: body));
      return routes['POST $path'] ?? <String, dynamic>{};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
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
          visibleLabels: const ['Analytics', 'History', 'Simulation'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: AppColors.bg, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient) module,
  Map<String, dynamic> routes, {
  required DesignSystem system,
  double width = 430,
  double height = 6000,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(module(rest), system));
  await tester.pumpAndSettle();
  return api;
}

// ── History: a window whose months genuinely add up ──────────────────────────
// One large month, one middling, one at exactly zero. The zero is the point:
// it is what the shipped bar chart draws as nothing at all.
Map<String, dynamic> _historyRoutes() => {
      '/analytics/history': {
        'series': [
          {
            'month': '2026-08',
            'revenue': 177214,
            'bills': 49,
            'orders': 61,
            'avg_bill': 3617,
            'new_customers': 16,
            'feedback_count': 12,
            'avg_rating': 4.55,
          },
          {
            'month': '2026-07',
            'revenue': 59071,
            'bills': 20,
            'orders': 24,
            'avg_bill': 2953,
            'new_customers': 4,
            'feedback_count': 0,
          },
          {
            'month': '2026-06',
            'revenue': 0,
            'bills': 0,
            'orders': 3,
            'avg_bill': 0,
            'new_customers': 0,
            'feedback_count': 0,
          },
        ],
      },
    };

Map<String, dynamic> _analyticsRoutes() => {
      '/orders/apc': {
        'monthly_apc': 1114.55,
        'total_revenue': 177214,
        'total_covers': 159,
        'month': 'August 2026',
        'employee_incentives': <dynamic>[],
        'orders': <dynamic>[],
      },
      '/feedback/summary': {'averageRating': 4.55, 'totalResponses': 12},
      '/orders/daily-revenue': {
        'series': [
          for (var i = 0; i < 14; i++)
            {'date': '2026-08-${(i + 1).toString().padLeft(2, '0')}', 'revenue': 12000 + i * 1500},
        ],
      },
      '/orders/timing-stats': {'avg_prep_ms': 4320000},
      '/orders/apc-trends': {'series': <dynamic>[]},
      '/analytics/advanced': {
        'kpis': [
          {'key': 'table_turnaround', 'label': 'Table turnaround', 'value': 107.9, 'unit': ' min', 'status': 'red'},
          {'key': 'revpash', 'label': 'RevPASH', 'value': 1.71, 'unit': '', 'status': 'red'},
          {'key': 'nps', 'label': 'NPS', 'value': 54.55, 'unit': '', 'status': 'green'},
        ],
      },
    };

const _simBaseline = <String, dynamic>{
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
  'sources': {'fixed_costs_per_day': 'default'},
};

const _simRun = <String, dynamic>{
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
  'notes': <String>[],
  'breakeven_days': null,
};

Map<String, dynamic> _simRoutes() => {
      '/simulation/baseline': _simBaseline,
      'POST /simulation/run': _simRun,
    };

void main() {
  group('the default is untouched — Rustic Fork renders none of this', () {
    testWidgets('History keeps its month cards and its bar chart', (tester) async {
      await _mount(tester, (r) => m.historyModule(r, r.auth.profile!), _historyRoutes(),
          system: DesignSystem.rustic);
      expect(find.byType(GaiaStrataList), findsNothing);
      expect(find.byType(GaiaStrataChart), findsNothing);
      expect(find.byType(ForkCard), findsWidgets);
      expect(find.text('Aug 2026'), findsWidgets);
    });

    testWidgets('Analytics keeps its KPI tiles', (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          system: DesignSystem.rustic);
      expect(find.byType(GaiaStrataList), findsNothing);
      expect(find.byType(GaiaStrataChart), findsNothing);
      expect(find.text('TABLE TURNAROUND'), findsOneWidget);
    });

    testWidgets('Simulation keeps its card and its table', (tester) async {
      await _mount(tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.rustic);
      // The results table only exists after a run — before one, the card says
      // so rather than showing an empty grid.
      await tester.tap(find.text('Run Simulation'));
      await tester.pumpAndSettle();
      expect(find.byType(GaiaBicolourPanel), findsNothing);
      expect(find.byType(GaiaBicolourSplit), findsNothing);
      expect(find.byType(GaiaDeltaRow), findsNothing);
      expect(find.byType(Table), findsWidgets);
      expect(find.text('What-If Simulator'), findsOneWidget);
    });
  });

  group('STRATA · History', () {
    testWidgets('the month list becomes strata, and a zero month is still on '
        'the page with its figure', (tester) async {
      await _mount(tester, (r) => m.historyModule(r, r.auth.profile!), _historyRoutes(),
          system: DesignSystem.gaia);
      final list = tester.widget<GaiaStrataList>(find.byType(GaiaStrataList));
      expect(list.mode, GaiaStrataMode.share,
          reason: 'months are parts of the window total, so share is legitimate');
      expect(list.strata.length, 3);
      // The zero month is a band, not an omission. (It also names the chart's
      // left axis, which is why this is findsWidgets rather than one.)
      expect(list.strata.map((s) => s.label), contains('Jun 2026'));
      expect(find.text('JUN 2026'), findsWidgets);
      expect(find.text('ZERO'), findsOneWidget);
      // And the two real months are in true proportion: 177214 : 59071 = 3 : 1.
      final aug = list.strata[0].value;
      final jul = list.strata[1].value;
      expect(aug / jul, closeTo(3, 0.01));
    });

    testWidgets('the window picker and the headline totals survive the restyle',
        (tester) async {
      await _mount(tester, (r) => m.historyModule(r, r.auth.profile!), _historyRoutes(),
          system: DesignSystem.gaia);
      expect(find.byType(DateRangeChip), findsOneWidget,
          reason: 'the shipped date-range control stays');
      expect(find.text('TOTAL REVENUE'), findsOneWidget);
    });

    testWidgets('the chart becomes the stacked area', (tester) async {
      await _mount(tester, (r) => m.historyModule(r, r.auth.profile!), _historyRoutes(),
          system: DesignSystem.gaia);
      expect(find.byType(GaiaStrataChart), findsOneWidget);
    });

    testWidgets('a month still opens its own detail', (tester) async {
      await _mount(tester, (r) => m.historyModule(r, r.auth.profile!), _historyRoutes(),
          system: DesignSystem.gaia);
      final list = tester.widget<GaiaStrataList>(find.byType(GaiaStrataList));
      for (final s in list.strata) {
        expect(s.onTap, isNotNull, reason: '${s.label} became a dead band');
      }
    });
  });

  group('STRATA · Analytics', () {
    testWidgets('KPI health becomes strata in RANK mode — no share is claimed '
        'between metrics that share no total', (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          system: DesignSystem.gaia);
      final lists = tester
          .widgetList<GaiaStrataList>(find.byType(GaiaStrataList))
          .toList();
      expect(lists, isNotEmpty);
      final kpi = lists.firstWhere((l) => l.strata.any((s) => s.label == 'RevPASH'));
      expect(kpi.mode, GaiaStrataMode.rank);
      expect(find.text('ACTION'), findsNWidgets(2));
      expect(find.text('ON TARGET'), findsOneWidget);
    });

    testWidgets('the window picker and the view tabs survive the restyle',
        (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          system: DesignSystem.gaia);
      // The top picker, pinned on its own: exactly one full-size chip, outside
      // every section header. Counting chips is not enough since the Kitchen and
      // Actionable insights headers carry live copies (they were static pills),
      // and those alone would satisfy "a chip is on screen".
      final top = find.byWidgetPredicate((w) => w is DateRangeChip && !w.dense, description: 'the top DateRangeChip');
      expect(top, findsOneWidget, reason: 'the page-level window picker is gone');
      expect(find.ancestor(of: top, matching: find.byType(SectionHeader)), findsNothing);
      // The header copies: dense, inside a header, and on the ONE module window.
      final inHeaders = find.descendant(of: find.byType(SectionHeader), matching: find.byType(DateRangeChip));
      expect(inHeaders, findsNWidgets(2), reason: 'Kitchen and Actionable insights');
      expect(find.byType(DateRangeChip), findsNWidgets(3), reason: 'a chip outside both the top and a header');
      final window = tester.widget<DateRangeChip>(top).value.label();
      for (final c in tester.widgetList<DateRangeChip>(inHeaders)) {
        expect(c.dense, isTrue, reason: 'a header copy must be the dense chip');
        expect(c.value.label(), window, reason: 'a header chip is on a different window from the top picker');
      }
      expect(find.byType(ForkTabs), findsOneWidget);
    });

    testWidgets('a KPI band still opens its drill-down', (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          system: DesignSystem.gaia);
      final kpi = tester
          .widgetList<GaiaStrataList>(find.byType(GaiaStrataList))
          .firstWhere((l) => l.strata.any((s) => s.label == 'RevPASH'));
      for (final s in kpi.strata) {
        expect(s.onTap, isNotNull);
      }
    });
  });

  group('BICOLOUR · Simulation', () {
    testWidgets('the levers panel becomes the slab and the split heads the '
        'screen', (tester) async {
      await _mount(tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.gaia);
      expect(find.byType(GaiaBicolourPanel), findsOneWidget);
      expect(find.byType(GaiaBicolourSplit), findsOneWidget);
      expect(find.text('Levers'), findsOneWidget);
    });

    testWidgets('the scenario half stays at rest until a run', (tester) async {
      await _mount(tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.gaia);
      expect(find.textContaining('Nothing run yet'), findsOneWidget);
      await tester.tap(find.text('RUN SIMULATION'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing run yet'), findsNothing);
    });

    testWidgets('the results table becomes delta rows, with a direction glyph '
        'on every non-zero delta', (tester) async {
      await _mount(tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.gaia);
      await tester.tap(find.text('RUN SIMULATION'));
      await tester.pumpAndSettle();
      expect(find.byType(GaiaDeltaRow), findsWidgets);
      // Food cost moved by exactly zero — no sign, no arrow, no status ink.
      // That case is the one the reference implementation rendered as ₹NaN.
      expect(find.text('₹0'), findsWidgets);
      // Net profit fell: a bad move, so a down arrow as well as the red.
      expect(find.textContaining('▼'), findsWidgets);
      expect(find.textContaining('NaN'), findsNothing);
    });

    testWidgets('THE CONTRACT: the run body is identical on the slab and on '
        'the card', (tester) async {
      final gaia = await _mount(
          tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.gaia);
      await tester.tap(find.text('RUN SIMULATION'));
      await tester.pumpAndSettle();
      final gaiaBody =
          gaia.posts.lastWhere((p) => p.path == '/simulation/run').body! as Map;

      final rustic = await _mount(
          tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.rustic);
      await tester.tap(find.text('Run Simulation'));
      await tester.pumpAndSettle();
      final rusticBody =
          rustic.posts.lastWhere((p) => p.path == '/simulation/run').body! as Map;

      expect(gaiaBody.keys.toSet(), rusticBody.keys.toSet(),
          reason: 'the restyle must not add or drop a single lever');
      for (final k in rusticBody.keys) {
        expect(gaiaBody[k], rusticBody[k], reason: 'lever "$k" differs');
      }
      // And the omit-inactive contract itself still holds on BOTH grounds: the
      // body carries the active levers and nothing else, so every one of the
      // other catalogue parameters is resolved server-side to this tenant's own
      // neutral value rather than arriving as a zero.
      expect(kParamCatalog.length, greaterThan(kInitialActiveKeys.length));
      expect(rusticBody.keys.toSet(), kInitialActiveKeys.toSet());
      expect(gaiaBody.keys.toSet(), kInitialActiveKeys.toSet());
    });

    testWidgets('the picker still opens from the slab', (tester) async {
      await _mount(tester, (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
          system: DesignSystem.gaia);
      await tester.tap(find.text('ADD A LEVER'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sim-pick-search')), findsOneWidget);
    });
  });
}
