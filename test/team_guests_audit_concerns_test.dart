import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Employees (performance + leave), the guest book (segments + one shared
/// sort), the audit trail's date/category filters, and the Concerns screen.
///
/// The four things pinned here are the ones that would be wrong SILENTLY:
/// a score with no data rendering as a zero, a "most spent" ranking that only
/// ranks the loaded page, a filter change that appends to rows fetched under the
/// previous filter, and a concern stated with no way to act on it.

/// Records every path so a test can assert what was actually asked of the
/// server — sorting and paging are server-side here, so the request IS the
/// behaviour.
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
    calls.add(path);
    if (routes.containsKey(path)) return _resolve(routes[path], path);
    // Longest matching prefix, so one route answers a whole query-carrying
    // family and a callable route can vary its reply by query string.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return _resolve(routes[prefixes.first], path);
    throw ApiException('No fake route for $path', 404);
  }

  dynamic _resolve(dynamic route, String path) =>
      route is dynamic Function(String) ? route(path) : route;

  List<String> callsTo(String prefix) => calls.where((c) => c.startsWith(prefix)).toList();
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child, {List<String>? labels, void Function(String, Map<String, dynamic>?)? onOpen}) =>
    MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (label, {Map<String, dynamic>? target}) => onOpen?.call(label, target),
        visibleLabels: labels ??
            const [
              'Overview', 'Concerns', 'Orders', 'Menu', 'Inventory', 'Purchase Orders',
              'Tables', 'Feedback', 'Attendance', 'Billing', 'Employees', 'Customers',
            ],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _desktop(WidgetTester tester, {double width = 1700, double height = 1600}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Mounts a module on a clean tree and returns the fake so the test can read
/// back what it asked the server for. The blank pump matters: these screens hold
/// their own state, so re-pumping the same widget type would keep the previous
/// State and its already-loaded payload.
Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  List<String>? labels,
  void Function(String, Map<String, dynamic>?)? onOpen,
}) async {
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(module(rest, rest.auth.profile!), labels: labels, onOpen: onOpen));
  await tester.pumpAndSettle();
  return api;
}

// ------------------------------------------------------------------ fixtures --

Map<String, dynamic> _component({
  required bool available,
  num? value,
  num? score,
  String unit = 'stars (1-5)',
  int sample = 0,
  num? benchmark,
  required String note,
}) =>
    {
      'value': value,
      'score': score,
      'available': available,
      'unit': unit,
      'sample': sample,
      'benchmark': benchmark,
      'note': note,
    };

/// One scored employee (Asha) whose turnaround could not be measured, and one
/// (Bala) the server returned no row for at all.
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
          'score': 78.4,
          'components': {
            'apc': _component(
              available: true,
              value: 480.5,
              score: 100,
              unit: 'currency per cover',
              sample: 12,
              benchmark: 450,
              note: 'Pre-tax spend per cover across 12 settled bills (26 covers), '
                  'against a house average of 450.',
            ),
            'rating': _component(
              available: true,
              value: 4.5,
              score: 87.5,
              sample: 8,
              note: 'Average of 8 guest ratings.',
            ),
            'attendance': _component(
              available: true,
              value: 92,
              score: 92,
              unit: '% presence/punctuality',
              sample: 24,
              note: 'Present on 22 of 24 open days (2 excused by approved leave).',
            ),
            'tat': _component(
              available: false,
              unit: 'minutes per table',
              note: 'No completed seating in this window was billed by them, so '
                  'turnaround cannot be measured.',
            ),
          },
          'effective_weights': {'apc': 0.41, 'rating': 0.35, 'attendance': 0.24, 'tat': 0},
          'components_available': 3,
        },
      ],
    };

Map<String, dynamic> _users() => {
      'users': [
        {
          'id': 'e1',
          'employee_id': 'e1',
          'employee_Username': 'asha',
          'emp_Fname': 'Asha',
          'emp_Lname': 'Rao',
          'role': 'waiter',
          'role_all': ['waiter'],
        },
        {
          'id': 'e2',
          'employee_id': 'e2',
          'employee_Username': 'bala',
          'emp_Fname': 'Bala',
          'emp_Lname': 'Nair',
          'role': 'chef',
          'role_all': ['chef'],
        },
      ],
    };

