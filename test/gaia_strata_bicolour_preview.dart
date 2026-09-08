// A PREVIEW RENDERER for STRATA and BICOLOUR, not a test.
//
// Deliberately NOT named *_test.dart, for the same reason as `gaia_preview
// .dart`: it asserts nothing and renders pictures, so `flutter test` must never
// collect it. Run it by path:
//
//     flutter test test/gaia_strata_bicolour_preview.dart
//
// It writes PNGs to build/gaia_preview/, named `strata-*` and `bicolour-*`.
// The prefix is not decoration: the other signature styles have their own
// preview renderer writing into the same directory, and a shared numeric
// sequence silently overwrites whichever ran second.
//
// The three screens are the REAL modules — `analyticsModule`, `historyModule`
// and `simulationModule` as the app runs them — mounted against a fake API and
// photographed under each design system in turn. They are pictures of the
// shipping widgets, not of a mock-up of them.
//
// Fonts have to be registered by hand: `flutter test` paints every glyph in
// Ahem (solid boxes) unless the real files are loaded, and the whole point of
// the Gaia work is Cormorant figures against Instrument Sans labels. Rustic
// Fork bundles no font of its own, so its reference shots come out in Ahem
// boxes — expected, and the reason those pictures are for LAYOUT comparison
// only. Material icons are not registered either, so every glyph icon renders
// as a hollow box in BOTH systems' pictures; that is the harness, not the
// design.
//
// ## Each picture takes several minutes and the runner reports a timeout
//
// Every test here writes its PNG and then sits until the harness's ten-minute
// per-test limit. The picture on disk at that point is COMPLETE and correct —
// the log line naming it is printed as the last statement of the shot — so the
// output is trustworthy even though the run is reported as failing.
//
// The cause is the combination this file cannot avoid: `tester.runAsync` (the
// only way to register a real font) plus a real module tree whose AsyncViews
// hold periodic timers. Awaiting every real-async step inside one runAsync did
// not fix it, and pumping the tree away after the shot made it WORSE — that
// raises TestAsyncUtils' guarded-function conflict, which fails all eight
// tests at once instead of one every ten minutes, so you get a single picture
// per run instead of eight. Do not add a pump after `_shoot`. Since nothing
// here asserts anything, the timeout costs wall-clock and nothing else.
//
// What DOES help: run it as two processes over disjoint halves, which is a
// straight halving of the wall clock —
//
//     flutter test test/gaia_strata_bicolour_preview.dart --name "History under|Analytics under"
//     flutter test test/gaia_strata_bicolour_preview.dart --name "Simulation under|specimen"

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      loader.addFont(
        File(p).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
    }
    await loader.load();
  }

  await load('Cormorant Garamond', [
    'assets/fonts/CormorantGaramond-Regular.ttf',
    'assets/fonts/CormorantGaramond-Italic.ttf',
  ]);
  await load('Instrument Sans', [
    'assets/fonts/InstrumentSans-Regular.ttf',
    'assets/fonts/InstrumentSans-Italic.ttf',
  ]);
}

Future<void> _shoot(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('build/gaia_preview')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote build/gaia_preview/$name.png');
}

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Test',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method == 'POST') return routes['POST $path'] ?? <String, dynamic>{};
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

// ── The tenant in the pictures ──────────────────────────────────────────────
// The mockup's own numbers, so the screenshots can be held against it: one
// heavy August, a lighter July, and months at exactly zero — which is the case
// the whole "zero renders honestly" rule exists for.

