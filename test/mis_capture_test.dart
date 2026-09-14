import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// THE CAPTURE SCREENS — migrations 034-039, from the till's side.
///
/// Six facts had routes and no way for a restaurant to reach them, which meant
/// six permanently empty reports. These tests pin the promises that make the
/// writing side trustworthy, because a control ledger is only worth the
/// discipline of the screen that fills it:
///
///   * THE ACTOR IS THE SESSION. No form here may carry an "acting user" field.
///     `authorised_by` is the SECOND name and is a field on purpose; a till that
///     could name its own cashier could sign someone else's comp.
///   * A CONTROL THAT WOULD 403 IS NOT OFFERED. The three manager acts default
///     to manager-only, so a waiter gets a disabled control WITH THE REASON, and
///     never one that fails under a guest's nose.
///   * A REVERSAL IS SUPERSESSION. Nothing here deletes: a comp, a waiver and a
///     tender all stay on the record, stamped, and drop out of the live totals.
///   * A TIP IS NOT PART OF THE BILL. It is never folded into a tender's amount,
///     which is the only reason a tipped bill still reconstructs its total.
///   * THE COMMON SETTLE DID NOT CHANGE. One method, no tip, no split sends the
///     body it has always sent — the busy Saturday must not get slower to buy a
///     report a column.
///   * NOTHING QUEUES. Every route here is refused offline, with the billing
///     sentence where it is a bill, and the outbox allowlist is untouched.
///   * NO BULK MENU SAVE, EVER. Groups and variations are targeted writes; a
///     `PUT /menu` from this feature would be the bug that wiped 56 items.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.actions = const ['*'], this.role = 'admin'});

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;

  /// The signed-in LOGIN identity. It is what the capture forms pre-fill
  /// `authorised_by` with — never the actor, which comes from the session on
  /// the server and has no field anywhere in this feature.
  static const String username = 'manager01';

  /// Every request in order, as `'POST /path'`.
  final List<String> calls = <String>[];

  /// The body of every write, in order, beside its path.
  final List<({String method, String path, Object? body})> writes = [];

  /// When set, EVERY request fails the way a dead line fails: an ApiException
  /// with NO status, which is the only shape RestClient treats as an outage.
  bool offline = false;

  /// A path fragment the fake refuses with a real 400, message and all.
  String failOn = '';
  String failMessage = 'refused';

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
          'employeeUsername': username,
          'role': role,
          'actions_set': actions,
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (offline) throw ApiException('Connection failed');
    calls.add('$method $path');
    if (failOn.isNotEmpty && path.contains(failOn)) {
      throw ApiException(failMessage, 400);
    }
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a query-carrying family.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  Object? bodyOf(String pathFragment) {
    for (final w in writes) {
      if (w.path.contains(pathFragment)) return w.body;
    }
    return null;
  }

  bool wrote(String method, String pathFragment) =>
      writes.any((w) => w.method == method && w.path.contains(pathFragment));
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Tables', 'Orders', 'Menu', 'Settings'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _size(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  List<String> actions = const ['*'],
  String role = 'admin',
  double width = 1400,
  double height = 1200,
}) async {
  await tester.pumpWidget(const SizedBox());
  _size(tester, width, height);
  final api = _FakeApi(routes, actions: actions, role: role);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

// ------------------------------------------------------------------ fixtures

/// One occupied table with an open bill, one order of two lines, a live service
/// charge and a comp already recorded against the second line.
Map<String, dynamic> _table({bool occupied = true}) => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': occupied,
      'reserved': false,
      'num_covers': 3,
    };

Map<String, dynamic> _bill({
  double serviceCharge = 120.0,
  bool waived = false,
  double ncTotal = 0,
}) =>
    {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': 1200.0,
      'subtotal': 1200.0,
      'discount': 0.0,
      'discount_type': null,
      'discount_value': 0.0,
      'service_charge': waived ? 0.0 : serviceCharge,
      'service_charge_percent': 10.0,
      'service_charge_waived': waived,
      'service_charge_waiver': waived
          ? {
              'id': 'w-1',
              'bill_id': 'bill-1',
              'waiver_kind': 'guest_complaint',
              'reason': 'Long wait for the mains',
              'amount_waived': 120.0,
              'tax_on_waived': 6.0,
              // The two DIFFER whenever tax rode on the charge, and the guest is
              // told the second one.
              'grand_total_reduction': 126.0,
              'waived_by_username': 'asha',
              'authorised_by_username': 'manager01',
              'reversed_at': null,
            }
          : null,
      'taxes': const [
        {'name': 'CGST', 'percentage': 2.5, 'amount': 30.0},
      ],
      'tax_total': 60.0,
      'grand_total': waived ? 1260.0 : 1380.0,
      'nc_total': ncTotal,
      'covers': 3,
      'apc': 400.0,
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
        {'name': 'Gulab Jamun', 'price': 120.0, 'quantity': 1},
      ],
      'target_apc': 0,
      'apc_status': 'neutral',
      'apc_suggestions': const [],
      'payment_method': null,
      'payment_status': null,
      'bill_no': '101',
    };