Map<String, dynamic> _leaves() => {
      'leaves': [
        {
          'id': 'l1',
          'emp_id': 'e1',
          'employee_name': 'Asha Rao',
          'leave_type': 'sick',
          'start_day': '2026-08-10',
          'end_day': '2026-08-12',
          'days': 3,
          'status': 'requested',
          'reason': 'Fever',
          'requested_by': 'e1',
          'requested_by_name': 'Asha Rao',
          'decided_by': null,
          'decided_by_name': null,
          'decided_at': null,
          'created_at': '2026-08-01T06:00:00.000Z',
        },
      ],
      'total': 1,
      'has_more': false,
      'from': '2026-07-05',
      'to': '2026-11-01',
    };

Map<String, dynamic> _employeeRoutes() => {
      '/restaurant/users': _users(),
      '/roles': <dynamic>[],
      '/restaurant/password-requests': {'requests': <dynamic>[]},
      '/analytics/staff-performance': _performance(),
      '/leaves': _leaves(),
    };

Map<String, dynamic> _guest(int i, {String segment = 'regular'}) => {
      'customer_id': 'c$i',
      'name': 'Guest $i',
      'phone': '90000000$i',
      'email': 'guest$i@example.com',
      'visits': i,
      'total_spend': 100.0 * i,
      'total_service_charge': 0,
      'total_tax': 0,
      'pre_tax_spend': 100.0 * i,
      'avg_spend_per_visit': 100.0,
      'last_visit': '2026-08-01T12:00:00Z',
      'days_since_last_visit': i,
      'bills': i,
      'avg_rating': null,
      'feedbacks': 0,
      'segment': segment,
    };

dynamic Function(String) _segmentsRoute(List<Map<String, dynamic>> guests) => (String path) {
      final limit = int.tryParse(RegExp(r'limit=(\d+)').firstMatch(path)?.group(1) ?? '') ?? 50;
      final segment = RegExp(r'segment=([\w-]+)').firstMatch(path)?.group(1) ?? 'all';
      final page = guests.take(limit).toList();
      if (!path.contains('meta=1')) return page;
      return {
        'customers': page,
        'total': guests.length,
        'has_more': guests.length > page.length,
        'sort': RegExp(r'sort=(\w+)').firstMatch(path)?.group(1) ?? 'recent',
        'segment': segment,
        // As the server does it: counted over the set AFTER its own segment
        // filter, which is exactly why the app must not trust these while a
        // segment is selected.
        'segment_counts': segment == 'all'
            ? {'new': 1, 'regular': guests.length, 'high-spend': 2, 'dormant': 3}
            : {'new': 0, 'regular': 0, 'high-spend': 0, 'dormant': 0, segment: guests.length},
        'spend_basis': 'tax-inclusive grand total of settled bills',
      };
    };

Map<String, dynamic> _concernRow({
  required String key,
  required String title,
  required String severity,
  required String module,
  required int count,
  required String advice,
  List<Map<String, dynamic>> items = const [],
  num? amount,
}) =>
    {
      'key': key,
      'label': title,
      'title': title,
      'count': count,
      'severity': severity,
      'module': module,
      'detail': '',
      'items': items,
      'amount': ?amount,
      'what_to_do': advice,
      'impact': amount ?? count,
      'deep_link': {'module': module, 'params': <String, String>{}},
    };

