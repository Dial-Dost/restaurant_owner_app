// ROUND 2, ITEMS 1 AND 4 — the settled-bill half of "Edit name / GSTIN", the
// customer lines on the bill, and the REPRINT banner on the preview.
//
// Item 1: "This option has to come in the past bills section in accounting."
//   * each settled bill row, and the bill's own sheet, carry "Edit name /
//     GSTIN" behind EXACTLY the gate "Reprint bill" sits behind — so a waiter
//     sees neither;
//   * Save posts {customer, customer_gstin} to POST /bills/:billId/customer-details
//     and the row repaints from the server's answer / the sheet re-reads;
//   * "Bill not found" is the server's sentence; a missing route says the server
//     is a release behind.
//
// The customer slot: the bill preview and the settled-bill sheet show
// `Name: <name>` — a bare `Name:` for a walk-in, the slot left blank as the
// client's printed bill leaves it — and, when set, `Customer GSTIN: <gstin>`, in
// their own ruled-off block directly under the restaurant header and above the
// date / cashier / bill-no block — where the client's printed bill has them.
//
// Item 4: "Reprint has to mention reprint on top once the bill has been
// reprinted and it should show the same on the preview as well." The preview of
// a bill the server says was already printed carries a REPRINT banner at the
// very top of the receipt; the preview of a first print does not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

const String _addOrders = '4ad474d4-5230-449c-874f-6a238b833bca';

enum _Answer { ok, notFound, routeMissing }

class _FakeApi extends ApiClient {
  _FakeApi({
    this.role = 'admin',
    this.actions = const ['*'],
    this.waiterOnly,
    this.answer = _Answer.ok,
    this.customer = 'Guest',
    this.gstin,
    this.bill,
  });

  final String role;
  final List<String> actions;
  final bool? waiterOnly;
  final _Answer answer;

  /// The settled bill's name and GSTIN; a successful save changes them, so a
  /// re-read shows whether the screen really went back to the server.
  Object? customer;
  Object? gstin;

  /// The open bill /bill-for-table answers, for the preview tests.
  final Map<String, dynamic>? bill;

  final List<String> calls = [];
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'meera',
          'emp_Fname': 'Meera',
          'role': role,
          'role_all': [role],
          if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
          'actions_set': actions,
          'action_names': const <String>[],
        }),
      );

  Map<String, dynamic> get _row => {
        'id': 'b1',
        'bill_no': '57',
        'table_name': 'T1',
        'covers': 4,
        'grand_total': 4600.00,
        'payment_method': 'UPI',
        'settled_at': '2026-08-05T14:20:00.000Z',
        'customer': customer,
        'customer_gstin': gstin,
      };

  Map<String, dynamic> get _detail => {
        ..._row,
        'items_subtotal': 4000.00,
        'taxable_base': 4000.00,
        'service_charge': 400.00,
        'tax_total': 200.00,
        'taxes': const <Map<String, dynamic>>[],
        'items': const [
          {'name': 'Paneer Tikka', 'quantity': 2, 'price': 2000.00, 'line_total': 4000.00},
        ],
        'orders': const <Map<String, dynamic>>[],
        'payment_splits': const <Map<String, dynamic>>[],
      };

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      if (path == '/bills/b1/customer-details') {
        switch (answer) {
          case _Answer.notFound:
            throw ApiException('Bill not found', 404);
          case _Answer.routeMissing:
            throw ApiException('Cannot POST /bills/b1/customer-details', 404);
          case _Answer.ok:
            final b = body as Map;
            final name = '${b['customer']}'.trim();
            customer = name.isEmpty ? 'Guest' : name;
            gstin = b['customer_gstin'];
            return <String, dynamic>{'success': true, 'bill_id': 'b1', 'customer': customer, 'customer_gstin': gstin};
        }
      }
      return <String, dynamic>{'success': true};
    }
    if (path.startsWith('/bills/closed/b1')) return _detail;
    if (path.startsWith('/bills/closed')) return {'bills': [_row], 'total': 1, 'has_more': false};
    if (path.startsWith('/reports/sales')) {
      return {'total_sales': 4600.0, 'net_sales': 4600.0, 'bill_count': 1, 'by_day': const [], 'by_method': const []};
    }
    if (path.startsWith('/reports/gst')) return {'by_rate': const []};
    if (path.startsWith('/reports/pnl')) return {'expenses_by_category': const []};
    if (path.startsWith('/reports/discounts')) return {'by_coupon': const [], 'notes': const []};
    if (path.startsWith('/expenses')) return {'expenses': const []};
    if (path.startsWith('/payroll')) return {'rows': const []};
    // --- the open-bill preview ---
    if (path.startsWith('/bill-for-table') && bill != null) return bill;
    if (path.startsWith('/get-tables')) {
      return [
        {'table_name': 'T1', 'capacity': 4, 'max_capacity': 4, 'section': 'Main', 'occupied': true, 'has_order': true, 'covers': 2},
      ];
    }
    if (path.startsWith('/table-sections')) {
      return {
        'sections': [
          {'section': 'Main'},
        ],
      };
    }
    if (path.startsWith('/restaurant/settings')) return {'kitchen_sections': <dynamic>[]};
    if (path.startsWith('/restaurant/profile')) return {'outlet_add': ''};
    if (path.startsWith('/table-assignments') || path.startsWith('/get-bookings') || path.startsWith('/menu') || path.startsWith('/orders')) {
      return <dynamic>[];
    }
    throw ApiException('No fake route for $path', 404);
  }

  List<({String method, String path, Object? body})> get detailWrites =>
      writes.where((w) => w.path.endsWith('/customer-details')).toList();
}

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Accounting'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<void> _mount(WidgetTester tester, _FakeApi api, Widget Function(RestClient, Profile) module) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'meera', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
}

