// SETTLE AS NC — client item 5, from the till's side.
//
// "NC has to come up as an option for payment mode when settling a bill, this
// has to be coded in as analytics for NC is required."
//
// What these pin:
//   * the pure rules (lib/models/nc_settle.dart) — gates, refusals, the body,
//     the words, the report and overview readers, the paper's NC line;
//   * THE SETTLE SHEET: the NC pill is offered beside the modes only to a
//     session holding BOTH the comp permission and Close Bill; it posts ONCE to
//     settle-nc with the sheet's quote and never approves or closes; it is
//     greyed WITH the reason when money is already on the bill or a discount is;
//     a ₹0 bill whose dishes were all comped opens as NC and never sends UPI;
//     offline it refuses with the billing sentence and queues nothing;
//   * THE PAPER PREVIEW: a comped line reads "<dish> (NC)" at 0.00 and the value
//     given away is disclosed under the total;
//   * THE OVERVIEW: today's NC beside the by-method block, never inside it;
//   * the wiring the widgets above do not reach (the report panels, the closed
//     bill), and the same words as the web dashboard and the backend.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/nc_settle.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';
import 'package:restaurant_owner_app/widgets/table_bill.dart';

/// PERM_NON_CHARGEABLE and the record-payment action, as the server names them.
const String _permNc = 'b4e7a1c9-2d58-4f36-9a07-5c81e3b0d472';
const String _permRecordPayment = '2393edd7-cdd9-439c-9ff3-d563d5216967';

