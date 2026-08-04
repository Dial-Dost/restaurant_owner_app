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
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The Employees tab's scoring band and leave register.
///
/// The one thing that would be wrong SILENTLY here is a ranking: a person the
/// server could not measure has a null score, and reading that as 0 puts them at
/// the bottom of a leaderboard that says "worst" by position alone. So the
/// ranking tests are written around the person with the missing component, not
/// around the person with the good one.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<String> calls = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') return <String, dynamic>{'changed': true};
    if (routes.containsKey(path)) return routes[path];
    final hit = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (hit.isNotEmpty) return routes[hit.first];
    throw ApiException('No fake route for $path', 404);
  }
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Overview', 'Employees', 'Attendance', 'Analytics'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _size(WidgetTester tester, double width, {double height = 4200, double scale = 1.0}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<_FakeApi> _mount(WidgetTester tester, Map<String, dynamic> routes) async {
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.employeesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

// ------------------------------------------------------------------ fixtures --

Map<String, dynamic> _measured(num value, num score, String unit, {int sample = 5}) => {
      'value': value,
      'score': score,
      'available': true,
      'unit': unit,
      'sample': sample,
      'benchmark': null,
      'note': 'Measured over $sample observation(s).',
    };

Map<String, dynamic> _blank(String unit, String note) => {
      'value': null,
      'score': null,
      'available': false,
      'unit': unit,
      'sample': 0,
      'benchmark': null,
      'note': note,
    };

/// Asha is measured on everything. Bala is measured on everything EXCEPT guest
/// rating, and scores worse than Asha where he is measured. Chandra has no row
/// at all. That is the whole point of the fixture: on the rating board Bala must
/// leave the ranking entirely rather than sink to the bottom of it.
Map<String, dynamic> _performance() => {
      'window_days': 30,
      'from': '2026-07-05',
      'to': '2026-08-03',
      'timezone': 'Asia/Kolkata',
      'generated_at': '2026-08-03T04:30:00.000Z',
      'weights': {'apc': 0.35, 'rating': 0.30, 'attendance': 0.20, 'tat': 0.15},
      'benchmarks': {'apc': 450, 'tat_minutes': 62, 'apc_basis': 'pre-tax taxable base'},
      'rows': [
        {
          'employee_id': 'e1',
          'employee_name': 'Asha Rao',
          'role': 'waiter',
          'score': 90,
          'components': {
            'apc': _measured(480.5, 100, 'currency per cover', sample: 12),
            'rating': _measured(4.6, 90, 'stars (1-5)', sample: 8),
            'attendance': _measured(96, 96, '% presence/punctuality', sample: 24),
            'tat': _measured(50, 80, 'minutes per table', sample: 9),
          },
          'effective_weights': {'apc': 0.35, 'rating': 0.30, 'attendance': 0.20, 'tat': 0.15},
          'components_available': 4,
        },
        {
          'employee_id': 'e2',
          'employee_name': 'Bala Nair',
          'role': 'waiter',
          'score': 30,
          'components': {
            'apc': _measured(180, 40, 'currency per cover', sample: 4),
            'rating': _blank('stars (1-5)',
                'No guest feedback was attributed to them in this window — scored as excluded, NOT as zero stars.'),
            'attendance': _measured(50, 50, '% presence/punctuality', sample: 20),
            'tat': _measured(120, 20, 'minutes per table', sample: 3),
          },
          'effective_weights': {'apc': 0.5, 'rating': 0, 'attendance': 0.29, 'tat': 0.21},
          'components_available': 3,
        },
      ],
    };

Map<String, dynamic> _users() => {
      'users': [
        for (final e in const [
          ['e1', 'asha', 'Asha', 'Rao'],
          ['e2', 'bala', 'Bala', 'Nair'],
          ['e3', 'chandra', 'Chandra', 'Iyer'],
        ])
          {
            'id': e[0],
            'employee_id': e[0],
            'employee_Username': e[1],
            'emp_Fname': e[2],
            'emp_Lname': e[3],
            'role': 'waiter',
            'role_all': const ['waiter'],
          },
      ],
    };

String _day(int offset) {
  final base = RestaurantTime.nowWall().add(Duration(days: offset));
  return RestaurantTime.isoDate(base);
}

