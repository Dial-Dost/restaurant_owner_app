import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/report_export.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// THE SIX REPORTS THAT MIGRATIONS 034-039 GAVE DATA TO.
///
/// They were absent from this screen for one honest reason — nothing recorded
/// what they describe — and they are here now because the capture screens in
/// this app write it. So these tests pin the promises that make each of the six
/// readable rather than merely present:
///
///   * NC shows BOTH facts — what came off the guest's bill AND that it is
///     revenue given away — because showing one is how a comp reads as either a
///     discount or a loss, and it is neither;
///   * a TIP is never revenue: it appears on its own page, on no rung of the
///     money ladder, and the screen says so out loud;
///   * the GROUP report's two gaps stay two — Unclassified is a configuration
///     gap an owner can close, Unattributed is history that cannot be, and
///     folding them tells an owner who has just filed their whole menu that a
///     bucket they cannot empty is their fault;
///   * the COUNTER report carries the money ladder, because its rows are the
///     Sales Summary's own bills re-cut and that is the claim a reader checks;
///   * every tab says WHICH CLOCK it is dated on, because fifteen reports over
///     one date range do not all answer the same question about the same days;
///   * the search box appears only where the server actually searches.
///
/// And, as for the other nine: nothing on this screen writes. The fake throws
/// on any non-GET, so a control report that could mutate anything fails here.

// ------------------------------------------------------------------ fixtures

Map<String, dynamic> _meta(String report, String title) => {
      'report': report,
      'title': title,
      'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
      'timezone': 'Asia/Kolkata',
      'outlet_scope': 'outlet',
      'outlet_name': 'Kalyani Nagar',
      'generated_at': '2026-08-03T04:00:00.000Z',
      'notes': ['Counted the way this report says it is counted.'],
    };

/// Two comps, one of them reversed. The reversed row reads ZERO in the live
/// money column and carries its amount under Reversed, so every column still
/// sums to its own total while the row stays visible.
const _ncRows = [
  {
    'nc_id': 'nc-1',
    'marked_at': '2026-08-01T13:00:00.000Z',
    'bill_id': 'bill-1',
    'bill_no': '101',
    'order_id': 'order-1',
    'item_name': 'Gulab Jamun',
    'category': 'Desserts',
    'quantity': 2,
    'menu_price': 120.0,
    'nc_price': 120.0,
    'menu_value': 240.0,
    'loss': 240.0,
    'nc_kind': 'Guest complaint',
    'reason': 'Dessert arrived cold',
    'authorised_by': 'manager01',
    'marked_by': 'asha',
    'waiter': 'Asha',
    'table_name': 'T1',
    'order_type': 'Dine-in',
    'reversed': false,
    'reversed_loss': 0.0,
    'reversed_by': null,
  },
  {
    'nc_id': 'nc-2',
    'marked_at': '2026-08-02T20:10:00.000Z',
    'bill_id': 'bill-2',
    'bill_no': '102',
    'order_id': 'order-2',
    'item_name': 'Paneer Tikka',
    'category': 'Starters',
    'quantity': 1,
    'menu_price': 320.0,
    'nc_price': 300.0,
    'menu_value': 320.0,
    // Reversed: it gave away nothing, so the LIVE column is zero.
    'loss': 0.0,
    'nc_kind': 'Complimentary',
    'reason': 'Regular guest',
    'authorised_by': 'manager01',
    'marked_by': 'vikram',
    'waiter': 'Vikram',
    'table_name': 'T4',
    'order_type': 'Dine-in',
    'reversed': true,
    'reversed_loss': 300.0,
    'reversed_by': 'manager01',
  },
];

