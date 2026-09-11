import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/service_clock.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// D1 AND D2 ARE THE SERVER'S MEASUREMENT NOW, AND THIS FILE PROVES IT IS READ.
///
/// service_clock.ts ships `{started_at, ended_at, elapsed_ms, running, as_of}`
/// on every order row, on the open table bill and on a closed bill. It was
/// written so this app and the dashboard could not disagree about the same
/// table — and a field nobody reads settles nothing at all, so these tests fail
/// the moment this client goes back to subtracting two timestamps itself.
///
/// THE FIXTURES ARE DELIBERATELY CONTRADICTORY. Every one of them carries a
/// `created_at` that a local subtraction would read as HOURS and a server
/// `elapsed_ms` that says MINUTES. There is no way to pass them by accident: a
/// client doing its own arithmetic prints the hours, a client obeying the server
/// prints the minutes.
///
/// WHY THAT DISAGREEMENT IS THE REALISTIC CASE AND NOT A CONTRIVANCE. A Windows
/// till in a restaurant is exactly the sort of machine whose clock is wrong —
/// no domain, no NTP, a CMOS battery nobody has replaced — and `now -
/// created_at` on such a machine reports the till's error as the kitchen's
/// delay. That is why the duration arrives measured, in milliseconds, against
/// the server's own clock.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;

  /// Always an owner here: this file is about the CLOCK, and a scoped role
  /// would take the money chips off the screens it reads.
  static const List<String> actions = ['*'];
  static const String role = 'admin';

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
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'scope': const {'waiter_only': false},
          'actions_set': actions,
          'action_names': const ['View Orders', 'View Tables', 'View Bills'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

// ------------------------------------------------------------------ fixtures

/// A server clock reading. [elapsedMs] is what the SERVER measured; the ISO
/// instants are only ever used to rebase, never to subtract against a device.
Map<String, dynamic> clock({
  required int elapsedMs,
  required bool running,
  String startedAt = '2026-09-11T10:00:00.000Z',
  String? endedAt,
  String asOf = '2026-09-11T10:11:00.000Z',
}) =>
    <String, dynamic>{
      'started_at': startedAt,
      'ended_at': endedAt,
      'elapsed_ms': elapsedMs,
      'running': running,
      'as_of': asOf,
    };

/// `created_at` far enough in the past that a local `now - created_at` cannot
/// possibly land on the server's figure. Any test that prints hours has gone
/// back to subtracting.
const String _longAgo = '2020-01-01T00:00:00.000Z';

Map<String, dynamic> _order({Map<String, dynamic>? service, String? billClosedAt}) => {
      'id': 'order-1',
      'table': 'T1',
      'customer': 'Guest',
      'status': 'Preparing',
      'order_type': 'dine_in',
      'total': 1200.0,
      'created_at': _longAgo,
      'bill_closed_at': billClosedAt,
      'taken_by_employee_name': 'Ravi K',
      'items': const [
        {'name': 'Paneer Tikka', 'qty': 2, 'price': 320.0, 'total': 640.0},
      ],
      'service': ?service,
    };

Map<String, dynamic> _ordersRoutes(Map<String, dynamic> order) => {
      '/orders': [order],
      '/get-tables': <dynamic>[],
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/menu': const <dynamic>[],
    };

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

Map<String, dynamic> _bill({
  Map<String, dynamic>? service,
  String firstOrderAt = _longAgo,
  String lastOrderAt = _longAgo,
  String? adminApprovedAt,
}) =>
    {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': 1200.0,
      'subtotal': 1200.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'tax_total': 0.0,
      'grand_total': 1200.0,
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
      'admin_approved_at': adminApprovedAt,
      'service': ?service,
    };

Map<String, dynamic> _floorRoutes(Map<String, dynamic> bill) => {
      '/get-tables': [_table()],
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
      '/menu': const <dynamic>[],
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

Future<void> _mount(WidgetTester tester, _FakeApi api, bool floor) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  final p = rest.auth.profile!;
  await tester.pumpWidget(_host(floor ? m.tablesModule(rest, p) : m.ordersModule(rest, p)));
  await tester.pumpAndSettle();
}

/// The elapsed chip lives on the order's DETAIL SHEET, not on the grid tile —
/// the tile carries the placed time and the money and nothing else. So the
/// sheet is opened before the duration is read.
Future<void> _openOrder(WidgetTester tester) async {
  await tester.tap(find.text('Table T1').first);
  await tester.pumpAndSettle();
}

/// Every string currently on screen, so an assertion can say what the chip reads
/// rather than only whether a widget exists.
List<String> _texts(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        if (t.data != null) t.data!,
    ];

bool _shows(WidgetTester tester, String fragment) =>
    _texts(tester).any((t) => t.contains(fragment));

void main() {
  setUp(() {
    PrintedBills.instance.resetForTest();
    RestaurantTime.zoneNotifier.value = RestaurantTime.defaultZone;
  });
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // THE PARSER
  // ==========================================================================

  group('the reading is taken as sent', () {
    test('a full block parses field for field', () {
      final c = ServiceClock.fromJson(clock(elapsedMs: 660000, running: true))!;
      expect(c.hasStart, isTrue);
      expect(c.elapsedMs, 660000);
      expect(c.running, isTrue);
      expect(c.endedAt, isNull);
      expect(c.asOf, DateTime.utc(2026, 9, 11, 10, 11));
    });

    test('absent is not zero', () {
      // The server's own rule: a row with no placed-at comes back with a null
      // start and a zero elapsed, and a caller must be able to tell "no clock"
      // from "zero seconds". Rendering 0 as "0m" on a table that has been open
      // two hours is worse than rendering nothing.
      final c = ServiceClock.fromJson(<String, dynamic>{
        'started_at': null,
        'ended_at': null,
        'elapsed_ms': 0,
        'running': false,
        'as_of': '2026-09-11T10:11:00.000Z',
      })!;
      expect(c.hasStart, isFalse);
      expect(c.elapsedMs, 0);
    });

    test('a backend that sends no service block at all reads as null', () {
      expect(ServiceClock.fromJson(null), isNull);
      expect(ServiceClock.fromJson('later'), isNull);
      expect(ServiceClock.fromJson(<String, dynamic>{}), isNull);
      // A malformed block is null too: a duration invented out of a payload
      // nobody can read is worse than no duration.
      expect(
          ServiceClock.fromJson(
              <String, dynamic>{'elapsed_ms': 'soon', 'running': true}),
          isNull);
      expect(
          ServiceClock.fromJson(<String, dynamic>{'elapsed_ms': 5, 'running': 'yes'}),
          isNull);
    });

    test('two identical readings compare equal', () {
      // Load-bearing: the ticking widget restarts its monotonic timer when the
      // clock CHANGES, so a poll that returns the same reading must compare
      // equal or every refresh would discard the seconds counted since the last.
      final a = ServiceClock.fromJson(clock(elapsedMs: 660000, running: true));
      final b = ServiceClock.fromJson(clock(elapsedMs: 660000, running: true));
      final later = ServiceClock.fromJson(clock(elapsedMs: 720000, running: true));
      expect(a, b);
      expect(a, isNot(later));
    });
  });

  // ==========================================================================
  // THE TICK
  // ==========================================================================

  group('a running clock ticks off a monotonic delta and nothing else', () {
    final running = ServiceClock.fromJson(clock(elapsedMs: 660000, running: true))!;
    final stopped = ServiceClock.fromJson(clock(
        elapsedMs: 2520000,
        running: false,
        endedAt: '2026-09-11T10:42:00.000Z'))!;

    test('the delta is added to the server\'s figure, not to a wall clock', () {
      expect(running.tickedBy(0), 660000);
      expect(running.tickedBy(5000), 665000);
    });

    test('a stopped clock adds nothing, however long ago it was read', () {
      // A settled bill's duration is a FACT about a finished service. A client
      // that keeps ticking one is reporting a table that has gone home.
      expect(stopped.tickedBy(0), 2520000);
      expect(stopped.tickedBy(3600000), 2520000);
    });

    test('a delta that is not monotonic is ignored, never subtracted', () {
      expect(running.tickedBy(-5000), 660000);
    });
  });

  // ==========================================================================
  // THE REBASE — D1 OFF THE SAME READING
  // ==========================================================================

  group('the latest order is the same reading, restarted', () {
    // /bill-for-table carries ONE clock for the seating. The "latest order"
    // figure shortens it by the gap between the bill's own first_order_at and
    // last_order_at — two of the SERVER's timestamps, differenced against each
    // other. No device clock enters it.
    final table = ServiceClock.fromJson(clock(
      elapsedMs: 2400000, // 40m on the table
      running: true,
      startedAt: '2026-09-11T10:00:00.000Z',
      asOf: '2026-09-11T10:40:00.000Z',
    ))!;

    test('the gap between the two server instants is what is removed', () {
      final latest = table.rebasedTo('2026-09-11T10:28:00.000Z')!;
      expect(latest.elapsedMs, 720000); // 12m since the last ticket
      expect(latest.running, isTrue);
      expect(latest.startedAt, DateTime.utc(2026, 9, 11, 10, 28));
    });

    test('nothing sane to return is null, never a made-up number', () {
      expect(table.rebasedTo(''), isNull);
      expect(table.rebasedTo('not a date'), isNull);
      // Before the seating began, or after the reading was taken: either means
      // the two timestamps did not come off the same response.
      expect(table.rebasedTo('2026-09-11T09:00:00.000Z'), isNull);
      expect(table.rebasedTo('2026-09-11T11:00:00.000Z'), isNull);
    });
  });

  // ==========================================================================
  // ON SCREEN — THE DEVICE CLOCK IS NOT CONSULTED
  // ==========================================================================

  group('D1/D2 render the server\'s number', () {
    testWidgets('an order chip shows what the server measured, not now - created_at',
        (tester) async {
      // created_at is in 2020. A local subtraction prints years; the server says
      // eleven minutes. There is no arithmetic that reaches 11m from that row.
      await _mount(
          tester,
          _FakeApi(_ordersRoutes(
              _order(service: clock(elapsedMs: 11 * 60000, running: true)))),
          false);
      await _openOrder(tester);
      expect(_shows(tester, 'Open 11m 00s'), isTrue,
          reason: 'the chip must read the server\'s elapsed_ms\n${_texts(tester)}');
      // …and the sheet's own line, which is the same reading printed without a
      // tick rather than a second subtraction.
      // The sheet renders its key/value labels upper-cased.
      expect(_shows(tester, 'OPEN FOR'), isTrue, reason: '${_texts(tester)}');
    });

    testWidgets('a settled ticket freezes at the server\'s figure and stops',
        (tester) async {
      await _mount(
        tester,
        _FakeApi(_ordersRoutes(_order(
          billClosedAt: '2026-09-11T10:42:00.000Z',
          service: clock(
              elapsedMs: 42 * 60000,
              running: false,
              endedAt: '2026-09-11T10:42:00.000Z'),
        ))),
        false,
      );
      await _openOrder(tester);
      expect(_shows(tester, 'Took 42m'), isTrue, reason: '${_texts(tester)}');
      // A stopped clock does not move. Five minutes of frames later it still
      // reads the same, because the duration is a fact and not a counter.
      await tester.pump(const Duration(minutes: 5));
      expect(_shows(tester, 'Took 42m 00s'), isTrue);
      expect(_shows(tester, 'ORDER TO SETTLE'), isTrue, reason: '${_texts(tester)}');
    });

    testWidgets('an order with no service block still renders the old way',
        (tester) async {
      // The field is ADDITIVE. A build pointed at a backend that predates it
      // must behave exactly as it did — the local subtraction, on `created_at`.
      await _mount(tester, _FakeApi(_ordersRoutes(_order())), false);
      await _openOrder(tester);
      expect(_shows(tester, 'Open '), isTrue, reason: '${_texts(tester)}');
      expect(_shows(tester, 'Open 11m 00s'), isFalse);
    });

    testWidgets('the table sheet reads the seating clock and the latest ticket',
        (tester) async {
      await _mount(
        tester,
        _FakeApi(_floorRoutes(_bill(
          firstOrderAt: '2026-09-11T10:00:00.000Z',
          lastOrderAt: '2026-09-11T10:28:00.000Z',
          service: clock(
            elapsedMs: 40 * 60000,
            running: true,
            startedAt: '2026-09-11T10:00:00.000Z',
            asOf: '2026-09-11T10:40:00.000Z',
          ),
        ))),
        true,
      );
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      expect(_shows(tester, 'On table 40m'), isTrue, reason: '${_texts(tester)}');
      expect(_shows(tester, 'Latest order 12m'), isTrue);
    });

    testWidgets('a recorded payment does not stop the clock — the CLOSE does',
        (tester) async {
      // THE DISAGREEMENT THIS REPLACES. This sheet used to freeze the span at
      // `admin_approved_at`; the server keeps it running until the bill closes,
      // on the stated grounds that a bill whose payment method has been recorded
      // is not a bill that has been paid. Two screens, one table, two numbers —
      // until the client stopped deciding.
      await _mount(
        tester,
        _FakeApi(_floorRoutes(_bill(
          firstOrderAt: '2026-09-11T10:00:00.000Z',
          lastOrderAt: '2026-09-11T10:00:00.000Z',
          adminApprovedAt: '2026-09-11T10:30:00.000Z',
          service: clock(
            elapsedMs: 40 * 60000,
            running: true,
            startedAt: '2026-09-11T10:00:00.000Z',
            asOf: '2026-09-11T10:40:00.000Z',
          ),
        ))),
        true,
      );
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      expect(_shows(tester, 'On table 40m'), isTrue,
          reason: 'still running: the money is still outstanding\n${_texts(tester)}');
      expect(_shows(tester, 'Took '), isFalse);
    });

    testWidgets('a bill the server could not date grows no chip at all',
        (tester) async {
      await _mount(
        tester,
        _FakeApi(_floorRoutes(_bill(
          firstOrderAt: '',
          lastOrderAt: '',
          service: <String, dynamic>{
            'started_at': null,
            'ended_at': null,
            'elapsed_ms': 0,
            'running': false,
            'as_of': '2026-09-11T10:40:00.000Z',
          },
        ))),
        true,
      );
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      expect(_shows(tester, 'On table'), isFalse, reason: '${_texts(tester)}');
      expect(_shows(tester, '0m 00s'), isFalse);
    });
  });
}
