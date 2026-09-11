import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
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

/// THE SERVER'S REFUSAL HAS TO REACH THE PERSON HOLDING THE TABLET.
///
/// WHAT WAS WRONG. The backend answers a refusal with a body that says what to
/// do about it — "This table has ₹6,351 unpaid — a manager must settle or write
/// it off", "A reprint has to be made by a manager, admin — ask one of them",
/// "Settling a bill requires the 'Close Bill' permission". This client read the
/// `error` key, which on every one of those bodies is the word "Forbidden", and
/// threw the sentence away. A waiter got a one-word snackbar and walked off to
/// fetch a manager to find out what it meant — which is the same outcome as no
/// message at all, only slower.
///
/// THE POINT IS THE SENTENCE, NOT THE STATUS. A status code is for the client;
/// the sentence is for the person. So [ApiException.fromBody] prefers `details`,
/// falls back to `error` ONLY when that is itself a sentence, and writes a real
/// one when the body carries nothing at all. Every module in this app renders a
/// caught failure as `'$e'`, so fixing the seam fixes release, reprint, settle,
/// comp, void and everything after them at once — which is why this file tests
/// the SEAM with unit cases and then proves the chain end-to-end on two real
/// surfaces rather than trying to drive all of them.
///
/// WHAT MUST NOT LEAK. `requiredPermission` is an Action UUID and
/// `requiredRoles` is a machine list. Neither is language and neither belongs in
/// front of a guest at a table. They stay readable on the exception; only the
/// sentence is rendered.
///
/// AND AN ADMIN LOSES NOTHING: the last group drives the same controls with a
/// server that says yes, and asserts the writes still leave.

// --------------------------------------------------------------- the bodies
//
// Copied from the backend's own 403s (routes/tables.ts, routes/bills.ts,
// routes/_shared.ts) rather than invented, so a test that passes here is a test
// that would pass against the wire.

const String _permCloseBill = 'a953d044-0000-0000-0000-000000000000';

/// POST /release-table, refused because the release would destroy value and the
/// caller does not hold Close Bill.
const Map<String, dynamic> _releaseRefusal = <String, dynamic>{
  'error': 'Forbidden',
  'details':
      'This table has ₹6,351 unpaid — a manager must settle it or write it off.',
  'requiredPermission': _permCloseBill,
  'write_off_value': 6351.0,
};

/// POST /print/bill, refused because a waiter-only identity is asking for a
/// second copy.
const Map<String, dynamic> _reprintRefusal = <String, dynamic>{
  'error': 'Forbidden',
  'details':
      "This table's bill has already been printed. A reprint has to be made by "
          'a manager, admin — ask one of them.',
  'reprint_needs_senior': true,
  'print_count': 1,
  'allowed_roles': ['manager', 'admin'],
};

/// enforceSettleAuthority's refusal — the one that names the permission in
/// WORDS so an owner can find the checkbox.
const Map<String, dynamic> _settleRefusal = <String, dynamic>{
  'error': 'Forbidden',
  'details':
      "Settling a bill requires the 'Close Bill' permission. Ask an admin to "
          'grant it to your role.',
  'requiredPermission': _permCloseBill,
};

// ------------------------------------------------------------------ the fake

/// A refusal the fake server will answer a write with.
typedef _Refusal = ({int status, Map<String, dynamic> body});

class _FakeApi extends ApiClient {
  _FakeApi(
    this.routes, {
    this.actions = const ['*'],
    this.role = 'admin',
    this.roleAll,
    this.scope,
    this.refusals = const <String, _Refusal>{},
  });

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;
  final List<String>? roleAll;
  final Map<String, dynamic>? scope;

