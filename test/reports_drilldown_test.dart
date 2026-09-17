import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/async_view.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// REPORTS — WHICH ROWS OPEN SOMETHING, AND WHETHER THE SCREEN SAYS SO.
///
/// The reported complaint was that the reports "are not clickable". The wiring
/// was never broken: of the fifteen, nine have rows that open something and six
/// do not, because six of them are AGGREGATES. "Paneer Tikka, 47 sold" is 47
/// lines off an unknown number of bills — there is no single bill behind it, and
/// inventing one would be worse than opening nothing. What was missing was any
/// way to tell a correctly-inert row from a broken control.
///
/// So these tests pin BOTH halves of the promise, on the grid and on the card:
///   * a row the screen says can be opened actually opens, and
///   * a row that cannot never advertises a tap it will not honour — no
///     chevron, no pointer cursor — and the report says in words why.
///
/// The row shapes are the server's own (database_supabase.ts): only Discount,
/// Void KOT, Bill Edit, Order Summary, NC Summary, Service Charge Deny and Tip
/// Summary carry `bill_id`/`order_id`; Sales Summary narrows to a day and
/// Executive Summary switches branch; the other six carry no identifier at all.

Map<String, dynamic> _report(
  String key,
  String title,
  List<Map<String, dynamic>> columns,
  String rowsKey,
  List<Map<String, dynamic>> rows,
) => {
      'meta': {
        'report': key,
        'title': title,
        'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'clamped': false},
        'timezone': 'Asia/Kolkata',
        'outlet_scope': 'outlet',
        'outlet_name': 'Kalyani Nagar',
        'notes': <String>[],
      },
      'columns': columns,
      rowsKey: rows,
      'totals': <String, dynamic>{},
      'page': {'limit': 100, 'offset': 0, 'total': rows.length, 'has_more': false},
    };

List<Map<String, dynamic>> _cols(List<String> keys) =>
    [for (final k in keys) {'key': k, 'label': k, 'type': 'text'}];

