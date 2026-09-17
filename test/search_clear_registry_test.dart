import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/menu_badge.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_tabs.dart';
import 'package:restaurant_owner_app/widgets/menu_badges.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

import 'fixtures/planted_searches.dart';
import 'search_contract.dart';
import 'text_field_scan.dart';

/// CLIENT ITEM 6 (2.0.2) — "While typing in a search bar in any part of the
/// software, pressing the 'x' does not clear the search … in tables and every
/// other section with a search, clicking the 'x' at the rightmost end after
/// typing must clear the search."
///
/// THE REGISTRY. Every search box in the app is the shared AppSearchField, and
/// every one has a row here (the MIS reports' row is in
/// test/reports_module_test.dart, beside its fixtures): the real screen,
/// pumped in both design systems, on Android at 360dp and on Windows, and put
/// through the whole contract in test/search_contract.dart by pressing the x
/// where it is drawn.
///
/// Then the guards that keep it that way: no search-shaped text field outside
/// the shared widget, no AppSearchField without a row, and a contract that
/// still catches every broken box planted in test/fixtures.

class _Api extends ApiClient {
  _Api(this.routes, {this.role = 'admin'});

  /// Path prefix → the GET response (a value, or a function of the full path).
  final Map<String, Object> routes;
  final String role;
  final List<String> gets = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'ravi',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'actions_set': role == 'waiter' ? const ['a1'] : const ['*'],
          'action_names': const ['View Orders', 'Create Order', 'View Tables', 'Occupy Table', 'View Menu'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') return routes['$method $path'] ?? <String, dynamic>{'success': true};
    gets.add(path);
    final keys = routes.keys.where(path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    if (keys.isEmpty) throw ApiException('No fake route for $path', 404);
    final hit = routes[keys.first]!;
    return hit is Function ? (hit as dynamic Function(String))(path) : hit;
  }

  /// Whether the newest GET that starts with [prefix] carried a search.
  bool lastSearched(String prefix) =>
      gets.lastWhere((p) => p.startsWith(prefix), orElse: () => '').contains('search=');
}

String _searchOf(String path) => Uri.parse('http://x$path').queryParameters['search'] ?? '';

const _dishes = [
  {'id': 'mi-1', 'name': 'Paneer Tikka', 'price': 250.0, 'category': 'Starters', 'available': true},
  {'id': 'mi-2', 'name': 'Dal Makhani', 'price': 220.0, 'category': 'Mains', 'available': true},
  {'id': 'mi-3', 'name': 'Butter Naan', 'price': 60.0, 'category': 'Breads', 'available': true},
];

Map<String, dynamic> _guest(String name, int i) => {
      'customer_id': 'c$i',
      'name': name,
      'phone': '90000000$i',
      'email': 'g$i@example.com',
      'visits': 2,
      'total_spend': 100.0 * i,
      'total_service_charge': 0,
      'total_tax': 0,
      'pre_tax_spend': 100.0 * i,
      'avg_spend_per_visit': 100.0,
      'last_visit': '2026-08-0${i}T12:00:00Z',
      'days_since_last_visit': i,
      'bills': 2,
      'avg_rating': null,
      'feedbacks': 0,
      'segment': 'regular',
    };

dynamic _guests(String path) {
  final q = _searchOf(path).toLowerCase();
  final all = [_guest('Asha Rao', 1), _guest('Ravi Kumar', 2), _guest('Meena Iyer', 3)];
  final rows = [for (final g in all) if (q.isEmpty || '${g['name']}'.toLowerCase().contains(q)) g];
  if (!path.contains('meta=1')) return rows;
  return {
    'customers': rows,
    'total': rows.length,
    'has_more': false,
    'sort': 'recent',
    'segment': 'all',
    'segment_counts': {'new': 0, 'regular': rows.length, 'high-spend': 0, 'dormant': 0},
    'spend_basis': 'tax-inclusive grand total of settled bills',
  };
}

dynamic _audit(String path) {
  final q = _searchOf(path).toLowerCase();
  final all = [
    {'id': 'a1', 'action': 'Menu Edited', 'details': 'price', 'employee': 'Asha', 'category': 'Menu', 'timestamp': '2026-08-03T05:00:00.000Z'},
    {'id': 'a2', 'action': 'Bill Printed', 'details': 'T4', 'employee': 'Ravi', 'category': 'Bill', 'timestamp': '2026-08-03T06:00:00.000Z'},
  ];
  final rows = [for (final r in all) if (q.isEmpty || '${r['action']} ${r['employee']}'.toLowerCase().contains(q)) r];
  return {'logs': rows, 'total': rows.length, 'has_more': false};
}

Map<String, dynamic> _bill(String id, String no, String table) => {
      'id': id,
      'bill_no': no,
      'table_name': table,
      'covers': 2,
      'grand_total': 500.0,
      'payment_method': 'Cash',
      'settled_at': '${RestaurantTime.isoDate(DateTime.now())}T10:00:00.000Z',
    };

dynamic _closedBills(String path) {
  final q = _searchOf(path).toLowerCase();
  final all = [_bill('b1', '101', 'T1'), _bill('b2', '102', 'T7')];
  final rows = [for (final b in all) if (q.isEmpty || '${b['bill_no']} ${b['table_name']}'.toLowerCase().contains(q)) b];
  return {'bills': rows, 'total': rows.length, 'has_more': false};
}

final Map<String, Object> _accounting = {
  '/reports/sales': {
    'total_sales': 100.0, 'total_tax': 0.0, 'total_service_charge': 0.0, 'total_refund': 0.0,
    'net_sales': 100.0, 'bill_count': 1, 'by_day': <Map<String, dynamic>>[], 'by_method': <Map<String, dynamic>>[],
  },
  '/reports/gst': {'total_taxable': 0.0, 'total_tax': 0.0, 'by_rate': <Map<String, dynamic>>[]},
  '/reports/pnl': {
    'gross_sales': 100.0, 'refunds': 0.0, 'tax_collected': 0.0, 'net_revenue': 100.0,
    'total_expenses': 0.0, 'net_profit': 100.0, 'expenses_by_category': <Map<String, dynamic>>[],
  },
  '/reports/discounts': {'bill_count': 1, 'discounted_bills': 0, 'by_coupon': <Map<String, dynamic>>[]},
  '/reports/schedules': {'schedules': <Map<String, dynamic>>[]},
  '/reports/deliveries': {'deliveries': <Map<String, dynamic>>[]},
  '/expenses': {'expenses': <Map<String, dynamic>>[]},
  '/payroll': {'total_due': 0.0, 'total_paid': 0.0, 'rows': <Map<String, dynamic>>[]},
  '/bills/closed': _closedBills,
};

final Map<String, Object> _settings = {
  '/restaurant/profile': <String, dynamic>{'restaurant_name': 'CSR Organics'},
  '/restaurant/settings': <String, dynamic>{'timezone': 'Asia/Kolkata', 'currency': 'INR'},
  '/restaurant/timezones': <String, dynamic>{
    'timezones': ['Asia/Kolkata', 'America/New_York', 'UTC'],
    'current': 'Asia/Kolkata',
    'default': 'Asia/Kolkata',
  },
};

const _simulation = <String, Object>{
  'POST /simulation/run': <String, dynamic>{
    'current': {'covers': 100, 'apc': 400, 'revenue': 40000, 'labour_cost': 6000, 'food_cost': 12800, 'marketing_per_day': 0, 'net_profit': 16200, 'tat_min': 42},
    'simulated': {'covers': 100, 'apc': 400, 'revenue': 40000, 'labour_cost': 6000, 'food_cost': 12800, 'marketing_per_day': 0, 'net_profit': 16200, 'tat_min': 42},
    'delta': {'covers': 0, 'apc': 0, 'revenue': 0, 'labour_cost': 0, 'food_cost': 0, 'marketing_per_day': 0, 'net_profit': 0, 'tat_min': 0},
    'notes': <String>[],
    'breakeven_days': null,
  },
  '/simulation/baseline': <String, dynamic>{
    'window_days': 30, 'covers_per_day': 100, 'apc': 400, 'revenue_per_day': 40000,
    'food_cost_pct': 32, 'labour_cost_per_day': 6000, 'staff_count': 12, 'avg_tat_min': 42,
    'table_count': 18, 'fixed_costs_per_day': 5000, 'net_profit_per_day': 16200,
    'sources': <String, dynamic>{},
  },
};

Future<_Api> _signIn(_Api api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  _auth = auth;
  return api;
}

late AuthController _auth;

/// A 412dp phone, for the three rows whose SCREEN (not its search box)
/// overflows at 360dp today. Found by these rows, reported with the 2.0.2
/// search work and not fixed in it; a row moves back to 360dp when its screen
/// is fixed:
///  * the audit trail's entry row (modules.dart `_entryCard`), Gaia: 5.6px;
///  * the timezone dialog's zone row, both designs: 16px;
///  * the Simulation lever row, Gaia: 16px, before the picker is opened.
const _widePhone = Size(412, 800);

/// A module the way the shell hosts one.
Future<_Api> _mountModule(
  WidgetTester tester,
  DesignSystem ds,
  Widget Function(RestClient, Profile) module,
  Map<String, Object> routes, {
  bool widePhone = false,
}) async {
  await tester.pumpWidget(const SizedBox());
  useSearchView(tester, onPhone && widePhone ? _widePhone : null);
  final api = await _signIn(_Api(routes));
  await tester.pumpWidget(searchThemed(
    ds,
    Scaffold(
      body: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Menu', 'Customers', 'Audit log', 'Accounting', 'Settings', 'Simulation'],
        clearFocus: () {},
        child: module(RestClient(_auth), _auth.profile!),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

bool _shown(String t) => find.text(t, skipOffstage: false).evaluate().isNotEmpty;

/// The testIds of every AppSearchField in lib/, read from the source.
Map<String, List<String>> _libSearchFields() {
  final byId = <String, List<String>>{};
  for (final s in libSources) {
    if (s.path == 'lib/ui/widgets/app_search_field.dart') continue;
    for (final call in s.calls(const {'AppSearchField'})) {
      final id = call.args['testId'];
      final literal = id == null ? null : RegExp(r"^'([a-z0-9-]+)'$").firstMatch(id)?.group(1);
      (byId[literal ?? '<not a literal: $id>'] ??= []).add(call.where);
    }
  }
  return byId;
}

/// The testIds that have contract rows, read from the tests.
Set<String> _rowIds() => {
      for (final f in Directory('test').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('_test.dart')))
        for (final m in RegExp(r"searchContractRows\(\s*'([a-z0-9-]+)'").allMatches(f.readAsStringSync())) m.group(1)!,
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Outbox.instance.debugReset();
    RestaurantTime.adopt(RestaurantTime.defaultZone);
  });

  // ---------------------------------------------------------- the rows ----

  // Tables → a table → the order pad (and Orders → takeaway / delivery). The
  // box the client's complaint was about, as a waiter sees it.
  searchContractRows('order-search', (tester, ds) async {
    useSearchView(tester);
    await _signIn(_Api({'/menu': _dishes}, role: 'waiter'));
    await tester.pumpWidget(searchThemed(ds, OrderEntryScreen(rest: RestClient(_auth), tableName: 'T1')));
    await tester.pumpAndSettle();
    return SearchSurface(
      field: find.byKey(const ValueKey('order-search')),
      typed: 'dal',
      filtered: () => find.text('Paneer Tikka').evaluate().isEmpty,
    );
  });

  // Menu, inside the REAL shell: the shell rebuilds it on every MediaQuery
  // change and every setState of its own, which is what used to wipe it.
  searchContractRows('menu-search', (tester, ds) async {
    useSearchView(tester);
    await _signIn(_Api({'/menu': _dishes}));
    await tester.pumpWidget(searchThemed(ds, HomeShell(auth: _auth, startPrinterAgent: false)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    if (onPhone) {
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Menu')));
    } else {
      await tester.tap(find.descendant(of: find.byType(ListView).first, matching: find.text('Menu')));
    }
    await tester.pumpAndSettle();
    return SearchSurface(
      field: find.byKey(const ValueKey('menu-search')),
      typed: 'dal',
      // While searching, the category tabs step aside for one flat result list.
      filtered: () => find.byType(ForkTabs).evaluate().isEmpty,
      rebuild: () async {
        // Any setState of the shell's own (the sidebar toggle, a badge count)…
        (tester.state(find.byType(HomeShell)) as dynamic).setState(() {});
        await tester.pumpAndSettle();
        // …and a window resize (a tablet turned, a till window restored).
        tester.view.physicalSize = searchViewSize + const Offset(40, 0);
        await tester.pumpAndSettle();
      },
    );
  });

  searchContractRows('audit-search', (tester, ds) async {
    final api = await _mountModule(tester, ds, m.auditLogModule, {'/audit-logs': _audit},
        widePhone: ds == DesignSystem.gaia);
    return SearchSurface(
      field: find.byKey(const ValueKey('audit-search')),
      typed: 'ravi',
      filtered: () => api.lastSearched('/audit-logs'),
    );
  });

  // One box, both design systems: the Rustic column and the Gaia bokeh list.
  searchContractRows('guests-search', (tester, ds) async {
    final api = await _mountModule(tester, ds, m.customersModule, {'/customers/segments': _guests});
    return SearchSurface(
      field: find.byKey(const ValueKey('guests-search')),
      typed: 'asha',
      filtered: () => api.gets.lastWhere((p) => p.contains('meta=1')).contains('search='),
    );
  });

  // Accounting → Settled bills.
  searchContractRows('bills-search', (tester, ds) async {
    final api = await _mountModule(tester, ds, m.accountingModule, _accounting);
    await _scrollTo(tester, find.byKey(const ValueKey('bills-search')));
    return SearchSurface(
      field: find.byKey(const ValueKey('bills-search')),
      typed: '102',
      filtered: () => api.lastSearched('/bills/closed'),
    );
  });

  // Settings → Timezone → Change: a box in a dialog.
  searchContractRows('tz-search', (tester, ds) async {
    await _mountModule(tester, ds, m.settingsModule, _settings, widePhone: true);
    final change = find.ancestor(of: find.byIcon(Icons.public), matching: find.byType(ForkButton));
    await _scrollTo(tester, change);
    await tester.tap(change);
    await tester.pumpAndSettle();
    return SearchSurface(
      field: find.byKey(const ValueKey('tz-search')),
      typed: 'york',
      filtered: () => !_shown('UTC'),
      stillOpen: () => find.byType(Dialog).evaluate().isNotEmpty,
    );
  });

  // Menu → Tag dishes: a box in a dialog, beside the badge pills.
  searchContractRows('tag-dishes-search', (tester, ds) async {
    await _mountModule(
      tester,
      ds,
      (rest, _) => Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => MenuBadgeTagDialog(
                rest: rest,
                items: const [
                  {'id': 'mi-1', 'name': 'Paneer Tikka', 'category': 'Starters', 'badges': ['chef']},
                  {'id': 'mi-2', 'name': 'Dal Makhani', 'category': 'Mains', 'badges': <String>[]},
                ],
                catalogue: const [MenuBadge(id: 'chef', label: 'Chef special', kind: MenuBadgeKind.promo)],
                perItemMax: 3,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      const {},
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return SearchSurface(
      field: find.byKey(const ValueKey('tag-dishes-search')),
      typed: 'dal',
      filtered: () => !_shown('Paneer Tikka'),
      stillOpen: () => find.byType(MenuBadgeTagDialog).evaluate().isNotEmpty,
    );
  });

  // Simulation → Add a lever: a bottom sheet on the phone, a popover on the till.
  searchContractRows('sim-pick-search', (tester, ds) async {
    await _mountModule(tester, ds, m.simulationModule, _simulation, widePhone: ds == DesignSystem.gaia);
    await tester.tap(textAnyCase('Add a lever').first);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('sim-pick-search'));
    int rows() => find
        .byWidgetPredicate((w) {
          final k = w.key;
          return k is ValueKey<String> && k.value.startsWith('sim-pick-') && !k.value.startsWith('sim-pick-search');
        }, skipOffstage: false)
        .evaluate()
        .length;
    final all = rows();
    expect(all, greaterThan(1));
    return SearchSurface(
      field: field,
      typed: 'price',
      filtered: () => rows() < all,
      stillOpen: () => field.evaluate().isNotEmpty,
    );
  });

  // ------------------------------------------------------ what the rows prove

  testWidgets('the order pad: the x never touches the order being built', (tester) async {
    useSearchView(tester);
    await _signIn(_Api({'/menu': _dishes}));
    await tester.pumpWidget(searchThemed(DesignSystem.rustic, OrderEntryScreen(rest: RestClient(_auth), orderType: 'takeaway')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('order-search'));
    await tester.enterText(field, 'naan');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Send order · 1 item'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('order-search-clear'))), kind: searchPointer);
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, field), isEmpty);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.textContaining('Send order · 1 item'), findsOneWidget, reason: 'the cart is untouched');
  }, variant: searchPlatforms);

  testWidgets('the Menu keeps its search when the phone keyboard goes down after Done', (tester) async {
    // The exact phone sequence that used to lose it: tap the box (keyboard up),
    // type, press the keyboard's Done (keyboard down) to look at the results.
    useSearchView(tester, const Size(360, 800));
    await _signIn(_Api({'/menu': _dishes}));
    await tester.pumpWidget(searchThemed(DesignSystem.gaia, HomeShell(auth: _auth, startPrinterAgent: false)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Menu')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('menu-search'));
    await tester.tapAt(tester.getCenter(field), kind: searchPointer);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'dal');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, field), 'dal');
    expect(find.byType(ForkTabs), findsNothing, reason: 'the search results are still showing');
    expect(find.text('Paneer Tikka'), findsNothing);

    // The empty state's own "Clear search" empties the box too.
    await tester.enterText(field, 'zzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('"zzz"'), findsOneWidget);
    await tester.ensureVisible(textAnyCase('Clear search'));
    await tester.tap(textAnyCase('Clear search'));
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, field), isEmpty);
    expect(find.byType(ForkTabs), findsOneWidget);
  }, variant: searchPlatforms);

  testWidgets("the audit trail's Clear filters empties the box, with one request", (tester) async {
    final api = await _mountModule(tester, DesignSystem.rustic, m.auditLogModule, {'/audit-logs': _audit});
    final field = find.byKey(const ValueKey('audit-search'));
    await tester.enterText(field, 'ravi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(api.lastSearched('/audit-logs'), isTrue);
    final before = api.gets.length;
    await tester.tap(textAnyCase('Clear filters').first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, field), isEmpty);
    expect(api.gets.length - before, 1, reason: 'clearing the box must not be a second request');
    expect(api.lastSearched('/audit-logs'), isFalse);
  }, variant: searchPlatforms);

  testWidgets('Settled bills: the x is there on the first keystroke, and Enter searches at once', (tester) async {
    final api = await _mountModule(tester, DesignSystem.rustic, m.accountingModule, _accounting);
    final field = find.byKey(const ValueKey('bills-search'));
    await _scrollTo(tester, field);
    await tester.enterText(field, '102');
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('bills-search-clear')), findsOneWidget);
    expect(api.lastSearched('/bills/closed'), isFalse, reason: 'a keystroke is not a request');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(api.lastSearched('/bills/closed'), isTrue);
  }, variant: searchPlatforms);

  testWidgets('the Guests box looks like the Gaia search, and its x is a real button in both designs', (tester) async {
    for (final ds in DesignSystem.values) {
      await _mountModule(tester, ds, m.customersModule, {'/customers/segments': _guests});
      final field = find.byKey(const ValueKey('guests-search'));
      expect(find.text('Find a guest by name, phone or email…'), findsOneWidget);
      await tester.enterText(field, 'asha');
      await tester.pump();
      final x = find.byKey(const ValueKey('guests-search-clear'));
      expect(find.descendant(of: field, matching: x), findsOneWidget, reason: 'the x sits in the field, not beside it');
      expect(tester.getSize(x).width, greaterThanOrEqualTo(40));
      expect(tester.getSize(x).height, greaterThanOrEqualTo(40));
      expect(tester.takeException(), isNull);
    }
  }, variant: searchPlatforms);

  // ------------------------------------------------------------ the guards --

  test('no search-shaped text field exists outside the shared AppSearchField', () {
    // Read with test/text_field_scan.dart: every file under lib/, comments left
    // out. A box that searches says so in its hint or label, or carries the
    // search glyph; any such TextField, or any InputDecoration built for one,
    // is a hand-rolled search box — the thing that let each screen get its x
    // wrong in its own way.
    final searchWords = RegExp(r'search|find|filter', caseSensitive: false);
    final offenders = <String>[];
    var fields = 0;
    for (final s in libSources) {
      if (s.path == 'lib/ui/widgets/app_search_field.dart') continue;
      for (final call in s.calls(const {'TextField', 'TextFormField', 'InputDecoration'})) {
        if (call.name != 'InputDecoration') fields++;
        final text = call.argText;
        final words = [
          for (final m in RegExp(r'''(hintText|labelText)\s*:\s*(?:const\s+)?['"]([^'"]*)['"]''').allMatches(text)) m.group(2)!,
        ];
        if (text.contains('Icons.search') || words.any(searchWords.hasMatch)) {
          offenders.add('${call.where}: ${call.name} ${words.isEmpty ? '(search glyph)' : words.join(' / ')}');
        }
      }
      for (final call in s.calls(const {'SearchBar', 'SearchAnchor', 'CupertinoSearchTextField', 'GaiaSearchField'})) {
        offenders.add('${call.where}: ${call.name}');
      }
    }
    expect(fields, greaterThan(100), reason: 'the scan must actually be reading the app');
    expect(offenders, isEmpty, reason: 'use AppSearchField (lib/ui/widgets/app_search_field.dart)');
  });

  test('every AppSearchField has a contract row, and every row a box', () {
    final lib = _libSearchFields();
    // Pinned, so a new search box is a deliberate addition to this list AND to
    // the rows. (guests-search is written once and placed twice: the Rustic
    // column and the Gaia list both build `_guestSearch()`.)
    expect(lib.keys.toSet(), {
      'order-search',
      'menu-search',
      'audit-search',
      'guests-search',
      'bills-search',
      'tz-search',
      'tag-dishes-search',
      'reports-search',
      'sim-pick-search',
    }, reason: '$lib');
    expect(lib.values.every((sites) => sites.length == 1), isTrue, reason: 'one call site per testId: $lib');
    final rows = _rowIds();
    expect(lib.keys.toSet().difference(rows), isEmpty, reason: 'an AppSearchField with no contract row');
    expect(rows.difference(lib.keys.toSet()), isEmpty, reason: 'a contract row for a box that no longer exists');
  });

  test('the shared field is the only place an x is wired to a search', () {
    // Comments blanked, so the widget's own explanation cannot satisfy a check.
    final src = libSources.singleWhere((s) => s.path == 'lib/ui/widgets/app_search_field.dart').code;
    // The listener is the only route from text to query …
    expect(RegExp(r'_c\.addListener\(_onText\)').allMatches(src).length, 2);
    expect(src, isNot(contains('onChanged')));
    // … the x clears the controller and keeps the focus …
    expect(src, matches(RegExp(r'void _clear\(\) \{\s*_c\.clear\(\);\s*_focus\.requestFocus\(\);')));
    expect(src, matches(RegExp(r'suffixIcon: _c\.text\.isEmpty\s*\?\s*null\s*:\s*IconButton\(')));
    expect(src, contains('onPressed: _clear'));
    // … and props never re-seed the text.
    expect(src, isNot(matches(RegExp(r'_c\.text\s*=[^=]'))));
    // Every screen reaches the query through onQuery, never by reading a box.
    for (final s in libSources) {
      if (s.path == 'lib/ui/widgets/app_search_field.dart') continue;
      for (final call in s.calls(const {'AppSearchField'})) {
        expect(call.args.containsKey('onQuery'), isTrue, reason: call.where);
      }
    }
  });

  // ------------------------------------------------- the contract has teeth

  final expected = <PlantedBug, String>{
    PlantedBug.filterOnlyX: 'C3',
    PlantedBug.staleDebounce: 'C8',
    PlantedBug.decorativeX: 'C2',
    PlantedBug.reseedOnRebuild: 'C9',
    PlantedBug.xBesideTheField: 'C2',
    PlantedBug.lateX: 'C1',
    PlantedBug.noX: 'C1',
  };
  for (final bug in PlantedBug.values) {
    testWidgets('the contract catches a planted box: ${bug.name} (${expected[bug]})', (tester) async {
      useSearchView(tester);
      await tester.pumpWidget(searchThemed(DesignSystem.rustic, Scaffold(body: PlantedSearch(bug: bug))));
      await tester.pumpAndSettle();
      String applied() => tester.widget<Text>(find.byKey(const ValueKey('planted-applied'))).data!;
      final broken = await checkSearchContract(
        tester,
        SearchSurface(
          field: find.byKey(const ValueKey('planted')),
          typed: 'dal',
          filtered: () => applied() != 'applied=',
          rebuild: () async {
            await tester.tap(find.byKey(const ValueKey('planted-rebuild')));
            await tester.pumpAndSettle();
          },
        ),
      );
      debugPrint('planted ${bug.name} [${defaultTargetPlatform.name}]: $broken');
      expect(broken.where((b) => b.startsWith('${expected[bug]!} ')), isNotEmpty, reason: '$broken');
      expect(broken.where((b) => b.startsWith('(precondition)')), isEmpty, reason: '$broken');
    }, variant: searchPlatforms);
  }
}
