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

/// THE BILL PREVIEW IS A RECEIPT-SHAPED ARTIFACT AND IT GETS TURNED TOWARD A
/// GUEST. Every figure on it must be the figure the paper will carry, which is
/// the figure the drawer will take.
///
/// WHAT THIS FILE EXISTS TO STOP. The preview used to compute its own "without
/// service charge" ladder in Dart: it zeroed `service_charge` and recomputed
/// each tax line on the smaller base. `service_charge` is the
/// restaurant_percent leg ONLY. A tenant carrying the charge as a LINE IN
/// Outlets.default_tax — the tax_line shape, which is the shipped seed
/// (migrations/000_base_schema.sql) and therefore most tenants — has
/// `service_charge` = 0 while the guest is very much being charged one, because
/// the charge is one of the tax lines. That line was faithfully recomputed and
/// kept, so the "without" preview equalled the "with" preview TO THE PAISA.
/// That is F2, the bug that was just fixed in the server math, re-implemented
/// client-side in a second language — which is how two implementations of one
/// ladder always end: disagreeing.
///
/// THE RULE BEING PINNED, and it is the rule escpos.ts already obeys: the
/// client does not do money arithmetic. It renders the rungs the billing layer
/// computed, verbatim. So the tests below never assert what a total OUGHT to
/// be — they assert that what is painted is what the server sent, and that two
/// different server answers paint two different totals.
///
/// The numbers are the real ones for the probed shape: a 5499 subtotal under
/// SGST 2.5 + CGST 2.5 + a 10% "Service Charge" tax line.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;

  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'asha',
          'emp_Fname': 'Asha',
          'role': 'admin',
          'role_all': const ['admin'],
          'actions_set': const ['*'],
          'action_names': const ['View Bills', 'View Tables'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  Iterable<({String method, String path, Object? body})> to(String fragment) =>
      writes.where((w) => w.path.contains(fragment));
}

// --------------------------------------------------------------- fixtures --

const double _subtotal = 5499.0;

/// SGST / CGST as the seed ships them, each levied on the subtotal.
List<Map<String, dynamic>> get _statutoryTaxes => [
      {'name': 'SGST', 'percentage': 2.5, 'amount': 137.48},
      {'name': 'CGST', 'percentage': 2.5, 'amount': 137.48},
    ];

/// The service charge ON A TAX-LINE TENANT: it is a tax line, not
/// `service_charge`. 10% of 5499.
Map<String, dynamic> get _serviceChargeTaxLine =>
    {'name': 'Service Charge', 'percentage': 10.0, 'amount': 549.90};

/// GET /bill-for-table exactly as the server answers it for this tenant, with
/// the charge on ([waived] false) and with a RECORDED WAIVER live ([waived]
/// true). Both ladders come out of computeBillCharges via openBillChargeConfig,
/// which is the same resolver settle reads — so the waived answer is what the
/// guest is charged, not merely what is printed.
Map<String, dynamic> _taxLineBill({required bool waived}) => {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': _subtotal,
      'subtotal': _subtotal,
      'discount': 0.0,
      // ZERO IN BOTH CASES, and that is the whole trap: on this shape the guest
      // is charged a service charge that never appears in this field.
      'service_charge': 0.0,
      'service_charge_percent': 10.0,
      'service_charge_waived': waived,
      'service_charge_waiver': waived
          ? {
              'id': 'w-1',
              'waiver_kind': 'goodwill',
              'reason': 'Long wait for the mains',
              'amount_waived': 549.90,
              'waived_by_username': 'asha',
              'authorised_by_username': 'asha',
            }
          : null,
      'taxes': waived
          ? _statutoryTaxes
          : [..._statutoryTaxes, _serviceChargeTaxLine],
      'tax_total': waived ? 274.96 : 824.86,
      'grand_total': waived ? 5773.96 : 6323.86,
      'nc_total': 0.0,
      'covers': 4,
      'apc': 1374.75,
      'target_apc': 0.0,
      'apc_status': 'neutral',
      'apc_suggestions': const <String>[],
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
        {'name': 'Dal Makhani', 'price': 4859.0, 'quantity': 1},
      ],
      'payment_status': null,
    };

Map<String, dynamic> _routes(Map<String, dynamic> bill) => {
      '/get-tables': [
        {
          'table_name': 'T1',
          'capacity': 4,
          'max_capacity': 4,
          'section': 'Main',
          'occupied': true,
          'reserved': false,
          'num_covers': 4,
          'covers': 4,
          'table_total': _subtotal,
          'table_apc': 1374.75,
          'apc_status': 'neutral',
        }
      ],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': bill,
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': <dynamic>[],
    };

// ------------------------------------------------------------------ hosts --

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(WidgetTester tester, Map<String, dynamic> bill) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(_routes(bill));
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Finder _button(String label) => find.byWidgetPredicate(
    (w) => w is ForkButton && w.label == label,
    description: 'ForkButton "$label"');

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120,
        scrollable: find.byType(Scrollable).last);
  } catch (_) {/* already on screen, or not on this sheet at all */}
  await tester.pumpAndSettle();
}

/// Open the receipt preview for T1.
Future<void> _openPreview(WidgetTester tester) async {
  await _openTable(tester);
  await _reveal(tester, _button('Print bill'));
  await tester.tap(_button('Print bill'));
  await tester.pumpAndSettle();
  expect(find.text('Bill preview'), findsOneWidget,
      reason: 'the receipt preview did not open');
}

