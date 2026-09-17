import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// THE V3 CLIENT BLOCK — C2, C3, C5, C6, D1, D2 and the client half of A2.
///
/// THE RULE THIS FILE IS BUILT ON, and it is the one the production bug taught.
///
/// The waiter scoping used to be decided HERE, by asking whether every role
/// string on the profile was literally the word "waiter". A custom role is
/// stored as a UUID, so any tenant using granular RBAC had waiters carrying
/// `["waiter", "<uuid>"]`, the test failed, and every restriction lifted —
/// including the money. The rule now lives once, on the server, and arrives as
/// `scope.waiter_only`. So the first group below does not test a role NAME at
/// all: it feeds the exact production shape and pins that the client OBEYS the
/// server's answer, in both directions.
///
/// AND THE TWO PROMISES THE FLOOR TESTS ALREADY RUN ON:
///
///   * A HIDDEN CONTROL MUST BE UNREACHABLE, NOT MERELY UNDRAWN. Every scoping
///     test drives the surviving surface and asserts the WRITE never leaves —
///     no settle, no approve, no second print, no role write.
///   * AN ADMIN MUST LOSE NOTHING. Every case is run for an owner too, and the
///     owner's assertions are the shipped behaviour. The failure to fear is not
///     "a waiter saw a figure", it is "the fix took the till away from the
///     person who runs it".

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(
    this.routes, {
    this.actions = const ['*'],
    this.role = 'admin',
    this.roleAll,
    this.waiterOnly,
    this.actionNames = const [
      'View Orders', 'Create Order', 'View Tables', 'Occupy Table',
      'View Menu', 'View Bills',
    ],
  });

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;

  /// The WHOLE role set, so a test can feed the production shape
  /// `["waiter", "<uuid>"]` rather than a tidy one this app never saw.
  final List<String>? roleAll;

  /// The server's own `scope.waiter_only`, or null for a backend that predates
  /// the field (which is when — and only when — the local fallback answers).
  final bool? waiterOnly;

  final List<String> actionNames;

  final List<String> calls = <String>[];
  final List<({String method, String path, Object? body})> writes = [];

  /// Paths that must fail, so a refusal can be exercised as well as a success.
  final Set<String> failWrites = <String>{};

  /// Path fragment -> the server's answer to a write there, for the writes
  /// whose ANSWER a screen reads (a print names the next party's seat).
  final Map<String, Object? Function(Object? body)> replies = {};

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
          'role_all': roleAll ?? [role],
          if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
          'actions_set': actions,
          'action_names': actionNames,
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      if (failWrites.any(path.contains)) throw ApiException('nope', 500);
      for (final r in replies.entries) {
        if (path == r.key) return r.value(body);
      }
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

// ---------------------------------------------------------------- fixtures --

/// The production shape that defeated the old client-side rule: a waiter who
/// also holds one of their tenant's own custom roles, stored by id.
const String _customRoleId = 'd2b1f0c4-1b3a-4c5e-9f11-2a7c8e6b4d10';

Map<String, dynamic> _table({bool occupied = true, String name = 'T1'}) => {
      'table_name': name,
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': occupied,
      'reserved': false,
      'num_covers': 3,
      'covers': 3,
      'table_total': 1380.0,
      'table_apc': 460.0,
      'apc_status': 'red',
      'waiter_name': 'Ravi K',
    };

Map<String, dynamic> _bill({
  String? paymentStatus,
  String firstOrderAt = '2026-09-11T10:00:00Z',
  String lastOrderAt = '2026-09-11T10:40:00Z',
  String? settledAt,
}) =>
    {
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
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
      ],
      'first_order_at': firstOrderAt,
      'last_order_at': lastOrderAt,
      'admin_approved_at': ?settledAt,
      'payment_status': paymentStatus,
    };

/// CLIENT ITEM 6 — the seat the server opens beside a printed T1: its own
/// row, free, unprinted, and named for its root.
Map<String, dynamic> _nextPartySeat() => {
      'table_name': 'T1 #2',
      'parent_table': 'T1',
      'party_no': 2,
      'display_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': false,
      'reserved': false,
      'print_count': 0,
      'bill_printed_at': null,
      'printed_at': null,
    };

