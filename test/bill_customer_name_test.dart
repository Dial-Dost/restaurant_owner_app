// REQUIREMENT 6.5 — "Edit guest name" on the table sheet's bill.
//
// Pins the app to the web's H6 dialog (bill-actions.tsx) and the server's
// POST /bills/customer-name:
//   * seeded with the name already on the bill, never with the "Guest"
//     placeholder;
//   * Save posts {table_name, customer}, trimmed and whitespace-collapsed, and
//     the bill is re-read so the new name reaches the sheet and the preview;
//   * empty clears the name; the box stops at 120 characters, as the server does;
//   * the server's own sentence is what the person reads when it refuses;
//   * offline it is refused, never queued;
//   * hidden from a scoped waiter (the web does not show it to one either) and
//     from anybody without "Add Orders", the action the route is validated on.
//
// ROUND 2 ITEM 1 — the same dialog carries the customer's GSTIN, and the entry
// point is at the TOP of the sheet with the name and GSTIN beside it:
//   * the GSTIN is normalised (upper-cased, spaces stripped) and checked against
//     the server's pattern before any write; empty clears it (null);
//   * `customer_gstin` is sent only when it changed, so a name-only fix is the
//     request it always was;
//   * a server a release behind that ignores the field is called out.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

const String _addOrders = '4ad474d4-5230-449c-874f-6a238b833bca';

Map<String, dynamic> _bill(Object? customer, [Object? gstin]) => {
      'bill_id': 'bill-1',
      'customer': customer,
      'customer_gstin': gstin,
      'total_amt': 699.0,
      'subtotal': 699.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
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
    };

/// How the fake server answers POST /bills/customer-name.
enum _Answer { ok, refused, routeMissing, offline, gstinUnknown }

class _FakeApi extends ApiClient {
  _FakeApi({required this.customer, required this.actions, this.gstin, this.role = 'admin', this.waiterOnly, this.answer = _Answer.ok});

  /// The name the bill carries; a successful save changes it, so a re-read
  /// shows whether the sheet really went back to the server.
  Object? customer;
  Object? gstin;
  final List<String> actions;
  final String role;
  final bool? waiterOnly;
  final _Answer answer;
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
          'employeeUsername': 'manager01',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
          'actions_set': actions,
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      if (path == '/bills/customer-name') {
        switch (answer) {
          case _Answer.refused:
            throw ApiException('This table has no running orders to name.', 400);
          case _Answer.routeMissing:
            throw ApiException('Cannot POST /bills/customer-name', 404);
          case _Answer.offline:
            throw const SocketException('Network is unreachable');
          case _Answer.gstinUnknown:
            // A server a release behind: saves the name, has never heard of
            // `customer_gstin`, and does not answer it.
            final name = '${(body as Map)['customer']}';
            customer = name.isEmpty ? 'Guest' : name;
            return <String, dynamic>{'success': true, 'customer': name.isEmpty ? null : name, 'orders_updated': 1};
          case _Answer.ok:
            final b = body as Map;
            final name = '${b['customer']}';
            customer = name.isEmpty ? 'Guest' : name;
            if (b.containsKey('customer_gstin')) gstin = b['customer_gstin'];
            return <String, dynamic>{
              'success': true,
              'customer': name.isEmpty ? null : name,
              'customer_gstin': gstin,
              'orders_updated': 1,
            };
        }
      }
      return <String, dynamic>{'success': true};
    }
    if (path.startsWith('/bill-for-table')) return _bill(customer, gstin);
    if (path.startsWith('/get-tables')) {
      return [
        {
          'table_name': 'T1',
          'capacity': 4,
          'max_capacity': 4,
          'section': 'Main',
          'occupied': true,
          'has_order': true,
          'reserved': false,
          'covers': 2,
          'table_total': 699.0,
        },
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
    if (path.startsWith('/table-assignments') || path.startsWith('/get-bookings') || path.startsWith('/menu')) {
      return <dynamic>[];
    }
    throw ApiException('No fake route for $path', 404);
  }
}

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<void> _openT1(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'ravi', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

final Finder _button = find.byKey(const ValueKey('table-bill-customer-name'));
final Finder _field = find.byKey(const ValueKey('bill-customer-name-field'));
final Finder _save = find.byKey(const ValueKey('bill-customer-name-save'));
final Finder _gstinField = find.byKey(const ValueKey('bill-customer-gstin-field'));
final Finder _headerGstin = find.byKey(const ValueKey('table-bill-customer-gstin'));

Future<void> _openDialog(WidgetTester tester) async {
  await tester.ensureVisible(_button);
  await tester.tap(_button);
  await tester.pumpAndSettle();
}

String _headerName(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('table-bill-customer'))).data ?? '';

