import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart' as shell;
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

/// THE NINE CAPABILITY FLAGS: PARSED, CARRIED, AND OBEYED.
///
/// WHAT THIS FILE IS FOR, stated as the failure it is built to catch.
///
/// The server ships nine answers on the session's `scope` block — settle_bill,
/// delete_table, edit_table, manage_table_sections, comp_item,
/// waive_service_charge, void_order, view_roles, manage_roles. Each is backed
/// by a permission uuid and a route guard, and each exists so that no client
/// has to hold the uuid or reason about role names. A field nobody reads is not
/// a feature, it is a claim; so every test here is written to FAIL if this app
/// goes back to deriving its own answer.
///
/// THE SHAPE OF THAT TEST, and it is the one that would have caught
/// csrorganics: a profile whose ROLE STRINGS say one thing and whose SERVER
/// FLAGS say the opposite. The old client asked `roles.every((r) => r ==
/// "waiter")` and got the wrong answer on every tenant that used custom roles,
/// because a custom role is a uuid and a uuid is not the word "waiter". Any
/// rule derived from role strings will disagree with the fixtures below; only a
/// rule that reads the flags will pass them.
///
/// AND THE THREE PROMISES EVERY SCOPING TEST IN THIS REPO RUNS ON:
///
///   * A HIDDEN CONTROL MUST BE UNREACHABLE, NOT MERELY UNDRAWN. Where a flag
///     removes a control, the surviving surface is DRIVEN and the assertion is
///     that the WRITE never left. `findsNothing` on a button is not scoping.
///   * AN ADMIN MUST LOSE NOTHING. Every case runs for an owner too. The
///     failure to fear is not "a waiter saw a figure", it is "the fix emptied
///     the till".
///   * A MISSING FLAG MEANS "THE SERVER DID NOT SAY", NEVER FALSE. An app that
///     auto-updated ahead of its backend must behave exactly as it did the day
///     before, or the fix takes the restaurant off the air.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(
    this.routes, {
    this.actions = const ['*'],
    this.role = 'admin',
    this.roleAll,
    this.scope,
  });

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;
  final List<String>? roleAll;

  /// The WHOLE `scope` block verbatim, so a test can feed the exact payload
  /// /auth/employee-login builds rather than a tidied-up version of it.
  final Map<String, dynamic>? scope;

  /// Enough permitted ACTION NAMES for the keyword gates to say yes, so a test
  /// that narrows something is narrowing it with a capability rather than by
  /// starving the keyword match.
  static const List<String> actionNames = [
    'View Orders', 'Create Order', 'View Tables', 'Occupy Table',
    'View Menu', 'View Bills', 'View Roles', 'Manage Table Sections',
  ];

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
          'role_all': roleAll ?? [role],
          'scope': ?scope,
          'actions_set': actions,
          'action_names': actionNames,
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

// ------------------------------------------------------------------ fixtures

/// A tenant's own custom role, stored by id — the shape that defeated the old
/// client-side rule and the reason none of these answers may be derived here.
const String _customRoleId = 'd2b1f0c4-1b3a-4c5e-9f11-2a7c8e6b4d10';

/// The permission uuids this app still carries ONLY as the fallback for a
/// backend too old to send `scope`. A test that grants one of these while the
/// server denies the matching flag is testing exactly the drift these flags
/// exist to prevent.
const String _permNonChargeable = 'b4e7a1c9-2d58-4f36-9a07-5c81e3b0d472';
const String _permCreateRole = 'c0135d18-68b4-45e9-9b51-849158df6efd';

/// Every one of the nine, set to [value]. `waiter_only` rides along because it
/// arrives in the same block and the same parse must carry both.
Map<String, dynamic> scopeAll(bool value, {bool waiterOnly = false}) =>
    <String, dynamic>{
      'waiter_only': waiterOnly,
      for (final c in Capability.values) c.wireKey: value,
    };

