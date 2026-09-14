import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Overview dashboard: the empty-restaurant case, the "a card that leads
/// nowhere must not be tappable" rule, and which charts answer the pointer.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

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
    calls.add('$method $path');
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

/// Every label the shell can show — the "this owner sees everything" case.
const _allVisible = [
  'Overview', 'Orders', 'Kitchen', 'Menu', 'Tables', 'Waitlist', 'Inventory',
  'Purchase Orders', 'Bookings', 'Customers', 'Feedback', 'Analytics', 'History',
  'Employees', 'Settings',
];

Widget _host(
  Widget child, {
  List<String> visible = _allVisible,
  OpenModuleCallback? openModule,
}) =>
    MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: openModule ?? (_, {Map<String, dynamic>? target}) {},
        visibleLabels: visible,
        clearFocus: () {},
        child: child,
      ),
    );

/// The Overview is a lazy ListView, so anything below the fold is simply not
/// built. A desktop-sized window is what the dense grid is designed for anyway.
void _wideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The ForkCard a metric tile is built from, located by its own label.
ForkCard _tileFor(WidgetTester tester, String label) => tester.widget<ForkCard>(
      find.ancestor(of: find.text(label), matching: find.byType(ForkCard)).first,
    );

// Live shape of GET /analytics/overview, trimmed to one row per section.
const _insights = <String, dynamic>{
  'window_days': 30,
  'headline': {
    'revenue': {'value': 184320.5, 'previous': 150000, 'pct_change': 22.88, 'direction': 'up', 'compared_to': 'previous 30 days'},
    'bills': {'value': 412, 'previous': 380, 'pct_change': 8.42, 'direction': 'up', 'compared_to': 'previous 30 days'},
    'covers': {'value': 1180, 'previous': 1180, 'pct_change': 0, 'direction': 'flat', 'compared_to': 'previous 30 days'},
    'apc': {'value': 156.2, 'previous': null, 'pct_change': null, 'direction': 'flat', 'compared_to': 'previous 30 days'},
    'today_revenue': 8420,
    'yesterday_revenue': 11250,
  },
  'top_dishes_by_revenue': [
    {'name': 'Paneer Tikka', 'category': 'Starters', 'quantity': 214, 'revenue': 42800, 'share_pct': 23.2},
    {'name': 'Dal Makhani', 'category': 'Mains', 'quantity': 180, 'revenue': 27000, 'share_pct': 14.6},
  ],
  'top_staff': [
    {'employee_id': 'e9', 'employee_name': 'Asha', 'orders': 91, 'revenue': 61200, 'avg_rating': 4.6, 'hours_worked': 148.5, 'ranked_by': 'revenue'},
  ],
  'kitchen': {
    'avg_prep_ms': 742000, 'p90_prep_ms': 1380000, 'slowest_section': 'Tandoor',
    'slowest_section_avg_ms': 1100000, 'slowest_dish': 'Biryani', 'slowest_dish_avg_ms': 1620000,
    'orders_timed': 388,
  },
  'peak': {
    'hour': 20, 'hour_orders': 96, 'hour_revenue': 41200,
    'weekday': 'Saturday', 'weekday_orders': 140, 'weekday_revenue': 63400,
  },
  'needs_attention': <dynamic>[],
};

/// The Overview picks its column count off the WINDOW width, but it is laid out
/// inside the shell's body — the fixed sidebar is 224px of that window it never
/// gets. This host reproduces that geometry without touching the shell: at a
/// 1100px window the grid goes to four across while each card is really
/// (1100 - 224 - 32 - 42) / 4 ≈ 200px wide.
Widget _shellGeometry(Widget child, {List<String> visible = _allVisible}) => _host(
      Row(children: [
        const SizedBox(width: 224),
        Expanded(child: child),
      ]),
      visible: visible,
    );