String _fieldText(WidgetTester tester) => tester.widget<TextField>(_field).controller!.text;

List<({String method, String path, Object? body})> _nameWrites(_FakeApi api) =>
    api.writes.where((w) => w.path == '/bills/customer-name').toList();

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  group('the rules — mirrored from the web and the server', () {
    test('the seed is the current name, never the placeholder', () {
      expect(m.billCustomerNameSeed('Mr Sharma'), 'Mr Sharma');
      expect(m.billCustomerNameSeed('  Mr Sharma '), 'Mr Sharma');
      expect(m.billCustomerNameSeed('Guest'), '');
      expect(m.billCustomerNameSeed('qr guest'), '');
      expect(m.billCustomerNameSeed(null), '');
      expect(m.billCustomerNameSeed('Guesthouse party'), 'Guesthouse party');
    });

    test('normalised as the server stores it: trimmed, collapsed, capped at 120', () {
      expect(m.normaliseBillCustomerName('  Mr   Sharma  '), 'Mr Sharma');
      expect(m.normaliseBillCustomerName('   '), '');
      expect(m.billCustomerNameMaxLength, 120);
      expect(m.normaliseBillCustomerName('x' * 400), hasLength(120));
    });

    test('a GSTIN is upper-cased and stripped of spaces; empty clears', () {
      expect(m.normaliseBillCustomerGstin(' 29abcde1234f1z5 '), '29ABCDE1234F1Z5');
      expect(m.normaliseBillCustomerGstin('29 ABCDE 1234F 1Z5'), '29ABCDE1234F1Z5');
      expect(m.normaliseBillCustomerGstin('   '), '');
    });

    test("a GSTIN is checked against the server's pattern, in the server's words", () {
      expect(m.billCustomerGstinError(''), isNull, reason: 'empty clears it');
      expect(m.billCustomerGstinError('29abcde1234f1z5'), isNull);
      expect(m.billCustomerGstinError('27AAPFU0939F1ZV'), isNull);
      expect(m.billCustomerGstinError('29ABCDE1234F1Z'), m.billCustomerGstinInvalidMessage, reason: '14 chars');
      expect(m.billCustomerGstinError('29ABCDE1234F1Y5'), isNotNull, reason: 'the 14th must be Z');
      expect(m.billCustomerGstinError('29ABCDE1234F0Z5'), isNotNull, reason: 'the entity number is 1-9 or A-Z');
      expect(m.billCustomerGstinError('ABABCDE1234F1Z5'), isNotNull, reason: 'the state code is two digits');
      expect(m.billCustomerGstinInvalidMessage, 'GSTIN must be 15 characters, e.g. 29ABCDE1234F1Z5');
    });

    // Worded as the client's printed bill words it — "Name:" — and, like that
    // bill, a walk-in's slot is left BLANK rather than filled with the "Guest"
    // placeholder, which printed reads as a name somebody wrote down.
    test('the customer slot: Name (blank for a walk-in), then Customer GSTIN when set', () {
      expect(m.billCustomerLines({'customer': 'Acme Ltd', 'customer_gstin': '29ABCDE1234F1Z5'}),
          ['Name: Acme Ltd', 'Customer GSTIN: 29ABCDE1234F1Z5']);
      expect(m.billCustomerLines({'customer': 'Guest', 'customer_gstin': '29ABCDE1234F1Z5'}),
          ['Name:', 'Customer GSTIN: 29ABCDE1234F1Z5']);
      expect(m.billCustomerLines({'customer': 'QR Guest', 'customer_gstin': null}), ['Name:']);
      expect(m.billCustomerLines({'customer': '', 'customer_gstin': ''}), ['Name:']);
      expect(m.billCustomerLines({'customer': null}), ['Name:']);
      // escpos.ts `present()` drops a stored "null"; so does the slot.
      expect(m.billCustomerLines({'customer': 'null', 'customer_gstin': 'null'}), ['Name:']);
      expect(m.billCustomerLines({'customer': 'Mr Sharma'}), ['Name: Mr Sharma']);
      // Never a placeholder, in any casing, anywhere in the slot.
      for (final placeholder in ['Guest', 'guest', 'QR Guest', 'qr guest']) {
        expect(m.billCustomerLines({'customer': placeholder}).join(' '), isNot(matches(RegExp('guest', caseSensitive: false))));
      }
    });
  });

  group('Customer GSTIN on a live table — round 2 item 1', () {
    testWidgets('the name and GSTIN sit at the TOP of the sheet, above the table controls', (tester) async {
      final api = _FakeApi(customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5', actions: const ['*']);
      await _openT1(tester, api);
      expect(_headerName(tester), 'Acme Ltd');
      expect(find.text('GSTIN 29ABCDE1234F1Z5'), findsOneWidget);
      final header = tester.getTopLeft(find.byKey(const ValueKey('table-bill-customer-header'))).dy;
      expect(header, lessThan(tester.getTopLeft(find.text('Split')).dy));
      expect(header, lessThan(tester.getTopLeft(find.text('Customers scan to order & pay')).dy));
      // One entry point, not two: the old button in the bill wrap is gone.
      expect(_button, findsOneWidget);
      expect(find.textContaining('Edit guest name'), findsNothing);
    });

    testWidgets('Save sends the GSTIN normalised, then the re-read shows it', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      expect(_headerGstin, findsNothing);
      await _openDialog(tester);
      await tester.enterText(_field, 'Acme Ltd');
      await tester.enterText(_gstinField, '29 abcde 1234f 1z5');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      expect(_nameWrites(api).single.body,
          {'table_name': 'T1', 'customer': 'Acme Ltd', 'customer_gstin': '29ABCDE1234F1Z5'});
      expect(_headerName(tester), 'Acme Ltd');
      expect(find.text('GSTIN 29ABCDE1234F1Z5'), findsOneWidget);
      expect(find.text("Name updated — this table's bill now prints for Acme Ltd. Customer GSTIN: 29ABCDE1234F1Z5."),
          findsOneWidget);
    });

    testWidgets('the dialog opens seeded with the GSTIN already on the bill', (tester) async {
      final api = _FakeApi(customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      expect(tester.widget<TextField>(_gstinField).controller!.text, '29ABCDE1234F1Z5');
    });

    testWidgets('a malformed GSTIN is refused in the box and nothing is written', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_gstinField, '29ABCDE1234');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('GSTIN must be 15 characters, e.g. 29ABCDE1234F1Z5'), findsOneWidget);
      expect(find.text('Name / GSTIN / address on bill · Table T1'), findsOneWidget, reason: 'the dialog stays open');
      expect(_nameWrites(api), isEmpty);
    });

    testWidgets('an emptied GSTIN is sent as null, which clears it', (tester) async {
      final api = _FakeApi(customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_gstinField, '  ');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(_nameWrites(api).single.body, {'table_name': 'T1', 'customer': 'Acme Ltd', 'customer_gstin': null});
      expect(_headerGstin, findsNothing);
      expect(find.textContaining('Customer GSTIN removed.'), findsOneWidget);
    });

    testWidgets('an unchanged GSTIN is not sent at all', (tester) async {
      final api = _FakeApi(customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Acme Pvt Ltd');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(_nameWrites(api).single.body, {'table_name': 'T1', 'customer': 'Acme Pvt Ltd'});
    });

    testWidgets('a server that ignores the GSTIN is called out, not trusted', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*'], answer: _Answer.gstinUnknown);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Acme Ltd');
      await tester.enterText(_gstinField, '29ABCDE1234F1Z5');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.textContaining('The GSTIN was not saved: this server has not finished updating.'), findsOneWidget);
    });

    testWidgets('the header fits a phone: a long name and a GSTIN beside the button, no overflow', (tester) async {
      final api = _FakeApi(customer: 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer', gstin: '29ABCDE1234F1Z5', actions: const ['*']);
      await _openT1(tester, api);
      tester.view.physicalSize = const Size(400, 3000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_button, findsOneWidget);
      expect(find.text('GSTIN 29ABCDE1234F1Z5'), findsOneWidget);
    });

    testWidgets('a scoped waiter reads the name and GSTIN but cannot edit them', (tester) async {
      final api = _FakeApi(
          customer: 'Acme Ltd', gstin: '29ABCDE1234F1Z5', actions: const [_addOrders], role: 'waiter', waiterOnly: true);
      await _openT1(tester, api);
      expect(_headerName(tester), 'Acme Ltd');
      expect(find.text('GSTIN 29ABCDE1234F1Z5'), findsOneWidget);
      expect(_button, findsNothing);
    });
  });

  group('Edit name / GSTIN at the top of the table sheet — 6.5', () {
    testWidgets('the dialog opens seeded with the name already on the bill', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['*']);
      await _openT1(tester, api);
      expect(_button, findsOneWidget);
      expect(_headerName(tester), 'Mr Sharma');

      await _openDialog(tester);
      expect(find.text('Name / GSTIN / address on bill · Table T1'), findsOneWidget);
      expect(_fieldText(tester), 'Mr Sharma');
    });

    testWidgets('an unnamed bill opens EMPTY, not seeded with "Guest"', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      expect(_headerName(tester), 'No guest name on the bill');
      await _openDialog(tester);
      expect(_fieldText(tester), '');
    });

    testWidgets('Save posts the table and the trimmed name, then re-reads the bill', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      final billReadsBefore = api.calls.where((c) => c.startsWith('GET /bill-for-table')).length;

      await _openDialog(tester);
      await tester.enterText(_field, '  Mr   Sharma ');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      final writes = _nameWrites(api);
      expect(writes, hasLength(1));
      expect(writes.single.method, 'POST');
      expect(writes.single.body, {'table_name': 'T1', 'customer': 'Mr Sharma'});
      expect(api.calls.where((c) => c.startsWith('GET /bill-for-table')).length, greaterThan(billReadsBefore),
          reason: 'the bill is re-read so the preview and the print carry the new name');
      expect(find.text("Name updated — this table's bill now prints for Mr Sharma."), findsOneWidget);
      // The re-read reached the sheet.
      expect(_headerName(tester), 'Mr Sharma');
    });

    testWidgets('Cancel writes nothing', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Somebody else');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(_nameWrites(api), isEmpty);
    });

    testWidgets('an empty name CLEARS it, as on the web', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('bill-customer-name-clear')));
      await tester.pump();
      expect(_fieldText(tester), '');
      await tester.enterText(_field, '    ');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      // Clear clears all THREE boxes. This fixture's bill carries no
      // `customer_address` key (a server before client item 7), so the cleared
      // address box goes out as null — which such a server ignores.
      expect(_nameWrites(api).single.body, {'table_name': 'T1', 'customer': '', 'customer_address': null});
      expect(find.text('Name cleared — the bill will print without a guest name.'), findsOneWidget);
      expect(_headerName(tester), 'No guest name on the bill');
    });

    testWidgets('the box stops at 120 characters, and 120 is what is sent', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'A' * 200);
      await tester.pump();
      expect(_fieldText(tester), hasLength(120));
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect((_nameWrites(api).single.body as Map)['customer'], 'A' * 120);
      expect(tester.takeException(), isNull);
    });

    testWidgets("a refusal shows the server's own sentence", (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['*'], answer: _Answer.refused);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Mr Verma');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('This table has no running orders to name.'), findsOneWidget);
      expect(_headerName(tester), 'Mr Sharma', reason: 'nothing changed');
    });

    testWidgets('a server without the route says so, in the web\'s words', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*'], answer: _Answer.routeMissing);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Mr Verma');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.textContaining('This server has not finished updating'), findsOneWidget);
    });

    testWidgets('offline it is refused with a sentence about the name, and never queued', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*'], answer: _Answer.offline);
      await _openT1(tester, api);
      await _openDialog(tester);
      await tester.enterText(_field, 'Mr Verma');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('Changing the name on a bill needs a connection — reconnect and try again.'), findsOneWidget);
      expect(Outbox.instance.entries, isEmpty);
      expect(OutboxPolicy.decide('POST', '/bills/customer-name').queueable, isFalse);
    });

    testWidgets('a non-admin holding Add Orders gets it', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const [_addOrders], role: 'captain');
      await _openT1(tester, api);
      expect(_button, findsOneWidget);
    });

    testWidgets('hidden without Add Orders', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['view-only'], role: 'captain');
      await _openT1(tester, api);
      // The rest of the bill controls are there, so it is the permission that hid it.
      expect(find.text('Split'), findsOneWidget);
      expect(_button, findsNothing);
    });

    testWidgets('hidden from a scoped waiter, as on the web, even holding Add Orders', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const [_addOrders], role: 'waiter', waiterOnly: true);
      await _openT1(tester, api);
      expect(_button, findsNothing);
      expect(find.textContaining('Edit name / GSTIN'), findsNothing);
    });
  });
}