void main() {
  // ------------------------------------------------------------- employees ---

  testWidgets('Employees: the card carries the score and the sheet carries its components',
      (tester) async {
    _desktop(tester);
    await _mount(tester, m.employeesModule, _employeeRoutes());

    // 78.4 rounds to 78 — the score is ON the card, not behind the tap.
    expect(find.text('78 / 100 score'), findsOneWidget);
    // Bala has no performance row at all: never a zero, and never a blank.
    expect(find.text('Not enough data'), findsOneWidget);

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();

    expect(find.text('PERFORMANCE'), findsOneWidget);
    for (final measure in ['Average per cover', 'Guest rating', 'Attendance', 'Table turnaround']) {
      expect(find.text(measure), findsOneWidget, reason: '"$measure" must be shown behind the score');
    }
    // The score is never a bare number: the sheet says what built it.
    expect(find.textContaining('Built from 3 of 4 measures'), findsOneWidget);
    // And the weighting is the server's, per measure.
    expect(find.text('Counts for 41% of this score.'), findsOneWidget);
    expect(find.text('Counts for 24% of this score.'), findsOneWidget);
  });

  testWidgets('Employees: an unmeasurable component reads as "not enough data", never as 0',
      (tester) async {
    _desktop(tester);
    await _mount(tester, m.employeesModule, _employeeRoutes());

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();

    // Scoped to the open sheet — the roster behind it legitimately carries its
    // own "not enough data" chip for the employee with no row at all.
    final sheet = find.byType(Dialog);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);

    // Turnaround could not be measured. A zero here would say "they were the
    // slowest possible", which is the opposite of what the server reported.
    expect(inSheet(find.text('0 / 100')), findsNothing);
    // The chip, the server's own reason, and the honest statement that the
    // measure was excluded rather than scored.
    expect(inSheet(find.text('Not enough data')), findsOneWidget);
    expect(
      inSheet(find.textContaining('turnaround cannot be measured')),
      findsOneWidget,
      reason: "the server's own explanation must be shown, not swallowed",
    );
    expect(inSheet(find.textContaining('Left out of the score')), findsOneWidget);
  });

  // `effective_weights` is not guaranteed: an older server sends none, and a
  // trimmed payload can drop a single key. Coercing that to 0.0 printed "Counts
  // for 0% of this score." beside a measure that plainly did count — a figure
  // the app invented, contradicting the score directly above it.
  testWidgets('Employees: a missing weight reads as unknown, never as 0%', (tester) async {
    _desktop(tester);
    final perf = _performance();
    // A whole-key drop, the older-server shape.
    (perf['rows'] as List)[0].remove('effective_weights');
    await _mount(tester, m.employeesModule, {..._employeeRoutes(), '/analytics/staff-performance': perf});

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();
    final sheet = find.byType(Dialog);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);

    expect(inSheet(find.text('Counts for 0% of this score.')), findsNothing,
        reason: 'an unreported share must never be printed as zero');
    // Three measures were scored; each says its share is unknown rather than nil.
    expect(inSheet(find.text('It counted towards this score, but the server did not say by how much.')),
        findsNWidgets(3));
    // The one measure that genuinely was excluded still says so.
    expect(inSheet(find.textContaining('Left out of the score')), findsOneWidget);
  });

  testWidgets('Employees: one dropped weight leaves the reported ones alone', (tester) async {
    _desktop(tester);
    final perf = _performance();
    (((perf['rows'] as List)[0] as Map)['effective_weights'] as Map).remove('rating');
    await _mount(tester, m.employeesModule, {..._employeeRoutes(), '/analytics/staff-performance': perf});

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();
    final sheet = find.byType(Dialog);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);

    expect(inSheet(find.text('Counts for 41% of this score.')), findsOneWidget);
    expect(inSheet(find.text('Counts for 24% of this score.')), findsOneWidget);
    // Only the dropped one is unknown, and it is not reported as 0%.
    expect(inSheet(find.text('It counted towards this score, but the server did not say by how much.')),
        findsOneWidget);
    expect(inSheet(find.text('Counts for 0% of this score.')), findsNothing);
  });

  testWidgets('Employees: a weight the server really did send as 0 is still shown as 0%',
      (tester) async {
    _desktop(tester);
    final perf = _performance();
    // `tat` is excluded, so the server reports a genuine zero share for it. The
    // fix must not turn a REPORTED zero into "unknown" — only an absent one.
    ((((perf['rows'] as List)[0] as Map)['components'] as Map)['tat'] as Map)
      ..['available'] = true
      ..['score'] = 55;
    await _mount(tester, m.employeesModule, {..._employeeRoutes(), '/analytics/staff-performance': perf});

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();
    final sheet = find.byType(Dialog);
    expect(find.descendant(of: sheet, matching: find.text('Counts for 0% of this score.')),
        findsOneWidget);
  });

  testWidgets('Employees: leave shows on the card and can be decided from the sheet',
      (tester) async {
    _desktop(tester);
    await _mount(tester, m.employeesModule, _employeeRoutes());

    // The card flags that somebody is waiting on a decision.
    expect(find.text('1 to review'), findsOneWidget);

    // .first is the ROSTER card: her name now also appears in the leave
    // register below it, which is a different control entirely.
    await tester.tap(find.text('Asha Rao').first);
    await tester.pumpAndSettle();

    // Scoped to the SHEET: the tab's own leave register carries the same
    // request, and deciding it there is a second, legitimate control.
    final sheet = find.byType(Dialog);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
    expect(find.text('LEAVE'), findsOneWidget);
    expect(inSheet(find.textContaining('Sick leave')), findsOneWidget);
    expect(inSheet(find.text('Approve')), findsOneWidget);
    expect(inSheet(find.text('Reject')), findsOneWidget);
  });

  testWidgets('Employees: no analytics permission says so instead of showing an empty score',
      (tester) async {
    _desktop(tester);
    await tester.pumpWidget(const SizedBox());
    final api = _FakeApi(_employeeRoutes());
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = AuthController(api: api);
    await auth.login('CSR Organics', 'admin', 'admin123');
    // A real waiter login: no wildcard, no analytics action.
    final limited = Profile.fromJson(<String, dynamic>{
      'employeeId': 'e9',
      'restaurantName': 'CSR Organics',
      'role': 'waiter',
      'actions_set': <String>['92cb8236-1039-4b47-a66f-6c7c8b0144ae'],
      'action_names': <String>['View Employees'],
    });
    await tester.pumpWidget(_host(m.employeesModule(RestClient(auth), limited)));
    await tester.pumpAndSettle();

    expect(api.callsTo('/analytics/staff-performance'), isEmpty,
        reason: 'a permission the login does not hold must not be requested');
    expect(find.textContaining('need the analytics permission'), findsWidgets);
  });

  // ---------------------------------------------------------------- guests ---

  testWidgets('Guest book: the segment band and the list are ranked by the same server sort',
      (tester) async {
    _desktop(tester);
    final api = await _mount(tester, m.customersModule, {
      '/customers/segments': _segmentsRoute([for (var i = 1; i <= 6; i++) _guest(i)]),
    });

    // Three server-ranked leaderboards, not a re-sort of the loaded page.
    for (final title in ['Most recent', 'Most spent', 'Most visited']) {
      expect(find.text(title), findsWidgets, reason: '"$title" must be one of the overview rankings');
    }
    api.calls.clear();

    await tester.tap(find.text('Most spent').first);
    await tester.pumpAndSettle();

    final list = api.callsTo('/customers/segments').where((c) => c.contains('meta=1')).toList();
    expect(list, isNotEmpty);
    // The LIST is re-fetched under the new sort, from the top.
    expect(list.every((c) => c.contains('sort=spend')), isTrue, reason: 'the list must re-sort server-side');
    expect(list.every((c) => c.contains('offset=0')), isTrue, reason: 'a sort change restarts paging');
    // And the band is re-ranked under the same filters alongside it.
    final band = api.callsTo('/customers/segments').where((c) => !c.contains('meta=1')).toList();
    expect(band.length, 3, reason: 'all three rankings are re-read, not re-sorted locally');
    expect(find.text('sorting the list'), findsOneWidget);
  });

  testWidgets('Guest book: a segment filter applies to the list AND to the rankings',
      (tester) async {
    _desktop(tester);
    final api = await _mount(tester, m.customersModule, {
      '/customers/segments': _segmentsRoute([for (var i = 1; i <= 6; i++) _guest(i)]),
    });

    // Counts come off the server's segment_counts, so a tab can be badged
    // without paging the whole book.
    expect(find.text('High spend · 2'), findsOneWidget);
    api.calls.clear();

    await tester.tap(find.text('Dormant · 3'));
    await tester.pumpAndSettle();

    final all = api.callsTo('/customers/segments');
    expect(all, hasLength(4), reason: 'one list page plus the three rankings');
    expect(all.every((c) => c.contains('segment=dormant')), isTrue,
        reason: 'the segment must reach the rankings too, not only the list');
    expect(all.where((c) => c.contains('meta=1')).every((c) => c.contains('offset=0')), isTrue);

    // The server counts its segments AFTER applying the segment filter, so this
    // response says "0 high spend". That number describes a different question
    // and must never reach the tab — the count taken while unsegmented stands.
    expect(find.text('High spend · 0'), findsNothing);
    expect(find.text('High spend · 2'), findsOneWidget);
  });

  // ----------------------------------------------------------------- audit ---

  testWidgets('Audit: changing a filter resets paging to offset 0 and drops the loaded rows',
      (tester) async {
    _desktop(tester);
    // 50 rows on the unfiltered first page, a second page behind it, and a
    // single obviously-different row once any filter is applied.
    dynamic auditRoute(String path) {
      final filtered = path.contains('category=') || path.contains('from=');
      if (filtered) {
        return {
          'logs': [
            {'id': 'f1', 'action': 'Filtered Entry', 'details': '', 'employee': 'Asha', 'category': 'Menu', 'timestamp': '2026-08-03T05:00:00.000Z'},
          ],
          'total': 1,
          'has_more': false,
        };
      }
      final offset = int.tryParse(RegExp(r'offset=(\d+)').firstMatch(path)?.group(1) ?? '') ?? 0;
      // Six rows a page, not the real fifty: the list is lazily built, so the
      // paging foot has to be on screen for the test to reach it.
      return {
        'logs': [
          for (var i = 0; i < 6; i++)
            {
              'id': 'a${offset + i}',
              'action': 'Entry ${offset + i}',
              'details': '',
              'employee': 'Asha',
              'category': 'General',
              'timestamp': '2026-08-03T05:00:00.000Z',
            },
        ],
        'total': 12,
        'has_more': offset == 0,
      };
    }

    final api = await _mount(tester, m.auditLogModule, {'/audit-logs': auditRoute});
    expect(find.text('Entry 0'), findsOneWidget);

    await tester.tap(find.textContaining('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Entry 6'), findsOneWidget, reason: 'the second page appended');
    expect(api.callsTo('/audit-logs').any((c) => c.contains('offset=6')), isTrue);
    api.calls.clear();

    // Today: a date preset, resolved in the restaurant's zone.
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();

    final after = api.callsTo('/audit-logs');
    expect(after, isNotEmpty);
    expect(after.every((c) => c.contains('offset=0')), isTrue,
        reason: 'a filter change must restart at the first page');
    expect(after.every((c) => c.contains('from=')), isTrue);
    // Everything scrolled in under the old filter is gone — not appended to.
    expect(find.text('Entry 0'), findsNothing);
    expect(find.text('Entry 6'), findsNothing);
    expect(find.text('Filtered Entry'), findsOneWidget);
  });

  testWidgets('Audit: the category filter is a server filter and also restarts paging',
      (tester) async {
    _desktop(tester);
    final api = await _mount(tester, m.auditLogModule, {
      '/audit-logs': (String path) => {
            'logs': [
              {
                'id': path.contains('category=Bill') ? 'm1' : 'g1',
                'action': path.contains('category=Bill') ? 'Bill Entry' : 'General Entry',
                'details': '',
                'employee': 'Asha',
                'category': path.contains('category=Bill') ? 'Bill' : 'General',
                'timestamp': '2026-08-03T05:00:00.000Z',
              },
            ],
            'total': 1,
            'has_more': false,
          },
    });
    expect(find.text('General Entry'), findsOneWidget);
    api.calls.clear();

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    // warnIfMissed: a PopupMenuButton's route sits under its own transform, so
    // the hit-test warning here is noise, not a missed tap.
    await tester.tap(find.text('Bill').last, warnIfMissed: false);
    await tester.pumpAndSettle();

    final after = api.callsTo('/audit-logs');
    expect(after, isNotEmpty);
    expect(after.every((c) => c.contains('category=Bill') && c.contains('offset=0')), isTrue);
    expect(find.text('Bill Entry'), findsOneWidget);
    expect(find.text('General Entry'), findsNothing);
  });

  // -------------------------------------------------------------- concerns ---

  testWidgets('Concerns: grouped worst first, and every concern names who and what to do',
      (tester) async {
    _desktop(tester);
    String? opened;
    await _mount(
      tester,
      m.concernsModule,
      {
        '/analytics/concerns': {
          'window_days': 30,
          'timezone': 'Asia/Kolkata',
          'generated_at': '2026-08-03T04:30:00.000Z',
          'totals': {'high': 1, 'medium': 1, 'low': 1},
          'concerns': [
            _concernRow(
              key: 'unresolved_feedback',
              title: 'Bad reviews nobody has followed up',
              severity: 'high',
              module: 'Feedback',
              count: 2,
              advice: 'Call each of these guests back and record the outcome.',
              items: [
                {'label': 'Meera Iyer', 'sub': '2/5 · served by Asha'},
                {'label': 'Anon guest', 'sub': '1/5'},
              ],
            ),
            _concernRow(
              key: 'low_stock',
              title: 'Ingredients about to run out',
              severity: 'medium',
              module: 'Inventory',
              count: 1,
              advice: 'Raise a purchase order for these ingredients today.',
              items: [
                {'label': 'Tomatoes', 'sub': '2 kg left'},
              ],
            ),
            _concernRow(
              key: 'slow_movers',
              title: 'Dishes nobody orders',
              severity: 'low',
              module: 'Menu',
              count: 1,
              advice: 'Re-price it, re-photograph it, or take it off the menu.',
              items: [
                {'label': 'Beetroot Salad', 'sub': '0 sold'},
              ],
            ),
          ],
        },
      },
      onOpen: (label, _) => opened = label,
    );

    // Severity bands, worst first.
    expect(find.text('High — deal with today'), findsOneWidget);
    expect(find.text('Medium — deal with this week'), findsOneWidget);
    expect(find.text('Low — worth a look'), findsOneWidget);

    // The people and things affected are NAMED, not counted.
    expect(find.text('Meera Iyer'), findsOneWidget);
    expect(find.text('Tomatoes'), findsOneWidget);
    expect(find.text('Beetroot Salad'), findsOneWidget);

    // Every concern offers an action.
    for (final advice in [
      'Call each of these guests back and record the outcome.',
      'Raise a purchase order for these ingredients today.',
      'Re-price it, re-photograph it, or take it off the menu.',
    ]) {
      expect(find.text(advice), findsOneWidget, reason: 'every concern must state what to do');
    }

    // Every one of them also offers a way to go and fix it — a concern that
    // states a problem and then strands you is half a screen.
    expect(find.textContaining('Open '), findsNWidgets(3));
    for (final dest in ['Open Feedback', 'Open Inventory', 'Open Menu']) {
      expect(find.text(dest), findsOneWidget, reason: '$dest must be reachable from its concern');
    }

    // And the deep link actually goes somewhere.
    final open = find.text('Open Inventory');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(opened, 'Inventory');
  });

  testWidgets('Concerns: an empty list reads as good news, not as a failed load', (tester) async {
    _desktop(tester);
    await _mount(tester, m.concernsModule, {
      '/analytics/concerns': {
        'window_days': 30,
        'timezone': 'Asia/Kolkata',
        'generated_at': '2026-08-03T04:30:00.000Z',
        'totals': {'high': 0, 'medium': 0, 'low': 0},
        'concerns': <dynamic>[],
      },
    });

    expect(find.text('Nothing needs your attention'), findsOneWidget);
    expect(find.textContaining('No open concerns'), findsOneWidget);
    expect(find.textContaining("Couldn't"), findsNothing);
  });

  // ------------------------------------------------------------------ fit ---

  // Every one of these screens grew a card grid, and the widest tile is not the
  // dangerous one — it is the one where the window is just wide enough for
  // another column. Long real-world values (a double-barrelled name, four
  // roles, a wordy server note) are pinned at each breakpoint the grids use.
  testWidgets('Team, guest book and concerns fit every column count they produce', (tester) async {
    final longUsers = {
      'users': [
        {
          'id': 'e1',
          'employee_id': 'e1',
          'employee_Username': 'anantharamakrishnan.venkataraghavan',
          'emp_Fname': 'Anantharamakrishnan',
          'emp_Lname': 'Venkataraghavan',
          'role': 'waiter',
          'role_all': ['waiter', 'cashier', 'manager', 'host'],
        },
      ],
    };

    for (final width in [700.0, 760.0, 1000.0, 1120.0, 1500.0, 1700.0]) {
      _desktop(tester, width: width, height: 1600);

      await _mount(tester, m.employeesModule, {..._employeeRoutes(), '/restaurant/users': longUsers});
      expect(tester.takeException(), isNull, reason: 'employee card overflowed at ${width}px');

      await _mount(tester, m.customersModule, {
        '/customers/segments': _segmentsRoute([
          for (var i = 1; i <= 6; i++)
            {..._guest(i), 'name': 'Dr Anantharamakrishnan Venkataraghavan Subramanian $i'},
        ]),
      });
      expect(tester.takeException(), isNull, reason: 'guest tile overflowed at ${width}px');

      await _mount(tester, m.concernsModule, {
        '/analytics/concerns': {
          'window_days': 30,
          'timezone': 'Asia/Kolkata',
          'generated_at': '2026-08-03T04:30:00.000Z',
          'totals': {'high': 1, 'medium': 0, 'low': 0},
          'concerns': [
            _concernRow(
              key: 'unsettled_bills',
              title: 'Bills left open on tables that have already gone home',
              severity: 'high',
              module: 'Tables',
              count: 3,
              amount: 18450.75,
              advice: 'Chase these tables and close the bills. This is money already '
                  'earned and not yet collected.',
              items: [
                {'label': 'Table 12 — window, second row from the kerb', 'sub': '₹8,200.00 · open 2 days'},
              ],
            ),
          ],
        },
      });
      expect(tester.takeException(), isNull, reason: 'concern card overflowed at ${width}px');
    }
  });
}
