import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/stat_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Attendance, Outlets and the Employees LEAVE register: no figure is a dead end.
///
/// The failure modes pinned here are the ones that make an affordance worse than
/// none at all:
///   * a tap that does nothing — every element asserted names the sheet it opens,
///     and the three deliberately inert ones (BRANCHES, and the two attendance
///     tiles at zero) are asserted to carry no gesture AT ALL, not merely to open
///     an empty list;
///   * a sheet that only repeats its card — so each assertion lands on something
///     the card could not hold (punctuality behind a shift total, share-of-group
///     behind a branch's revenue, who signed a leave off and when);
///   * a decision fired by accident — reading a shift, a branch or a leave must
///     never write, and approve/reject must never be what a card tap does;
///   * a time read off the wrong clock — every stamp is the RESTAURANT's, which
///     is only provable by moving the zone and watching the figure move with it.
///
/// And one house rule gets its own tests: ONLY APPROVED LEAVE EXCUSES AN ABSENCE.
/// A leave still awaiting a decision over days that have already passed is
/// counting against the person right now, and the register has to say so.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.profileJson});

  final Map<String, dynamic> routes;
  final Map<String, dynamic>? profileJson;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(profileJson ??
            <String, dynamic>{
              'employeeId': 'e1',
              'restaurantName': 'CSR Organics',
              'restaurantUsername': 'csrorganics',
              'role': 'admin',
              'actions_set': ['*'],
              'action_names': <String>[],
            }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a query-carrying family
    // while an exact id route still wins over its own list.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  List<String> get writes => calls.where((c) => !c.startsWith('GET ')).toList();
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

const List<String> _allLabels = [
  'Overview', 'Orders', 'Menu', 'Tables', 'Bookings',
  'Feedback', 'Employees', 'Attendance', 'Outlets', 'Analytics',
];

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  Map<String, dynamic>? profileJson,
}) async {
  // Blank pump first: these screens hold their own State, so re-pumping the
  // same widget type would keep the previously loaded payload.
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes, profileJson: profileJson);
  final rest = await _signIn(api);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (label, {Map<String, dynamic>? target}) {},
      visibleLabels: _allLabels,
      clearFocus: () {},
      child: Scaffold(backgroundColor: Colors.transparent, body: module(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void _size(WidgetTester tester, double width, {double height = 1800, double scale = 1.0}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// These pages are long, so bring the target into the tree before tapping it.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final page = find.byType(Scrollable).first;
  if (finder.evaluate().isEmpty) {
    await tester.drag(page, const Offset(0, 8000), warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250, scrollable: page, maxScrolls: 250);
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('Close').last);
  await tester.pumpAndSettle();
}

/// Scoped to the open drill-down dialog. Without this an assertion about the
/// sheet can be satisfied by the page still sitting behind it — which is exactly
/// the "sheet only repeats the card" failure these tests exist to catch.
Finder _inSheet(Finder inner) => find.descendant(of: find.byType(Dialog), matching: inner);

Finder _sheetText(String s) => _inSheet(find.text(s));

Finder _sheetContaining(String s) => _inSheet(find.textContaining(s));

/// Scroll the whole page top to bottom so every row is actually laid out — a
/// ListView only builds what it can see, and an overflow in row 40 is invisible
/// to a test that never scrolls to row 40.
Future<void> _scrollThrough(WidgetTester tester) async {
  final page = find.byType(Scrollable).first;
  for (var i = 0; i < 16; i++) {
    await tester.drag(page, const Offset(0, -600), warnIfMissed: false);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// The card behind a caption, so an assertion about one tile cannot be satisfied
/// by a different tile on the page.
Finder _tileCard(String caption) =>
    find.ancestor(of: find.text(caption), matching: find.byType(ForkCard)).last;

/// A top-of-page stat tile, matched on its StatCard rather than on the nearest
/// card. MicroStat uppercases its own label too, so on Outlets the plain text
/// "REVENUE (30D)" appears on every branch card as well — an ancestor search
/// from the text lands on whichever card came last, not on the tile.
Finder _statCard(String caption) =>
    find.ancestor(of: find.text(caption), matching: find.byType(StatCard)).first;

/// A branch's own card, matched on something only that card carries.
Finder _cardWith(String unique) =>
    find.ancestor(of: find.text(unique), matching: find.byType(ForkCard)).first;

/// A restaurant calendar day [d] days from today, as the "YYYY-MM-DD" key the
/// leave rows carry. Relative, so these fixtures do not rot overnight.
String _day(int d) => DateTime.parse('${RestaurantTime.todayIso()}T00:00:00Z')
    .add(Duration(days: d))
    .toIso8601String()
    .substring(0, 10);

// ---------------------------------------------------------------- attendance --

/// One open pending shift, one team member on shift, and the punctuality read
/// the sheets fill in lazily.
Map<String, dynamic> _attendanceRoutes({
  List<Map<String, dynamic>>? pending,
  List<Map<String, dynamic>>? rows,
  bool withPunctuality = true,
}) =>
    {
      '/attendance/me': {
        'clocked_in': true,
        'since': '2026-08-03T04:30:00Z',
        'today_minutes': 145,
        'pending_approval': true,
      },
      '/attendance': {
        'from': '2026-07-04',
        'to': '2026-08-03',
        'rows': rows ??
            [
              {'emp_id': 'e2', 'name': 'Rhea Kapoor', 'minutes': 615, 'shifts': 5, 'open': true},
              {'emp_id': 'e4', 'name': 'Devika Raghunathan-Balasubramanian', 'minutes': 90, 'shifts': 1, 'open': false},
            ],
        'pending': pending ??
            [
              {
                'id': 'a1',
                'emp_id': 'e3',
                'name': 'Sunil Rao',
                'clock_in': '2026-08-03T04:30:00Z',
                'clock_out': null,
              },
            ],
      },
      if (withPunctuality)
        '/analytics/advanced': {
          'staff_attendance': [
            {
              'emp_id': 'e2',
              'name': 'Rhea Kapoor',
              'typical_start': '17:48',
              'late_shifts': 3,
              'late_pct': 20.0,
              'days_present': 15,
              'absent_days': 2,
              'leave_days': 4,
            },
            {'emp_id': 'e3', 'name': 'Sunil Rao', 'typical_start': '09:30', 'late_shifts': 0, 'late_pct': 0.0},
          ],
        },
    };

void main() {
  // Every timestamp assertion below is about the RESTAURANT's clock, so each
  // test states the zone it expects rather than inheriting whatever the last one
  // left behind.
  setUp(() => RestaurantTime.adopt(RestaurantTime.defaultZone));
  tearDown(() => RestaurantTime.adopt(RestaurantTime.defaultZone));

  group('Attendance', () {
    testWidgets('a shift row opens its detail with the times in RESTAURANT time', (tester) async {
      _size(tester, 1400);
      RestaurantTime.adopt('Asia/Kolkata');
      final api = await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      await _tap(tester, find.text('Sunil Rao'));
      expect(_sheetText('ATTENDANCE · PENDING APPROVAL'), findsOneWidget);
      // 04:30 UTC is 10:00 in Asia/Kolkata, and the stamp names the offset it
      // used so the reading cannot be mistaken for the device's.
      expect(_sheetContaining('3 Aug 2026, 10:00:00 UTC+05:30'), findsOneWidget);
      expect(_sheetText('Still on shift'), findsOneWidget);
      // Reading a shift must not decide it.
      expect(api.writes, isEmpty);
      await _closeSheet(tester);
    });

    testWidgets('the same shift re-reads in a different zone — it is not the device clock', (tester) async {
      _size(tester, 1400);
      RestaurantTime.adopt('UTC');
      await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      await _tap(tester, find.text('Sunil Rao'));
      // Same instant, restaurant now in UTC: the hour moves with the zone.
      expect(_sheetContaining('3 Aug 2026, 04:30:00 UTC+00:00'), findsOneWidget);
      expect(_sheetContaining('10:00:00'), findsNothing);
      await _closeSheet(tester);
    });

    testWidgets('the shift detail carries the baseline a start time can be judged against', (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      await _tap(tester, find.text('Sunil Rao'));
      // Lazily fetched: /analytics/advanced is not read until a sheet needs it.
      expect(_sheetContaining('usually starts around 09:30'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('punctuality is not paid for on page load, only when a sheet asks', (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      expect(api.calls.where((c) => c.contains('/analytics/advanced')), isEmpty);
      await _tap(tester, find.text('Rhea Kapoor'));
      expect(api.calls.where((c) => c.contains('/analytics/advanced')), hasLength(1));
      await _closeSheet(tester);

      // Cached: a second sheet reuses the one read rather than paying again.
      await _tap(tester, find.text('Sunil Rao'));
      expect(api.calls.where((c) => c.contains('/analytics/advanced')), hasLength(1));
      await _closeSheet(tester);
    });

    testWidgets('the team sheet adds what the row cannot hold — late starts and unexplained days',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      await _tap(tester, find.text('Rhea Kapoor'));
      expect(_sheetText('ATTENDANCE · TEAM HOURS'), findsOneWidget);
      // The row's own figures...
      expect(_sheetText('10h 15m'), findsWidgets);
      // ...and the ones no row on this page carries.
      expect(_sheetText('17:48'), findsOneWidget);
      expect(_sheetContaining('20% of shifts'), findsOneWidget);
      expect(_sheetText('4'), findsWidgets); // excused by leave
      expect(_sheetContaining('Approved leave is already taken out'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('a punctuality read that fails says so instead of reading as "never late"', (tester) async {
      _size(tester, 1400);
      await _mount(
        tester,
        (r, p) => m.attendanceModule(r, p),
        _attendanceRoutes(withPunctuality: false),
      );

      await _tap(tester, find.text('Rhea Kapoor'));
      expect(_sheetContaining("Punctuality couldn't be loaded"), findsOneWidget);
      // The failure is reported, not thrown past the builder.
      expect(tester.takeException(), isNull);
      await _closeSheet(tester);
    });

    testWidgets('the summary tiles drill into the PEOPLE behind them, and those rows lead on',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      // Pending approvals -> the set, then one person's own record.
      await _tap(tester, _statCard('PENDING APPROVALS'));
      expect(_sheetText('1 clock-in awaiting review'), findsOneWidget);
      await _tap(tester, _sheetText('Sunil Rao'));
      expect(_sheetText('ATTENDANCE · PENDING APPROVAL'), findsOneWidget);
      // The list was REPLACED, not stacked: one Close returns to the page.
      await _closeSheet(tester);
      expect(find.byType(Dialog), findsNothing);

      // On shift now -> only the open rows, and each opens its roll-up.
      await _tap(tester, _statCard('ON SHIFT NOW'));
      expect(_sheetText('1 on shift now'), findsOneWidget);
      expect(_sheetText('Rhea Kapoor'), findsOneWidget);
      expect(_sheetText('Devika Raghunathan-Balasubramanian'), findsNothing);
      await _tap(tester, _sheetText('Rhea Kapoor'));
      expect(_sheetText('ATTENDANCE · TEAM HOURS'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('HOURS TODAY opens my own day, with the full stamp and the clock control',
        (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      await _tap(tester, _statCard('HOURS TODAY'));
      expect(_sheetText('ATTENDANCE · MY DAY'), findsOneWidget);
      expect(_sheetText('2h 25m'), findsOneWidget);
      // What the strip below the tile cannot hold: the full stamp and the zone.
      expect(_sheetContaining('3 Aug 2026, 10:00:00 UTC+05:30'), findsOneWidget);
      expect(_sheetContaining('Asia/Kolkata'), findsOneWidget);
      expect(_sheetContaining('awaiting review'), findsOneWidget);
      // The control is offered but opening the sheet did not press it.
      expect(_sheetText('Clock out'), findsOneWidget);
      expect(api.writes, isEmpty);
      await _closeSheet(tester);
    });

    testWidgets('making the clock strip tappable did not swallow the clock button', (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.attendanceModule(r, p), _attendanceRoutes());

      // The card opens the sheet, but a control inside it still wins its own
      // gesture — otherwise this change would have broken clocking out.
      await _tap(tester, find.text('Clock out'));
      expect(find.byType(Dialog), findsNothing);
      expect(api.writes, contains('POST /attendance/clock-out'));
    });

    testWidgets('tiles with nothing behind them are inert — no tap, not an empty list', (tester) async {
      _size(tester, 1400);
      await _mount(
        tester,
        (r, p) => m.attendanceModule(r, p),
        _attendanceRoutes(pending: const [], rows: const []),
      );

      // A dead tap in a dense grid is worse than an obviously static readout, so
      // these carry no gesture at all rather than opening onto nothing.
      expect(tester.widget<StatCard>(find.ancestor(
              of: find.text('PENDING APPROVALS'), matching: find.byType(StatCard)))
          .onTap, isNull);
      expect(tester.widget<StatCard>(
              find.ancestor(of: find.text('ON SHIFT NOW'), matching: find.byType(StatCard)))
          .onTap, isNull);
      // My own day always has something to say, so it stays live.
      expect(tester.widget<StatCard>(
              find.ancestor(of: find.text('HOURS TODAY'), matching: find.byType(StatCard)))
          .onTap, isNotNull);
    });

    testWidgets('a shift left open past the payroll cap is flagged, not silently approved', (tester) async {
      _size(tester, 1400);
      await _mount(
        tester,
        (r, p) => m.attendanceModule(r, p),
        _attendanceRoutes(pending: [
          {
            'id': 'a9',
            'emp_id': 'e3',
            'name': 'Sunil Rao',
            // Long enough ago that the open shift is well past 16 hours.
            'clock_in': '2020-01-01T00:00:00Z',
            'clock_out': null,
          },
        ]),
      );

      await _tap(tester, find.text('Sunil Rao'));
      expect(_sheetContaining('Still open after more than 16 hours'), findsOneWidget);
      // Flagged, never blocked — the decision is still the manager's.
      expect(_sheetText('Approve'), findsWidgets);
      await _closeSheet(tester);
    });
  });

  // ------------------------------------------------------------------ outlets --

  Map<String, dynamic> outletRoutes({List<Map<String, dynamic>>? rollup}) => {
        '/outlets': {
          'outlets': [
            {'id': 'o1', 'outlet_name': 'Harbour Main', 'is_default': true, 'is_active': true,
             'outlet_add': '1 Dock Rd', 'outlet_phone': '+91 98765 43210',
             'outlet_hours': 'Mon-Sun 11:00-23:30, kitchen closes 22:45'},
            {'id': 'o2', 'outlet_name': 'Hilltop', 'is_default': false, 'is_active': true},
            {'id': 'o3', 'outlet_name': 'Airport Kiosk', 'is_default': false, 'is_active': false},
          ],
        },
        '/outlets/rollup': {
          'days': 30,
          'totals': {'revenue': 500000.0, 'orders': 1100, 'outlets': 3},
          'outlets': rollup ??
              [
                {'outlet_id': 'o1', 'name': 'Harbour Main', 'revenue': 300000.0, 'orders': 600},
                {'outlet_id': 'o2', 'name': 'Hilltop', 'revenue': 200000.0, 'orders': 500},
                // o3 is deliberately absent from the roll-up.
              ],
        },
      };

  group('Outlets', () {
    testWidgets('REVENUE drills into every branch, ranked, with the share no card holds',
        (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.outletsModule(r, p), outletRoutes());

      await _tap(tester, _statCard('REVENUE (30D)'));
      expect(_sheetText('Revenue by branch'), findsOneWidget);
      expect(_sheetContaining('60% of group'), findsOneWidget);
      expect(_sheetContaining('40% of group'), findsOneWidget);
      // A branch the roll-up never returned says so — it does not read as ₹0.
      expect(_sheetContaining('Not in the 30-day roll-up'), findsOneWidget);
      // And the row leads on to that outlet's own record.
      await _tap(tester, _sheetText('Hilltop'));
      expect(_sheetText('MULTI-OUTLET'), findsOneWidget);
      expect(_sheetText('Hilltop'), findsOneWidget);
      expect(api.writes, isEmpty);
      await _closeSheet(tester);
    });

    testWidgets('ORDERS drills into the same branches ranked by volume, with the average order',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.outletsModule(r, p), outletRoutes());

      await _tap(tester, _statCard('ORDERS (30D)'));
      expect(_sheetText('Orders by branch'), findsOneWidget);
      // Each branch carries its own average, not the group's.
      expect(_sheetContaining('average ₹500 per order'), findsOneWidget);
      expect(_sheetContaining('average ₹400 per order'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('BRANCHES is deliberately inert — its list is the grid on this very page',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.outletsModule(r, p), outletRoutes());

      expect(
          tester.widget<StatCard>(find.ancestor(of: find.text('BRANCHES'), matching: find.byType(StatCard)))
              .onTap,
          isNull);
    });

    testWidgets('a failed roll-up leaves both money tiles inert rather than opening nothing',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.outletsModule(r, p), outletRoutes(rollup: const []));

      for (final caption in ['REVENUE (30D)', 'ORDERS (30D)']) {
        expect(
            tester.widget<StatCard>(find.ancestor(of: find.text(caption), matching: find.byType(StatCard)))
                .onTap,
            isNull,
            reason: caption);
      }
    });

    testWidgets('the outlet sheet reports orders and the average order alongside revenue',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.outletsModule(r, p), outletRoutes());

      await _tap(tester, _cardWith('1 Dock Rd'));
      expect(_sheetText('₹300000'), findsOneWidget);
      expect(_sheetText('600'), findsOneWidget);
      expect(_sheetText('₹500'), findsOneWidget);
      // The card cuts the opening hours to stay glanceable; the sheet has them whole.
      expect(_sheetText('Mon-Sun 11:00-23:30, kitchen closes 22:45'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('two branches sharing a name keep their own takings', (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.outletsModule(r, p), {
        '/outlets': {
          'outlets': [
            {'id': 'o1', 'outlet_name': 'Hilltop', 'is_default': true, 'is_active': true},
            {'id': 'o2', 'outlet_name': 'Hilltop', 'is_default': false, 'is_active': true},
          ],
        },
        '/outlets/rollup': {
          'totals': {'revenue': 90000.0, 'orders': 300, 'outlets': 2},
          'outlets': [
            {'outlet_id': 'o1', 'name': 'Hilltop', 'revenue': 60000.0, 'orders': 200},
            {'outlet_id': 'o2', 'name': 'Hilltop', 'revenue': 30000.0, 'orders': 100},
          ],
        },
      });

      // Keyed on NAME, the map collapsed to one entry and both branches read
      // whichever row happened to land last. Keyed on id they keep their own.
      await _tap(tester, _statCard('REVENUE (30D)'));
      expect(_sheetText('₹60000'), findsOneWidget);
      expect(_sheetText('₹30000'), findsOneWidget);
      await _closeSheet(tester);
    });
  });

  // -------------------------------------------------------------------- leaves --

  Map<String, dynamic> employeeRoutes({List<Map<String, dynamic>>? leaves}) => {
        '/restaurant/users': {
          'users': [
            {'employee_id': 'e2', 'emp_Fname': 'Rhea', 'emp_Lname': 'Kapoor',
             'employee_Username': 'rhea', 'role': 'waiter', 'role_all': ['waiter']},
            {'employee_id': 'e3', 'emp_Fname': 'Sunil', 'emp_Lname': 'Rao',
             'employee_Username': 'sunil', 'role': 'chef', 'role_all': ['chef']},
          ],
        },
        '/roles': <dynamic>[],
        '/restaurant/password-requests': {'requests': <dynamic>[]},
        '/analytics/staff-performance': {'window_days': 30, 'rows': <dynamic>[]},
        '/leaves': {
          'from': _day(-29),
          'to': _day(90),
          'total': 4,
          'leaves': leaves ??
              [
                {
                  'id': 'l1', 'emp_id': 'e2', 'employee_name': 'Rhea Kapoor',
                  'leave_type': 'sick', 'start_day': _day(-1), 'end_day': _day(0), 'days': 2,
                  'status': 'requested', 'reason': 'Fever, saw a doctor on the second day',
                  'requested_by_name': 'Rhea Kapoor', 'decided_by_name': null, 'decided_at': null,
                  'created_at': '2026-08-03T04:30:00Z',
                },
                {
                  'id': 'l2', 'emp_id': 'e3', 'employee_name': 'Sunil Rao',
                  'leave_type': 'holiday', 'start_day': _day(0), 'end_day': _day(0), 'days': 1,
                  'status': 'approved', 'reason': null,
                  'requested_by_name': 'Sunil Rao', 'decided_by_name': 'Priya Nair',
                  'decided_at': '2026-08-01T09:15:00Z', 'created_at': '2026-07-30T06:00:00Z',
                },
                {
                  'id': 'l3', 'emp_id': 'e2', 'employee_name': 'Rhea Kapoor',
                  'leave_type': 'casual', 'start_day': _day(5), 'end_day': _day(7), 'days': 3,
                  'status': 'approved', 'reason': 'Wedding',
                  'requested_by_name': 'Rhea Kapoor', 'decided_by_name': 'Priya Nair',
                  'decided_at': '2026-08-02T11:00:00Z', 'created_at': '2026-07-28T05:00:00Z',
                },
                {
                  'id': 'l4', 'emp_id': 'e3', 'employee_name': 'Sunil Rao',
                  'leave_type': 'unpaid', 'start_day': _day(-10), 'end_day': _day(-10), 'days': 1,
                  'status': 'rejected', 'reason': null,
                  'requested_by_name': 'Sunil Rao', 'decided_by_name': 'Priya Nair',
                  'decided_at': '2026-07-27T10:00:00Z', 'created_at': '2026-07-26T10:00:00Z',
                },
              ],
        },
      };

  group('Employees — leave register', () {
    testWidgets('a leave row opens its full record: who filed it, who signed it, when', (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      await _tap(tester, find.text('Booked ahead'));
      await _tap(tester, find.widgetWithText(ForkCard, 'Wedding'));
      expect(_sheetText('LEAVE · APPROVED'), findsOneWidget);
      expect(_sheetText('Casual leave'), findsOneWidget);
      expect(_sheetText('3 days'), findsOneWidget);
      expect(_sheetText('Wedding'), findsOneWidget);
      // The register row carries none of this.
      expect(_sheetText('Priya Nair'), findsOneWidget);
      expect(_sheetContaining('2 Aug 2026, 16:30:00 UTC+05:30'), findsOneWidget);
      // Reading a leave must never decide it.
      expect(api.writes, isEmpty);
      await _closeSheet(tester);
    });

    testWidgets('the register row on the page opens the record, and does not decide it',
        (tester) async {
      _size(tester, 1400);
      final api = await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      // The row itself, on the page — not a row inside a tile's drill-down.
      await _tap(tester, find.widgetWithText(ForkCard, 'Wedding'));
      expect(_sheetText('LEAVE · APPROVED'), findsOneWidget);
      // Named as the title and again as who filed it.
      expect(_sheetText('Rhea Kapoor'), findsNWidgets(2));
      expect(_sheetText('Casual leave'), findsOneWidget);
      // A card tap must never be a decision.
      expect(api.writes, isEmpty);
      await _closeSheet(tester);
    });

    testWidgets('approve/reject appear only for an undecided leave, and only in the sheet',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      // Undecided: the reviewer can act.
      await _tap(tester, find.text('Awaiting decision'));
      await _tap(tester, find.widgetWithText(ForkCard, 'Fever, saw a doctor on the second day'));
      expect(_sheetText('LEAVE · REQUESTED'), findsOneWidget);
      expect(_inSheet(find.text('Approve')), findsOneWidget);
      expect(_inSheet(find.text('Reject')), findsOneWidget);
      await _closeSheet(tester);

      // Already decided: no decision controls, because there is nothing to decide.
      await _tap(tester, find.text('Booked ahead'));
      await _tap(tester, find.widgetWithText(ForkCard, 'Wedding'));
      expect(_inSheet(find.text('Approve')), findsNothing);
      expect(_inSheet(find.text('Reject')), findsNothing);
      await _closeSheet(tester);
    });

    testWidgets('without Review Attendance the register is absent and the reason is stated',
        (tester) async {
      _size(tester, 1400);
      await _mount(
        tester,
        (r, p) => m.employeesModule(r, p),
        employeeRoutes(),
        profileJson: <String, dynamic>{
          'employeeId': 'e9',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'role': 'manager',
          'actions_set': <String>[],
          'action_names': <String>[],
        },
      );
      await _scrollThrough(tester);

      expect(find.textContaining('Review Attendance permission'), findsOneWidget);
      // No row to tap, rather than rows whose actions quietly 403.
      expect(find.text('Awaiting decision'), findsNothing);
      expect(find.text('Wedding'), findsNothing);
    });

    testWidgets('an undecided leave over days already past is called what it is: an absence',
        (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      await _tap(tester, find.text('Awaiting decision'));
      await _tap(tester, find.widgetWithText(ForkCard, 'Fever, saw a doctor on the second day'));
      expect(_sheetContaining('counting as unexplained absences'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('an approved leave says plainly that its days are excused', (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      await _tap(tester, find.text('Booked ahead'));
      await _tap(tester, find.widgetWithText(ForkCard, 'Wedding'));
      expect(_sheetContaining('excluded from this person\'s absence count'), findsOneWidget);
      await _closeSheet(tester);
    });

    testWidgets('each leave count opens exactly the set it counted', (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes());

      // On leave today = approved and covering today. The pending leave that
      // also covers today is NOT excused, so it must not be in this list.
      await _tap(tester, _tileCard('ON LEAVE TODAY'));
      expect(_sheetText('On leave today'), findsOneWidget);
      expect(_sheetText('Sunil Rao'), findsOneWidget);
      expect(_sheetText('Rhea Kapoor'), findsNothing);
      await _closeSheet(tester);

      // Booked ahead = approved and starting strictly after today, so the leave
      // already running is counted once, not in both registers.
      await _tap(tester, _tileCard('BOOKED AHEAD'));
      expect(_sheetText('Booked ahead'), findsWidgets);
      expect(_sheetText('Rhea Kapoor'), findsOneWidget);
      expect(_sheetText('Sunil Rao'), findsNothing);
      await _closeSheet(tester);
    });

    testWidgets('a leave count of zero is inert, not a tap onto an empty list', (tester) async {
      _size(tester, 1400);
      await _mount(tester, (r, p) => m.employeesModule(r, p), employeeRoutes(leaves: const []));
      await _scrollThrough(tester);

      for (final label in ['ON LEAVE TODAY', 'AWAITING DECISION', 'BOOKED AHEAD']) {
        expect(tester.widget<ForkCard>(_tileCard(label)).onTap, isNull, reason: label);
      }
    });
  });

  // ------------------------------------------------------------------ overflow --

  group('Overflow sweep', () {
    // Hostile data: a name longer than any card, free text where a chip is
    // expected, and a figure with every digit it could carry.
    final hostile = <String, Map<String, dynamic>>{
      'Attendance': {
        '/attendance/me': {
          'clocked_in': true,
          'since': '2026-08-03T04:30:00Z',
          'today_minutes': 99999,
          'pending_approval': true,
        },
        '/attendance': {
          'from': '2026-07-04',
          'to': '2026-08-03',
          'rows': [
            {'emp_id': 'e2', 'name': 'Devika Raghunathan-Balasubramanian Venkataraman',
             'minutes': 987654, 'shifts': 321, 'open': true},
          ],
          'pending': [
            {'id': 'a1', 'emp_id': 'e2', 'name': 'Devika Raghunathan-Balasubramanian Venkataraman',
             'clock_in': '2026-08-03T04:30:00Z', 'clock_out': null},
          ],
        },
        '/analytics/advanced': {
          'staff_attendance': [
            {'emp_id': 'e2', 'typical_start': '17:48', 'late_shifts': 321, 'late_pct': 99.9,
             'days_present': 300, 'absent_days': 45, 'leave_days': 12},
          ],
        },
      },
      'Outlets': {
        '/outlets': {
          'outlets': [
            {'id': 'o1', 'outlet_name': 'Harbour Main Riverside Terrace & Rooftop Grill',
             'is_default': true, 'is_active': true,
             'outlet_add': 'Plot 14, Block C, Marine Drive Extension, Fort Kochi 682001',
             'outlet_phone': '+91 98765 43210 / +91 98765 43211',
             'outlet_hours': 'Mon-Sun 11:00-23:30, kitchen closes 22:45, brunch from 09:00'},
            {'id': 'o2', 'outlet_name': 'Hilltop', 'is_default': false, 'is_active': false},
          ],
        },
        '/outlets/rollup': {
          'totals': {'revenue': 98765432.10, 'orders': 987654, 'outlets': 2},
          'outlets': [
            {'outlet_id': 'o1', 'name': 'Harbour Main Riverside Terrace & Rooftop Grill',
             'revenue': 98765432.10, 'orders': 987654},
          ],
        },
      },
    };

    for (final width in [390.0, 1100.0, 1200.0, 1700.0]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('Attendance survives ${width.toInt()} at ${scale}x', (tester) async {
          _size(tester, width, scale: scale);
          await _mount(tester, (r, p) => m.attendanceModule(r, p), hostile['Attendance']!);
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull);

          // The sheets are laid out at the same widths — a 460px dialog on a
          // 390px phone gets 266, which is where these overflow.
          await _tap(tester, find.text('Devika Raghunathan-Balasubramanian Venkataraman').first);
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);

          await _tap(tester, _statCard('HOURS TODAY'));
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);
        });

        testWidgets('Outlets survives ${width.toInt()} at ${scale}x', (tester) async {
          _size(tester, width, scale: scale);
          await _mount(tester, (r, p) => m.outletsModule(r, p), hostile['Outlets']!);
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull);

          await _tap(tester, _statCard('REVENUE (30D)'));
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);

          await _tap(tester, _statCard('ORDERS (30D)'));
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);
        });

        testWidgets('Leave register survives ${width.toInt()} at ${scale}x', (tester) async {
          _size(tester, width, scale: scale);
          await _mount(
            tester,
            (r, p) => m.employeesModule(r, p),
            employeeRoutes(leaves: [
              {
                'id': 'l1', 'emp_id': 'e2',
                'employee_name': 'Devika Raghunathan-Balasubramanian Venkataraman',
                'leave_type': 'sick', 'start_day': _day(-1), 'end_day': _day(364), 'days': 366,
                'status': 'requested',
                'reason': 'Extended medical leave following surgery, with a review scheduled '
                    'every six weeks at the district hospital',
                'requested_by_name': 'Devika Raghunathan-Balasubramanian Venkataraman',
                'decided_by_name': null, 'decided_at': null,
                'created_at': '2026-08-03T04:30:00Z',
              },
            ]),
          );
          await _scrollThrough(tester);
          expect(tester.takeException(), isNull);

          await _tap(tester, _tileCard('AWAITING DECISION'));
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);
        });
      }
    }
  });
}
