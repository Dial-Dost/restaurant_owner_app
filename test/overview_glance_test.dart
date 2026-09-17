import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/glance_drill.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart' show visibleModuleLabelsFor;
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/services/time_slot.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// "Today at a glance" — every element leads somewhere (client item 10).
///
/// What this pins, element by element: which sheet a tap opens, which module
/// its jump reaches, and that the destination is set up to show the SAME
/// number — the report tab, the server's day, ALL DAY (a remembered Lunch slot
/// is deliberately left behind first, so the reset is proven, not assumed), and
/// for Accounting its one-shot bill filter. Then the rules around it: a module
/// this user cannot open is never offered (the next fallback is), an older
/// backend's payload with no drills lands in the same places, a waiter never
/// gets the box at all, and every new sheet survives a 360px phone at 1.3x.
///
/// Both design systems and both platforms, because Gaia renders its own card,
/// header and button (the jump reads "VIEW IN REPORTS" there) and Android is a
/// touch screen with no hover.
///
/// The dead-tap half — every text leaf in the box, tapped on a fresh mount —
/// lives with the other sweeps in dead_tap_sweep_test.dart.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {Map<String, dynamic>? profile}) : profile = profile ?? _owner;
  final Map<String, dynamic> routes;
  final Map<String, dynamic> profile;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult('test-token', Profile.fromJson(profile));

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  List<String> get writes => calls.where((c) => !c.startsWith('GET ')).toList();
}

const Map<String, dynamic> _owner = {
  'employeeId': 'e1',
  'restaurantName': 'Gaia Global Vegetarian',
  'restaurantUsername': 'gaiaglobalvegetarian',
  'role': 'admin',
  'actions_set': ['*'],
  'action_names': <String>[],
};

Map<String, dynamic> _profile(String role, List<String> actionNames, {Map<String, dynamic> features = const {}}) => {
      'employeeId': 'e2',
      'employeeUsername': 'staff',
      'restaurantName': 'Gaia Global Vegetarian',
      'restaurantUsername': 'gaiaglobalvegetarian',
      'role': role,
      'role_all': [role],
      'actions_set': const ['a1'],
      'action_names': actionNames,
      'features': features,
    };

const _waiterActions = ['Add Orders', 'View Orders', 'Table Occupied', 'Occupy Table', 'View Menu', 'View Bills'];

/// Every module a glance element can reach, plus the Overview itself.
const _all = ['Overview', 'Orders', 'Tables', 'Analytics', 'History', 'Reports', 'Accounting', 'Cash register', 'Settings'];

String get _today => todayKey();
String get _monthFrom => '${_today.substring(0, 7)}-01';

Map<String, dynamic> _target(GlanceTarget t) => {
      'module': t.module,
      'params': {
        if (t.report != null) 'report': t.report,
        if (t.from != null) 'from': t.from,
        if (t.to != null) 'to': t.to,
        if (t.slotAll) 'slot': 'all',
        if (t.method != null) 'method': t.method,
      },
      'href': '/dashboard',
      if (t.bills) 'bills': true,
    };

/// A drill as the backend ships it, built off the same table (the pure suite
/// pins that table to the backend's).
Map<String, dynamic> _drill(String key, {String? row}) {
  final d = glanceFallbackDrill(key, today: _today, monthFrom: _monthFrom, rowMethod: row)!;
  return {
    ..._target(d.primary),
    'fallbacks': [for (final f in d.fallbacks) _target(f)],
    if (d.secondary != null) 'secondary': _target(d.secondary!),
  };
}