/// The right-hand figure on the preview row whose left-hand label is [label].
///
/// Scoped to the dialog on purpose: the table sheet underneath prints a grand
/// total of its own, and an assertion that cannot tell the two apart would pass
/// on the sheet while the paper-coloured artifact above it said something else.
String _previewAmount(WidgetTester tester, String label) {
  final dialog = find.byType(Dialog);
  expect(dialog, findsOneWidget);
  final labelFinder = find.descendant(of: dialog, matching: find.text(label));
  expect(labelFinder, findsOneWidget, reason: 'no "$label" row on the preview');
  final row = find.ancestor(of: labelFinder, matching: find.byType(Row)).first;
  final texts = tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .toList();
  return texts.last.data ?? '';
}

/// Every figure painted on the preview, so a test can assert about the whole
/// sheet rather than one row it remembered to look at.
List<String> _previewFigures(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byType(Dialog), matching: find.byType(Text))))
        if ((t.data ?? '').startsWith('₹')) t.data!,
    ];

void main() {
  group('the bill preview renders the server ladder and derives nothing', () {
    // THE F2 REGRESSION, IN THE SHAPE THAT BROKE. Two server answers for one
    // tax-line tenant, one with the charge and one with it waived. The preview
    // must show two different totals; the old client math showed one.
    testWidgets('with-charge and waived previews differ, and each is the'
        ' server\'s own grand total', (tester) async {
      await _mount(tester, _taxLineBill(waived: false));
      await _openPreview(tester);
      final withCharge = _previewAmount(tester, 'Grand total');
      expect(withCharge, '₹6323.86',
          reason: 'the preview must print grand_total as the server sent it');
      // The charge is visible as what it is on this shape: a tax line.
      expect(find.descendant(
              of: find.byType(Dialog), matching: find.text('Service Charge (10%)')),
          findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _mount(tester, _taxLineBill(waived: true));
      await _openPreview(tester);
      final waived = _previewAmount(tester, 'Grand total');
      expect(waived, '₹5773.96',
          reason: 'the waived bill\'s grand total, as the server computed it');

      expect(waived, isNot(withCharge),
          reason: 'F2: a tax-line tenant showed the SAME total with and without'
              ' the service charge, because only the restaurant_percent leg was'
              ' zeroed. The two must differ.');
    });

    // The waived preview must not merely be quieter — the charge must be gone
    // from the ladder AND the paper must say why, because a line that is simply
    // absent leaves the guest and the waiter to work it out.
    testWidgets('a waived bill drops the charge line and says so',
        (tester) async {
      await _mount(tester, _taxLineBill(waived: true));
      await _openPreview(tester);

      expect(
          find.descendant(
              of: find.byType(Dialog), matching: find.text('Service Charge (10%)')),
          findsNothing,
          reason: 'the waived charge must not still be billed as a tax line');
      expect(_previewAmount(tester, 'Service charge'), 'waived');
      expect(find.text('Service charge waived on this bill.'), findsOneWidget);
      expect(_previewFigures(tester), isNot(contains('₹549.90')),
          reason: 'a waived charge must not be priced anywhere on the receipt');
    });

    // THE RULE ITSELF, pinned independently of any particular tax shape: the
    // dialog prints the billing layer's total even when that total is not what
    // re-adding the printed rungs would produce. A client that "corrects" the
    // server here is a client that will one day correct it wrongly — which is
    // exactly how the ladder this file is named after got out of step.
    testWidgets('the grand total is the server\'s, never a re-derivation of the'
        ' rungs', (tester) async {
      final bill = _taxLineBill(waived: false);
      // 5499.00 + 824.86 = 6323.86. The server says 6300.00. The server wins.
      bill['grand_total'] = 6300.00;
      await _mount(tester, bill);
      await _openPreview(tester);

      expect(_previewAmount(tester, 'Grand total'), '₹6300.00');
      expect(_previewAmount(tester, 'Subtotal'), '₹5499.00');
    });
  });

  group('the print-only reprint never rehearses a total nobody will pay', () {
    // `no_service_charge` on POST /print/bill changes the PAPER and nothing
    // else: no settle path reads it, so the guest is charged the full amount.
    // Putting the smaller ladder on a paper-coloured sheet — which is what this
    // button used to do — hands the till a receipt for a total that will not be
    // taken. So this path shows no figures at all and names the mechanism that
    // does change what the guest pays.
    testWidgets('it confirms without money, then prints', (tester) async {
      final api = await _mount(tester, _taxLineBill(waived: false));
      await _openTable(tester);
      await _reveal(tester, _button('Reprint (no service charge)'));
      await tester.tap(_button('Reprint (no service charge)'));
      await tester.pumpAndSettle();

      expect(find.text('Bill preview'), findsNothing,
          reason: 'the receipt preview must not be used for a paper-only reprint');
      expect(find.byType(AlertDialog), findsOneWidget);
      final figures = [
        for (final t in tester.widgetList<Text>(
            find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text))))
          t.data ?? '',
      ];
      expect(figures.any((f) => f.contains('₹')), isFalse,
          reason: 'no rupee figure may appear on the reprint confirmation');
      // 4.1: the dialog states the outcome as a condition — the server removes
      // the charge only when a waiver is recorded, and says so — rather than the
      // old sentence this used to pin.
      expect(find.textContaining('prints WITH the service charge'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('Waive service charge')), findsOneWidget);

      await tester.tap(find.text('Reprint'));
      await tester.pumpAndSettle();
      final prints = api.to('/print/bill').toList();
      expect(prints, hasLength(1));
      expect((prints.single.body as Map)['no_service_charge'], true);
    });

    testWidgets('cancelling prints nothing', (tester) async {
      final api = await _mount(tester, _taxLineBill(waived: false));
      await _openTable(tester);
      await _reveal(tester, _button('Reprint (no service charge)'));
      await tester.tap(_button('Reprint (no service charge)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.to('/print/bill'), isEmpty);
    });
  });
}