Map<String, dynamic> _historyRoutes() => {
      '/analytics/history': {
        'series': [
          {
            'month': '2026-08', 'revenue': 177214, 'bills': 49, 'orders': 61,
            'avg_bill': 3617, 'new_customers': 16, 'feedback_count': 12,
            'avg_rating': 4.55, 'avg_tat_min': 107.9,
          },
          {
            'month': '2026-07', 'revenue': 59071, 'bills': 20, 'orders': 24,
            'avg_bill': 2953, 'new_customers': 4, 'feedback_count': 3,
            'avg_rating': 4.2,
          },
          {
            'month': '2026-06', 'revenue': 8940, 'bills': 4, 'orders': 5,
            'avg_bill': 2235, 'new_customers': 1, 'feedback_count': 0,
          },
          {
            'month': '2026-05', 'revenue': 0, 'bills': 0, 'orders': 2,
            'avg_bill': 0, 'new_customers': 0, 'feedback_count': 0,
          },
          {
            'month': '2026-04', 'revenue': 0, 'bills': 0, 'orders': 1,
            'avg_bill': 0, 'new_customers': 0, 'feedback_count': 0,
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
        'orders': [
          {'table_name': 'T1', 'total': 41870},
          {'table_name': 'T4', 'total': 33210},
          {'table_name': 'T7', 'total': 28640},
          {'table_name': 'T2', 'total': 19120},
          {'table_name': 'T9', 'total': 14480},
          {'table_name': 'T3', 'total': 11250},
          {'table_name': 'T5', 'total': 9380},
          {'table_name': 'T8', 'total': 7940},
          {'table_name': 'T6', 'total': 6210},
          {'table_name': 'T10', 'total': 5114},
        ],
      },
      '/feedback/summary': {'averageRating': 4.55, 'totalResponses': 12},
      '/orders/daily-revenue': {
        'series': [
          for (var i = 0; i < 14; i++)
            {
              'date': '2026-08-${(i + 15).toString().padLeft(2, '0')}',
              'revenue': 9800 + (i * 900) + (i.isEven ? 1600 : 0),
            },
        ],
      },
      '/orders/timing-stats': {'avg_prep_ms': 1444000},
      '/orders/apc-trends': {'series': <dynamic>[]},
      '/analytics/advanced': {
        'kpis': [
          {'key': 'table_turnaround', 'label': 'Table turnaround', 'value': 107.9, 'unit': ' min', 'status': 'red'},
          {'key': 'revpash', 'label': 'RevPASH', 'value': 1.71, 'unit': '', 'status': 'red'},
          {'key': 'avg_rating', 'label': 'Feedback rating', 'value': 4.55, 'unit': '/5', 'status': 'green'},
          {'key': 'nps', 'label': 'NPS', 'value': 54.55, 'unit': '', 'status': 'green'},
          {'key': 'labour_cost', 'label': 'Labour cost', 'value': null, 'unit': '', 'status': 'grey'},
        ],
      },
    };

const _simBaseline = <String, dynamic>{
  'window_days': 30,
  'covers_per_day': 5.3,
  'apc': 1051,
  'revenue_per_day': 5573,
  'food_cost_pct': 32,
  'labour_cost_per_day': 6300,
  'staff_count': 6,
  'avg_tat_min': 107.9,
  'table_count': 72,
  'fixed_costs_per_day': 1783,
  'net_profit_per_day': -2510,
  'sources': {'fixed_costs_per_day': 'default'},
};

const _simRun = <String, dynamic>{
  'current': {
    'covers': 5.3, 'apc': 1051, 'revenue': 5573, 'labour_cost': 6300,
    'food_cost': 1783, 'marketing_per_day': 0, 'net_profit': -2510, 'tat_min': 107.9,
  },
  'simulated': {
    'covers': 5.5, 'apc': 935, 'revenue': 5097, 'labour_cost': 12450,
    'food_cost': 2956, 'marketing_per_day': 0, 'net_profit': -10309, 'tat_min': 104.9,
  },
  'delta': {
    'covers': 0.2, 'apc': -116, 'revenue': -476, 'labour_cost': 6150,
    'food_cost': 1173, 'marketing_per_day': 0, 'net_profit': -7799, 'tat_min': -3,
  },
  'notes': [
    'Price cut of 11%: demand responds x1.10 at elasticity -0.9.',
    'One extra expediter cuts achievable turnaround to 104.9 min.',
  ],
  'breakeven_days': null,
};

Map<String, dynamic> _simRoutes() => {
      '/simulation/baseline': _simBaseline,
      'POST /simulation/run': _simRun,
    };

Widget _frame(Widget child, DesignSystem system, Size size) => RepaintBoundary(
      key: const ValueKey('shot'),
      child: GaiaScope(
        system: system,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
            home: ModuleNavigator(
              openModule: (_, {Map<String, dynamic>? target}) {},
              visibleLabels: const ['Analytics', 'History', 'Simulation'],
              clearFocus: () {},
              child: Scaffold(
                backgroundColor: AppColors.bg,
                body: SizedBox(width: size.width, height: size.height, child: child),
              ),
            ),
          ),
        ),
      ),
    );