/// The ORDER behind that bill. Its lines carry ids — the bill's do not, because
/// `/bill-for-table` merges them for printing, which is exactly why the comp
/// sheet works off this and not off the bill.
List<Map<String, dynamic>> _orders({String status = 'Preparing'}) => [
      {
        'id': 'order-1',
        'table': 'T1',
        'status': status,
        'order_type': 'dine_in',
        'customer': 'Guest',
        'total': 760.0,
        'created_at': '2026-08-01T12:00:00.000Z',
        'barked_at': '2026-08-01T12:01:00.000Z',
        'taken_by_employee_name': 'Asha',
        'items': [
          {'id': 'item-1', 'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
          {'id': 'item-2', 'name': 'Gulab Jamun', 'price': 120.0, 'quantity': 1},
        ],
      },
    ];

Map<String, dynamic> _tableRoutes({
  Map<String, dynamic>? bill,
  List<Map<String, dynamic>>? orders,
  List<Map<String, dynamic>> comps = const [],
  Map<String, dynamic>? tenderState,
  List<Map<String, dynamic>> counters = const [],
}) =>
    {
      '/get-tables': [_table()],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': bill ?? _bill(),
      '/orders/scope': {'outlets': <dynamic>[], 'is_all_outlets': false},
      '/orders': orders ?? _orders(),
      '/orders/order-1/non-chargeables': {'non_chargeables': comps},
      '/bills/tenders': tenderState ??
          {
            'bill_id': 'bill-1',
            'grand_total': 1380.0,
            'tenders': <dynamic>[],
            'tendered': 0.0,
            'outstanding': 1380.0,
            'exact': false,
            'partial': false,
            'over': false,
            'tips_total': 0.0,
            'payment_method': null,
            'payment_splits': <dynamic>[],
          },
      '/billing-counters': {'counters': counters},
    };

/// Open the table sheet for T1.
Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

/// Scroll a sheet until [finder] is on screen. The table sheet is taller than
/// any test window.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

/// The onPressed of the ForkButton carrying [key] — null means the control is
/// present but deliberately inert.
VoidCallback? _pressOf(WidgetTester tester, Key key) =>
    tester.widget<ForkButton>(find.byKey(key)).onPressed;

/// Fill the shared reason form and confirm it.
Future<void> _fillReason(
  WidgetTester tester, {
  String? kind,
  String reason = 'Because it was cold',
  String? authoriser,
}) async {
  if (kind != null) {
    await tester.tap(find.byKey(ValueKey('capture-kind-$kind')));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byKey(const ValueKey('capture-reason')), reason);
  await tester.pumpAndSettle();
  if (authoriser != null) {
    await tester.enterText(find.byKey(const ValueKey('capture-authoriser')), authoriser);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('capture-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(m.misResetCaptureMemory);

  // ==========================================================================
  // 034 — NON-CHARGEABLE
  // ==========================================================================

  group('034 · comp a dish', () {
    testWidgets('a manager is offered it; a waiter does not see it at all',
        (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      expect(_pressOf(tester, const ValueKey('table-comps')), isNotNull);

      // THIS REVERSED IN V3 AND THE REVERSAL IS THE CLIENT'S. Until then a
      // waiter saw the control dimmed, labelled "manager only", on the argument
      // that they need to know a comp EXISTS so they fetch a manager rather than
      // arguing with a guest about a screen with no such option. The V3
      // requirements say "completely hidden", so it is gone — and the thing
      // traded away is exactly that discoverability. See
      // FloorScope.managerOnlyAsks, which is the single flag to flip if the pass
      // finds it costs more than the clutter did.
      await _mount(tester, m.tablesModule, _tableRoutes(),
          actions: const ['x'], role: 'waiter');
      await _openTable(tester);
      // No _reveal: that helper scrolls UNTIL VISIBLE and throws when the target
      // does not exist, which is precisely what is being asserted here. The
      // sheet is fully built by _openTable, so an absent control is absent from
      // the tree whether or not anything scrolls.
      expect(find.byKey(const ValueKey('table-comps')), findsNothing);
      expect(find.textContaining('Comp an item'), findsNothing);
    });

    testWidgets('a disabled control LOOKS disabled — no click cursor, no hover lift',
        (tester) async {
      // The dead-looking control is a known bug class here, and every gated
      // affordance in the product rides on this one widget: before this, a null
      // onPressed rendered identically to a live button.
      //
      // DRIVEN WITH A CASHIER, NOT A WAITER, since V3 removed the control from a
      // waiter entirely — there would be no disabled button left to inspect. The
      // property under test is about the WIDGET and not about waiters: somebody
      // who may see a control but not operate it must be able to tell.
      await _mount(tester, m.tablesModule, _tableRoutes(),
          actions: const ['x'], role: 'cashier');
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));

      final region = tester.widget<MouseRegion>(find.descendant(
        of: find.byKey(const ValueKey('table-comps')),
        matching: find.byType(MouseRegion),
      ));
      expect(region.cursor, MouseCursor.defer,
          reason: 'a disabled button must not invite a click');

      final opacity = tester.widget<Opacity>(find.descendant(
        of: find.byKey(const ValueKey('table-comps')),
        matching: find.byType(Opacity),
      ));
      expect(opacity.opacity, lessThan(1.0), reason: 'a disabled button must read as disabled');

      // …and a live one is untouched.
      await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      final live = tester.widget<MouseRegion>(find.descendant(
        of: find.byKey(const ValueKey('table-comps')),
        matching: find.byType(MouseRegion),
      ));
      expect(live.cursor, SystemMouseCursors.click);
      final liveOpacity = tester.widget<Opacity>(find.descendant(
        of: find.byKey(const ValueKey('table-comps')),
        matching: find.byType(Opacity),
      ));
      expect(liveOpacity.opacity, 1.0);
    });

    testWidgets('comping a whole line posts the kind, the reason and the SECOND name — and no actor',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();

      // The whole-line case: Gulab Jamun is a quantity of one, so there is no
      // stepper and nothing to choose.
      await tester.tap(find.byKey(const ValueKey('nc-comp-item-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-nc-qty')), findsNothing);

      await _fillReason(tester, kind: 'guest_complaint', reason: 'Dessert arrived cold');

      final body = api.bodyOf('/items/item-2/non-chargeable') as Map?;
      expect(body, isNotNull, reason: 'the comp never reached the server');
      expect(body!['nc_kind'], 'guest_complaint');
      expect(body['reason'], 'Dessert arrived cold');
      // Pre-filled from the SESSION's own username: a manager acting alone signs
      // their own name and the ledger then says so.
      expect(body['authorised_by'], 'manager01');
      // Absent means the WHOLE line. Sending a quantity equal to the line would
      // make the data layer split it and leave a chargeable remainder of zero.
      expect(body.containsKey('quantity'), isFalse);
      // THE ACTOR IS THE SESSION. No form in this feature may carry one.
      for (final k in const ['marked_by', 'actor', 'employee_id', 'username']) {
        expect(body.containsKey(k), isFalse, reason: '$k must never come from a form');
      }
    });

    testWidgets('a partial comp sends the quantity, and says what stays on the bill',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();

      // Paneer Tikka is a quantity of two, so the stepper is offered.
      await tester.tap(find.byKey(const ValueKey('nc-comp-item-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-nc-qty')), findsOneWidget);
      expect(find.text('The whole line'), findsOneWidget);

      await tester.tap(find.byTooltip('One fewer'));
      await tester.pumpAndSettle();
      // The consequence, in words, before anything is written.
      expect(find.text('The other 1 stay on the bill'), findsOneWidget);

      await _fillReason(tester, kind: 'staff_meal', reason: 'One went to the kitchen');
      final body = api.bodyOf('/items/item-1/non-chargeable') as Map?;
      expect(body!['quantity'], 1);
    });

    testWidgets('the form refuses to submit until it could actually succeed', (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nc-comp-item-2')));
      await tester.pumpAndSettle();

      // A kind is pre-selected, but a blank reason is not a reason: the server
      // would 400 naming a field, and a disabled button is a better answer.
      expect(_pressOf(tester, const ValueKey('capture-confirm')), isNull);
      await tester.enterText(find.byKey(const ValueKey('capture-reason')), 'On the house');
      await tester.pumpAndSettle();
      expect(_pressOf(tester, const ValueKey('capture-confirm')), isNotNull);

      // Clearing the authoriser disables it again — the second name is the whole
      // control and is never optional.
      await tester.enterText(find.byKey(const ValueKey('capture-authoriser')), '');
      await tester.pumpAndSettle();
      expect(_pressOf(tester, const ValueKey('capture-confirm')), isNull);
    });

    testWidgets('a LIVE comp offers a reversal and needs no second name for it', (tester) async {
      final api = await _mount(
        tester,
        m.tablesModule,
        _tableRoutes(comps: [
          {
            'id': 'nc-1',
            'order_id': 'order-1',
            'item_id': 'item-2',
            'item_name': 'Gulab Jamun',
            'nc_kind': 'complimentary',
            'reason': 'Regular guest',
            'quantity': 1,
            'unit_price': 120.0,
            'value': 120.0,
            'marked_by_username': 'asha',
            'authorised_by_username': 'manager01',
            'reversed_at': null,
          },
        ]),
      );
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();

      // The comped line reads as comped, with both names and the money.
      expect(find.byKey(const ValueKey('nc-comp-item-2')), findsNothing);
      expect(find.byKey(const ValueKey('nc-reverse-item-2')), findsOneWidget);
      expect(find.textContaining('given away'), findsWidgets);
      expect(find.textContaining('By manager01'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nc-reverse-item-2')));
      await tester.pumpAndSettle();
      // NO SECOND NAME on a reversal: putting a charge back on a guest is not
      // the act the control exists to catch, and requiring another person to
      // undo a mistake is how mistakes get left standing.
      expect(find.byKey(const ValueKey('capture-authoriser')), findsNothing);
      await _fillReason(tester, reason: 'Comped in error');

      final body = api.bodyOf('/non-chargeables/nc-1/reverse') as Map?;
      expect(body, isNotNull);
      expect(body!['reason'], 'Comped in error');
      expect(body.containsKey('authorised_by'), isFalse);
    });

    testWidgets('a REVERSED comp is chargeable again, so the line offers Comp, not Reverse',
        (tester) async {
      await _mount(
        tester,
        m.tablesModule,
        _tableRoutes(comps: [
          {
            'id': 'nc-1',
            'order_id': 'order-1',
            'item_id': 'item-2',
            'item_name': 'Gulab Jamun',
            'nc_kind': 'complimentary',
            'reason': 'Regular guest',
            'quantity': 1,
            'unit_price': 120.0,
            'value': 120.0,
            'marked_by_username': 'asha',
            'authorised_by_username': 'manager01',
            // Superseded, not deleted: the ledger row stays and the LINE is
            // billable again.
            'reversed_at': '2026-08-01T13:00:00.000Z',
            'reversed_by_username': 'manager01',
          },
        ]),
      );
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nc-comp-item-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('nc-reverse-item-2')), findsNothing);
    });

    testWidgets('the bill SHOWS what was comped instead of the dish simply not appearing',
        (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes(bill: _bill(ncTotal: 120.0)));
      await _openTable(tester);
      await _reveal(tester, find.text('Non-chargeable (given away)'));
      expect(find.text('Non-chargeable (given away)'), findsOneWidget);
      expect(find.text('₹120.00'), findsWidgets);
    });
  });

  // ==========================================================================
  // 035 — VOID WITH A REASON
  // ==========================================================================

  group('035 · void with a reason', () {
    testWidgets('a manager declining a pending order records WHY, on the void route',
        (tester) async {
      final api = await _mount(
        tester,
        m.ordersModule,
        _tableRoutes(orders: _orders(status: 'Pending')),
      );
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();

      await _fillReason(tester, kind: 'duplicate', reason: 'Rung twice by mistake');

      final body = api.bodyOf('/orders/order-1/void') as Map?;
      expect(body, isNotNull, reason: 'a manager cancel must carry a reason');
      expect(body!['void_kind'], 'duplicate');
      expect(body['reason'], 'Rung twice by mistake');
      expect(body['authorised_by'], 'manager01');
      // The STAGE is derived server-side from facts the client cannot reach —
      // the person whose void it is has an obvious interest in "before_print".
      expect(body.containsKey('stage'), isFalse);
      // …and the old reasonless route was not used.
      expect(api.wrote('PATCH', '/orders/order-1/status'), isFalse);
    });

    // ---- REQUIREMENT A2 CHANGED THIS TEST, AND THE CHANGE IS THE POINT ----
    //
    // WHAT IT USED TO SAY. "A waiter keeps the fast path" was written as "no
    // form at all", on the reasoning that demanding a reason AND an authoriser
    // from somebody who holds neither permission would stop a live floor
    // cancelling anything. Half of that reasoning was right and half was a
    // conflation: the thing that cannot be demanded of a waiter is the SECOND
    // NAME, and the thing that cannot be demanded of the network is the STRICT
    // VOID ROUTE, which is outside the offline queue. Neither of those is a
    // reason to let a cancellation through with no explanation at all — and A2
    // asks, in as many words, for a mandatory reason before any cancel is
    // processed.
    //
    // WHAT IT SAYS NOW. The prompt is unconditional; the ROUTE still is not. A
    // waiter is asked why, in the same words as everybody else, and their answer
    // then travels on the queueable PATCH — no authoriser, no /void, nothing
    // that could fail when the wifi drops mid-service.
    testWidgets('a waiter is asked WHY, and still travels the fast path',
        (tester) async {
      final api = await _mount(
        tester,
        m.ordersModule,
        _tableRoutes(orders: _orders(status: 'Pending')),
        actions: const ['x'],
        role: 'waiter',
      );
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();

      // A2: THE PROMPT IS THERE, and nothing has been written yet.
      expect(find.byKey(const ValueKey('capture-reason')), findsOneWidget);
      expect(api.wrote('PATCH', '/orders/order-1/status'), isFalse);
      // …and no second name is demanded of somebody who cannot be their own
      // authoriser. That is what "keeps the fast path" actually protected.
      expect(find.byKey(const ValueKey('capture-authoriser')), findsNothing);

      await _fillReason(tester, kind: 'guest_changed_mind', reason: 'Guest left');

      expect(api.wrote('PATCH', '/orders/order-1/status'), isTrue);
      expect(api.wrote('POST', '/orders/order-1/void'), isFalse);
      final body = api.bodyOf('/orders/order-1/status') as Map?;
      expect(body, isNotNull);
      expect(body!['status'], 'Cancelled');
      // The reason rides along on the queueable route. A server that has not
      // been taught the field ignores it and the cancel behaves exactly as it
      // does today — which is what lets this ship ahead of the server change.
      expect(body['reason'], 'Guest left');
      expect(body['cancel_kind'], 'guest_changed_mind');
    });

    // A2's other half: MANDATORY means backing out cancels nothing.
    testWidgets('dismissing the reason prompt cancels nothing at all',
        (tester) async {
      final api = await _mount(
        tester,
        m.ordersModule,
        _tableRoutes(orders: _orders(status: 'Pending')),
        actions: const ['x'],
        role: 'waiter',
      );
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      // The confirm is inert until a reason is typed — the prompt cannot be
      // satisfied by pressing through it.
      final confirm = tester.widget<ForkButton>(find.byKey(const ValueKey('capture-confirm')));
      expect(confirm.onPressed, isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.wrote('PATCH', '/orders/order-1/status'), isFalse);
      expect(api.wrote('POST', '/orders/order-1/void'), isFalse);
    });
  });

  // ==========================================================================
  // 036 — SERVICE CHARGE WAIVER
  // ==========================================================================

  group('036 · waive the service charge', () {
    testWidgets('nothing is offered on an outlet that charges none', (tester) async {
      await _mount(
        tester,
        m.tablesModule,
        _tableRoutes(bill: _bill(serviceCharge: 0)),
      );
      await _openTable(tester);
      // Offering to waive a charge that does not exist is a control that 400s.
      expect(find.byKey(const ValueKey('sc-waiver-apply')), findsNothing);
      expect(find.byKey(const ValueKey('sc-waiver-reverse')), findsNothing);
    });

    testWidgets('waiving posts the table, the kind, the reason and the second name',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-apply')));
      await tester.tap(find.byKey(const ValueKey('sc-waiver-apply')));
      await tester.pumpAndSettle();

      await _fillReason(tester, kind: 'goodwill', reason: 'Regular, long wait');

      final body = api.bodyOf('/bills/service-charge-waiver') as Map?;
      expect(body, isNotNull);
      // The TABLE, not the bill id: WaiveServiceCharge resolves the table's open
      // bill and mints one where the table has none — which is the case a guest
      // asks about before the bill has been raised.
      expect(body!['table_name'], 'T1');
      expect(body['waiver_kind'], 'goodwill');
      expect(body['reason'], 'Regular, long wait');
      expect(body['authorised_by'], 'manager01');
    });

    testWidgets('a waiter sees neither the control nor its explanation', (tester) async {
      // V3: "completely hidden ... including its accompanying text". 1.8.6
      // shipped the opposite deliberately — inert, with the reason beside it —
      // and the sentence went with the control when the client asked for both.
      await _mount(tester, m.tablesModule, _tableRoutes(),
          actions: const ['x'], role: 'waiter');
      await _openTable(tester);
      // See the note on the comp case: _reveal throws on a missing target.
      expect(find.byKey(const ValueKey('sc-waiver-apply')), findsNothing);
      expect(find.textContaining('Only a manager can waive a service charge'), findsNothing);
    });

    testWidgets('a cashier still sees it inert, with the reason beside it', (tester) async {
      // The visible-but-inert treatment survives for everyone who is not a
      // waiter, which is what keeps "fetch a manager" discoverable at the till.
      await _mount(tester, m.tablesModule, _tableRoutes(),
          actions: const ['x'], role: 'cashier');
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-apply')));
      expect(_pressOf(tester, const ValueKey('sc-waiver-apply')), isNull);
      expect(find.textContaining('Only a manager can waive a service charge'), findsOneWidget);
    });

    testWidgets('a live waiver shows BOTH figures, because tax rode on the charge',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes(bill: _bill(waived: true)));
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-reverse')));

      // The charge that came off, and the larger amount the TOTAL fell by. Only
      // showing one of them is how a guest is told a different number from the
      // one on the paper.
      expect(find.textContaining('₹120.00 charge off'), findsOneWidget);
      expect(find.textContaining('₹126.00 off the total'), findsOneWidget);
      expect(find.textContaining('authorised by manager01'), findsOneWidget);
      // …while the BILL shows nothing about it: a removed charge has no row
      // ("don't show service charge opted out when removed"). This card is
      // where a manager sees who took it off, and puts it back.
      expect(find.text('waived'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sc-waiver-reverse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-authoriser')), findsNothing);
      await _fillReason(tester, reason: 'Manager overruled it');
      final body = api.bodyOf('/bills/service-charge-waiver/w-1/reverse') as Map?;
      expect(body!['reason'], 'Manager overruled it');
    });
  });

  // ==========================================================================
  // 037 + 038 — TENDERS, TIPS AND THE TILL
  // ==========================================================================

  group('037/038 · the payment screen', () {
    Future<_FakeApi> openPayment(
      WidgetTester tester, {
      Map<String, dynamic>? tenderState,
      List<Map<String, dynamic>> counters = const [],
      List<String> actions = const ['*'],
      String role = 'admin',
    }) async {
      final api = await _mount(
        tester,
        m.tablesModule,
        _tableRoutes(tenderState: tenderState, counters: counters),
        actions: actions,
        role: role,
      );
      await _openTable(tester);
      await _reveal(tester, find.text('Settle bill'));
      await tester.tap(find.text('Settle bill'));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('the outstanding balance is the headline, not the bill total', (tester) async {
      await openPayment(tester);
      expect(find.text('STILL TO PAY'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-outstanding')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('pay-outstanding'))).data,
        '₹1380.00',
      );
      // The bill total is still there — smaller, because at a till the question
      // is always "how much more".
      expect(find.text('Bill ₹1380.00'), findsOneWidget);
    });

    testWidgets('THE COMMON SETTLE IS UNCHANGED: one method, no tenders key', (tester) async {
      final api = await openPayment(tester);
      await tester.tap(find.byKey(const ValueKey('pay-method-Cash')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      expect(body, isNotNull);
      expect(body!['payment_method'], 'Cash');
      // NO `tenders`. That key makes the settle reconcile against a quote taken
      // a moment ago; without it the server computes the total inside its own
      // transaction, exactly as it always has.
      expect(body.containsKey('tenders'), isFalse);
      // …and the three calls are the three calls.
      expect(api.wrote('POST', 'waiter-confirm-payment'), isTrue);
      expect(api.wrote('POST', 'admin-approve-payment'), isTrue);
      expect(api.wrote('POST', '/close'), isTrue);
    });

    testWidgets('a tip rides ON the tender and is never folded into the amount',
        (tester) async {
      final api = await openPayment(tester);
      await tester.tap(find.byKey(const ValueKey('pay-method-Card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-add-tip')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pay-tip-amount')), '100');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-tip-mode-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-tip-pool')));
      await tester.pumpAndSettle();

      // The tip is reported on its own line and NOT added to the bill.
      expect(find.text('Bill ₹1380.00'), findsOneWidget);
      expect(find.text('Tips ₹100.00 (not part of the bill)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      final tenders = (body!['tenders'] as List).cast<Map>();
      expect(tenders, hasLength(1));
      // THE AMOUNT IS THE BILL'S SHARE, to the paisa, tip excluded. That is the
      // only reason a tipped bill still reconstructs its grand total.
      expect(tenders.first['amount'], 1380.0);
      expect(tenders.first['tip_amount'], 100.0);
      expect(tenders.first['tip_mode'], 'card');
      expect(tenders.first['tip_credited_to_username'], 'pool');
    });

    testWidgets('a tip with nowhere to go is refused before the card is charged',
        (tester) async {
      await openPayment(tester);
      await tester.tap(find.byKey(const ValueKey('pay-add-tip')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pay-tip-amount')), '100');
      await tester.pumpAndSettle();
      // 037's CHECK: a tip must say who it goes to. Said here, not after.
      expect(_pressOf(tester, const ValueKey('pay-settle')), isNull);
      await tester.tap(find.byKey(const ValueKey('pay-tip-pool')));
      await tester.pumpAndSettle();
      expect(_pressOf(tester, const ValueKey('pay-settle')), isNotNull);
    });

    testWidgets('OVER-TENDER is refused, never recorded and never netted off', (tester) async {
      await openPayment(tester);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '2000');
      await tester.pumpAndSettle();
      expect(_pressOf(tester, const ValueKey('pay-settle')), isNull);
      expect(find.textContaining('hand the change back in cash'), findsOneWidget);
    });

    testWidgets('a split settles in two parts that add back to the bill exactly',
        (tester) async {
      final api = await openPayment(tester);
      await tester.tap(find.byKey(const ValueKey('pay-method-Cash')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '1000');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-split')));
      await tester.pumpAndSettle();

      // The remaining balance moved, and the composer is pre-filled with it.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('pay-outstanding'))).data,
        '₹380.00',
      );
      await tester.tap(find.byKey(const ValueKey('pay-method-Card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      final tenders = (body!['tenders'] as List).cast<Map>();
      expect(tenders, hasLength(2));
      expect(tenders[0]['method'], 'Cash');
      expect(tenders[0]['amount'], 1000.0);
      expect(tenders[1]['method'], 'Card');
      expect(tenders[1]['amount'], 380.0);
      final sum = tenders.fold<double>(0, (s, t) => s + (t['amount'] as double));
      expect(sum, 1380.0, reason: 'the parts must reconstruct the grand total exactly');
    });

    testWidgets('an under-tender cannot settle, but CAN be recorded as a part payment',
        (tester) async {
      final api = await openPayment(tester);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '500');
      await tester.pumpAndSettle();

      // Under-tender at settle is refused by the server; saying so here means
      // the cashier is not told after the card machine.
      expect(_pressOf(tester, const ValueKey('pay-settle')), isNull);
      expect(find.textContaining('leaves ₹880.00 unpaid'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-refusal')), findsOneWidget,
          reason: 'a disabled Settle button must say why, beside itself');

      // The named, legal alternative: the guest has paid some of it and the
      // table stays open. This is why POST /bills/tenders exists at all.
      expect(find.byKey(const ValueKey('pay-part')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pay-part')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('/bills/tenders') as Map?;
      expect(body, isNotNull);
      expect((body!['tenders'] as List).first['amount'], 500.0);
      // A part payment must NOT close the bill.
      expect(api.wrote('POST', '/close'), isFalse);
    });

    testWidgets('the till is offered only when tills exist, and rides on the settle',
        (tester) async {
      // No counters configured — the overwhelmingly common case, and there must
      // be no control at all for it.
      await openPayment(tester);
      expect(find.byKey(const ValueKey('pay-counter')), findsNothing);

      final api = await openPayment(tester, counters: [
        {'id': 'c-1', 'code': 'C1', 'name': 'Front counter', 'kind': 'counter', 'active': true},
      ]);
      expect(find.byKey(const ValueKey('pay-counter')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pay-counter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('C1 · Front counter').last);
      await tester.pumpAndSettle();
      expect(find.text('Till: C1 · Front counter'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      expect(body!['counter_id'], 'c-1');
    });

    testWidgets('a recorded payment can be voided with a reason, and is never deleted',
        (tester) async {
      final api = await openPayment(tester, tenderState: {
        'bill_id': 'bill-1',
        'grand_total': 1380.0,
        'tenders': [
          {
            'id': 'tn-1', 'seq': 1, 'method': 'Card', 'amount': 1000.0,
            'txn_ref': 'AUTH123', 'tip_amount': 0.0, 'tip_mode': null,
            'tip_credited_to_username': null, 'voided_at': null,
            'settled_by_username': 'asha', 'settled_at': '2026-08-01T13:00:00.000Z',
          },
        ],
        'tendered': 1000.0,
        'outstanding': 380.0,
        'exact': false, 'partial': true, 'over': false,
        'tips_total': 0.0,
        'payment_method': 'Card',
        'payment_splits': <dynamic>[],
      });

      expect(find.text('Already paid'), findsOneWidget);
      expect(find.text('Card · ₹1000.00'), findsOneWidget);
      expect(find.text('Ref AUTH123'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('pay-outstanding'))).data,
        '₹380.00',
      );

      await tester.tap(find.byTooltip('Void this payment'));
      await tester.pumpAndSettle();
      await _fillReason(tester, reason: 'Keyed twice');
      final body = api.bodyOf('/bills/tenders/tn-1/void') as Map?;
      expect(body!['reason'], 'Keyed twice');
    });

    testWidgets('a bill already paid in full closes from the ledger, with no new tender',
        (tester) async {
      final api = await openPayment(tester, tenderState: {
        'bill_id': 'bill-1',
        'grand_total': 1380.0,
        'tenders': [
          {
            'id': 'tn-1', 'seq': 1, 'method': 'Cash', 'amount': 1380.0,
            'txn_ref': null, 'tip_amount': 0.0, 'tip_mode': null,
            'tip_credited_to_username': null, 'voided_at': null,
            'settled_by_username': 'asha', 'settled_at': '2026-08-01T13:00:00.000Z',
          },
        ],
        'tendered': 1380.0,
        'outstanding': 0.0,
        'exact': true, 'partial': false, 'over': false,
        'tips_total': 0.0,
        'payment_method': 'Cash',
        'payment_splits': <dynamic>[],
      });
      expect(find.text('PAID IN FULL'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      // The LEDGER is the authority on how it was paid; the route still needs a
      // field that says "this is a settle", so it gets the ledger's own answer
      // rather than a second tender that would over-tender the bill.
      expect(body!.containsKey('tenders'), isFalse);
      expect(body['payment_method'], 'Cash');
    });

    testWidgets('a settle that dies AFTER the tenders landed never re-sends them',
        (tester) async {
      final api = await openPayment(tester);
      await tester.tap(find.byKey(const ValueKey('pay-add-tip')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pay-tip-amount')), '100');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-tip-pool')));
      await tester.pumpAndSettle();

      // RecordBillTenders commits in its OWN transaction, so an approval that
      // fails afterwards leaves the payments recorded on an open bill.
      api.failOn = 'admin-approve-payment';
      api.failMessage = 'Not permitted to approve payments';
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Not permitted to approve payments'), findsOneWidget);
      // The composed tip is GONE — it was re-read from the server rather than
      // left on screen where a second tap would send it again.
      expect(find.textContaining('Tips ₹100.00'), findsNothing);

      api.failOn = '';
      final before = api.writes.where((w) => w.path.contains('waiter-confirm-payment')).length;
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      final second = api.writes.where((w) => w.path.contains('waiter-confirm-payment')).toList();
      expect(second, hasLength(before + 1));
      // Sending the same tenders a second time would over-tender the bill and be
      // refused — which reads like a dead end with a guest at the till.
      expect((second.last.body as Map).containsKey('tenders'), isFalse);
    });

    testWidgets('a session that cannot record payments degrades honestly, and asks for nothing',
        (tester) async {
      // Neither the ledger nor the tills are readable without the record-payment
      // action. Not asking is the difference between opening in the degraded
      // mode on purpose and opening there because two requests quietly 403'd.
      //
      // THE ROLE IS 'cashier', NOT 'waiter', AND THE SUBJECT IS UNCHANGED. What
      // this case is about is a session that lacks the record-payment action —
      // `actions: ['x']` is what says so, and it says it for any role. A waiter
      // can no longer reach the payment screen at all (item 18 took Settle off
      // their table sheet), so leaving the role as 'waiter' would have this test
      // failing on the way IN and never reaching the degradation it exists to
      // pin. A cashier without the action is the same session, still able to
      // open the screen.
      final api = await openPayment(tester, actions: const ['x'], role: 'cashier');
      expect(find.text('Single payment only'), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-amount')), findsNothing);
      expect(find.byKey(const ValueKey('pay-add-tip')), findsNothing);
      expect(api.calls.any((c) => c.contains('/bills/tenders')), isFalse);
      expect(api.calls.any((c) => c.contains('/billing-counters')), isFalse);

      // …and it still settles, exactly the way it always did.
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      final body = api.bodyOf('waiter-confirm-payment') as Map?;
      expect(body!['payment_method'], 'Upi');
      expect(body.containsKey('tenders'), isFalse);
    });
  });

  // ==========================================================================
  // 039 — MENU GROUPS AND VARIATIONS
  // ==========================================================================

  group('039 · menu groups', () {
    Map<String, dynamic> menuRoutes() => {
          '/menu': [
            {'id': 'menu-1', 'name': 'Paneer Tikka', 'price': 320.0, 'category': 'Starters', 'available': true},
          ],
          '/menu/costing': {'items': <dynamic>[]},
          '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
          '/menu/badges': {'badges': <dynamic>[], 'presets': <dynamic>[]},
          '/inventory': <dynamic>[],
          '/menu-group-assignments': {
            'kind': 'revenue',
            'groups': [
              {'id': 'g-1', 'name': 'Food', 'kind': 'revenue', 'active': true, 'sort_order': 0},
              {'id': 'g-2', 'name': 'Liquor', 'kind': 'revenue', 'active': false, 'sort_order': 1},
            ],
            'categories': [
              {'id': 'cat-1', 'name': 'Starters', 'group_id': null, 'resolved_group_id': null, 'resolved_group_name': null},
            ],
            'items': [
              {'id': 'menu-1', 'name': 'Paneer Tikka', 'group_id': null, 'resolved_group_id': null, 'resolved_group_name': null},
            ],
            'unclassified_items': 1,
          },
          '/menu-variations': {
            'variations': [
              {'id': 'v-1', 'menu_id': 'menu-1', 'name': 'Half', 'price': 180.0, 'is_default': true, 'active': true, 'sort_order': 0},
            ],
          },
        };

    testWidgets('the editor meets the owner with the number the report will show them',
        (tester) async {
      await _mount(tester, m.menuModule, menuRoutes());
      await tester.tap(find.byKey(const ValueKey('menu-groups')));
      await tester.pumpAndSettle();
      // `unclassified_items` is deliberately prominent: the Group Summary's
      // totals only equal the Sales Summary's because that bucket is counted,
      // and an owner should meet it here rather than in front of an accountant.
      expect(find.textContaining('1 dish in no group'), findsOneWidget);
      expect(find.text('Food'), findsWidgets);
      expect(find.text('Retired'), findsOneWidget, reason: 'a retired group is still listed');
    });

    testWidgets('filing a CATEGORY is one targeted write, and clearing it sends null',
        (tester) async {
      final api = await _mount(tester, m.menuModule, menuRoutes());
      await tester.tap(find.byKey(const ValueKey('menu-groups')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('groups-assign-cat-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food').last);
      await tester.pumpAndSettle();

      final body = api.bodyOf('/menu-group-assignments') as Map?;
      expect(body, isNotNull);
      expect(body!['main_cat_id'], 'cat-1');
      expect(body['group_id'], 'g-1');
      // The per-item key must NOT travel with the category one: the server
      // refuses a body carrying both rather than guessing which was meant.
      expect(body.containsKey('menu_id'), isFalse);

      await tester.tap(find.byKey(const ValueKey('groups-assign-cat-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No group'));
      await tester.pumpAndSettle();
      final cleared = api.writes.last.body as Map;
      expect(cleared['group_id'], isNull, reason: 'null CLEARS, and is an ordinary state');
    });

    testWidgets('retiring is the only way out — nothing here deletes a group', (tester) async {
      final api = await _mount(tester, m.menuModule, menuRoutes());
      await tester.tap(find.byKey(const ValueKey('menu-groups')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Retire it').first);
      await tester.pumpAndSettle();
      final body = api.bodyOf('/menu-groups/g-1') as Map?;
      expect(body!['active'], false);
      // A group id sits on menu rows and reports resolve it at READ time, so a
      // delete would strand those references and rewrite history as Unclassified.
      expect(api.writes.any((w) => w.method == 'DELETE'), isFalse);
    });

    testWidgets('the per-item override says when it is only following its category',
        (tester) async {
      await _mount(tester, m.menuModule, menuRoutes());
      await tester.tap(find.byKey(const ValueKey('menu-groups')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('groups-toggle-target')));
      await tester.pumpAndSettle();
      expect(find.text('Paneer Tikka'), findsWidgets);
      // The precedence is shown, not re-derived by the reader: item override ->
      // category default -> Unclassified.
      expect(find.byKey(const ValueKey('groups-assign-menu-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('groups-assign-menu-1')));
      await tester.pumpAndSettle();
      expect(find.text('Follow my category'), findsOneWidget);
    });
  });

  group('039 · menu variations', () {
    Map<String, dynamic> menuRoutes() => {
          '/menu': [
            {'id': 'menu-1', 'name': 'Paneer Tikka', 'price': 320.0, 'category': 'Starters', 'available': true},
          ],
          '/menu/costing': {'items': <dynamic>[]},
          '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
          '/menu/badges': {'badges': <dynamic>[], 'presets': <dynamic>[]},
          '/inventory': <dynamic>[],
          '/menu-variations': {
            'variations': [
              {'id': 'v-1', 'menu_id': 'menu-1', 'name': 'Half', 'price': 180.0, 'is_default': true, 'active': true, 'sort_order': 0},
            ],
          },
        };

    Future<_FakeApi> openVariations(WidgetTester tester) async {
      final api = await _mount(tester, m.menuModule, menuRoutes());
      await tester.tap(find.text('Paneer Tikka').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-variations')));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('a size is a targeted write against the dish — never a bulk menu save',
        (tester) async {
      final api = await openVariations(tester);
      expect(find.text('Half'), findsWidgets);
      expect(find.text('Default'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('variations-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('variation-name')), 'Full');
      await tester.enterText(find.byKey(const ValueKey('variation-price')), '320');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('variation-save')));
      await tester.pumpAndSettle();

      final body = api.bodyOf('/menu-variations') as Map?;
      expect(body!['menu_id'], 'menu-1');
      expect(body['name'], 'Full');
      expect(body['price'], 320.0);
      // THE BUG THAT WIPED 56 ITEMS. A bulk save from this feature would be it
      // happening again, with images, sections and recipes as the casualties.
      expect(api.writes.any((w) => w.method == 'PUT' && w.path.startsWith('/menu')), isFalse);
    });

    testWidgets('a ₹0 size is refused, because the price is a FLOOR', (tester) async {
      final api = await openVariations(tester);
      await tester.tap(find.byKey(const ValueKey('variations-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('variation-name')), 'Taster');
      await tester.enterText(find.byKey(const ValueKey('variation-price')), '0');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('variation-save')));
      await tester.pumpAndSettle();

      // A ₹0 variation is a standing invitation to ring any quantity of the dish
      // in at nothing with the bill still printing its name.
      expect(find.textContaining('A size must cost something'), findsOneWidget);
      expect(api.writes.any((w) => w.path.contains('/menu-variations')), isFalse);
    });

    testWidgets('a size is retired, not deleted — past sales still name it', (tester) async {
      final api = await openVariations(tester);
      await tester.tap(find.byTooltip('Retire it').first);
      await tester.pumpAndSettle();
      final body = api.bodyOf('/menu-variations/v-1') as Map?;
      expect(body!['active'], false);
      expect(api.writes.any((w) => w.method == 'DELETE'), isFalse);
    });
  });

  // ==========================================================================
  // OFFLINE — nothing here queues, and the allowlist is untouched
  // ==========================================================================

  group('offline', () {
    test('every capture route is refused, and the billing family says WHY', () {
      // The three manager acts and the menu taxonomy: refused with the generic
      // sentence, because none of them carries idempotent() on the server.
      for (final (method, path) in const [
        ('POST', '/orders/o1/items/i1/non-chargeable'),
        ('POST', '/non-chargeables/nc1/reverse'),
        ('POST', '/orders/o1/void'),
        ('POST', '/menu-groups'),
        ('PATCH', '/menu-groups/g1'),
        ('POST', '/menu-group-assignments'),
        ('POST', '/menu-variations'),
        ('PATCH', '/menu-variations/v1'),
        ('POST', '/billing-counters'),
      ]) {
        final d = OutboxPolicy.decide(method, path);
        expect(d.queueable, isFalse, reason: '$method $path must never queue');
        expect(d.refusal, isNotEmpty);
      }

      // Money: the BILLING sentence, because "reconnect" alone does not tell a
      // waiter why a payment cannot wait.
      for (final path in const [
        '/bills/tenders',
        '/bills/tenders/t1/void',
        '/bills/counter',
        '/bills/service-charge-waiver',
        '/bills/service-charge-waiver/w1/reverse',
      ]) {
        final d = OutboxPolicy.decide('POST', path);
        expect(d.queueable, isFalse);
        expect(d.refusal, contains('Billing'),
            reason: '$path is money and must say so');
      }
    });

    testWidgets('a settle attempted offline refuses with the billing message, and queues nothing',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.text('Settle bill'));
      await tester.tap(find.text('Settle bill'));
      await tester.pumpAndSettle();

      api.offline = true;
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();

      // The refusal OutboxPolicy chose, verbatim — it says a bill number can
      // only be issued by the server, which is the fact that matters.
      expect(find.textContaining('Billing needs a connection'), findsOneWidget);
      // The sheet is still open on the unpaid bill, not closed over a settle
      // that never happened.
      expect(find.byKey(const ValueKey('pay-settle')), findsOneWidget);
    });

    testWidgets('a comp attempted offline refuses too, and the line stays chargeable',
        (tester) async {
      final api = await _mount(tester, m.tablesModule, _tableRoutes());
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();
      api.offline = true;
      await tester.tap(find.byKey(const ValueKey('nc-comp-item-2')));
      await tester.pumpAndSettle();
      await _fillReason(tester, kind: 'complimentary', reason: 'On the house');
      // An offline-queued comp means the printed bill says one total and the
      // server later says another. The right answer is "refuse now".
      expect(find.byKey(const ValueKey('nc-comp-item-2')), findsOneWidget,
          reason: 'the line must still be chargeable');
    });
  });

  // ==========================================================================
  // THE PHONE — this app ships to Windows AND to Android
  // ==========================================================================

  group('phone', () {
    testWidgets('the comp sheet and the payment screen fit a 390dp phone', (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes(), width: 390, height: 900);
      await _openTable(tester);

      await _reveal(tester, find.byKey(const ValueKey('table-comps')));
      await tester.tap(find.byKey(const ValueKey('table-comps')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the comp sheet overflowed a phone');
      expect(find.byKey(const ValueKey('nc-comp-item-1')), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await _reveal(tester, find.text('Settle bill'));
      await tester.tap(find.text('Settle bill'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the payment screen overflowed a phone');
      // The outstanding stays the headline at phone width — it is the one number
      // that must never be the thing that gets truncated.
      expect(find.byKey(const ValueKey('pay-outstanding')), findsOneWidget);
      expect(find.byKey(const ValueKey('pay-method-Cash')), findsOneWidget);
    });

    testWidgets('the reason form fits a 390dp phone with the second name on it',
        (tester) async {
      await _mount(tester, m.tablesModule, _tableRoutes(), width: 390, height: 900);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-apply')));
      await tester.tap(find.byKey(const ValueKey('sc-waiver-apply')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the reason form overflowed a phone');
      expect(find.byKey(const ValueKey('capture-reason')), findsOneWidget);
      expect(find.byKey(const ValueKey('capture-authoriser')), findsOneWidget);
    });
  });

  // ==========================================================================
  // THE OTHER ENTRY POINT — a comp taken from the order ticket
  // ==========================================================================

  testWidgets('the order sheet offers the comp too, because a comp is taken on a LINE',
      (tester) async {
    final api = await _mount(tester, m.ordersModule, _tableRoutes());
    await tester.tap(find.text('Table T1').first);
    await tester.pumpAndSettle();
    // The detail sheet grew a line — D2's "Open for 12m 04s" — so the comp
    // button can sit below the fold on a short test viewport. Scroll to it
    // rather than widening the window: the button being reachable by scrolling
    // is the real behaviour, and a tap that silently misses is how this started.
    await tester.ensureVisible(find.text('Comp an item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comp an item'));
    await tester.pumpAndSettle();

    // It opened on THIS ticket's lines, which is the level the ids exist at.
    expect(find.byKey(const ValueKey('nc-comp-item-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('nc-comp-item-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nc-comp-item-2')));
    await tester.pumpAndSettle();
    await _fillReason(tester, kind: 'tasting', reason: 'Kitchen tasting');
    expect(api.wrote('POST', '/orders/order-1/items/item-2/non-chargeable'), isTrue);
  });

  testWidgets('a waiter is not offered the comp on the order sheet at all', (tester) async {
    await _mount(tester, m.ordersModule, _tableRoutes(),
        actions: const ['x'], role: 'waiter');
    await tester.tap(find.text('Table T1').first);
    await tester.pumpAndSettle();
    // Here the whole action is absent rather than disabled: the sheet already
    // carries five other controls, and an inert sixth beside them reads as a
    // broken screen rather than as a permission.
    expect(find.text('Comp an item'), findsNothing);
  });

  // ==========================================================================
  // 038 — MOVING A SETTLED BILL TO ANOTHER TILL
  // ==========================================================================

  group('038 · correcting a till attribution', () {
    Future<_FakeApi> mountAction(
      WidgetTester tester, {
      List<Map<String, dynamic>> counters = const [
        {'id': 'c-1', 'code': 'C1', 'name': 'Front counter', 'kind': 'counter', 'active': true},
        {'id': 'c-2', 'code': 'BAR', 'name': 'Bar terminal', 'kind': 'terminal', 'active': true},
      ],
      List<String> actions = const ['*'],
      String role = 'admin',
    }) async {
      await tester.pumpWidget(const SizedBox());
      _size(tester, 800, 600);
      final api = _FakeApi({'/billing-counters': {'counters': counters}},
          actions: actions, role: role);
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(Builder(
        builder: (context) => m.misBillCounterAction(
          context,
          rest: rest,
          profile: rest.auth.profile!,
          billId: 'bill-1',
          onChanged: () {},
        ),
      )));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('an outlet with no tills is offered nothing — there is nowhere to move it',
        (tester) async {
      await mountAction(tester, counters: const []);
      expect(find.byKey(const ValueKey('bill-counter-move')), findsNothing);
    });

    testWidgets('moving a settled bill posts the bill id and the new till', (tester) async {
      final api = await mountAction(tester);
      await tester.tap(find.byKey(const ValueKey('bill-counter-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BAR · Bar terminal'));
      await tester.pumpAndSettle();

      final body = api.bodyOf('/bills/counter') as Map?;
      expect(body, isNotNull, reason: 'a misconfigured terminal must be correctable');
      expect(body!['bill_id'], 'bill-1');
      expect(body['counter_id'], 'c-2');
    });

    testWidgets('clearing it OMITS the counter, which is what "this outlet’s till" means',
        (tester) async {
      final api = await mountAction(tester);
      await tester.tap(find.byKey(const ValueKey('bill-counter-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This outlet’s single till'));
      await tester.pumpAndSettle();

      final body = api.bodyOf('/bills/counter') as Map?;
      // An ABSENT counter_id clears the attribution back to the state every bill
      // written before migration 038 is already in. Sending an empty string
      // instead would be an id the server cannot resolve.
      expect(body!.containsKey('counter_id'), isFalse);
    });

    testWidgets('someone who cannot take payments cannot move a bill either', (tester) async {
      await mountAction(tester, actions: const ['x'], role: 'waiter');
      expect(find.byKey(const ValueKey('bill-counter-move')), findsNothing);
    });
  });
}
