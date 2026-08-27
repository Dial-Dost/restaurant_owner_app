import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/date_range_picker.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The shared date-range control, wired to real modules.
///
/// `date_range_test.dart` pins the arithmetic; this pins the WIRING, which is
/// where a window feature actually fails. Five claims, each untestable before
/// the control existed because each module invented its own period:
///
///   1. A PRESET REACHES THE API. Tapping "Last 7 days" re-requests the module's
///      reads on that window — it does not repaint the label over stale rows,
///      which is the failure that makes an owner trust a wrong number.
///   2. A CUSTOM SPAN REACHES THE API AS from/to. "1–15 August" is the question
///      the whole feature exists to answer, and it is not expressible as a
///      rolling day count at all.
///   3. THE LABEL ON SCREEN IS THE WINDOW THAT WAS FETCHED. A chip saying one
///      thing while the rows were cut on another is worse than no chip.
///   4. THE EXPORT CARRIES THE SAME RANGE AS THE SCREEN. An export that quietly
///      disagrees with the figures above it is the copy that gets filed.
///   5. THE WINDOW SURVIVES LEAVING THE MODULE AND COMING BACK.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;

  /// Every path requested, in order — this is what the assertions read.
  final List<String> paths = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    paths.add(path);
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a whole query-carrying family.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  /// The raw-body path (the Tally XML export) does NOT go through `request` —
  /// RestClient.getText calls this instead — so it needs its own stub, or the
  /// export test silently exercises a real HttpClient and proves nothing.
  @override
  Future<String> getText(String path, String token, [String? outletId]) async {
    paths.add(path);
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isEmpty) throw ApiException('No fake route for $path', 404);
    return '${routes[prefixes.first]}';
  }

  /// Everything requested since the last [mark], so one reload can be inspected
  /// on its own instead of through the initial load's noise.
  int _mark = 0;
  void mark() => _mark = paths.length;
  List<String> get since => paths.sublist(_mark);
  Iterable<String> sinceMatching(String prefix) => since.where((p) => p.startsWith(prefix));
}

Map<String, dynamic> _accountingRoutes() => {
      '/reports/sales': {
        'total_sales': 100.0,
        'total_tax': 0.0,
        'total_service_charge': 0.0,
        'total_refund': 0.0,
        'net_sales': 100.0,
        'bill_count': 1,
        'by_day': <Map<String, dynamic>>[],
        'by_method': <Map<String, dynamic>>[],
      },
      '/reports/gst': {'total_taxable': 0.0, 'total_tax': 0.0, 'by_rate': <Map<String, dynamic>>[]},
      '/reports/pnl': {
        'gross_sales': 100.0,
        'refunds': 0.0,
        'tax_collected': 0.0,
        'net_revenue': 100.0,
        'total_expenses': 0.0,
        'net_profit': 100.0,
        'expenses_by_category': <Map<String, dynamic>>[],
      },
      '/reports/discounts': {'bill_count': 1, 'discounted_bills': 0, 'by_coupon': <Map<String, dynamic>>[]},
      '/reports/schedules': {'schedules': <Map<String, dynamic>>[]},
      '/reports/deliveries': {'deliveries': <Map<String, dynamic>>[]},
      '/reports/tally.xml': '<ENVELOPE/>',
      '/expenses': {'expenses': <Map<String, dynamic>>[]},
      '/payroll': {'total_due': 0.0, 'total_paid': 0.0, 'rows': <Map<String, dynamic>>[]},
      '/bills/closed': {'bills': <Map<String, dynamic>>[], 'total': 0, 'has_more': false},
    };

Map<String, dynamic> _analyticsRoutes() => {
      '/orders/apc': {'orders': <Map<String, dynamic>>[], 'employee_incentives': <Map<String, dynamic>>[]},
      '/feedback/summary': <String, dynamic>{},
      '/orders/daily-revenue': {'series': <Map<String, dynamic>>[]},
      '/orders/timing-stats': <String, dynamic>{},
      '/analytics/menu-insights': <String, dynamic>{},
      '/orders/apc-trends': <String, dynamic>{},
      '/analytics/advanced': <String, dynamic>{},
      '/analytics/kitchen': <String, dynamic>{},
      '/analytics/metric-explainers': <String, dynamic>{},
    };