final _ncSummary = {
  'meta': _meta('nc_summary', 'NC Summary'),
  'columns': const [
    {'key': 'marked_at', 'label': 'Date & time', 'type': 'datetime'},
    {'key': 'bill_no', 'label': 'Bill', 'type': 'text'},
    {'key': 'item_name', 'label': 'Item', 'type': 'text'},
    {'key': 'quantity', 'label': 'Qty', 'type': 'int', 'total': true},
    {'key': 'menu_price', 'label': 'Menu price', 'type': 'money'},
    {'key': 'nc_price', 'label': 'NC price', 'type': 'money'},
    {'key': 'loss', 'label': 'Loss (given away)', 'type': 'money', 'total': true},
    {'key': 'nc_kind', 'label': 'Kind', 'type': 'text'},
    {'key': 'reason', 'label': 'Reason', 'type': 'text'},
    {'key': 'authorised_by', 'label': 'Authorised by', 'type': 'text'},
    {'key': 'reversed_loss', 'label': 'Reversed', 'type': 'money', 'total': true, 'default_on': false},
  ],
  'rows': _ncRows,
  'totals': const {
    'entries': 2,
    'reversed_entries': 1,
    'quantity': 3,
    'menu_value': 560.0,
    'loss': 240.0,
    'reversed_loss': 300.0,
    'net_sales': 1800.0,
    'loss_pct_of_net': 13.3,
  },
  'by_kind': const [
    {'kind': 'guest_complaint', 'label': 'Guest complaint', 'entries': 1, 'quantity': 2, 'loss': 240.0},
  ],
  'page': const {'limit': 100, 'offset': 0, 'total': 2, 'has_more': false},
  'category_exact': false,
};

