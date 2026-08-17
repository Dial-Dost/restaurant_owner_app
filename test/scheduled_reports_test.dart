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
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Scheduled reports in Accounting.
///
/// What is being pinned, and why each one is worth a test:
///   * WHEN a schedule runs is stated in the RESTAURANT's zone. A bare "08:00"
///     is read as device time by an owner in another state, and the whole point
///     of the feature is that the file covers the restaurant's own day.
///   * A value the picker does not offer must still OPEN. Minutes are quarter
///     hours here, but the backend accepts 0-59 and the web dashboard can write
///     :07 — a dropdown whose value matches no item asserts outright.
///   * A failure is visible. A schedule the server paused after repeated
///     failures says so; a delivery that failed carries its reason and offers
///     no download, because there is no file behind it.
///   * Reading the page writes nothing, and deleting asks first.
///   * "All outlets (combined)" is read-only at the server. This list widens to
///     every outlet's schedules in that mode, so any control that writes would
///     be a guaranteed 400 — it must be gone, and the reason has to be on screen.
///   * A refused repeat of "Run now" (409) reports the FIRST run as still on its
///     way. Calling it a failure invites another click; calling it a second
///     queued run is a lie — the server deliberately queued nothing.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.writeErrors = const <String, ApiException>{}});

  final Map<String, dynamic> routes;

  /// Keyed 'METHOD path' (e.g. 'POST /reports/schedules/s1/run-now') -> the
  /// exception that call answers with, so a test can drive a real backend
  /// refusal (run-now's 409) rather than only the happy path.
  final Map<String, ApiException> writeErrors;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
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
    if (method != 'GET') {
      final refusal = writeErrors['$method $path'];
      if (refusal != null) throw refusal;
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a query-carrying family.
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

Map<String, dynamic> _schedule(
  String id,
  String name,
  String reportKey,
  String frequency, {
  int hour = 8,
  int minute = 0,
  int? weekday,
  int? dayOfMonth,
  bool enabled = true,
  int failures = 0,
  String lastStatus = '',
  String lastError = '',
  String lastRunAt = '',
}) =>
    {
      'id': id,
      'outlet_id': 'o1',
      'name': name,
      'report_key': reportKey,
      'frequency': frequency,
      'hour_local': hour,
      'minute_local': minute,
      'weekday': weekday,
      'day_of_month': dayOfMonth,
      'channel': 'inbox',
      'format': 'csv',
      'enabled': enabled,
      'last_occurrence_key': lastStatus.isEmpty ? null : '2026-08-10',
      'last_status': lastStatus.isEmpty ? null : lastStatus,
      'last_error': lastError.isEmpty ? null : lastError,
      'last_run_at': lastRunAt.isEmpty ? null : lastRunAt,
      'consecutive_failures': failures,
      'created_at': '2026-08-01T02:30:00.000Z',
      'updated_at': '2026-08-01T02:30:00.000Z',
    };

Map<String, dynamic> _delivery(
  String id,
  String scheduleId,
  String status, {
  String from = '2026-08-09',
  String to = '2026-08-09',
  String? occurrenceKey = '2026-08-10',
  String artifactName = '',
  bool truncated = false,
  String error = '',
}) =>
    {
      'id': id,
      'schedule_id': scheduleId,
      'outlet_id': 'o1',
      'occurrence_key': occurrenceKey,
      'fire_at': '2026-08-10T02:30:00.000Z',
      'period_from': from,
      'period_to': to,
      'timezone': 'Asia/Kolkata',
      'status': status,
      'attempts': status == 'failed' ? 3 : 1,
      'channel': 'inbox',
      'artifact_name': artifactName.isEmpty ? null : artifactName,
      'artifact_bytes': artifactName.isEmpty ? null : 2048,
      'artifact_truncated': truncated,
      'error': error.isEmpty ? null : error,
      'delivered_at': status == 'delivered' ? '2026-08-10T02:30:12.000Z' : null,
      'created_at': '2026-08-10T02:30:00.000Z',
    };

/// The daily/weekly/monthly trio plus the delivery history they produced.
Map<String, dynamic> _routes({
  List<Map<String, dynamic>> schedules = const [],
  List<Map<String, dynamic>> deliveries = const [],
}) =>
    {
      '/reports/sales': {
        'total_sales': 100.0,
        'total_tax': 0.0,
        'total_service_charge': 0.0,
        'total_refund': 0.0,
        'net_sales': 100.0,
        'bill_count': 1,
        'by_day': <Map<String, dynamic>>[],
        'by_method': <Map<String, dynamic>>[],
      },
      '/reports/gst': {'total_taxable': 0.0, 'total_tax': 0.0, 'by_rate': <Map<String, dynamic>>[]},
      '/reports/pnl': {
        'gross_sales': 100.0,
        'refunds': 0.0,
        'tax_collected': 0.0,
        'net_revenue': 100.0,
        'total_expenses': 0.0,
        'net_profit': 100.0,
        'expenses_by_category': <Map<String, dynamic>>[],
      },
      '/reports/discounts': {'bill_count': 1, 'discounted_bills': 0, 'by_coupon': <Map<String, dynamic>>[]},
      '/reports/schedules': {'schedules': schedules},
      '/reports/deliveries': {'deliveries': deliveries},
      '/expenses': {'expenses': <Map<String, dynamic>>[]},
      '/payroll': {'total_due': 0.0, 'total_paid': 0.0, 'rows': <Map<String, dynamic>>[]},
      '/bills/closed': {'bills': <Map<String, dynamic>>[], 'total': 0, 'has_more': false},
    };

Future<_FakeApi> _mountAccounting(
  WidgetTester tester,
  Map<String, dynamic> routes, {
  double width = 1400,
  double scale = 1.0,
  // The active outlet, exactly as the app-bar switcher sets it. 'all' is the
  // combined view the backend serves reads from and refuses every write in.
  String? outlet,
  Map<String, ApiException> writeErrors = const <String, ApiException>{},
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final api = _FakeApi(routes, writeErrors: writeErrors);
  final rest = await _signIn(api);
  if (outlet != null) rest.auth.selectOutlet(outlet);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: const ['Accounting'],
      clearFocus: () {},
      child: Scaffold(body: m.accountingModule(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

/// The section sits at the bottom of a long page, and a ListView only builds
/// what it can see — so bring the target into the tree before asserting on it.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final page = find.byType(Scrollable).first;
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300, scrollable: page, maxScrolls: 250);
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

/// Scoped to one schedule's own card, so an assertion about the paused row
/// cannot be satisfied by the healthy row above it.
Finder _cardOf(String name) => find.ancestor(of: find.text(name), matching: find.byType(ForkCard)).last;

/// Open a schedule's overflow menu and choose an item.
Future<void> _menu(WidgetTester tester, String name, String item) async {
  await _tap(tester, find.descendant(of: _cardOf(name), matching: find.byType(PopupMenuButton<String>)));
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => RestaurantTime.adopt(RestaurantTime.defaultZone));
  tearDown(() => RestaurantTime.adopt(RestaurantTime.defaultZone));

  group('scheduled reports', () {
    testWidgets('every frequency states when it runs, in the restaurant zone', (tester) async {
      await _mountAccounting(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'sales', 'daily', hour: 8),
          _schedule('s2', 'Weekly P&L', 'pnl', 'weekly', hour: 18, minute: 45, weekday: 1),
          _schedule('s3', 'Month-end GST', 'gst', 'monthly', hour: 9, minute: 7, dayOfMonth: 3),
        ]),
      );

      // The zone is named on every line: "08:00" alone reads as device time.
      await _reveal(tester, find.text('Sales · Every day at 08:00 Asia/Kolkata'));
      expect(find.text('Sales · Every day at 08:00 Asia/Kolkata'), findsOneWidget);
      expect(find.text('Profit & loss · Every Monday at 18:45 Asia/Kolkata'), findsOneWidget);
      expect(find.text('GST / tax · Day 3 of every month at 09:07 Asia/Kolkata'), findsOneWidget);
    });

    testWidgets('a paused schedule says the server paused it, and why', (tester) async {
      await _mountAccounting(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'sales', 'daily', lastStatus: 'delivered', lastRunAt: '2026-08-10T02:30:00.000Z'),
          _schedule('s2', 'Weekly P&L', 'pnl', 'weekly', weekday: 1, enabled: false, failures: 5,
              lastStatus: 'failed', lastError: 'Timed out reading bills'),
        ]),
      );

      await _reveal(tester, find.text('Weekly P&L'));
      final paused = _cardOf('Weekly P&L');
      expect(find.descendant(of: paused, matching: find.text('Paused')), findsOneWidget);
      expect(find.descendant(of: paused, matching: find.text('Last run failed')), findsOneWidget);
      expect(find.descendant(of: paused, matching: find.text('Timed out reading bills')), findsOneWidget);
      expect(
        find.descendant(
            of: paused,
            matching: find.text('Paused automatically after repeated failures — fix the cause, then resume it.')),
        findsOneWidget,
      );

      // The healthy one is not tarred with it.
      final live = _cardOf('Morning sales');
      expect(find.descendant(of: live, matching: find.text('On')), findsOneWidget);
      expect(find.descendant(of: live, matching: find.text('Last run delivered')), findsOneWidget);
    });

    testWidgets('history: a delivered run offers its file, a failed one offers its reason', (tester) async {
      await _mountAccounting(
        tester,
        _routes(
          schedules: [_schedule('s1', 'Morning sales', 'sales', 'daily')],
          deliveries: [
            _delivery('d1', 's1', 'delivered', artifactName: 'sales_2026-08-09_to_2026-08-09.csv'),
            _delivery('d2', 's1', 'failed', error: 'Timed out reading bills'),
            // A real manual run's key, not null: "Run now" is deduplicated per
            // minute, so it stores a `manual:`-prefixed key. Seeding null here
            // would let the label rule regress to "occurrence_key is present"
            // and still pass, which is exactly how it broke.
            _delivery('d3', 's1', 'delivered',
                occurrenceKey: 'manual:2026-08-08T09:15',
                artifactName: 'sales_2026-08-08_to_2026-08-08.csv', truncated: true),
          ],
        ),
      );

      await _reveal(tester, find.text('Recent deliveries'));
      expect(find.text('Delivered'), findsNWidgets(2));
      expect(find.text('Failed'), findsOneWidget);

      // Only the two rows with a stored file can be downloaded — a failed run
      // has no artifact behind it, so offering the control would be a dead tap.
      expect(find.byTooltip('Download sales_2026-08-09_to_2026-08-09.csv'), findsOneWidget);
      expect(find.byTooltip('Download sales_2026-08-08_to_2026-08-08.csv'), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsNWidgets(2),
          reason: 'the failed row must not offer a download it cannot serve');

      // A manual run is labelled as one: it neither collides with nor consumes
      // the day's scheduled occurrence, and the history has to show that.
      expect(find.textContaining('run manually'), findsOneWidget);
      expect(find.textContaining('file truncated'), findsOneWidget);
      expect(find.text('Timed out reading bills'), findsOneWidget);
    });

    testWidgets('a minute the picker does not offer still opens the editor', (tester) async {
      // :07 is writable through the API and the web dashboard. A dropdown whose
      // value matches no item throws outright, so the row would be uneditable.
      final api = await _mountAccounting(
        tester,
        _routes(schedules: [_schedule('s3', 'Month-end GST', 'gst', 'monthly', hour: 9, minute: 7, dayOfMonth: 3)]),
      );

      await _menu(tester, 'Month-end GST', 'Edit');
      expect(tester.takeException(), isNull);
      expect(find.text('Edit schedule'), findsOneWidget);
      expect(
        find.text("Runs at 09:07 on the restaurant's clock (Asia/Kolkata). Covers the whole previous calendar month."),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(api.writes, contains('PATCH /reports/schedules/s3'));
    });

    testWidgets('reading writes nothing; run-now and pause go to their own routes', (tester) async {
      final api = await _mountAccounting(
        tester,
        _routes(schedules: [_schedule('s1', 'Morning sales', 'sales', 'daily')]),
      );
      expect(api.writes, isEmpty, reason: 'opening Accounting must not trigger a report run');

      await _tap(tester, find.descendant(of: _cardOf('Morning sales'), matching: find.text('Run now')));
      expect(api.writes, contains('POST /reports/schedules/s1/run-now'));

      await _menu(tester, 'Morning sales', 'Pause');
      expect(api.writes, contains('PATCH /reports/schedules/s1'));
    });

    testWidgets('delete asks first, and cancelling writes nothing', (tester) async {
      final api = await _mountAccounting(
        tester,
        _routes(schedules: [_schedule('s1', 'Morning sales', 'sales', 'daily')]),
      );

      await _menu(tester, 'Morning sales', 'Delete');
      // The server archives rather than destroys, and the copy has to say so —
      // the delivery history is what stops an occurrence going out twice.
      expect(find.textContaining('stay in the history'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);

      await _menu(tester, 'Morning sales', 'Delete');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(api.writes, contains('DELETE /reports/schedules/s1'));
    });

    testWidgets('all outlets (combined): no control that writes is offered, and it says why', (tester) async {
      final api = await _mountAccounting(
        tester,
        _routes(
          schedules: [
            _schedule('s1', 'Morning sales', 'sales', 'daily'),
            _schedule('s2', 'Weekly P&L', 'pnl', 'weekly', weekday: 1),
          ],
          deliveries: [_delivery('d1', 's1', 'delivered', artifactName: 'sales_2026-08-09_to_2026-08-09.csv')],
        ),
        outlet: 'all',
      );

      await _reveal(tester, find.text('Morning sales'));
      expect(find.text('New schedule'), findsNothing);
      expect(find.text('Run now'), findsNothing);
      for (final name in const ['Morning sales', 'Weekly P&L']) {
        expect(
          find.descendant(of: _cardOf(name), matching: find.byType(PopupMenuButton<String>)),
          findsNothing,
          reason: 'edit/pause/delete on $name would be rejected by the server in the combined view',
        );
      }
      expect(
        find.textContaining('Switch to a single outlet to create, edit, pause, delete or run one.'),
        findsOneWidget,
      );

      // Reads are untouched: the schedules still list, and a stored file still
      // downloads — it is only the writes the combined view cannot carry.
      await _reveal(tester, find.text('Recent deliveries'));
      expect(find.byTooltip('Download sales_2026-08-09_to_2026-08-09.csv'), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('run now: a refused repeat says the first run is still coming, not that it failed', (tester) async {
      final api = await _mountAccounting(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'sales', 'daily'),
          _schedule('s2', 'Weekly P&L', 'pnl', 'weekly', weekday: 1),
        ]),
        writeErrors: {
          // What the server really answers: a manual run is bucketed to the
          // restaurant's own minute, so the second click inside it is refused.
          'POST /reports/schedules/s1/run-now':
              ApiException('This report was just queued — try again in a minute', 409),
          'POST /reports/schedules/s2/run-now': ApiException('Unable to queue this report', 400),
        },
      );

      await _tap(tester, find.descendant(of: _cardOf('Morning sales'), matching: find.text('Run now')));
      expect(api.writes, contains('POST /reports/schedules/s1/run-now'));
      expect(find.textContaining('nothing extra was queued'), findsOneWidget);
      expect(find.textContaining('Queued — it appears under Recent deliveries'), findsNothing,
          reason: 'the server queued nothing, so the UI must not claim a second run');

      // A real refusal is still a refusal — only the 409 is reinterpreted.
      // SnackBars queue, so let the first one retire or the second never shows.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tap(tester, find.descendant(of: _cardOf('Weekly P&L'), matching: find.text('Run now')));
      expect(find.textContaining('Unable to queue this report'), findsOneWidget);
    });

    testWidgets('nothing overflows on a phone at 1.3x', (tester) async {
      await _mountAccounting(
        tester,
        _routes(
          schedules: [
            _schedule('s1', 'Morning sales report for the whole restaurant', 'sales', 'daily',
                lastStatus: 'delivered', lastRunAt: '2026-08-10T02:30:00.000Z'),
            _schedule('s2', 'Weekly P&L', 'pnl', 'weekly', hour: 18, minute: 45, weekday: 3,
                enabled: false, failures: 5, lastStatus: 'failed', lastError: 'Timed out reading bills'),
          ],
          deliveries: [_delivery('d1', 's1', 'delivered', artifactName: 'sales_2026-08-09_to_2026-08-09.csv')],
        ),
        width: 390,
        scale: 1.3,
      );

      await _reveal(tester, find.text('Recent deliveries'));
      expect(tester.takeException(), isNull, reason: 'the scheduled-reports section overflowed at 390px / 1.3x');
    });
  });
}