String _rupees(double v) => '₹${v.toStringAsFixed(2)}';

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.actions = const ['*'], this.role = 'admin'});

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;
  static const String username = 'manager01';

  final List<String> calls = <String>[];
  final List<({String method, String path, Object? body})> writes = [];
  bool offline = false;
  String failOn = '';
  String failMessage = 'refused';
  int failStatus = 400;

  /// Refuse with a body that decodes to nothing: what an older server's own
  /// "Cannot POST" page is to this app.
  bool failWithoutBody = false;

  final Map<String, Object?> replies = <String, Object?>{};

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': username,
          'role': role,
          'actions_set': actions,
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (offline) throw ApiException('Connection failed');
    calls.add('$method $path');
    if (failOn.isNotEmpty && path.contains(failOn)) {
      throw ApiException.fromBody(failWithoutBody ? null : {'error': failMessage}, failStatus);
    }
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return replies.containsKey(path) ? replies[path] : <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  Object? bodyOf(String fragment) {
    for (final w in writes) {
      if (w.path.contains(fragment)) return w.body;
    }
    return null;
  }

  bool wrote(String fragment) => writes.any((w) => w.path.contains(fragment));
}

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  List<String> actions = const ['*'],
  String role = 'admin',
  List<String> labels = const ['Tables', 'Orders', 'Menu', 'Settings'],
  Size size = const Size(1400, 1400),
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes, actions: actions, role: role);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: labels,
      clearFocus: () {},
      child: Scaffold(backgroundColor: Colors.transparent, body: module(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

// ------------------------------------------------------------------ fixtures

Map<String, dynamic> _bill({
  double subtotal = 1200,
  double grand = 1386,
  double ncTotal = 0,
  double discount = 0,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': subtotal,
      'subtotal': subtotal,
      'discount': discount,
      'discount_type': discount > 0 ? 'flat' : null,
      'discount_value': discount,
      'service_charge': grand > 0 ? 120.0 : 0.0,
      'service_charge_percent': 10.0,
      'service_charge_waived': false,
      'taxes': grand > 0
          ? const [
              {'name': 'CGST', 'percentage': 2.5, 'amount': 33.0},
              {'name': 'SGST', 'percentage': 2.5, 'amount': 33.0},
            ]
          : const <dynamic>[],
      'tax_total': grand > 0 ? 66.0 : 0.0,
      'round_off': 0.0,
      'grand_total': grand,
      'nc_total': ncTotal,
      'covers': 3,
      'apc': 400.0,
      'order_ids': const ['order-1'],
      'items': items ??
          const [
            {'name': 'Paneer Tikka', 'price': 350.0, 'quantity': 2},
            {'name': 'Dal Makhani', 'price': 500.0, 'quantity': 1},
          ],
      'target_apc': 0,
      'apc_status': 'neutral',
      'apc_suggestions': const [],
      'payment_method': null,
      'payment_status': null,
      'bill_no': '101',
    };

Map<String, dynamic> _tenders({double grand = 1386, double tendered = 0}) => {
      'bill_id': 'bill-1',
      'grand_total': grand,
      'tenders': tendered > 0
          ? [
              {'id': 't-1', 'method': 'Cash', 'amount': tendered, 'voided_at': null},
            ]
          : <dynamic>[],
      'tendered': tendered,
      'outstanding': grand - tendered,
      'exact': grand == tendered,
      'partial': tendered > 0 && tendered < grand,
      'over': false,
      'tips_total': 0.0,
      'payment_method': null,
      'payment_splits': <dynamic>[],
    };

Map<String, dynamic> _routes({Map<String, dynamic>? bill, Map<String, dynamic>? tenders}) => {
      '/get-tables': [
        {
          'table_name': 'T1',
          'capacity': 4,
          'max_capacity': 4,
          'section': 'Main',
          'occupied': true,
          'reserved': false,
          'num_covers': 3,
        },
      ],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': bill ?? _bill(),
      '/orders/scope': {'outlets': <dynamic>[], 'is_all_outlets': false},
      '/orders': [
        {
          'id': 'order-1',
          'table': 'T1',
          'status': 'Served',
          'order_type': 'dine_in',
          'customer': 'Guest',
          'total': 1200.0,
          'created_at': '2026-09-16T12:00:00.000Z',
          'barked_at': '2026-09-16T12:01:00.000Z',
          'taken_by_employee_name': 'Asha',
          'items': [
            {'id': 'item-1', 'name': 'Paneer Tikka', 'price': 350.0, 'quantity': 2},
            {'id': 'item-2', 'name': 'Dal Makhani', 'price': 500.0, 'quantity': 1},
          ],
        },
      ],
      '/bills/tenders': tenders ?? _tenders(),
      '/billing-counters': {'counters': <dynamic>[]},
    };

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

Future<_FakeApi> _openSettle(
  WidgetTester tester, {
  Map<String, dynamic>? bill,
  Map<String, dynamic>? tenders,
  List<String> actions = const ['*'],
  String role = 'admin',
  Size size = const Size(1400, 1400),
}) async {
  final api = await _mount(tester, m.tablesModule, _routes(bill: bill, tenders: tenders),
      actions: actions, role: role, size: size);
  await _openTable(tester);
  await _reveal(tester, find.text('Settle bill'));
  await tester.tap(find.text('Settle bill'));
  await tester.pumpAndSettle();
  return api;
}

VoidCallback? _pressOf(WidgetTester tester, Key key) => tester.widget<ForkButton>(find.byKey(key)).onPressed;

Future<void> _tapVisible(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Would a finger on [finder]'s centre land on it? False when it is clipped,
/// covered, or under the keyboard's part of the screen.
bool _reachable(WidgetTester tester, Finder finder) {
  final target = tester.renderObject(finder);
  return tester.hitTestOnBinding(tester.getCenter(finder)).path.any((e) => identical(e.target, target));
}

/// [key] inside the settle dialog's SCROLL, rather than pinned around it.
Finder _inSheetScroll(Key key) => find.descendant(
      of: find.descendant(of: find.byType(Dialog), matching: find.byType(SingleChildScrollView)),
      matching: find.byKey(key),
    );

/// Choose NC and fill its form.
Future<void> _fillNc(WidgetTester tester, {String kind = 'staff_meal', String reason = 'Team dinner', bool tapPill = true}) async {
  if (tapPill) await _tapVisible(tester, const ValueKey('pay-method-NC'));
  await _tapVisible(tester, ValueKey('pay-nc-kind-$kind'));
  await tester.ensureVisible(find.byKey(const ValueKey('pay-nc-reason')));
  await tester.enterText(find.byKey(const ValueKey('pay-nc-reason')), reason);
  await tester.pumpAndSettle();
}

// --------------------------------------------------------------------- tests

void main() {
  setUp(m.misResetCaptureMemory);

  group('the rules, by value', () {
    test('offered only with the comp permission AND Close Bill', () {
      expect(NcSettle.mayOffer(compItem: true, settleBill: true), isTrue);
      expect(NcSettle.mayOffer(compItem: false, settleBill: true), isFalse, reason: 'a cashier');
      expect(NcSettle.mayOffer(compItem: true, settleBill: false), isFalse);
      expect(NcSettle.mayOffer(compItem: false, settleBill: false), isFalse, reason: 'a waiter');
    });

    test('the quote is the server\'s own subtotal; a fully comped ₹0 bill opens as NC', () {
      final b = _bill();
      expect(NcSettle.value(b), 1200);
      expect(NcSettle.wouldHaveCharged(b), 1386);
      expect(NcSettle.givenAway(_bill(subtotal: 1000, ncTotal: 200)), 1200);
      expect(NcSettle.opensAsNc(b), isFalse);
      expect(NcSettle.opensAsNc(_bill(subtotal: 0, grand: 0, ncTotal: 760)), isTrue);
      expect(NcSettle.opensAsNc(_bill(subtotal: 0, grand: 0)), isFalse, reason: 'nothing was given away');
      expect(NcSettle.opensAsNc(null), isFalse);
    });

    test('each refusal, in the server\'s order and words', () {
      String? blocked({Map? bill, double tendered = 0, int drafts = 0}) =>
          NcSettle.blocker(bill: bill, tendered: tendered, drafts: drafts, money: _rupees);
      expect(blocked(bill: _bill()), isNull);
      expect(blocked(), contains('could not be read'));
      expect(blocked(bill: {..._bill(), 'payment_status': 'pending_approval'}, tendered: 5),
          startsWith('A payment for this bill is already waiting for approval.'));
      expect(blocked(bill: _bill(discount: 50), tendered: 400),
          '₹400.00 is already recorded as paid on this bill. Void that payment first, or comp dishes individually and take the rest.');
      expect(blocked(bill: _bill(discount: 50), drafts: 1), kNcWholeBillOnly);
      expect(blocked(bill: _bill(discount: 50)),
          'This bill carries a discount or a coupon. Remove it first — a comped bill has nothing to discount.');
      expect(blocked(bill: {..._bill(), 'coupon_code': 'WELCOME'}), contains('discount or a coupon'));
      expect(blocked(bill: _bill(subtotal: 0, grand: 0)), 'There is nothing on this table to settle.');
      expect(blocked(bill: _bill(subtotal: 0, grand: 0, ncTotal: 760)), isNull,
          reason: 'a fully comped table still settles as NC, at 0.00');
    });

    test('the form needs all three answers, and the body never carries an amount', () {
      expect(NcSettle.formReady(kind: 'promo', reason: 'Launch night', authorisedBy: 'asha'), isTrue);
      expect(NcSettle.formReady(kind: '', reason: 'x', authorisedBy: 'asha'), isFalse);
      expect(NcSettle.formReady(kind: 'promo', reason: '  ', authorisedBy: 'asha'), isFalse,
          reason: 'the reason stays required for a whole-bill NC');
      expect(NcSettle.formReady(kind: 'promo', reason: 'x', authorisedBy: ''), isFalse);
      final body = NcSettle.body(
          kind: ' staff_meal ', reason: ' Team dinner ', authorisedBy: ' asha ', expectedValue: 1200.004, counterId: 'c-1');
      expect(body, {
        'nc_kind': 'staff_meal',
        'reason': 'Team dinner',
        'authorised_by': 'asha',
        'expected_value': 1200.0,
        'print': true,
        'counter_id': 'c-1',
      });
      for (final k in const ['amount', 'tenders', 'splits', 'payment_method']) {
        expect(body.containsKey(k), isFalse);
      }
      expect(NcSettle.body(kind: 'a', reason: 'b', authorisedBy: 'c', expectedValue: 0).containsKey('counter_id'), isFalse);
    });

    test('the words on the sheet and in the snackbar', () {
      expect(NcSettle.headline(1200, _rupees), 'NOTHING TO PAY · ₹1200.00 given away');
      expect(NcSettle.doneSentence({'bill_no': '101', 'nc_value': 1200, 'printed': true}, _rupees),
          'Bill 101 was settled as non-chargeable — ₹1200.00 given away, nothing collected. The NC bill is printing.');
      expect(NcSettle.doneSentence({'nc_value': 5, 'printed': false, 'print_error': 'No printer online'}, _rupees),
          'The bill was settled as non-chargeable — ₹5.00 given away, nothing collected. The NC bill did not print: No printer online');
      expect(NcSettle.doneSentence({'bill_no': '7', 'already': true}, _rupees), 'Bill 7 was already settled as non-chargeable.');
    });

    test('the figures read back: overview, reports, the closed bill', () {
      final nc = NcSettle.headlineNc({
        'today_nc': {'label': 'Non-chargeable (NC) — not collected', 'hint': 'h', 'bills': 2, 'value': 1450.5},
      });
      expect(nc, (label: 'Non-chargeable (NC) — not collected', hint: 'h', bills: 2, value: 1450.5));
      expect(NcSettle.besideLine(2, 1450.5, _rupees), '2 NC bills · ₹1450.50 given away');
      expect(NcSettle.besideLine(1, 0, _rupees), '1 NC bill · ₹0.00 given away');
      expect(NcSettle.headlineNc({'today_nc': {'label': 'x', 'bills': 0, 'value': 0}}), isNull);
      expect(NcSettle.headlineNc({'today_nc': {'label': ' ', 'bills': 1, 'value': 1}}), isNull);
      expect(NcSettle.headlineNc({}), isNull);

      expect(NcSettle.salesSummary({'nc_bills': 1, 'nc_value': 1200}), (bills: 1, value: 1200.0));
      expect(NcSettle.salesSummary({'nc_bills': 0, 'nc_value': 0}), isNull);
      expect(NcSettle.settlementSummary({'nc': {'bills': 1, 'value': 1200}}), (bills: 1, value: 1200.0));
      expect(NcSettle.settlementSummary({}), isNull);
      expect(
        NcSettle.byScope({
          'by_scope': [
            {'scope': 'item', 'label': 'Item comped', 'entries': 0, 'loss': 0},
            {'scope': 'bill', 'label': 'Bill settled as NC', 'entries': 3, 'loss': 1200},
          ],
        }),
        [(scope: 'bill', label: 'Bill settled as NC', entries: 3, loss: 1200.0)],
      );

      final closed = {
        'payment_method': 'NC',
        'nc_settlement': {'kind_label': 'Staff meal', 'authorised_by': 'asha', 'reason': 'Team dinner', 'value': 1200, 'would_have_charged': 1386},
      };
      expect(NcSettle.settlement(closed),
          (kind: 'Staff meal', authorisedBy: 'asha', reason: 'Team dinner', value: 1200.0, wouldHaveCharged: 1386.0));
      expect(NcSettle.settlement({...closed, 'payment_method': 'Cash'}), isNull);
      expect(NcSettle.isMethod(' nc '), isTrue);
      expect(NcSettle.isMethod('Upi'), isFalse);
    });

    test('the paper: a comped line reads "(NC)" at 0.00, and its value is disclosed', () {
      expect(NcSettle.lineLabel('Gulab Jamun', true), 'Gulab Jamun (NC)');
      expect(NcSettle.lineLabel('Gulab Jamun', null), 'Gulab Jamun');
      expect(NcSettle.lineAmount(120, 2, true), 0);
      expect(NcSettle.lineAmount(120, 2, false), 240);
      expect(NcSettle.paperNcValue([
        {'name': 'A', 'price': 350, 'quantity': 1},
        {'name': 'B', 'price': 120, 'quantity': 2, 'nc': true},
        {'name': 'C', 'price': 99.5, 'quantity': 0, 'nc': true},
      ]), 339.5);
      expect(NcSettle.paperNcValue([{'name': 'A', 'price': 350, 'quantity': 1}]), isNull);
    });

    test('an NC settle is refused offline with the billing sentence, and never queued', () {
      final d = OutboxPolicy.decide('POST', '/bills/order/order-1/settle-nc');
      expect(d.queueable, isFalse);
      expect(d.refusal, contains('Billing needs a connection'));
    });
  });

  group('the settle sheet', () {
    testWidgets('a manager sees the NC pill beside the modes; choosing it swaps the form, and back', (tester) async {
      await _openSettle(tester);
      expect(find.byKey(const ValueKey('pay-method-NC')), findsOneWidget);
      expect(find.text(kNcSettlePill), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-settle')), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsNothing);

      await _tapVisible(tester, const ValueKey('pay-method-NC'));
      expect(find.byKey(const ValueKey('pay-nc-headline')), findsOneWidget);
      expect(find.text('NOTHING TO PAY · ₹1200.00 given away'), findsOneWidget);
      expect(find.textContaining('The guest would have paid ₹1386.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-nc-whole-bill')), findsOneWidget);
      // Nothing a bill that takes nothing would need.
      expect(find.byKey(const ValueKey('pay-amount')), findsNothing);
      expect(find.byKey(const ValueKey('pay-ref')), findsNothing);
      expect(find.byKey(const ValueKey('pay-add-tip')), findsNothing);
      expect(find.byKey(const ValueKey('pay-split')), findsNothing);
      expect(find.text('Approval is required before the bill closes and the table frees.'), findsNothing);
      // Not pressable until kind and reason are given (the authoriser is filled in).
      expect(_pressOf(tester, const ValueKey('pay-settle-nc')), isNull);
      expect(find.byKey(const ValueKey('pay-refusal')), findsOneWidget);
      final authoriser = tester.widget<TextField>(find.byKey(const ValueKey('pay-nc-authoriser')));
      expect(authoriser.controller!.text, _FakeApi.username);

      await _tapVisible(tester, const ValueKey('pay-method-Cash'));
      expect(find.byKey(const ValueKey('pay-settle')), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-nc-headline')), findsNothing);
      expect(find.byKey(const ValueKey('pay-amount')), findsOneWidget);
    });

    testWidgets('Settle as NC posts ONCE, with the quote — and never approves or closes', (tester) async {
      final api = await _openSettle(tester);
      api.replies['/bills/order/order-1/settle-nc'] = {
        'success': true, 'bill_id': 'bill-1', 'bill_no': '101', 'payment_method': 'NC',
        'total_amt': 0, 'nc_value': 1200.0, 'nc_lines': 2, 'printed': true,
      };
      await _fillNc(tester);
      expect(_pressOf(tester, const ValueKey('pay-settle-nc')), isNotNull);
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));

      final body = api.bodyOf('/settle-nc') as Map?;
      expect(body, {
        'nc_kind': 'staff_meal',
        'reason': 'Team dinner',
        'authorised_by': _FakeApi.username,
        'expected_value': 1200.0,
        'print': true,
      });
      expect(api.writes.where((w) => w.path.contains('settle-nc')), hasLength(1));
      expect(api.wrote('waiter-confirm-payment'), isFalse);
      expect(api.wrote('admin-approve-payment'), isFalse);
      expect(api.wrote('/close'), isFalse);
      expect(find.text('Bill 101 was settled as non-chargeable — ₹1200.00 given away, nothing collected. The NC bill is printing.'),
          findsOneWidget);
      // The sheet closed over a settled bill.
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsNothing);
    });

    testWidgets('a fully comped ₹0 bill opens as NC and is never sent as a ₹0 UPI settle', (tester) async {
      final api = await _openSettle(
        tester,
        bill: _bill(subtotal: 0, grand: 0, ncTotal: 760),
        tenders: _tenders(grand: 0),
      );
      expect(find.text('PAID IN FULL'), findsNothing);
      expect(find.text('NOTHING TO PAY · ₹760.00 given away'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-settle')), findsNothing);
      await _fillNc(tester, kind: 'complimentary', reason: 'Owner guests', tapPill: false);
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));
      expect((api.bodyOf('/settle-nc') as Map?)?['expected_value'], 0.0);
      expect(api.wrote('waiter-confirm-payment'), isFalse, reason: 'the UPI a 2.0.0 till sent');
    });

    testWidgets('money already taken greys the pill and says why', (tester) async {
      final api = await _openSettle(tester, tenders: _tenders(tendered: 400));
      final pill = tester.widget<GestureDetector>(
          find.descendant(of: find.byKey(const ValueKey('pay-method-NC')), matching: find.byType(GestureDetector)));
      expect(pill.onTap, isNull);
      expect(find.textContaining('₹400.00 is already recorded as paid on this bill'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pay-method-NC')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsNothing);
      expect(api.wrote('settle-nc'), isFalse);
    });

    testWidgets('a discount on the bill greys it too', (tester) async {
      await _openSettle(tester, bill: _bill(discount: 50, grand: 1330));
      expect(find.byKey(const ValueKey('pay-nc-blocked')), findsOneWidget);
      expect(find.textContaining('This bill carries a discount or a coupon.'), findsOneWidget);
    });

    testWidgets('a cashier (Close Bill, no comp permission) is not offered NC', (tester) async {
      await _openSettle(tester, actions: const [_permRecordPayment], role: 'cashier');
      expect(find.byKey(const ValueKey('pay-settle')), findsOneWidget, reason: 'the ordinary settle is still there');
      expect(find.byKey(const ValueKey('pay-method-NC')), findsNothing);
      expect(find.text(kNcSettlePill), findsNothing);
    });

    testWidgets('a custom role holding the comp permission and Close Bill is offered it', (tester) async {
      await _openSettle(tester, actions: const [_permNc, _permRecordPayment], role: 'superadmin');
      expect(find.byKey(const ValueKey('pay-method-NC')), findsOneWidget);
    });

    testWidgets('a waiter never reaches a settle control at all (C1)', (tester) async {
      await _mount(tester, m.tablesModule, _routes(), actions: const ['x'], role: 'waiter');
      await _openTable(tester);
      expect(find.text('Settle bill'), findsNothing);
      expect(find.byKey(const ValueKey('pay-method-NC')), findsNothing);
    });

    testWidgets('the server\'s refusal is shown verbatim and the bill is read again', (tester) async {
      final api = await _openSettle(tester);
      api.failOn = 'settle-nc';
      api.failMessage =
          'The bill changed while you were deciding: its food now comes to ₹1300.00, not ₹1200.00. Check it and settle again.';
      await _fillNc(tester);
      final readsBefore = api.calls.where((c) => c.contains('/bill-for-table')).length;
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));
      expect(find.text(api.failMessage), findsOneWidget);
      expect(api.calls.where((c) => c.contains('/bill-for-table')).length, greaterThan(readsBefore));
      // Still open, still in NC mode, the form kept.
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsOneWidget);
    });

    testWidgets('offline it refuses with the billing sentence and nothing is written or queued', (tester) async {
      final api = await _openSettle(tester);
      await _fillNc(tester);
      api.offline = true;
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));
      expect(find.textContaining('Billing needs a connection'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsOneWidget);
      expect(api.writes, isEmpty);
    });
  });

  // A PHONE WITH THE KEYBOARD UP. The tests above pump at 1400x1400. At
  // 360x640 a 260px keyboard leaves the dialog about 300px, and NC mode pinned
  // a four-line paragraph under its headline (plus a four-line refusal while
  // the form was incomplete): the enabled "Settle as NC" was pushed under the
  // keyboard, 69px of overflow with the form complete.
  group('the settle sheet on a phone', () {
    const phone = Size(360, 640);

    /// NC and a kind are chosen first (no keyboard), then the reason field is
    /// tapped: the keyboard comes up, and the reason is typed under it.
    Future<_FakeApi> ncWithKeyboard(WidgetTester tester, {required double keyboard, String? reason}) async {
      final api = await _openSettle(tester, bill: _bill(ncTotal: 240), size: phone);
      await _tapVisible(tester, const ValueKey('pay-method-NC'));
      await _tapVisible(tester, const ValueKey('pay-nc-kind-staff_meal'));
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byKey(const ValueKey('pay-nc-reason')));
      await tester.pumpAndSettle();
      if (reason != null) {
        await tester.enterText(find.byKey(const ValueKey('pay-nc-reason')), reason);
        await tester.pumpAndSettle();
      }
      return api;
    }

    testWidgets('a complete form: nothing overflows, and "Settle as NC" is above the keyboard', (tester) async {
      final api = await ncWithKeyboard(tester, keyboard: 260, reason: 'Team dinner');
      expect(tester.takeException(), isNull, reason: 'the NC form overflowed its dialog');
      final settle = find.byKey(const ValueKey('pay-settle-nc'));
      expect(_pressOf(tester, const ValueKey('pay-settle-nc')), isNotNull);
      expect(tester.getRect(settle).bottom, lessThanOrEqualTo(640.0 - 260),
          reason: 'the button is under the keyboard');
      expect(_reachable(tester, settle), isTrue);
      // The headline's figure is pinned; what it is made of scrolls.
      expect(find.byKey(const ValueKey('pay-nc-headline')), findsOneWidget);
      expect(_inSheetScroll(const ValueKey('pay-nc-headline')), findsNothing);
      expect(_inSheetScroll(const ValueKey('pay-nc-explanation')), findsOneWidget);

      await tester.tap(settle);
      await tester.pumpAndSettle();
      expect(api.writes.where((w) => w.path.contains('settle-nc')), hasLength(1));
    });

    testWidgets('an incomplete form: its refusal scrolls while the keyboard is up, and is pinned again after',
        (tester) async {
      await ncWithKeyboard(tester, keyboard: 300);
      expect(tester.takeException(), isNull, reason: 'the refusal pushed the form out of its dialog');
      expect(_inSheetScroll(const ValueKey('pay-refusal')), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('pay-settle-nc'))).bottom, lessThanOrEqualTo(640.0 - 300));

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pay-refusal')), findsOneWidget);
      expect(_inSheetScroll(const ValueKey('pay-refusal')), findsNothing,
          reason: 'with room to spare the reason stands beside the button');
    });

    testWidgets('pressing "Settle as NC" puts the keyboard away, so its refusal is read beside the button',
        (tester) async {
      final api = await ncWithKeyboard(tester, keyboard: 260, reason: 'Team dinner');
      expect(tester.testTextInput.isVisible, isTrue);
      api.failOn = 'settle-nc';
      api.failMessage = 'Another device changed this bill at the same moment. Refresh it and try again.';
      api.failStatus = 409;
      await tester.tap(find.byKey(const ValueKey('pay-settle-nc')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse, reason: 'the keyboard stayed up over the refusal');
      expect(find.text(api.failMessage), findsOneWidget);
    });

    testWidgets('the payment form fits too, with its approval line', (tester) async {
      await _openSettle(tester, size: phone);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the payment form overflowed its dialog');
      expect(_inSheetScroll(const ValueKey('pay-method-NC')), findsOneWidget);
      expect(find.descendant(of: find.byType(SingleChildScrollView), matching: find.text('Approval is required before the bill closes and the table frees.')),
          findsOneWidget);
      expect(_reachable(tester, find.byKey(const ValueKey('pay-settle'))), isTrue);
    });
  });

  // AN OLDER SERVER. A 2.0.1 till can meet a backend without the settle-nc
  // route: before that backend is deployed, or after it is rolled back (the
  // auto-updater cannot downgrade the app). Express answers the unknown route
  // with its own HTML 404, which this app could only call "Request failed
  // (404).", and a fully comped ₹0 bill opens in NC mode with no other action.
  group('a server without the settle-nc route', () {
    testWidgets('the pill steps aside, the sheet says why, and "Settle & close" is back', (tester) async {
      final api = await _openSettle(
        tester,
        bill: _bill(subtotal: 0, grand: 0, ncTotal: 760),
        tenders: _tenders(grand: 0),
      );
      api.failOn = 'settle-nc';
      api.failStatus = 404;
      api.failWithoutBody = true;
      await _fillNc(tester, kind: 'complimentary', reason: 'Owner guests', tapPill: false);
      final readsBefore = api.calls.where((c) => c.contains('/bill-for-table')).length;
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));

      expect(find.text(kNcSettleUnsupported), findsOneWidget);
      expect(find.text('Request failed (404).'), findsNothing);
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsNothing);
      expect(find.byKey(const ValueKey('pay-method-NC')), findsNothing,
          reason: 'offered again on a server that has no route');
      expect(find.byKey(const ValueKey('pay-nc-headline')), findsNothing);
      expect(api.calls.where((c) => c.contains('/bill-for-table')).length, readsBefore,
          reason: 're-reading the bill reopens the NC form');
      expect(_pressOf(tester, const ValueKey('pay-settle')), isNotNull);

      // The ₹0 settle this server has always taken.
      await _tapVisible(tester, const ValueKey('pay-settle'));
      expect(api.wrote('waiter-confirm-payment'), isTrue);
      expect(api.writes.where((w) => w.path.contains('settle-nc')), isEmpty);
    });

    testWidgets('CONTROL — a 404 the 2.0.1 route writes itself is an ordinary refusal: NC stays', (tester) async {
      final api = await _openSettle(tester);
      api.failOn = 'settle-nc';
      api.failStatus = 404;
      api.failMessage = 'That order is not open on this outlet.';
      await _fillNc(tester);
      await _tapVisible(tester, const ValueKey('pay-settle-nc'));
      expect(find.text(api.failMessage), findsOneWidget);
      expect(find.text(kNcSettleUnsupported), findsNothing);
      expect(find.byKey(const ValueKey('pay-settle-nc')), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-method-NC')), findsOneWidget);
    });

    test('only a bodiless 404 means the route is missing', () {
      expect(NcSettle.routeMissing(status: 404, body: null), isTrue);
      expect(NcSettle.routeMissing(status: 404, body: const {'error': 'Order not found'}), isFalse);
      expect(NcSettle.routeMissing(status: 400, body: null), isFalse);
      expect(NcSettle.routeMissing(status: null, body: null), isFalse, reason: 'an outage is not an old server');
      expect(NcSettle.routeMissing(status: 503, body: null), isFalse);
    });
  });

  group('the bill preview', () {
    testWidgets('a comped line reads "<dish> (NC)" at 0.00, and its value sits under the total', (tester) async {
      await _mount(
        tester,
        m.tablesModule,
        _routes(
          bill: _bill(subtotal: 700, grand: 808.5, ncTotal: 500, items: const [
            {'name': 'Paneer Tikka', 'price': 350.0, 'quantity': 2},
            {'name': 'Dal Makhani', 'price': 500.0, 'quantity': 1, 'nc': true},
          ]),
        ),
      );
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.pumpAndSettle();
      expect(find.text('Dal Makhani (NC)'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsWidgets);
      expect(find.text('700.00'), findsWidgets, reason: 'the paid line and the Sub Total');
      expect(find.text('0.00'), findsWidgets, reason: 'the comped line');
      expect(find.byKey(const ValueKey('bill-preview-nc-value')), findsOneWidget);
      expect(find.text('NC value (not charged)'), findsOneWidget);
      expect(find.text('500.00'), findsWidgets);
    });

    testWidgets('a bill with nothing comped has no NC line', (tester) async {
      await _mount(tester, m.tablesModule, _routes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bill-preview-nc-value')), findsNothing);
      expect(find.textContaining('(NC)'), findsNothing);
    });
  });

  // THE RUNNING-BILL SHEET, opened from the order pad's bill strip and from
  // the Orders module's "View order". It printed a comped dish at its full
  // price above a Subtotal that leaves that dish out (GetBillForTable keeps
  // the line's price, marks it `nc: true`, and reports its value in
  // `nc_total`), so the column did not add up.
  group('the running-bill sheet', () {
    Map<String, dynamic> comped() => _bill(subtotal: 700, grand: 808.5, ncTotal: 500, items: const [
          {'name': 'Paneer Tikka', 'price': 350.0, 'quantity': 2},
          {'name': 'Dal Makhani', 'price': 500.0, 'quantity': 1, 'nc': true},
        ]);

    Future<void> openSheet(WidgetTester tester, Map<String, dynamic> bill, {bool waiter = false}) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final api = _FakeApi({'/bill-for-table': bill},
          actions: waiter ? const ['x'] : const ['*'], role: waiter ? 'waiter' : 'admin');
      final auth = AuthController(api: api);
      await auth.login('CSR Organics', 'staff', 'pw');
      final rest = RestClient(auth);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTableBillSheet(ctx, rest: rest, tableName: 'T1', profile: rest.auth.profile),
                child: const Text('open bill'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open bill'));
      await tester.pumpAndSettle();
    }

    testWidgets('a comped dish reads "(NC)" at ₹0.00, the column adds up, and its value sits under the total',
        (tester) async {
      await openSheet(tester, comped());
      expect(find.text('Dal Makhani (NC)  ×1'), findsOneWidget);
      expect(find.text('Paneer Tikka  ×2'), findsOneWidget);
      expect(find.text('₹0.00'), findsOneWidget, reason: 'the comped line');
      expect(find.text('₹500.00'), findsOneWidget, reason: 'only the NC value row, never the comped line');
      // The paid line and the Subtotal (and the running bill in the strip).
      expect(find.text('₹700.00'), findsWidgets);
      final nc = find.byKey(const ValueKey('table-bill-nc-value'));
      expect(nc, findsOneWidget);
      expect(find.descendant(of: nc, matching: find.text('NC value (not charged)')), findsOneWidget);
      expect(find.descendant(of: nc, matching: find.text('₹500.00')), findsOneWidget);
      expect(tester.getTopLeft(nc).dy, greaterThan(tester.getTopLeft(find.text('TOTAL PAYABLE')).dy),
          reason: 'beside the total, never in it');
    });

    testWidgets('nothing comped: no marker and no NC row', (tester) async {
      await openSheet(tester, _bill());
      expect(find.textContaining('(NC)'), findsNothing);
      expect(find.byKey(const ValueKey('table-bill-nc-value')), findsNothing);
      expect(find.text('₹700.00'), findsOneWidget, reason: 'Paneer Tikka x2 at its full price');
    });

    testWidgets('a waiter sees the dishes as before: no figures, and no NC marker', (tester) async {
      await openSheet(tester, comped(), waiter: true);
      expect(find.text('Dal Makhani  ×1'), findsOneWidget);
      expect(find.textContaining('(NC)'), findsNothing);
      expect(find.textContaining('₹'), findsNothing);
      expect(find.byKey(const ValueKey('table-bill-nc-value')), findsNothing);
    });
  });

  group('the overview', () {
    Map<String, dynamic> headline({Map<String, dynamic>? nc}) => {
          'today': '2026-09-16', 'month_from': '2026-09-01', 'timezone': 'Asia/Kolkata',
          'today_net': {'value': 1000, 'label': "Today's net sale", 'hint': 'x'},
          'today_gross': {'value': 1100, 'label': "Today's gross sale", 'hint': 'x'},
          'cash_collection': {'value': 1100, 'label': 'Cash collection', 'hint': 'x'},
          'today_bills': 2, 'month_bills': 2,
          'today_by_method': [
            {'method': 'Cash', 'label': 'Cash', 'bills': 1, 'amount': 1100, 'share_pct': 100, 'refund': 0, 'net_amount': 1100},
          ],
          'today_split_bills': 0, 'today_unallocated': 0,
          'by_method': {'label': 'Collected by payment method', 'hint': 'x'},
          'today_nc': ?nc,
        };

    testWidgets('today\'s NC is its own labelled line under the by-method block', (tester) async {
      await _mount(
        tester,
        m.overviewModule,
        {
          '/analytics/headline': headline(nc: {
            'label': 'Non-chargeable (NC) — not collected',
            'hint': 'Given away today at menu value before tax.',
            'bills': 1,
            'value': 1200,
          }),
        },
        labels: const ['Overview', 'Accounting'],
      );
      expect(find.byKey(const ValueKey('headline-nc')), findsOneWidget);
      expect(find.text('NON-CHARGEABLE (NC) — NOT COLLECTED'), findsOneWidget);
      expect(find.text('1 NC bill · ₹1200.00 given away'), findsOneWidget);
      // Beside the modes, never one of them.
      final byMethod = tester.getTopLeft(find.text('COLLECTED BY PAYMENT METHOD'));
      final nc = tester.getTopLeft(find.byKey(const ValueKey('headline-nc')));
      expect(nc.dy, greaterThan(byMethod.dy));
      expect(find.text(kNcSettleLabel), findsNothing, reason: 'no by-method bar is called NC');
    });

    testWidgets('an older backend, or a day with no NC, draws nothing', (tester) async {
      await _mount(tester, m.overviewModule, {'/analytics/headline': headline()}, labels: const ['Overview', 'Accounting']);
      expect(find.byKey(const ValueKey('headline-nc')), findsNothing);
    });
  });

  group('the wiring the widgets above do not reach', () {
    String read(String rel) => File(rel).readAsStringSync().replaceAll('\r\n', '\n');

    test('the report panels and the closed bill read the NC figures', () {
      final reports = read('lib/screens/reports.dart');
      expect(reports, contains('final salesNc = NcSettle.salesSummary(totals);'));
      expect(reports, contains('final settleNc = NcSettle.settlementSummary(totals);'));
      expect(reports, contains('final scopes = NcSettle.byScope(d);'));
      expect(RegExp(r'_misNcBeside\(').allMatches(reports).length, 3, reason: 'two calls and the definition');
      // The kitchen-ticket drill-down marks a comped line, as the web one does.
      expect(reports, contains("Text(NcSettle.lineLabel(_s(it, 'name'), it['nc']), style: text.bodyMedium),"));
      final modules = read('lib/screens/modules.dart');
      expect(modules, contains("import '../models/nc_settle.dart';"));
      expect(modules, contains('final ncSettled = NcSettle.settlement(bill);'));
      expect(modules, contains("NcSettle.lineLabel(_s(items[i], 'name', 'Item'), items[i]['nc'])"));
      expect(modules, contains("money(method.isEmpty ? 'Method not recorded' : methodShown, _money(grand)),"));
      expect(modules, contains('final ncToday = _headlineNc(context, h);'));
      expect(modules, contains('label: NcSettle.isMethod(method) ? kNcSettleLabel : method),'),
          reason: 'the settled-bill row names an NC bill as the paper does');
    });

    test('the sheet posts to the route the server registers, and only there', () {
      final sheet = read('lib/screens/mis_capture.dart');
      expect(sheet, contains("'/bills/order/\$oid/settle-nc'"));
      final start = sheet.indexOf('Future<void> _settleAsNc() async {');
      final end = sheet.indexOf('String? get _settleRefusal', start);
      expect(start, greaterThan(-1));
      final act = sheet.substring(start, end);
      expect(act, isNot(contains('admin-approve-payment')));
      expect(act, isNot(contains('/close')));
      expect(act, isNot(contains('waiter-confirm-payment')));
      expect(act, contains('expectedValue: NcSettle.value(_ncBill)'));
    });

    test('the same words as the web dashboard and the backend (when their checkouts are beside this one)', () {
      final web = File('../Restaurant_Dashboard_UI/src/lib/nc-settle.ts');
      if (web.existsSync()) {
        final src = web.readAsStringSync();
        expect(src, contains("export const NC_SETTLE_LABEL = '$kNcSettleLabel';"));
        expect(src, contains("export const NC_SETTLE_BUTTON = '$kNcSettleButton';"));
        expect(src, contains("'$kNcWholeBillOnly'"));
        expect(src, contains('NOTHING TO PAY · '));
      }
      final backend = File('../Restaurant_Backend/nc_settle.ts');
      if (backend.existsSync()) {
        expect(backend.readAsStringSync(), contains('"$kNcWholeBillOnly"'));
      }
      final methods = File('../Restaurant_Backend/payment_methods.ts');
      if (methods.existsSync()) {
        expect(methods.readAsStringSync(), contains('export const NC_SETTLE_LABEL = "$kNcSettleLabel";'));
      }
    });
  });
}