void _window(WidgetTester tester, double width, [double height = 3000]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Live shape of GET /analytics/headline, with today's takings by payment
/// method. The rows are the server's Settlement Summary cut over today, so they
/// add up to today_gross (22680.90) and the Cash row is cash_collection.
Map<String, dynamic> _headline({Map<String, dynamic> over = const {}}) => {
      'today': '2026-09-14',
      'month_from': '2026-09-01',
      'timezone': 'Asia/Kolkata',
      'today_net': {'value': 20000, 'label': "Today's net sale", 'hint': 'Settled today, after discounts.'},
      'today_gross': {'value': 22680.9, 'label': "Today's gross sale", 'hint': 'Settled today, tax inclusive.'},
      'online_net': {'value': 0, 'label': 'Online sale (net)', 'hint': 'Delivery and aggregators.'},
      'online_gross': {'value': 0, 'label': 'Online sale (gross)', 'hint': 'Delivery and aggregators.'},
      'cash_collection': {'value': 8430.5, 'label': 'Cash collection', 'hint': 'Cash taken today.'},
      'month_to_date': {'value': 412000, 'label': 'Month to date', 'hint': 'Gross sales this month.'},
      'today_bills': 14,
      'month_bills': 301,
      'today_by_method': [
        {'method': 'Upi', 'bills': 6, 'amount': 11000, 'share_pct': 48.5, 'refund': 0, 'net_amount': 11000},
        {'method': 'Cash', 'bills': 6, 'amount': 8430.5, 'share_pct': 37.17, 'refund': 120, 'net_amount': 8310.5},
        {'method': 'Card', 'bills': 3, 'amount': 3250.4, 'share_pct': 14.33, 'refund': 0, 'net_amount': 3250.4},
      ],
      'today_split_bills': 1,
      'today_unallocated': 0,
      'by_method': {
        'label': 'Collected by payment method',
        'hint': "Settled today, by how it was paid; adds up to Today's gross sale.",
      },
      ...over,
    };

/// 14 days of revenue — the minimum the week-on-week delta needs — collapsing to
/// nothing in the last 7, which is the widest the delta line ever prints.
Map<String, dynamic> _dailySeries() => {
      'series': [
        for (var i = 0; i < 14; i++)
          {'date': '2026-07-${(i + 1).toString().padLeft(2, '0')}', 'revenue': i < 7 ? 9000 : 0, 'orders': 10},
      ],
    };

void main() {
  // A brand-new restaurant answers every read with nothing (here: 404 on every
  // route, which is what the module's own catch handlers see). It must render,
  // and it must never print the raw shape of missing data at the owner.
  testWidgets('Overview renders on a completely empty payload', (tester) async {
    final api = _FakeApi(const <String, dynamic>{});
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Welcome'), findsOneWidget);

    // RichText catches Text as well as the StatCard's spans, so this covers
    // every glyph actually on screen.
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      final shown = rt.text.toPlainText(includeSemanticsLabels: false, includePlaceholders: false);
      expect(shown.contains('NaN'), isFalse, reason: 'NaN leaked into "$shown"');
      expect(shown.toLowerCase().contains('null'), isFalse, reason: 'null leaked into "$shown"');
      expect(shown.contains('Infinity'), isFalse, reason: 'Infinity leaked into "$shown"');
    }

    // Nothing to summarise from the other tabs, so no hollow Operations block.
    expect(find.text('Operations'), findsNothing);
  });

  // An unreachable destination must produce an INERT card, not a dead control:
  // no chevron, no hover lift, nothing to click in a dense grid of tiles.
  testWidgets('a metric card with no reachable destination is not tappable', (tester) async {
    final api = _FakeApi(const {'/analytics/overview?days=30': _insights});
    final rest = await _signIn(api);
    _wideWindow(tester);

    // This user has no Analytics module at all.
    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      visible: const ['Overview'],
    ));
    await tester.pumpAndSettle();

    expect(_tileFor(tester, 'REVENUE (INCL. TAX)').onTap, isNull);
    expect(_tileFor(tester, 'BUSIEST HOUR').onTap, isNull);
    // The chevron is the promise of a tap, so it must be absent too.
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('REVENUE (INCL. TAX)'), matching: find.byType(ForkCard)).first,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
    // The top-selling bars lead to Menu, which is gated here as well.
    expect(tester.widget<HBarRow>(find.byType(HBarRow).first).onTap, isNull);
  });

  testWidgets('the same card opens its module when that module is reachable', (tester) async {
    final api = _FakeApi(const {'/analytics/overview?days=30': _insights});
    final rest = await _signIn(api);
    final opened = <String>[];
    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:$target'),
    ));
    await tester.pumpAndSettle();

    expect(_tileFor(tester, 'REVENUE (INCL. TAX)').onTap, isNotNull);
    await tester.tap(find.text('REVENUE (INCL. TAX)'));
    await tester.pump();
    // No focus payload: a whole-module summary has no record to focus, and an
    // unread key would make the destination claim the record is missing.
    expect(opened, ['Analytics:null']);
  });

  testWidgets('a top-selling bar is hoverable and drills into the menu', (tester) async {
    final api = _FakeApi(const {'/analytics/overview?days=30': _insights});
    final rest = await _signIn(api);
    final opened = <String>[];
    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:$target'),
    ));
    await tester.pumpAndSettle();

    final bar = tester.widget<HBarRow>(
      find.ancestor(of: find.text('Paneer Tikka'), matching: find.byType(HBarRow)).first,
    );
    expect(bar.onTap, isNotNull);
    expect(bar.tooltip, contains('Paneer Tikka'));
    expect(bar.tooltip, contains('214 sold'));

    await tester.tap(find.text('Paneer Tikka'));
    await tester.pump();
    expect(opened, ['Menu:null']);
  });

  // The revenue drill-down is where the charts DO lead somewhere: nothing else
  // in that sheet is competing for the tap, so both the strip and the weekday
  // bars name their day on hover and open it on tap.
  testWidgets('the revenue drill-down charts name their day and open it', (tester) async {
    final api = _FakeApi(const {
      '/orders/daily-revenue?days=14': {
        'series': [
          {'date': '2026-07-30', 'revenue': 4200, 'orders': 12},
          {'date': '2026-07-31', 'revenue': 5100, 'orders': 15},
        ],
      },
    });
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revenue this month — all channels'));
    await tester.pumpAndSettle();

    final bars = tester.widget<WeekdayBars>(find.byType(WeekdayBars));
    expect(bars.onTap, isNotNull);
    expect(bars.tooltipBuilder, isNotNull);
    // 2026-07-31 is a Friday, and the weekday must be spelled out — "T" on the
    // axis is either Tuesday or Thursday.
    expect(bars.tooltipBuilder!(1), contains('Fri, Jul 31'));
    expect(bars.tooltipBuilder!(1), contains('₹5100.00'));
    expect(bars.tooltipBuilder!(1), contains('15 order(s)'));

    // The strip inside the sheet is live too, indexed into the source series.
    final strip = tester.widget<CopperBarcode>(find.byType(CopperBarcode).last);
    expect(strip.onTap, isNotNull);
    expect(strip.tooltipBuilder!(0), contains('Thu, Jul 30'));

    // Tapping the last bar opens that day, not the whole window.
    bars.onTap!(1);
    await tester.pumpAndSettle();
    expect(find.text('Fri, Jul 31'), findsOneWidget);
    expect(find.text('REVENUE · ONE DAY'), findsOneWidget);
    // ₹5100 over 15 orders, and the only day in the window with any takings.
    expect(find.text('₹340.00'), findsOneWidget);
  });

  // The stat card is ALREADY a control. A per-bar tap on the chart inside it
  // would be the deeper hit target and would swallow the card's own tap, so the
  // inline strip reads on hover and every pixel of the card opens the same
  // drill-down. This is the trap the wiring must not create.
  testWidgets('the inline revenue strip reads but never steals the card tap', (tester) async {
    final api = _FakeApi({'/orders/daily-revenue?days=14': _dailySeries()});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    final strip = tester.widget<CopperBarcode>(find.byType(CopperBarcode).first);
    expect(strip.tooltipBuilder, isNotNull, reason: 'a chart you cannot read is decoration');
    expect(strip.onTap, isNull, reason: 'a tap here would swallow the card it sits in');
    expect(strip.tooltipBuilder!(0), contains('₹9000.00'));

    // Tapping the chart itself opens the card's drill-down, not nothing.
    await tester.tap(find.byType(CopperBarcode).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('REVENUE'), findsOneWidget);
    expect(find.text('Last 14 days'), findsOneWidget);
  });

  // The occupancy gauge follows the same rule, and says the counts behind it.
  testWidgets('the occupancy gauge reads on the card and acts in the sheet', (tester) async {
    final api = _FakeApi(const {
      '/get-tables': [
        {'table_name': 'T1', 'occupied': true, 'covers': 4, 'table_total': 1200},
        {'table_name': 'T2', 'occupied': true, 'covers': 2, 'table_total': 800},
        {'table_name': 'T3', 'occupied': false},
        {'table_name': 'T4', 'occupied': false},
      ],
    });
    final rest = await _signIn(api);
    final opened = <String>[];
    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:$target'),
    ));
    await tester.pumpAndSettle();

    final onCard = tester.widget<DonutGauge>(find.byType(DonutGauge).first);
    expect(onCard.onTap, isNull);
    expect(onCard.tooltip, '2 of 4 tables occupied (50%) · 6 cover(s) seated');

    await tester.tap(find.text('Tables occupied right now'));
    await tester.pumpAndSettle();

    final inSheet = tester.widget<DonutGauge>(
      find.descendant(of: find.byType(Dialog), matching: find.byType(DonutGauge)),
    );
    expect(inSheet.onTap, isNotNull);
    inSheet.onTap!();
    await tester.pumpAndSettle();
    // Closed the sheet and went to the floor plan, with no focus payload: an
    // occupancy figure is not one table.
    expect(opened, ['Tables:null']);
    expect(find.byType(Dialog), findsNothing);
  });

  // The tooltip tests above call the builder directly; this one drives a real
  // pointer, because the index a bar REPORTS is derived from its position and
  // the painter's bar count. Get that mapping wrong and the hover card names one
  // day while the tap opens another.
  testWidgets('tapping the far-right bar opens the far-right day', (tester) async {
    final api = _FakeApi(const {
      '/orders/daily-revenue?days=14': {
        'series': [
          {'date': '2026-07-29', 'revenue': 1000, 'orders': 4},
          {'date': '2026-07-30', 'revenue': 4200, 'orders': 12},
          {'date': '2026-07-31', 'revenue': 5100, 'orders': 15},
        ],
      },
    });
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revenue this month — all channels'));
    await tester.pumpAndSettle();

    final strip = find.byType(CopperBarcode).last;
    final box = tester.getRect(strip);
    // Two pixels in from the right edge — the last slot the painter drew.
    await tester.tapAt(Offset(box.right - 2, box.center.dy));
    await tester.pumpAndSettle();

    expect(find.text('Fri, Jul 31'), findsOneWidget);
    expect(find.text('Wed, Jul 29'), findsNothing);
  });

  // Overflow is the recurring failure on this page and 1.3x is an ordinary
  // accessibility setting. The drill-downs are a fixed 460px card, so they are
  // the ones a narrow window and a raised scale actually squeeze.
  testWidgets('the charted cards and every drill-down survive each window and scale',
      (tester) async {
    for (final width in [390.0, 1100.0, 1200.0, 1700.0]) {
      for (final scale in [1.0, 1.3]) {
        final api = _FakeApi({
          '/orders/daily-revenue?days=14': _dailySeries(),
          '/orders/apc': const {
            'total_revenue': 98765432.1,
            'monthly_apc': 12345.67,
            'total_covers': 4821,
            'orders': [1, 2, 3],
            'month': 'August 2026',
          },
          '/feedback/summary': const {
            'averageRating': 4.35,
            'totalResponses': 1284,
            'last30DaysResponses': 96,
            'categoryAverages': {
              'food': {'label': 'Food quality and presentation', 'average': 4.6, 'count': 900},
              'service': {'label': 'Service', 'average': 3.9, 'count': 384},
            },
          },
          '/get-tables': [
            for (var i = 0; i < 9; i++)
              {'table_name': 'T$i', 'occupied': i.isEven, 'covers': 4, 'table_total': 999999.99},
          ],
        });
        final rest = await _signIn(api);
        tester.view.physicalSize = Size(width, 4000);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Overview at ${width}px / ${scale}x');

        for (final card in const [
          'Revenue this month — all channels',
          'Average per cover (APC), pre-tax',
          'Tables occupied right now',
          'Average guest rating',
        ]) {
          await tester.tap(find.text(card));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: '"$card" drill-down at ${width}px / ${scale}x');
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
        }

        // And the day sheet the revenue charts open, which nests one sheet
        // inside another.
        await tester.tap(find.text('Revenue this month — all channels'));
        await tester.pumpAndSettle();
        tester.widget<WeekdayBars>(find.byType(WeekdayBars)).onTap!(0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'day sheet at ${width}px / ${scale}x');
        await tester.tap(find.text('Close').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close').last);
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('cross-tab metrics report real figures from their own endpoints', (tester) async {
    final api = _FakeApi(const {
      '/inventory': [
        {'id': 'i1', 'name': 'Tomatoes', 'status': 'Low Stock'},
        {'id': 'i2', 'name': 'Paneer', 'status': 'In Stock'},
        {'id': 'i3', 'name': 'Saffron', 'status': 'Out of Stock'},
      ],
      '/purchase-orders': {
        'orders': [
          {'id': 'po1', 'status': 'ordered', 'total_cost': 4200},
          {'id': 'po2', 'status': 'draft', 'total_cost': 800},
          {'id': 'po3', 'status': 'received', 'total_cost': 9999},
        ],
      },
      '/get-bookings?window=upcoming': [
        {'booking_id': 'b1', 'customer_name': 'Later', 'status': 'Confirmed', 'booking_date_time': '2026-08-09T20:00:00Z', 'number_of_people': 6},
        {'booking_id': 'b2', 'customer_name': 'Sooner', 'status': 'Confirmed', 'booking_date_time': '2026-08-04T19:30:00Z', 'number_of_people': 2},
        {'booking_id': 'b3', 'customer_name': 'Gone', 'status': 'Cancelled', 'booking_date_time': '2026-08-05T19:30:00Z', 'number_of_people': 4},
      ],
      '/waitlist': {
        'entries': [
          {'id': 'w1', 'name': 'Rahul', 'position': 1, 'party_size': 2, 'status': 'waiting'},
          {'id': 'w2', 'name': 'Meera', 'position': 2, 'party_size': 4, 'status': 'waiting'},
          {'id': 'w3', 'name': 'Seated', 'position': 3, 'party_size': 2, 'status': 'seated'},
        ],
      },
      '/bills/open?limit=1': {'bills': <dynamic>[], 'total': 3, 'outstanding_total': 5240.5},
    });
    final rest = await _signIn(api);
    final opened = <String>[];

    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      openModule: (label, {Map<String, dynamic>? target}) => opened.add(label),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Operations'), findsOneWidget);
    // 3 items, one low and one out — counted off the same `status` string the
    // Inventory screen colours its rows by.
    expect(find.text('1 out of stock · 1 low'), findsOneWidget);
    // draft + ordered are open; the received PO is not, and its cost is not
    // counted as money on order.
    expect(_tileFor(tester, 'PURCHASE ORDERS OPEN').onTap, isNotNull);
    expect(find.text('₹5000.00 on order'), findsOneWidget);
    // Cancelled bookings are not upcoming, and "next" is the soonest by date.
    expect(find.textContaining('party of 2'), findsOneWidget);
    expect(find.text('next up Rahul'), findsOneWidget);
    expect(find.text('₹5240.50 uncollected'), findsOneWidget);

    await tester.tap(find.text('INVENTORY ITEMS'));
    await tester.pump();
    expect(opened, ['Inventory']);
  });

  // 1100px is the exact width where the stat grid goes to four across, and the
  // "▲ 100.0% vs prior week" line under the revenue card is a fixed-width Row
  // with nothing to give. The card is the first thing on the page, so this is
  // the overflow an owner on a 1100px window sees before anything else.
  testWidgets('the revenue delta line survives the four-across breakpoint', (tester) async {
    for (final width in [1100.0, 1120.0, 1280.0]) {
      final api = _FakeApi({'/orders/daily-revenue?days=14': _dailySeries()});
      final rest = await _signIn(api);
      _window(tester, width);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_shellGeometry(m.overviewModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'metric tile overflowed at ${width}px');
      // Degraded, not dropped: the comparison window is what makes the number
      // mean anything, so it must still be on screen.
      expect(find.textContaining('vs prior week'), findsOneWidget, reason: 'delta lost at ${width}px');
    }
  });

  // The server always sends the kitchen object, zeroed, so this used to be two
  // tiles reading "—" under a heading — indistinguishable from a failed load.
  testWidgets('a restaurant that has never timed a ticket says so once', (tester) async {
    final api = _FakeApi(const {
      '/analytics/overview?days=30': {
        'window_days': 30,
        'headline': <String, dynamic>{},
        'top_dishes_by_revenue': <dynamic>[],
        'top_staff': <dynamic>[],
        'kitchen': {
          'avg_prep_ms': 0, 'p90_prep_ms': 0, 'orders_timed': 0,
          'slowest_section': '', 'slowest_dish': '',
          'slowest_section_avg_ms': 0, 'slowest_dish_avg_ms': 0,
        },
        'peak': <String, dynamic>{},
        'needs_attention': <dynamic>[],
      },
    });
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.text('AVG PREP'), findsNothing);
    expect(find.text('SLOWEST 10%'), findsNothing);
    expect(find.textContaining('No timed orders yet'), findsOneWidget);
  });

  // The sweep above cannot speak for the headline tiles: with `headline: {}` the
  // whole block is skipped, so an assertion about them there is vacuous. Give it
  // a POPULATED headline whose figures are null — the shape a partial server
  // response really has — and assert the contract that actually holds: a tile may
  // show a dash, but never a bare one. APC/today/yesterday each pair theirs with
  // a sub-line saying why, which is what makes it read as "nothing yet" instead
  // of "failed to load".
  testWidgets('a headline figure that is missing explains itself', (tester) async {
    final api = _FakeApi(const {
      '/analytics/overview?days=30': {
        'window_days': 30,
        'headline': {
          'revenue': {'value': 1200, 'previous': 1000, 'pct_change': 20, 'direction': 'up', 'compared_to': 'prior 30 days'},
          'bills': {'value': 4, 'previous': 3, 'pct_change': 33, 'direction': 'up', 'compared_to': 'prior 30 days'},
          'covers': {'value': 9, 'previous': 8, 'pct_change': 12, 'direction': 'up', 'compared_to': 'prior 30 days'},
          'apc': {'value': null, 'previous': null, 'pct_change': null, 'direction': 'flat', 'compared_to': 'prior 30 days'},
          'today_revenue': null,
          'yesterday_revenue': null,
        },
        'top_dishes_by_revenue': <dynamic>[],
        'top_staff': <dynamic>[],
        'kitchen': <String, dynamic>{},
        'peak': <String, dynamic>{},
        'needs_attention': <dynamic>[],
      },
    });
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The headline block really did build — otherwise this test proves nothing,
    // which is exactly how the previous version of this check passed.
    expect(find.textContaining('REVENUE'), findsWidgets);

    // Every dash carries an explanation somewhere on the page.
    final dashes = tester.widgetList<Text>(find.text('—')).length;
    if (dashes > 0) {
      expect(
        find.textContaining(RegExp('nothing (recorded|settled)', caseSensitive: false)),
        findsWidgets,
        reason: 'a headline tile shows a dash with nothing saying why',
      );
    }
    // And never a raw null/NaN leaking into the UI.
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final d = t.data ?? '';
      expect(d.contains('null'), isFalse, reason: 'raw null rendered: "$d"');
      expect(d.contains('NaN'), isFalse, reason: 'NaN rendered: "$d"');
    }
  });

  // The same block with real timings is untouched.
  testWidgets('kitchen timings still render once tickets have been timed', (tester) async {
    final api = _FakeApi(const {'/analytics/overview?days=30': _insights});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.text('AVG PREP'), findsOneWidget);
    expect(find.text('across 388 timed order(s)'), findsOneWidget);
    expect(find.textContaining('No timed orders yet'), findsNothing);
  });

  // A gated module must not even be asked for: the tile could never be shown,
  // so the request is pure cost (and would 403 anyway).
  testWidgets('gated modules are not fetched and get no tile', (tester) async {
    final api = _FakeApi(const <String, dynamic>{});
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      visible: const ['Overview'],
    ));
    await tester.pumpAndSettle();

    expect(api.calls, isNot(contains('GET /inventory')));
    expect(api.calls, isNot(contains('GET /purchase-orders')));
    expect(api.calls, isNot(contains('GET /get-bookings?window=upcoming')));
    expect(api.calls, isNot(contains('GET /waitlist')));
    expect(api.calls, isNot(contains('GET /bills/open?limit=1')));
    expect(find.text('Operations'), findsNothing);
  });

  // ---- TODAY BY PAYMENT METHOD ---------------------------------------------
  // Client ask: "How much money from each payment method made in the day has to
  // be shown." The rows ride on /analytics/headline; the server proves they add
  // up to Today's gross and that the Cash row is Cash collection. What these pin
  // is that the Overview prints them, prints them verbatim, and prints nothing
  // when an older server did not send them.

  testWidgets('today by payment method renders one bar per mode inside the headline box', (tester) async {
    final api = _FakeApi({'/analytics/headline': _headline()});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('COLLECTED BY PAYMENT METHOD'), findsOneWidget);
    expect(find.text("Settled today, by how it was paid; adds up to Today's gross sale."), findsOneWidget);
    final bars = tester.widgetList<HBarRow>(find.byType(HBarRow)).where((b) => ['Upi', 'Cash', 'Card'].contains(b.label)).toList();
    // In the server's order — largest first — with the money at two decimals.
    expect(bars.map((b) => b.label), ['Upi', 'Cash', 'Card']);
    expect(bars.map((b) => b.value), ['₹11000.00', '₹8430.50', '₹3250.40']);
    expect(find.text('6 bill(s) · 48.5%'), findsOneWidget);
    // The bar is the share of today, not the size against the largest mode.
    expect(bars[2].fraction, closeTo(3250.4 / 22680.9, 1e-12));
    // A refund gets its own line, with what survived it.
    expect(find.text('6 bill(s) · 37.2% · − ₹120.00 refunded · ₹8310.50 net'), findsOneWidget);
    // And the split note — which claims only that each part counts under its
    // own method. "Adds up to more than the bills settled" is false the moment
    // a released ₹0 table is in the tag's count and has no row.
    expect(find.text('1 bill(s) paid across more than one method; each part counts under its own method.'), findsOneWidget);
    expect(find.textContaining('add up to more than'), findsNothing);
    expect(find.textContaining('could not be put under a payment method'), findsNothing);
    expect(find.textContaining('split amounts do not add up'), findsNothing);
  });

  testWidgets("the bars divide by the server's Today's gross, not a re-sum of the rows", (tester) async {
    // The rows add to 22680.90; the gross is a paisa away so a block that summed
    // its own rows draws a different fraction. The server guarantees the two
    // agree (mis_report_agreement.test.ts) — the paisa only tells them apart.
    final api = _FakeApi({
      '/analytics/headline': _headline(over: {
        'today_gross': {'value': 22680.91, 'label': "Today's gross sale", 'hint': 'Settled today, tax inclusive.'},
      }),
    });
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    final card = tester.widget<HBarRow>(find.ancestor(of: find.text('Card'), matching: find.byType(HBarRow)));
    expect(card.fraction, closeTo(3250.4 / 22680.91, 1e-12));
    expect(card.fraction, isNot(closeTo(3250.4 / 22680.9, 1e-12)));
  });

  testWidgets('residuals that cancel to ₹0.00 across bills are still flagged, off the row', (tester) async {
    // ₹50 short on one split, ₹50 over on another: today_unallocated is 0 and so
    // is the row's amount. Its two bills are what say something is wrong.
    final api = _FakeApi({
      '/analytics/headline': _headline(over: {
        'today_by_method': [
          {'method': 'Cash', 'bills': 2, 'amount': 1250, 'share_pct': 62.5, 'refund': 0, 'net_amount': 1250},
          {'method': 'Upi', 'bills': 2, 'amount': 750, 'share_pct': 37.5, 'refund': 0, 'net_amount': 750},
          {'method': 'Unallocated', 'bills': 2, 'amount': 0, 'share_pct': 0, 'refund': 0, 'net_amount': 0},
        ],
        'today_gross': {'value': 2000, 'label': "Today's gross sale", 'hint': 'x'},
        'cash_collection': {'value': 1250, 'label': 'Cash collection', 'hint': 'x'},
        'today_split_bills': 2,
        'today_unallocated': 0,
      }),
    });
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text("2 bills' split amounts do not add up to their totals and need looking at "
          '(the differences cancel out to ₹0.00 today).'),
      findsOneWidget,
    );
    final row = tester.widget<HBarRow>(find.ancestor(of: find.text('Unallocated'), matching: find.byType(HBarRow)));
    expect(row.value, '₹0.00');
    expect(row.color, AppColors.warning);
  });

  testWidgets('the Cash row prints through the same money formatter as the Cash collection tile', (tester) async {
    // FORMATTER PARITY only. That the two NUMBERS agree is the server's promise
    // (cash_collection is read off these rows) and is proven in backend jest
    // (mis_report_agreement.test.ts); this fixture hand-sets both, so all this
    // can catch is the row and the tile formatting one value two ways.
    final api = _FakeApi({'/analytics/headline': _headline()});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    final cashRow = tester.widget<HBarRow>(find.ancestor(of: find.text('Cash'), matching: find.byType(HBarRow)));
    // The tile prints the same payload value through the same formatter.
    final tile = find.ancestor(of: find.text('CASH COLLECTION'), matching: find.byType(Column)).first;
    expect(find.descendant(of: tile, matching: find.text(cashRow.value)), findsOneWidget);
    expect(cashRow.value, '₹8430.50');
  });

  testWidgets('an older backend that sends no rows gets no block — not "nothing by any method"', (tester) async {
    final legacy = _headline()
      ..remove('today_by_method')
      ..remove('today_split_bills')
      ..remove('today_unallocated')
      ..remove('by_method');
    final api = _FakeApi({'/analytics/headline': legacy});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The headline itself still draws…
    expect(find.text('Today at a glance'), findsOneWidget);
    expect(find.text('CASH COLLECTION'), findsOneWidget);
    // …and the block does not.
    expect(find.text('COLLECTED BY PAYMENT METHOD'), findsNothing);
    expect(find.ancestor(of: find.text('Cash'), matching: find.byType(HBarRow)), findsNothing);
  });

  testWidgets('an empty day or an unlabelled block draws nothing either', (tester) async {
    for (final over in <Map<String, dynamic>>[
      {'today_by_method': <dynamic>[], 'today_bills': 0},
      {'by_method': <String, dynamic>{'label': '  ', 'hint': 'x'}},
    ]) {
      final api = _FakeApi({'/analytics/headline': _headline(over: over)});
      final rest = await _signIn(api);
      _wideWindow(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();

      expect(find.text('Today at a glance'), findsOneWidget);
      expect(find.text('COLLECTED BY PAYMENT METHOD'), findsNothing, reason: '$over');
    }
  });

  testWidgets('money that could not be put under a mode is flagged, in either direction', (tester) async {
    final api = _FakeApi({
      '/analytics/headline': _headline(over: {
        'today_by_method': [
          {'method': 'Cash', 'bills': 1, 'amount': 1200, 'share_pct': 120, 'refund': 0, 'net_amount': 1200},
          {'method': 'Unallocated', 'bills': 1, 'amount': -200, 'share_pct': -20, 'refund': 0, 'net_amount': -200},
        ],
        'today_gross': {'value': 1000, 'label': "Today's gross sale", 'hint': 'x'},
        'today_unallocated': -200,
      }),
    });
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text("₹200.00 could not be put under a payment method — 1 bill's split amounts do not add up to their "
          'totals and need looking at.'),
      findsOneWidget,
    );
    final row = tester.widget<HBarRow>(find.ancestor(of: find.text('Unallocated'), matching: find.byType(HBarRow)));
    expect(row.fraction, 0, reason: 'a negative residual draws no bar');
  });

  testWidgets('a mode opens its drill-down, which jumps to Accounting ON THAT DAY', (tester) async {
    // The day the headline is about is the device's today here — the ordinary
    // tap. Accounting was last on 30 days, as it is on a first visit.
    DateRangeMemory.reset();
    addTearDown(DateRangeMemory.reset);
    DateRangeMemory.remember('accounting', DateRange.fromPreset(RangePreset.last30));
    final api = _FakeApi({'/analytics/headline': _headline(over: {'today': todayKey()})});
    final rest = await _signIn(api);
    final opened = <String>[];
    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      visible: const [..._allVisible, 'Accounting'],
      openModule: (label, {Map<String, dynamic>? target}) => opened.add('$label:$target'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Cash · ₹8430.50'), findsOneWidget);
    expect(find.text('− ₹120.00'), findsOneWidget);
    expect(find.text('₹8310.50'), findsOneWidget);
    expect(find.text('37.2%'), findsOneWidget);

    // Looking is not jumping: closing the sheet leaves Accounting's window alone.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(DateRangeMemory.of('accounting').preset, RangePreset.last30);
    expect(opened, isEmpty);

    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View in Accounting'));
    await tester.pumpAndSettle();
    // No focus payload: Accounting takes none, and an unread key would make it
    // claim the record is missing.
    expect(opened, ['Accounting:null']);
    expect(find.byType(Dialog), findsNothing);
    // And it opens on TODAY — not the 30 days it was on, where its Cash bar is a
    // month of cash beside the day's ₹8430.50 the owner just tapped. The Today
    // PRESET, so it moves with the calendar past midnight like any other Today.
    expect(DateRangeMemory.of('accounting'), DateRange.fromPreset(RangePreset.today));
  });

  testWidgets("a headline whose day is not the device's day pins Accounting to the headline's day", (tester) async {
    // The device has crossed midnight (or sits in another zone) while the sheet
    // still names the server's day. Landing on the device's Today would put a
    // different day's figures behind the jump.
    DateRangeMemory.reset();
    addTearDown(DateRangeMemory.reset);
    final serverDay = addDaysToKey(todayKey(), -1);
    final api = _FakeApi({'/analytics/headline': _headline(over: {'today': serverDay})});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(
      m.overviewModule(rest, rest.auth.profile!),
      visible: const [..._allVisible, 'Accounting'],
      openModule: (label, {Map<String, dynamic>? target}) {},
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Upi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View in Accounting'));
    await tester.pumpAndSettle();
    expect(DateRangeMemory.of('accounting'), DateRange(from: serverDay, to: serverDay, preset: RangePreset.custom));
  });

  testWidgets('without Accounting the drill-down still opens but offers no dead jump', (tester) async {
    final api = _FakeApi({'/analytics/headline': _headline()});
    final rest = await _signIn(api);
    _wideWindow(tester);

    await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Card'));
    await tester.pumpAndSettle();
    expect(find.text('Card · ₹3250.40'), findsOneWidget);
    expect(find.text('View in Accounting'), findsNothing);
  });

  testWidgets('the by-method block and its drill-down survive a phone and a raised text scale', (tester) async {
    for (final width in [360.0, 390.0, 800.0, 1200.0]) {
      for (final scale in [1.0, 1.3]) {
        final api = _FakeApi({
          '/analytics/headline': _headline(over: {
            'today_by_method': [
              {'method': 'Eazydiner', 'bills': 1234, 'amount': 98765432.1, 'share_pct': 97.5, 'refund': 12345.67, 'net_amount': 98753086.43},
              {'method': 'Cash', 'bills': 999, 'amount': 2468013.57, 'share_pct': 2.44, 'refund': 0, 'net_amount': 2468013.57},
              {'method': 'Unallocated', 'bills': 12, 'amount': 55555.55, 'share_pct': 0.06, 'refund': 0, 'net_amount': 55555.55},
            ],
            'today_gross': {'value': 101289001.22, 'label': "Today's gross sale", 'hint': 'x'},
            'cash_collection': {'value': 2468013.57, 'label': 'Cash collection', 'hint': 'x'},
            'today_split_bills': 321,
            'today_unallocated': 55555.55,
          }),
        });
        final rest = await _signIn(api);
        tester.view.physicalSize = Size(width, 4000);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_host(m.overviewModule(rest, rest.auth.profile!), visible: const [..._allVisible, 'Accounting']));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'by-method block at ${width}px / ${scale}x');
        expect(find.text('COLLECTED BY PAYMENT METHOD'), findsOneWidget);

        await tester.tap(find.text('Eazydiner'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'by-method drill-down at ${width}px / ${scale}x');
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
    }
  });
}
