import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/next_party.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// ROUND-3 ITEM 4'S FOLLOW-UP — A HIDDEN CARD MUST NOT DELETE ITS TABLE.
///
/// THE REPORTED SHAPE. The server now keeps one card per table number by
/// leaving rows OFF GET /get-tables (planNextPartyFloorHidden): a settled "T1"
/// beside a running "T1 #2" draws one card, and the card it drops is the ROOT's.
/// Restaurant_Backend#31 drops a spare free seat and a second running card on
/// top of that.
///
/// Every NON-SERVICE surface in this app is built out of that same payload by
/// dropping the rows that carry a `parent_table` ([isNextPartyRow]) — the
/// one-line way to say "the room's tables, not the floor's cards". It assumes
/// the root is always in the payload. When the hidden row IS the root, the
/// number is in neither half: no T1 on the floor plan, none in its
/// Delete-a-table picker, none in its "N tables · M seats" legend, none in the
/// booking assign picker, and "N of M tables occupied" counts it in neither N
/// nor M. An owner whose table has gone from the layout screen reports it as a
/// table we deleted.
///
/// THE FIX IS A DIFFERENT READ, NOT A RECONSTRUCTION. `?include_hidden=1`
/// answers every live row. The surfaces that list TABLES ask for it; the
/// surfaces that draw CARDS — the Tables screen, and every service-time picker
/// that offers a table to move to, merge with or seat on — do not, because a
/// hidden card offered as a destination is the duplicate coming back.
///
/// Rebuilding T1 out of "T1 #2" was the alternative and is worse: the seat
/// carries T1's NAME and nothing else the editor writes through — T1's own
/// seats, and the name every layout write (PATCH/DELETE /table/:name)
/// addresses — so the editor would be editing and deleting an invented row.
///
/// Each group below shows the same floor twice: what the two reads answer, and
/// what each screen makes of them.

// ------------------------------------------------------------------ the fake

typedef _Route = Object? Function(String path);

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, _Route> routes;

  /// Every GET this screen made, in order.
  final List<String> gets = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Global Vegetarian',
          'restaurantUsername': 'ggv',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'atsu',
          'emp_Fname': 'Atsu',
          'role': 'admin',
          'role_all': const ['admin'],
          'actions_set': const ['*'],
          'action_names': const ['View Tables', 'View Orders', 'View Bills', 'View Menu'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') return <String, dynamic>{'success': true};
    gets.add(path);
    // Longest matching prefix wins, so "/get-tables?include_hidden=1" is
    // answered by its own route and not by the bare "/get-tables" one.
    final keys = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (keys.isEmpty) throw ApiException('No fake route for $path', 404);
    return routes[keys.first]!(path);
  }

  /// The one /get-tables read this screen made.
  String get tablesRead => gets.singleWhere((g) => g.startsWith('/get-tables'));
}

// ---------------------------------------------------------------- fixtures --

Map<String, dynamic> _table(String name, {bool occupied = false, int capacity = 4}) => {
      'table_name': name,
      'parent_table': null,
      'party_no': null,
      'display_name': name,
      'capacity': capacity,
      'max_capacity': capacity,
      'section': 'Main',
      'occupied': occupied,
      'has_order': occupied,
      'reserved': false,
      'booked': false,
      'covers': occupied ? 2 : 0,
      'table_total': 0.0,
      'table_apc': 0.0,
      'apc_status': 'neutral',
      'print_count': 0,
      'bill_printed_at': null,
      'printed_at': null,
    };

Map<String, dynamic> _seat(String root, {bool occupied = true}) => {
      ..._table('$root #2', occupied: occupied),
      'parent_table': root,
      'party_no': 2,
      'display_name': root,
    };

/// THE CLIENT'S PHOTO. T1 was settled while its next party was still eating, so
/// the FLOOR draws "T1 #2" alone — the card rule hides the free root — and the
/// ROOM still holds both rows. T2 is the ordinary neighbour that must not move.
final List<Map<String, dynamic>> _roomRows = [_table('T1'), _seat('T1'), _table('T2')];
final List<Map<String, dynamic>> _floorRows = [_seat('T1'), _table('T2')];

/// The floor routes, answering the two reads differently — exactly as the
/// server does with and without the flag.
Map<String, _Route> _floor() => {
      '/get-tables': (_) => _floorRows,
      '/get-tables?include_hidden=1': (_) => _roomRows,
      '/table-assignments': (_) => <dynamic>[],
      '/get-bookings': (_) => <dynamic>[],
      '/table-sections': (_) => {
            'sections': [
              {'section': 'Main'},
            ],
          },
      '/bills/open': (_) => <String, dynamic>{'total': 0, 'outstanding_total': 0},
      '/restaurant/settings': (_) => {'kitchen_sections': <dynamic>[]},
    };