/// GET /analytics/headline, today, with every element the box can draw.
Map<String, dynamic> _headline({Map<String, dynamic> over = const {}, bool drills = true}) {
  Map<String, dynamic> fig(String key, num value, String label, String hint) =>
      {'value': value, 'label': label, 'hint': hint, if (drills) 'drill': _drill(key)};
  const rows = [
    {'method': 'Upi', 'label': 'UPI', 'bills': 6, 'amount': 11000, 'share_pct': 48.5, 'refund': 0, 'net_amount': 11000},
    {'method': 'Cash', 'label': 'Cash', 'bills': 6, 'amount': 8430.5, 'share_pct': 37.17, 'refund': 120, 'net_amount': 8310.5},
    {'method': 'Unallocated', 'label': 'Unallocated', 'bills': 1, 'amount': 0, 'share_pct': 0, 'refund': 0, 'net_amount': 0},
  ];
  return {
    'today': _today,
    'month_from': _monthFrom,
    'timezone': 'Asia/Kolkata',
    'today_net': fig('today_net', 20000, "Today's net sale", 'Net hint.'),
    'today_gross': fig('today_gross', 22680.9, "Today's gross sale", 'Gross hint.'),
    'online_net': fig('online_net', 0, 'Online sale (net)', 'Online net hint.'),
    'online_gross': fig('online_gross', 0, 'Online sale (gross)', 'Online gross hint.'),
    'cash_collection': fig('cash_collection', 8430.5, 'Cash collection', 'Cash hint.'),
    'month_to_date': fig('month_to_date', 412000, 'Month to date', 'MTD hint.'),
    'today_bills': 14,
    'month_bills': 301,
    'today_online_bills': 0,
    'today_ladder': {
      'bills': 14, 'item_total': 21000, 'discount': 1000, 'net': 20000, 'service_charge': 1000,
      'tax': 1680.5, 'round_off': 0.4, 'grand_total': 22680.9, 'refund': 120,
    },
    'today_by_method': rows,
    'today_split_bills': 1,
    'today_unallocated': 0,
    'by_method': {'label': 'Collected by payment method', 'hint': 'By-method hint.'},
    'today_nc': {'label': 'Non-chargeable (NC) — not collected', 'hint': 'NC hint.', 'bills': 2, 'value': 1200},
    if (drills)
      'drills': {
        for (final k in const ['header', 'bills', 'day', 'zone', 'month', 'by_method', 'split', 'unallocated', 'nc', 'nothing_settled'])
          k: _drill(k),
        'by_method_rows': {for (final r in rows) '${r['method']}': _drill('by_method_row', row: '${r['method']}')},
      },
    ...over,
  };
}

