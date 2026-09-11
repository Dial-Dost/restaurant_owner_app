import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// THE WAITER'S FLOOR — items 14 to 20.
///
/// The table sheet is the busiest screen in the app and it carried fifteen
/// controls. Nine of them are somebody else's job (seating, settling, releasing,
/// merging, splitting, discounting, couponing, re-seating, deleting), one is a
/// setup artefact (the guest QR) and one is a floor-manager decision (who covers
/// this table). What is left is the two things a waiter actually does at a
/// table, and this file pins that they are the two things the screen leads with.
///
/// TWO PROMISES RUN THROUGH EVERY TEST HERE, and neither is "the button is gone":
///
///   * A HIDDEN CONTROL MUST BE UNREACHABLE, NOT MERELY UNDRAWN. Hiding a button
///     that a deep link, a back-navigation or a stale cached screen still walks
///     into is not scoping. So the tests below do not stop at `findsNothing`:
///     they drive the surviving surface and assert that the WRITE never happens
///     — no POST /occupy-table, no /release-table, no /bills/merge, no settle.
///
///   * AN ADMIN MUST LOSE NOTHING. Every case is run for an owner too, and the
///     owner's assertions are the shipped behaviour word for word. The failure
///     mode this file is guarding against is not "a waiter saw money", it is
///     "the fix took the till away from the person who runs it".
///
/// And both design systems ship in this release, so the sheet is rendered under
/// each of them.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.actions = const ['*'], this.role = 'admin'});

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;

  final List<String> calls = <String>[];
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
          'employeeUsername': 'ravi',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'actions_set': actions,
          // The action names a floor waiter really carries. Every one of them is
          // a substring some module keyword matches, which is exactly why the
          // permission gate alone never scoped this role.
          'action_names': const [
            'View Orders', 'Create Order', 'View Tables', 'Occupy Table',
            'View Menu', 'View Bills',
          ],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
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

  /// Every write to a path containing [fragment] — the assertion that matters
  /// when a control is supposed to be unreachable rather than merely unpainted.
  Iterable<({String method, String path, Object? body})> to(String fragment) =>
      writes.where((w) => w.path.contains(fragment));
}

// ---------------------------------------------------------------- fixtures --

Map<String, dynamic> _table({bool occupied = true}) => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': occupied,
      'reserved': false,
      'num_covers': 3,
      'covers': 3,
      // What the tile prints down its bottom edge for anyone who may see money.
      'table_total': 1380.0,
      'table_apc': 460.0,
      'apc_status': 'red',
      'waiter_name': 'Ravi K',
    };

Map<String, dynamic> _bill() => {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': 1200.0,
      'subtotal': 1200.0,
      'discount': 0.0,
      'service_charge': 120.0,
      'service_charge_waived': false,
      'tax_total': 60.0,
      'grand_total': 1380.0,
      'nc_total': 0.0,
      'covers': 3,
      'apc': 400.0,
      'target_apc': 500.0,
      'apc_status': 'red',
      'apc_suggestions': const ['Offer a dessert'],
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
        {'name': 'Gulab Jamun', 'price': 120.0, 'quantity': 1, 'note': 'no nuts'},
      ],
      'payment_status': null,
    };

Map<String, dynamic> _routes({bool occupied = true, Map<String, dynamic>? bill}) => {
      '/get-tables': [_table(occupied: occupied)],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': bill ?? _bill(),
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': [
        {'id': 'mi-1', 'name': 'Paneer Tikka', 'price': 320.0, 'category': 'Starters'},
      ],
    };

// ------------------------------------------------------------------- hosts --

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
  return RestClient(auth);
}

