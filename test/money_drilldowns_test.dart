import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Accounting, Purchase Orders and Feedback: no figure is a dead end.
///
/// The failure modes being pinned are the ones that make an affordance worse
/// than none:
///   * a tap that does nothing — every element asserted here names the sheet it
///     opens, and the one tile deliberately left inert (Recovery at zero) is
///     asserted to carry no gesture at all;
///   * a sheet that only repeats its card — so each assertion lands on
///     something the card could not hold (the rate behind a tax total, the
///     question wording behind a complaint, the short delivery behind a PO);
///   * an action fired by accident — reading a bill, an expense, a PO or a
///     complaint must not write.
///
/// And one house rule gets its own tests: SERVICE CHARGE IS NOT TAX. Collapsing
/// the two once booked ₹31,733.92 of owner income as GST, so that exact figure
/// is the fixture and every money surface has to keep it out of the tax lines.

const double _serviceCharge = 31733.92;
const double _taxTotal = 18000.00;

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
          'restaurantUsername': 'csrorganics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a query-carrying family
    // while an exact id route still wins over its own list.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  List<String> get writes => calls.where((c) => !c.startsWith('GET ')).toList();
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

const List<String> _allLabels = [
  'Overview', 'Orders', 'Menu', 'Inventory', 'Purchase Orders',
  'Tables', 'Bookings', 'Feedback', 'Employees', 'Accounting',
];

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  List<String> labels = _allLabels,
  void Function(String, Map<String, dynamic>?)? onOpen,
}) async {
  // Blank pump first: these screens hold their own State, so re-pumping the
  // same widget type would keep the previously loaded payload.
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes);
  final rest = await _signIn(api);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (label, {Map<String, dynamic>? target}) => onOpen?.call(label, target),
      visibleLabels: labels,
      clearFocus: () {},
      child: Scaffold(backgroundColor: Colors.transparent, body: module(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void _size(WidgetTester tester, double width, {double height = 1600, double scale = 1.0}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// These pages are long, so bring the target into the tree before tapping it.
/// The rewind matters: an earlier `ensureVisible` parks the list with that row
/// at the leading edge, which can leave a later target ABOVE it.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final page = find.byType(Scrollable).first;
  if (finder.evaluate().isEmpty) {
    await tester.drag(page, const Offset(0, 8000), warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250, scrollable: page, maxScrolls: 250);
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('Close').last);
  await tester.pumpAndSettle();
}

/// Scoped to the open drill-down dialog. Without this an assertion about the
/// sheet can be satisfied by the page still sitting behind it — which is
/// exactly the "sheet only repeats the card" failure the tests exist to catch.
Finder _inSheet(Finder inner) => find.descendant(of: find.byType(Dialog), matching: inner);

Finder _sheetText(String s) => _inSheet(find.text(s));

Future<void> _toTop(WidgetTester tester) async {
  final page = find.byType(Scrollable).first;
  await tester.drag(page, const Offset(0, 9000), warnIfMissed: false);
  await tester.pumpAndSettle();
}

/// Scroll the whole page top to bottom so every row is actually laid out —
/// a ListView only builds what it can see, and an overflow in row 40 is
/// invisible to a test that never scrolls to row 40.
Future<void> _scrollThrough(WidgetTester tester) async {
  final page = find.byType(Scrollable).first;
  for (var i = 0; i < 14; i++) {
    await tester.drag(page, const Offset(0, -600), warnIfMissed: false);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// The tile's own card, found through its caption, so an assertion about one
/// stat card cannot be satisfied by a different card on the page.
Finder _tileCard(String caption) =>
    find.ancestor(of: find.text(caption), matching: find.byType(ForkCard)).last;

// ---------------------------------------------------------------- accounting --

Map<String, dynamic> _accountingRoutes({
  List<Map<String, dynamic>> expenses = const [],
  List<Map<String, dynamic>> payrollRows = const [],
  List<Map<String, dynamic>> closedBills = const [],
  Map<String, dynamic>? billDetail,
  List<Map<String, dynamic>> byMethod = const [
    {'method': 'Cash', 'sales': 220000.00, 'bills': 40},
    {'method': 'UPI', 'sales': 189733.92, 'bills': 60},
  ],
}) =>
    {
      '/reports/sales': {
        'from': '2026-07-07',
        'to': '2026-08-05',
        'total_sales': 409733.92,
        'total_tax': _taxTotal,
        'total_service_charge': _serviceCharge,
        'total_refund': 2500.00,
        'total_refunded_tax': 300.00,
        'net_sales': 407233.92,
        'bill_count': 100,
        'by_day': [
          {'date': '2026-08-04', 'sales': 200000.00, 'tax': 9000.0, 'service_charge': 15866.96, 'refund': 0, 'bills': 50},
          {'date': '2026-08-05', 'sales': 209733.92, 'tax': 9000.0, 'service_charge': 15866.96, 'refund': 2500.0, 'bills': 50},
        ],
        'by_method': byMethod,
      },
      '/reports/gst': {
        'total_taxable': 391733.92,
        'total_tax': _taxTotal,
        'total_service_charge': _serviceCharge,
        'by_rate': [
          {'name': 'CGST', 'percentage': 2.5, 'taxable': 360000.00, 'tax': 9000.00},
          {'name': 'SGST', 'percentage': 2.5, 'taxable': 360000.00, 'tax': 9000.00},
        ],
      },
      '/reports/pnl': {
        'gross_sales': 409733.92,
        'refunds': 2500.00,
        'tax_collected': 17700.00,
        'service_charge': _serviceCharge,
        'net_revenue': 389533.92,
        'total_expenses': 120000.00,
        'net_profit': 269533.92,
        'expenses_by_category': [
          {'category': 'Payroll', 'amount': 90000.00},
          {'category': 'Produce', 'amount': 30000.00},
        ],
      },
      '/reports/discounts': {
        'bill_count': 100,
        'discounted_bills': 12,
        'total_discount': 8400.00,
        'manual_discount': 3400.00,
        'coupon_discount': 5000.00,
        'estimated_bills': 0,
        'total_sales': 409733.92,
        'gift_redemption_total': 1200.00,
        'by_coupon': [
          {'code': 'MONSOON20', 'kind': 'promo', 'uses': 8, 'amount': 4000.00},
          {'code': 'GIFT-114', 'kind': 'gift', 'uses': 2, 'amount': 1000.00},
        ],
        'notes': <String>[],
      },
      '/expenses': {'expenses': expenses},
      '/payroll': {'total_due': 45000.00, 'total_paid': 90000.00, 'rows': payrollRows},
      '/bills/closed': {'bills': closedBills, 'total': closedBills.length, 'has_more': false},
      // The null-aware element the lint asks for cannot express this one. `?`
      // guards the VALUE, and the KEY dereferences `billDetail` too — so
      // `'/bills/closed/${billDetail['id']}': ?billDetail` would still throw on
      // the key before the marker ever applied. The `if` element is the only
      // form that guards both halves, so the rule is silenced here rather than
      // the entry rewritten into something that would break.
      // ignore: use_null_aware_elements
      if (billDetail != null) '/bills/closed/${billDetail['id']}': billDetail,
    };

Map<String, dynamic> _expense(String id, String category, double amount,
        {String vendor = '', String note = '', String spentOn = '2026-08-02'}) =>
    {
      'id': id,
      'category': category,
      'amount': amount,
      'vendor': vendor,
      'note': note,
      'spent_on': spentOn,
      'created_at': '2026-08-02T06:30:00.000Z',
      'created_by': 'Meera',
    };

Map<String, dynamic> _payrollRow(String id, String name, {bool paid = false, bool hourly = false}) => {
      'emp_id': id,
      'name': name,
      'role': 'Waiter',
      'paid': paid,
      'paid_amount': paid ? 22000.00 : null,
      'paid_at': paid ? '2026-08-01T05:00:00.000Z' : null,
      'computed_pay': paid ? null : 23500.00,
      'hours_worked': hourly ? 164 : 0,
      'profile': {
        'pay_type': hourly ? 'hourly' : 'monthly',
        'base_salary': hourly ? 0 : 22000.00,
        'hourly_rate': hourly ? 140.00 : 0,
        'allowances': 2000.00,
        'deductions': 500.00,
      },
    };

/// A settled bill whose four guaranteed fields balance:
/// taxable_base + service_charge + tax_total == grand_total.
Map<String, dynamic> _billDetail() => {
      'id': 'b1',
      'bill_no': '57',
      'table_name': 'T1',
      'covers': 4,
      'items_subtotal': 4200.00,
      'discount_amount': 200.00,
      'taxable_base': 4000.00,
      'service_charge': 400.00,
      'service_charge_percent': 10,
      'tax_total': 200.00,
      'grand_total': 4600.00,
      'payment_method': 'UPI',
      'settled_at': '2026-08-05T14:20:00.000Z',
      'closed_by': 'Meera',
      'closed_at': '2026-08-05T14:19:00.000Z',
      'taxes': [
        {'name': 'CGST', 'percentage': 2.5, 'amount': 100.00},
        {'name': 'SGST', 'percentage': 2.5, 'amount': 100.00},
      ],
      'items': [
        {'name': 'Paneer Tikka', 'quantity': 2, 'price': 450.00, 'line_total': 900.00},
        {'name': 'Dal Makhani', 'quantity': 1, 'price': 380.00, 'line_total': 380.00},
      ],
      'orders': <Map<String, dynamic>>[],
      'payment_splits': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _closedBillRow() => {
      'id': 'b1',
      'bill_no': '57',
      'table_name': 'T1',
      'covers': 4,
      'grand_total': 4600.00,
      'payment_method': 'UPI',
      'settled_at': '2026-08-05T14:20:00.000Z',
    };

// ----------------------------------------------------------- purchase orders --

Map<String, dynamic> _po({
  String id = 'po1',
  String status = 'ordered',
  String vendor = 'Green Valley Farms',
  List<Map<String, dynamic>> items = const [
    {'inventory_id': 'i1', 'name': 'Tomatoes', 'qty_ordered': 40, 'unit_cost': 32.50, 'qty_received': 25},
    {'inventory_id': 'i2', 'name': 'Paneer', 'qty_ordered': 10, 'unit_cost': 310.00, 'qty_received': 10},
  ],
  String notes = '',
}) =>
    {
      'id': id,
      'vendor_id': 'v1',
      'vendor_name': vendor,
      'status': status,
      'items': items,
      'total_cost': 4400.00,
      'notes': notes,
      'expected_date': '2026-08-08',
      'created_at': '2026-08-01T04:00:00.000Z',
      'created_by': 'Meera',
      'ordered_at': '2026-08-01T05:00:00.000Z',
      'received_at': null,
      'quality_rating': 4,
    };

Map<String, dynamic> _poRoutes(List<Map<String, dynamic>> orders) => {
      '/purchase-orders': {'orders': orders},
      '/vendors': {'vendors': [{'id': 'v1', 'name': 'Green Valley Farms'}]},
      '/inventory': [{'id': 'i1', 'name': 'Tomatoes'}],
    };

// ------------------------------------------------------------------ feedback --

Map<String, dynamic> _entry(
  String id, {
  required num rating,
  String name = 'Guest',
  String comment = '',
  String employeeId = 'emp1',
  num? nps,
  String source = 'qr',
  List<Map<String, dynamic>> cats = const [],
}) =>
    {
      'id': id,
      'employee_id': employeeId,
      'customer_name': name,
      'overall_rating': rating,
      'comments': comment,
      'nps': nps,
      'source': source,
      'submitted_at': '2026-08-05T12:00:00.000Z',
      'category_ratings': cats,
    };

Map<String, dynamic> _feedbackRoutes({
  required List<Map<String, dynamic>> items,
  List<Map<String, dynamic>> tickets = const [],
  Map<String, dynamic>? categoryAverages,
  List<Map<String, dynamic>> employees = const [],
}) =>
    {
      '/feedback/summary': {
        'totalResponses': 412,
        'averageRating': 4.15,
        'last30DaysResponses': 88,
        'categoryAverages': categoryAverages ??
            {
              'food': {'label': 'Food quality', 'average': 4.6},
              'service': {'label': 'Service speed', 'average': 2.9},
            },
      },
      '/feedback/recovery': {'tickets': tickets},
      '/restaurant/users': {'users': employees},
      '/feedback': {'items': items},
    };

void main() {
  // ---------------------------------------------------------------------------
  group('Accounting — every figure opens its arithmetic', () {
    testWidgets('all four headline tiles open a breakdown, and each is a different one',
        (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());

      // NET SALES → gross, refunds, average bill, and what sits inside gross.
      await _tap(tester, _tileCard('NET SALES'));
      expect(_sheetText('Gross sales'), findsOneWidget);
      expect(_sheetText('Average bill'), findsOneWidget);
      expect(_sheetText('₹4097.34'), findsOneWidget, reason: 'average of 409733.92 over 100 bills');
      await _closeSheet(tester);

      // GST COLLECTED → the rates behind the total.
      await _tap(tester, _tileCard('GST COLLECTED'));
      expect(_sheetText('CGST · 2.5%'), findsOneWidget);
      expect(_sheetText('Total tax'), findsOneWidget);
      await _closeSheet(tester);

      // EXPENSES → the categories behind the total.
      await _tap(tester, _tileCard('EXPENSES'));
      expect(_sheetText('Payroll'), findsOneWidget);
      expect(_sheetText('Produce'), findsOneWidget);
      expect(_sheetText('Total expenses'), findsOneWidget);
      await _closeSheet(tester);

      // NET PROFIT → the walk from gross sales down to profit.
      await _tap(tester, _tileCard('NET PROFIT'));
      expect(_sheetText('Net revenue (ex-tax)'), findsOneWidget);
      expect(_sheetText('Tax kept out'), findsOneWidget);
      expect(_sheetText('Net profit'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('the tax sheet reports the service charge separately, and never as a rate',
        (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _tap(tester, _tileCard('GST COLLECTED'));

      // Both rates are named with their own base, and they add to the total —
      // the service charge is not one of them.
      expect(_sheetText('CGST · 2.5%'), findsOneWidget);
      expect(_sheetText('SGST · 2.5%'), findsOneWidget);
      expect(_sheetText('₹18000.00'), findsNWidgets(2),
          reason: 'the sheet title and the "Total tax" row, both 9000 + 9000');

      // The service charge is present, on its own line, at its own value, under
      // a heading that says it is not tax.
      expect(_sheetText('Service charge'), findsOneWidget);
      expect(_sheetText('₹31733.92'), findsOneWidget);
      expect(_inSheet(find.textContaining('NOT TAX')), findsOneWidget);
      expect(_inSheet(find.textContaining("restaurant's own income")), findsOneWidget);

      // And the two are genuinely distinct figures — the bug this guards was
      // one bucket holding both.
      expect(find.text('₹49733.92'), findsNothing,
          reason: 'tax and service charge must never be summed into one figure');
    });

    testWidgets('the GST card on the page names the service charge as not-tax', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _reveal(tester, find.text('GST breakdown'));
      expect(find.text('Service charge — not tax'), findsOneWidget);
      expect(find.textContaining('excluded from every rate above'), findsOneWidget);
    });

    testWidgets('the net-sales sheet keeps tax and service charge apart inside gross', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _tap(tester, _tileCard('NET SALES'));
      expect(_sheetText('Tax collected'), findsOneWidget);
      expect(_sheetText('Service charge'), findsOneWidget);
      expect(_inSheet(find.textContaining('service charge is NOT tax')), findsOneWidget);
      expect(_sheetText('₹18000.00'), findsOneWidget);
      expect(_sheetText('₹31733.92'), findsOneWidget);
    });

    testWidgets('the profit sheet says the service charge stayed in revenue', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _tap(tester, _tileCard('NET PROFIT'));
      expect(_sheetText('Service charge earned'), findsOneWidget);
      expect(_inSheet(find.textContaining('The service charge is the opposite')), findsOneWidget);
      expect(_sheetText('₹31733.92'), findsOneWidget);
    });

    testWidgets('a payment method row opens its own share and average bill', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _tap(tester, find.text('Cash'));
      expect(find.text('Share of gross sales'), findsOneWidget);
      expect(find.text('Average bill'), findsOneWidget);
      // 220000 of 409733.92
      expect(find.text('53.7%'), findsOneWidget);
      expect(find.text('₹5500.00'), findsOneWidget);
    });

    testWidgets('a payment method reads by the label the owner gave it, the one the till shows', (tester) async {
      // The server attaches `label` beside the stored id (Settings > Payments). A
      // renamed built-in must not read "Dineout" here while the till says
      // "Swiggy Dineout".
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes(byMethod: const [
        {'method': 'Dineout', 'label': 'Swiggy Dineout', 'sales': 220000.00, 'bills': 40},
        {'method': 'Upi', 'label': 'UPI', 'sales': 189733.92, 'bills': 60},
      ]));
      expect(find.text('Swiggy Dineout'), findsWidgets);
      expect(find.text('Dineout'), findsNothing);
      await _tap(tester, find.text('Swiggy Dineout').first);
      expect(find.text('Share of gross sales'), findsOneWidget);
      expect(find.text('53.7%'), findsOneWidget);
    });

    testWidgets('a tax rate row opens the base behind it and excludes the service charge',
        (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());
      await _tap(tester, find.text('CGST · 2.5%'));
      expect(find.text('Taxable base'), findsOneWidget);
      expect(find.text('Share of all tax'), findsOneWidget);
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.textContaining('base excludes the service charge'), findsOneWidget);
    });

    testWidgets('discounts and a single coupon each open their own record', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.accountingModule, _accountingRoutes());

      await _tap(tester, find.text('Total given'));
      expect(find.text('Bills discounted'), findsOneWidget);
      expect(find.text('12 of 100'), findsOneWidget);
      expect(find.textContaining('already stored NET of discount'), findsOneWidget);
      await _closeSheet(tester);

      await _tap(tester, find.text('MONSOON20'));
      expect(find.text('Times redeemed'), findsOneWidget);
      expect(find.text('Average per use'), findsOneWidget);
      expect(find.text('₹500.00'), findsOneWidget, reason: '4000 over 8 uses');
    });

    testWidgets('an expense row opens its record and deletes nothing', (tester) async {
      _size(tester, 1200);
      final api = await _mount(
        tester,
        m.accountingModule,
        _accountingRoutes(expenses: [
          _expense('x1', 'Produce', 30000.00, vendor: 'Green Valley', note: 'Weekly vegetable run'),
        ]),
      );

      await _tap(tester, find.text('Produce · Green Valley'));
      expect(find.text('Share of expenses'), findsOneWidget);
      expect(find.text('Booked by'), findsOneWidget);
      expect(find.text('Weekly vegetable run'), findsOneWidget);
      expect(find.text('25.0%'), findsOneWidget, reason: '30000 of 120000');

      // Reading a record must never mutate it, and the sheet must not offer the
      // destructive control that the row's own button owns.
      expect(api.writes, isEmpty);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('a payroll row opens how the pay was computed', (tester) async {
      _size(tester, 1200);
      final api = await _mount(
        tester,
        m.accountingModule,
        _accountingRoutes(payrollRows: [_payrollRow('e9', 'Ravi Kumar', hourly: true)]),
      );

      await _tap(tester, find.textContaining('Ravi Kumar'));
      expect(find.text('Hours worked'), findsOneWidget);
      expect(find.text('Allowances'), findsOneWidget);
      expect(find.text('Deductions'), findsOneWidget);
      expect(find.text('₹22960.00'), findsOneWidget, reason: '140/h × 164h');
      expect(api.writes, isEmpty, reason: 'opening a payroll record must not pay anyone');
    });
  });

  // ---------------------------------------------------------------------------
  group('Accounting — a settled bill opens its full record', () {
    testWidgets('tax and service charge are separate, labelled lines that balance',
        (tester) async {
      _size(tester, 1200);
      final api = await _mount(
        tester,
        m.accountingModule,
        _accountingRoutes(closedBills: [_closedBillRow()], billDetail: _billDetail()),
      );

      await _tap(tester, find.text('Bill #57 · T1'));

      // The record, not a repeat of the row: the line items and who closed it.
      expect(find.text('Paneer Tikka'), findsOneWidget);
      expect(find.text('Dal Makhani'), findsOneWidget);
      expect(find.text('Handled by'), findsOneWidget);
      expect(find.text('CLOSED'), findsOneWidget, reason: 'the _kv key, which renders uppercase');

      // Service charge on its own row, with its own percentage basis...
      expect(find.text('Service charge'), findsOneWidget);
      expect(find.textContaining('10% of the taxable base'), findsOneWidget);

      // ...and the taxes listed rate by rate, with the service charge in none
      // of them. Two 100.00 rate lines, a 200.00 tax total, a 400.00 service
      // charge: four figures that stay four.
      expect(find.text('CGST 2.5%'), findsOneWidget);
      expect(find.text('SGST 2.5%'), findsOneWidget);
      expect(find.text('Tax total'), findsOneWidget);
      expect(find.text('₹400.00'), findsOneWidget, reason: 'the service charge, alone');
      expect(find.text('₹600.00'), findsNothing,
          reason: 'service charge folded into tax would read 600.00');

      // The contract identity is printed rather than assumed.
      expect(
        find.text('₹4000.00 base + ₹400.00 service + ₹200.00 tax = ₹4600.00'),
        findsOneWidget,
      );

      expect(api.writes, isEmpty, reason: 'opening a settled bill must not write');
    });

    testWidgets('the bill sheet is fetched only when it is opened', (tester) async {
      _size(tester, 1200);
      final api = await _mount(
        tester,
        m.accountingModule,
        _accountingRoutes(closedBills: [_closedBillRow()], billDetail: _billDetail()),
      );
      expect(api.calls.where((c) => c.contains('/bills/closed/b1')), isEmpty);

      await _tap(tester, find.text('Bill #57 · T1'));
      expect(api.calls.where((c) => c.contains('/bills/closed/b1')), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  group('Purchase orders — a PO opens its detail', () {
    testWidgets('vendor, lines, quantities, costs, status and dates', (tester) async {
      _size(tester, 1200);
      final api = await _mount(tester, m.purchaseOrdersModule, _poRoutes([_po(notes: 'Split delivery agreed')]));

      await _tap(tester, find.text('Green Valley Farms'));

      // The lines the card only ever counted, with what was asked for beside
      // what actually turned up.
      expect(find.text('Tomatoes'), findsOneWidget);
      expect(find.text('Paneer'), findsOneWidget);
      expect(find.text('40 × ₹32.50 · 25 in'), findsOneWidget);
      expect(find.text('10 × ₹310.00 · 10 in'), findsOneWidget);
      expect(find.text('₹1300.00'), findsOneWidget, reason: '40 × 32.50');

      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Total cost'), findsOneWidget);
      expect(find.text('35 of 50'), findsOneWidget);
      expect(find.text('Delivery quality'), findsOneWidget);
      expect(find.text('Raised by'), findsOneWidget);
      expect(find.text('Expected'), findsOneWidget);
      expect(find.text('Split delivery agreed'), findsOneWidget);

      expect(api.writes, isEmpty, reason: 'reading a PO must not change its status');
    });

    testWidgets('the sheet carries the forward actions and neither destructive one',
        (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.purchaseOrdersModule, _poRoutes([_po(status: 'draft')]));
      await _tap(tester, find.text('Green Valley Farms'));

      expect(_sheetText('Place this order'), findsOneWidget);
      expect(_sheetText('Receive stock'), findsOneWidget);
      // Cancel and Delete stay on the card. A sheet opened to READ must not put
      // a destructive control under the next tap.
      expect(_sheetText('Cancel'), findsNothing);
      expect(_sheetText('Delete'), findsNothing);
      expect(find.text('Cancel'), findsOneWidget, reason: 'still on the card behind the sheet');
    });

    testWidgets('a received PO offers no receive action', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.purchaseOrdersModule, _poRoutes([_po(status: 'received')]));
      await _tap(tester, find.text('Green Valley Farms'));
      expect(find.text('Receive stock'), findsNothing);
      expect(find.text('Place this order'), findsNothing);
    });

    testWidgets('the jump to Inventory forwards no focus key it cannot resolve', (tester) async {
      _size(tester, 1200);
      final opened = <String, Map<String, dynamic>?>{};
      await _mount(
        tester,
        m.purchaseOrdersModule,
        _poRoutes([_po()]),
        onOpen: (label, target) => opened[label] = target,
      );
      await _tap(tester, find.text('Green Valley Farms'));
      await _tap(tester, find.text('View in Inventory'));

      expect(opened.keys, contains('Inventory'));
      // Inventory reads no focus key. Anything sent would make it paint the
      // "that record isn't in this list" banner on arrival.
      expect(opened['Inventory'], isNull);
    });

    testWidgets('the jump is not offered when Inventory is gated away', (tester) async {
      _size(tester, 1200);
      await _mount(
        tester,
        m.purchaseOrdersModule,
        _poRoutes([_po()]),
        labels: const ['Purchase Orders'],
      );
      await _tap(tester, find.text('Green Valley Farms'));
      expect(find.text('Tomatoes'), findsOneWidget, reason: 'the sheet still opens');
      expect(find.text('View in Inventory'), findsNothing);
    });

    // "New PO" was gated on inventory with `onPressed: null` — but a FAB with a
    // null onPressed keeps its full colour (FABs have no disabled look), so on
    // a fresh outlet it was a button that LOOKED tappable and silently ate the
    // tap. A real owner reported exactly that. The FAB is now always live and
    // the empty case says out loud why a PO cannot be raised yet.
    testWidgets('New PO with an empty inventory explains itself instead of eating the tap',
        (tester) async {
      _size(tester, 1200);
      final opened = <String>[];
      await _mount(
        tester,
        m.purchaseOrdersModule,
        {
          '/purchase-orders': {'orders': <dynamic>[]},
          '/vendors': {'vendors': <dynamic>[]},
          '/inventory': <dynamic>[],
        },
        onOpen: (label, _) => opened.add(label),
      );

      await tester.tap(find.text('New PO'));
      await tester.pumpAndSettle();

      expect(find.textContaining('has none yet'), findsOneWidget,
          reason: 'the tap must answer WHY, never land nowhere');
      // The dead end names the way out — and takes the owner there.
      await tester.tap(find.text('Open Inventory'));
      await tester.pumpAndSettle();
      expect(opened, contains('Inventory'));
    });

    testWidgets('New PO tells a failed inventory read apart from an empty one', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.purchaseOrdersModule, {
        '/purchase-orders': {'orders': <dynamic>[]},
        '/vendors': {'vendors': <dynamic>[]},
        // No '/inventory' route: the read fails. "Add items first" would be a
        // lie here — the outlet may hold plenty.
      });

      await tester.tap(find.text('New PO'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Open Inventory'), findsNothing,
          reason: 'a failed read is not cured by adding items');
    });

    testWidgets('New PO opens the create dialog when inventory exists', (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.purchaseOrdersModule, _poRoutes(const []));

      await tester.tap(find.text('New PO'));
      await tester.pumpAndSettle();

      expect(find.text('New purchase order'), findsOneWidget);
      expect(find.text('Place order'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  group('Feedback — a score the owner cannot click into is the complaint', () {
    testWidgets('the responses tile opens where they came from and what they carried',
        (tester) async {
      _size(tester, 1200);
      await _mount(
        tester,
        m.feedbackModule,
        _feedbackRoutes(items: [
          _entry('f1', rating: 5, comment: 'Lovely evening', nps: 9, source: 'qr'),
          _entry('f2', rating: 2, source: 'valet'),
          _entry('f3', rating: 4, comment: 'Good', source: 'qr'),
        ]),
      );

      await _tap(tester, _tileCard('RESPONSES'));
      expect(find.text('All time'), findsOneWidget);
      expect(find.text('Last 30 days'), findsOneWidget);
      expect(find.text('WHERE THEY CAME IN'), findsOneWidget);
      expect(find.text('qr'), findsOneWidget);
      expect(find.text('valet'), findsOneWidget);
      expect(find.text('Left a comment'), findsOneWidget);
      // 2 of 3 carried words; the tile could only ever show "412".
      expect(find.text('67%'), findsWidgets);
    });

    testWidgets('the average tile opens the spread and the per-question averages',
        (tester) async {
      _size(tester, 1200);
      await _mount(
        tester,
        m.feedbackModule,
        _feedbackRoutes(items: [
          _entry('f1', rating: 5),
          _entry('f2', rating: 5),
          _entry('f3', rating: 1),
          _entry('f4', rating: 2),
        ]),
      );

      await _tap(tester, _tileCard('AVG RATING'));
      expect(find.text('HOW THE SCORES FALL'), findsOneWidget);
      expect(find.text('5 stars'), findsOneWidget);
      expect(find.text('1 star'), findsOneWidget);
      expect(find.text('At 2 stars or below'), findsOneWidget);
      expect(find.text('50%'), findsWidgets, reason: 'two of four at 2 or below');

      // The per-question averages are on no card anywhere on this page — worst
      // question first, which is the whole reason to open a 4.15.
      expect(find.text('BY QUESTION — WORST FIRST'), findsOneWidget);
      expect(find.text('Service speed'), findsOneWidget);
      expect(find.text('Food quality'), findsOneWidget);
      expect(find.text('2.9 / 5'), findsOneWidget);
    });

    testWidgets('the recovery tile at zero opens the sheet that says what recovery IS',
        (tester) async {
      _size(tester, 1200);
      await _mount(tester, m.feedbackModule, _feedbackRoutes(items: [_entry('f1', rating: 5)]));

      // The tile stays LIVE at zero. Its caption names a concept nothing on the
      // page explains, so the tap must answer "what is this?" — a real owner
      // read the old inert-at-zero tile as a broken control, and they were
      // right to: nothing distinguished it from a dead handler.
      final tile = _tileCard('RECOVERY');
      expect(tester.widget<ForkCard>(tile).onTap, isNotNull);

      await _tap(tester, tile);
      expect(find.text('All clear'), findsOneWidget);
      expect(find.textContaining('2 out of 5 or below'), findsOneWidget,
          reason: 'the empty sheet must say when a ticket lands here');
      expect(find.textContaining('marks them resolved'), findsOneWidget,
          reason: 'and how one leaves the queue');
    });

    testWidgets('the recovery tile opens the queue when tickets are waiting', (tester) async {
      _size(tester, 1200);
      await _mount(
        tester,
        m.feedbackModule,
        _feedbackRoutes(
          items: [_entry('f1', rating: 1)],
          tickets: [
            {'id': 'f1', 'customer_name': 'Anita', 'overall_rating': 1, 'submitted_at': '2026-08-05T12:00:00.000Z', 'recovery_status': 'open', 'category_ratings': <Map<String, dynamic>>[]},
            {'id': 'f9', 'customer_name': 'Bala', 'overall_rating': 2, 'submitted_at': '2026-08-04T12:00:00.000Z', 'recovery_status': 'open', 'category_ratings': <Map<String, dynamic>>[]},
          ],
        ),
      );

      await _tap(tester, _tileCard('RECOVERY'));
      expect(find.textContaining('lowest score first'), findsOneWidget);
      expect(find.text('2 open'), findsOneWidget);
      expect(find.text('Anita'), findsWidgets);
      expect(find.text('Bala'), findsWidgets);
    });

    testWidgets('a recovery card opens the wording the ticket reader does not return',
        (tester) async {
      _size(tester, 1200);
      final api = await _mount(
        tester,
        m.feedbackModule,
        _feedbackRoutes(
          items: [
            _entry('f1', rating: 1, name: 'Anita', comment: 'Cold food', nps: 2, source: 'qr', cats: [
              {
                'key': 'service',
                'label': 'Service speed',
                'rating': 1,
                'question': 'How quickly were you served?',
                'follow_up': 'What held things up?',
                'follow_up_answer': 'Waited 40 minutes for mains',
              },
            ]),
          ],
          tickets: [
            {
              'id': 'f1',
              'customer_name': 'Anita',
              'overall_rating': 1,
              'comments': 'Cold food',
              'submitted_at': '2026-08-05T12:00:00.000Z',
              'recovery_status': 'open',
              // The recovery reader returns no question and no follow-up prompt.
              'category_ratings': [
                {'key': 'service', 'label': 'Service speed', 'rating': 1, 'follow_up_answer': 'Waited 40 minutes for mains'},
              ],
            },
          ],
        ),
      );

      await _tap(tester, find.ancestor(of: find.text('Low rating'), matching: find.byType(ForkCard)).last);

      // Joined back to the full response: the question and the prompt are on
      // the entry, never on the ticket the card was built from.
      expect(find.text('How quickly were you served?'), findsOneWidget);
      expect(find.text('What held things up?'), findsOneWidget);
      expect(find.text('Would recommend'), findsOneWidget);
      expect(find.text('2 / 10'), findsOneWidget);
      expect(find.text('Came in via'), findsOneWidget);
      expect(find.text('FOLLOW-UP'), findsOneWidget);

      // Reading a complaint must not close it.
      expect(api.writes, isEmpty);
      expect(find.text('Resolve'), findsWidgets, reason: 'still on the card behind the sheet');
    });

    testWidgets('a per-waiter QR row opens that waiter own scores', (tester) async {
      _size(tester, 1200);
      await _mount(
        tester,
        m.feedbackModule,
        _feedbackRoutes(
          items: [
            _entry('f1', rating: 5, employeeId: 'emp1'),
            _entry('f2', rating: 1, employeeId: 'emp1'),
            _entry('f3', rating: 4, employeeId: 'emp2'),
          ],
          employees: [
            {'id': 'emp1', 'emp_Fname': 'Ravi', 'emp_Lname': 'Kumar', 'employee_Username': 'ravi'},
          ],
        ),
      );

      await _tap(tester, find.text('Per-waiter feedback QR'));
      await _tap(tester, find.text('Their feedback'));

      expect(find.text('Ravi Kumar'), findsWidgets);
      expect(find.text('Responses'), findsWidgets);
      expect(find.text('MOST RECENT'), findsOneWidget);
      // Two of the three responses are theirs — the QR card could never say so.
      expect(find.text('Average'), findsOneWidget);
      expect(find.text('3.00 / 5'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  group('Hostile data survives every width and text scale', () {
    const widths = [390.0, 1100.0, 1200.0, 1700.0];
    const scales = [1.0, 1.3];

    testWidgets('Accounting', (tester) async {
      // 90-character vendor and category names, a note nobody could fit, and a
      // money figure with eight digits in front of the decimal point.
      final expenses = [
        for (var i = 0; i < 6; i++)
          _expense(
            'x$i',
            'Miscellaneous kitchen consumables and single-use packaging, reviewed quarterly $i',
            98765432.10,
            vendor: 'Sri Venkateswara Wholesale Provisions and Cold Storage Private Limited',
            note: 'Reconciled against the September stock count after the second delivery was split',
          ),
      ];
      final payroll = [
        for (var i = 0; i < 4; i++)
          _payrollRow('e$i', 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer $i',
              paid: i.isEven, hourly: i == 1),
      ];

      for (final width in widths) {
        for (final scale in scales) {
          _size(tester, width, scale: scale);
          await _mount(
            tester,
            m.accountingModule,
            _accountingRoutes(
              expenses: expenses,
              payrollRows: payroll,
              closedBills: [_closedBillRow()],
              billDetail: _billDetail(),
              byMethod: const [
                {'method': 'UPI — PhonePe, GPay and Paytm collections settled nightly', 'sales': 98765432.10, 'bills': 4000},
                {'method': 'Cash', 'sales': 220000.00, 'bills': 40},
              ],
            ),
          );
          expect(tester.takeException(), isNull, reason: 'Accounting overflowed at ${width}px / ${scale}x');
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull,
              reason: 'an Accounting row overflowed at ${width}px / ${scale}x');
        }
      }
    });

    testWidgets('Accounting drill-down sheets', (tester) async {
      for (final width in widths) {
        for (final scale in scales) {
          _size(tester, width, scale: scale);
          await _mount(tester, m.accountingModule, _accountingRoutes());
          for (final caption in const ['NET SALES', 'GST COLLECTED', 'EXPENSES', 'NET PROFIT']) {
            await _tap(tester, _tileCard(caption));
            expect(tester.takeException(), isNull,
                reason: '$caption sheet overflowed at ${width}px / ${scale}x');
            await _closeSheet(tester);
          }
        }
      }
    });

    testWidgets('Purchase orders', (tester) async {
      final orders = [
        for (var i = 0; i < 5; i++)
          _po(
            id: 'po$i',
            status: const ['draft', 'ordered', 'received', 'cancelled', 'ordered'][i],
            vendor: 'Sri Venkateswara Wholesale Provisions and Cold Storage Private Limited $i',
            notes: 'Split across two lorries; the second is expected on the following working day',
            items: [
              for (var j = 0; j < 4; j++)
                {
                  'inventory_id': 'i$j',
                  'name': 'Cold-pressed groundnut oil, 15 litre tin, food-grade sealed $j',
                  'qty_ordered': 9876543,
                  'unit_cost': 98765.43,
                  'qty_received': j,
                },
            ],
          ),
      ];

      for (final width in widths) {
        for (final scale in scales) {
          _size(tester, width, scale: scale);
          await _mount(tester, m.purchaseOrdersModule, _poRoutes(orders));
          expect(tester.takeException(), isNull,
              reason: 'the PO list overflowed at ${width}px / ${scale}x');
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull,
              reason: 'a PO card overflowed at ${width}px / ${scale}x');

          await _tap(tester, find.textContaining('Cold Storage Private Limited 0'));
          expect(tester.takeException(), isNull,
              reason: 'the PO sheet overflowed at ${width}px / ${scale}x');
          await _closeSheet(tester);
        }
      }
    });

    testWidgets('Feedback', (tester) async {
      final items = [
        for (var i = 0; i < 12; i++)
          _entry(
            'f$i',
            rating: i % 5 + 1,
            name: 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer $i',
            comment: 'The paneer was excellent but the table beside the kitchen door was very loud '
                'for the whole of the second course, and nobody came to check on us $i',
            employeeId: 'emp1',
            nps: i % 11,
            cats: [
              {
                'key': 'service',
                'label': 'Speed of service from being seated to the first course arriving',
                'rating': i % 5 + 1,
                'question': 'How quickly were you served once you had been seated at your table?',
                'follow_up': 'If it was slow, what do you think held things up on the night?',
                'follow_up_answer': 'We waited forty minutes for the mains and nobody explained why',
              },
            ],
          ),
      ];
      final tickets = [
        for (var i = 0; i < 3; i++)
          {
            'id': 'f$i',
            'customer_name': 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer $i',
            'overall_rating': 1,
            'comments': 'Cold food and a very long wait for the mains, twice in the same week',
            'submitted_at': '2026-08-05T12:00:00.000Z',
            'recovery_status': 'open',
            'category_ratings': <Map<String, dynamic>>[],
          },
      ];

      for (final width in widths) {
        for (final scale in scales) {
          _size(tester, width, scale: scale);
          await _mount(
            tester,
            m.feedbackModule,
            _feedbackRoutes(
              items: items,
              tickets: tickets,
              employees: [
                {'id': 'emp1', 'emp_Fname': 'Ravi', 'emp_Lname': 'Kumar', 'employee_Username': 'ravi'},
              ],
            ),
          );
          expect(tester.takeException(), isNull, reason: 'Feedback overflowed at ${width}px / ${scale}x');
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull,
              reason: 'a Feedback card overflowed at ${width}px / ${scale}x');

          await _toTop(tester);
          await _tap(tester, _tileCard('AVG RATING'));
          expect(tester.takeException(), isNull,
              reason: 'the rating sheet overflowed at ${width}px / ${scale}x');
          await _closeSheet(tester);
        }
      }
    });
  });
}