Map<String, dynamic> _cashRoutes() => {
      '/cash/current': {'session': null},
      '/cash/sessions': {'sessions': <Map<String, dynamic>>[]},
    };

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  double width = 1400,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);

  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: const ['Accounting', 'Analytics', 'Cash'],
      clearFocus: () {},
      child: Scaffold(body: module(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

/// Open the chip's sheet and tap a preset by its label.
Future<void> _pickPreset(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.byType(DateRangeChip).first);
  await tester.tap(find.byType(DateRangeChip).first, warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(find.text('Period'), findsOneWidget, reason: 'the range sheet did not open');
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// A calendar range an owner picked earlier in this session. This is exactly how
/// a custom window reaches a module on a revisit, and it is the shape the
/// calendar itself writes — so asserting on it proves the same wire path two
/// taps on the grid would, without depending on Material's internal semantics
/// labels for a day cell.
const _custom = DateRange(from: '2026-08-01', to: '2026-08-15', preset: RangePreset.custom);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    RestaurantTime.adopt(RestaurantTime.defaultZone);
    // Session memory is process-wide by design (that IS the feature); a test must
    // not inherit the window the previous one picked.
    DateRangeMemory.reset();
  });

  group('Accounting', () {
    testWidgets('opens on the shared default and says so on screen', (tester) async {
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());
      final expected = DateRange.fromPreset(RangePreset.last30);

      expect(find.byType(DateRangeChip), findsWidgets);
      expect(find.textContaining(expected.label()), findsWidgets,
          reason: 'the window has to be readable without opening anything');
      expect(api.paths.where((p) => p.startsWith('/reports/sales?')).single,
          '/reports/sales?${expected.reportQuery}');
    });

    testWidgets('a preset re-requests EVERY report on that window', (tester) async {
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());
      api.mark();

      await _pickPreset(tester, 'Last 7 days');

      final week = DateRange.fromPreset(RangePreset.last7);
      // Not just the sales report: a screen where one card followed the picker
      // and the others did not would be showing four periods at once.
      for (final route in ['/reports/sales', '/reports/gst', '/reports/pnl', '/expenses']) {
        expect(api.sinceMatching('$route?'), contains('$route?${week.reportQuery}'),
            reason: '$route was not refetched on the chosen window');
      }
      expect(find.textContaining(week.label()), findsWidgets);
    });

    testWidgets('a CUSTOM span reaches the API as from/to, and is labelled as one',
        (tester) async {
      DateRangeMemory.remember('accounting', _custom);
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());

      expect(api.paths.where((p) => p.startsWith('/reports/sales?')).single,
          '/reports/sales?from=2026-08-01&to=2026-08-15');
      expect(_custom.days, 15, reason: 'both ends are inclusive');
      // The chip renders the span the way the owner asked for it.
      expect(find.textContaining('1–15 Aug'), findsWidgets);
    });

    testWidgets('the Tally export carries the SAME range as the screen', (tester) async {
      DateRangeMemory.remember('accounting', _custom);
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());
      api.mark();

      await tester.ensureVisible(find.text('Tally XML').first);
      await tester.tap(find.text('Tally XML').first, warnIfMissed: false);
      await tester.pumpAndSettle();

      // The save dialog cannot open under test and the handler reports that in a
      // snackbar — but the REQUEST goes out first, and its window is the point.
      expect(api.sinceMatching('/reports/tally.xml?'),
          contains('/reports/tally.xml?from=2026-08-01&to=2026-08-15'));
    });

    testWidgets('the calendar is reachable from the sheet', (tester) async {
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await tester.ensureVisible(find.byType(DateRangeChip).first);
      await tester.tap(find.byType(DateRangeChip).first, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Presets first, calendar second — both present, both one tap from the chip.
      for (final p in kRangePresets) {
        expect(find.text(presetLabel(p)), findsWidgets, reason: '${presetLabel(p)} is missing');
      }
      await tester.tap(find.text('Pick dates on a calendar'));
      await tester.pumpAndSettle();
      // Material's range picker, in the app's own wording.
      expect(find.text('Select a period'), findsWidgets);
      expect(find.text('Apply'), findsWidgets);
    });
  });

  group('Analytics', () {
    testWidgets('every window-aware read gets from/to AND a matching days', (tester) async {
      final api = await _mount(tester, m.analyticsModule, _analyticsRoutes());
      api.mark();

      await _pickPreset(tester, 'Last 7 days');
      final week = DateRange.fromPreset(RangePreset.last7);

      // `days` rides along with the dates so a route that only understands the
      // rolling count still gets a window of the right LENGTH rather than
      // silently answering for its own 30-day default.
      for (final route in ['/analytics/menu-insights', '/analytics/advanced', '/analytics/kitchen']) {
        expect(api.sinceMatching('$route?'), contains('$route?${week.query}'),
            reason: '$route did not carry the chosen window');
      }
      expect(week.query, contains('days=7'));
      expect(find.textContaining(week.label()), findsWidgets);
    });

    testWidgets('a custom span is expressible here too — the gap this feature closed',
        (tester) async {
      // The /analytics/* routes took a ROLLING day count and nothing else, so
      // "1–15 August" could not be asked of them at all. Both halves now go.
      DateRangeMemory.remember('analytics', _custom);
      final api = await _mount(tester, m.analyticsModule, _analyticsRoutes());

      expect(api.paths.where((p) => p.startsWith('/analytics/kitchen?')).single,
          '/analytics/kitchen?from=2026-08-01&to=2026-08-15&days=15');
    });
  });

  group('Cash', () {
    testWidgets('the past-sessions list is cut on the chosen window', (tester) async {
      final api = await _mount(tester, m.cashModule, _cashRoutes());
      api.mark();

      await _pickPreset(tester, 'This month');
      final month = DateRange.fromPreset(RangePreset.thisMonth);

      expect(api.sinceMatching('/cash/sessions?'),
          contains('/cash/sessions?${month.reportQuery}'));
      // The OPEN drawer is "right now" and must keep taking no window at all.
      expect(api.since, contains('/cash/current'));
      expect(api.since.where((p) => p.startsWith('/cash/current?')), isEmpty);
    });
  });

  group('per-screen memory', () {
    testWidgets('a module reopens on the window it was left on', (tester) async {
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _pickPreset(tester, 'Yesterday');
      final yesterday = DateRange.fromPreset(RangePreset.yesterday);

      // Leave the module and come back — exactly what switching to Menu and back
      // does. The window must not reset to a different period from the one the
      // owner was reasoning about.
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());
      expect(api.paths.where((p) => p.startsWith('/reports/sales?')).last,
          '/reports/sales?${yesterday.reportQuery}');
      expect(find.textContaining(yesterday.label()), findsWidgets);
    });

    testWidgets('two modules keep separate windows', (tester) async {
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _pickPreset(tester, 'Yesterday');

      // Accounting is on Yesterday; Analytics must still open on the default.
      final api = await _mount(tester, m.analyticsModule, _analyticsRoutes());
      final fallback = DateRange.fromPreset(RangePreset.last30);
      expect(api.paths.where((p) => p.startsWith('/analytics/kitchen?')).single,
          '/analytics/kitchen?${fallback.query}');
    });
  });
}