/// What a current backend does on a print: answers with the seat it opened,
/// and lists that seat on the next /get-tables.
_FakeApi _withNextPartyOnPrint(_FakeApi api) {
  api.replies['/print/bill'] = (_) {
    api.routes['/get-tables'] = [_table(), _nextPartySeat()];
    return <String, dynamic>{
      'success': true,
      'next_party_table': 'T1 #2',
      'next_party_message': 'Seat the next party at T1 (next party).',
    };
  };
  return api;
}

Map<String, dynamic> _floorRoutes({bool occupied = true, Map<String, dynamic>? bill}) => {
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
      '/menu': const <dynamic>[],
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

/// A waiter as the SERVER describes one: the primary role, the tenant's custom
/// role beside it, and the server's own verdict.
_FakeApi _waiterApi(Map<String, dynamic> routes, {bool? waiterOnly = true}) => _FakeApi(
      routes,
      role: 'waiter',
      roleAll: const ['waiter', _customRoleId],
      waiterOnly: waiterOnly,
      actions: const ['a1'],
    );

_FakeApi _ownerApi(Map<String, dynamic> routes) =>
    _FakeApi(routes, role: 'admin', actions: const ['*']);

Future<_FakeApi> _mountFloor(WidgetTester tester, _FakeApi api,
    {bool plan = false, Size size = const Size(1400, 1800)}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  final p = rest.auth.profile!;
  await tester.pumpWidget(
      _host(plan ? m.floorPlanModule(rest, p) : m.tablesModule(rest, p)));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _openTable(WidgetTester tester, {String name = 'T1'}) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* not on this sheet at all */}
  await tester.pumpAndSettle();
}

List<String> _buttons(WidgetTester tester) =>
    [for (final b in tester.widgetList<ForkButton>(find.byType(ForkButton))) b.label];

/// Press every enabled control the sheet still offers. The assertion that
/// matters afterwards is what did NOT reach the network.
Future<void> _pressEverything(WidgetTester tester) async {
  for (final b in find.byType(ForkButton).evaluate().toList()) {
    final w = b.widget as ForkButton;
    if (w.onPressed == null) continue;
    if (w.label == 'Add order') continue; // pushes a route, tested elsewhere
    w.onPressed!();
    await tester.pumpAndSettle();
  }
  for (final t in find.byType(TextButton).evaluate().toList()) {
    final w = t.widget as TextButton;
    if (w.onPressed == null) continue;
    w.onPressed!();
    await tester.pumpAndSettle();
  }
}

