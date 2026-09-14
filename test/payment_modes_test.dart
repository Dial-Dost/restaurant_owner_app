import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/payment_modes.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// PAYMENT MODES — "there has to be an option to add mode of payments".
///
/// The server stores the restaurant's modes; this suite pins the app's half:
///
///   * THE WIRING. A mode saved in Settings reaches the settle sheet as a pill,
///     SHOWN by its label and SENT by its id, with the screenshot rule the
///     config gives it. A settle sheet that kept its own seven pills is exactly
///     how the owner's switches used to stop at the guest QR page.
///   * THE EDITOR. Settings > Payments can add a mode, and says why a name that
///     would book free food or an unpaid bill as revenue cannot be one.
///   * NEVER BLOCKED. With no settings (an older backend, a dead line) the sheet
///     offers the built-in list the server settles with — the keys the capture
///     tests already tap stay exactly where they were.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.unknownIsEmpty = false});

  final Map<String, dynamic> routes;
  final bool unknownIsEmpty;
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'manager01',
          'role': 'admin',
          'actions_set': const ['*'],
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      if (path == '/restaurant/settings' && body is Map && body['payment_methods'] is List) {
        // Stored, as the server would, so the reload after a save reads it back.
        final current = routes['/restaurant/settings'];
        routes['/restaurant/settings'] = {
          if (current is Map) ...current,
          'payment_methods': body['payment_methods'],
        };
        return <String, dynamic>{'payment_methods': body['payment_methods']};
      }
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    if (unknownIsEmpty) return <String, dynamic>{};
    throw ApiException('No fake route for $path', 404);
  }

  Object? bodyOf(String fragment) {
    for (final w in writes) {
      if (w.path.contains(fragment)) return w.body;
    }
    return null;
  }
}

Widget _host(Widget child, List<String> labels) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: labels,
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<_FakeApi> _mount(WidgetTester tester, Widget Function(RestClient, Profile) module,
    Map<String, dynamic> routes, List<String> labels, {bool unknownIsEmpty = false, double height = 1200}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(1400, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes, unknownIsEmpty: unknownIsEmpty);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!), labels));
  await tester.pumpAndSettle();
  return api;
}

/// What GET /restaurant/settings answers after the owner added "Swiggy Dineout"
/// (screenshot required) and switched Card off.
List<Map<String, dynamic>> _savedModes() => [
      for (final d in PaymentModes.fallback)
        {...d.toJson(), if (d.id == 'Card') 'enabled': false},
      {
        'id': 'Swiggy Dineout',
        'label': 'Swiggy (Dineout)',
        'enabled': true,
        'requires_screenshot': true,
        'custom': true,
        'show_to_guests': false,
      },
    ];

Map<String, dynamic> _tableRoutes({List<Map<String, dynamic>>? modes}) => {
      '/get-tables': [
        {'table_name': 'T1', 'capacity': 4, 'max_capacity': 4, 'section': 'Main', 'occupied': true, 'reserved': false, 'num_covers': 3},
      ],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': {
        'bill_id': 'bill-1',
        'total_amt': 1000.0,
        'subtotal': 1000.0,
        'discount': 0.0,
        'service_charge': 0.0,
        'service_charge_percent': 0.0,
        'taxes': const [],
        'grand_total': 1000.0,
        'covers': 3,
        'order_ids': const ['order-1'],
        'items': const [
          {'name': 'Paneer Tikka', 'price': 500.0, 'quantity': 2},
        ],
        'bill_no': '101',
      },
      '/orders/scope': {'outlets': <dynamic>[], 'is_all_outlets': false},
      '/orders': [
        {
          'id': 'order-1',
          'table': 'T1',
          'status': 'Preparing',
          'order_type': 'dine_in',
          'total': 1000.0,
          'created_at': '2026-08-01T12:00:00.000Z',
          'items': [
            {'id': 'item-1', 'name': 'Paneer Tikka', 'price': 500.0, 'quantity': 2},
          ],
        },
      ],
      '/orders/order-1/non-chargeables': {'non_chargeables': <dynamic>[]},
      '/bills/tenders': {
        'bill_id': 'bill-1',
        'grand_total': 1000.0,
        'tenders': <dynamic>[],
        'tendered': 0.0,
        'outstanding': 1000.0,
        'exact': false,
        'partial': false,
        'over': false,
        'tips_total': 0.0,
        'payment_method': null,
        'payment_splits': <dynamic>[],
      },
      '/billing-counters': {'counters': <dynamic>[]},
      if (modes != null) '/restaurant/settings': {'kitchen_sections': <dynamic>[], 'payment_methods': modes},
    };

