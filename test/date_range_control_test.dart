import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/get_cache.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/date_range_picker.dart';
import 'package:restaurant_owner_app/ui/widgets/section_header.dart';
import 'package:restaurant_owner_app/ui/widgets/skeleton.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
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
  _FakeApi(this.routes, {this.latency = Duration.zero});

  final Map<String, dynamic> routes;

  /// How long a GET takes to answer. Zero (the default) answers inside the same
  /// frame, so a loud reload never paints its skeleton; a real network does, and
  /// the skeleton is what throws the page's scroll position away.
  final Duration latency;

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
    if (latency > Duration.zero) await Future<void>.delayed(latency);
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

/// A trading month's worth of detail ABOVE the Settled bills section, so on a
/// phone the bills sit well past the list's build-ahead margin: the case where
/// the header has no element at all once the reload puts the page at the top.
Map<String, dynamic> _tallAccountingRoutes() => {
      ..._accountingRoutes(),
      '/reports/sales': {
        ...(_accountingRoutes()['/reports/sales'] as Map<String, dynamic>),
        'by_day': [
          for (var i = 1; i <= 14; i++) {'date': '2026-08-${i.toString().padLeft(2, '0')}', 'sales': 1000.0 + i},
        ],
        'by_method': [
          for (final mth in ['Cash', 'Upi', 'Card', 'Zomato', 'District', 'Dineout'])
            {'method': mth, 'sales': 500.0, 'bills': 3},
        ],
      },
      '/reports/gst': {
        'total_taxable': 0.0,
        'total_tax': 0.0,
        'by_rate': [
          for (var i = 0; i < 12; i++) {'name': 'GST $i', 'percentage': 5, 'taxable': 100.0, 'tax': 5.0},
        ],
      },
      '/reports/discounts': {
        'bill_count': 20,
        'discounted_bills': 20,
        'by_coupon': [
          for (var i = 0; i < 20; i++) {'code': 'SAVE$i', 'kind': 'coupon', 'amount': 50.0, 'uses': 1},
        ],
      },
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
  double height = 2400,
  double textScale = 1.0,
  DesignSystem system = DesignSystem.rustic,
  Duration latency = Duration.zero,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes, latency: latency);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);

  await tester.pumpWidget(GaiaScope(
    system: system,
    child: MaterialApp(
      theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Accounting', 'Analytics', 'Cash'],
        clearFocus: () {},
        child: Scaffold(body: module(rest, rest.auth.profile!)),
      ),
    ),
  ));
  if (latency > Duration.zero) {
    // The skeleton animates forever, so settle only once the first load is in.
    for (var i = 0; i < 20 && find.byType(SkeletonBox).evaluate().isNotEmpty; i++) {
      await tester.pump(latency);
    }
  }
  await tester.pumpAndSettle();
  return api;
}

/// The section header titled [title]. Gaia upper-cases the title inside its own
/// header, but the SectionHeader widget and its `title` are the same in both.
Finder _header(String title) =>
    find.byWidgetPredicate((w) => w is SectionHeader && w.title == title, description: 'SectionHeader "$title"');

/// THE BUG CLASS: a bordered pill that reads the window, drawn as a static
/// InfoChip. It looks exactly like the date control and does nothing on tap.
Finder _deadRangePills(DateRange r) => find.byWidgetPredicate((w) => w is InfoChip && w.label == r.label(),
    description: 'static InfoChip reading ${r.label()}');

/// Is [finder]'s widget painted inside the test window right now?
bool _onScreen(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  final rect = tester.getRect(finder);
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return rect.top >= 0 && rect.bottom <= size.height;
}

