// CLIENT ITEMS 7 AND 8 — the guest's address on the bill, and Reprint in
// History. Every widget case runs in BOTH design systems (Rustic Fork and the
// Gaia skin) on BOTH TargetPlatform.windows and TargetPlatform.android.
//
// Item 7: "An option in the tables section to add the ADDRESS of a guest to the
// bill, like name and GSTIN, especially for corporate parties."
//   * the one name / GSTIN dialog gains an address box — multi-line, never cut
//     (over 5 lines or 250 characters is the server's sentence and Save is
//     off), on the live table and on a settled bill;
//   * the live save sends the address only when it CHANGED; a settled list
//     row (which never carries the address) sends one only if it was typed —
//     a name fix must not wipe an address the row could not see;
//   * a server before item 7 that ignores the field is called out;
//   * the bill preview prints the address under the GSTIN and above the date,
//     keyed by position (the old per-kind keys crashed on a second address
//     line), and the settled sheet shows the same lines;
//   * the table header shows the first line and fits a 360dp phone.
//
// Item 8: "Reprint bill should show up in History; old bills should be
// reprintable from the history section."
//   * History -> month -> bill now shows Reprint and the name edit (it used to
//     drop the profile, so the sheet was the read-only drill-down) for an admin
//     and for a manager holding exactly the permission History itself needs;
//   * a tap POSTs /print/bill/settled {bill_id} — the same route Accounting uses;
//   * History never offers "Move to another till" — Accounting still does;
//   * the History page has its own settled-bill list with a search, and its
//     rows reprint too;
//   * without the permission there is no Reprint anywhere in History.

import 'dart:io';

import 'package:flutter/foundation.dart';
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

const String _accounting = 'df75119b-e5f1-4f38-aba5-78a1cf182f56';
const String _viewBill = '98b10bde-802d-4a5b-a726-53a826424f79';
const String _addOrders = '4ad474d4-5230-449c-874f-6a238b833bca';

const String _address = '4th Floor, Prestige Tower\n12 Residency Road\nBengaluru 560025';

final String _thisMonth = () {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}';
}();

class _FakeApi extends ApiClient {
  _FakeApi({
    this.role = 'admin',
    this.actions = const ['*'],
    this.waiterOnly,
    this.liveAddress = _address,
    this.liveKnowsAddress = true,
    this.serverKnowsAddress = true,
    this.detailAddress = _address,
  });

  final String role;
  final List<String> actions;
  final bool? waiterOnly;

  /// The running bill's address; [liveKnowsAddress] false models a server
  /// before client item 7 (no `customer_address` key at all).
  Object? liveAddress;
  final bool liveKnowsAddress;

  /// False: the server keeps name and GSTIN and never answers the address.
  final bool serverKnowsAddress;

  /// The settled bill's address (the DETAIL carries it; the list never does).
  Object? detailAddress;
  Object? liveCustomer = 'Acme Pvt Ltd';
  Object? liveGstin = '29ABCDE1234F1Z5';
  Object? settledCustomer = 'Acme Pvt Ltd';