// ------------------------------------------------------------------- hosts --

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Global Vegetarian', 'atsu', 'pw');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Overview', 'Tables', 'Bookings'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<RestClient> _mount(WidgetTester tester, _FakeApi api,
    Widget Function(RestClient rest, Profile p) module) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return rest;
}

void main() {
  // ==========================================================================
  // WHAT THE TWO PAYLOADS ARE — the bug, stated before anything is mounted.
  // ==========================================================================

  test('THE BUG: dropping the seats from the FLOOR payload loses T1 entirely', () {
    expect([for (final r in _floorRows) if (!isNextPartyRow(r)) r['table_name']], ['T2']);
    // …and the count goes with it: T1 is neither occupied nor a table.
    expect(countRoomsInUse(_floorRows, (t) => t['occupied'] == true), (inUse: 0, rooms: 1));
    // The ROOM payload has both halves right.
    expect([for (final r in _roomRows) if (!isNextPartyRow(r)) r['table_name']], ['T1', 'T2']);
    expect(countRoomsInUse(_roomRows, (t) => t['occupied'] == true), (inUse: 1, rooms: 2));
  });

  // ==========================================================================
  // THE LAYOUT EDITOR
  // ==========================================================================

  group('the floor plan is the room, hidden root and all', () {
    testWidgets('T1 is still a table to lay out, and still not its seat', (tester) async {
      final api = _FakeApi(_floor());
      await _mount(tester, api, m.floorPlanModule);
      expect(api.tablesRead, '/get-tables?include_hidden=1');
      expect(find.byKey(const ValueKey('plan-table-T1')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-table-T2')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-table-T1 #2')), findsNothing);
      // The legend counts the room: two tables, eight seats — not one and four.
      expect(find.text('2 tables'), findsWidgets);
      expect(find.text('8 seats'), findsWidgets);
      expect(find.text('1 table'), findsNothing);
    });

    testWidgets('the Delete-a-table picker offers T1 again', (tester) async {
      final api = _FakeApi(_floor());
      await _mount(tester, api, m.floorPlanModule);
      await tester.tap(find.byKey(const ValueKey('floor-delete-table')));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('T1')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('T2')), findsOneWidget);
      // The seat is still never offered: the server refuses to delete one.
      expect(find.descendant(of: dialog, matching: find.textContaining('T1 #2')), findsNothing);
    });
  });

  // ==========================================================================
  // THE SERVICE FLOOR — unchanged, and that is the point
  // ==========================================================================

  group('the Tables screen still draws one card per table number', () {
    testWidgets('it asks for the plain floor and gets "T1 #2" alone', (tester) async {
      final api = _FakeApi(_floor());
      await _mount(tester, api, m.tablesModule);
      expect(api.tablesRead, '/get-tables');
      // One card for the number, drawn under the root's name, as item 4 asks.
      expect(find.byKey(const ValueKey('table-title-T1 #2')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-title-T1')), findsNothing);
      expect(find.byKey(const ValueKey('table-title-T2')), findsOneWidget);
    });
  });

  // ==========================================================================
  // THE OVERVIEW'S COUNT
  // ==========================================================================

  group('"N of M tables occupied" counts the room', () {
    testWidgets('T1 is one occupied table of two, through its next party', (tester) async {
      final api = _FakeApi(_floor());
      await _mount(tester, api, m.overviewModule);
      expect(api.tablesRead, '/get-tables?include_hidden=1');
      final gauge = tester.widget<DonutGauge>(find.byType(DonutGauge).first);
      expect(gauge.tooltip, '1 of 2 tables occupied (50%) · 2 cover(s) seated');
    });
  });

  // ==========================================================================
  // THE BOOKING PICKER
  // ==========================================================================

  group('the booking assign picker offers every real table', () {
    testWidgets('T1 is back in "Assign to table", and its seat is not', (tester) async {
      final api = _FakeApi({
        ..._floor(),
        '/get-bookings?window=upcoming': (_) => [
              <String, dynamic>{
                'booking_id': 'bk-1',
                'customer_name': 'Anaya',
                'status': 'Confirmed',
                'booking_date_time': '2026-09-27T18:30:00Z',
                // No party size: the seating suggestion is skipped and the
                // plain picker — the one this fix is about — is what opens.
                'number_of_people': 0,
              },
            ],
      });
      await _mount(tester, api, m.bookingsModule);
      await tester.tap(find.text('Anaya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assign / combine tables'));
      await tester.pumpAndSettle();

      expect(api.tablesRead, '/get-tables?include_hidden=1');
      expect(find.text('Assign to table'), findsOneWidget);
      final dialog = find.byType(SimpleDialog);
      expect(find.descendant(of: dialog, matching: find.textContaining('T1 #2')), findsNothing);
      expect(find.descendant(of: dialog, matching: find.textContaining('T1')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('T2')), findsOneWidget);
    });
  });
}