void main() {
  // [PrintedBills] is a process-wide singleton — the grid and the sheet have to
  // agree the instant one of them prints — so it is reset between tests.
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // C2 — A WAITER CANNOT SETTLE, DECIDED BY THE SERVER
  // ==========================================================================

  group('C2 · settling is the server\'s decision, obeyed here', () {
    // THE PRODUCTION SHAPE. `["waiter", "<uuid>"]` is what defeated the old
    // client-side `roles.every((r) => r == "waiter")`; with the server's answer
    // carried on the profile it cannot defeat anything.
    test('the custom-role UUID that used to un-scope a waiter no longer does', () {
      final p = Profile.fromJson(<String, dynamic>{
        'role': 'waiter',
        'role_all': const ['waiter', _customRoleId],
        'scope': const {'waiter_only': true},
        'actions_set': const ['a1'],
        'action_names': const ['View Tables', 'View Order APC'],
      });
      expect(RoleScope.isWaiterOnly(p), isTrue);
      expect(FloorScope.of(p).settle, isFalse);
      expect(RoleScope.showsMoney(p), isFalse);
    });

    // THE CONVERSE, and it is the half that keeps this honest: when the server
    // says NOT scoped, the client does not argue. A tenant whose "waiter" role
    // is really a floor manager is the server's call to make, not this app's.
    test('a server saying not-scoped is obeyed even for a role named waiter', () {
      final p = Profile.fromJson(<String, dynamic>{
        'role': 'waiter',
        'role_all': const ['waiter'],
        'scope': const {'waiter_only': false},
        'actions_set': const ['a1'],
        'action_names': const ['View Tables'],
      });
      expect(RoleScope.isWaiterOnly(p), isFalse);
      expect(FloorScope.of(p).settle, isTrue);
    });

    testWidgets('no control on a waiter\'s sheet settles the table', (tester) async {
      final api = await _mountFloor(tester, _waiterApi(_floorRoutes()));
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      expect(_buttons(tester), isNot(contains('Settle bill')));
      await _pressEverything(tester);

      for (final route in const [
        'confirm-payment', 'admin-approve-payment', '/bills/settle', '/release-table',
      ]) {
        expect(api.to(route), isEmpty, reason: '$route was reachable to a waiter');
      }
      // Nor by the other road into the till: marking the order Paid.
      final paid = api.to('/orders/').where((w) =>
          w.path.endsWith('/status') &&
          '${(w.body as Map?)?['status'] ?? ''}'.toLowerCase() == 'paid');
      expect(paid, isEmpty);
    });

    // THE APPROVE-A-GUEST-PAYMENT CARD, which C2 names because it CLOSES the
    // table — it is the settle wearing a different hat.
    testWidgets('nor does the approve-a-guest-payment card, which also closes it',
        (tester) async {
      final api = await _mountFloor(
          tester, _waiterApi(_floorRoutes(bill: _bill(paymentStatus: 'pending_approval'))));
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));

      expect(find.text('Approve payment & close'), findsNothing);
      await _pressEverything(tester);
      expect(api.to('admin-approve-payment'), isEmpty);
      expect(api.to('confirm-payment'), isEmpty);
    });

    // AN ADMIN LOSES NOTHING — both halves, on the same two bills.
    testWidgets('an owner still settles, and still approves', (tester) async {
      await _mountFloor(tester, _ownerApi(_floorRoutes()));
      await _openTable(tester);
      await _reveal(tester, find.text('Settle bill'));
      expect(_buttons(tester), contains('Settle bill'));

      await _mountFloor(
          tester, _ownerApi(_floorRoutes(bill: _bill(paymentStatus: 'pending_approval'))));
      await _openTable(tester);
      await _reveal(tester, find.text('Approve payment & close'));
      expect(find.text('Approve payment & close'), findsOneWidget);
    });

    // THE FALLBACK PATH — an app pointed at a backend older than the `scope`
    // block. It must still scope this waiter, because the old client rule is
    // exactly what production proved wrong.
    test('with no server answer at all, the custom-role waiter is STILL scoped', () {
      final p = Profile.fromJson(<String, dynamic>{
        'role': 'waiter',
        'role_all': const ['waiter', _customRoleId],
        'actions_set': const ['a1'],
        'action_names': const ['View Tables'],
      });
      expect(p.waiterOnly, isNull, reason: 'the server said nothing');
      expect(RoleScope.isWaiterOnly(p), isTrue);
      expect(FloorScope.of(p).settle, isFalse);
    });
  });

  // ==========================================================================
  // C3 — THE ONE PRINT
  // ==========================================================================

  group('C3 · a waiter prints once, and the table leaves their floor', () {
    Future<_FakeApi> printAsWaiter(WidgetTester tester, _FakeApi api) async {
      await _mountFloor(tester, api);
      await _openTable(tester);
      await _reveal(tester, find.byKey(const ValueKey('table-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-print-bill')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      return api;
    }

    // CHANGED ON PURPOSE FOR CLIENT ITEM 6. This test used to pin that the
    // table went and nothing came back — which is exactly the complaint: "Table
    // where bill is printed is disappearing from the waiter app. There should be
    // a duplicate table showing same number for order taking for the next round
    // of guests." C3 still holds for the PRINTED PARTY; the number comes back as
    // the next party's seat the server opened on the print.
    testWidgets('the print happens, the printed party goes, and the next party gets T1',
        (tester) async {
      final api = await printAsWaiter(tester, _withNextPartyOnPrint(_waiterApi(_floorRoutes())));

      // The action itself is untouched — the guest still gets a real bill.
      expect(api.to('/print/bill'), hasLength(1));
      expect((api.to('/print/bill').single.body as Map)['table_name'], 'T1');

      // The sheet closed itself and the floor came back WITHOUT the printed row…
      expect(find.text('Table T1'), findsNothing);
      expect(find.byKey(const ValueKey('table-title-T1')), findsNothing,
          reason: 'the printed party is still on their floor');
      // …and WITH the number, as the next party's seat.
      expect(find.byKey(const ValueKey('table-title-T1 #2')), findsOneWidget);
      expect(find.text('T1'), findsOneWidget, reason: 'the tile reads the same number');
      expect(find.byKey(const ValueKey('next-party-chip-T1 #2')), findsOneWidget);
      expect(find.text('Next party'), findsOneWidget);
      // The waiter is told where the next guests go, in the server's words —
      // in the line that follows "Printing bill…" off the screen.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.textContaining('It has come off your tables. Seat the next party at T1 (next party).'),
          findsOneWidget);
      expect(find.textContaining('every table you printed'), findsNothing);
    });

    // THE OLD BACKEND, and the reason the empty-floor sentence stays: no seat is
    // opened, so the floor is what 2.0.0 showed.
    testWidgets('against a backend with no next-party seat, the table goes and nothing replaces it',
        (tester) async {
      await printAsWaiter(tester, _waiterApi(_floorRoutes()));
      expect(find.text('Table T1'), findsNothing);
      expect(find.text('T1'), findsNothing, reason: 'the printed table is still on their floor');
      expect(find.textContaining('every table you printed'), findsOneWidget);
    });

    // NOTHING WAS WRITTEN TO THE TABLE, and this is the assertion that separates
    // "clear from their view" from the settle C2 forbids. The bill is still
    // owing; only one list on one device changed.
    testWidgets('and NOTHING was written to the table — it is not a settle',
        (tester) async {
      final api = await printAsWaiter(tester, _waiterApi(_floorRoutes()));
      expect(api.to('/release-table'), isEmpty);
      expect(api.to('confirm-payment'), isEmpty);
      expect(api.to('admin-approve-payment'), isEmpty);
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);
      expect(api.writes.where((w) => w.path.endsWith('/status')), isEmpty);
      // The only write of the whole flow was the print.
      expect(api.writes.map((w) => w.path).toSet(), {'/print/bill'});
    });

    // THE SECOND PRINT IS UNREACHABLE, not merely undrawn: the table is gone, so
    // there is no sheet to reach, and driving what IS on screen writes nothing.
    testWidgets('a second print is unreachable on the next look at the floor',
        (tester) async {
      final api = await printAsWaiter(tester, _withNextPartyOnPrint(_waiterApi(_floorRoutes())));
      // Come back to the screen as a back-navigation or a poll would.
      await _mountFloor(tester, api);
      expect(find.byKey(const ValueKey('table-title-T1')), findsNothing);
      // The only T1 left is the next party's, which has nothing on it to print.
      expect(find.byKey(const ValueKey('table-title-T1 #2')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-print-bill')), findsNothing);
      await _pressEverything(tester);
      final printed = [for (final w in api.to('/print/bill')) (w.body as Map)['table_name']];
      expect(printed, ['T1'], reason: 'a second bill was printed for the printed party');
    });

    // A PRINT THAT FAILED IS A PRINT THEY STILL HAVE TO MAKE. Burning the one
    // attempt on a refused request would leave a waiter holding a table they
    // cannot bill at all.
    testWidgets('a refused print costs them nothing — the button is still there',
        (tester) async {
      final api = _waiterApi(_floorRoutes())..failWrites.add('/print/bill');
      await printAsWaiter(tester, api);
      expect(find.text('Table T1'), findsOneWidget, reason: 'the sheet closed on a failure');
      expect(find.byKey(const ValueKey('table-print-bill')), findsOneWidget);
    });

    // AN ADMIN LOSES NOTHING: they print, and print again, and the table stays.
    testWidgets('an owner prints as many times as they like', (tester) async {
      final api = _ownerApi(_floorRoutes());
      await _mountFloor(tester, api);
      for (var i = 0; i < 2; i++) {
        await _openTable(tester);
        await _reveal(tester, find.text('Print bill'));
        await tester.tap(find.text('Print bill'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Print'));
        await tester.pumpAndSettle();
        // The sheet is still open and the table is still on the floor.
        expect(find.text('T1'), findsWidgets);
        await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
        await tester.pumpAndSettle();
      }
      expect(api.to('/print/bill'), hasLength(2));
      expect(find.text('T1'), findsWidgets);
    });

    // THE POLICY ITSELF, stated where it can be argued with.
    test('BillPrintScope narrows nobody but a waiter, and only after a print', () {
      Profile who(String role, {List<String> actions = const ['a1']}) =>
          Profile.fromJson(<String, dynamic>{
            'role': role,
            'role_all': [role],
            'actions_set': actions,
            'action_names': const ['View Tables'],
          });

      final fresh = BillPrintScope.of(who('waiter'), printed: false);
      expect([fresh.print, !fresh.reprintNeedsSenior, !fresh.retiresTable],
          everyElement(isTrue));
      final spent = BillPrintScope.of(who('waiter'), printed: true);
      expect([spent.print, !spent.reprintNeedsSenior, !spent.retiresTable],
          everyElement(isFalse));

      for (final role in ['admin', 'manager', 'cashier', 'captain']) {
        for (final printed in [false, true]) {
          final s = BillPrintScope.of(who(role), printed: printed);
          expect(s.print, isTrue, reason: '$role lost the reprint');
          expect(s.retiresTable, isFalse, reason: '$role lost a table off their floor');
        }
      }
    });
  });

  // ==========================================================================
  // C5 / C6 — ROLE MANAGEMENT
  // ==========================================================================

  group('C5 and C6 · roles can be read, and edited by whoever may', () {
    const String permCreateRole = 'c0135d18-68b4-45e9-9b51-849158df6efd';
    const String permDeleteRole = '53d0927d-00f4-48cc-a40c-51edb09826d8';

    Map<String, dynamic> roleRoutes() => {
          '/roles': [
            {
              'id': 'role-1',
              'role_name': 'Floor Supervisor',
              'actions_performable': const ['act-1'],
            },
          ],
          '/actions': const [
            {'id': 'act-1', 'action_name': 'View Tables', 'group': 'Floor'},
            {'id': 'act-2', 'action_name': 'Close Bill', 'group': 'Money'},
          ],
          '/core-roles': const [
            {'role': 'admin', 'actions': ['*']},
            {'role': 'waiter', 'actions': ['act-1']},
            {'role': 'manager', 'actions': ['act-1', 'act-2', 'act-unknown']},
          ],
        };

    Future<_FakeApi> mountRoles(WidgetTester tester, {required List<String> actions}) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = _FakeApi(roleRoutes(),
          role: 'manager',
          actions: actions,
          actionNames: const ['View Roles', 'Create Role', 'Delete Role']);
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.rolesModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();
      return api;
    }

    // ---- C6 -------------------------------------------------------------
    //
    // There was no gesture on a core role at all: a restaurant could see that a
    // role called "waiter" existed and had no way whatever to find out what one
    // is allowed to do.
    testWidgets('a core role opens, and says what it grants', (tester) async {
      await mountRoles(tester, actions: const ['*']);
      expect(find.byKey(const ValueKey('core-role-waiter')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('core-role-waiter')));
      await tester.pumpAndSettle();

      expect(find.text('CORE ROLE'), findsOneWidget);
      // The NAME, joined from /actions — never the raw uuid.
      expect(find.text('View Tables'), findsWidgets);
      expect(find.textContaining('act-1'), findsNothing);
    });

    testWidgets('the owner role says "everything" rather than listing a "*"',
        (tester) async {
      await mountRoles(tester, actions: const ['*']);
      await tester.tap(find.byKey(const ValueKey('core-role-admin')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Every permission in the system'), findsOneWidget);
      expect(find.text('*'), findsNothing);
    });

    // An id this build has no name for is COUNTED, not dropped: a list that
    // silently under-reports what a role can do is worse than no list.
    testWidgets('a permission this build cannot name is reported, not swallowed',
        (tester) async {
      await mountRoles(tester, actions: const ['*']);
      await tester.tap(find.byKey(const ValueKey('core-role-manager')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 further permission'), findsOneWidget);
    });

    // ---- C5 -------------------------------------------------------------
    testWidgets('a manager granted the role actions can create, edit and delete',
        (tester) async {
      await mountRoles(tester, actions: const [permCreateRole, permDeleteRole]);
      expect(find.text('New role'), findsOneWidget);
      expect(find.byTooltip('Delete role'), findsOneWidget);

      await tester.tap(find.text('Floor Supervisor'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      final box = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Close Bill'));
      expect(box.onChanged, isNotNull, reason: 'a manager who may edit cannot tick a box');
    });

    // A CONTROL THAT WOULD 403 IS NOT SHOWN — and, because undrawn is not
    // enough, the surviving surface is driven and the writes are asserted away.
    testWidgets('a reader without them may VIEW and can write nothing', (tester) async {
      final api = await mountRoles(tester, actions: const ['some-other-action']);
      expect(find.text('New role'), findsNothing);
      expect(find.byTooltip('Delete role'), findsNothing);

      // C5's first verb still works: the role opens and shows what it grants.
      await tester.tap(find.text('Floor Supervisor'));
      await tester.pumpAndSettle();
      expect(find.text('View Tables'), findsWidgets);
      // Said twice, deliberately: once on the page ("you can look, not
      // change") and once inside the role that is open, where the tick boxes a
      // reader can see but not operate would otherwise be unexplained.
      expect(find.textContaining('needs the role-editing permission'), findsNWidgets(2));
      // …and the second does not: no Save, and every tick box is inert.
      expect(find.text('Save'), findsNothing);
      final box = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Close Bill'));
      expect(box.onChanged, isNull);

      await _pressEverything(tester);
      expect(api.to('/roles'), isEmpty, reason: 'a role was written by someone who may not');
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);
    });

    // AN ADMIN LOSES NOTHING.
    testWidgets('an owner keeps the whole editor', (tester) async {
      await mountRoles(tester, actions: const ['*']);
      expect(find.text('New role'), findsOneWidget);
      expect(find.byTooltip('Delete role'), findsOneWidget);
      await tester.tap(find.text('Floor Supervisor'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
    });

    // A build pointed at a backend with no /core-roles must not lose the screen.
    testWidgets('an older backend costs the tap, not the page', (tester) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final routes = roleRoutes()..remove('/core-roles');
      final api = _FakeApi(routes, role: 'admin', actions: const ['*']);
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.rolesModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Core roles'), findsOneWidget);
      expect(find.text('Floor Supervisor'), findsOneWidget);
      // Inert rather than a button that does nothing when pressed.
      await tester.tap(find.byKey(const ValueKey('core-role-waiter')));
      await tester.pumpAndSettle();
      expect(find.text('CORE ROLE'), findsNothing);
    });
  });

  // ==========================================================================
  // C7 / H8 — DELETE IN ONE PLACE, AND EXPLICIT ABOUT ITSELF
  // ==========================================================================

  group('C7 and H8 · delete lives in the Floor header and says what it does', () {
    testWidgets('the confirmation names what goes AND what survives', (tester) async {
      final api = await _mountFloor(
          tester, _ownerApi(_floorRoutes(occupied: false)), plan: true);
      await tester.tap(find.byKey(const ValueKey('floor-delete-table')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-pick-T1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('disappears from the floor plan on every device'),
          findsOneWidget);
      expect(find.textContaining('past orders and bills are NOT deleted'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      // Nothing has been written while the question is still on screen.
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('floor-delete-confirm')));
      await tester.pumpAndSettle();
      expect(api.to('/table/T1'), hasLength(1));
      expect(api.to('/table/T1').single.method, 'DELETE');
    });

    testWidgets('keeping it writes nothing', (tester) async {
      final api = await _mountFloor(
          tester, _ownerApi(_floorRoutes(occupied: false)), plan: true);
      await tester.tap(find.byKey(const ValueKey('floor-delete-table')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-pick-T1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);
    });

    // The server refuses a busy table ("Settle or release the table before
    // deleting it"), so the picker does not offer one — the answer a manager
    // needs before they walk to the table, not after.
    testWidgets('an occupied table is not offered, and is said not to be',
        (tester) async {
      final api = await _mountFloor(tester, _ownerApi(_floorRoutes()), plan: true);
      await tester.tap(find.byKey(const ValueKey('floor-delete-table')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-pick-T1')), findsNothing);
      expect(find.textContaining('settled or released'), findsWidgets);
      expect(api.writes.where((w) => w.method == 'DELETE'), isEmpty);
    });
  });

  // ==========================================================================
  // D1 / D2 — THE DURATIONS
  // ==========================================================================

  group('D1 and D2 · one basis, one formatter, one set of thresholds', () {
    // The clock is injected: a duration that ticks cannot be asserted against
    // the real DateTime.now().
    final now = DateTime.utc(2026, 9, 11, 11, 0);

    test('an elapsed span is measured between two server instants', () {
      expect(m.elapsedSinceMsAt('2026-09-11T10:00:00Z', now), 3600000);
      // An offset written into the stamp is the same instant, not a shift.
      expect(m.elapsedSinceMsAt('2026-09-11T15:30:00+05:30', now), 3600000);
    });

    test('a span that has ENDED stops at its end, not at now', () {
      expect(
          m.elapsedBetweenMsAt('2026-09-11T10:00:00Z', '2026-09-11T10:40:00Z', now),
          40 * 60000);
      // …and with no end it runs to now, which is what an open bill is.
      expect(m.elapsedBetweenMsAt('2026-09-11T10:00:00Z', '', now), 3600000);
    });

    test('a row that cannot be dated gets no duration at all', () {
      expect(m.elapsedSinceMsAt('', now), isNull);
      expect(m.elapsedSinceMsAt('not a date', now), isNull);
      expect(m.elapsedBetweenMsAt('', '2026-09-11T10:40:00Z', now), isNull);
    });

    // A server clock a few seconds ahead of the tablet's is ordinary; a chip
    // reading "-3s" in front of a guest is not.
    test('a future instant reads zero, never negative', () {
      expect(m.elapsedSinceMsAt('2026-09-11T11:30:00Z', now), 0);
      expect(
          m.elapsedBetweenMsAt('2026-09-11T10:40:00Z', '2026-09-11T10:00:00Z', now), 0);
    });

    // D2 ON THE TABLE — and D1 beside it, for the waiter the requirement is for.
    testWidgets('a waiter sees how long the table has run and how long the kitchen has had it',
        (tester) async {
      await _mountFloor(tester, _waiterApi(_floorRoutes()));
      await _openTable(tester);
      await tester.pump();

      expect(find.byKey(const ValueKey('table-open-for')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-latest-order')), findsOneWidget);
      expect(find.textContaining('On table'), findsOneWidget);
      expect(find.textContaining('Latest order'), findsOneWidget);
    });

    // Two chips saying the same span with different words in front of them is
    // how a screen teaches people to stop reading it.
    testWidgets('a table that has ordered once shows the span once', (tester) async {
      const at = '2026-09-11T10:00:00Z';
      await _mountFloor(tester,
          _waiterApi(_floorRoutes(bill: _bill(firstOrderAt: at, lastOrderAt: at))));
      await _openTable(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('table-open-for')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-latest-order')), findsNothing);
    });

    // AN ADMIN LOSES NOTHING — and gains the same read.
    testWidgets('an owner gets the same two chips on the same bill', (tester) async {
      await _mountFloor(tester, _ownerApi(_floorRoutes()));
      await _openTable(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('table-open-for')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-latest-order')), findsOneWidget);
    });

    // A bill with no timestamps must not grow a "0s" chip: that would be a claim
    // about the kitchen that nobody made.
    testWidgets('a bill the server did not date grows no chip', (tester) async {
      final undated = _bill()
        ..remove('first_order_at')
        ..remove('last_order_at');
      await _mountFloor(tester, _waiterApi(_floorRoutes(bill: undated)));
      await _openTable(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('table-open-for')), findsOneWidget);
      expect(find.textContaining('On table'), findsNothing,
          reason: 'an undated bill was given a duration anyway');
    });
  });
}
