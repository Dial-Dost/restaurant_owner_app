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
///
/// BARE AS WELL AS PRICED. The paper prints the item columns and the ladder as
/// plain figures ("549.90") and puts the currency on the Grand Total alone, and
/// the preview now does the same — so a helper that only collected "₹…" would
/// let a waived charge back onto the sheet unseen. Returned without the symbol.
List<String> _previewFigures(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byType(Dialog), matching: find.byType(Text))))
        if (RegExp(r'^₹?[+-]?\d+\.\d{2}$').hasMatch(t.data ?? '')) t.data!.replaceFirst('₹', ''),
    ];

final Finder _serviceChargeNote = find.byKey(const ValueKey('bill-preview-service-charge-note'));

void main() {
  group('the bill preview renders the server ladder and derives nothing', () {
    // THE F2 REGRESSION, IN THE SHAPE THAT BROKE. Two server answers for one
    // tax-line tenant, one with the charge and one with it waived. The preview
    // must show two different totals; the old client math showed one.
    testWidgets('with-charge and waived previews differ, and each is the'
        ' server\'s own grand total', (tester) async {
      await _mount(tester, _taxLineBill(waived: false));
      await _openPreview(tester);
      final withCharge = _previewAmount(tester, 'Grand Total');
      expect(withCharge, '₹6323.86',
          reason: 'the preview must print grand_total as the server sent it');
      // The charge is visible as what it is on this shape: a tax line, labelled
      // as the paper labels it.
      expect(_previewAmount(tester, 'Service Charge 10%'), '549.90');
      // And the guest is being charged for service, so the paper's disclaimer
      // is on the sheet — on THIS shape too, where `service_charge` is 0.
      expect(_serviceChargeNote, findsOneWidget,
          reason: 'a tax-line charge is a charge; the disclaimer must follow it');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _mount(tester, _taxLineBill(waived: true));
      await _openPreview(tester);
      final waived = _previewAmount(tester, 'Grand Total');
      expect(waived, '₹5773.96',
          reason: 'the waived bill\'s grand total, as the server computed it');

      expect(waived, isNot(withCharge),
          reason: 'F2: a tax-line tenant showed the SAME total with and without'
              ' the service charge, because only the restaurant_percent leg was'
              ' zeroed. The two must differ.');
    });

    // THE CLIENT: "In the overview, don't show service charge opted out when
    // removed" — and, of the bill, "this too". A waived bill's preview reads like
    // a bill with no service charge, because it is one: no charge line, no
    // "Opted-out" rung, and no staff caption announcing the waiver. The paper
    // (escpos.ts) prints none of it either.
    testWidgets('a waived bill drops the charge line and shows nothing in its place',
        (tester) async {
      await _mount(tester, _taxLineBill(waived: true));
      await _openPreview(tester);
      final dialog = find.byType(Dialog);

      expect(find.descendant(of: dialog, matching: find.textContaining('Service Charge')), findsNothing,
          reason: 'a removed charge has no row — not a figure, not a word');
      expect(find.descendant(of: dialog, matching: find.textContaining('Opted-out')), findsNothing);
      expect(find.textContaining('waived on this bill'), findsNothing,
          reason: 'the staff caption announced the waiver on a receipt-shaped sheet');
      expect(_previewFigures(tester), isNot(contains('549.90')),
          reason: 'a waived charge must not be priced anywhere on the receipt');
      expect(_serviceChargeNote, findsNothing,
          reason: 'no voluntary-charge disclaimer on a bill that charges none');
      // The total is still the server's own, waiver and all.
      expect(_previewAmount(tester, 'Grand Total'), '₹5773.96');
    });

    testWidgets('the table sheet\'s Bill card shows no "waived" service-charge row either',
        (tester) async {
      await _mount(tester, _taxLineBill(waived: true));
      await _openTable(tester);
      await _reveal(tester, find.text('TOTAL PAYABLE'));
      expect(find.text('TOTAL PAYABLE'), findsOneWidget);
      expect(find.text('waived'), findsNothing,
          reason: 'the Bill card used to read "Service charge   waived"');
      expect(find.text('Service charge'), findsNothing);
    });

    // BACKEND MIGRATION 048: every bill is rounded to the rupee in the billing
    // layer and `round_off` rides beside `grand_total`. The client's receipt:
    // 4745 + SGST 118.63 + CGST 118.63 = 4982.26 -> "Round off -0.26",
    // "Grand Total 4982.00".
    Map<String, dynamic> gaiaRounded({required double? roundOff}) => {
          ..._taxLineBill(waived: true),
          'subtotal': 4745.0,
          'total_amt': 4745.0,
          'service_charge_waived': false,
          'service_charge_waiver': null,
          'service_charge_percent': 0.0,
          'taxes': const [
            {'name': 'SGST', 'percentage': 2.5, 'amount': 118.63},
            {'name': 'CGST', 'percentage': 2.5, 'amount': 118.63},
          ],
          'tax_total': 237.26,
          'round_off': roundOff,
          'grand_total': roundOff == null ? 4982.26 : 4982.0,
          'items': const [
            {'name': 'Thali', 'price': 4745.0, 'quantity': 1},
          ],
        };

    testWidgets('a rounded bill shows its Round off above the Grand Total, on the preview and the sheet',
        (tester) async {
      await _mount(tester, gaiaRounded(roundOff: -0.26));
      await _openPreview(tester);
      // The paper's own wording and sign, and no currency on the rung.
      expect(_previewAmount(tester, 'Round off'), '-0.26');
      expect(_previewAmount(tester, 'Grand Total'), '₹4982.00');
      final dialog = find.byType(Dialog);
      expect(tester.getTopLeft(find.descendant(of: dialog, matching: find.text('Round off'))).dy,
          lessThan(tester.getTopLeft(find.descendant(of: dialog, matching: find.text('Grand Total'))).dy));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _reveal(tester, find.text('TOTAL PAYABLE'));
      expect(find.text('Round off'), findsOneWidget, reason: 'the table sheet\'s Bill card');
      expect(find.text('−₹0.26'), findsOneWidget);
    });

    testWidgets('a bill with no round-off (whole, or an older backend) shows no Round off line',
        (tester) async {
      await _mount(tester, gaiaRounded(roundOff: null));
      await _openPreview(tester);
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('Round off')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _mount(tester, gaiaRounded(roundOff: 0.0));
      await _openTable(tester);
      await _reveal(tester, find.text('TOTAL PAYABLE'));
      expect(find.text('Round off'), findsNothing);
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

      expect(_previewAmount(tester, 'Grand Total'), '₹6300.00');
      expect(_previewAmount(tester, 'Sub Total'), '5499.00');
    });
  });

  // THE CLIENT'S PRINTED BILL IS THE REFERENCE, and escpos.ts now follows it
  // block for block. A preview laid out differently is previewing a different
  // slip, so the order of the blocks and the column the figures sit in are
  // pinned here — without pinning a pixel.
  group('the bill preview is laid out the way the paper is', () {
    Finder inPreview(Finder f) => find.descendant(of: find.byType(Dialog), matching: f);

    // The disclaimer follows the CHARGE, in both shapes — the paper's
    // `service_charge_applied` — never one leg of it, and never a waived bill.
    test('the service-charge disclaimer follows a charge in either shape, and never a waiver', () {
      // restaurant_percent: the charge is its own field.
      expect(m.billPrintsServiceChargeNote({'service_charge': 400.0, 'taxes': const []}), isTrue);
      // tax_line: `service_charge` is 0 and the charge is a tax line.
      expect(m.billPrintsServiceChargeNote(_taxLineBill(waived: false)), isTrue);
      expect(m.billPrintsServiceChargeNote({'service_charge': 0, 'taxes': [{'name': 'service  charge', 'percentage': 5, 'amount': 20}]}), isTrue);
      // No charge configured at all: statutory taxes only.
      expect(m.billPrintsServiceChargeNote({'service_charge': 0.0, 'taxes': _statutoryTaxes}), isFalse);
      // A live waiver took it off, in either shape.
      expect(m.billPrintsServiceChargeNote(_taxLineBill(waived: true)), isFalse);
      expect(m.billPrintsServiceChargeNote({'service_charge': 400.0, 'service_charge_waived': true}), isFalse);
    });

    testWidgets('header, name slot, date, item table, ladder, total, disclaimer, QR — in that order',
        (tester) async {
      await _mount(tester, _taxLineBill(waived: false));
      await _openPreview(tester);
      double y(Finder f) {
        expect(inPreview(f), findsOneWidget, reason: '$f is not on the preview');
        return tester.getTopLeft(inPreview(f)).dy;
      }

      final order = <Finder>[
        find.text('Gaia Test'),
        find.text('Name:'),
        find.text('Dine In: T1'),
        find.text('Amount'),
        find.text('Paneer Tikka'),
        find.text('Sub Total'),
        find.text('SGST 2.5%'),
        find.text('Grand Total'),
        _serviceChargeNote,
        find.byKey(const ValueKey('bill-preview-qr')),
      ];
      for (var i = 1; i < order.length; i++) {
        expect(y(order[i]), greaterThan(y(order[i - 1])),
            reason: '${order[i]} must come after ${order[i - 1]}');
      }
      // The paper's headings and labels, word for word.
      for (final label in ['Item', 'Qty.', 'Price', 'Amount', 'Total Qty: 3']) {
        expect(inPreview(find.text(label)), findsOneWidget, reason: '"$label" is missing');
      }
      expect(inPreview(find.textContaining('Thanks')), findsNothing,
          reason: 'the paper has no Thanks line now');
      // The table is bold on the Date row; the Grand Total is the biggest figure.
      expect(tester.widget<Text>(inPreview(find.text('Dine In: T1'))).style?.fontWeight, FontWeight.bold);
      final grand = tester.widget<Text>(inPreview(find.text('₹6323.86'))).style!;
      final sub = DefaultTextStyle.of(tester.element(inPreview(find.text('5499.00')))).style
          .merge(tester.widget<Text>(inPreview(find.text('5499.00'))).style);
      expect(grand.fontWeight, FontWeight.w800);
      expect(grand.fontSize!, greaterThan(sub.fontSize!));
    });

    testWidgets('every figure right-aligns on the one Amount column', (tester) async {
      await _mount(tester, _taxLineBill(waived: false));
      await _openPreview(tester);
      double right(Finder f) => tester.getTopRight(f).dx;
      // The heading, a line amount (320 x 2), the ladder rungs and the grand
      // total all end at the same x — the right edge of the Amount column.
      final edge = right(inPreview(find.text('Amount')));
      for (final figure in ['640.00', '5499.00', '549.90', '₹6323.86']) {
        expect(right(inPreview(find.text(figure))), moreOrLessEquals(edge, epsilon: 0.5),
            reason: '"$figure" is out of the Amount column');
      }
      // SGST and CGST are both 137.48.
      for (final e in inPreview(find.text('137.48')).evaluate()) {
        expect(tester.getTopRight(find.byElementPredicate((x) => x == e)).dx, moreOrLessEquals(edge, epsilon: 0.5));
      }
      // ...and a ladder label ENDS before its figure's column, well in from the
      // left margin: right-aligned, as the paper's ladder is.
      expect(right(inPreview(find.text('Grand Total'))),
          lessThanOrEqualTo(tester.getTopLeft(inPreview(find.text('₹6323.86'))).dx + 0.5));
      expect(tester.getTopLeft(inPreview(find.text('Sub Total'))).dx,
          greaterThan(tester.getTopLeft(inPreview(find.text('Item'))).dx),
          reason: 'the ladder label is right-aligned, not left');
    });
  });

  group('removing the service charge never rehearses a total nobody will pay', () {
    // The print-only "Reprint (no service charge)" this group used to pin is
    // gone (client item 6): the flag it sent could not take the charge off, and
    // the waiver that could was a second, separate step. One control now does
    // both through one server call, POST /bills/service-charge-waiver/print,
    // and what this group still guards is the property it was written for: no
    // receipt-shaped rehearsal of a smaller ladder on screen, on the tenant
    // shape where that rehearsal used to be wrong, and no print-time flag.
    testWidgets('it asks for the reason with no ladder, then makes ONE call and no flagged print',
        (tester) async {
      final api = await _mount(tester, _taxLineBill(waived: false));
      await _openTable(tester);
      expect(_button('Reprint (no service charge)'), findsNothing);
      await _reveal(tester, _button('Remove service charge & print'));
      await tester.tap(_button('Remove service charge & print'));
      await tester.pumpAndSettle();

      expect(find.text('Bill preview'), findsNothing,
          reason: 'the receipt preview must not be used to rehearse a removal');
      // The one figure on the form is the CHARGE being removed — the tax line,
      // on this shape, since `service_charge` is 0 — never a total.
      expect(find.text('₹549.90'), findsOneWidget);
      expect(find.text('₹5773.96'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'Guest asked');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('capture-confirm')));
      await tester.pumpAndSettle();

      final removals = api.to('/bills/service-charge-waiver/print').toList();
      expect(removals, hasLength(1));
      expect((removals.single.body as Map)['table_name'], 'T1');
      expect(api.to('/print/bill'), isEmpty);
      expect(api.writes.any((w) => '${w.body}'.contains('no_service_charge')), isFalse);
    });

    testWidgets('cancelling writes nothing', (tester) async {
      final api = await _mount(tester, _taxLineBill(waived: false));
      await _openTable(tester);
      await _reveal(tester, _button('Remove service charge & print'));
      await tester.tap(_button('Remove service charge & print'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
    });
  });
}