/// Open the chip INSIDE [header] and tap a preset: the reported path, where the
/// owner is down at a section rather than at the top of the page.
Future<void> _pickPresetFrom(WidgetTester tester, Finder header, String label) async {
  final chip = find.descendant(of: header, matching: find.byType(DateRangeChip));
  expect(chip, findsOneWidget, reason: 'no live date chip in that header');
  await tester.tap(chip, warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(find.text('Period'), findsOneWidget, reason: 'the range sheet did not open');
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Scroll the module's page (its outermost vertical list) until [finder] shows.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _analyticsWithAttendance() => {
      ..._analyticsRoutes(),
      // Attendance only renders with something to say; a summary with an empty
      // list is enough to put its header on screen.
      '/analytics/advanced': {
        'staff_attendance': <Map<String, dynamic>>[],
        'attendance_summary': {'staff_tracked': 0, 'window_days': 30},
      },
    };

/// The page-level window picker: the one full-size chip. Section headers carry
/// dense copies of it now, so `find.byType(DateRangeChip).first` would quietly
/// resolve to one of those if the top picker ever went missing.
Finder _topChip() =>
    find.byWidgetPredicate((w) => w is DateRangeChip && !w.dense, description: 'the top DateRangeChip');

/// Open the TOP chip's sheet and tap a preset by its label.
Future<void> _pickPreset(WidgetTester tester, String label) async {
  expect(_topChip(), findsOneWidget, reason: 'the page-level date picker is missing');
  await tester.ensureVisible(_topChip());
  await tester.tap(_topChip(), warnIfMissed: false);
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
      await tester.ensureVisible(_topChip());
      await tester.tap(_topChip(), warnIfMissed: false);
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

    // "In Accounting in settled bills the date frame is not selectable." The pill
    // beside 'Settled bills' was a static InfoChip dressed as this control.
    testWidgets('the Settled bills header carries the LIVE chip, reading the page window', (tester) async {
      await _mount(tester, m.accountingModule, _accountingRoutes());
      final window = DateRange.fromPreset(RangePreset.last30);

      await tester.ensureVisible(_header('Settled bills'));
      await tester.pumpAndSettle();
      final chip = find.descendant(of: _header('Settled bills'), matching: find.byType(DateRangeChip));
      expect(chip, findsOneWidget);
      expect(tester.widget<DateRangeChip>(chip).value.label(), window.label());
      expect(tester.widget<DateRangeChip>(chip).dense, isTrue);
      expect(_deadRangePills(window), findsNothing, reason: 'a static pill still reads the window');
    });

    testWidgets('picking from the Settled bills header moves the ONE window: bills AND reports refetch',
        (tester) async {
      final api = await _mount(tester, m.accountingModule, _accountingRoutes());
      await tester.ensureVisible(_header('Settled bills'));
      await tester.pumpAndSettle();
      api.mark();

      await _pickPresetFrom(tester, _header('Settled bills'), 'Last 7 days');

      final week = DateRange.fromPreset(RangePreset.last7);
      expect(api.sinceMatching('/bills/closed?').where((p) => p.contains('from=${week.from}&to=${week.to}')),
          isNotEmpty,
          reason: 'the bills list was not refetched on the picked window');
      // Not a section-private window: the totals above the list follow it too.
      for (final route in ['/reports/sales', '/reports/gst', '/reports/pnl']) {
        expect(api.sinceMatching('$route?'), contains('$route?${week.reportQuery}'),
            reason: '$route did not follow the Settled bills chip');
      }
      final chips = tester.widgetList<DateRangeChip>(find.byType(DateRangeChip)).toList();
      expect(chips, hasLength(2), reason: 'the top chip and the Settled bills chip');
      for (final c in chips) {
        expect(c.value.label(), week.label(), reason: 'both chips must show the window the bills chip set');
      }
      expect(DateRangeMemory.of('accounting').label(), week.label());
    });

    testWidgets('after the reload the owner is back on Settled bills, not at the top of the page',
        (tester) async {
      // A phone: the bills sit several screens below the top chip, which is
      // exactly where the reload used to strand the owner.
      await _mount(tester, m.accountingModule, _tallAccountingRoutes(),
          width: 400, height: 800, latency: const Duration(milliseconds: 200));
      expect(find.byWidgetPredicate((w) => w is SectionHeader && w.title == 'Settled bills', skipOffstage: false),
          findsNothing,
          reason: 'precondition: the section must be past the build-ahead margin, or this proves nothing');
      await _scrollTo(tester, _header('Settled bills'));

      final chip = find.descendant(of: _header('Settled bills'), matching: find.byType(DateRangeChip));
      await tester.tap(chip, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 days').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The reload really is loud: the list is gone behind the skeleton, taking
      // its scroll position with it. Without this the test would pass on a list
      // that was never torn down.
      expect(find.byType(SkeletonBox), findsWidgets, reason: 'precondition: the reload never showed the skeleton');
      for (var i = 0; i < 20 && find.byType(SkeletonBox).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();

      expect(_onScreen(tester, _header('Settled bills')), isTrue,
          reason: 'picking dates from the bills header threw the page back to the top');
      // The toolbar at the very top (the exports beside the top chip) is not even
      // built, so the page really did not reset.
      expect(_onScreen(tester, find.text('Tally XML')), isFalse, reason: 'the page reset to the top');
    });

    testWidgets('the TOP chip keeps its old behaviour: no jump down the page', (tester) async {
      await _mount(tester, m.accountingModule, _tallAccountingRoutes(), width: 400, height: 800);
      await _pickPreset(tester, 'Last 7 days');
      expect(_onScreen(tester, _topChip()), isTrue);
      expect(_onScreen(tester, _header('Settled bills')), isFalse);
    });

    for (final system in DesignSystem.values) {
      testWidgets('the header chip fits a 320dp phone at 1.3x on a year-straddling window (${system.name})',
          (tester) async {
        const straddle = DateRange(from: '2025-07-28', to: '2026-01-03', preset: RangePreset.custom);
        DateRangeMemory.remember('accounting', straddle);
        await _mount(tester, m.accountingModule, _accountingRoutes(),
            width: 320, height: 900, textScale: 1.3, system: system);
        await _scrollTo(tester, _header('Settled bills'));

        expect(tester.takeException(), isNull, reason: 'the header overflowed');
        final chip = find.descendant(of: _header('Settled bills'), matching: find.byType(DateRangeChip));
        expect(chip, findsOneWidget);
        expect(tester.getSize(chip).width, lessThanOrEqualTo(220));
        expect(tester.getRect(chip).right, lessThanOrEqualTo(tester.getRect(_header('Settled bills')).right + 0.5));
      });
    }
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

    // Same bug class as Accounting's Settled bills pill: three section headers
    // carried a static calendar InfoChip reading the window.
    testWidgets("Kitchen, Attendance and Actionable insights carry the live chip, on this module's window",
        (tester) async {
      await _mount(tester, m.analyticsModule, _analyticsWithAttendance(), height: 6000);
      // 'Everything' puts all three on one screen. The view choice is module-wide
      // on purpose, so it is handed back to Overview for the tests after this one.
      await tester.ensureVisible(find.text('Everything').first);
      await tester.tap(find.text('Everything').first);
      await tester.pumpAndSettle();
      try {
        final window = DateRange.fromPreset(RangePreset.last30);
        for (final title in ['Kitchen', 'Attendance', 'Actionable insights']) {
          final chip = find.descendant(of: _header(title), matching: find.byType(DateRangeChip));
          expect(chip, findsOneWidget, reason: '$title has no live date chip');
          expect(tester.widget<DateRangeChip>(chip).value.label(), window.label());
        }
        expect(_deadRangePills(window), findsNothing, reason: 'a static pill still reads the window');
      } finally {
        await tester.ensureVisible(find.text('Overview').first);
        await tester.tap(find.text('Overview').first);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('picking from the Kitchen header re-requests every read and lands back on Kitchen',
        (tester) async {
      final api = await _mount(tester, m.analyticsModule, _analyticsRoutes(), width: 400, height: 420);
      expect(_onScreen(tester, _header('Kitchen')), isFalse,
          reason: 'precondition: Kitchen must start below the fold, or this proves nothing');
      await _scrollTo(tester, _header('Kitchen'));
      api.mark();

      await _pickPresetFrom(tester, _header('Kitchen'), 'Last 7 days');

      final week = DateRange.fromPreset(RangePreset.last7);
      for (final route in ['/analytics/menu-insights', '/analytics/advanced', '/analytics/kitchen']) {
        expect(api.sinceMatching('$route?'), contains('$route?${week.query}'),
            reason: '$route did not follow the Kitchen chip');
      }
      expect(DateRangeMemory.of('analytics').label(), week.label());
      expect(_onScreen(tester, _header('Kitchen')), isTrue,
          reason: 'picking dates from the Kitchen header threw the page back to the top');
    });

    // The same pick, on the path a real tablet takes most: going BACK to a window
    // that loaded minutes ago (the 'Last 30 days' the module opened on). The
    // remounted body paints that window's saved copy first, old enough to wear
    // the "Updated Xm ago" pill, and the reveal fires on that paint. Then the
    // silent refresh lands and the pill clears. AsyncView used to return the
    // bare list there instead of the Stack it had just been, which remounted the
    // list at offset 0: the owner landed on Kitchen and was thrown back to the
    // top a moment later. Zero latency or a fresh copy never shows that.
    testWidgets('going back to an older saved window still lands on Kitchen once the live figures arrive',
        (tester) async {
      await _mount(tester, m.analyticsModule, _analyticsRoutes(),
          width: 400, height: 420, latency: const Duration(milliseconds: 300));
      await _scrollTo(tester, _header('Kitchen'));
      await _pickPresetFrom(tester, _header('Kitchen'), 'Last 7 days');
      expect(_onScreen(tester, _header('Kitchen')), isTrue, reason: 'precondition: the first pick did not land');

      // Every saved copy is now ten minutes old, the opening window's included.
      final prefs = await SharedPreferences.getInstance();
      final old = DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
      final saved = prefs.getKeys().where((k) => k.startsWith(GetCache.keyPrefix)).toList();
      expect(saved, isNotEmpty, reason: 'precondition: nothing was saved, so no saved copy can paint');
      for (final k in saved) {
        final d = (jsonDecode(prefs.getString(k)!) as Map)['d'];
        await prefs.setString(k, '{"t":$old,"d":${jsonEncode(d)}}');
      }

      await tester.tap(find.descendant(of: _header('Kitchen'), matching: find.byType(DateRangeChip)),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 30 days').last);
      // Frame by frame, so the saved-copy paint and the live swap are both seen.
      var copyPainted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (find.text('Updated 10m ago').evaluate().isNotEmpty) copyPainted = true;
      }
      await tester.pumpAndSettle();

      expect(copyPainted, isTrue, reason: 'precondition: the aged saved copy never painted with its pill');
      expect(find.textContaining('Updated '), findsNothing,
          reason: 'precondition: the live figures never replaced the saved copy');
      expect(DateRangeMemory.of('analytics').label(), DateRange.fromPreset(RangePreset.last30).label());
      expect(_onScreen(tester, _header('Kitchen')), isTrue,
          reason: 'the live refresh after the saved copy threw the page back to the top');
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