Profile who({
  String role = 'admin',
  List<String> roleAll = const ['admin', 'manager'],
  List<String> actions = const ['a1'],
  List<String> actionNames = const [
    'View Tables',
    'Manage Table Sections',
    'View Roles'
  ],
  Map<String, dynamic>? scope,
}) =>
    Profile.fromJson(<String, dynamic>{
      'role': role,
      'role_all': roleAll,
      'actions_set': actions,
      'action_names': actionNames,
      'scope': ?scope,
    });

Map<String, dynamic> _table() => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': true,
      'reserved': false,
      'num_covers': 3,
      'covers': 3,
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
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
      ],
      'first_order_at': '2026-09-11T10:00:00Z',
      'last_order_at': '2026-09-11T10:40:00Z',
    };

Map<String, dynamic> _floorRoutes() => {
      '/get-tables': [_table()],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': _bill(),
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': const <dynamic>[],
    };

Map<String, dynamic> _roleRoutes() => {
      '/roles': [
        {
          'id': 'role-1',
          'role_name': 'Floor lead',
          'actions_performable': const ['act-1'],
          'permissions': const [
            {'id': 'act-1', 'action_name': 'View Tables', 'group': 'Floor'},
          ],
          'editable': true,
        },
      ],
      '/actions': const [
        {'id': 'act-1', 'action_name': 'View Tables', 'group': 'Floor'},
      ],
      '/core-roles': const [
        {
          'role': 'waiter',
          'actions': ['act-1'],
          'permissions': [
            {
              'id': 'act-1',
              'action_name': 'View Tables',
              'action_desc': null,
              'group': 'Floor'
            },
          ],
        },
      ],
    };

// --------------------------------------------------------------------- hosts

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
  return RestClient(auth);
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