final _scDeny = {
  'meta': _meta('service_charge_deny', 'Service Charge Deny'),
  'columns': const [
    {'key': 'waived_at', 'label': 'Date & time', 'type': 'datetime'},
    {'key': 'bill_no', 'label': 'Bill', 'type': 'text'},
    {'key': 'table_name', 'label': 'Table', 'type': 'text'},
    {'key': 'amount_waived', 'label': 'Amount denied', 'type': 'money', 'total': true},
    {'key': 'tax_on_waived', 'label': 'Tax denied', 'type': 'money', 'total': true},
    {'key': 'grand_total_reduction', 'label': 'Total reduction', 'type': 'money', 'total': true},
    {'key': 'waiver_kind', 'label': 'Kind', 'type': 'text'},
    {'key': 'reason', 'label': 'Reason', 'type': 'text'},
    {'key': 'denied_by', 'label': 'Denied by', 'type': 'text'},
  ],
  'rows': const [
    {
      'waiver_id': 'w-1',
      'waived_at': '2026-08-01T14:00:00.000Z',
      'bill_id': 'bill-1',
      'bill_no': '101',
      'table_name': 'T1',
      'basis': 'Restaurant percentage',
      'basis_percent': 10.0,
      'basis_amount': 1200.0,
      'amount_waived': 120.0,
      'tax_on_waived': 6.0,
      'grand_total_reduction': 126.0,
      'waiver_kind': 'Guest complaint',
      'reason': 'Long wait for the mains',
      'denied_by': 'asha',
      'authorised_by': 'manager01',
      'reversed': false,
      'reversed_amount': 0.0,
    },
  ],
  'totals': const {
    'waivers': 1,
    'reversed_waivers': 0,
    'amount_waived': 120.0,
    'tax_on_waived': 6.0,
    'grand_total_reduction': 126.0,
    'reversed_amount': 0.0,
    'bill_grand_total': 1200.0,
    'service_charge_collected': 880.0,
    'denied_pct_of_chargeable': 12.0,
  },
  'by_kind': const [
    {'kind': 'guest_complaint', 'label': 'Guest complaint', 'waivers': 1, 'amount': 120.0},
  ],
  'page': const {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
};

/// A real group, plus BOTH gap buckets — the whole point of this fixture.
final _groupSummary = {
  'meta': _meta('group_summary', 'Group Summary'),
  'columns': const [
    {'key': 'group_name', 'label': 'Group', 'type': 'text'},
    {'key': 'items', 'label': 'Items', 'type': 'int', 'total': true},
    {'key': 'qty', 'label': 'Qty', 'type': 'int', 'total': true},
    {'key': 'gross_amount', 'label': 'Gross', 'type': 'money', 'total': true},
    {'key': 'net_amount', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'contribution_pct', 'label': '% contribution', 'type': 'percent'},
  ],
  'rows': const [
    {
      'group_id': 'g-1', 'group_name': 'Food', 'gap': false, 'items': 4, 'qty': 9,
      'gross_amount': 1400.0, 'discount_amount': 0.0, 'net_amount': 1400.0,
      'nc_qty': 0, 'nc_value': 0.0, 'contribution_pct': 73.7,
    },
    {
      'group_id': null, 'group_name': 'Unclassified', 'gap': true, 'items': 1, 'qty': 2,
      'gross_amount': 300.0, 'discount_amount': 0.0, 'net_amount': 300.0,
      'nc_qty': 0, 'nc_value': 0.0, 'contribution_pct': 15.8,
    },
    {
      'group_id': null, 'group_name': 'Unattributed', 'gap': true, 'items': 1, 'qty': 1,
      'gross_amount': 200.0, 'discount_amount': 0.0, 'net_amount': 200.0,
      'nc_qty': 0, 'nc_value': 0.0, 'contribution_pct': 10.5,
    },
  ],
  'totals': const {
    'groups': 3, 'items': 6, 'qty': 12,
    'gross_amount': 1900.0, 'discount_amount': 0.0, 'net_amount': 1900.0,
    'nc_qty': 0, 'nc_value': 0.0,
    'unclassified_gross': 300.0,
    'unattributed_gross': 200.0,
  },
  'bill_level_discount': 100.0,
};

final _variationSummary = {
  'meta': _meta('variation_summary', 'Variation Summary'),
  'columns': const [
    {'key': 'item_name', 'label': 'Item', 'type': 'text'},
    {'key': 'variation_name', 'label': 'Variation', 'type': 'text'},
    {'key': 'qty', 'label': 'Qty', 'type': 'int', 'total': true},
    {'key': 'avg_price', 'label': 'Sold at', 'type': 'money'},
    {'key': 'list_price', 'label': 'Configured price', 'type': 'money'},
    {'key': 'gross_amount', 'label': 'Gross', 'type': 'money', 'total': true},
    {'key': 'net_amount', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'item_share_pct', 'label': '% of item', 'type': 'percent'},
  ],
  'rows': const [
    {
      'menu_id': 'menu-1', 'item_name': 'Paneer Tikka', 'variation_id': 'v-1',
      'variation_name': 'Half', 'qty': 4, 'avg_price': 180.0, 'list_price': 180.0,
      'gross_amount': 720.0, 'discount_amount': 0.0, 'net_amount': 720.0,
      'nc_qty': 0, 'nc_value': 0.0, 'item_share_pct': 40.0, 'contribution_pct': 37.9,
    },
    {
      'menu_id': 'menu-1', 'item_name': 'Paneer Tikka', 'variation_id': 'v-2',
      'variation_name': 'Full', 'qty': 3, 'avg_price': 360.0, 'list_price': 320.0,
      'gross_amount': 1080.0, 'discount_amount': 0.0, 'net_amount': 1080.0,
      'nc_qty': 0, 'nc_value': 0.0, 'item_share_pct': 60.0, 'contribution_pct': 56.8,
    },
  ],
  'totals': const {
    'items': 1, 'variations': 2, 'qty': 7,
    'gross_amount': 1800.0, 'discount_amount': 0.0, 'net_amount': 1800.0,
    'nc_qty': 0, 'nc_value': 0.0,
  },
  'window_gross': 1900.0,
  'no_variations_configured': false,
};

final _tipSummary = {
  'meta': _meta('tip_summary', 'Tip Summary'),
  'columns': const [
    {'key': 'settled_at', 'label': 'Date & time', 'type': 'datetime'},
    {'key': 'bill_no', 'label': 'Bill', 'type': 'text'},
    {'key': 'table_name', 'label': 'Table', 'type': 'text'},
    {'key': 'method', 'label': 'Tender', 'type': 'text'},
    {'key': 'tip_mode', 'label': 'Tip mode', 'type': 'text'},
    {'key': 'credited_to', 'label': 'Credited to', 'type': 'text'},
    {'key': 'tip_amount', 'label': 'Tip', 'type': 'money', 'total': true},
  ],
  'rows': const [
    {
      'tender_id': 't-1', 'settled_at': '2026-08-01T13:30:00.000Z',
      'bill_id': 'bill-1', 'bill_no': '101', 'table_name': 'T1', 'order_type': 'Dine-in',
      'method': 'Card', 'tip_amount': 100.0, 'tip_mode': 'card',
      'credited_to': 'asha', 'settled_by': 'asha',
    },
    {
      'tender_id': 't-2', 'settled_at': '2026-08-02T15:10:00.000Z',
      'bill_id': 'bill-2', 'bill_no': '102', 'table_name': 'T4', 'order_type': 'Dine-in',
      'method': 'Cash', 'tip_amount': 50.0, 'tip_mode': 'cash',
      'credited_to': 'pool', 'settled_by': 'vikram',
    },
  ],
  'totals': const {'tip_amount': 150.0, 'tenders': 2, 'bills': 2},
  'by_mode': const [
    {'mode': 'card', 'label': 'Card', 'tips': 100.0, 'tenders': 1},
    {'mode': 'cash', 'label': 'Cash', 'tips': 50.0, 'tenders': 1},
  ],
  'by_credited_to': const [
    {'credited_to': 'asha', 'tips': 100.0, 'tenders': 1},
    {'credited_to': 'pool', 'tips': 50.0, 'tenders': 1},
  ],
  'page': const {'limit': 100, 'offset': 0, 'total': 2, 'has_more': false},
};

/// One configured till plus the unassigned bucket. Their grand totals sum to
/// ₹2000 — the same ₹2000 the Sales Summary reports for this window in the
/// sibling suite, which is the reconciliation this report exists to make
/// checkable rather than merely asserted.
final _counterSummary = {
  'meta': _meta('counter_summary', 'Counter Summary'),
  'columns': const [
    {'key': 'counter_code', 'label': 'Counter', 'type': 'text'},
    {'key': 'counter_name', 'label': 'Name', 'type': 'text'},
    {'key': 'cashiers', 'label': 'Cashiers', 'type': 'text'},
    {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
    {'key': 'gross', 'label': 'Gross', 'type': 'money', 'total': true},
    {'key': 'discount', 'label': 'Discount', 'type': 'money', 'total': true},
    {'key': 'net', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
    {'key': 'payment_modes', 'label': 'Payment modes', 'type': 'text'},
  ],
  'rows': const [
    {
      'counter_id': 'c-1', 'counter_code': 'C1', 'counter_name': 'Front counter',
      'counter_kind': 'counter', 'active': true, 'cashiers': 'Asha', 'cashier_count': 1,
      'bills': 1, 'covers': 3, 'gross': 1300.0, 'discount': 100.0, 'net': 1200.0,
      'service_charge': 0.0, 'tax': 0.0, 'grand_total': 1200.0, 'refund': 0.0,
      'by_method': [{'method': 'Cash', 'amount': 1200.0}],
      'payment_modes': 'Cash ₹1200.00', 'sessions': 1,
      'opened_at': '2026-08-01T05:00:00.000Z', 'closed_at': '2026-08-01T18:00:00.000Z',
      'variance': -40.0,
    },
    {
      // EVERY BILL LANDS SOMEWHERE. A bill written before migration 038 has no
      // counter, and it must be a visible row rather than a dropped one.
      'counter_id': null, 'counter_code': '(none)', 'counter_name': 'Not attributed',
      'counter_kind': null, 'active': null, 'cashiers': 'Vikram', 'cashier_count': 1,
      'bills': 1, 'covers': 2, 'gross': 600.0, 'discount': 0.0, 'net': 600.0,
      'service_charge': 0.0, 'tax': 200.0, 'grand_total': 800.0, 'refund': 0.0,
      'by_method': [{'method': 'UPI', 'amount': 800.0}],
      'payment_modes': 'UPI ₹800.00', 'sessions': 0,
      'opened_at': null, 'closed_at': null, 'variance': null,
    },
  ],
  'totals': const {
    'counters': 2, 'bills': 2, 'covers': 5,
    'gross': 1900.0, 'discount': 100.0, 'net': 1800.0,
    'service_charge': 0.0, 'tax': 200.0, 'round_off': 0.0,
    'grand_total': 2000.0, 'refund': 0.0,
    'sessions': 1, 'variance': -40.0, 'payment_modes': 'Cash ₹1200.00 · UPI ₹800.00',
  },
  'no_counters_configured': false,
};

// ---------------------------------------------------------------------- fake

class _FakeApi extends ApiClient {
  _FakeApi({Map<String, dynamic>? extra}) : routes = {..._base, ...?extra};

  static final Map<String, dynamic> _base = <String, dynamic>{
    '/outlets': {
      'outlets': [
        {'id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'is_active': true},
      ],
    },
    '/reports/mis/nc-summary': _ncSummary,
    '/reports/mis/service-charge-deny': _scDeny,
    '/reports/mis/group-summary': _groupSummary,
    '/reports/mis/variation-summary': _variationSummary,
    '/reports/mis/tip-summary': _tipSummary,
    '/reports/mis/counter-summary': _counterSummary,
  };

  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    // THE READ-ONLY GUARANTEE, enforced rather than asserted: a control report
    // that could write anything would also reach the offline outbox.
    if (method != 'GET') {
      throw StateError('Reports must never write — saw $method $path');
    }
    final base = Uri.parse('http://x$path').path;
    final hit = routes[base];
    if (hit == null) throw ApiException('No fake route for $base', 404);
    return hit;
  }

  List<String> get gets => calls.where((c) => c.startsWith('GET ')).toList();
}

Future<_FakeApi> _mount(WidgetTester tester,
    {double width = 1400, double height = 1000}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final fake = _FakeApi();
  final auth = AuthController(api: fake);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: const ['Reports'],
      clearFocus: () {},
      switchOutlet: (_) {},
      child: Scaffold(backgroundColor: Colors.transparent, body: m.reportsModule(rest, auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return fake;
}

/// Fifteen tabs do not fit any window, so the strip scrolls — a test has to
/// scroll it exactly as a reader would.
Future<void> _openTab(WidgetTester tester, String title) async {
  final tab = find.text(title).first;
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    ReportExporter.overrideDeliver = null;
    ReportExporter.overrideIsMobile = null;
  });

  // ------------------------------------------------------------ 1. NC Summary

  testWidgets('NC Summary shows BOTH facts: off the guest’s bill, and given away',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'NC Summary');

    // The headline is the money given away, beside the sales it is measured
    // against — a comp with no scale is a number nobody can judge.
    expect(find.text('GIVEN AWAY'), findsOneWidget);
    expect(find.text('₹240.00'), findsWidgets);
    expect(find.text('% OF NET SALES'), findsOneWidget);
    expect(find.text('13.3%'), findsWidgets);
    expect(find.text('NET SALES'), findsOneWidget);

    // The sentence that stops the number being misread as missing takings.
    expect(
      find.textContaining('revenue given away, not revenue lost from a total'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reversed comp stays visible, worth zero, with its money under Reversed',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'NC Summary');

    // Both rows are listed — dropping the reversed one would hide the most
    // interesting row in a fraud-control document.
    expect(find.text('Gulab Jamun'), findsOneWidget);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    // …and the screen says how many were reversed rather than leaving the reader
    // to notice that a row's Loss column is zero.
    expect(find.textContaining('was reversed'), findsOneWidget);
    expect(find.text('REVERSED'), findsOneWidget);
    expect(find.text('₹300.00'), findsWidgets);
  });

  testWidgets('NC keeps the Item Wise caveat about names, because it joins the same way',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'NC Summary');
    expect(find.textContaining('matched by dish NAME'), findsOneWidget);
  });

  // -------------------------------------------------- 6. Service Charge Deny

  testWidgets('Service Charge Deny reports what was NOT charged, beside what was',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Service Charge Deny');

    expect(find.text('CHARGE DENIED'), findsOneWidget);
    expect(find.text('₹120.00'), findsWidgets);
    // The reduction differs from the charge whenever tax rode on it. Both are
    // shown, because the guest is told the second one.
    // Twice: once as the headline tile, once as the grid's own column header.
    expect(find.text('TOTAL REDUCTION'), findsWidgets);
    expect(find.text('₹126.00'), findsWidgets);
    expect(find.text('CHARGE COLLECTED'), findsOneWidget);
    // Money never entered a sales figure — said, not implied.
    expect(find.textContaining('never entered a sales figure'), findsOneWidget);
  });

  // ------------------------------------------------------- 10. Group Summary

  testWidgets('the two gap buckets stay TWO — a configuration gap and a history gap',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Group Summary');

    // Both rows survive, under their own names.
    expect(find.text('Unclassified'), findsWidgets);
    expect(find.text('Unattributed'), findsWidgets);

    // And they are explained DIFFERENTLY: one an owner can close, one they
    // cannot. Folding them would tell an owner who has just filed their whole
    // menu that a bucket they can never empty is still their fault.
    expect(find.textContaining('File them to close it.'), findsOneWidget);
    expect(find.textContaining('cannot be reclassified backwards'), findsOneWidget);

    // The reconciliation the report is built on, stated where it is read.
    expect(find.textContaining('ties to Item Wise'), findsOneWidget);
  });

  testWidgets('Group Summary carries the bill-level discount it cannot spread across lines',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Group Summary');
    expect(find.text('BILL-LEVEL DISCOUNT'), findsOneWidget);
    expect(find.text('not spread across lines'), findsOneWidget);
    expect(find.text('₹100.00'), findsWidgets);
  });

  // --------------------------------------------------- 11. Variation Summary

  testWidgets('Variation Summary says it is a SUBSET and shows the whole it is part of',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Variation Summary');

    expect(find.text('WHOLE MENU GROSS'), findsOneWidget);
    expect(find.text('Item Wise, same window'), findsOneWidget);
    expect(find.textContaining('Only dishes that HAVE sizes appear'), findsOneWidget);
    // Sold-at against configured price is the finding this report exists for.
    expect(find.text('Half'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);
  });

  // --------------------------------------------------------- 13. Tip Summary

  testWidgets('a tip is NOT revenue, and the screen says so on the page it is read',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Tip Summary');

    expect(find.text('TIPS'), findsOneWidget);
    expect(find.text('₹150.00'), findsWidgets);
    expect(find.text('not revenue'), findsOneWidget);
    expect(
      find.textContaining('in no sales figure, no APC and no ABV'),
      findsOneWidget,
    );

    // Who is owed it — the reason a shift lead opens this page at all.
    expect(find.text('Who is owed it'), findsOneWidget);
    expect(find.text('asha'), findsWidgets);
    expect(find.text('pool'), findsWidgets);
  });

  testWidgets('the tip page carries no money ladder — a tip is on no rung of one',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Tip Summary');
    expect(find.text('Money ladder'), findsNothing);
    expect(find.text('Grand total'), findsNothing);
  });

  // ----------------------------------------------------- 14. Counter Summary

  testWidgets('Counter Summary carries the ladder, because its rows ARE the Sales Summary’s bills',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Counter Summary');

    // The ladder is how a reader CHECKS the claim rather than taking it.
    expect(find.text('Money ladder'), findsOneWidget);
    expect(find.textContaining('sum to the Sales Summary grand total'), findsOneWidget);
    expect(find.text('₹2000.00'), findsWidgets);

    // Every bill lands somewhere: the unattributed bucket is a row, not a drop.
    expect(find.text('(none)'), findsWidgets);
  });

  testWidgets('a cash variance is flagged rather than left in a column nobody turned on',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Counter Summary');
    expect(find.text('CASH VARIANCE'), findsOneWidget);
    expect(find.textContaining('Cash variance'), findsWidgets);
  });

  // ------------------------------------------------------------ the toolbar

  testWidgets('every tab names the clock it is dated on', (tester) async {
    await _mount(tester);

    // The default tab is Item Wise, which counts on ORDER PLACEMENT and
    // deliberately does not tie to the Sales Summary.
    expect(find.text('Dated on order placement'), findsOneWidget);

    await _openTab(tester, 'NC Summary');
    expect(find.text('Dated on the comp'), findsOneWidget);

    await _openTab(tester, 'Service Charge Deny');
    expect(find.text('Dated on the waiver'), findsOneWidget);

    await _openTab(tester, 'Tip Summary');
    expect(find.text('Dated on the tender'), findsOneWidget);

    await _openTab(tester, 'Counter Summary');
    expect(find.text('Dated on settlement'), findsOneWidget);
  });

  testWidgets('the search box is offered only where the server actually searches',
      (tester) async {
    await _mount(tester);
    // Item Wise searches (its reader has an ilike on the dish name).
    expect(find.byKey(const ValueKey('reports-search')), findsOneWidget);

    await _openTab(tester, 'NC Summary');
    expect(find.byKey(const ValueKey('reports-search')), findsOneWidget);

    // Group Summary answers a whole window off the order lines and ignores the
    // parameter entirely — a box that refetches the same answer is a dead
    // control, and this pack cannot afford one.
    await _openTab(tester, 'Group Summary');
    expect(find.byKey(const ValueKey('reports-search')), findsNothing);

    await _openTab(tester, 'Counter Summary');
    expect(find.byKey(const ValueKey('reports-search')), findsNothing);
  });

  testWidgets('a search term is DROPPED, not silently carried, onto a tab that ignores it',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'NC Summary');
    await tester.enterText(find.byKey(const ValueKey('reports-search')), 'Gulab');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(api.gets.last, contains('search=Gulab'));

    await _openTab(tester, 'Group Summary');
    // The group request carries no search — the server would ignore it, and a
    // term in the URL that changes nothing is how an export comes out labelled
    // with a filter that was never applied.
    expect(api.gets.last, contains('/reports/mis/group-summary'));
    expect(api.gets.last, isNot(contains('search=')));

    // …and coming back, the box is empty rather than showing a term that is no
    // longer in force.
    await _openTab(tester, 'NC Summary');
    expect(api.gets.last, isNot(contains('search=')));
  });

  // ------------------------------------------------------------- read-only

  testWidgets('opening all six writes nothing at all', (tester) async {
    final api = await _mount(tester);
    for (final t in const [
      'NC Summary', 'Service Charge Deny', 'Group Summary',
      'Variation Summary', 'Tip Summary', 'Counter Summary',
    ]) {
      await _openTab(tester, t);
      expect(tester.takeException(), isNull, reason: '$t threw');
    }
    expect(api.calls.every((c) => c.startsWith('GET ')), isTrue,
        reason: 'the reports pack must never write: ${api.calls}');
  });

  // ---------------------------------------------------------- phone layout

  testWidgets('the six degrade to cards on a phone, every value beside its own label',
      (tester) async {
    await _mount(tester, width: 390, height: 1400);
    await _openTab(tester, 'Counter Summary');
    expect(find.byKey(const ValueKey('reports-grid')), findsNothing);
    expect(find.byKey(const ValueKey('reports-cards')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
