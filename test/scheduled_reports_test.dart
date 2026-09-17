import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/report_email.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Scheduled reports — now in Insights → Reports → Email reports (client item 9).
///
/// What is being pinned, and why each one is worth a test:
///   * WHEN a schedule runs, and WHAT the next run covers, in the restaurant's
///     words: "Every day at 02:00 · the day that just ended", and the 24 hours
///     the server says it will read.
///   * ANY MINUTE. The 2.0.1 editor offered quarter hours; the client asked for
///     "a specific time". The minute the owner picks is the minute sent.
///   * A 2.0.1 schedule still opens, as the single calendar-day CSV it always
///     was, and saving it without touching the addresses leaves them alone.
///   * GST and P&L are calendar days only — the chip says so rather than
///     letting the server refuse.
///   * A failure is visible; a schedule the server paused says so.
///   * Reading writes nothing; deleting asks first; "Run now"'s 409 says the
///     FIRST run is still coming.
///   * "All outlets (combined)" is read-only at the server, so no control that
///     writes is offered there, and the reason is on screen.
///   * Accounting says where the schedules went and opens them.
///   * Both skins, both platforms; nothing overflows on a phone at 1.3x.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {Map<String, ApiException> writeErrors = const {}}) : writeErrors = Map.of(writeErrors);

  final Map<String, dynamic> routes;
  final Map<String, ApiException> writeErrors;
  final List<String> calls = <String>[];
  final List<Object?> bodies = <Object?>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'o1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      bodies.add(body);
      final refusal = writeErrors['$method $path'];
      if (refusal != null) throw refusal;
      return <String, dynamic>{'success': true};
    }
    final base = Uri.parse('http://x$path').path;
    if (routes.containsKey(base)) return routes[base];
    throw ApiException('No fake route for $base', 404);
  }

  List<String> get writes => calls.where((c) => !c.startsWith('GET ')).toList();
}

Map<String, dynamic> _schedule(
  String id,
  String name,
  String frequency, {
  String reportKey = 'sales',
  List<String>? reportKeys,
  List<String>? formats,
  String windowMode = 'calendar',
  String channel = 'inbox',
  List<String> recipients = const [],
  int hour = 8,
  int minute = 0,
  int? weekday,
  int? dayOfMonth,
  bool enabled = true,
  int failures = 0,
  String lastStatus = '',
  String lastError = '',
  Map<String, dynamic>? nextWindow,
  String? nextRunAt,
}) =>
    {
      'id': id,
      'outlet_id': 'o1',
      'name': name,
      'report_key': reportKey,
      'report_keys': ?reportKeys,
      'formats': ?formats,
      if (reportKeys != null) 'window_mode': windowMode,
      if (reportKeys != null) 'outlet_scope': 'outlet',
      'frequency': frequency,
      'hour_local': hour,
      'minute_local': minute,
      'weekday': weekday,
      'day_of_month': dayOfMonth,
      'channel': channel,
      'recipients': recipients,
      'format': 'csv',
      'enabled': enabled,
      'last_occurrence_key': lastStatus.isEmpty ? null : '2026-09-16',
      'last_status': lastStatus.isEmpty ? null : lastStatus,
      'last_error': lastError.isEmpty ? null : lastError,
      'last_run_at': lastStatus.isEmpty ? null : '2026-09-16T02:30:00.000Z',
      'consecutive_failures': failures,
      'next_run_at': nextRunAt,
      'next_window': nextWindow,
      'created_at': '2026-09-01T02:30:00.000Z',
      'updated_at': '2026-09-01T02:30:00.000Z',
    };

