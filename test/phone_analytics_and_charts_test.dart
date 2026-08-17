import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/ui/widgets/stat_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Analytics and the charts inside it, ON A PHONE — the two things no test in the
/// suite had ever pumped narrow. Both defects came out of the same blind spot:
/// the module has no width branch at all, so a 200px stat tile that needs 412px
/// to sit two across collapsed to one per row, and `CopperColumns` was handed 14
/// (or 30, or 365) columns of an 8px-gapped `Expanded` row and painted its wrapped
/// labels straight out of the chart's box.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

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
    if (routes.containsKey(path)) return routes[path];
    // The analytics/report endpoints carry their window in the query string, so a
    // route is matched by prefix, longest key first.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(Map<String, dynamic> routes) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi(routes));
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Analytics', 'Accounting'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<void> _mount(WidgetTester tester, Widget Function(RestClient) module,
    Map<String, dynamic> routes,
    {required double width, double height = 4000}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(_FakeApi(routes).routes);
  await tester.pumpWidget(_host(module(rest)));
  await tester.pumpAndSettle();
}

String _isoDay(int i) {
  final d = DateTime.utc(2026, 1, 1).add(Duration(days: i));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _analyticsRoutes() => {
      '/orders/apc': {
        // Deliberately a big money figure: StatCard clips its value with
        // TextOverflow.clip and no ellipsis, so a two-up tile has to keep it whole.
        'monthly_apc': 1234.5,
        'total_revenue': 1234567,
        'total_covers': 812,
        'month': 'August 2026',
        'employee_incentives': <dynamic>[],
        'orders': <dynamic>[],
      },
      '/feedback/summary': {'averageRating': 4.6, 'totalResponses': 128},
      // 14 rows — the fixed window the Revenue chart asks for, and one of the
      // series the diagnosis measured overflowing at 292px.
      '/orders/daily-revenue': {
        'series': [
          for (var i = 0; i < 14; i++) {'date': _isoDay(i), 'revenue': 12000 + i * 1500},
        ],
      },
      '/orders/timing-stats': {'avg_prep_ms': 4320000},
      // 12 rows -> the three "by month" charts.
      '/orders/apc-trends': {
        'series': [
          for (var i = 1; i <= 12; i++)
            {
              'month': '2026-${i.toString().padLeft(2, '0')}',
              'total_revenue': 400000 + i * 12000,
              'monthly_apc': 900 + i * 11,
              'total_covers': 400 + i * 9,
              'bills': 120 + i,
            },
        ],
      },
      '/analytics/advanced': {
        // Keys the KPI registry does not map, which is exactly how a new KPI
        // surfaces on the Overview view instead of vanishing.
        'kpis': [
          {'key': 'zz_one', 'label': 'Profit margin', 'value': 18.4, 'unit': '%', 'status': 'green'},
          {'key': 'zz_two', 'label': 'Revenue per seat hour', 'value': 412, 'unit': '', 'status': 'amber'},
        ],
      },
    };

/// Reports over a long window: the catastrophic case. `by_day` is one row per
/// trading day and the period tabs go to a full year, so this chart was handed 90,
/// 180 or 365 columns whose 8px gaps alone (712px at 90) exceed a phone's whole
/// width — every `Expanded` gets zero and the row overflows sideways.
Map<String, dynamic> _reportRoutes({required int days}) => {
      '/reports/sales': {
        'total_sales': 4500000,
        'by_day': [
          for (var i = 0; i < days; i++) {'date': _isoDay(i), 'sales': 40000 + (i % 17) * 2500},
        ],
        'by_method': <dynamic>[],
      },
      '/reports/gst': {'by_rate': <dynamic>[]},
      '/reports/pnl': {'net_profit': 812000, 'revenue': 4500000},
      '/expenses': {'expenses': <dynamic>[]},
    };

Finder _statCardOf(String caption) =>
    find.ancestor(of: find.text(caption), matching: find.byType(StatCard)).first;

Rect _tile(WidgetTester tester, String caption) => tester.getRect(_statCardOf(caption));

/// Fails on any layout error EXCEPT one specific pre-existing artifact: the
/// design system's `CopperColumns` reserves exactly 40px for its value label, the
/// 5px gap, the 7px gap and its axis label, and those five things want 40.04px —
/// so the PEAK column (the only one that always shows its value) overflows by
/// 0.04px whenever a `valueFormatter` is given. That is a sub-pixel shortfall in a
/// frozen file (`lib/ui/` is out of scope for this fix), it predates it, and it is
/// invisible on screen. It is pinned by its own test below so it cannot be
/// confused with the phone bug. Anything else still fails — including every
/// horizontal overflow, which is what the phone bug actually was.
void _expectNoLayoutError(WidgetTester tester, {String? reason}) {
  final error = tester.takeException();
  if (error == null) return;
  final over = _bottomOverflow('$error');
  expect(over != null && over < 1.0, isTrue,
      reason: '${reason ?? 'unexpected layout error'}: $error');
}

/// How many pixels a "RenderFlex overflowed by N pixels on the bottom" error is
/// out by, or null when the error is anything else at all.
double? _bottomOverflow(String error) {
  final match = RegExp(r'overflowed by ([\d.]+) pixels on the bottom').firstMatch(error);
  return match == null ? null : double.tryParse(match.group(1)!);
}

/// The point size the tile's big number is actually rendered at. StatCard builds
/// its value as the FIRST RichText under the card, so this reads the real
/// resolved style rather than trusting the theme.
double _valueFontSize(WidgetTester tester, String caption) => tester
    .widget<RichText>(
        find.descendant(of: _statCardOf(caption), matching: find.byType(RichText)).first)
    .text
    .style!
    .fontSize!;

void main() {
  group('Analytics stat tiles go two per row on a phone', () {
    // 320 is the narrowest phone still in service, 390 the common portrait size.
    // Both were ONE per row before: two 200px tiles need 412px and a 390px window
    // leaves 358 inside the page padding.
    for (final width in [320.0, 390.0]) {
      testWidgets('two tiles share a row at ${width.toInt()}dp', (tester) async {
        await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
            width: width);

        final apc = _tile(tester, 'MONTHLY APC');
        final revenue = _tile(tester, 'REVENUE');
        expect(revenue.top, apc.top, reason: 'the first two tiles must be on the SAME row');
        expect(revenue.left, greaterThan(apc.left));
        // Both inside the page, and neither overlapping the other.
        expect(apc.right, lessThanOrEqualTo(revenue.left));
        expect(revenue.right, lessThanOrEqualTo(width - 16));
        expect(tester.takeException(), isNull, reason: 'analytics overflowed at ${width.toInt()}dp');
      });

      testWidgets('the KPI health tiles go two per row at ${width.toInt()}dp', (tester) async {
        await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
            width: width);

        // The KPI band is sorted, so which of the two comes first is not this
        // test's business — that they share a row is.
        final one = tester.getRect(find.text('PROFIT MARGIN'));
        final two = tester.getRect(find.text('REVENUE PER SEAT HOUR'));
        expect(two.top, one.top, reason: 'the KPI tiles must be on the SAME row');
        expect(two.left, isNot(one.left));
      });
    }

    testWidgets('a desktop window keeps the 200px design tile', (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          width: 1400);

      expect(_tile(tester, 'MONTHLY APC').width, 200);
      _expectNoLayoutError(tester, reason: 'analytics overflowed at 1400dp');
    });

    // The whole point of the narrow tile is that the number stays readable in it.
    // StatCard clips (not ellipsises) its value, so a clipped revenue figure reads
    // as a DIFFERENT, smaller number with no visual cue at all.
    testWidgets('the narrow tile steps the value down the type scale, not off the card',
        (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          width: 320);
      final narrowSize = _valueFontSize(tester, 'REVENUE');

      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          width: 1400);
      final wideSize = _valueFontSize(tester, 'REVENUE');
      _expectNoLayoutError(tester);

      // displayMedium (32) on desktop, displaySmall (24) in a half-row tile —
      // both tokens off the same scale, neither a hardcoded number.
      expect(wideSize, 32);
      expect(narrowSize, 24);
    });
  });

  group('column charts on a phone', () {
    for (final width in [320.0, 390.0]) {
      testWidgets('Analytics charts do not overflow at ${width.toInt()}dp', (tester) async {
        await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
            width: width);

        expect(tester.takeException(), isNull);
        // 14 days and 12 months cannot be drawn as columns in ~292px, so nothing
        // may try: the series is redrawn as the one chart that derives its own
        // mark count from the width it is given.
        expect(find.byType(CopperColumns), findsNothing,
            reason: 'a column chart was drawn at ${width.toInt()}dp, where its '
                'labels cannot fit');
        expect(find.byType(CopperBarcode), findsWidgets);
        // The time axis is not lost with the columns.
        expect(find.text('${_isoDay(0).split('-')[2]}/01'), findsWidgets);
        expect(find.text('14 points'), findsWidgets);
      });
    }

    testWidgets('a desktop window still draws real columns', (tester) async {
      await _mount(tester, (r) => m.analyticsModule(r, r.auth.profile!), _analyticsRoutes(),
          width: 1400);

      // Unchanged behaviour where it always worked — and it is the columns, with
      // their per-point labels, that the owner says look good on the desktop.
      expect(find.byType(CopperColumns), findsWidgets);
      _expectNoLayoutError(tester, reason: 'analytics charts overflowed at 1400dp');
    });

    // Pins the artifact `_expectNoLayoutError` tolerates, straight off the design
    // system widget with no module around it — so it is on the record that the
    // sub-pixel bottom overflow belongs to `CopperColumns`' own 40px label reserve
    // and not to anything this fix wired up. No existing test had ever given the
    // widget a `valueFormatter`, which is why it was never seen.
    testWidgets('KNOWN: CopperColumns is a sub-pixel short in its own label reserve',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: CopperColumns(
              values: const [4, 9, 2, 7],
              labels: const ['a', 'b', 'c', 'd'],
              valueFormatter: (v) => '₹${v.toStringAsFixed(0)}',
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final error = tester.takeException();
      expect('$error', contains('pixels on the bottom'));
      expect(_bottomOverflow('$error'), isNotNull);
      expect(_bottomOverflow('$error'), lessThan(1.0),
          reason: 'if this grows past a sub-pixel it is no longer the known artifact');
    });

    // Month, Quarter, Half year and Year on the Reports page. 30 columns already
    // overflowed; past 38 the gaps alone exceed a phone's width.
    for (final days in [30, 90, 365]) {
      testWidgets('Reports "Sales — daily" survives a $days-day window at 320dp', (tester) async {
        await _mount(tester, (r) => m.accountingModule(r, r.auth.profile!),
            _reportRoutes(days: days), width: 320);

        expect(find.text('Sales — daily'), findsOneWidget);
        expect(find.byType(CopperColumns), findsNothing);
        expect(find.text('$days points'), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: 'the $days-day sales chart overflowed at 320dp');
      });
    }
  });
}