  /// path fragment -> what the server answers that write with. The exception is
  /// built with the PRODUCTION factory, so this exercises the real body→words
  /// rule rather than a test's idea of it. (ApiClient reaches for the top-level
  /// `http` functions, so there is no client to inject a canned response into;
  /// [ApiException.fromBody] is the seam, and it is the thing under test.)
  final Map<String, _Refusal> refusals;

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
          'action_names': const [
            'View Orders', 'Create Order', 'View Tables', 'Occupy Table',
            'View Menu', 'View Bills',
          ],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      for (final entry in refusals.entries) {
        if (path.contains(entry.key)) {
          throw ApiException.fromBody(entry.value.body, entry.value.status);
        }
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

// ------------------------------------------------------------------ fixtures

Map<String, dynamic> _table() => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': true,
      'reserved': false,
      'num_covers': 3,
      'covers': 3,
      'table_total': 6351.0,
      'table_apc': 2117.0,
      'apc_status': 'red',
      'waiter_name': 'Ravi K',
    };

/// The bill as an UNPRINTED one. That is the interesting shape: the client
/// draws the control because its copy of the world says the print has not
/// happened, and the server refuses anyway. A hidden control is the courtesy;
/// this is what happens when the courtesy is out of date.
Map<String, dynamic> _bill() => {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': 6000.0,
      'subtotal': 6000.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'tax_total': 351.0,
      'grand_total': 6351.0,
      'nc_total': 0.0,
      'covers': 3,
      'apc': 2000.0,
      'target_apc': 2000.0,
      'apc_status': 'green',
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
      ],
      'print_count': 0,
      'bill_printed_at': null,
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

// --------------------------------------------------------------------- hosts

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
  tester.view.physicalSize = const Size(1400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
}

ForkButton? _button(WidgetTester tester, bool Function(String) match) {
  for (final b in tester.widgetList<ForkButton>(find.byType(ForkButton))) {
    if (match(b.label)) return b;
  }
  return null;
}

/// Take the AFFIRMATIVE option out of whatever dialog is on screen. The last
/// action in a dialog's row is the one that does the thing ("Print").
Future<void> _confirmDialog(WidgetTester tester) async {
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

/// Every string currently painted anywhere on screen. Used to prove a UUID is
/// NOT among them — `find.text` only matches a whole Text widget, and a leak
/// would more likely be a UUID embedded in a longer line.
List<String> _allText(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        t.data ?? t.textSpan?.toPlainText() ?? '',
    ];

void main() {
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // THE SEAM: a body becomes words
  // ==========================================================================

  group('ApiException.fromBody renders the sentence the server wrote', () {
    test('a release refusal names the money it would have destroyed', () {
      final e = ApiException.fromBody(_releaseRefusal, 403);
      expect(e.message, _releaseRefusal['details']);
      expect(e.message, contains('₹6,351'));
      expect('$e', isNot(contains('Forbidden')));
      expect(e.status, 403);
      // The machine-readable halves survive for anything that wants them; they
      // are simply not what a person is shown.
      expect(e.serverError, 'Forbidden');
      expect(e.details, _releaseRefusal['details']);
    });

    test('a reprint refusal names who to ask', () {
      final e = ApiException.fromBody(_reprintRefusal, 403);
      expect(e.message, contains('A reprint has to be made by'));
      expect(e.message, isNot(contains('Forbidden')));
    });

    test('a settle refusal names the permission IN WORDS', () {
      final e = ApiException.fromBody(_settleRefusal, 403);
      expect(e.message, contains("'Close Bill'"));
      // …and never the uuid behind it.
      expect(e.message, isNot(contains(_permCloseBill)));
    });

    test('a 403 with no details at all still says something useful', () {
      // TODAY'S WORDING WAS "Forbidden", which is the status wearing a word. A
      // bare title is not a sentence, so it does not get to be the message.
      final e = ApiException.fromBody(const {'error': 'Forbidden'}, 403);
      expect(e.message, isNot('Forbidden'));
      expect(e.message, contains('permission'));
      expect(e.serverError, 'Forbidden',
          reason: 'the token is kept, it is just not what is shown');
    });

    test('a 403 with NO BODY at all — a proxy, a gateway page', () {
      final e = ApiException.fromBody(null, 403);
      expect(e.message, contains('permission'));
      expect(e.message, isNot(contains('403')));
    });

    test('an `error` that IS a sentence still comes through untouched', () {
      // The backend has plenty of these and none of them are broken by the
      // change: "Action not permitted", "Only an admin can change this", the
      // plan-limit messages, the 400s that name the offending value.
      for (final msg in const [
        'Action not permitted',
        'Only an admin can change the restaurant timezone.',
        'Your plan allows up to 2 outlet(s). Upgrade to add more.',
      ]) {
        expect(ApiException.fromBody({'error': msg}, 403).message, msg);
      }
      expect(
        ApiException.fromBody(const {'error': 'Unknown timezone Mars/Olympus'}, 400)
            .message,
        'Unknown timezone Mars/Olympus',
      );
    });

    test('details wins over error, and both over the caller fallback', () {
      expect(
        ApiException.fromBody(
                const {'error': 'Action not permitted', 'details': 'Do X instead.'},
                403)
            .message,
        'Do X instead.',
      );
      expect(
        ApiException.fromBody(const {'error': 'Unauthorized'}, 401,
                fallback: 'Sign-in failed.')
            .message,
        'Sign-in failed.',
      );
    });

    test("a screen's bespoke line yields to a server that said more", () {
      // A handful of screens replace the generic refusal with wording of their
      // own, because "You do not have permission for this action" told nobody
      // anything on a settings toggle. Those lines stay — they just stop
      // overwriting a server that had something specific to say.
      expect(
        ApiException.fromBody(const {'error': 'Forbidden'}, 403)
            .sentenceOr('Only an admin can change kitchen sections.'),
        'Only an admin can change kitchen sections.',
      );
      expect(
        ApiException.fromBody(_releaseRefusal, 403)
            .sentenceOr('Only an admin can change kitchen sections.'),
        _releaseRefusal['details'],
      );
    });

    test('a non-2xx with a body this app cannot read degrades quietly', () {
      expect(ApiException.fromBody('<html>502</html>', 502).message,
          'Request failed (502).');
      expect(ApiException.fromBody(const {'details': '   '}, 500).message,
          'Request failed (500).');
    });
  });

  // ==========================================================================
  // THE CHAIN: what is actually on the screen afterwards
  // ==========================================================================

  group('the sentence reaches the floor', () {
    testWidgets('a refused release says what the table owes and who fixes it',
        (tester) async {
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            actions: const ['*'],
            refusals: {
              '/release-table': (status: 403, body: _releaseRefusal),
            }),
      );
      await _openTable(tester);
      final release = _button(tester, (l) => l.contains('Release'));
      expect(release?.onPressed, isNotNull);
      release!.onPressed!();
      await tester.pumpAndSettle();

      // THE WRITE WAS ATTEMPTED AND REFUSED — the server is the control, and
      // this is the courtesy that tells a human what the control said.
      expect(api.to('/release-table'), isNotEmpty);
      expect(find.text(_releaseRefusal['details'] as String), findsOneWidget,
          reason: 'the waiter is told the table owes ₹6,351 and who can clear '
              'it, instead of the word "Forbidden"');
      expect(find.text('Forbidden'), findsNothing);
    });

    testWidgets('and never the Action uuid behind it', (tester) async {
      await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            actions: const ['*'],
            refusals: {
              '/release-table': (status: 403, body: _releaseRefusal),
            }),
      );
      await _openTable(tester);
      _button(tester, (l) => l.contains('Release'))!.onPressed!();
      await tester.pumpAndSettle();
      expect(_allText(tester).where((t) => t.contains(_permCloseBill)), isEmpty,
          reason: 'a uuid is not language; the server already named the '
              'permission in words where a human needed it');
    });