Future<RestClient> _signIn(Map<String, dynamic> routes) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi(routes));
  await auth.login('Gaia Test', 'admin', 'admin123');
  return RestClient(auth);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// One system per test. Flipping mid-test and awaiting toImage() again wedges
  /// flutter_test's fake-async zone (see the note in `gaia_preview.dart`); the
  /// live flip is covered properly by `gaia_design_system_test.dart`.
  Future<void> shot(
    WidgetTester tester,
    String name,
    DesignSystem system,
    Widget Function(RestClient) module,
    Map<String, dynamic> routes, {
    Size size = const Size(430, 1500),
    Future<void> Function(WidgetTester)? after,
  }) async {
    // EVERY real-async thing this test does happens inside ONE runAsync, and
    // every one of them is awaited: loading four variable fonts, flipping the
    // design system (which persists through a platform channel) and signing in
    // to the fake API. Leaving any of them dangling — `unawaited`, or awaited
    // outside a runAsync — parks a Future on a clock the fake-async zone never
    // advances, and the test then runs to its ten-minute timeout AFTER the
    // picture has already been written. That looked exactly like "rendering is
    // slow" for eight pictures in a row.
    final rest = await tester.runAsync(() async {
      await _loadFonts();
      AppearanceController.instance.debugReset();
      if (system == DesignSystem.gaia) {
        await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      }
      return _signIn(routes);
    });
    tester.view.physicalSize = Size(size.width * 2, size.height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_frame(module(rest!), system, size));
    await tester.pumpAndSettle();
    if (after != null) await after(tester);
    await _shoot(tester, name);
    AppearanceController.instance.debugReset();
  }

  // ── STRATA ────────────────────────────────────────────────────────────────

  testWidgets('History under Rustic Fork', (tester) async {
    await shot(tester, 'strata-1-history-rustic', DesignSystem.rustic,
        (r) => m.historyModule(r, r.auth.profile!), _historyRoutes());
  });

  testWidgets('History under Gaia — STRATA', (tester) async {
    await shot(tester, 'strata-2-history-gaia', DesignSystem.gaia,
        (r) => m.historyModule(r, r.auth.profile!), _historyRoutes());
  });

  testWidgets('Analytics under Rustic Fork', (tester) async {
    await shot(tester, 'strata-3-analytics-rustic', DesignSystem.rustic,
        (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
        size: const Size(430, 1900));
  });

  testWidgets('Analytics under Gaia — STRATA', (tester) async {
    await shot(tester, 'strata-4-analytics-gaia', DesignSystem.gaia,
        (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
        size: const Size(430, 1900));
  });

  // ── BICOLOUR ──────────────────────────────────────────────────────────────

  Future<void> run(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('Simulation under Rustic Fork', (tester) async {
    await shot(tester, 'bicolour-1-simulation-rustic', DesignSystem.rustic,
        (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
        // Tall enough to reach the results table: the split, the slab, the
        // baseline card AND the delta rows are all one scroll on this screen,
        // and a picture that stops above the deltas misses half of BICOLOUR.
        size: const Size(430, 3400),
        after: (t) => run(t, 'Run Simulation'));
  });

  testWidgets('Simulation under Gaia — BICOLOUR', (tester) async {
    await shot(tester, 'bicolour-2-simulation-gaia', DesignSystem.gaia,
        (r) => m.simulationModule(r, r.auth.profile!), _simRoutes(),
        size: const Size(430, 3400),
        after: (t) => run(t, 'RUN SIMULATION'));
  });

  // ── The primitives on their own, at the mockup's own numbers ──────────────

  testWidgets('a STRATA specimen — the stacked chart and both band modes',
      (tester) async {
    await tester.runAsync(() async {
      await _loadFonts();
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
    });
    tester.view.physicalSize = const Size(860, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_frame(
      SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const GaiaWordmark(text: 'GAIA', section: 'Strata'),
          const SizedBox(height: 18),
          const GaiaEyebrow('Revenue by tender, fourteen evenings'),
          const SizedBox(height: 14),
          GaiaStrataChart(
            series: const [
              GaiaStrataSeries(label: 'Cash', values: [
                16, 15, 17, 16, 18, 16, 15, 17, 16, 18, 17, 16, 18, 19
              ]),
              GaiaStrataSeries(label: 'Card', values: [
                38, 36, 39, 41, 40, 42, 41, 43, 44, 43, 45, 46, 45, 47
              ]),
              GaiaStrataSeries(label: 'UPI', values: [
                46, 48, 47, 50, 52, 51, 54, 53, 56, 58, 57, 60, 62, 64
              ]),
            ],
            format: (v) => '₹${v.toStringAsFixed(0)}k',
            axisLabels: const ['21 Aug', '3 Sep'],
          ),
          const SizedBox(height: 30),
          const GaiaEyebrow('A window with a refund in it'),
          const SizedBox(height: 14),
          GaiaStrataChart(
            series: const [
              GaiaStrataSeries(label: 'Sales', values: [80, 95, 60, 110, 90]),
              GaiaStrataSeries(label: 'Refunds', values: [0, -12, 0, -38, -5]),
            ],
            format: (v) => '₹${v.toStringAsFixed(0)}k',
            axisLabels: const ['Mon', 'Fri'],
          ),
          const SizedBox(height: 30),
          const GaiaEyebrow('Share mode · thickness is share'),
          const SizedBox(height: 14),
          GaiaStrataList(
            mode: GaiaStrataMode.share,
            extent: 380,
            caption: 'Newest on top.',
            strata: [
              const GaiaStratum(
                  label: 'Aug 2026',
                  value: 177214,
                  display: '₹1,77,214',
                  tagLabel: '49 cheques',
                  tagColor: GaiaColors.champagneDim,
                  caption: 'Average cheque ₹3,617 · 159 covers'),
              const GaiaStratum(
                  label: 'Jul 2026',
                  value: 59071,
                  display: '₹59,071',
                  caption: 'Average cheque ₹2,953'),
              const GaiaStratum(
                  label: 'Jun 2026', value: 8940, display: '₹8,940'),
              const GaiaStratum(label: 'May 2026', value: 0, display: '₹0'),
              const GaiaStratum(
                  label: 'Apr 2026', value: -4200, display: '−₹4,200'),
            ],
          ),
          const SizedBox(height: 30),
          const GaiaEyebrow('Rank mode · no share is claimed'),
          const SizedBox(height: 14),
          GaiaStrataList(
            caption: 'These metrics share no total.',
            strata: [
              GaiaStratum(
                  label: 'Table turnaround',
                  value: 107.9,
                  display: '107.9',
                  unit: 'min',
                  tagLabel: 'Action',
                  tagColor: GaiaStrataColors.tagCoral,
                  caption: 'Target 60 min. Two tables have sat with an open'
                      ' cheque for ten days and skew this.'),
              GaiaStratum(
                  label: 'RevPASH',
                  value: 1.71,
                  display: '₹1.71',
                  unit: '/seat·h',
                  tagLabel: 'Action',
                  tagColor: GaiaStrataColors.tagCoral,
                  caption: 'Revenue per available seat-hour, across 72 tables.'),
              const GaiaStratum(
                  label: 'Feedback rating',
                  value: 4.55,
                  display: '4.55',
                  unit: '/5',
                  tagLabel: 'On target',
                  tagColor: GaiaColors.sage,
                  caption: '12 responses.'),
              const GaiaStratum(
                  label: 'NPS',
                  value: 54.55,
                  display: '54.55',
                  tagLabel: 'On target',
                  tagColor: GaiaColors.sage,
                  caption: 'Churn 0% · excellent.'),
              const GaiaStratum(
                  label: 'Labour, food cost, margin',
                  value: 0,
                  display: '—',
                  tagLabel: 'No data',
                  caption: 'Estimates until supplier invoices are attached.'),
            ],
          ),
        ]),
      ),
      DesignSystem.gaia,
      const Size(430, 2400),
    ));
    await tester.pumpAndSettle();
    await _shoot(tester, 'strata-5-specimen');
    AppearanceController.instance.debugReset();
  });

  testWidgets('a BICOLOUR specimen — the split, the slab and the delta rows',
      (tester) async {
    await tester.runAsync(() async {
      await _loadFonts();
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
    });
    tester.view.physicalSize = const Size(860, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_frame(
      SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 20),
          const GaiaBicolourSplit(
            current: GaiaBicolourFace(
              eyebrow: 'Current · net per day',
              value: '−₹2,510',
              valueColor: GaiaColors.coral,
              detail: 'Revenue ₹5,573 · labour ₹6,300',
            ),
            scenario: GaiaBicolourFace(
              eyebrow: 'Scenario · net per day',
              value: '−₹10,309',
              valueColor: GaiaColors.coral,
              detail: 'Revenue ₹5,097 · labour ₹12,450',
            ),
          ),
          GaiaBicolourPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GaiaBicolourHeading(
                title: 'Levers',
                trailing: Text('RESET',
                    style: GaiaType.eyebrow(color: GaiaBicolourColors.label)),
              ),
              const SizedBox(height: 10),
              Text('Every menu price moves by this much.',
                  style: GaiaType.detail(color: GaiaBicolourColors.body)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: Text('MENU PRICE',
                        style: GaiaType.eyebrow(color: GaiaBicolourColors.label))),
                Text('−11%',
                    style: GaiaType.serif(
                        size: 26, weight: 500, color: GaiaBicolourColors.ink)),
              ]),
              Builder(
                builder: (context) => SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    inactiveTrackColor: GaiaBicolourColors.line2,
                    activeTrackColor: GaiaBicolourColors.ink,
                    thumbColor: GaiaBicolourColors.ink,
                    trackHeight: 3,
                  ),
                  child: Slider(value: 0.32, onChanged: (_) {}),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 10, runSpacing: 10, children: [
                GaiaBicolourButton(label: 'Add a lever', icon: Icons.add, onPressed: () {}),
                GaiaBicolourButton(label: 'Reset values (3)', onPressed: () {}),
                GaiaBicolourButton(
                    label: 'Run Simulation',
                    icon: Icons.play_arrow,
                    primary: true,
                    dense: false,
                    onPressed: () {}),
              ]),
              const SizedBox(height: 14),
              // The app's OWN StatusChip, handed the DARK-ground inks its call
              // sites pass. On champagne those measure 1.02-1.71:1; what the
              // picture shows is the panel remapping them.
              const Wrap(spacing: 8, runSpacing: 8, children: [
                StatusChip(label: 'speculative', color: GaiaColors.amber, dense: true),
                StatusChip(label: '2 unsettled', color: GaiaColors.coral, dense: true),
                StatusChip(label: 'on target', color: GaiaColors.sage, dense: true),
              ]),
            ]),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(children: [
              const GaiaDeltaRow(
                first: true,
                header: true,
                metric: 'Metric',
                current: 'Current',
                scenario: 'Scenario',
                delta: 'Delta',
              ),
              const GaiaDeltaRow(
                  metric: 'Covers / day',
                  current: '5.3',
                  scenario: '5.5',
                  delta: '+0.2',
                  deltaColor: GaiaColors.sage,
                  rise: 1),
              const GaiaDeltaRow(
                  metric: 'Average per cover',
                  current: '₹1,051',
                  scenario: '₹935',
                  delta: '−116',
                  deltaColor: GaiaColors.coral,
                  rise: -1),
              const GaiaDeltaRow(
                  metric: 'Food cost / day',
                  current: '₹1,783',
                  scenario: '₹1,783',
                  delta: '₹0'),
              const GaiaDeltaRow(
                  metric: 'Net profit / day',
                  current: '−₹2,510',
                  scenario: '−₹10,309',
                  delta: '−7,799',
                  deltaColor: GaiaColors.coral,
                  rise: -1),
            ]),
          ),
          const SizedBox(height: 30),
        ]),
      ),
      DesignSystem.gaia,
      const Size(430, 1800),
    ));
    await tester.pumpAndSettle();
    await _shoot(tester, 'bicolour-3-specimen');
    AppearanceController.instance.debugReset();
  });
}