Map<String, dynamic> _leave(
  String id,
  String empId,
  String name, {
  required String status,
  required int from,
  required int to,
  String type = 'casual',
}) =>
    {
      'id': id,
      'emp_id': empId,
      'employee_name': name,
      'leave_type': type,
      'start_day': _day(from),
      'end_day': _day(to),
      'days': to - from + 1,
      'status': status,
      'reason': 'Family',
      'requested_by': empId,
      'requested_by_name': name,
      'decided_by': null,
      'decided_by_name': null,
      'decided_at': null,
      'created_at': '2026-08-01T06:00:00.000Z',
    };

Map<String, dynamic> _leavePage(List<Map<String, dynamic>> leaves) => {
      'leaves': leaves,
      'total': leaves.length,
      'has_more': false,
      'from': _day(-29),
      'to': _day(90),
    };

Map<String, dynamic> _routes({List<Map<String, dynamic>>? leaves, Map<String, dynamic>? perf}) => {
      '/restaurant/users': _users(),
      '/roles': <dynamic>[],
      '/restaurant/password-requests': {'requests': <dynamic>[]},
      '/analytics/staff-performance': perf ?? _performance(),
      '/leaves': _leavePage(leaves ?? const []),
    };

/// The five boxes, by the caption each one carries.
const _boxes = [
  ['Overall score — team average', 'Overall score'],
  ['Average per cover — team average', 'Average per cover'],
  ['Guest rating — team average', 'Guest rating'],
  ['Attendance — team average', 'Attendance'],
  ['Table turnaround — team average', 'Table turnaround'],
];