Map<String, dynamic> _routes({List<Map<String, dynamic>> schedules = const [], Map<String, dynamic>? config}) => {
      '/outlets': {'outlets': <Map<String, dynamic>>[]},
      '/reports/mis/item-wise': {
        'meta': {'report': 'item_wise', 'title': 'Item Wise', 'window': {'from': '2026-09-16', 'to': '2026-09-16'}, 'notes': <String>[]},
        'columns': <Map<String, dynamic>>[],
        'rows': [
          {'name': 'Paneer Tikka'},
        ],
        'totals': <String, dynamic>{},
        'page': {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
      },
      '/reports/email/config': config ??
          {
            'email_available': true,
            'schema_ready': true,
            'send_now_enabled': true,
            'scheduler': {'enabled': true},
            'limits': {'recipients_per_send': 10, 'address_book': 25},
            'formats': ['xlsx', 'csv'],
            'can_edit_recipients': true,
            'can_use_all_outlets': true,
          },
      '/reports/email/recipients': {
        'recipients': [
          {'id': 'r1', 'email': 'owner@gaia.test', 'label': 'Owner', 'status': 'active'},
          {'id': 'r2', 'email': 'accounts@firm.test', 'status': 'active'},
        ],
        'can_edit': true,
        'max': 25,
      },
      '/reports/schedules': {'schedules': schedules},
      '/reports/deliveries': {'deliveries': <Map<String, dynamic>>[]},
      // Accounting's own reads, for the pointer test.
      '/reports/sales': {'total_sales': 0.0, 'by_day': <Map<String, dynamic>>[], 'by_method': <Map<String, dynamic>>[]},
      '/reports/gst': {'total_taxable': 0.0, 'total_tax': 0.0, 'by_rate': <Map<String, dynamic>>[]},
      '/reports/pnl': {'gross_sales': 0.0, 'expenses_by_category': <Map<String, dynamic>>[]},
      '/reports/discounts': {'bill_count': 0, 'by_coupon': <Map<String, dynamic>>[]},
      '/expenses': {'expenses': <Map<String, dynamic>>[]},
      '/payroll': {'rows': <Map<String, dynamic>>[]},
      '/bills/closed': {'bills': <Map<String, dynamic>>[], 'total': 0, 'has_more': false},
    };

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

Future<_FakeApi> _mount(
  WidgetTester tester,
  Map<String, dynamic> routes, {
  double width = 1400,
  double scale = 1.0,
  String? outlet,
  DesignSystem system = DesignSystem.rustic,
  Map<String, ApiException> writeErrors = const {},
  bool accounting = false,
  void Function(String label, Map<String, dynamic>? target)? opened,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  m.misResetReportMemory();
  final api = _FakeApi(routes, writeErrors: writeErrors);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  if (outlet != null) auth.selectOutlet(outlet);
  final rest = RestClient(auth);
  await tester.pumpWidget(GaiaScope(
    system: system,
    child: MaterialApp(
      theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ModuleNavigator(
        openModule: (label, {Map<String, dynamic>? target}) => opened?.call(label, target),
        visibleLabels: const ['Reports', 'Accounting'],
        clearFocus: () {},
        child: Scaffold(
          body: accounting ? m.accountingModule(rest, auth.profile!) : m.reportsModule(rest, auth.profile!),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  if (!accounting) {
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('reports-view')), matching: find.text(kEmailAreaTitle)));
    await tester.pumpAndSettle();
  }
  return api;
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250, scrollable: find.byType(Scrollable).first, maxScrolls: 250);
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

Finder _cardOf(String name) => find.ancestor(of: find.text(name), matching: find.byType(ForkCard)).last;

Future<void> _menu(WidgetTester tester, String name, String item) async {
  await _tap(tester, find.descendant(of: _cardOf(name), matching: find.byType(PopupMenuButton<String>)));
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

/// Pick [value] in the dropdown keyed [key] (the menu opens around the current value).
Future<void> _pick(WidgetTester tester, String key, String value) async {
  await _tap(tester, find.byKey(ValueKey(key)));
  // The open menu is the last scrollable; sixty minutes do not all fit in it.
  if (find.text(value).evaluate().length < 2) {
    await tester.scrollUntilVisible(find.text(value), 40, scrollable: find.byType(Scrollable).last, maxScrolls: 60);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Map _lastBody(_FakeApi api) => api.bodies.last as Map;

void main() {
  setUp(() => RestaurantTime.adopt(RestaurantTime.defaultZone));
  tearDown(() => RestaurantTime.adopt(RestaurantTime.defaultZone));

  group('scheduled reports', () {
    for (final system in DesignSystem.values) {
      testWidgets('every schedule says when it runs and what its next run covers (${system.name})', (tester) async {
        await _mount(
          tester,
          _routes(schedules: [
            _schedule('s1', 'Nightly close', 'daily',
                reportKeys: ['sales_summary', 'settlement_summary'], formats: ['xlsx'], windowMode: 'trading_day',
                channel: 'email', recipients: ['owner@gaia.test'], hour: 2,
                nextRunAt: '2026-09-17T20:30:00.000Z',
                nextWindow: {'from': '2026-09-17', 'to': '2026-09-17', 'day_close': '02:00', 'start_at': '2026-09-16T20:30:00.000Z', 'end_at': '2026-09-17T20:30:00.000Z'}),
            _schedule('s2', 'Weekly P&L', 'weekly', reportKey: 'pnl', hour: 18, minute: 45, weekday: 1),
            _schedule('s3', 'Month-end GST', 'monthly', reportKey: 'gst', hour: 9, minute: 7, dayOfMonth: 3),
          ]),
          system: system,
        );
        expect(find.text('Sales Summary and Settlement Summary · XLSX'), findsOneWidget);
        expect(find.text('Every day at 02:00 · the day that just ended · Email to owner@gaia.test'), findsOneWidget);
        expect(find.text('Next: 18 Sep, 02:00 — covers 17 Sep, 02:00 → 18 Sep, 02:00'), findsOneWidget);
        expect(find.text('Every Monday at 18:45 · In-app inbox'), findsOneWidget);
        expect(find.text('On day 3 of each month at 09:07 · In-app inbox'), findsOneWidget);
        expect(find.text('Profit & Loss · CSV'), findsOneWidget);
      }, variant: _platforms);
    }

    testWidgets('a paused schedule says the server paused it, and why', (tester) async {
      await _mount(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'daily', lastStatus: 'delivered'),
          _schedule('s2', 'Weekly P&L', 'weekly', reportKey: 'pnl', weekday: 1, enabled: false, failures: 5,
              lastStatus: 'failed', lastError: 'Timed out reading bills'),
        ]),
      );
      final paused = _cardOf('Weekly P&L');
      expect(find.descendant(of: paused, matching: find.text('Paused')), findsOneWidget);
      expect(find.descendant(of: paused, matching: find.text('Last run failed')), findsOneWidget);
      expect(find.descendant(of: paused, matching: find.text('Timed out reading bills · 5 failures in a row')), findsOneWidget);
      expect(
        find.descendant(of: paused, matching: find.text('Paused automatically after repeated failures — fix the cause, then resume it.')),
        findsOneWidget,
      );
      final live = _cardOf('Morning sales');
      expect(find.descendant(of: live, matching: find.text('On')), findsOneWidget);
      expect(find.descendant(of: live, matching: find.text('Last run OK')), findsOneWidget);
    });

    testWidgets('a new schedule: any minute, the day that just ended, the reports and addresses chosen', (tester) async {
      final api = await _mount(tester, _routes());
      await _tap(tester, find.byKey(const ValueKey('email-new-schedule')));
      expect(find.text('SCHEDULED REPORT'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('schedule-name')), 'Nightly close');
      await _pick(tester, 'send-at-hour', '22');
      await _pick(tester, 'send-at-minute', '32');
      expect(find.textContaining('Covers the 24 hours up to 22:32'), findsOneWidget);

      // GST cannot be ticked while the day closes at the send time…
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-report-gst'))).onSelected, isNull);
      await _tap(tester, find.byKey(const ValueKey('email-report-void_kot')));
      await _tap(tester, find.byKey(const ValueKey('email-format-csv')));
      await _tap(tester, find.byKey(const ValueKey('email-to-r2')));
      await _tap(tester, find.byKey(const ValueKey('schedule-save')));

      expect(api.writes, ['POST /reports/schedules']);
      expect(_lastBody(api), {
        'name': 'Nightly close',
        'report_keys': ['void_kot', 'sales_summary', 'settlement_summary'],
        'formats': ['xlsx', 'csv'],
        'frequency': 'daily',
        'hour_local': 22,
        'minute_local': 32,
        'weekday': null,
        'day_of_month': null,
        'window_mode': 'trading_day',
        'outlet_scope': 'outlet',
        'channel': 'email',
        'enabled': true,
        'recipient_ids': ['r2'],
      });
    });

    testWidgets('…and a calendar day lets GST in; weekly is always calendar', (tester) async {
      final api = await _mount(tester, _routes());
      await _tap(tester, find.byKey(const ValueKey('email-new-schedule')));
      await tester.enterText(find.byKey(const ValueKey('schedule-name')), 'Tax pack');
      await _tap(tester, find.byKey(const ValueKey('schedule-window-calendar')));
      await _tap(tester, find.byKey(const ValueKey('email-report-gst')));
      await _pick(tester, 'schedule-frequency', 'Weekly');
      expect(find.byKey(const ValueKey('schedule-window-calendar')), findsNothing, reason: 'no day choice off a daily run');
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('schedule-save')));
      final body = _lastBody(api);
      expect(body['window_mode'], 'calendar');
      expect(body['frequency'], 'weekly');
      expect(body['weekday'], 1);
      expect(body['report_keys'], ['sales_summary', 'settlement_summary', 'gst']);
    });

    testWidgets('an email schedule needs an address; the refusal is on the form, nothing is sent', (tester) async {
      final api = await _mount(tester, _routes());
      await _tap(tester, find.byKey(const ValueKey('email-new-schedule')));
      await tester.enterText(find.byKey(const ValueKey('schedule-name')), 'Nobody');
      await _tap(tester, find.byKey(const ValueKey('schedule-save')));
      expect(find.byKey(const ValueKey('schedule-error')), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('a 2.0.1 inbox schedule opens as the single calendar-day CSV it always was', (tester) async {
      final api = await _mount(
        tester,
        _routes(schedules: [_schedule('s3', 'Month-end GST', 'monthly', reportKey: 'gst', hour: 9, minute: 7, dayOfMonth: 3)]),
      );
      await _menu(tester, 'Month-end GST', 'Edit');
      expect(tester.takeException(), isNull);
      expect(find.text('Edit schedule'), findsOneWidget);
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-report-gst'))).selected, isTrue);
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-format-csv'))).selected, isTrue);
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-format-xlsx'))).selected, isFalse);
      expect(find.text('Covers the whole previous calendar month. Restaurant time (Asia/Kolkata).'), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('schedule-save')));
      expect(api.writes, ['PATCH /reports/schedules/s3']);
      expect(_lastBody(api), {
        'name': 'Month-end GST',
        'report_keys': ['gst'],
        'formats': ['csv'],
        'frequency': 'monthly',
        'hour_local': 9,
        'minute_local': 7,
        'weekday': null,
        'day_of_month': 3,
        'window_mode': 'calendar',
        'outlet_scope': 'outlet',
        'channel': 'inbox',
        'enabled': true,
        'recipient_ids': <String>[],
      });
    });

    testWidgets('an edit that does not touch the addresses leaves them alone — even one no longer in the book', (tester) async {
      final api = await _mount(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Nightly close', 'daily',
              reportKeys: ['sales_summary'], formats: ['xlsx'], windowMode: 'trading_day', channel: 'email',
              recipients: ['owner@gaia.test', 'gone@firm.test'], hour: 2),
        ]),
      );
      await _menu(tester, 'Nightly close', 'Edit');
      expect(find.textContaining('Also stored: gone@firm.test'), findsOneWidget);
      await _pick(tester, 'send-at-minute', '03');
      await _tap(tester, find.byKey(const ValueKey('schedule-save')));
      final body = _lastBody(api);
      expect(body.containsKey('recipient_ids'), isFalse);
      expect(body['minute_local'], 3);
      expect(body['window_mode'], 'trading_day');
    });

    testWidgets('mail off: email is not offered for a new schedule, and Run now waits on an email one', (tester) async {
      final api = await _mount(
        tester,
        _routes(
          config: {'email_available': false, 'schema_ready': true, 'scheduler': {'enabled': false}, 'can_edit_recipients': true},
          schedules: [
            _schedule('s1', 'Nightly close', 'daily',
                reportKeys: ['sales_summary'], formats: ['xlsx'], channel: 'email', recipients: ['owner@gaia.test']),
          ],
        ),
      );
      expect(find.text(kMailOffSentence), findsOneWidget);
      final run = find.descendant(of: _cardOf('Nightly close'), matching: find.text('Run now'));
      await _tap(tester, run);
      expect(api.writes, isEmpty);

      await _tap(tester, find.byKey(const ValueKey('email-new-schedule')));
      expect(find.text('In-app inbox (notification bell)'), findsWidgets, reason: 'a new schedule starts on the inbox');
    });

    testWidgets('reading writes nothing; run-now and pause go to their own routes', (tester) async {
      final api = await _mount(tester, _routes(schedules: [_schedule('s1', 'Morning sales', 'daily')]));
      expect(api.writes, isEmpty, reason: 'opening Email reports must not trigger a report run');
      await _tap(tester, find.descendant(of: _cardOf('Morning sales'), matching: find.text('Run now')));
      expect(api.writes, contains('POST /reports/schedules/s1/run-now'));
      await _menu(tester, 'Morning sales', 'Pause');
      expect(api.writes, contains('PATCH /reports/schedules/s1'));
      expect(_lastBody(api), {'enabled': false});
    });

    testWidgets('delete asks first, and cancelling writes nothing', (tester) async {
      final api = await _mount(tester, _routes(schedules: [_schedule('s1', 'Morning sales', 'daily')]));
      await _menu(tester, 'Morning sales', 'Delete');
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
      final api = await _mount(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'daily'),
          _schedule('s2', 'Weekly P&L', 'weekly', reportKey: 'pnl', weekday: 1),
        ]),
        outlet: 'all',
      );
      expect(find.byKey(const ValueKey('email-new-schedule')), findsNothing);
      expect(find.text('Run now'), findsNothing);
      for (final name in const ['Morning sales', 'Weekly P&L']) {
        expect(find.descendant(of: _cardOf(name), matching: find.byType(PopupMenuButton<String>)), findsNothing);
      }
      expect(find.textContaining('Switch to a single outlet to create, edit, pause, delete or run one.'), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('run now: a refused repeat says the first run is still coming, not that it failed', (tester) async {
      final api = await _mount(
        tester,
        _routes(schedules: [
          _schedule('s1', 'Morning sales', 'daily'),
          _schedule('s2', 'Weekly P&L', 'weekly', reportKey: 'pnl', weekday: 1),
        ]),
        writeErrors: {
          'POST /reports/schedules/s1/run-now': ApiException('This report was just queued — try again in a minute', 409),
          'POST /reports/schedules/s2/run-now': ApiException('Unable to queue this report', 400),
        },
      );
      await _tap(tester, find.descendant(of: _cardOf('Morning sales'), matching: find.text('Run now')));
      expect(api.writes, contains('POST /reports/schedules/s1/run-now'));
      expect(find.textContaining('nothing extra was queued'), findsOneWidget);
      expect(find.textContaining('Queued — its result appears'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tap(tester, find.descendant(of: _cardOf('Weekly P&L'), matching: find.text('Run now')));
      expect(find.textContaining('Unable to queue this report'), findsOneWidget);
    });

    for (final system in DesignSystem.values) {
      testWidgets('nothing overflows on a phone at 1.3x (${system.name})', (tester) async {
        await _mount(
          tester,
          _routes(schedules: [
            _schedule('s1', 'Morning sales report for the whole restaurant', 'daily',
                reportKeys: [for (final r in kEmailableReports) r.key], formats: ['xlsx', 'csv'], channel: 'email',
                recipients: ['owner@gaia.test', 'accounts@firm.test'], lastStatus: 'delivered',
                nextRunAt: '2026-09-18T02:30:00.000Z', nextWindow: {'from': '2026-09-17', 'to': '2026-09-17', 'day_close': null}),
            _schedule('s2', 'Weekly P&L', 'weekly', reportKey: 'pnl', hour: 18, minute: 45, weekday: 3,
                enabled: false, failures: 5, lastStatus: 'failed', lastError: 'Timed out reading bills'),
          ]),
          width: 360,
          scale: 1.3,
          system: system,
        );
        await _reveal(tester, find.text('Weekly P&L'));
        expect(tester.takeException(), isNull, reason: 'the schedules overflowed at 360px / 1.3x');
        await _menu(tester, 'Morning sales report for the whole restaurant', 'Edit');
        expect(tester.takeException(), isNull, reason: 'the editor overflowed at 360px / 1.3x');
      }, variant: _platforms);
    }
  });

  group('Accounting', () {
    testWidgets('says where the schedules went, opens them, and no longer reads them', (tester) async {
      String? label;
      Map<String, dynamic>? target;
      final api = await _mount(tester, _routes(), accounting: true, opened: (l, t) {
        label = l;
        target = t;
      });
      await _reveal(tester, find.byKey(const ValueKey('accounting-open-email-reports')));
      expect(find.text(m.kSchedulesMovedSentence), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('accounting-open-email-reports')));
      expect(label, 'Reports');
      expect(target, {'view': 'email'});
      expect(api.calls.where((c) => c.contains('/reports/schedules') || c.contains('/reports/deliveries')), isEmpty);
      expect(api.writes, isEmpty);
    });
  });
}