Future<void> _openSettle(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Settle bill'), 120, scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Settle bill'));
  await tester.pumpAndSettle();
}

String _pillLabel(WidgetTester tester, String id) {
  final pill = find.byKey(ValueKey('pay-method-$id'));
  final texts = find.descendant(of: pill, matching: find.byType(Text));
  return tester.widget<Text>(texts.first).data ?? '';
}

void main() {
  setUp(m.misResetCaptureMemory);

  group('the rules', () {
    test('no settings is the built-in list the server settles with', () {
      for (final raw in [null, 'nonsense', <dynamic>[], <dynamic>[{'nope': true}]]) {
        final modes = PaymentModes.parse(raw);
        expect(modes.map((x) => x.id), ['Razorpay', 'Upi', 'Cash', 'Card', 'Dineout', 'Zomato', 'Eazydiner', 'District']);
        expect(PaymentModes.till(modes).map((x) => x.id), ['Upi', 'Cash', 'Card', 'Dineout', 'Zomato', 'Eazydiner', 'District'],
            reason: 'the seven pills the sheet always had, the gateway excluded');
        expect(PaymentModes.till(modes).where((x) => x.requiresScreenshot).map((x) => x.id),
            ['Dineout', 'Zomato', 'Eazydiner', 'District']);
      }
    });

    test('a saved custom mode is a till mode; a switched-off one is not', () {
      final modes = PaymentModes.parse(_savedModes());
      final till = PaymentModes.till(modes);
      expect(till.map((x) => x.id), contains('Swiggy Dineout'));
      expect(till.map((x) => x.id), isNot(contains('Card')));
      expect(PaymentModes.labelFor('Swiggy Dineout', modes), 'Swiggy (Dineout)');
      expect(PaymentModes.labelFor('upi', modes), 'UPI');
      expect(PaymentModes.labelFor('Legacy', modes), 'Legacy');
      expect(PaymentModes.needsScreenshot('swiggy-dineout', modes), isTrue);
      expect(PaymentModes.needsScreenshot('Dine Out', modes), isTrue);
      expect(PaymentModes.needsScreenshot('Cash', modes), isFalse);
      // A custom mode is off the guest page unless the server says it is on.
      expect(PaymentMode.fromJson({'id': 'X', 'custom': true})!.showToGuests, isFalse);
    });

    test('names that are not money are refused, with the sentence the server uses', () {
      final modes = PaymentModes.parse(_savedModes());
      for (final n in ['Complimentary', 'NC', 'n/c', 'Staff Meal', 'non-chargeable']) {
        expect(PaymentModes.newModeRefusal(n, modes), contains('Mark as non-chargeable'), reason: n);
      }
      for (final n in ['Credit', 'On Account', 'due', 'Pay later']) {
        expect(PaymentModes.newModeRefusal(n, modes), contains('no money has arrived'), reason: n);
      }
      for (final n in ['Split', 'Other', 'Unallocated']) {
        expect(PaymentModes.newModeRefusal(n, modes), contains('reports already use'), reason: n);
      }
      for (final n in ['Zomato Pay', 'dine-out', 'UPI', 'Razorpay']) {
        expect(PaymentModes.newModeRefusal(n, modes), contains('built-in'), reason: n);
      }
      expect(PaymentModes.newModeRefusal('Swiggy;Dineout', modes), contains('characters'));
      expect(PaymentModes.newModeRefusal('x' * 33, modes), contains('too long'));
      expect(PaymentModes.newModeRefusal('swiggy dineout', modes), contains('already has'));
      expect(PaymentModes.newModeRefusal('Magicpin', modes), isNull);
      expect(PaymentModes.newModeRefusal('Credit Card (Amex)', modes), isNull);
      expect(PaymentModes.labelRefusal('Complimentary', 'Swiggy Dineout', modes), contains('non-chargeable'));
      expect(PaymentModes.labelRefusal('Cash', 'Upi', modes), contains('built-in Cash'));
      expect(PaymentModes.labelRefusal('Zomato Pay', 'Zomato', modes), isNull);
    });

    test('names that CONTAIN a not-money word are refused too — whole words, like the server', () {
      final modes = PaymentModes.parse(_savedModes());
      // The same cases the server's suite pins (jest-tests/payment_methods.test.ts).
      for (final n in ['Staff Meals', 'Complimentary Meal', 'Comps', 'FOC', 'Non Chargeable Bill', 'Guest (Comp)', 'Staff-Meal Friday', 'NonChargeable']) {
        expect(PaymentModes.notMoneyKind(n), 'comp', reason: n);
        expect(PaymentModes.newModeRefusal(n, modes), contains('Mark as non-chargeable'), reason: n);
      }
      for (final n in ['On Credit', 'Due Payment', 'Credit/Due', 'Customer Credit', 'Pay Later - Regulars', 'PayLater', 'On Account (Corporate)']) {
        expect(PaymentModes.notMoneyKind(n), 'credit', reason: n);
        expect(PaymentModes.newModeRefusal(n, modes), contains('no money has arrived'), reason: n);
      }
      for (final n in ['Credit Card', 'HDFC Credit/Debit Card', 'Credit Cards (Visa)', 'Company Card', 'Compass Pay', 'Duet Pay', 'NCB Bank', 'Focus Wallet', 'Staffing Co']) {
        expect(PaymentModes.notMoneyKind(n), isNull, reason: n);
        expect(PaymentModes.newModeRefusal(n, modes), isNull, reason: n);
      }
      expect(PaymentModes.notMoneyKind('Card Credit'), 'credit');
      expect(PaymentModes.labelRefusal('Staff Meals', 'Swiggy Dineout', modes), contains('non-chargeable'));
      expect(PaymentModes.labelRefusal('Card on Credit', 'Card', modes), contains('no money has arrived'));
    });

    test('a report row reads by the label the server attached, and still keys on the id', () {
      expect(PaymentModes.reportName({'method': 'Dineout', 'label': 'Swiggy Dineout'}), 'Swiggy Dineout');
      expect(PaymentModes.reportName({'method': 'Upi'}), 'Upi');
      expect(PaymentModes.reportName({'method': 'Cash', 'label': '  '}), 'Cash');
      expect(PaymentModes.reportName({'method': ''}), 'Other');
    });

    test('what a new mode saves as: permanent tidy id, label = name, custom, flags as ticked', () {
      final next = PaymentModes.withCustom(PaymentModes.fallback,
          name: '  Swiggy   Dineout ', requiresScreenshot: true, showToGuests: false);
      expect(next.last.toJson(), {
        'id': 'Swiggy Dineout',
        'label': 'Swiggy Dineout',
        'enabled': true,
        'requires_screenshot': true,
        'online': false,
        'custom': true,
        'show_to_guests': false,
      });
    });
  });

  group('WIRED: a mode saved in Settings reaches the settle sheet', () {
    testWidgets('its pill is labelled by the owner and settles by its id, screenshot demanded', (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes(modes: _savedModes()), const ['Tables', 'Orders', 'Menu', 'Settings']);
      await _openSettle(tester);

      expect(find.byKey(const ValueKey('pay-method-Swiggy Dineout')), findsOneWidget);
      expect(_pillLabel(tester, 'Swiggy Dineout'), 'Swiggy (Dineout)');
      expect(_pillLabel(tester, 'Upi'), 'UPI');
      expect(find.byKey(const ValueKey('pay-method-Card')), findsNothing, reason: 'switched off in Settings');
      expect(find.byKey(const ValueKey('pay-method-Razorpay')), findsNothing, reason: 'the gateway is not a till pill');

      await tester.tap(find.byKey(const ValueKey('pay-method-Swiggy Dineout')));
      await tester.pumpAndSettle();
      // The config's screenshot rule, said beside the grey button by label.
      expect(find.textContaining('Swiggy (Dineout) needs a payment screenshot'), findsWidgets);
      expect(api.bodyOf('waiter-confirm-payment'), isNull);
    });

    testWidgets('a custom mode with no screenshot rule settles with the id in the body', (tester) async {
      final modes = [
        for (final x in _savedModes())
          if (x['id'] == 'Swiggy Dineout') {...x, 'requires_screenshot': false} else x,
      ];
      final api = await _mount(tester, m.tablesModule, _tableRoutes(modes: modes), const ['Tables', 'Orders', 'Menu', 'Settings']);
      await _openSettle(tester);
      await tester.tap(find.byKey(const ValueKey('pay-method-Swiggy Dineout')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      expect(body, isNotNull);
      expect(body!['payment_method'], 'Swiggy Dineout', reason: 'the id is sent, never the label');
      expect(body.containsKey('tenders'), isFalse, reason: 'the common settle body is unchanged');
    });

    testWidgets('no settings read: the seven built-in pills, exactly as before', (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes(), const ['Tables', 'Orders', 'Menu', 'Settings']);
      await _openSettle(tester);
      for (final id in ['Upi', 'Cash', 'Card', 'Dineout', 'Zomato', 'Eazydiner', 'District']) {
        expect(find.byKey(ValueKey('pay-method-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('pay-method-Razorpay')), findsNothing);
    });
  });

  group('Settings > Payments can add a mode', () {
    Future<_FakeApi> openCard(WidgetTester tester, List<Map<String, dynamic>> modes) async {
      final api = await _mount(
        tester,
        m.settingsModule,
        {
          '/restaurant/profile': <String, dynamic>{'restaurant_name': 'CSR Organics'},
          '/restaurant/settings': {'payment_methods': modes, 'currency': '₹'},
        },
        const ['Settings'],
        unknownIsEmpty: true,
        height: 2600,
      );
      final add = find.byKey(const ValueKey('payment-mode-open-add'));
      final list = find.byType(Scrollable).first;
      for (var i = 0; i < 40 && add.evaluate().isEmpty; i++) {
        await tester.drag(list, const Offset(0, -400));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(add, findsOneWidget, reason: 'never reached the Payments card');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('the card lists the saved modes with their labels, and the copy says till AND guest page', (tester) async {
      await openCard(tester, _savedModes());
      expect(find.byKey(const ValueKey('payment-mode-row-Swiggy Dineout')), findsOneWidget);
      expect(find.textContaining('Payment modes offered at the till and on the guest QR page'), findsOneWidget);
      expect(find.textContaining('which payment methods guests can use'), findsNothing);
    });

    testWidgets('adding "Magicpin" posts the whole list with the new custom mode, keeping the rest', (tester) async {
      final api = await openCard(tester, _savedModes());
      await tester.tap(find.byKey(const ValueKey('payment-mode-open-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('payment-mode-name')), ' Magicpin ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('payment-mode-screenshot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('payment-mode-add')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('/restaurant/settings') as Map?;
      expect(body, isNotNull);
      final sent = (body!['payment_methods'] as List).cast<Map>();
      expect(sent.map((x) => x['id']), containsAll(['Upi', 'Card', 'Swiggy Dineout', 'Magicpin']));
      final magic = sent.firstWhere((x) => x['id'] == 'Magicpin');
      expect(magic['custom'], isTrue);
      expect(magic['requires_screenshot'], isTrue);
      expect(magic['show_to_guests'], isFalse);
      expect(magic['enabled'], isTrue);
      // The switched-off mode went back switched off — removal is never a delete.
      expect(sent.firstWhere((x) => x['id'] == 'Card')['enabled'], isFalse);
      expect(find.byKey(const ValueKey('payment-mode-row-Magicpin')), findsOneWidget);
    });

    testWidgets('"Complimentary" is refused in the dialog, with the NC pointer, and nothing is posted', (tester) async {
      final api = await openCard(tester, _savedModes());
      await tester.tap(find.byKey(const ValueKey('payment-mode-open-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('payment-mode-name')), 'Complimentary');
      await tester.pumpAndSettle();
      expect(find.textContaining('Mark as non-chargeable'), findsWidgets);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('payment-mode-add'))).onPressed, isNull);
      expect(api.bodyOf('/restaurant/settings'), isNull);
    });
  });

  group('source guards', () {
    final capture = File('lib/screens/mis_capture.dart').readAsStringSync();
    final modules = File('lib/screens/modules.dart').readAsStringSync();

    test('the settle sheet keeps no list of its own', () {
      expect(capture, isNot(contains("static const _methods = ['Upi'")));
      expect(capture, isNot(contains('static const _needsProof')));
      expect(capture, contains("getMap('/restaurant/settings')"));
      expect(capture, contains('PaymentModes.till(modes)'));
      expect(capture, contains('PaymentModes.needsScreenshot(_method, _allModes)'));
    });

    test('Accounting names each payment method by its label; the filter still matches on the id', () {
      expect(modules, isNot(contains("_s(m, 'method', 'Other')")),
          reason: 'every by_method row reads PaymentModes.reportName, so a renamed mode matches the till');
      expect("PaymentModes.reportName(m)".allMatches(modules).length, greaterThanOrEqualTo(5));
      expect(modules, contains("value: _s(m as Map, 'method', ''),"));
    });

    test('the Settings card edits PaymentModes and can add one', () {
      expect(modules, contains('PaymentModes.withCustom('));
      expect(modules, contains("'payment_methods': [for (final m in list) m.toJson()]"));
    });
  });
}