/// Scrolls the tab until [f] is on screen. The page is a lazy ListView and the
/// new sections sit under the roster.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------------------- scoring band --

  testWidgets('every scoring box opens a ranked list for its own measure', (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes());

    for (final box in _boxes) {
      await _reveal(tester, find.text(box[0]));
      await tester.tap(find.text(box[0]));
      await tester.pumpAndSettle();

      final sheet = find.byType(Dialog);
      expect(sheet, findsOneWidget, reason: '${box[1]} did not open a board');
      expect(find.descendant(of: sheet, matching: find.text(box[1])), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Ranked')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('SCORING')), findsOneWidget);
      // A leaderboard, not a static tile: one ranked bar per measured person.
      expect(find.descendant(of: sheet, matching: find.byType(HBarRow)), findsWidgets);

      await tester.tap(find.descendant(of: sheet, matching: find.text('Close')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the board ranks by the measure and shows each value in its own unit',
      (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes());

    await _reveal(tester, find.text('Average per cover — team average'));
    await tester.tap(find.text('Average per cover — team average'));
    await tester.pumpAndSettle();

    final sheet = find.byType(Dialog);
    final bars = tester
        .widgetList<HBarRow>(find.descendant(of: sheet, matching: find.byType(HBarRow)))
        .toList();
    expect(bars.length, 2);
    // Best first, numbered, with the reading in the measure's own unit beside it.
    expect(bars[0].label, '1. Asha Rao');
    expect(bars[0].value, '₹480.50');
    expect(bars[0].sub, 'score 100');
    expect(bars[1].label, '2. Bala Nair');
    expect(bars[1].value, '₹180.00');
    // And a rank leads to the person it names.
    expect(bars[0].onTap, isNotNull);
  });

  // THE test. Bala has no guest feedback. A zero would rank him last on rating —
  // "the worst-rated waiter" — off a measure nobody could take for him.
  testWidgets('an employee with no data for a measure is not ranked last by it', (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes());

    await _reveal(tester, find.text('Guest rating — team average'));
    await tester.tap(find.text('Guest rating — team average'));
    await tester.pumpAndSettle();

    final sheet = find.byType(Dialog);
    final bars = tester
        .widgetList<HBarRow>(find.descendant(of: sheet, matching: find.byType(HBarRow)))
        .toList();
    // Only the one person who HAS a rating is ranked at all.
    expect(bars.length, 1);
    expect(bars.single.label, '1. Asha Rao');
    for (final b in bars) {
      expect(b.label.contains('Bala'), isFalse, reason: 'an unmeasured person was ranked');
      expect(b.label.contains('Chandra'), isFalse, reason: 'an unmeasured person was ranked');
      expect(b.sub, isNot('score 0'));
    }

    // Both unmeasured people are named under their own heading, below the
    // ranking, each with the server's own reason rather than a made-up one.
    expect(find.descendant(of: sheet, matching: find.text('Not enough data')), findsNWidgets(3));
    expect(find.descendant(of: sheet, matching: find.text('Bala Nair')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Chandra Iyer')), findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.textContaining('NOT as zero stars')),
      findsOneWidget,
    );
    // Below, not last-in-the-ranking: position on screen is the claim being made.
    expect(
      tester.getTopLeft(find.descendant(of: sheet, matching: find.text('Bala Nair'))).dy,
      greaterThan(tester.getTopLeft(find.descendant(of: sheet, matching: find.text('Ranked'))).dy),
    );
  });

  testWidgets('a box reads its team average, its benchmark and how many it covered',
      (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes());

    await _reveal(tester, find.text('Average per cover — team average'));
    // (100 + 40) / 2 = 70 over the two people it could be measured for.
    expect(find.text('house ₹450.00 per cover · 2 of 3 measured'), findsOneWidget);
    // Rating covered only Asha, and the box says so rather than averaging in a 0.
    expect(find.text('absolute 1–5 star scale · 1 of 3 measured'), findsOneWidget);

    // The distribution inside the box READS but does not tap: the box is the
    // control, and a bar tap would swallow it.
    final dist = tester.widget<WeekdayBars>(find.byType(WeekdayBars).first);
    expect(dist.onTap, isNull);
    expect(dist.tooltipBuilder, isNotNull);
    expect(dist.tooltipBuilder!(0), contains('Asha Rao'));
    expect(dist.tooltipBuilder!(0), contains('score 100'));
  });

  testWidgets('no scoring band at all when the scores could not be read', (tester) async {
    _size(tester, 1700);
    await tester.pumpWidget(const SizedBox());
    final api = _FakeApi(_routes());
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = AuthController(api: api);
    await auth.login('CSR Organics', 'admin', 'admin123');
    // A login with no analytics action: the reason is already stated once above
    // the roster, and five dashed boxes would say it five more times.
    final limited = Profile.fromJson(<String, dynamic>{
      'employeeId': 'e9',
      'restaurantName': 'CSR Organics',
      'role': 'waiter',
      'actions_set': <String>['92cb8236-1039-4b47-a66f-6c7c8b0144ae'],
      'action_names': <String>['View Employees'],
    });
    await tester.pumpWidget(_host(m.employeesModule(RestClient(auth), limited)));
    await tester.pumpAndSettle();

    expect(find.text('Scoring'), findsNothing);
    expect(find.text('Leave'), findsNothing);
    expect(find.textContaining('need the analytics permission'), findsWidgets);
  });

  // ---------------------------------------------------------- leave register --

  testWidgets('the leave register renders with nothing on record', (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes(leaves: const []));

    await _reveal(tester, find.text('Leave'));
    expect(tester.takeException(), isNull);
    expect(find.text('ON LEAVE TODAY'), findsOneWidget);
    expect(find.text('everyone is in'), findsOneWidget);
    expect(find.text('nothing to review'), findsOneWidget);
    expect(find.text('nothing booked'), findsOneWidget);
    expect(find.textContaining('No leave on record between'), findsOneWidget);
    // Nothing to decide, so no decision controls anywhere on the page.
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('one pending leave is bucketed, counted and decidable in place', (tester) async {
    _size(tester, 1700);
    final api = await _mount(tester, _routes(leaves: [
      _leave('l1', 'e1', 'Asha Rao', status: 'requested', from: 3, to: 5, type: 'sick'),
    ]));

    await _reveal(tester, find.text('Awaiting decision'));
    expect(find.text('AWAITING DECISION'), findsOneWidget);
    // Requested, so it is NOT counted as booked ahead — that register is
    // approved leave only.
    expect(find.text('nothing booked'), findsOneWidget);
    expect(find.text('everyone is in'), findsOneWidget);
    expect(find.textContaining('Sick leave'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /leaves/l1/approve'));
  });

  testWidgets('filing from the register asks who it is for', (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes(leaves: const []));

    await _reveal(tester, find.text('Request leave'));
    await tester.tap(find.text('Request leave'));
    await tester.pumpAndSettle();

    // The whole roster, because this section only exists for a login that can
    // already file for somebody else — the same split the server enforces.
    expect(find.text('Request leave for'), findsOneWidget);
    for (final who in ['Asha Rao', 'Bala Nair', 'Chandra Iyer']) {
      expect(find.descendant(of: find.byType(SimpleDialog), matching: find.text(who)), findsOneWidget);
    }

    await tester.tap(find.descendant(
        of: find.byType(SimpleDialog), matching: find.text('Bala Nair')));
    await tester.pumpAndSettle();
    expect(find.text('Request leave — Bala Nair'), findsOneWidget);
  });

  testWidgets('many leaves land in the right register each', (tester) async {
    _size(tester, 1700);
    await _mount(tester, _routes(leaves: [
      _leave('l1', 'e1', 'Asha Rao', status: 'approved', from: -1, to: 1),
      _leave('l2', 'e2', 'Bala Nair', status: 'approved', from: 0, to: 0, type: 'sick'),
      _leave('l3', 'e3', 'Chandra Iyer', status: 'approved', from: 7, to: 9),
      _leave('l4', 'e1', 'Asha Rao', status: 'approved', from: 20, to: 21),
      _leave('l5', 'e2', 'Bala Nair', status: 'requested', from: 4, to: 4),
      _leave('l6', 'e3', 'Chandra Iyer', status: 'requested', from: 12, to: 13),
      _leave('l7', 'e1', 'Asha Rao', status: 'rejected', from: 15, to: 15),
    ]));

    await _reveal(tester, find.text('Leave'));
    expect(tester.takeException(), isNull);
    // Two running today, two waiting, two starting later. The rejected one is in
    // neither register but is still part of the section's own count.
    expect(find.text('On leave today'), findsOneWidget);
    expect(find.text('Awaiting decision'), findsOneWidget);
    expect(find.text('Booked ahead'), findsOneWidget);
    expect(find.text('Asha Rao, Bala Nair'), findsOneWidget);

    await _reveal(tester, find.text('Booked ahead'));
    // A leave already running is counted once — today's register, not both.
    expect(find.text('Reject'), findsNWidgets(2));
  });

  // ----------------------------------------------------------------- layout ---

  // Overflow is the recurring failure on this screen, and 1.3x is an ordinary
  // accessibility setting rather than an edge case. Hostile data: a very long
  // name, a very large money figure and a full leave register.
  testWidgets('the new sections survive every window and text scale', (tester) async {
    final users = _users();
    (users['users'] as List)[0]['emp_Fname'] = 'Bartholomew Fitzwilliam';
    (users['users'] as List)[0]['emp_Lname'] = 'Featherstonehaugh-Vandermeer';
    final perf = _performance();
    (((perf['rows'] as List)[0] as Map)['components'] as Map)['apc'] =
        _measured(9876543.21, 100, 'currency per cover');
    (perf['benchmarks'] as Map)['apc'] = 1234567.89;

    for (final width in [390.0, 1100.0, 1200.0, 1700.0]) {
      for (final scale in [1.0, 1.3]) {
        _size(tester, width, height: 6000, scale: scale);
        await _mount(tester, {
          ..._routes(leaves: [
            _leave('l1', 'e1', 'Bartholomew Fitzwilliam Featherstonehaugh-Vandermeer',
                status: 'requested', from: 2, to: 9, type: 'unpaid'),
            _leave('l2', 'e2', 'Bala Nair', status: 'approved', from: 0, to: 2),
            _leave('l3', 'e3', 'Chandra Iyer', status: 'approved', from: 30, to: 33),
          ]),
          '/restaurant/users': users,
          '/analytics/staff-performance': perf,
        });

        expect(tester.takeException(), isNull,
            reason: 'Employees overflowed at ${width}px / ${scale}x');

        // And the boards they open have to survive it too.
        await _reveal(tester, find.text('Overall score — team average'));
        await tester.tap(find.text('Overall score — team average'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'the scoring board overflowed at ${width}px / ${scale}x');
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
    }
  });
}