final _routes = <String, dynamic>{
  '/outlets': {
    'outlets': [
      {'id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'is_active': true},
      {'id': 'out-2', 'outlet_name': 'Baner', 'is_active': true},
    ],
  },
  '/reports/mis/item-wise': _report('item_wise', 'Item Wise', _cols(['name', 'category', 'qty']), 'rows', [
    {'name': 'Paneer Tikka', 'category': 'Starters', 'qty': 47},
  ]),
  '/reports/mis/discount': _report('discount', 'Discount', _cols(['bill_no', 'table_name']), 'rows', [
    {'bill_no': '101', 'table_name': 'T1', 'bill_id': 'bill-1'},
  ]),
  '/reports/mis/void-kot': _report('void_kot', 'Void KOT', _cols(['order_id', 'table_name']), 'rows', [
    {'order_id': 'order-9', 'table_name': 'T1'},
  ]),
  // The MIXED report, and the reason the description is derived per ROW: Bill
  // Edit carries whichever identifier the audit writer happened to record, and
  // a re-open often records neither.
  '/reports/mis/bill-edit': _report('bill_edit', 'Bill Edit', _cols(['action', 'table_name']), 'rows', [
    {'action': 'Item deleted', 'table_name': 'T1', 'bill_id': 'bill-1'},
    {'action': 'Bill re-opened', 'table_name': 'T4'},
  ]),
  '/reports/mis/sales-summary':
      _report('sales_summary', 'Sales Summary', _cols(['bucket', 'bills']), 'series', [
    {'bucket': '2026-08-01', 'bills': 2},
  ]),
  '/reports/mis/order-summary':
      _report('order_summary', 'Order Summary', _cols(['bill_no', 'table_name']), 'rows', [
    {'bill_no': '101', 'table_name': 'T1', 'bill_id': 'bill-1'},
  ]),
  '/reports/mis/executive-summary':
      _report('executive_summary', 'Executive Summary', _cols(['outlet_name', 'bills']), 'by_outlet', [
    {'outlet_name': 'Baner', 'bills': 5, 'outlet_id': 'out-2'},
  ]),
  '/reports/mis/cover-size-summary':
      _report('cover_size_summary', 'Cover Size Summary', _cols(['party_size', 'parties']), 'rows', [
    {'party_size': 'Two', 'parties': 9},
  ]),
  '/reports/mis/settlement-summary':
      _report('settlement_summary', 'Settlement Summary', _cols(['method', 'bills']), 'rows', [
    {'method': 'Cash', 'bills': 4},
  ]),
  // A comp on a billed order and a comp on one that has not been billed yet:
  // one opens a bill, the other a ticket. Both open something.
  '/reports/mis/nc-summary': _report('nc_summary', 'NC Summary', _cols(['bill_no', 'item_name']), 'rows', [
    {'bill_no': '101', 'item_name': 'Dal', 'bill_id': 'bill-1', 'order_id': 'order-9'},
    {'bill_no': 'Unbilled', 'item_name': 'Raita', 'order_id': 'order-9'},
  ]),
  '/reports/mis/service-charge-deny':
      _report('service_charge_deny', 'Service Charge Deny', _cols(['bill_no', 'basis']), 'rows', [
    {'bill_no': '101', 'basis': 'Restaurant %', 'bill_id': 'bill-1'},
  ]),
  '/reports/mis/group-summary': _report('group_summary', 'Group Summary', _cols(['group_name', 'items']), 'rows', [
    {'group_name': 'Breads', 'items': 6},
  ]),
  '/reports/mis/variation-summary':
      _report('variation_summary', 'Variation Summary', _cols(['item_name', 'variation_name']), 'rows', [
    {'item_name': 'Biryani', 'variation_name': 'Half'},
  ]),
  '/reports/mis/tip-summary': _report('tip_summary', 'Tip Summary', _cols(['bill_no', 'method']), 'rows', [
    {'bill_no': '101', 'method': 'Card', 'bill_id': 'bill-1'},
  ]),
  '/reports/mis/counter-summary':
      _report('counter_summary', 'Counter Summary', _cols(['counter_code', 'counter_name']), 'rows', [
    {'counter_code': 'C1', 'counter_name': 'Front'},
  ]),
  '/reports/mis/bill/bill-1': {
    'id': 'bill-1', 'bill_no': '101', 'grand_total': 1200.0, 'items': <dynamic>[], 'taxes': <dynamic>[],
  },
  '/reports/mis/kot/order-9': {
    'id': 'order-9', 'status': 'Cancelled', 'table_name': 'T1', 'items': <dynamic>[], 'trail': <dynamic>[],
  },
};

class _Api extends ApiClient {
  final List<String> calls = <String>[];

  /// While true every request throws like a dead network.
  bool offline = false;

  @override
  Future<LoginResult> login(String r, String u, String p, {String? outletId}) async => LoginResult(
        't',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1', 'restaurantName': 'CSR', 'res_id': 'res-1', 'outlet_id': 'out-1',
          'role': 'admin', 'actions_set': ['*'], 'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add(path);
    if (offline) throw ApiException('Connection refused', null);
    final base = Uri.parse('http://x$path').path;
    final hit = _routes[base];
    if (hit == null) throw ApiException('No fake route for $base', 404);
    return hit;
  }

  List<String> get drills =>
      calls.where((c) => c.startsWith('/reports/mis/bill/') || c.startsWith('/reports/mis/kot/')).toList();
}

Future<_Api> _mount(
  WidgetTester tester, {
  double width = 1500,
  double height = 1100,
  void Function(String)? switchOutlet,
  bool canSwitchOutlet = true,
  _Api? api,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fake = api ?? _Api();
  final auth = AuthController(api: fake);
  await auth.login('CSR', 'a', 'b');
  final rest = RestClient(auth);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: const ['Reports'],
      clearFocus: () {},
      switchOutlet: canSwitchOutlet ? (switchOutlet ?? (_) {}) : null,
      child: Scaffold(body: m.reportsModule(rest, auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _openTab(WidgetTester tester, String title) async {
  final tab = find.text(title).first;
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// Brings [f] into the tree and onto the screen.
///
/// The phone layout is one long lazy ListView — tiles, then the action bar,
/// then a card per row — so anything below the first screenful genuinely is not
/// built yet. A reader scrolls to it; so does this.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 220, maxScrolls: 60,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
  }
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
}

/// Taps a row by one of its cell values, scrolling it into view first.
Future<void> _tapRow(WidgetTester tester, String cell) async {
  await _reveal(tester, find.text(cell));
  await tester.tap(find.text(cell).first);
  await tester.pumpAndSettle();
}

Future<String> _drillChip(WidgetTester tester) async {
  final chip = find.byKey(const ValueKey('reports-drill'));
  await _reveal(tester, chip);
  if (chip.evaluate().isEmpty) return '<no chip>';
  return tester.widget<Text>(find.descendant(of: chip, matching: find.byType(Text))).data ?? '';
}

int _chevrons(WidgetTester tester, {required bool compact}) => find
    .descendant(
      of: find.byKey(ValueKey(compact ? 'reports-cards' : 'reports-grid')),
      matching: find.byIcon(Icons.chevron_right),
    )
    .evaluate()
    .length;

/// One report: its tab, a cell to tap, what the chip must say, and what the tap
/// must produce. `drill` null means the tap must do NOTHING.
class _Case {
  const _Case(this.tab, this.cell, this.chip, {this.drill, this.rows = 1, this.chevrons = 1});
  final String tab;
  final String cell;
  final String chip;
  final String? drill;
  final int rows;
  final int chevrons;
}

const _cases = <_Case>[
  _Case('Item Wise', 'Paneer Tikka', 'Each row totals many bills — no single one to open', chevrons: 0),
  _Case('Discount', '101', 'Tap a row to open its full bill', drill: '/reports/mis/bill/bill-1'),
  _Case('Void KOT', 'order-9', 'Tap a row to open its kitchen ticket', drill: '/reports/mis/kot/order-9'),
  _Case('Bill Edit', 'Item deleted', 'Some rows open its full bill · 1 of 2 rows name none',
      drill: '/reports/mis/bill/bill-1', rows: 2, chevrons: 1),
  _Case('Sales Summary', '2026-08-01', 'Tap a row to open that day on its own'),
  _Case('Order Summary', '101', 'Tap a row to open its full bill', drill: '/reports/mis/bill/bill-1'),
  _Case('Executive Summary', 'Baner', 'Tap a row to open that branch'),
  _Case('Cover Size Summary', 'Two', 'Each row totals many bills — no single one to open', chevrons: 0),
  _Case('Settlement Summary', 'Cash', 'Each row totals many bills — no single one to open', chevrons: 0),
  _Case('NC Summary', 'Dal', 'Tap a row to open the bill or ticket it names',
      drill: '/reports/mis/bill/bill-1', rows: 2, chevrons: 2),
  _Case('Service Charge Deny', '101', 'Tap a row to open its full bill', drill: '/reports/mis/bill/bill-1'),
  _Case('Group Summary', 'Breads', 'Each row totals many bills — no single one to open', chevrons: 0),
  _Case('Variation Summary', 'Biryani', 'Each row totals many bills — no single one to open', chevrons: 0),
  _Case('Tip Summary', '101', 'Tap a row to open its full bill', drill: '/reports/mis/bill/bill-1'),
  _Case('Counter Summary', 'C1', 'Each row totals many bills — no single one to open', chevrons: 0),
];

void main() {
  setUp(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final compact in [false, true]) {
    final where = compact ? 'card' : 'grid';
    group('$where — every report says whether its rows open anything', () {
      for (final c in _cases) {
        testWidgets('${c.tab}: "${c.chip}"', (tester) async {
          final switched = <String>[];
          final api = await _mount(tester,
              width: compact ? 420 : 1500,
              // Tall on purpose: the phone body is ONE lazy ListView, so a card
              // below the fold is not in the tree at all — and this test counts
              // the chevrons of the whole report, not of a screenful. Scrolling
              // a phone is pinned in reports_module_test.
              height: compact ? 1600 : 1100,
              switchOutlet: switched.add);
          await _openTab(tester, c.tab);

          // 1. THE WORDS. Present on every report that has rows, and the same
          //    sentence on the phone as on the desktop — the reader's question
          //    ("is this broken?") does not change with the window.
          expect(await _drillChip(tester), c.chip, reason: '${c.tab} described its rows wrongly');

          // 2. THE PER-ROW AFFORDANCE. Exactly as many chevrons as there are
          //    rows that open something — so a dead row cannot look live and a
          //    live one cannot look dead.
          expect(_chevrons(tester, compact: compact), c.chevrons,
              reason: '${c.tab} drew the wrong number of drill-down chevrons');

          // 3. THE TAP ITSELF.
          final before = api.calls.length;
          await _tapRow(tester, c.cell);
          final after = api.calls.sublist(before);
          if (c.drill != null) {
            expect(after, contains(c.drill), reason: '${c.tab} advertised a tap it did not honour');
          } else {
            expect(api.drills, isEmpty, reason: '${c.tab} opened a drill-down it never advertised');
          }
        });
      }
    });
  }

  // ------------------------------------------------- the two non-drill taps --

  testWidgets('a Sales Summary day row narrows the window to that day, as it says',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    expect(await _drillChip(tester), 'Tap a row to open that day on its own');
    await _tapRow(tester, '2026-08-01');
    final call = api.calls.lastWhere((c) => c.contains('/reports/mis/sales-summary'));
    expect(call, contains('from=2026-08-01'));
    expect(call, contains('to=2026-08-01'));
  });

  testWidgets('an Executive Summary row switches branch, as it says', (tester) async {
    final switched = <String>[];
    await _mount(tester, switchOutlet: switched.add);
    await _openTab(tester, 'Executive Summary');
    expect(await _drillChip(tester), 'Tap a row to open that branch');
    await _tapRow(tester, 'Baner');
    expect(switched, ['out-2']);
  });

  // ------------------------------------------- the promise is never inflated --

  testWidgets('a reader who cannot switch branches is not promised that they can',
      (tester) async {
    // The Executive Summary's tap is a branch switch, so a session with no
    // switcher has nothing behind those rows. Saying "tap a row to open that
    // branch" there would be the exact failure this chip exists to end.
    await _mount(tester, canSwitchOutlet: false);
    await _openTab(tester, 'Executive Summary');
    expect(await _drillChip(tester), 'Each row totals many bills — no single one to open');
    expect(_chevrons(tester, compact: false), 0);
  });

  testWidgets('an hour-bucketed Sales Summary stops promising the day narrowing',
      (tester) async {
    // The window is a pair of calendar DAYS, so an hour row has nothing to
    // narrow to — and the moment the toggle moves, the words move with it.
    await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    expect(await _drillChip(tester), 'Tap a row to open that day on its own');

    await tester.tap(find.text('Hour-wise'));
    await tester.pumpAndSettle();
    expect(await _drillChip(tester), 'Each row totals many bills — no single one to open');
    expect(_chevrons(tester, compact: false), 0);
  });

  testWidgets('the bare half of a mixed report eats no tap', (tester) async {
    // Bill Edit's re-open row names neither a bill nor an order. It must not
    // open anything, and it must not have looked as though it would.
    final api = await _mount(tester);
    await _openTab(tester, 'Bill Edit');
    expect(await _drillChip(tester), 'Some rows open its full bill · 1 of 2 rows name none');
    await _tapRow(tester, 'Bill re-opened');
    expect(api.drills, isEmpty);

    // …while its neighbour, which does name one, opens it.
    await _tapRow(tester, 'Item deleted');
    expect(api.drills, ['/reports/mis/bill/bill-1']);
  });

  testWidgets('an empty report claims nothing about tapping', (tester) async {
    final api = _Api();
    // A window with no rows: the empty state speaks for itself, and a chip
    // describing taps on rows that do not exist would be noise.
    _routes['/reports/mis/counter-summary'] =
        _report('counter_summary', 'Counter Summary', _cols(['counter_code']), 'rows', const []);
    addTearDown(() {
      _routes['/reports/mis/counter-summary'] =
          _report('counter_summary', 'Counter Summary', _cols(['counter_code', 'counter_name']), 'rows', [
        {'counter_code': 'C1', 'counter_name': 'Front'},
      ]);
    });
    await _mount(tester, api: api);
    await _openTab(tester, 'Counter Summary');
    expect(find.byKey(const ValueKey('reports-drill')), findsNothing);
    expect(find.text('Nothing in this period'), findsOneWidget);
  });

  // ------------------------------------------------------------- offline ----

  testWidgets('a report opened with the line down says what the reader can DO',
      (tester) async {
    // The reports pane routes its own failure through [LoadErrorState] now, so
    // an outage here reads exactly like an outage anywhere else in the app —
    // and names the two things in the reader's hands rather than the app's.
    final api = _Api()..offline = true;
    await _mount(tester, api: api);
    await tester.pumpAndSettle();
    expect(find.text(offlineNothingSavedTitle), findsOneWidget);
    expect(find.textContaining('Wi-Fi'), findsOneWidget);
    expect(find.textContaining('hotspot'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Load more with the line down keeps the page and says what to do',
      (tester) async {
    // Load more and the export sweep are the two things on this screen that go
    // back to the network AFTER the report is up. Both keep what is on screen
    // and report through the same helper, so a cashier is told about their
    // Wi-Fi rather than shown a transport exception.
    final api = _Api();
    final paged = _report('order_summary', 'Order Summary', _cols(['bill_no', 'table_name']), 'rows', [
      {'bill_no': '101', 'table_name': 'T1', 'bill_id': 'bill-1'},
    ]);
    (paged['page'] as Map)
      ..['has_more'] = true
      ..['total'] = 200;
    final saved = _routes['/reports/mis/order-summary'];
    _routes['/reports/mis/order-summary'] = paged;
    addTearDown(() => _routes['/reports/mis/order-summary'] = saved);

    await _mount(tester, api: api);
    await _openTab(tester, 'Order Summary');
    api.offline = true;
    await tester.tap(find.byKey(const ValueKey('reports-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('101'), findsWidgets, reason: 'a failed Load more threw away the page');
    expect(find.textContaining("can't reach the restaurant server"), findsOneWidget);
    expect(find.textContaining('ApiException'), findsNothing,
        reason: 'the transport exception must not reach the cashier');
  });

  testWidgets('the drill note survives a 360dp phone at the largest text scale',
      (tester) async {
    // The chip carries the longest sentence on this screen, and the mixed-report
    // form is the longest of those. The design system ellipsises rather than
    // overflowing (ChipLabel is a Flexible with maxLines: 1) — this measures
    // that instead of assuming it, and pins that the load-bearing words come
    // FIRST, so what survives a cut is "Some rows open…" and not the count.
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _mount(tester, width: 360, height: 1600);
    await _openTab(tester, 'Bill Edit');
    expect(await _drillChip(tester), 'Some rows open its full bill · 1 of 2 rows name none');
    expect(tester.takeException(), isNull, reason: 'the drill note overflowed a 360dp phone');
  });

  testWidgets('the kitchen ticket marks a comped line "(NC)", as the bill and the web drill-down do',
      (tester) async {
    const path = '/reports/mis/kot/order-9';
    final original = _routes[path];
    _routes[path] = {
      'id': 'order-9', 'status': 'Served', 'table_name': 'T1', 'value': 590.0, 'trail': <dynamic>[],
      'items': [
        {'name': 'Paneer Tikka', 'quantity': 1, 'price': 350.0, 'line_total': 350.0},
        {'name': 'Gulab Jamun', 'quantity': 2, 'price': 120.0, 'line_total': 240.0, 'nc': true},
      ],
    };
    addTearDown(() => _routes[path] = original);
    await _mount(tester);
    await _openTab(tester, 'Void KOT');
    await _tapRow(tester, 'order-9');
    expect(find.text('Gulab Jamun (NC)'), findsOneWidget);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.text('Paneer Tikka (NC)'), findsNothing);
  });

  testWidgets('a report that the SERVER refused shows the server own words',
      (tester) async {
    // A 404 is an answer. Dressing it as an outage would send someone to check
    // a router that is working perfectly.
    final api = _Api();
    _routes.remove('/reports/mis/item-wise');
    addTearDown(() {
      _routes['/reports/mis/item-wise'] =
          _report('item_wise', 'Item Wise', _cols(['name', 'category', 'qty']), 'rows', [
        {'name': 'Paneer Tikka', 'category': 'Starters', 'qty': 47},
      ]);
    });
    await _mount(tester, api: api);
    await tester.pumpAndSettle();
    expect(find.text(offlineNothingSavedTitle), findsNothing);
    expect(find.text('Could not load Item Wise.'), findsOneWidget);
  });
}
