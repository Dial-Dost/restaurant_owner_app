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

Map<String, dynamic> _bill(Object? customer) => {
      'bill_id': 'bill-1',
      'customer': customer,
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
enum _Answer { ok, refused, routeMissing, offline }

class _FakeApi extends ApiClient {
  _FakeApi({required this.customer, required this.actions, this.role = 'admin', this.waiterOnly, this.answer = _Answer.ok});

  /// The name the bill carries; a successful save changes it, so a re-read
  /// shows whether the sheet really went back to the server.
  Object? customer;
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
          case _Answer.ok:
            final name = '${(body as Map)['customer']}';
            customer = name.isEmpty ? 'Guest' : name;
            return <String, dynamic>{'success': true, 'customer': name.isEmpty ? null : name, 'orders_updated': 1};
        }
      }
      return <String, dynamic>{'success': true};
    }
    if (path.startsWith('/bill-for-table')) return _bill(customer);
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

Future<void> _openDialog(WidgetTester tester) async {
  await tester.ensureVisible(_button);
  await tester.tap(_button);
  await tester.pumpAndSettle();
}

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
  });

  group('Edit guest name on the table sheet — 6.5', () {
    testWidgets('the dialog opens seeded with the name already on the bill', (tester) async {
      final api = _FakeApi(customer: 'Mr Sharma', actions: const ['*']);
      await _openT1(tester, api);
      expect(_button, findsOneWidget);
      expect(find.text('Edit guest name · Mr Sharma'), findsOneWidget);

      await _openDialog(tester);
      expect(find.text('Name on bill · Table T1'), findsOneWidget);
      expect(_fieldText(tester), 'Mr Sharma');
    });

    testWidgets('an unnamed bill opens EMPTY, not seeded with "Guest"', (tester) async {
      final api = _FakeApi(customer: 'Guest', actions: const ['*']);
      await _openT1(tester, api);
      expect(find.text('Edit guest name'), findsOneWidget);
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
      expect(find.text('Edit guest name · Mr Sharma'), findsOneWidget);
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

      expect(_nameWrites(api).single.body, {'table_name': 'T1', 'customer': ''});
      expect(find.text('Name cleared — the bill will print without a guest name.'), findsOneWidget);
      expect(find.text('Edit guest name'), findsOneWidget);
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
      expect(find.text('Edit guest name · Mr Sharma'), findsOneWidget, reason: 'nothing changed');
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
      expect(find.textContaining('Edit guest name'), findsNothing);
    });
  });
}