Widget _host(Widget child, {DesignSystem system = DesignSystem.rustic}) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mountFloor(
  WidgetTester tester, {
  required String role,
  List<String> actions = const ['a1'],
  bool occupied = true,
  Map<String, dynamic>? bill,
  DesignSystem system = DesignSystem.rustic,
  /// REQUIREMENT D5 — which of the two floor screens to open. Defaults to the
  /// service one (Tables), because that is where a waiter lives and what every
  /// test in this file was written about; the layout assertions pass `plan`.
  bool plan = false,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _FakeApi(_routes(occupied: occupied, bill: bill), actions: actions, role: role);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(
      plan ? m.floorPlanModule(rest, rest.auth.profile!) : m.tablesModule(rest, rest.auth.profile!),
      system: system));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

/// Scroll the sheet until [finder] is on screen. Never throws when the target
/// does not exist — the point of most of these tests is that it does not.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* not on this sheet at all */}
  await tester.pumpAndSettle();
}

/// Every glyph actually painted. RichText catches Gaia's composed headers as
/// well as plain Text, so a money assertion cannot pass on one design system and
/// silently skip the other.
List<String> _painted(WidgetTester tester) => [
      for (final rt in tester.widgetList<RichText>(find.byType(RichText)))
        rt.text.toPlainText(includeSemanticsLabels: false, includePlaceholders: false),
    ];

/// The labels of every control on the open sheet.
List<String> _buttons(WidgetTester tester) =>
    [for (final b in tester.widgetList<ForkButton>(find.byType(ForkButton))) b.label];