Future<_FakeApi> _mountFloor(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

/// Press every enabled control the sheet still offers, and dismiss whatever it
/// opens. What matters afterwards is what did NOT reach the network.
///
/// Each control is re-resolved by LABEL immediately before it is pressed: a
/// press rebuilds the sheet, so a list of Elements captured up front is a list
/// of corpses by the third one.
Future<void> _pressEverything(WidgetTester tester) async {
  final labels = <String>[
    for (final b in tester.widgetList<ForkButton>(find.byType(ForkButton))) b.label,
  ];
  for (final label in labels) {
    if (label == 'Add order') continue; // pushes a route, tested elsewhere
    // Its confirm dialog pops an int, and the blind dialog sweep below would
    // pop it with a bool. It is a billOps control, exercised elsewhere, and
    // nothing here turns on it.
    if (label.startsWith('Reprint')) continue;
    final b = _button(tester, (l) => l == label);
    if (b?.onPressed == null) continue;
    b!.onPressed!();
    await tester.pumpAndSettle();
    await _drainDialogs(tester);
  }
}

/// Take the AFFIRMATIVE option out of whatever dialog is on screen, repeatedly.
///
/// The last button in a dialog's action row is the one that does the thing —
/// "Print", "Release", "Confirm" — so this drives each prompt to its write
/// rather than cancelling out of it. A scoping test that only ever pressed
/// Cancel would prove nothing at all.
Future<void> _drainDialogs(WidgetTester tester) async {
  for (var round = 0; round < 8; round++) {
    final els = <Element>[
      ...find.byType(TextButton).evaluate(),
      ...find.byType(FilledButton).evaluate(),
    ];
    if (els.isEmpty) return;
    final last = els.last.widget;
    final onPressed =
        last is TextButton ? last.onPressed : (last as FilledButton).onPressed;
    if (onPressed == null) return;
    onPressed();
    await tester.pumpAndSettle();
  }
}

ForkButton? _button(WidgetTester tester, bool Function(String) match) {
  for (final b in tester.widgetList<ForkButton>(find.byType(ForkButton))) {
    if (match(b.label)) return b;
  }
  return null;
}

void main() {
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // THE TEST THAT WOULD HAVE CAUGHT CSRORGANICS
  // ==========================================================================

  group('the flags beat the role strings', () {
    // THE FIXTURE IS THE WHOLE ARGUMENT. Every role string on this profile reads
    // as senior — "admin", "manager" — and the server says no to all nine. A
    // client that derives from role_all answers "yes" nine times; a client that
    // obeys answers "no" nine times. There is no third result.
    //
    // Note there is NO "*" in `actions`: this is a tenant whose own role is
    // NAMED admin without carrying the wildcard, which is exactly the sort of
    // configuration accident the role-string rule could never tell from the
    // real thing.
    final denied = who(
      role: 'admin',
      roleAll: const ['admin', 'manager', _customRoleId],
      actions: const ['a1', _permNonChargeable, _permCreateRole],
      scope: scopeAll(false),
    );

    test('every capability the server denied is denied here', () {
      for (final c in Capability.values) {
        expect(RoleScope.may(denied, c, fallback: true), isFalse,
            reason:
                '${c.wireKey}: the server said false and the client must not argue');
        expect(denied.said(c), isFalse);
      }
    });

    test('and the floor gates go with them', () {
      final service = FloorScope.of(denied);
      final plan = FloorScope.of(denied, surface: FloorSurface.plan);
      expect(service.settle, isFalse);
      expect(service.release, isFalse);
      expect(plan.deleteTable, isFalse);
      expect(plan.addTable, isFalse);
      expect(plan.editSeating, isFalse);
      // …while everything the server did NOT speak to is untouched. This block
      // narrows what the server narrowed and nothing else.
      expect(service.seat, isTrue);
      expect(service.billOps, isTrue);
      expect(service.money, isTrue);
    });

    // THE OTHER DIRECTION, and it is the half that keeps this honest. A profile
    // holding NEITHER the permission uuid nor a senior-sounding role, whose
    // server says yes. A client re-deriving from `actions` says no; obedience
    // says yes. A tenant that granted a capability through a custom role is the
    // server's call to make, not this app's.
    test('a capability the server granted is granted, uuid or no uuid', () {
      final granted = who(
        role: 'cashier',
        roleAll: const ['cashier', _customRoleId],
        actions: const ['a1'],
        actionNames: const <String>[],
        scope: scopeAll(true),
      );
      for (final c in Capability.values) {
        expect(RoleScope.may(granted, c, fallback: false), isTrue,
            reason: '${c.wireKey}: the server said true');
      }
      expect(FloorScope.of(granted).settle, isTrue);
      expect(FloorScope.of(granted).release, isTrue);
      expect(FloorScope.of(granted, surface: FloorSurface.plan).deleteTable,
          isTrue);
    });

    // A waiter stays scoped whatever the capabilities say. The two questions are
    // different — "is this a scoped floor role" and "may this identity do x" —
    // and a tenant that ticked Close Bill for its waiters must still not get a
    // Settle button, because C2 is about the ROLE.
    test('a granted capability does not un-scope a waiter', () {
      final waiter = who(
        role: 'waiter',
        roleAll: const ['waiter', _customRoleId],
        scope: scopeAll(true, waiterOnly: true),
      );
      expect(RoleScope.isWaiterOnly(waiter), isTrue);
      expect(FloorScope.of(waiter).settle, isFalse);
      expect(FloorScope.of(waiter).release, isFalse);
      expect(FloorScope.of(waiter, surface: FloorSurface.plan).deleteTable,
          isFalse);
    });
  });

  // ==========================================================================
  // AN ADMIN LOSES NOTHING
  // ==========================================================================

  group('an admin loses nothing', () {
    // The `*` wildcard is the server's OWN admin marker out of `actions_set`,
    // and sessionCapabilities returns true for every flag when it is present —
    // so this can never contradict a correctly built server. It is here so a
    // malformed or half-migrated payload cannot take the floor away from the
    // person who owns the restaurant.
    test('the wildcard keeps every capability even against a hostile scope', () {
      final owner = who(
          role: 'admin',
          roleAll: const ['admin'],
          actions: const ['*'],
          scope: scopeAll(false));
      for (final c in Capability.values) {
        expect(RoleScope.may(owner, c, fallback: false), isTrue,
            reason: c.wireKey);
      }
      final plan = FloorScope.of(owner, surface: FloorSurface.plan);
      expect([
        plan.settle,
        plan.release,
        plan.deleteTable,
        plan.addTable,
        plan.editSeating,
        plan.billOps,
        plan.money,
      ], everyElement(isTrue));
    });

    test('an owner on the real payload keeps the whole floor', () {
      final owner = who(
          role: 'admin',
          roleAll: const ['admin'],
          actions: const ['*'],
          scope: scopeAll(true));
      final plan = FloorScope.of(owner, surface: FloorSurface.plan);
      expect([
        plan.seat,
        plan.settle,
        plan.release,
        plan.editSeating,
        plan.deleteTable,
        plan.addTable,
        plan.arrangeFloor,
        plan.billOps,
        plan.guestQr,
        plan.assignWaiter,
        plan.money,
        plan.floorSummary,
        plan.managerOnlyAsks,
      ], everyElement(isTrue));
    });
  });

  // ==========================================================================
  // A MISSING FLAG IS "NOT SAID", NEVER FALSE
  // ==========================================================================

  group('an app running ahead of its backend keeps the till', () {
    test('no scope block at all leaves every gate exactly where it was', () {
      final owner =
          who(role: 'admin', roleAll: const ['admin'], actions: const ['*']);
      final manager = who(
          role: 'manager', roleAll: const ['manager'], actions: const ['a1']);
      for (final c in Capability.values) {
        expect(owner.said(c), isNull, reason: c.wireKey);
        expect(manager.said(c), isNull, reason: c.wireKey);
        // The fallback is what the call site did before the flag existed, and it
        // is the ONLY thing consulted when the server said nothing.
        expect(RoleScope.may(manager, c, fallback: true), isTrue);
        expect(RoleScope.may(manager, c, fallback: false), isFalse);
      }
      final plan = FloorScope.of(manager, surface: FloorSurface.plan);
      expect([
        plan.settle,
        plan.release,
        plan.deleteTable,
        plan.addTable,
        plan.editSeating
      ], everyElement(isTrue));
    });

    test('a half-sent scope narrows only what it mentions', () {
      final p = who(
        role: 'manager',
        roleAll: const ['manager'],
        scope: const {'waiter_only': false, 'settle_bill': false},
      );
      expect(p.said(Capability.settleBill), isFalse);
      expect(p.said(Capability.deleteTable), isNull);
      expect(FloorScope.of(p).settle, isFalse);
      expect(FloorScope.of(p, surface: FloorSurface.plan).deleteTable, isTrue);
    });

    test('a non-boolean is "not said", not false', () {
      // A server mid-migration sending a string, or a null, must not be read as
      // a denial — that is the direction that empties the till.
      final p = who(scope: const {
        'waiter_only': false,
        'settle_bill': 'true',
        'delete_table': null,
        'edit_table': 1,
      });
      expect(p.said(Capability.settleBill), isNull);
      expect(p.said(Capability.deleteTable), isNull);
      expect(p.said(Capability.editTable), isNull);
    });
  });

  // ==========================================================================
  // THE OFFLINE RESTORE
  // ==========================================================================

  group('every capability survives the trip to disk and back', () {
    // The offline restore writes the profile to disk and reads it back as the
    // session. A capability that did not survive would come back ABSENT, the
    // fallback would answer instead, and a gate would silently CHANGE on a cold
    // launch — an owner's Settle button gone, or a cashier's back.
    test('all nine, in both directions', () {
      for (final value in const [true, false]) {
        final p = who(scope: scopeAll(value));
        final restored = Profile.fromJson(p.toJson());
        for (final c in Capability.values) {
          expect(restored.said(c), value, reason: '${c.wireKey} @ $value');
        }
        expect(restored.waiterOnly, isFalse);
      }
    });

    test('the gates computed off the restored copy are the same gates', () {
      final p = who(
        role: 'admin',
        roleAll: const ['admin', 'manager'],
        actions: const ['a1'],
        scope: scopeAll(false),
      );
      final restored = Profile.fromJson(p.toJson());
      expect(FloorScope.of(restored).settle, isFalse);
      expect(FloorScope.of(restored).release, isFalse);
      expect(FloorScope.of(restored, surface: FloorSurface.plan).deleteTable,
          isFalse);
    });

    test('a profile the server never spoke to writes no scope at all', () {
      // Silence must round-trip as silence. A restore that invented `false`
      // would be the very default this whole block refuses.
      final p = who(actions: const ['*']);
      expect(p.toJson().containsKey('scope'), isFalse);
      final restored = Profile.fromJson(p.toJson());
      for (final c in Capability.values) {
        expect(restored.said(c), isNull, reason: c.wireKey);
      }
    });

    test('the disk copy is the wire copy, key for key', () {
      final p = who(scope: scopeAll(true, waiterOnly: true));
      final written = p.toJson()['scope'] as Map<String, dynamic>;
      expect(written['waiter_only'], isTrue);
      for (final c in Capability.values) {
        expect(written[c.wireKey], isTrue, reason: c.wireKey);
      }
    });
  });

  // ==========================================================================
  // THE HOLE: RELEASE IS A WRITE-OFF
  // ==========================================================================

  group('release without payment is gated like the settle it is', () {
    // POST /release-table voids every active order on the table AND closes the
    // open bill at zero. Behind a permission the core waiter role holds, that
    // made the bill impossible to take for its true value and trivial to make
    // vanish for nothing — which is worse than not restricting settle at all,
    // because it LOOKS restricted. It takes the write-off authority now.
    test('a cashier who may not close a bill may not release a table either',
        () {
      final cashier = who(
        role: 'cashier',
        roleAll: const ['cashier'],
        scope: const {
          'waiter_only': false,
          'settle_bill': false,
          'delete_table': true,
          'edit_table': true,
        },
      );
      expect(FloorScope.of(cashier).settle, isFalse);
      expect(FloorScope.of(cashier).release, isFalse,
          reason: 'the front door is bolted; the side door must not be open');
    });

    testWidgets('and nothing on their sheet posts the release', (tester) async {
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            role: 'cashier',
            roleAll: const ['cashier'],
            actions: const ['a1'],
            scope: const {'waiter_only': false, 'settle_bill': false}),
      );
      await _openTable(tester);
      await _pressEverything(tester);

      // THE ASSERTION THAT IS ACTUALLY SCOPING: not that a button is missing,
      // but that driving everything that is left writes nothing.
      expect(api.to('/release-table'), isEmpty);
      expect(api.to('confirm-payment'), isEmpty);
      expect(api.to('admin-approve-payment'), isEmpty);
      expect(api.to('/bills/settle'), isEmpty);
      expect(api.to('/close'), isEmpty);
    });

    testWidgets('an owner releases exactly as before', (tester) async {
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            role: 'admin', actions: const ['*'], scope: scopeAll(true)),
      );
      await _openTable(tester);
      final release = _button(tester, (l) => l.contains('Release'));
      expect(release, isNotNull, reason: 'an owner must not lose the write-off');
      release!.onPressed!();
      await tester.pumpAndSettle();
      expect(api.to('/release-table'), isNotEmpty);
    });
  });

  // ==========================================================================
  // THE CONTROLS THE OTHER FLAGS STAND IN FRONT OF
  // ==========================================================================

  group('comp, roles and the rest obey the server too', () {
    testWidgets(
        'comp_item:false disables the button for a manager who holds the uuid',
        (tester) async {
      // The uuid IS on the profile. If this client still tested for it, the
      // button would be live. The server said no, so it is not.
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            role: 'manager',
            roleAll: const ['manager'],
            actions: const ['a1', _permNonChargeable],
            scope: const {'waiter_only': false, 'comp_item': false}),
      );
      await _openTable(tester);
      final comp = _button(tester, (l) => l.startsWith('Comp'));
      expect(comp, isNotNull,
          reason: 'a manager still SEES it; C1 hides it from waiters only');
      expect(comp!.onPressed, isNull);
      expect(comp.label, contains('manager only'));
      await _pressEverything(tester);
      expect(api.to('non-chargeable'), isEmpty);
    });

    testWidgets(
        'comp_item:true enables it for a manager who does NOT hold the uuid',
        (tester) async {
      await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            role: 'manager',
            roleAll: const ['manager'],
            actions: const ['a1'],
            scope: const {'waiter_only': false, 'comp_item': true}),
      );
      await _openTable(tester);
      final comp = _button(tester, (l) => l.startsWith('Comp'));
      expect(comp, isNotNull);
      expect(comp!.onPressed, isNotNull,
          reason:
              'the server granted it through a custom role; the uuid test would refuse');
      expect(comp.label, isNot(contains('manager only')));
    });

    test('view_roles decides whether the Roles module is in the nav', () {
      final denied = who(
        role: 'manager',
        roleAll: const ['manager'],
        actions: const ['a1'],
        actionNames: const ['View Roles', 'View Tables'],
        scope: const {'waiter_only': false, 'view_roles': false},
      );
      // The keyword gate says yes — "View Roles" contains "role" — and the two
      // reads behind the screen would 403, which renders as an access-control
      // page with no roles on it and no error. That is the C6 symptom.
      expect(denied.can(const ['role', 'permission']), isTrue);
      expect(shell.visibleModuleLabelsFor(denied), isNot(contains('Roles')));

      final allowed = who(
        role: 'manager',
        roleAll: const ['manager'],
        actions: const ['a1'],
        actionNames: const ['View Roles', 'View Tables'],
        scope: const {'waiter_only': false, 'view_roles': true},
      );
      expect(shell.visibleModuleLabelsFor(allowed), contains('Roles'));

      // An older backend: the keyword gate stays the whole rule.
      final older = who(
        role: 'manager',
        roleAll: const ['manager'],
        actions: const ['a1'],
        actionNames: const ['View Roles', 'View Tables'],
      );
      expect(shell.visibleModuleLabelsFor(older), contains('Roles'));

      // And an owner keeps it whatever the block says.
      final owner = who(
          role: 'admin',
          roleAll: const ['admin'],
          actions: const ['*'],
          scope: scopeAll(false));
      expect(shell.visibleModuleLabelsFor(owner), contains('Roles'));
    });

    testWidgets('manage_roles:false takes the role editor away from a uuid holder',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = _FakeApi(_roleRoutes(),
          role: 'manager',
          roleAll: const ['manager'],
          actions: const ['a1', _permCreateRole],
          scope: const {
            'waiter_only': false,
            'view_roles': true,
            'manage_roles': false
          });
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.rolesModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing,
          reason:
              'the uuid is on the profile; the server said no and the server wins');
      expect(api.to('/roles').where((w) => w.method != 'GET'), isEmpty);
    });

    testWidgets('manage_roles:true gives it to somebody without the uuid',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = _FakeApi(_roleRoutes(),
          role: 'manager',
          roleAll: const ['manager'],
          actions: const ['a1'],
          scope: const {
            'waiter_only': false,
            'view_roles': true,
            'manage_roles': true
          });
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.rolesModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  // ==========================================================================
  // C6 — THE NAMED PERMISSION LIST, READ RATHER THAN RE-JOINED
  // ==========================================================================

  group('a core role opens onto names, not uuids', () {
    testWidgets('the server\'s own projection is what renders', (tester) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // /actions comes back EMPTY — which is the production case that produced
      // the symptom, because /actions is gated on a different permission from
      // /core-roles. The local join has nothing to join against; only reading
      // the server's `permissions` can render a name here.
      final routes = _roleRoutes()..['/actions'] = const <dynamic>[];
      final api = _FakeApi(routes, role: 'admin', actions: const ['*']);
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.rolesModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('core-role-waiter')));
      await tester.pumpAndSettle();
      expect(find.text('View Tables'), findsWidgets);
      expect(find.textContaining('act-1'), findsNothing);
    });
  });
}