  final List<String> calls = [];
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia - Global Vegetarian',
          'restaurantUsername': 'gaiaglobalvegetarian',
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
        'settled_at': '$_thisMonth-05T14:20:00.000Z',
        'customer': settledCustomer,
        'customer_gstin': '29ABCDE1234F1Z5',
        // NO customer_address: the list never carries it.
      };

  Map<String, dynamic> get _detail => {
        ..._row,
        'customer_address': detailAddress,
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

  Map<String, dynamic> get _liveBill => {
        'bill_id': 'bill-1',
        'bill_no': '88',
        'customer': liveCustomer,
        'customer_gstin': liveGstin,
        if (liveKnowsAddress) 'customer_address': liveAddress,
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
        'print_count': 0,
        'items': const [
          {'name': 'Gin & Tonic', 'price': 699.0, 'quantity': 1},
        ],
      };

  List<Map> writesTo(String path) => [
        for (final w in writes)
          if (w.path == path) w.body as Map,
      ];

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      final b = (body as Map?) ?? const {};
      if (path == '/print/bill/settled') {
        return <String, dynamic>{'success': true, 'billId': b['bill_id'], 'jobId': 'job-1', 'destination': 'Bar'};
      }
      if (path == '/bills/customer-name') {
        final name = '${b['customer']}';
        liveCustomer = name.isEmpty ? 'Guest' : name;
        if (b.containsKey('customer_gstin')) liveGstin = b['customer_gstin'];
        if (serverKnowsAddress && b.containsKey('customer_address')) liveAddress = b['customer_address'];
        return <String, dynamic>{
          'success': true,
          'customer': name.isEmpty ? null : name,
          'customer_gstin': liveGstin,
          if (serverKnowsAddress) 'customer_address': liveAddress,
          'orders_updated': 1,
        };
      }
      if (path == '/bills/b1/customer-details') {
        final name = '${b['customer']}'.trim();
        settledCustomer = name.isEmpty ? 'Guest' : name;
        if (serverKnowsAddress && b.containsKey('customer_address')) detailAddress = b['customer_address'];
        return <String, dynamic>{
          'success': true,
          'bill_id': 'b1',
          'customer': settledCustomer,
          'customer_gstin': b['customer_gstin'],
          if (serverKnowsAddress) 'customer_address': detailAddress,
        };
      }
      return <String, dynamic>{'success': true};
    }
    if (path.startsWith('/analytics/history')) {
      return {
        'series': [
          {'month': _thisMonth, 'revenue': 4600, 'bills': 1, 'orders': 1, 'avg_bill': 4600, 'new_customers': 0, 'feedback_count': 0},
        ],
      };
    }
    if (path.startsWith('/bills/closed/b1')) return _detail;
    if (path.startsWith('/bills/closed')) return {'bills': [_row], 'total': 1, 'has_more': false};
    if (path.startsWith('/billing-counters')) {
      return {
        'counters': [
          {'id': 'c1', 'code': 'BAR', 'name': 'Bar till', 'active': true},
        ],
      };
    }
    if (path.startsWith('/reports/sales')) {
      return {'total_sales': 4600.0, 'net_sales': 4600.0, 'bill_count': 1, 'by_day': const [], 'by_method': const []};
    }
    if (path.startsWith('/reports/gst')) return {'by_rate': const []};
    if (path.startsWith('/reports/pnl')) return {'expenses_by_category': const []};
    if (path.startsWith('/reports/discounts')) return {'by_coupon': const [], 'notes': const []};
    if (path.startsWith('/expenses')) return {'expenses': const []};
    if (path.startsWith('/payroll')) return {'rows': const []};
    if (path.startsWith('/bill-for-table')) return _liveBill;
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
}

Widget _host(Widget child, DesignSystem system) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Accounting', 'History'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(
  WidgetTester tester,
  _FakeApi api,
  Widget Function(RestClient, Profile) module,
  DesignSystem system, {
  Size size = const Size(1400, 2600),
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia', 'meera', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!), system));
  await tester.pumpAndSettle();
  return api;
}

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

/// Case-insensitive exact text (Gaia upper-cases section headers).
Finder _ci(String t) => find.byWidgetPredicate((w) =>
    (w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase() == t.toLowerCase()) ||
    (w is RichText && w.text.toPlainText().toLowerCase() == t.toLowerCase()));

/// History: open this month's detail sheet the way a person does.
Future<void> _openHistoryMonth(WidgetTester tester, DesignSystem system) async {
  if (system == DesignSystem.gaia) {
    final list = tester.widget<GaiaStrataList>(find.byType(GaiaStrataList));
    list.strata.first.onTap!();
    await tester.pumpAndSettle();
  } else {
    await _tap(tester, find.text('1 bills'));
  }
  expect(_ci('MONTH'), findsWidgets, reason: 'the month sheet is open');
}

/// The bill row inside the open month sheet (the page's own list has one too).
Finder _sheetRow() => find.descendant(of: find.byType(BottomSheet), matching: find.text('Bill #57 · T1'));