    testWidgets('a 403 carrying no sentence still reads like an instruction',
        (tester) async {
      await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            actions: const ['*'],
            refusals: {
              '/release-table': (status: 403, body: const {'error': 'Forbidden'}),
            }),
      );
      await _openTable(tester);
      _button(tester, (l) => l.contains('Release'))!.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Forbidden'), findsNothing);
      expect(
          _allText(tester).any((t) => t.contains('do not have permission')), isTrue);
    });

    testWidgets('a refused reprint tells the WAITER who to ask', (tester) async {
      // The client's copy of the world says this bill is unprinted (print_count
      // 0), so it draws the button. The server knows better and refuses. What
      // the waiter must not get is a blank stare — they will go and press it on
      // the next tablet they find.
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            role: 'waiter',
            roleAll: const ['waiter'],
            actions: const ['a1'],
            scope: const {'waiter_only': true},
            refusals: {
              '/print/bill': (status: 403, body: _reprintRefusal),
            }),
      );
      await _openTable(tester);
      final print = _button(tester, (l) => l == 'Print bill');
      expect(print?.onPressed, isNotNull, reason: 'the courtesy is out of date');
      print!.onPressed!();
      await tester.pumpAndSettle();
      await _confirmDialog(tester);

      expect(api.to('/print/bill'), isNotEmpty);
      expect(find.text(_reprintRefusal['details'] as String), findsOneWidget);
      expect(find.text('Forbidden'), findsNothing);
    });
  });

  // ==========================================================================
  // AND NOTHING THAT USED TO WORK STOPPED WORKING
  // ==========================================================================

  group('an admin loses nothing', () {
    testWidgets('a release the server allows still releases, silently',
        (tester) async {
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(), actions: const ['*']),
      );
      await _openTable(tester);
      _button(tester, (l) => l.contains('Release'))!.onPressed!();
      await tester.pumpAndSettle();
      expect(api.to('/release-table'), isNotEmpty);
      expect(find.text(_releaseRefusal['details'] as String), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a 400 that is not about permission reads exactly as it did',
        (tester) async {
      final api = await _mountFloor(
        tester,
        _FakeApi(_floorRoutes(),
            actions: const ['*'],
            refusals: {
              '/release-table': (
                status: 400,
                body: const {'error': 'Table not found'},
              ),
            }),
      );
      await _openTable(tester);
      _button(tester, (l) => l.contains('Release'))!.onPressed!();
      await tester.pumpAndSettle();
      expect(api.to('/release-table'), isNotEmpty);
      expect(find.text('Table not found'), findsOneWidget);
    });
  });
}