/// GET /reports/mis/sales-summary for today, as the backend cuts it: Online
/// (gross) ₹1250.50 is its delivery row.
Map<String, dynamic> _salesSummary({bool split = true}) => {
      'meta': {
        'report': 'sales_summary',
        'title': 'Sales Summary',
        'window': {'from': _today, 'to': _today, 'days': 1, 'source': 'range', 'clamped': false},
        'timezone': 'Asia/Kolkata',
        'outlet_scope': 'outlet',
        'outlet_name': 'GGV',
        'generated_at': '${_today}T10:00:00.000Z',
        'notes': <String>[],
      },
      'columns': [
        {'key': 'bucket', 'label': 'Period', 'type': 'text'},
        {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
        {'key': 'grand_total', 'label': 'Gross', 'type': 'money', 'total': true},
      ],
      'totals': {
        'item_total': 24000, 'discount': 0, 'net': 21000, 'service_charge': 1000, 'tax': 1930.5,
        'round_off': 0.9, 'grand_total': 23931.4, 'refund': 0, 'bills': 15, 'covers': 40, 'apc': 525, 'abv': 1595.43,
      },
      'bucket': 'day',
      'series': [
        {'bucket': _today, 'bills': 15, 'grand_total': 23931.4},
      ],
      if (split)
        'by_order_type': [
          {'order_type': 'dine_in', 'bills': 14, 'grand_total': 22680.9, 'share_pct': 94.77},
          {'order_type': 'delivery', 'bills': 1, 'grand_total': 1250.5, 'share_pct': 5.23},
        ],
    };

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

void _window(WidgetTester tester, {double width = 1400, double height = 3000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeApi> _mount(
  WidgetTester tester, {
  Map<String, dynamic>? headline,
  DesignSystem system = DesignSystem.rustic,
  List<String> visible = _all,
  List<String>? opened,
  Map<String, dynamic> extra = const {},
  Map<String, dynamic>? profile,
  Widget Function(RestClient, Profile)? module,
}) async {
  await tester.pumpWidget(const SizedBox());
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await AppearanceController.instance.setDesignSystem(system);
  final api = _FakeApi({'/analytics/headline': headline ?? _headline(), ...extra}, profile: profile);
  final auth = AuthController(api: api);
  await auth.login('GGV', 'u', 'p');
  final rest = RestClient(auth);
  await tester.pumpWidget(GaiaScope(
    system: system,
    child: MaterialApp(
      theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (l, {Map<String, dynamic>? target}) {
          // No glance jump forwards a focus: none of these modules reads one.
          expect(target, isNull, reason: 'a glance jump must carry no focus target');
          opened?.add(l);
        },
        visibleLabels: visible,
        clearFocus: () {},
        child: Scaffold(
          backgroundColor: AppColors.bg,
          body: (module ?? m.overviewModule)(rest, rest.auth.profile!),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

Finder _key(String k) => find.byKey(ValueKey(k));
final Finder _jump = _key('sheet-jump');
final Finder _jump2 = _key('sheet-jump-secondary');

String _label(WidgetTester tester, Finder f) => tester.widget<ForkButton>(f).label;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Leave the destinations somewhere ELSE first, so every assertion that they
/// were moved is proven rather than true by default.
void _dirtyMemory() {
  m.misRememberReport('item_wise');
  DateRangeMemory.remember('reports', DateRange.fromPreset(RangePreset.last30));
  DateRangeMemory.remember('accounting', DateRange.fromPreset(RangePreset.last7));
  DateRangeMemory.remember('history', DateRange.fromPreset(RangePreset.lastMonth));
  DateRangeMemory.remember('analytics', DateRange.fromPreset(RangePreset.last30));
  TimeSlotMemory.remember('reports', TimeSlotSelection.preset('lunch'));
}

void _expectReports(String report, DateRange window) {
  expect(m.misOpenReportKey, report);
  expect(DateRangeMemory.of('reports'), window);
  expect(TimeSlotMemory.of('reports').isAllDay, isTrue, reason: 'a jump always opens the whole day');
}

DateRange get _day => DateRange.fromPreset(RangePreset.today);
DateRange get _month => _monthFrom == _today ? _day : DateRange.fromPreset(RangePreset.thisMonth);

void main() {
  setUp(() {
    RestaurantTime.adopt(RestaurantTime.defaultZone);
    DateRangeMemory.reset();
    m.misResetReportMemory();
    m.AccountingBillFilter.reset();
  });
  tearDown(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    m.AccountingBillFilter.reset();
    AppearanceController.instance.debugReset();
  });

  for (final system in DesignSystem.values) {
    group('[${system.id}]', () {
      testWidgets('each money figure opens its sheet, whose jump is the report that computes it', (tester) async {
        _window(tester);
        final cases = <String, (String, DateRange)>{
          'today_net': ('sales_summary', _day),
          'today_gross': ('sales_summary', _day),
          'online_net': ('sales_summary', _day),
          'online_gross': ('sales_summary', _day),
          'month_to_date': ('sales_summary', _month),
        };
        for (final e in cases.entries) {
          final opened = <String>[];
          _dirtyMemory();
          final api = await _mount(tester, system: system, opened: opened);
          await _tap(tester, _key('glance-${e.key}'));
          expect(find.byType(Dialog), findsOneWidget, reason: e.key);
          expect(opened, isEmpty, reason: 'looking is not jumping');
          expect(_label(tester, _jump), 'View in Reports');
          // Only Cash collection has a second place.
          expect(_jump2, findsNothing, reason: e.key);
          await _tap(tester, _jump);
          expect(opened, ['Reports'], reason: e.key);
          expect(find.byType(Dialog), findsNothing);
          _expectReports(e.value.$1, e.value.$2);
          expect(api.writes, isEmpty);
        }
      }, variant: _platforms);

      testWidgets('Online sale lands on a Sales Summary that shows the order-type split behind it', (tester) async {
        _window(tester);
        final opened = <String>[];
        _dirtyMemory();
        final h = _headline(over: {
          'online_gross': {'value': 1250.5, 'label': 'Online sale (gross)', 'hint': 'x', 'drill': _drill('online_gross')},
          'today_online_bills': 1,
        });
        await _mount(tester, system: system, headline: h, opened: opened);
        await _tap(tester, _key('glance-online_gross'));
        await _tap(tester, _jump);
        expect(opened, ['Reports']);
        _expectReports('sales_summary', _day);

        // The shell now mounts Reports, which reads what the jump left.
        final api = await _mount(tester, system: system, module: m.reportsModule, extra: {
          '/reports/mis/sales-summary': _salesSummary(),
        });
        final asked = api.calls.where((c) => c.startsWith('GET /reports/mis/sales-summary?')).toList();
        expect(asked, isNotEmpty);
        expect(asked.first, startsWith('GET /reports/mis/sales-summary?${_day.reportQuery}'));
        final split = _key('mis-order-types');
        await tester.ensureVisible(split);
        await tester.pumpAndSettle();
        expect(find.descendant(of: split, matching: find.text(m.kMisOrderTypeLabel)), findsOneWidget);
        // The tile's ₹1250.50 is the delivery row.
        expect(find.descendant(of: split, matching: find.text('delivery · ₹1250.50 (5.2%)')), findsOneWidget);
        expect(find.descendant(of: split, matching: find.text('dine_in · ₹22680.90 (94.8%)')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: _platforms);

      testWidgets('Cash collection is the Cash row: Settlement Summary first, the drawer second', (tester) async {
        _window(tester);
        final opened = <String>[];
        _dirtyMemory();
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-cash_collection'));
        expect(find.text('Cash · ₹8430.50'), findsOneWidget);
        expect(find.text(kGlanceDrawerNote), findsOneWidget);
        expect(_label(tester, _jump), 'View in Reports');
        expect(_label(tester, _jump2), 'View in Cash register');
        await _tap(tester, _jump);
        expect(opened, ['Reports']);
        _expectReports('settlement_summary', _day);

        opened.clear();
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-cash_collection'));
        await _tap(tester, _jump2);
        expect(opened, ['Cash register']);
      }, variant: _platforms);

      testWidgets("a mode's row and its count line open one sheet; its bills are Accounting's, filtered", (tester) async {
        _window(tester);
        final opened = <String>[];
        _dirtyMemory();
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-mode-count-Upi'));
        expect(find.text('UPI · ₹11000.00'), findsOneWidget);
        expect(find.text(kGlanceBillListNote), findsOneWidget);
        expect(_label(tester, _jump), 'View in Reports');
        expect(_label(tester, _jump2), 'View in Accounting');
        await _tap(tester, _jump2);
        expect(opened, ['Accounting']);
        expect(DateRangeMemory.of('accounting'), _day);
        expect(m.AccountingBillFilter.take(), (method: 'Upi', reveal: true));
        // The report tab was left alone: the owner took the other door.
        expect(m.misOpenReportKey, 'item_wise');

        opened.clear();
        await _mount(tester, system: system, opened: opened);
        // The bar itself, this time — the same sheet as its count line.
        await _tap(tester, find.byWidgetPredicate((w) => w is HBarRow && w.label == 'Unallocated'));
        expect(find.textContaining('Unallocated · '), findsOneWidget);
        await _tap(tester, _jump2);
        expect(opened, ['Accounting']);
        expect(m.AccountingBillFilter.take(), (method: 'Split', reveal: true),
            reason: "Unallocated is no stored method: its bills are the Split bills");
      }, variant: _platforms);

      testWidgets('the split note and the Unallocated warning lead to the Split bills', (tester) async {
        _window(tester);
        for (final key in const ['glance-split', 'glance-unallocated']) {
          final opened = <String>[];
          await _mount(tester, system: system, opened: opened);
          await _tap(tester, _key(key));
          expect(find.byType(Dialog), findsOneWidget, reason: key);
          expect(_label(tester, _jump), 'View in Accounting', reason: key);
          await _tap(tester, _jump);
          expect(opened, ['Accounting'], reason: key);
          expect(DateRangeMemory.of('accounting'), _day);
          expect(m.AccountingBillFilter.take(), (method: 'Split', reveal: true), reason: key);
        }
      }, variant: _platforms);

      testWidgets('NC opens its sheet and the NC Summary', (tester) async {
        _window(tester);
        final opened = <String>[];
        _dirtyMemory();
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-nc'));
        expect(find.text('Given away'), findsOneWidget);
        expect(find.text('₹1200.00'), findsOneWidget);
        await _tap(tester, _jump);
        expect(opened, ['Reports']);
        _expectReports('nc_summary', _day);
      }, variant: _platforms);

      testWidgets('the counts jump straight to their report; the header links to today', (tester) async {
        _window(tester);
        final cases = <String, String>{
          'glance-bills': 'order_summary',
          'glance-by-method': 'settlement_summary',
          'glance-report': 'sales_summary',
        };
        for (final e in cases.entries) {
          final opened = <String>[];
          _dirtyMemory();
          await _mount(tester, system: system, opened: opened);
          await _tap(tester, _key(e.key));
          expect(find.byType(Dialog), findsNothing, reason: '${e.key} is a direct jump');
          expect(opened, ['Reports'], reason: e.key);
          _expectReports(e.value, _day);
        }
        expect(tester.widget<ForkButton>(_key('glance-report')).label, kGlanceReportButton);
      }, variant: _platforms);

      testWidgets('the header title and the day chip explain how today is cut', (tester) async {
        _window(tester);
        for (final key in const ['glance-header', 'glance-day']) {
          final opened = <String>[];
          _dirtyMemory();
          await _mount(tester, system: system, opened: opened);
          // The title, not the link beside it.
          final at = key == 'glance-header'
              ? tester.getTopLeft(_key(key)) + const Offset(40, 8)
              : tester.getCenter(_key(key));
          await tester.tapAt(at);
          await tester.pumpAndSettle();
          expect(find.text(kGlanceDayTitle), findsOneWidget, reason: key);
          expect(find.text(kGlanceSettledClock), findsOneWidget);
          expect(find.text('Asia/Kolkata (UTC+05:30)'), findsOneWidget);
          await _tap(tester, _jump);
          expect(opened, ['Reports'], reason: key);
          _expectReports('sales_summary', _day);
        }
      }, variant: _platforms);

      testWidgets('the zone chip leads an admin to Settings, and anyone else to the day', (tester) async {
        _window(tester);
        var opened = <String>[];
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-zone'));
        expect(_label(tester, _jump), 'View in Settings');
        await _tap(tester, _jump);
        expect(opened, ['Settings']);

        opened = <String>[];
        await _mount(tester, system: system, opened: opened, visible: _all.where((l) => l != 'Settings').toList());
        await _tap(tester, _key('glance-zone'));
        expect(_label(tester, _jump), 'View in Reports');
        await _tap(tester, _jump);
        expect(opened, ['Reports']);
      }, variant: _platforms);

      testWidgets('the month chip is the month to date sheet', (tester) async {
        _window(tester);
        final opened = <String>[];
        _dirtyMemory();
        await _mount(tester, system: system, opened: opened);
        await _tap(tester, _key('glance-month'));
        expect(find.text('Month to date · ₹412000.00'), findsOneWidget);
        expect(find.text('Bills settled this month'), findsOneWidget);
        expect(find.text('301'), findsOneWidget);
        await _tap(tester, _jump);
        expect(opened, ['Reports']);
        _expectReports('sales_summary', _month);
      }, variant: _platforms);

      testWidgets('an empty day names the open bills and leads to the floor', (tester) async {
        _window(tester);
        final empty = _headline(over: {'today_bills': 0, 'today_by_method': <dynamic>[], 'today_nc': null});
        var opened = <String>[];
        await _mount(tester, system: system, headline: empty, opened: opened, extra: {
          '/bills/open': {'total': 3, 'outstanding_total': 5400, 'bills': <dynamic>[]},
        });
        expect(find.textContaining('3 bills are still open on the floor.'), findsOneWidget);
        await _tap(tester, _key('glance-nothing-settled'));
        expect(opened, ['Tables']);

        opened = <String>[];
        await _mount(tester, system: system, headline: empty, opened: opened,
            visible: const ['Overview', 'Orders'], extra: {'/bills/open': {'total': 0}});
        expect(find.textContaining('No bill is open on the floor either.'), findsOneWidget);
        await _tap(tester, _key('glance-nothing-settled'));
        expect(opened, ['Orders']);

        opened = <String>[];
        await _mount(tester, system: system, headline: empty, opened: opened, visible: const ['Overview']);
        // No floor to go to, and no count fetched: the sentence explains the day instead.
        expect(find.textContaining('still open on the floor'), findsNothing);
        await _tap(tester, _key('glance-nothing-settled'));
        expect(find.text(kGlanceDayTitle), findsOneWidget);
        expect(opened, isEmpty);
      }, variant: _platforms);
    });
  }

  group('what the sheets say', () {
    testWidgets('₹0 online explains that Zomato at the table is a payment mode, counted above', (tester) async {
      _window(tester);
      await _mount(tester);
      await _tap(tester, _key('glance-online_gross'));
      expect(find.text(kGlanceOnlineNone), findsOneWidget);
      expect(find.text(kGlanceOnlineRule), findsOneWidget);
      expect(find.text('Online bills today'), findsOneWidget);

      await _mount(tester, headline: _headline(over: {
        'online_gross': {'value': 1250.5, 'label': 'Online sale (gross)', 'hint': 'x'},
        'today_online_bills': 2,
      }));
      await _tap(tester, _key('glance-online_net'));
      expect(find.text(kGlanceOnlineNone), findsNothing);
      // In the sheet — the tile behind it prints the same figure.
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('₹1250.50')), findsOneWidget);
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('2')), findsOneWidget);
    });

    testWidgets("the net and gross sheets print today's ladder, and mark the figure tapped", (tester) async {
      _window(tester);
      await _mount(tester);
      await _tap(tester, _key('glance-today_net'));
      for (final (_, label) in kGlanceLadder) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('− ₹1000.00'), findsOneWidget, reason: 'the discount comes off');
      expect(find.text('− ₹120.00'), findsOneWidget, reason: 'and so do refunds');
      expect(find.text('this figure'), findsOneWidget);
      expect(tester.getTopLeft(find.text('this figure')).dy, closeTo(tester.getTopLeft(find.text('Net')).dy, 20));

      await _mount(tester);
      await _tap(tester, _key('glance-today_gross'));
      expect(find.text(kGlanceGrossAddsUp), findsOneWidget);
      expect(tester.getTopLeft(find.text('this figure')).dy, closeTo(tester.getTopLeft(find.text('Gross')).dy, 20));
    });

    testWidgets('an older backend with no ladder gets the sheet without it — never a ladder of zeros', (tester) async {
      _window(tester);
      final old = _headline(drills: false)..remove('today_ladder');
      await _mount(tester, headline: old);
      await _tap(tester, _key('glance-today_net'));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Item total'), findsNothing);
      expect(find.text('Service charge'), findsNothing);
      expect(find.text('Net hint.'), findsWidgets);
    });

    testWidgets('no cash taken today is said, not drawn as a row', (tester) async {
      _window(tester);
      await _mount(tester, headline: _headline(over: {
        'today_by_method': [
          {'method': 'Upi', 'label': 'UPI', 'bills': 1, 'amount': 100, 'share_pct': 100, 'refund': 0, 'net_amount': 100},
        ],
        'cash_collection': {'value': 0, 'label': 'Cash collection', 'hint': 'Cash hint.', 'drill': _drill('cash_collection')},
      }));
      await _tap(tester, _key('glance-cash_collection'));
      expect(find.text(kGlanceNoCash), findsOneWidget);
      expect(find.text('Cash collection · ₹0.00'), findsOneWidget);
    });

    testWidgets('each element is ONE button to a screen reader, named for what it opens', (tester) async {
      _window(tester);
      final handle = tester.ensureSemantics();
      await _mount(tester);
      expect(
        tester.getSemantics(_key('glance-today_net')),
        containsSemantics(label: "Today's net sale ₹20000.00, opens details", isButton: true, hasTapAction: true),
      );
      // The header keeps its children: the report link inside it is a button of its own.
      expect(find.bySemanticsLabel(RegExp(kGlanceReportButton, caseSensitive: false)), findsWidgets);
      handle.dispose();
    });
  });

  group('who can go where', () {
    testWidgets('a user who can open none of the destinations still gets every sheet — and no dead jump', (tester) async {
      _window(tester);
      final opened = <String>[];
      await _mount(tester, visible: const ['Overview'], opened: opened);
      expect(_key('glance-report'), findsNothing, reason: 'a link to nowhere is not offered');
      for (final key in const [
        'glance-today_net', 'glance-today_gross', 'glance-online_net', 'glance-online_gross',
        'glance-cash_collection', 'glance-month_to_date', 'glance-bills', 'glance-day', 'glance-zone',
        'glance-month', 'glance-by-method', 'glance-mode-count-Upi', 'glance-split', 'glance-unallocated',
        'glance-nc',
      ]) {
        await _tap(tester, _key(key));
        expect(find.byType(Dialog), findsOneWidget, reason: '$key must still explain itself');
        expect(_jump, findsNothing, reason: key);
        expect(_jump2, findsNothing, reason: key);
        await tester.tap(find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Close'));
        await tester.pumpAndSettle();
      }
      expect(opened, isEmpty);
    });

    testWidgets('an APC-only manager (the headline audience) lands on Reports, not a hidden Accounting', (tester) async {
      _window(tester);
      final profile = _profile('manager', const ['View Order APC']);
      final visible = visibleModuleLabelsFor(Profile.fromJson(profile));
      expect(visible, contains('Reports'));
      expect(visible, isNot(contains('Accounting')), reason: "'View Order APC' matches no Accounting keyword");
      final opened = <String>[];
      _dirtyMemory();
      await _mount(tester, profile: profile, visible: visible, opened: opened);
      await _tap(tester, _key('glance-mode-count-Cash'));
      expect(_label(tester, _jump), 'View in Reports');
      expect(_jump2, findsNothing, reason: 'Accounting is not theirs to open');
      await _tap(tester, _jump);
      expect(opened, ['Reports']);
      _expectReports('settlement_summary', _day);
    });

    testWidgets('a plan without accounting drops Reports and Accounting: the figures fall back to Analytics', (tester) async {
      _window(tester);
      final profile = _profile('manager', const ['View Order APC'], features: const {'accounting': false});
      final visible = visibleModuleLabelsFor(Profile.fromJson(profile));
      expect(visible, isNot(contains('Reports')));
      final opened = <String>[];
      _dirtyMemory();
      await _mount(tester, profile: profile, visible: visible, opened: opened);
      await _tap(tester, _key('glance-today_net'));
      expect(_label(tester, _jump), 'View in Analytics');
      await _tap(tester, _jump);
      expect(opened, ['Analytics']);
      // ...on the tapped day, not on the window Analytics last showed.
      expect(DateRangeMemory.of('analytics'), _day);
      // Nothing about Reports was touched on the way to a different module.
      expect(m.misOpenReportKey, 'item_wise');
      expect(TimeSlotMemory.of('reports').isAllDay, isFalse);

      // Month to date lands on the month.
      _dirtyMemory();
      opened.clear();
      await _mount(tester, profile: profile, visible: visible, opened: opened);
      await _tap(tester, _key('glance-month_to_date'));
      await _tap(tester, _jump);
      expect(opened, ['Analytics']);
      expect(DateRangeMemory.of('analytics'), _month);

      // Online trade is on the Sales Summary alone: the sheet explains, with no jump.
      await _mount(tester, profile: profile, visible: visible);
      await _tap(tester, _key('glance-online_gross'));
      expect(find.text(kGlanceOnlineRule), findsOneWidget);
      expect(_jump, findsNothing);

      // The split note's only destinations are Accounting and Reports: a sheet, no jump.
      await _mount(tester, profile: profile, visible: visible);
      await _tap(tester, _key('glance-split'));
      expect(find.byType(Dialog), findsOneWidget);
      expect(_jump, findsNothing);
    });

    testWidgets('an older backend with no drills lands every element in the same place', (tester) async {
      _window(tester);
      for (final (key, module) in const [
        ('glance-today_net', 'Reports'),
        ('glance-cash_collection', 'Reports'),
        ('glance-split', 'Accounting'),
        ('glance-nc', 'Reports'),
        ('glance-month', 'Reports'),
      ]) {
        final withDrills = <String>[];
        _dirtyMemory();
        await _mount(tester, opened: withDrills);
        await _tap(tester, _key(key));
        await _tap(tester, _jump);
        final served = (m.misOpenReportKey, DateRangeMemory.of('reports'), DateRangeMemory.of('accounting'));

        final without = <String>[];
        _dirtyMemory();
        await _mount(tester, headline: _headline(drills: false), opened: without);
        await _tap(tester, _key(key));
        await _tap(tester, _jump);
        expect(without, withDrills, reason: key);
        expect(without, [module], reason: key);
        expect((m.misOpenReportKey, DateRangeMemory.of('reports'), DateRangeMemory.of('accounting')), served, reason: key);
      }
      for (final key in const ['glance-bills', 'glance-by-method', 'glance-report']) {
        final opened = <String>[];
        await _mount(tester, headline: _headline(drills: false), opened: opened);
        await _tap(tester, _key(key));
        expect(opened, ['Reports'], reason: key);
      }
    });

    testWidgets("the server's destination is followed, not the app's table", (tester) async {
      _window(tester);
      final opened = <String>[];
      final h = _headline();
      h['today_net'] = {
        ...(h['today_net'] as Map),
        'drill': {'module': 'History', 'params': {'from': _monthFrom, 'to': _today}, 'href': '/dashboard/history', 'fallbacks': []},
      };
      await _mount(tester, headline: h, opened: opened);
      await _tap(tester, _key('glance-today_net'));
      expect(_label(tester, _jump), 'View in History');
      await _tap(tester, _jump);
      expect(opened, ['History']);
      expect(DateRangeMemory.of('history'), _month);
    });

    for (final (who, profile) in [
      ('a waiter', _profile('waiter', _waiterActions)),
      ('a waiter whose role holds View Order APC', _profile('waiter', const [..._waiterActions, 'View Order APC'])),
      ('a cashier without the analytics action', _profile('cashier', const ['View Bills', 'Close Bill', 'View Orders'])),
    ]) {
      testWidgets('$who never asks for the headline and never gets the box', (tester) async {
        _window(tester);
        final api = await _mount(tester, profile: profile, extra: const {
          '/me/scorecard': {'components': <String, dynamic>{}},
        });
        expect(api.calls.where((c) => c.contains('/analytics/headline')), isEmpty);
        expect(_key('glance-box'), findsNothing);
        expect(find.text('Today at a glance'), findsNothing);
      });
    }
  });

  group('the destinations take the jump', () {
    Map<String, dynamic> accountingRoutes() => {
          '/reports/sales': {
            'total_sales': 100.0, 'total_tax': 5.0, 'total_service_charge': 0, 'total_refund': 0,
            'net_sales': 100.0, 'bill_count': 1,
            'by_day': [{'date': _today, 'sales': 100.0, 'tax': 5.0, 'service_charge': 0, 'refund': 0, 'bills': 1}],
            'by_method': [{'method': 'Cash', 'sales': 100.0, 'bills': 1}],
          },
          '/reports/gst': {'by_rate': <dynamic>[]},
          '/reports/pnl': {'expenses_by_category': <dynamic>[]},
          '/expenses': {'expenses': <dynamic>[]},
          '/payroll': {'rows': <dynamic>[]},
          '/reports/discounts': {'by_coupon': <dynamic>[]},
          '/reports/schedules': {'schedules': <dynamic>[]},
          '/reports/deliveries': {'deliveries': <dynamic>[]},
          '/bills/closed': {'bills': <dynamic>[], 'total': 0, 'has_more': false},
          '/bills/open': {'bills': <dynamic>[], 'total': 0},
        };

    testWidgets('Accounting takes the one-shot filter once, holds it in the dropdown, and scrolls to the bills',
        (tester) async {
      _window(tester, width: 1200, height: 700);
      DateRangeMemory.remember('accounting', _day);
      m.AccountingBillFilter.remember('Split', reveal: true);
      final api = await _mount(tester, module: m.accountingModule, extra: accountingRoutes());
      final lists = api.calls.where((c) => c.startsWith('GET /bills/closed?')).toList();
      expect(lists, isNotEmpty);
      expect(lists.first, contains('payment_method=Split'));
      expect(lists.first, contains('from=$_today&to=$_today'));
      // 'Split' is not one of the window's modes, and the dropdown still holds it.
      expect(find.text('Split'), findsOneWidget);
      // Scrolled to the Settled bills header: it is inside the 700px viewport.
      final header = find.text('Settled bills');
      expect(header, findsOneWidget);
      final y = tester.getTopLeft(header).dy;
      expect(y, inInclusiveRange(0, 700));
      expect(m.AccountingBillFilter.take(), isNull, reason: 'spent on arrival');

      // The next ordinary visit is "All methods" again.
      final again = await _mount(tester, module: m.accountingModule, extra: accountingRoutes());
      expect(again.calls.where((c) => c.startsWith('GET /bills/closed?')).first, isNot(contains('payment_method')));
    }, variant: _platforms);

    testWidgets('Analytics opens on the window the jump left, and asks for that window', (tester) async {
      _window(tester);
      DateRangeMemory.remember('analytics', _day);
      final api = await _mount(tester, module: m.analyticsModule);
      final windowed = api.calls.where((c) => c.startsWith('GET /analytics/advanced?')).toList();
      expect(windowed, isNotEmpty);
      expect(windowed.first, 'GET /analytics/advanced?${_day.query}');
      expect(api.writes, isEmpty);
    });

    testWidgets('Reports opens on the remembered report, the server day and the whole day', (tester) async {
      _window(tester);
      m.misRememberReport('settlement_summary');
      DateRangeMemory.remember('reports', _day);
      final api = await _mount(tester, module: m.reportsModule, extra: const {
        '/reports/mis/settlement-summary': {'rows': <dynamic>[], 'totals': <String, dynamic>{}},
      });
      final asked = api.calls.where((c) => c.startsWith('GET /reports/mis/') && !c.contains('time-slots')).toList();
      expect(asked, isNotEmpty);
      expect(asked.first, startsWith('GET /reports/mis/settlement-summary?${_day.reportQuery}'));
      expect(asked.first, isNot(contains('slot=')), reason: 'all day adds nothing to the URL');
      // An unknown key moves nothing.
      m.misRememberReport('no_such_report');
      expect(m.misOpenReportKey, 'settlement_summary');
    });
  });

  group('phones and raised text', () {
    for (final system in DesignSystem.values) {
      testWidgets('the box and every new sheet survive 360-1200px at 1.0x and 1.3x [${system.id}]', (tester) async {
        for (final width in const [360.0, 390.0, 800.0, 1200.0]) {
          for (final scale in const [1.0, 1.3]) {
            tester.view.physicalSize = Size(width, 5000);
            tester.view.devicePixelRatio = 1.0;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            final big = _headline(over: {
              'today_gross': {'value': 101289001.22, 'label': "Today's gross sale", 'hint': 'x' * 200, 'drill': _drill('today_gross')},
              'today_nc': {'label': 'Non-chargeable (NC) — not collected', 'hint': 'y' * 200, 'bills': 1234, 'value': 98765432.1},
              'today_split_bills': 321,
              'today_unallocated': 55555.55,
            });
            await _mount(tester, system: system, headline: big);
            expect(tester.takeException(), isNull, reason: 'box at ${width}px / ${scale}x');
            for (final key in const [
              'glance-today_net', 'glance-today_gross', 'glance-online_gross', 'glance-cash_collection',
              'glance-month_to_date', 'glance-day', 'glance-zone', 'glance-month', 'glance-mode-count-Upi',
              'glance-split', 'glance-unallocated', 'glance-nc',
            ]) {
              await _tap(tester, _key(key));
              expect(tester.takeException(), isNull, reason: '$key sheet at ${width}px / ${scale}x');
              expect(find.byType(Dialog), findsOneWidget, reason: key);
              await tester.tap(find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Close'));
              await tester.pumpAndSettle();
            }
          }
        }
      });
    }
  });
}