void main() {
  // [PrintedBills] is a process-wide singleton — the floor grid and the table
  // sheet have to agree the instant one of them prints — so a waiter who printed
  // in one test would still have that table retired in the next. Reset between
  // tests; requirement C3's own group is what exercises it deliberately.
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  // ======================================================== the sheet's shape

  group('the table sheet a waiter is given', () {
    testWidgets('items 14, 15, 17, 18 and 20: what is gone, and what is left',
        (tester) async {
      await _mountFloor(tester, role: 'waiter');
      await _openTable(tester);
      // Walk the whole sheet so nothing below the fold is missed.
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      final labels = _buttons(tester);
      for (final gone in const [
        'Seat guests & take order', // 16
        'Settle bill', // 18
        'Release without payment', // 20
        'Edit seating', // 15
        'Merge', 'Split', 'Discount', 'Coupon', // 18
        'Reprint (no service charge)', // 18
        'Refund',
        'Print QR', // 17
      ]) {
        expect(labels, isNot(contains(gone)), reason: '$gone is still on a waiter\'s sheet');
      }
      // 15: delete is a TextButton, not a ForkButton.
      expect(find.text('Delete table'), findsNothing);
      // 14: the assign-waiter row, whichever half of it would have rendered.
      expect(find.textContaining('No waiter assigned'), findsNothing);
      expect(find.textContaining('Waiter: '), findsNothing);
      expect(find.text('Assign'), findsNothing);
      expect(find.text('Change'), findsNothing);

      // 17: and what IS there, at full width, in this order.
      expect(find.byKey(const ValueKey('table-add-order')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-print-bill')), findsOneWidget);
      final addOrder = tester.getRect(find.byKey(const ValueKey('table-add-order')));
      final printBill = tester.getRect(find.byKey(const ValueKey('table-print-bill')));
      expect(addOrder.top, lessThan(printBill.top), reason: 'Add order leads');
      expect(addOrder.width, greaterThan(300),
          reason: 'item 17 asked for BIGGER, not merely first');
      expect(addOrder.width, closeTo(printBill.width, 1));
    });

    testWidgets('an admin loses NOTHING — every service control is still there',
        (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*']);
      await _openTable(tester);
      await _reveal(tester, find.text('Refund'));

      final labels = _buttons(tester);
      for (final kept in const [
        'Settle bill', 'Release without payment',
        'Merge', 'Split', 'Discount',
        'Reprint (no service charge)', 'Refund', 'Print bill', 'Print QR',
      ]) {
        expect(labels, contains(kept), reason: '$kept went missing from an owner\'s sheet');
      }
      // The coupon button names the code when there is one, so match its stem.
      expect(labels.any((l) => l.startsWith('Coupon')), isTrue);
      expect(find.text('Waiter: Ravi K'), findsOneWidget);
      // The two waiter-only keys never appear for anyone else: their sheet keeps
      // the wrapped row it shipped with.
      expect(find.byKey(const ValueKey('table-add-order')), findsNothing);
      expect(find.byKey(const ValueKey('table-print-bill')), findsNothing);
    });

    // ---- REQUIREMENT D5, AND C7/H8 ---------------------------------------
    //
    // The layout controls did not GO, they MOVED, and that difference is the
    // whole of "an admin must lose nothing". These are a pair: one pins that the
    // service sheet no longer offers them to ANYBODY, the other that an owner
    // still has every one of them on the screen they moved to.
    testWidgets('the SERVICE sheet offers an owner no layout control at all',
        (tester) async {
      final api = await _mountFloor(tester, role: 'admin', actions: const ['*']);
      await _openTable(tester);
      await _reveal(tester, find.text('Refund'));

      expect(_buttons(tester), isNot(contains('Edit seating')));
      // C7 + H8: delete is off this sheet for every role and on both surfaces.
      expect(find.text('Delete table'), findsNothing);

      // AND IT IS UNREACHABLE, NOT MERELY UNDRAWN. Drive every control the sheet
      // still offers and assert neither layout write ever leaves.
      for (final b in find.byType(ForkButton).evaluate().toList()) {
        final w = b.widget as ForkButton;
        if (w.onPressed == null || w.label == 'Add order') continue;
        w.onPressed!();
        await tester.pumpAndSettle();
      }
      expect(api.writes.where((w) => w.method == 'DELETE' && w.path.startsWith('/table/')), isEmpty);
      expect(api.writes.where((w) => w.method == 'PATCH' && w.path.startsWith('/table/')), isEmpty);
    });

    testWidgets('an owner keeps every layout control on the Floor plan screen',
        (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*'], plan: true);
      expect(find.text('Add table'), findsOneWidget);
      expect(find.byKey(const ValueKey('floor-delete-table')), findsOneWidget);
      expect(find.text('New section'), findsOneWidget);
      // ...and the per-table one, on the sheet this screen opens.
      await _openTable(tester);
      await _reveal(tester, find.text('Edit seating'));
      expect(find.text('Edit seating'), findsOneWidget);
    });

    testWidgets('a waiter is offered no layout control on either screen',
        (tester) async {
      await _mountFloor(tester, role: 'waiter', plan: true);
      expect(find.text('Add table'), findsNothing);
      expect(find.byKey(const ValueKey('floor-delete-table')), findsNothing);
      expect(find.text('New section'), findsNothing);
      expect(find.text('Arrange'), findsNothing);
    });

    // ITEM 16, on a FREE table. There is no seat button, and "Add order" is
    // offered anyway — which is the whole of "occupancy follows the order".
    testWidgets('a free table offers the order, not the seating', (tester) async {
      await _mountFloor(tester, role: 'waiter', occupied: false);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      expect(find.text('Seat guests & take order'), findsNothing);
      expect(find.byKey(const ValueKey('table-add-order')), findsOneWidget);
      // Nothing to print yet — a button that answers "no open bill" is a wasted
      // walk to the printer.
      expect(find.byKey(const ValueKey('table-print-bill')), findsNothing);
    });

    testWidgets('an owner still seats a free table exactly as before', (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*'], occupied: false);
      await _openTable(tester);
      await _reveal(tester, find.text('Seat guests & take order'));
      expect(find.text('Seat guests & take order'), findsOneWidget);
    });

    for (final system in DesignSystem.values) {
      testWidgets("the waiter's sheet renders under ${system.name}", (tester) async {
        await _mountFloor(tester, role: 'waiter', system: system);
        await _openTable(tester);
        await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('table-add-order')), findsOneWidget);
        for (final shown in _painted(tester)) {
          expect(shown.contains('₹'), isFalse,
              reason: '${system.name} leaked money onto the sheet: "$shown"');
          expect(shown.contains('NaN'), isFalse);
        }
      });
    }
  });

  // ============================================================ item 19: money

  group('item 19 — no money on a waiter\'s screen', () {
    testWidgets('the floor tile prices nothing, and the APC light is off',
        (tester) async {
      await _mountFloor(tester, role: 'waiter');
      for (final shown in _painted(tester)) {
        expect(shown.contains('₹'), isFalse, reason: 'the floor plan priced a table: "$shown"');
      }
      expect(find.textContaining('apc'), findsNothing);
      expect(find.text('APC low'), findsNothing);
      // The table is still legibly a table: state, covers and the seat guide.
      expect(find.text('Occupied'), findsWidgets);
      expect(find.text('3 covers'), findsOneWidget);
    });

    testWidgets('the same tile still prices itself for an owner', (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*']);
      final painted = _painted(tester);
      expect(painted.any((t) => t.contains('₹1380.00')), isTrue);
      expect(find.text('APC low'), findsOneWidget);
    });

    testWidgets('the open order keeps its lines and loses its prices', (tester) async {
      await _mountFloor(tester, role: 'waiter');
      await _openTable(tester);
      await _reveal(tester, find.text('2 × Paneer Tikka'));

      // The ticket survives — the dish, the quantity and the kitchen note are
      // how a waiter works the table.
      expect(find.text('2 × Paneer Tikka'), findsOneWidget);
      expect(find.text('1 × Gulab Jamun'), findsOneWidget);
      expect(find.text('no nuts'), findsOneWidget);

      // The bill block, all of it.
      expect(find.text('Bill'), findsNothing);
      expect(find.text('TOTAL PAYABLE'), findsNothing);
      expect(find.text('Subtotal'), findsNothing);
      expect(find.text('Service charge'), findsNothing);
      expect(find.text('Tax'), findsNothing);
      // …and the APC insight card that is that figure again as an instruction.
      expect(find.textContaining('Below target'), findsNothing);
      expect(find.text('Offer a dessert'), findsNothing);

      for (final shown in _painted(tester)) {
        expect(shown.contains('₹'), isFalse, reason: 'a rupee figure survived: "$shown"');
      }
    });

    testWidgets('an owner keeps every line of that bill', (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*']);
      await _openTable(tester);
      await _reveal(tester, find.text('TOTAL PAYABLE'));
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('TOTAL PAYABLE'), findsOneWidget);
      expect(find.text('₹640.00'), findsOneWidget, reason: '2 × Paneer Tikka');
      expect(find.textContaining('Below target'), findsOneWidget);
    });

    // 1.8.6 shipped the service-charge waiver deliberately VISIBLE and inert to
    // a waiter, so they fetch a manager instead of arguing with a guest about a
    // screen that appears to have no such option. None of items 12-20 asks for
    // that to change — only for the FIGURE on it to go.
    testWidgets('the whole waiver block goes, amounts and all', (tester) async {
      final waived = _bill()
        ..['service_charge'] = 0.0
        ..['service_charge_waived'] = true
        ..['service_charge_waiver'] = {
          'id': 'w-1',
          'waiver_kind': 'guest_complaint',
          'reason': 'Long wait for the mains',
          'amount_waived': 120.0,
          'grand_total_reduction': 126.0,
          'waived_by_username': 'asha',
          'authorised_by_username': 'manager01',
        };
      // ITEM 19 SCOPED THE FIGURES; V3 REMOVED THE BLOCK. Item 19 left this
      // card standing for a waiter and dropped only the two rupee lines inside
      // it, so the reason and the reverse control survived. The V3 requirements
      // ask for the control and its accompanying text to be completely hidden
      // from a waiter, which takes the card with them — so a waiter now sees no
      // waiver surface at all, not even the reason a charge is already off.
      await _mountFloor(tester, role: 'waiter', bill: waived);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-reverse')));

      expect(find.byKey(const ValueKey('sc-waiver-reverse')), findsNothing);
      expect(find.textContaining('Long wait for the mains'), findsNothing);
      expect(find.textContaining('charge off'), findsNothing);
      expect(find.byKey(const ValueKey('table-comps')), findsNothing);

      // AN OWNER LOSES NOTHING — the promise this whole file runs on. Same bill,
      // same screen: the card, its reason and both figures are all still there.
      await _mountFloor(tester, role: 'admin', bill: waived);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('sc-waiver-reverse')));
      expect(find.byKey(const ValueKey('sc-waiver-reverse')), findsOneWidget);
      expect(find.textContaining('Long wait for the mains'), findsOneWidget);
      expect(find.textContaining('charge off'), findsOneWidget);
    });
  });

  // ================================================== the rule that matters --

  group('a hidden control is unreachable, not merely undrawn', () {
    // ITEM 16 + 20. /occupy-table and /release-table share ONE action, which a
    // waiter holds — the server will serve both. So the app is the gate, and the
    // test drives the surviving surface rather than trusting a findsNothing.
    testWidgets('nothing a waiter can press seats or releases a table', (tester) async {
      final api = await _mountFloor(tester, role: 'waiter', occupied: false);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      // Press every control the sheet actually offers.
      for (final b in find.byType(ForkButton).evaluate().toList()) {
        final w = b.widget as ForkButton;
        if (w.onPressed == null) continue;
        if (w.label == 'Add order') continue; // opens a route, tested separately
        w.onPressed!();
        await tester.pumpAndSettle();
      }
      expect(api.to('/occupy-table'), isEmpty);
      expect(api.to('/release-table'), isEmpty);
    });

    testWidgets('nor settles, merges, splits, discounts, coupons or refunds',
        (tester) async {
      final api = await _mountFloor(tester, role: 'waiter');
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      for (final b in find.byType(ForkButton).evaluate().toList()) {
        final w = b.widget as ForkButton;
        if (w.onPressed == null || w.label == 'Add order') continue;
        w.onPressed!();
        await tester.pumpAndSettle();
      }
      for (final route in const [
        '/bills/merge', '/bills/split', '/bills/discount', '/bills/apply-coupon',
        '/bills/refund', 'admin-approve-payment', 'confirm-payment',
      ]) {
        expect(api.to(route), isEmpty, reason: '$route was reachable');
      }
      // Nor the layout writes item 15 removes.
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);
      expect(api.writes.where((w) => w.method == 'PATCH' && w.path.startsWith('/table/')), isEmpty);
    });

    // A guest paid from the QR page and the table is waiting for approval.
    // Approving CLOSES the bill, so it went where Settle went — but the STATE
    // must still be legible, or a paid table looks ordinary on a busy floor.
    testWidgets('a payment awaiting approval is shown but not approvable', (tester) async {
      final pending = _bill()..['payment_status'] = 'pending_approval';
      final api = await _mountFloor(tester, role: 'waiter', bill: pending);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      expect(find.text('Approve payment & close'), findsNothing);
      expect(api.to('admin-approve-payment'), isEmpty);
      // The floor tile still says so.
      await tester.tap(find.byType(BackButtonIcon).evaluate().isEmpty
          ? find.text('Actions')
          : find.text('Actions'));
      await tester.pumpAndSettle();
    });

    testWidgets('an owner still approves it', (tester) async {
      final pending = _bill()..['payment_status'] = 'pending_approval';
      await _mountFloor(tester, role: 'admin', actions: const ['*'], bill: pending);
      await _openTable(tester);
      await _reveal(tester, find.text('Approve payment & close'));
      expect(find.text('Approve payment & close'), findsOneWidget);
    });

    // ITEM 15's third control, which item 15 does not name. Adding a table is
    // the same family as editing and deleting one; leaving it while removing the
    // other two produces a waiter who can create a table and not remove it.
    testWidgets('the floor plan offers a waiter no "Add table"', (tester) async {
      await _mountFloor(tester, role: 'waiter', plan: true);
      expect(find.text('Add table'), findsNothing);
      await _mountFloor(tester, role: 'admin', actions: const ['*'], plan: true);
      expect(find.text('Add table'), findsOneWidget);
      // D5: and it is not on the SERVICE screen for anybody, owner included.
      await _mountFloor(tester, role: 'admin', actions: const ['*']);
      expect(find.text('Add table'), findsNothing);
    });
  });

  // ========================================== item 17: printing without money

  group('item 17 — Print bill keeps the action and drops the rehearsal', () {
    testWidgets('a waiter prints from a confirmation that names no figure',
        (tester) async {
      final api = await _mountFloor(tester, role: 'waiter');
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-print-bill')));
      await tester.pumpAndSettle();

      // The confirmation says what it is about to do and how much of it there is
      // — never what it is worth.
      expect(find.text('Print the bill for T1?'), findsOneWidget);
      expect(find.textContaining('2 item(s)'), findsOneWidget);
      for (final shown in _painted(tester)) {
        expect(shown.contains('₹'), isFalse, reason: 'the print confirmation priced it: "$shown"');
      }

      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      // THE ACTION IS UNCHANGED: the same server-side print, so the paper the
      // guest is handed still carries every figure.
      expect(api.to('/print/bill'), hasLength(1));
      expect((api.to('/print/bill').single.body as Map)['table_name'], 'T1');
    });

    testWidgets('an owner still gets the receipt preview before it prints',
        (tester) async {
      await _mountFloor(tester, role: 'admin', actions: const ['*']);
      await _openTable(tester);
      await _reveal(tester, find.text('Print bill'));
      await tester.tap(find.text('Print bill'));
      await tester.pumpAndSettle();
      // The full priced receipt, exactly as it shipped.
      expect(find.textContaining('TOTAL'), findsWidgets);
      expect(_painted(tester).any((t) => t.contains('1380')), isTrue);
    });
  });

  // ============================== item 16 / constraint C: occupancy and covers

  group('occupancy follows the order', () {
    Future<_FakeApi> pumpEntry(WidgetTester tester,
        {required String role, required bool occupyOnSend}) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = _FakeApi(_routes(occupied: false), role: role, actions: const ['a1']);
      final rest = await _signIn(api);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: OrderEntryScreen(rest: rest, tableName: 'T1', occupyOnSend: occupyOnSend),
      ));
      await tester.pumpAndSettle();
      return api;
    }

    Future<void> addOneAndSend(WidgetTester tester) async {
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send order'));
      await tester.pumpAndSettle();
    }

    // THE ORDER OF THE TWO WRITES IS THE WHOLE FIX. TableSessions is written by
    // a trigger on the free -> occupied transition, and every reader that ties
    // money to a seating matches a bill to the session whose seated_at precedes
    // it. Send the order first and its bill predates the seating it belongs to.
    testWidgets('the send occupies the table FIRST, with the covers it asked for',
        (tester) async {
      final api = await pumpEntry(tester, role: 'waiter', occupyOnSend: true);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send order'));
      await tester.pumpAndSettle();

      // Covers are asked ONCE, as the send's own question.
      expect(find.text('How many guests at this table?'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '4');
      await tester.tap(find.widgetWithText(FilledButton, 'Send order'));
      await tester.pumpAndSettle();

      final paths = api.writes.map((w) => w.path).toList();
      expect(paths.indexOf('/occupy-table'), 0);
      expect(paths.indexOf('/orders'), 1);
      expect((api.to('/occupy-table').single.body as Map)['num_covers'], 4);
      expect((api.to('/occupy-table').single.body as Map)['table_name'], 'T1');
    });

    // Cancelling the covers question sends NOTHING. The table stays free, which
    // is better than the seat-first flow it replaces: that one left a table
    // occupied and empty whenever a waiter backed out.
    testWidgets('cancelling the covers question writes nothing at all', (tester) async {
      final api = await pumpEntry(tester, role: 'waiter', occupyOnSend: true);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send order'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(api.writes, isEmpty);
      // …and the pad is exactly as it was found, cart intact.
      expect(find.textContaining('Send order'), findsOneWidget);
    });

    // EVERYBODY ELSE'S FLOW IS BYTE-FOR-BYTE THE ONE THAT SHIPPED: they seated
    // the table first, so the send asks nothing and occupies nothing.
    testWidgets('an owner\'s order entry is untouched', (tester) async {
      final api = await pumpEntry(tester, role: 'admin', occupyOnSend: false);
      await addOneAndSend(tester);
      expect(find.text('How many guests at this table?'), findsNothing);
      expect(api.to('/occupy-table'), isEmpty);
      expect(api.to('/orders'), hasLength(1));
    });

    // Item 19 reaches the order pad too: the running-bill strip and the total on
    // the Send button. The MENU price stays — it is the card in the guest's
    // hands, and a waiter who cannot quote a dish cannot take the order.
    testWidgets('the pad shows the menu price and no bill total', (tester) async {
      await pumpEntry(tester, role: 'waiter', occupyOnSend: true);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('₹320.00'), findsOneWidget, reason: 'the menu price is the menu');
      expect(find.text('Send order · 1 item'), findsOneWidget);
      expect(find.textContaining('Send order · 1 item · ₹'), findsNothing);
    });

    testWidgets('an owner keeps the total on the send button', (tester) async {
      await pumpEntry(tester, role: 'admin', occupyOnSend: false);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Send order · 1 item · ₹320.00'), findsOneWidget);
    });
  });

  // ======================================================== the policy itself

  group('FloorScope', () {
    Profile who(String role, {List<String> actions = const ['a1']}) =>
        Profile.fromJson(<String, dynamic>{
          'role': role,
          'role_all': [role],
          'actions_set': actions,
          'action_names': const ['View Tables', 'Occupy Table', 'View Order APC'],
        });

    test('a waiter loses every control and every figure', () {
      // On the LAYOUT surface, which is the strictly harder case: the flags the
      // surface alone would have turned off are on, so every `false` below is
      // the ROLE's answer and not D5's.
      final s = FloorScope.of(who('waiter'), surface: FloorSurface.plan);
      expect([
        s.seat, s.settle, s.release, s.editSeating, s.deleteTable,
        s.billOps, s.guestQr, s.assignWaiter, s.addTable, s.money,
        s.floorSummary,
      ], everyElement(isFalse));
    });

    test('a granted action does not give one back', () {
      // The tenant ticked "View Order APC" for its waiters. The server will
      // serve them the money; this file is the other question.
      final s = FloorScope.of(who('waiter'));
      expect(s.money, isFalse);
      expect(RoleScope.showsMoney(who('waiter')), isFalse);
    });

    test('nobody else is narrowed — not one flag', () {
      for (final role in ['admin', 'manager', 'cashier', 'captain', 'employee', 'valet']) {
        final s = FloorScope.of(who(role), surface: FloorSurface.plan);
        expect([
          s.seat, s.settle, s.release, s.editSeating, s.deleteTable,
          s.billOps, s.guestQr, s.assignWaiter, s.addTable, s.money,
          s.floorSummary,
        ], everyElement(isTrue), reason: '$role lost something it had');
      }
    });

    test('a waiter who is also something else keeps the lot', () {
      for (final other in ['manager', 'captain', 'cashier']) {
        final p = Profile.fromJson(<String, dynamic>{
          'role': 'waiter',
          'role_all': ['waiter', other],
          'actions_set': const ['a1'],
          'action_names': const <String>[],
        });
        expect(FloorScope.of(p).settle, isTrue, reason: 'waiter + $other works the till');
      }
    });

    // REQUIREMENT D5 AS A PROPOSITION, stated where it can be argued with.
    test('the service surface refuses every layout flag, to everybody', () {
      for (final role in ['admin', 'manager', 'cashier', 'captain', 'waiter']) {
        final s = FloorScope.of(who(role), surface: FloorSurface.service);
        expect([s.editSeating, s.deleteTable, s.addTable, s.arrangeFloor],
            everyElement(isFalse),
            reason: '$role can still re-lay-out the floor from the service screen');
      }
    });

    test('and the plan surface cannot hand a waiter one back', () {
      final s = FloorScope.of(who('waiter'), surface: FloorSurface.plan);
      expect([s.editSeating, s.deleteTable, s.addTable, s.arrangeFloor],
          everyElement(isFalse),
          reason: 'the surface overruled the role, which is exactly backwards');
    });

    // The default is the RESTRICTIVE one: a call site written later and missing
    // the argument must lose a layout control, never gain one.
    test('the default surface is service', () {
      final s = FloorScope.of(who('admin', actions: const ['*']));
      expect([s.editSeating, s.deleteTable, s.addTable, s.arrangeFloor],
          everyElement(isFalse));
    });

    // AND THE SURFACE TOUCHES NOTHING ELSE. D5 is about the layout controls; it
    // must not quietly take the till off the service screen.
    test('the surface changes nothing else at all', () {
      for (final surface in FloorSurface.values) {
        final a = FloorScope.of(who('admin', actions: const ['*']), surface: surface);
        expect([a.seat, a.settle, a.release, a.billOps, a.guestQr, a.assignWaiter,
                a.money, a.floorSummary, a.managerOnlyAsks],
            everyElement(isTrue), reason: 'an owner lost a service control on ${surface.name}');
      }
    });
  });

  // ======================================================== the floor summary

  // THE "FLOOR PLAN" STRIP AT THE TOP OF TABLES.
  //
  // "27 tables · 4 Occupied · 0 Reserved · 23 Free" is a fact about the
  // RESTAURANT, sitting at the top of the screen a waiter lands on, above a grid
  // that is otherwise about their own tables. It also reads as a control: a
  // header, with a count, in exactly the place the floor-layout controls live
  // for everyone else.
  //
  // Asserted on the PAINTED GLYPHS rather than on the widget, so it cannot pass
  // by the header being present-but-empty, and run for an owner too — the
  // failure this pins against is not "a waiter saw a chip", it is "the fix took
  // the floor read-out away from the person who runs the floor".
  group('the floor-plan summary strip', () {
    // The SUMMARY chips are count-prefixed — '4 Occupied', '23 Free' — while an
    // individual table tile carries a bare 'Occupied'. Matching the count is
    // what separates "the house read-out is gone" from "the waiter can no longer
    // tell whether their own table is taken", which would be a far worse bug
    // than the one being fixed.
    final summaryChip = RegExp(r'\d+\s+(Occupied|Reserved|Free)');

    testWidgets('a waiter does not get it', (tester) async {
      await _mountFloor(tester, role: 'waiter');
      final painted = _painted(tester).join(' | ');
      expect(painted, isNot(contains('Floor plan')));
      expect(summaryChip.hasMatch(painted), isFalse,
          reason: 'a house-wide occupancy count reached a waiter: $painted');
    });

    testWidgets('an owner keeps it, unchanged', (tester) async {
      // D5 renamed the header per surface — the Tables screen says Tables, the
      // Floor plan screen says Floor plan — but the READ-OUT, which is what this
      // group exists to protect, is on both.
      await _mountFloor(tester, role: 'admin');
      var painted = _painted(tester).join(' | ');
      expect(painted, contains('Tables'));
      expect(summaryChip.hasMatch(painted), isTrue,
          reason: 'the floor read-out went missing for the person who runs the floor');

      await _mountFloor(tester, role: 'admin', plan: true);
      painted = _painted(tester).join(' | ');
      expect(painted, contains('Floor plan'));
      expect(summaryChip.hasMatch(painted), isTrue);
    });

    testWidgets('and the tables themselves are still there for the waiter',
        (tester) async {
      // The strip goes; the screen does not. A waiter still lands on Tables and
      // still sees the floor they are working.
      await _mountFloor(tester, role: 'waiter');
      expect(find.text('T1'), findsWidgets);
    });
  });
}