/// Bring [finder] into the tree on a long page, then tap it.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250, scrollable: find.byType(Scrollable).first, maxScrolls: 200);
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

final Finder _rowEdit = find.byKey(const ValueKey('closed-bill-row-edit-customer-b1'));
final Finder _sheetEdit = find.byKey(const ValueKey('closed-bill-edit-customer'));
final Finder _field = find.byKey(const ValueKey('bill-customer-name-field'));
final Finder _gstinField = find.byKey(const ValueKey('bill-customer-gstin-field'));
final Finder _save = find.byKey(const ValueKey('bill-customer-name-save'));

Future<void> _openBillSheet(WidgetTester tester) async {
  await _tap(tester, find.text('Bill #57 · T1'));
  expect(find.text('SETTLED BILL'), findsOneWidget);
}

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  group('Edit name / GSTIN on a settled bill in Accounting — round 2 item 1', () {
    testWidgets('the row edits in place: posts both fields, then repaints from the answer', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api, m.accountingModule);
      expect(_rowEdit, findsOneWidget);

      await _tap(tester, _rowEdit);
      expect(find.text('Name / GSTIN / address on Bill #57'), findsOneWidget);
      expect(tester.widget<TextField>(_field).controller!.text, '', reason: 'never seeded with "Guest"');
      await tester.enterText(_field, '  Acme   Ltd ');
      await tester.enterText(_gstinField, '29abcde1234f1z5');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      final w = api.detailWrites.single;
      expect(w.method, 'POST');
      expect(w.path, '/bills/b1/customer-details');
      expect(w.body, {'customer': 'Acme Ltd', 'customer_gstin': '29ABCDE1234F1Z5'});
      expect(find.text('Name and GSTIN updated on Bill #57.'), findsOneWidget);
      // The row now says who the bill was for.
      expect(find.text('Acme Ltd'), findsOneWidget);
      expect(find.text('GSTIN 29ABCDE1234F1Z5'), findsOneWidget);
    });

    testWidgets('the sheet shows the customer lines, edits, and re-reads the bill', (tester) async {
      final api = _FakeApi(customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5');
      await _mount(tester, api, m.accountingModule);
      await _openBillSheet(tester);
      expect(find.text('Name: Acme Ltd'), findsOneWidget);
      expect(find.text('Customer GSTIN: 29ABCDE1234F1Z5'), findsOneWidget);
      expect(find.text('Reprint bill'), findsOneWidget);
      expect(_sheetEdit, findsOneWidget);

      final detailReads = api.calls.where((c) => c == 'GET /bills/closed/b1').length;
      final listReads = api.calls.where((c) => c.startsWith('GET /bills/closed?')).length;
      await _tap(tester, find.text('Edit name / GSTIN / address'));
      expect(tester.widget<TextField>(_gstinField).controller!.text, '29ABCDE1234F1Z5');
      await tester.enterText(_field, 'Acme Pvt Ltd');
      await tester.enterText(_gstinField, '');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      expect(api.detailWrites.single.body, {'customer': 'Acme Pvt Ltd', 'customer_gstin': null});
      expect(api.calls.where((c) => c == 'GET /bills/closed/b1').length, greaterThan(detailReads),
          reason: 'the sheet re-reads the bill');
      expect(api.calls.where((c) => c.startsWith('GET /bills/closed?')).length, greaterThan(listReads),
          reason: 'the list behind the sheet refreshes its row');
      expect(find.text('Name: Acme Pvt Ltd'), findsOneWidget);
      expect(find.textContaining('Customer GSTIN:'), findsNothing);
    });

    testWidgets('a malformed GSTIN never reaches the server', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api, m.accountingModule);
      await _tap(tester, _rowEdit);
      await tester.enterText(_gstinField, '29ABCDE');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('GSTIN must be 15 characters, e.g. 29ABCDE1234F1Z5'), findsOneWidget);
      expect(api.detailWrites, isEmpty);
    });

    testWidgets('"Bill not found" is the server\'s sentence', (tester) async {
      final api = _FakeApi(answer: _Answer.notFound);
      await _mount(tester, api, m.accountingModule);
      await _tap(tester, _rowEdit);
      await tester.enterText(_field, 'Acme Ltd');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('Bill not found'), findsOneWidget);
    });

    testWidgets('a server without the route says it has not finished updating', (tester) async {
      final api = _FakeApi(answer: _Answer.routeMissing);
      await _mount(tester, api, m.accountingModule);
      await _tap(tester, _rowEdit);
      await tester.enterText(_field, 'Acme Ltd');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.textContaining('This server has not finished updating'), findsOneWidget);
    });

    testWidgets('hidden from a waiter, exactly as Reprint bill is', (tester) async {
      final api = _FakeApi(role: 'waiter', actions: const [_addOrders], waiterOnly: true, customer: 'Acme Ltd');
      await _mount(tester, api, m.accountingModule);
      expect(_rowEdit, findsNothing);
      await _openBillSheet(tester);
      expect(find.text('Reprint bill'), findsNothing);
      expect(find.descendant(of: _sheetEdit, matching: find.byType(OutlinedButton)), findsNothing);
      expect(find.text('Edit name / GSTIN / address'), findsNothing);
      expect(find.byTooltip('Edit name / GSTIN / address'), findsNothing);
      // The lines are not money, so they are still read.
      expect(find.text('Name: Acme Ltd'), findsOneWidget);
    });

    testWidgets('a manager holding the accounting permission gets it', (tester) async {
      final api = _FakeApi(role: 'manager', actions: const ['df75119b-e5f1-4f38-aba5-78a1cf182f56']);
      await _mount(tester, api, m.accountingModule);
      expect(_rowEdit, findsOneWidget);
    });
  });

  group('the bill preview — customer lines (contract D) and REPRINT (item 4)', () {
    Map<String, dynamic> openBill({Object? customer = 'Acme Ltd', Object? gstin = '29ABCDE1234F1Z5', Map<String, dynamic>? prints}) => {
          'bill_id': 'bill-1',
          'bill_no': '88',
          'customer': customer,
          'customer_gstin': gstin,
          'subtotal': 699.0,
          'total_amt': 699.0,
          'discount': 0.0,
          'service_charge': 0.0,
          'service_charge_waived': false,
          'taxes': const [],
          'tax_total': 0.0,
          'grand_total': 699.0,
          'nc_total': 0.0,
          'covers': 2,
          'apc': 349.5,
          'target_apc': 0,
          'order_ids': const ['o-1'],
          'items': const [
            {'name': 'Gin & Tonic', 'price': 699.0, 'quantity': 1},
          ],
          ...?prints,
        };

    Finder inPreview(Finder f) => find.descendant(of: find.byType(Dialog), matching: f);

    Future<void> openPreview(WidgetTester tester, _FakeApi api) async {
      await _mount(tester, api, m.tablesModule);
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      final print = find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Print bill');
      await tester.ensureVisible(print);
      await tester.pumpAndSettle();
      await tester.tap(print);
      await tester.pumpAndSettle();
      expect(find.text('Bill preview'), findsOneWidget);
    }

    testWidgets('the customer slot sits under the restaurant header and ABOVE the date / bill-no block',
        (tester) async {
      await openPreview(tester, _FakeApi(bill: openBill(prints: {'print_count': 0, 'bill_printed_at': null})));
      final name = inPreview(find.text('Name: Acme Ltd'));
      final gstin = inPreview(find.text('Customer GSTIN: 29ABCDE1234F1Z5'));
      expect(name, findsOneWidget);
      expect(gstin, findsOneWidget);
      double y(Finder f) => tester.getTopLeft(f).dy;
      expect(y(name), greaterThan(y(inPreview(find.text('CSR Organics')))), reason: 'below the restaurant header');
      expect(y(gstin), greaterThan(y(name)), reason: 'GSTIN directly under the name');
      expect(y(gstin), lessThan(y(inPreview(find.text('Dine In: T1')))),
          reason: 'above the date / table row, not under it');
      expect(y(gstin), lessThan(y(inPreview(find.text('Bill No.: 88')))),
          reason: 'above the bill-no block, not under it');
      expect(y(name), lessThan(y(inPreview(find.textContaining('Gin & Tonic')))));
      // One name line only — the old bare name under the bill number is gone.
      expect(inPreview(find.text('Acme Ltd')), findsNothing);
      expect(inPreview(find.textContaining('Acme Ltd')), findsOneWidget);
    });

    testWidgets('a walk-in bill leaves the "Name:" slot blank and prints no GSTIN line', (tester) async {
      await openPreview(tester, _FakeApi(bill: openBill(customer: 'Guest', gstin: null, prints: {'print_count': 0})));
      expect(inPreview(find.text('Name:')), findsOneWidget, reason: 'the slot is still there, as on the paper');
      expect(inPreview(find.textContaining('Customer GSTIN')), findsNothing);
      expect(inPreview(find.textContaining('Guest')), findsNothing,
          reason: 'the "Guest" placeholder is not a name, and the paper no longer prints it as one');
    });

    testWidgets('a first print carries NO reprint banner', (tester) async {
      await openPreview(tester, _FakeApi(bill: openBill(prints: {'print_count': 0, 'bill_printed_at': null, 'printed_at': null})));
      expect(find.byKey(const ValueKey('bill-preview-reprint')), findsNothing);
      expect(inPreview(find.text('REPRINT')), findsNothing);
    });

    testWidgets('an already-printed bill shows REPRINT, large and bold, at the very top', (tester) async {
      await openPreview(
          tester,
          _FakeApi(bill: openBill(prints: {
            'print_count': 1,
            'bill_printed_at': '2026-09-13T12:00:00.000Z',
            'printed_at': '2026-09-13T12:00:00.000Z',
          })));
      final banner = inPreview(find.text('REPRINT'));
      expect(banner, findsOneWidget);
      final style = tester.widget<Text>(banner).style!;
      expect(style.fontWeight, FontWeight.w900);
      expect(style.fontSize, greaterThanOrEqualTo(20));
      // Above the restaurant name, which heads the receipt.
      expect(tester.getTopLeft(banner).dy, lessThan(tester.getTopLeft(inPreview(find.text('CSR Organics'))).dy));
      expect(tester.getTopLeft(banner).dy, lessThan(tester.getTopLeft(inPreview(find.text('Name: Acme Ltd'))).dy));
    });

    testWidgets('a printed_at stamp alone is enough to mark the reprint', (tester) async {
      await openPreview(tester, _FakeApi(bill: openBill(prints: {'bill_printed_at': '2026-09-13T12:00:00.000Z'})));
      expect(inPreview(find.text('REPRINT')), findsOneWidget);
    });
  });
}