Finder _settledSheet() => find.text('SETTLED BILL');
final Finder _reprint = find.text('Reprint bill');
final Finder _sheetEdit = find.byKey(const ValueKey('closed-bill-edit-customer'));
final Finder _rowEdit = find.byKey(const ValueKey('closed-bill-row-edit-customer-b1'));
final Finder _tillMove = find.byKey(const ValueKey('bill-counter-move'));
final Finder _nameField = find.byKey(const ValueKey('bill-customer-name-field'));
final Finder _addressField = find.byKey(const ValueKey('bill-customer-address-field'));
final Finder _save = find.byKey(const ValueKey('bill-customer-name-save'));
final Finder _headerEdit = find.byKey(const ValueKey('table-bill-customer-name'));

Future<void> _openT1(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

Future<void> _openPreview(WidgetTester tester) async {
  final print = find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Print bill');
  await tester.ensureVisible(print);
  await tester.pumpAndSettle();
  await tester.tap(print);
  await tester.pumpAndSettle();
  expect(_ci('Bill preview'), findsWidgets);
}

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  group('the address rule — the server\'s, mirrored', () {
    test('line breaks kept, everything else tidied, empty clears', () {
      expect(m.normaliseBillCustomerAddress(_address), _address);
      expect(m.normaliseBillCustomerAddress('  4th  Floor,\t\tPrestige Tower  \r\n\r\n   \r\n12   Residency Road\r\n'),
          '4th Floor, Prestige Tower\n12 Residency Road');
      expect(m.normaliseBillCustomerAddress('A\rB${String.fromCharCode(0x2028)}C${String.fromCharCode(0x2029)}D'), 'A\nB\nC\nD');
      expect(m.normaliseBillCustomerAddress('12 MG${String.fromCharCode(0)} Road${String.fromCharCode(0x1b)}'), '12 MG Road');
      expect(m.normaliseBillCustomerAddress('12\tMG Road'), '12 MG Road');
      for (final empty in ['', '   ', '\n\n', ' \t ']) {
        expect(m.normaliseBillCustomerAddress(empty), '');
      }
    });

    test('5 lines / 250 characters are fine; one more is the server\'s sentence, and nothing is cut', () {
      const five = 'L1\nL2\nL3\nL4\nL5';
      expect(m.billCustomerAddressError(five), isNull);
      expect(m.billCustomerAddressError('$five\nL6'), m.billCustomerAddressLimitMessage);
      final line = 'x' * 49;
      final at = [line, line, line, line, '${line}x'].join('\n');
      expect(at.length, 250);
      expect(m.billCustomerAddressError(at), isNull);
      expect(m.billCustomerAddressError('${at}y'), m.billCustomerAddressLimitMessage);
      expect(m.billCustomerAddressError('L1\n\n\nL2\n\nL3\nL4\n\nL5\n\n'), isNull, reason: 'blank lines are not lines');
      expect(m.normaliseBillCustomerAddress('y' * 300), 'y' * 300, reason: 'reported, never shortened');
      expect(m.billCustomerAddressUsage('$five\nL6'), (lines: 6, chars: 17));
    });

    test('the numbers and sentences are the contract\'s (the web pins the same)', () {
      expect(m.billCustomerAddressMaxLines, 5);
      expect(m.billCustomerAddressMaxChars, 250);
      expect(m.billCustomerAddressLimitMessage, 'Address can be at most 5 lines and 250 characters');
      expect(m.billCustomerAddressHelp, 'Up to 5 lines. Leave it empty for none. Letters outside English print as "?".');
      expect(m.billCustomerEditLabel, 'Edit name / GSTIN / address');
    });

    test('the slot: Name, GSTIN, then the address one line each, the first labelled', () {
      expect(m.billCustomerLines({'customer': 'Acme', 'customer_gstin': '29ABCDE1234F1Z5', 'customer_address': _address}), [
        'Name: Acme',
        'Customer GSTIN: 29ABCDE1234F1Z5',
        'Address: 4th Floor, Prestige Tower',
        '12 Residency Road',
        'Bengaluru 560025',
      ]);
      expect(m.billCustomerLines({'customer': 'Guest', 'customer_address': '12 MG Road'}), ['Name:', 'Address: 12 MG Road']);
      for (final none in [null, '', '  ', 'null', 'undefined']) {
        expect(m.billCustomerLines({'customer': 'Acme', 'customer_address': none}), ['Name: Acme']);
      }
      expect(m.billCustomerAddressLines('  A \n\n B\r\nC'), ['Address: A', 'B', 'C']);
    });
  });

  for (final system in DesignSystem.values) {
    group('ITEM 7 — the address on a live table [$system]', () {
      testWidgets('the dialog has the address box, seeded; the header shows its first line', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.tablesModule, system);
        await _openT1(tester);
        final header = find.byKey(const ValueKey('table-bill-customer-header'));
        // Labelled as the paper and the web strip label it.
        expect(find.descendant(of: header, matching: find.text('Address: 4th Floor, Prestige Tower (+2 more)')), findsOneWidget);
        expect(find.descendant(of: header, matching: find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Edit name / GSTIN / address')),
            findsOneWidget);
        await _tap(tester, _headerEdit);
        expect(find.text('Name / GSTIN / address on bill · Table T1'), findsOneWidget);
        expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), findsNWidgets(3));
        expect(tester.widget<TextField>(_addressField).controller!.text, _address);
        final box = tester.widget<TextField>(_addressField);
        expect(box.maxLength, isNull, reason: 'refused, never cut: no maxLength');
        expect(box.keyboardType, TextInputType.multiline);
        expect(box.textInputAction, TextInputAction.newline, reason: 'Enter is a new line, never Save');
        expect(find.text(m.billCustomerAddressHelp), findsOneWidget);
        expect(find.text('3/5 lines · 60/250'), findsOneWidget);
        expect(api.writes, isEmpty);
      }, variant: _platforms);

      testWidgets('a changed address is sent normalised; the re-read header shows it', (tester) async {
        final api = await _mount(tester, _FakeApi(liveAddress: null), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        await tester.enterText(_addressField, '  Tower B \n\n Whitefield  ');
        await tester.pump();
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/customer-name').single,
            {'table_name': 'T1', 'customer': 'Acme Pvt Ltd', 'customer_address': 'Tower B\nWhitefield'});
        expect(find.textContaining('Address added to the bill.'), findsOneWidget);
        expect(find.text('Address: Tower B (+1 more)'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('an UNCHANGED address is not sent (a name fix is not an address write)', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        await tester.enterText(_nameField, 'Acme Ltd');
        // Typing in the box and putting it back is not a change either.
        await tester.enterText(_addressField, 'x');
        await tester.enterText(_addressField, _address);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/customer-name').single, {'table_name': 'T1', 'customer': 'Acme Ltd'});
      }, variant: _platforms);

      testWidgets('an emptied address is sent as null, which clears it', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        await tester.enterText(_addressField, '   ');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/customer-name').single, {'table_name': 'T1', 'customer': 'Acme Pvt Ltd', 'customer_address': null});
        expect(find.textContaining('Address removed.'), findsOneWidget);
        expect(find.byKey(const ValueKey('table-bill-customer-address')), findsNothing);
      }, variant: _platforms);

      testWidgets('over the limit: the server\'s sentence at once, Save off, nothing written, nothing cut', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        const six = 'L1\nL2\nL3\nL4\nL5\nL6';
        await tester.enterText(_addressField, six);
        await tester.pump();
        expect(find.text(m.billCustomerAddressLimitMessage), findsOneWidget);
        expect(tester.widget<FilledButton>(_save).onPressed, isNull);
        expect(tester.widget<TextField>(_addressField).controller!.text, six, reason: 'never cut');
        final long = 'y' * 300;
        await tester.enterText(_addressField, long);
        await tester.pump();
        expect(tester.widget<TextField>(_addressField).controller!.text, long);
        expect(find.text('1/5 lines · 300/250'), findsOneWidget);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writes, isEmpty);
        expect(find.byType(AlertDialog), findsOneWidget, reason: 'the dialog stays open');
      }, variant: _platforms);

      testWidgets('a server before item 7 that ignores the address is called out', (tester) async {
        final api = await _mount(tester, _FakeApi(liveKnowsAddress: false, serverKnowsAddress: false), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        expect(tester.widget<TextField>(_addressField).controller!.text, '');
        await tester.enterText(_addressField, 'Tower B');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect((api.writesTo('/bills/customer-name').single)['customer_address'], 'Tower B');
        expect(find.textContaining(m.billCustomerAddressNotSaved), findsOneWidget);
      }, variant: _platforms);

      testWidgets('…and against it an untouched box sends nothing at all', (tester) async {
        final api = await _mount(tester, _FakeApi(liveKnowsAddress: false, serverKnowsAddress: false), m.tablesModule, system);
        await _openT1(tester);
        await _tap(tester, _headerEdit);
        await tester.enterText(_nameField, 'Acme Ltd');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/customer-name').single, {'table_name': 'T1', 'customer': 'Acme Ltd'});
      }, variant: _platforms);

      testWidgets('the preview prints the address under the GSTIN and above the date — no duplicate-key crash', (tester) async {
        // Two identical lines: the case a text-derived key would collide on.
        await _mount(tester, _FakeApi(liveAddress: 'Bengaluru\nBengaluru\nKarnataka 560025'), m.tablesModule, system);
        await _openT1(tester);
        await _openPreview(tester);
        expect(tester.takeException(), isNull);
        final inPreview = find.byType(Dialog);
        Finder t(String s) => find.descendant(of: inPreview, matching: find.text(s));
        expect(t('Name: Acme Pvt Ltd'), findsOneWidget);
        expect(t('Customer GSTIN: 29ABCDE1234F1Z5'), findsOneWidget);
        expect(t('Address: Bengaluru'), findsOneWidget);
        expect(t('Bengaluru'), findsOneWidget);
        expect(t('Karnataka 560025'), findsOneWidget);
        double y(Finder f) => tester.getTopLeft(f).dy;
        expect(y(t('Address: Bengaluru')), greaterThan(y(t('Customer GSTIN: 29ABCDE1234F1Z5'))));
        expect(y(t('Bengaluru')), greaterThan(y(t('Address: Bengaluru'))));
        expect(y(t('Karnataka 560025')), greaterThan(y(t('Bengaluru'))));
        expect(y(t('Karnataka 560025')), lessThan(y(find.descendant(of: inPreview, matching: find.textContaining('Dine In: T1')))));
        // The first two keys are the ones tools already read.
        expect(find.byKey(const ValueKey('bill-preview-customer-name')), findsOneWidget);
        expect(find.byKey(const ValueKey('bill-preview-customer-gstin')), findsOneWidget);
        expect(find.byKey(const ValueKey('bill-preview-customer-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('bill-preview-customer-4')), findsOneWidget);
      }, variant: _platforms);

      testWidgets('a scoped waiter reads the address on their table but cannot edit it', (tester) async {
        final api = _FakeApi(role: 'waiter', actions: const [_addOrders], waiterOnly: true);
        await _mount(tester, api, m.tablesModule, system);
        await _openT1(tester);
        // Not money (C4), so a waiter's scoping leaves it on their table.
        expect(find.byKey(const ValueKey('table-bill-customer-address')), findsOneWidget);
        expect(_headerEdit, findsNothing);
        expect(find.text('Edit name / GSTIN / address'), findsNothing);
      }, variant: _platforms);

      testWidgets('the header fits a 360dp phone: name, GSTIN, address and the button, no overflow', (tester) async {
        final api = _FakeApi()
          ..liveCustomer = 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer'
          ..liveAddress = 'Flat 1204, Tower B, Brigade Metropolis Whitefield Main Road\nBengaluru 560048';
        await _mount(tester, api, m.tablesModule, system, size: const Size(360, 1600));
        await _openT1(tester);
        expect(tester.takeException(), isNull);
        final header = find.byKey(const ValueKey('table-bill-customer-header'));
        expect(header, findsOneWidget);
        expect(find.descendant(of: header, matching: _headerEdit), findsOneWidget);
        // On a phone the button sits UNDER the lines, so the name keeps its width.
        final name = find.byKey(const ValueKey('table-bill-customer'));
        expect(tester.getTopLeft(_headerEdit).dy, greaterThan(tester.getBottomLeft(name).dy));
        expect(tester.getSize(name).width, greaterThan(200));
        expect(tester.getRect(_headerEdit).right, lessThanOrEqualTo(360));
        await _tap(tester, _headerEdit);
        expect(tester.takeException(), isNull, reason: 'the dialog fits the phone too');
        expect(_addressField, findsOneWidget);
      }, variant: _platforms);
    });

    group('ITEM 7 — the address on a settled bill [$system]', () {
      testWidgets('the ROW edit never wipes what it cannot see: the list carries no address, so none is sent',
          (tester) async {
        final api = await _mount(tester, _FakeApi(), m.accountingModule, system);
        await _tap(tester, _rowEdit);
        expect(tester.widget<TextField>(_addressField).controller!.text, '');
        await tester.enterText(_nameField, 'Acme Ltd');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/b1/customer-details').single,
            {'customer': 'Acme Ltd', 'customer_gstin': '29ABCDE1234F1Z5'});
        expect(find.text('Name and GSTIN updated on Bill #57.'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('the SHEET shows the address as the paper prints it, and sends it only when it changes',
          (tester) async {
        final api = await _mount(tester, _FakeApi(), m.accountingModule, system);
        await _tap(tester, find.text('Bill #57 · T1'));
        expect(_settledSheet(), findsOneWidget);
        expect(find.text('Address: 4th Floor, Prestige Tower'), findsOneWidget);
        expect(find.text('12 Residency Road'), findsOneWidget);
        await _tap(tester, find.descendant(of: _sheetEdit, matching: find.text('Edit name / GSTIN / address')));
        expect(tester.widget<TextField>(_addressField).controller!.text, _address);
        await tester.enterText(_addressField, 'Tower B\nWhitefield');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/b1/customer-details').single,
            {'customer': 'Acme Pvt Ltd', 'customer_gstin': '29ABCDE1234F1Z5', 'customer_address': 'Tower B\nWhitefield'});
        expect(find.text('Name, GSTIN and address updated on Bill #57.'), findsOneWidget);
        expect(find.text('Address: Tower B'), findsOneWidget, reason: 'the sheet re-read the bill');
        expect(find.text('Whitefield'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('a name-only fix from the sheet does NOT re-send the address it knows (no 503 before 054)',
          (tester) async {
        final api = await _mount(tester, _FakeApi(), m.accountingModule, system);
        await _tap(tester, find.text('Bill #57 · T1'));
        await _tap(tester, find.descendant(of: _sheetEdit, matching: find.text('Edit name / GSTIN / address')));
        await tester.enterText(_nameField, 'Acme Ltd');
        // Touched and put back: still not a change.
        await tester.enterText(_addressField, 'x');
        await tester.enterText(_addressField, _address);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.writesTo('/bills/b1/customer-details').single,
            {'customer': 'Acme Ltd', 'customer_gstin': '29ABCDE1234F1Z5'});
        expect(find.text('Name and GSTIN updated on Bill #57.'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('a settled bill with no address shows no Address line; adding one from its sheet sends it',
          (tester) async {
        final api = await _mount(tester, _FakeApi(detailAddress: null), m.accountingModule, system);
        await _tap(tester, find.text('Bill #57 · T1'));
        expect(find.textContaining('Address:'), findsNothing);
        await _tap(tester, find.descendant(of: _sheetEdit, matching: find.text('Edit name / GSTIN / address')));
        expect(tester.widget<TextField>(_addressField).controller!.text, '');
        await tester.enterText(_addressField, '12 MG Road');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect((api.writesTo('/bills/b1/customer-details').single)['customer_address'], '12 MG Road');
        expect(find.text('Address: 12 MG Road'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('typed into from a row, the address IS sent', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.accountingModule, system);
        await _tap(tester, _rowEdit);
        await tester.enterText(_addressField, '12 MG Road');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect((api.writesTo('/bills/b1/customer-details').single)['customer_address'], '12 MG Road');
      }, variant: _platforms);

      testWidgets('a server that ignores the address is called out on a settled bill too', (tester) async {
        await _mount(tester, _FakeApi(serverKnowsAddress: false), m.accountingModule, system);
        await _tap(tester, _rowEdit);
        await tester.enterText(_addressField, '12 MG Road');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(find.textContaining(m.billCustomerAddressNotSaved), findsOneWidget);
      }, variant: _platforms);
    });

    group('ITEM 8 — Reprint in History [$system]', () {
      testWidgets('admin: History -> month -> bill shows Reprint and the edit; a tap prints through the settled route',
          (tester) async {
        final api = await _mount(tester, _FakeApi(), m.historyModule, system);
        await _openHistoryMonth(tester, system);
        expect(find.descendant(of: find.byType(BottomSheet), matching: _rowEdit), findsOneWidget,
            reason: 'the row edit is there, as in Accounting');
        await _tap(tester, _sheetRow());
        expect(_settledSheet(), findsOneWidget);
        expect(api.calls, contains('GET /bills/closed/b1'));
        expect(_reprint, findsOneWidget);
        expect(_sheetEdit, findsOneWidget);
        expect(find.text('Address: 4th Floor, Prestige Tower'), findsOneWidget);
        await _tap(tester, _reprint);
        expect(api.writesTo('/print/bill/settled'), [
          {'bill_id': 'b1'},
        ]);
        expect(find.text('Reprinting at Bar.'), findsOneWidget);
      }, variant: _platforms);

      testWidgets('History never offers "Move to another till" — Accounting still does', (tester) async {
        await _mount(tester, _FakeApi(), m.historyModule, system);
        await _openHistoryMonth(tester, system);
        await _tap(tester, _sheetRow());
        expect(_reprint, findsOneWidget);
        expect(_tillMove, findsNothing);
        expect(find.text('Move to another till'), findsNothing);

        await _mount(tester, _FakeApi(), m.accountingModule, system);
        await _tap(tester, find.text('Bill #57 · T1'));
        expect(_reprint, findsOneWidget);
        expect(_tillMove, findsOneWidget, reason: 'the control this test proves absent in History exists in Accounting');
      }, variant: _platforms);

      testWidgets('a manager holding exactly History\'s permission reprints from it', (tester) async {
        final api = await _mount(tester, _FakeApi(role: 'manager', actions: const [_accounting, _viewBill]), m.historyModule, system);
        await _openHistoryMonth(tester, system);
        await _tap(tester, _sheetRow());
        expect(_reprint, findsOneWidget);
        await _tap(tester, _reprint);
        expect(api.writesTo('/print/bill/settled').single, {'bill_id': 'b1'});
        expect(_tillMove, findsNothing, reason: 'no payment permission, and History never shows it anyway');
      }, variant: _platforms);

      testWidgets('without the permission there is no Reprint and no edit in History', (tester) async {
        final api = await _mount(tester, _FakeApi(role: 'captain', actions: const [_viewBill, _addOrders]), m.historyModule, system);
        await _openHistoryMonth(tester, system);
        expect(_rowEdit, findsNothing);
        await _tap(tester, _sheetRow());
        expect(_settledSheet(), findsOneWidget);
        expect(_reprint, findsNothing);
        // The edit widget is there and draws nothing without the permission.
        expect(find.descendant(of: _sheetEdit, matching: find.byType(OutlinedButton)), findsNothing);
        expect(find.text('Edit name / GSTIN / address'), findsNothing);
        expect(api.writes, isEmpty);
      }, variant: _platforms);

      testWidgets('the History PAGE lists the window\'s settled bills, searchable, and its rows reprint', (tester) async {
        final api = await _mount(tester, _FakeApi(), m.historyModule, system);
        final section = find.byKey(const ValueKey('history-settled-bills'));
        await tester.scrollUntilVisible(section, 300, scrollable: find.byType(Scrollable).first, maxScrolls: 200);
        await tester.pumpAndSettle();
        expect(find.descendant(of: section, matching: _ci('Settled bills')), findsWidgets);
        final pageRow = find.descendant(of: section, matching: find.text('Bill #57 · T1'));
        expect(pageRow, findsOneWidget);
        // The row says whose bill it was (the list now carries the name).
        expect(find.descendant(of: section, matching: find.text('Acme Pvt Ltd')), findsOneWidget);

        // Search: sent to the server, and cleared with the x.
        final search = find.byKey(const ValueKey('history-bill-search'));
        await tester.ensureVisible(search);
        await tester.enterText(search, '57');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(api.calls.any((c) => c.startsWith('GET /bills/closed?') && c.contains('search=57')), isTrue);
        await tester.tap(find.descendant(of: section, matching: find.byTooltip('Clear search')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, '');

        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('history-settled-bills')), matching: find.text('Bill #57 · T1')));
        expect(_settledSheet(), findsOneWidget);
        await _tap(tester, _reprint);
        expect(api.writesTo('/print/bill/settled').single, {'bill_id': 'b1'});
        expect(_tillMove, findsNothing);
      }, variant: _platforms);

      testWidgets('History fits a 360dp phone with its bill list and the reprint sheet', (tester) async {
        await _mount(tester, _FakeApi(), m.historyModule, system, size: const Size(360, 1600));
        expect(tester.takeException(), isNull);
        await _openHistoryMonth(tester, system);
        await _tap(tester, _sheetRow());
        expect(tester.takeException(), isNull);
        expect(_reprint, findsOneWidget);
      }, variant: _platforms);
    });
  }

  group('wiring — History reaches the settled reprint (the "built but never called" guard)', () {
    final modules = File('lib/screens/modules.dart').readAsStringSync().replaceAll('\r\n', '\n');
    final reports = File('lib/screens/reports.dart').readAsStringSync().replaceAll('\r\n', '\n');
    String body(String src, String start) {
      final at = src.indexOf(start);
      expect(at, greaterThan(-1), reason: start);
      final end = src.indexOf('\n}\n', at);
      return src.substring(at, end < 0 ? src.length : end);
    }

    test('historyModule hands the profile down, and both month taps pass it on', () {
      expect(modules, contains('Widget historyModule(RestClient rest, Profile p) => _HistoryModule(rest: rest, profile: p);'));
      expect(RegExp(r'_MonthDetailSheet\(\s*rest: rest,\s*month: m,\s*title: pretty\([^)]*\),\s*profile: profile,\s*\)')
          .allMatches(modules)
          .length, 2);
    });

    test('the month sheet and the page list open bills as HISTORY with the profile', () {
      final sheet = body(modules, 'class _MonthDetailSheet extends StatelessWidget');
      expect(sheet, matches(RegExp(r'_ClosedBillsList\([^;]*profile: profile,\s*surface: _ClosedBillSurface\.history')));
      final page = body(modules, 'class _HistorySettledBillsState extends State<_HistorySettledBills>');
      expect(page, matches(RegExp(r'_ClosedBillsList\([^;]*profile: widget\.profile,\s*surface: _ClosedBillSurface\.history')));
      expect(body(modules, 'Widget _historyBody('), contains('_HistorySettledBills('));
    });

    test('the sheet: Reprint and the edit for any write surface; the till move for Accounting only', () {
      final sheet = body(modules, 'class _ClosedBillSheet extends StatelessWidget');
      expect(sheet, contains('if (profile != null) ...['));
      expect(sheet, contains('_ReprintSettledBillButton('));
      expect(sheet, contains('_EditSettledBillCustomerButton('));
      expect(sheet, matches(RegExp(r'if \(surface == _ClosedBillSurface\.accounting\)\s*misBillCounterAction\(')));
      final button = body(modules, 'class _ReprintSettledBillButtonState extends State<_ReprintSettledBillButton>');
      expect(button, contains("widget.rest.post('/print/bill/settled', {'bill_id': widget.billId})"));
    });

    test('the Reports drill-down stays read-only: the body alone, no sheet, no reprint', () {
      final drill = body(reports, 'void _misOpenBill(');
      expect(drill, contains('_closedBillBody('));
      expect(drill, isNot(contains('_ClosedBillSheet')));
      expect(drill, isNot(contains('_ReprintSettledBillButton')));
      expect(drill, isNot(contains('profile')));
    });

    test('platform sanity', () {
      expect(defaultTargetPlatform, isNotNull);
    });
  });
}
