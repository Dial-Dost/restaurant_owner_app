import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/report_email.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/report_export.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// EMAIL REPORTS (client item 9) on the app — Send now from the report pane,
/// and the Email reports view's address book and history.
///
/// Pinned, on Windows AND Android, in the Rustic Fork AND Gaia skins:
///   * the Email button sits beside Export and sends THE REPORT ON SCREEN for
///     THE DAYS ON SCREEN, whole days only, to addresses picked from the book,
///     with the same request id only for a retry of the same choices before a
///     final answer — change the addresses after a failure and it is a NEW send;
///   * a failure the server will retry says "Not sent yet", and the history
///     says when; the history stops refreshing a row after fifteen minutes;
///   * it tells the truth while the server works: it polls the delivery and
///     says what happened to each address, and closes only on a real "Sent";
///   * "Email is not set up on this server" is said, and Send is not offered;
///   * the combined view's scope rides in the BODY and the request goes as a
///     real outlet, because the server refuses writes made "as all";
///   * offline it is refused with the outbox's own sentence, never queued;
///   * the address book is editable only when the SERVER says so; the test
///     email carries a request id; removing asks first;
///   * the history shows one outcome per address and hands over the stored
///     file bytes, not a re-render;
///   * nothing overflows on a 360dp phone at 1.3x.

const _config = <String, dynamic>{
  'email_available': true,
  'transport': 'smtp',
  'message': null,
  'reason': null,
  'schema_ready': true,
  'send_now_enabled': true,
  'scheduler': {'enabled': true, 'armed_here': true},
  'limits': {'recipients_per_send': 10, 'address_book': 25},
  'formats': ['xlsx', 'csv'],
  'reports': <Map<String, dynamic>>[],
  'can_edit_recipients': true,
  'can_use_all_outlets': true,
};

const _book = <String, dynamic>{
  'recipients': [
    {'id': 'r1', 'email': 'owner@gaia.test', 'label': 'Owner', 'status': 'active'},
    {'id': 'r2', 'email': 'accounts@firm.test', 'label': null, 'status': 'active'},
    {'id': 'r3', 'email': 'old@firm.test', 'label': null, 'status': 'suppressed', 'suppressed_reason': 'bounced'},
  ],
  'can_edit': true,
  'max': 25,
};

const _itemWise = <String, dynamic>{
  'meta': {
    'report': 'item_wise',
    'title': 'Item Wise',
    'window': {'from': '2026-09-15', 'to': '2026-09-16', 'days': 2, 'source': 'range', 'clamped': <String>[]},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-09-17T04:00:00.000Z',
    'notes': ['Aggregated by order placement time.'],
  },
  'columns': [
    {'key': 'name', 'label': 'Item', 'type': 'text'},
    {'key': 'qty', 'label': 'Qty', 'type': 'int', 'total': true},
  ],
  'rows': [
    {'name': 'Paneer Tikka', 'qty': 6},
  ],
  'totals': {'qty': 6},
  'page': {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
};

Map<String, dynamic> _delivery(
  String id, {
  String status = 'delivered',
  String kind = 'adhoc',
  List<String> keys = const ['item_wise'],
  List<String>? recipients = const ['owner@gaia.test', 'accounts@firm.test'],
  List<String> sent = const ['owner@gaia.test'],
  List<String> refused = const ['accounts@firm.test'],
  List<Map<String, dynamic>> files = const [],
  String? artifact,
  String? scheduleId,
  String? error,
  bool? isFinal,
  String? nextAttemptAt,
  String createdAt = '2026-09-16T20:30:00.000Z',
}) =>
    {
      'id': id,
      'schedule_id': scheduleId,
      'outlet_id': 'out-1',
      'occurrence_key': kind == 'adhoc' ? 'adhoc:$id' : '2026-09-16',
      'fire_at': '2026-09-16T20:30:00.000Z',
      'period_from': '2026-09-16',
      'period_to': '2026-09-16',
      'timezone': 'Asia/Kolkata',
      'status': status,
      'attempts': 1,
      'channel': kind == 'adhoc' || scheduleId != null ? 'email' : 'inbox',
      'kind': kind,
      'report_keys': keys,
      'formats': ['xlsx'],
      'outlet_scope': 'outlet',
      'day_close': '02:00',
      'window_start_at': '2026-09-15T20:30:00.000Z',
      'window_end_at': '2026-09-16T20:30:00.000Z',
      'recipients': recipients,
      'delivered_to': sent,
      'rejected_to': refused,
      'skipped_to': <String>[],
      'maybe_duplicate': false,
      'artifact_name': artifact,
      'artifact_truncated': false,
      'error': error,
      'files': files,
      'created_at': createdAt,
      'final': ?isFinal,
      'next_attempt_at': nextAttemptAt,
    };

class _Call {
  _Call(this.method, this.path, this.body, this.outlet);
  final String method;
  final String path;
  final Object? body;
  final String? outlet;
  @override
  String toString() => '$method $path';
}

class _FakeApi extends ApiClient {
  _FakeApi({Map<String, dynamic>? routes, Map<String, Object> writeErrors = const {}, this.offline = false})
      : writeErrors = Map<String, Object>.of(writeErrors),
        routes = {
          '/outlets': {
            'outlets': [
              {'id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'is_active': true},
              {'id': 'out-2', 'outlet_name': 'Baner', 'is_active': true},
            ],
          },
          '/reports/mis/item-wise': _itemWise,
          '/reports/email/config': _config,
          '/reports/email/recipients': _book,
          '/reports/schedules': {'schedules': <Map<String, dynamic>>[]},
          '/reports/deliveries': {'deliveries': <Map<String, dynamic>>[]},
          '/reports/deliveries/del-9': {'delivery': _delivery('del-9', recipients: ['owner@gaia.test'], refused: const [])},
          ...?routes,
        };

  final Map<String, dynamic> routes;
  final Map<String, Object> writeErrors;
  final bool offline;
  final List<_Call> calls = <_Call>[];
  final List<String> byteReads = <String>[];
  final List<String> textReads = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add(_Call(method, path, body, outletId));
    if (method != 'GET') {
      if (offline) throw const SocketException('network is unreachable');
      final err = writeErrors['$method $path'];
      if (err != null) {
        // One refusal per call: the retry that follows is answered normally.
        writeErrors.remove('$method $path');
        throw err;
      }
      if (path == '/reports/email/send') return {'delivery_id': 'del-9', 'replayed': false};
      if (path == '/reports/email/test') return {'delivery_id': 'del-t', 'replayed': false};
      return <String, dynamic>{'success': true};
    }
    final base = Uri.parse('http://x$path').path;
    final hit = routes[base];
    if (hit == null) throw ApiException('No fake route for $base', 404);
    return hit;
  }

  @override
  Future<Uint8List> getBytes(String path, String token, [String? outletId]) async {
    byteReads.add(path);
    return Uint8List.fromList([0x50, 0x4b, 0x03, 0x04]);
  }

  @override
  Future<String> getText(String path, String token, [String? outletId]) async {
    textReads.add(path);
    return 'Date,Net\n2026-09-16,100';
  }

  List<_Call> get writes => calls.where((c) => c.method != 'GET').toList();
}

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

Future<RestClient> _mount(
  WidgetTester tester,
  _FakeApi api, {
  double width = 1400,
  double height = 1000,
  double scale = 1.0,
  DesignSystem system = DesignSystem.rustic,
  String? outlet,
  ModuleFocusRequest? focus,
  bool resetMemory = true,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  if (resetMemory) m.misResetReportMemory();
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
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Reports', 'Accounting'],
        clearFocus: () {},
        focus: focus,
        switchOutlet: (_) {},
        child: Scaffold(backgroundColor: Colors.transparent, body: m.reportsModule(rest, auth.profile!)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return rest;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  // The Email reports view is a lazy ListView: bring a row below the fold
  // into the tree first, the way a reader scrolls to it.
  final panel = find.byKey(const ValueKey('email-reports-panel'));
  if (f.evaluate().isEmpty && panel.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(f, 250,
        scrollable: find.descendant(of: panel, matching: find.byType(Scrollable)).first, maxScrolls: 80);
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> _openSend(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('reports-email')));
  expect(find.text('SEND NOW'), findsOneWidget);
}

Future<void> _openArea(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('reports-view')), matching: find.text(kEmailAreaTitle)));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('email-reports-panel')), findsOneWidget);
}

/// Lets the sheet's poll run: it waits [kPollInterval] between reads.
Future<void> _poll(WidgetTester tester) async {
  await tester.pump(kPollInterval);
  await tester.pumpAndSettle();
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  setUp(() async {
    RestaurantTime.adopt(RestaurantTime.defaultZone);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Outbox.instance.debugReset();
  });
  tearDown(() {
    ReportExporter.overrideDeliver = null;
    RestaurantTime.adopt(RestaurantTime.defaultZone);
  });

  group('Send now', () {
    for (final system in DesignSystem.values) {
      testWidgets('the Email button sits beside Export and sends the report and days on screen (${system.name})', (tester) async {
        final api = _FakeApi();
        await _mount(tester, api, system: system);

        final bar = find.ancestor(of: find.byKey(const ValueKey('reports-export')), matching: find.byType(Wrap)).first;
        expect(find.descendant(of: bar, matching: find.byKey(const ValueKey('reports-email'))), findsOneWidget);
        expect(find.byTooltip(kEmailButtonTooltip), findsOneWidget);
        expect(api.writes, isEmpty, reason: 'opening Reports must not send anything');

        await _openSend(tester);
        // The tab on screen is ticked; nothing else is.
        final chip = tester.widget<FilterChip>(find.byKey(const ValueKey('email-report-item_wise')));
        expect(chip.selected, isTrue);
        expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-report-sales_summary'))).selected, isFalse);
        // A suppressed address is not offered.
        expect(find.byKey(const ValueKey('email-to-r3')), findsNothing);

        await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
        await _tap(tester, find.byKey(const ValueKey('email-send')));

        final send = api.writes.single;
        expect('$send', 'POST /reports/email/send');
        final body = send.body as Map;
        expect(body['client_request_id'], matches(_uuid));
        expect(body['report_keys'], ['item_wise']);
        expect(body['formats'], ['xlsx']);
        expect(body['outlet_scope'], 'outlet');
        expect(body['recipient_ids'], ['r1']);
        final window = body['window'] as Map;
        expect(window.keys.toSet(), {'from', 'to'}, reason: 'whole calendar days: no close, and never a session');
        expect('${window['from']}', matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));

        // It polls the delivery and says what happened; a real "Sent" closes it.
        await _poll(tester);
        expect(api.calls.map((c) => '$c'), contains('GET /reports/deliveries/del-9'));
        expect(find.textContaining('Sent to 1 address'), findsOneWidget);
        expect(find.text('SEND NOW'), findsNothing);
      }, variant: _platforms);
    }

    testWidgets('a retry after a failure is the SAME send; a new opening is a new one', (tester) async {
      final api = _FakeApi(writeErrors: {'POST /reports/email/send': ApiException('Upstream timed out', 502)});
      await _mount(tester, api);
      await _openSend(tester);
      await _tap(tester, find.byKey(const ValueKey('email-to-r2')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      expect(find.byKey(const ValueKey('email-send-error')), findsOneWidget);
      expect(find.text('SEND NOW'), findsOneWidget, reason: 'a failed send keeps the sheet open');

      await _tap(tester, find.byKey(const ValueKey('email-send')));
      await _poll(tester);
      final ids = [for (final w in api.writes) (w.body as Map)['client_request_id']];
      expect(ids, hasLength(2));
      expect(ids[0], ids[1], reason: 'the retry must be answered as a replay, not a second email');

      await _openSend(tester);
      await _tap(tester, find.byKey(const ValueKey('email-to-r2')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      await _poll(tester);
      expect((api.writes.last.body as Map)['client_request_id'], isNot(ids[0]));
    });

    for (final system in DesignSystem.values) {
      testWidgets('after a FINAL failure, changing the addresses is a NEW send — never a replay of the old one (${system.name})', (tester) async {
        final api = _FakeApi(routes: {
          '/reports/deliveries/del-9': {
            'delivery': _delivery('del-9', status: 'failed', isFinal: true, recipients: ['owner@gaia.test'], sent: const [],
                refused: const ['owner@gaia.test'], error: 'No address accepted this report: 1 refused by the mail service, 0 skipped.'),
          },
        });
        await _mount(tester, api, system: system);
        await _openSend(tester);
        await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
        await _tap(tester, find.byKey(const ValueKey('email-send')));
        await _poll(tester);
        expect(find.textContaining("Couldn't send. No address accepted this report"), findsOneWidget);
        expect(find.text('SEND NOW'), findsOneWidget, reason: 'a failed send keeps the sheet open');

        // The owner swaps the address and presses Send again.
        await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
        await _tap(tester, find.byKey(const ValueKey('email-to-r2')));
        await _tap(tester, find.byKey(const ValueKey('email-send')));
        await _poll(tester);
        final sends = [for (final w in api.writes) w.body as Map];
        expect(sends, hasLength(2));
        expect(sends[1]['recipient_ids'], ['r2']);
        expect(sends[1]['client_request_id'], matches(_uuid));
        expect(sends[1]['client_request_id'], isNot(sends[0]['client_request_id']),
            reason: 'the same id is answered with the OLD failed delivery, and r2 is never mailed');

        // …and the very same choices after that final answer are sent again, deliberately.
        await _tap(tester, find.byKey(const ValueKey('email-send')));
        await _poll(tester);
        expect(api.writes, hasLength(3));
        expect((api.writes.last.body as Map)['client_request_id'], isNot(sends[1]['client_request_id']));
      }, variant: _platforms);
    }

    testWidgets('a failure the server will retry says "Not sent yet" — and Send again with the same choices is the SAME send', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/deliveries/del-9': {
          'delivery': _delivery('del-9', status: 'failed', isFinal: false, nextAttemptAt: '2026-09-17T20:35:00.000Z',
              recipients: ['owner@gaia.test'], sent: const [], refused: const [], error: '421 4.7.0 try again later'),
        },
      });
      await _mount(tester, api);
      await _openSend(tester);
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      await _poll(tester);
      expect(find.textContaining('Not sent yet. 421 4.7.0 try again later The server tries again at 18 Sep, 02:05.'), findsOneWidget);
      expect(find.textContaining("Couldn't send"), findsNothing);
      // One read was enough: nothing changes before the retry.
      expect(api.calls.where((c) => c.path == '/reports/deliveries/del-9'), hasLength(1));

      await _tap(tester, find.byKey(const ValueKey('email-send')));
      await _poll(tester);
      final ids = [for (final w in api.writes) (w.body as Map)['client_request_id']];
      expect(ids, hasLength(2));
      expect(ids[1], ids[0], reason: 'the server answers it with the same delivery — no second email');
    }, variant: _platforms);

    testWidgets('a closing time and more reports: GST is calendar only, and the close rides in the window', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api);
      await _openSend(tester);
      await _tap(tester, find.byKey(const ValueKey('email-close-switch')));
      // GST cannot be ticked on a trading day, and says why.
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('email-report-gst'))).onSelected, isNull);
      expect(find.text('GST ($kCalendarDaysOnly)'), findsOneWidget);
      await _tap(tester, find.text(kAllMisReports));
      await _tap(tester, find.byKey(const ValueKey('email-format-csv')));
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      final body = api.writes.single.body as Map;
      expect(body['report_keys'], kMisEmailKeys);
      expect(body['formats'], ['xlsx', 'csv']);
      expect(body['window'], containsPair('day_close', '02:00'));
      await _poll(tester);
    });

    testWidgets('mail off: the sheet says so, and Send is not offered', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/email/config': {..._config, 'email_available': false, 'transport': 'off', 'message': kMailOffSentence},
      });
      await _mount(tester, api);
      await _openSend(tester);
      expect(find.byKey(const ValueKey('email-send-blocked')), findsOneWidget);
      expect(find.text(kMailOffSentence), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      expect(api.writes, isEmpty);
    });

    testWidgets('an empty address book: Send is not offered, and the sheet says where to add one', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/email/recipients': {'recipients': <Map<String, dynamic>>[], 'can_edit': true, 'max': 25},
      });
      await _mount(tester, api);
      await _openSend(tester);
      expect(find.byKey(const ValueKey('email-send-empty-book')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      expect(api.writes, isEmpty);
    });

    testWidgets('all outlets: the scope rides in the body, and the request goes as the home outlet', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api, outlet: 'all');
      await _openSend(tester);
      expect(find.textContaining('All outlets (combined) ·'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      final send = api.writes.single;
      expect((send.body as Map)['outlet_scope'], 'all');
      expect(send.outlet, 'out-1', reason: 'the server refuses every write made as "all"');
      // Reads still go as the combined view.
      expect(api.calls.firstWhere((c) => c.path == '/reports/email/config').outlet, 'all');
      await _poll(tester);
    });

    testWidgets('all outlets without the admin/manager right: refused on screen, nothing sent', (tester) async {
      final api = _FakeApi(routes: {'/reports/email/config': {..._config, 'can_use_all_outlets': false}});
      await _mount(tester, api, outlet: 'all');
      await _openSend(tester);
      expect(find.text('All outlets needs an admin or a manager'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      expect(api.writes, isEmpty);
    });

    testWidgets('offline: refused with the outbox\'s sentence, and NEVER queued', (tester) async {
      final api = _FakeApi(offline: true);
      await _mount(tester, api);
      await _openSend(tester);
      await _tap(tester, find.byKey(const ValueKey('email-to-r1')));
      await _tap(tester, find.byKey(const ValueKey('email-send')));
      expect(find.text(OutboxPolicy.unsupported), findsOneWidget);
      expect(Outbox.instance.hasPending, isFalse);
    });
  });

  group('the Email reports view', () {
    testWidgets('mail off: the banner, no test email, and the history still reads', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/email/config': {..._config, 'email_available': false, 'reason': 'SMTP_HOST is not set'},
        '/reports/deliveries': {
          'deliveries': [_delivery('d1')],
        },
      });
      await _mount(tester, api);
      await _openArea(tester);
      expect(find.text(kMailOffSentence), findsOneWidget);
      expect(find.textContaining('(SMTP_HOST is not set)'), findsOneWidget);
      final test = tester.widget<Widget>(find.byKey(const ValueKey('email-test-r1')));
      expect((test as dynamic).onPressed, isNull, reason: 'a test email cannot be sent with no transport');
      expect(find.text('Sent from Reports'), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('the address book is read-only unless the server says otherwise', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/email/config': {..._config, 'can_edit_recipients': false},
      });
      await _mount(tester, api);
      await _openArea(tester);
      expect(find.byKey(const ValueKey('email-book-read-only')), findsOneWidget);
      expect(find.byKey(const ValueKey('email-add-address')), findsNothing);
      expect(find.byKey(const ValueKey('email-test-r1')), findsNothing);
      expect(find.byKey(const ValueKey('email-remove-r1')), findsNothing);
      expect(find.text('owner@gaia.test'), findsOneWidget);
    });

    testWidgets('add, test and remove an address', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api);
      await _openArea(tester);

      // A typo is caught before the server sees it.
      await tester.enterText(find.byKey(const ValueKey('email-add-address')), 'no-at-sign');
      await _tap(tester, find.byKey(const ValueKey('email-add')));
      expect(find.byKey(const ValueKey('email-add-problem')), findsOneWidget);
      expect(api.writes, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('email-add-address')), '  ca@firm.test ');
      await tester.enterText(find.byKey(const ValueKey('email-add-label')), 'Accountant');
      await _tap(tester, find.byKey(const ValueKey('email-add')));
      expect('${api.writes.last}', 'POST /reports/email/recipients');
      expect(api.writes.last.body, {'email': 'ca@firm.test', 'label': 'Accountant'});

      await _tap(tester, find.byKey(const ValueKey('email-test-r1')));
      expect('${api.writes.last}', 'POST /reports/email/test');
      expect((api.writes.last.body as Map)['recipient_id'], 'r1');
      expect((api.writes.last.body as Map)['client_request_id'], matches(_uuid));

      // Removing asks first; cancelling writes nothing.
      final before = api.writes.length;
      await _tap(tester, find.byKey(const ValueKey('email-remove-r2')));
      expect(find.textContaining('every schedule skips it'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(before));
      await _tap(tester, find.byKey(const ValueKey('email-remove-r2')));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect('${api.writes.last}', 'DELETE /reports/email/recipients/r2');
    });

    testWidgets('history: one outcome per address, the stored bytes, and a test email with no files', (tester) async {
      Uint8List? handed;
      String? name;
      ReportExporter.overrideDeliver = (bytes, filename, format) async {
        handed = bytes;
        name = filename;
        return ReportExportResult('Saved $filename');
      };
      final api = _FakeApi(routes: {
        '/reports/schedules': {
          'schedules': [
            {
              'id': 's1', 'outlet_id': 'out-1', 'name': 'Nightly close', 'report_key': 'bundle',
              'report_keys': ['sales_summary', 'settlement_summary'], 'formats': ['xlsx'], 'format': 'xlsx',
              'frequency': 'daily', 'hour_local': 2, 'minute_local': 0, 'weekday': null, 'day_of_month': null,
              'channel': 'email', 'recipients': ['owner@gaia.test'], 'enabled': true, 'window_mode': 'trading_day',
              'outlet_scope': 'outlet', 'consecutive_failures': 0,
            },
          ],
        },
        '/reports/deliveries': {
          'deliveries': [
            _delivery('d1', files: [
              {'id': 'f1', 'report_key': 'bundle', 'format': 'xlsx', 'filename': 'reports_Kalyani-Nagar_2026-09-16_to_2026-09-16_close-0200.xlsx', 'mime': 'x', 'bytes': 48000, 'rows': 3, 'truncated': false, 'purged': false},
              {'id': 'f2', 'report_key': 'item_wise', 'format': 'csv', 'filename': 'item_wise.csv', 'mime': 'text/csv', 'bytes': 10, 'rows': 1, 'truncated': false, 'purged': true},
            ]),
            _delivery('d2', keys: const [], recipients: ['owner@gaia.test'], refused: const []),
            _delivery('d3', kind: 'scheduled', scheduleId: 's1', recipients: null, sent: const [], refused: const [], status: 'sending'),
          ],
        },
      });
      await _mount(tester, api);
      await _openArea(tester);

      expect(find.text('Test email'), findsOneWidget);
      expect(find.text('Nightly close'), findsWidgets);
      expect(find.text('Sending'), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('email-delivery-d1')));
      expect(find.text('Refused'), findsOneWidget);
      expect(find.text('accounts@firm.test'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('email-file-f1')));
      expect(api.byteReads, ['/reports/deliveries/d1/files/f1']);
      expect(handed, isNotNull);
      expect(name, 'reports_Kalyani-Nagar_2026-09-16_to_2026-09-16_close-0200.xlsx');
      // A purged body cannot be downloaded.
      expect((tester.widget<Widget>(find.byKey(const ValueKey('email-file-f2'))) as dynamic).onPressed, isNull);

      await _tap(tester, find.byKey(const ValueKey('email-delivery-d2')));
      expect(find.text('A test email carries no files.'), findsOneWidget);

      // A scheduled row reads its schedule's list: the address is waiting.
      await _tap(tester, find.byKey(const ValueKey('email-delivery-d3')));
      expect(find.text('Waiting'), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('the view is remembered across a remount, but a "Today at a glance" jump lands on its report', (tester) async {
      await _mount(tester, _FakeApi());
      await _openArea(tester);
      // The shell remounts the module (an outlet switch): still the address book.
      await _mount(tester, _FakeApi(), resetMemory: false);
      expect(find.byKey(const ValueKey('email-reports-panel')), findsOneWidget);
      // The glance primes its report (item 10) before the shell remounts it.
      m.misRememberReport('item_wise');
      await _mount(tester, _FakeApi(), resetMemory: false);
      expect(find.byKey(const ValueKey('email-reports-panel')), findsNothing);
      expect(m.misOpenReportKey, 'item_wise');
      // A key the pack does not know changes neither the tab nor the view.
      await _openArea(tester);
      m.misRememberReport('no_such_report');
      await _mount(tester, _FakeApi(), resetMemory: false);
      expect(find.byKey(const ValueKey('email-reports-panel')), findsOneWidget);
    });

    testWidgets('a bell about an emailed report opens the Email reports view', (tester) async {
      final api = _FakeApi();
      await _mount(tester, api,
          focus: const ModuleFocusRequest(moduleLabel: 'Reports', target: {'delivery_id': 'd1'}, serial: 1));
      expect(find.byKey(const ValueKey('email-reports-panel')), findsOneWidget);
    });

    for (final system in DesignSystem.values) {
      testWidgets('"Scheduled email reports are waiting" opens the Email reports view too — it names no delivery (${system.name})', (tester) async {
        for (final target in const <Map<String, dynamic>>[
          {'module': 'Reports', 'view': 'email', 'kind': 'mail_not_configured', 'day': '2026-09-17'},
          // A bell rung before the view was named still says what it is about.
          {'module': 'Reports', 'kind': 'mail_not_configured', 'day': '2026-09-17'},
        ]) {
          await _mount(tester, _FakeApi(), system: system, focus: ModuleFocusRequest(moduleLabel: 'Reports', target: target, serial: 1));
          expect(find.byKey(const ValueKey('email-reports-panel')), findsOneWidget, reason: '$target');
        }
        // …while a Reports focus that names nothing about email stays on the reports.
        await _mount(tester, _FakeApi(), system: system,
            focus: const ModuleFocusRequest(moduleLabel: 'Reports', target: {'module': 'Reports'}, serial: 1));
        expect(find.byKey(const ValueKey('email-reports-panel')), findsNothing);
      }, variant: _platforms);
    }

    testWidgets('history: a failure the server will retry says so, and when; a final one says Failed', (tester) async {
      final api = _FakeApi(routes: {
        '/reports/deliveries': {
          'deliveries': [
            _delivery('d1', status: 'failed', isFinal: false, nextAttemptAt: '2026-09-17T20:35:00.000Z',
                sent: const [], refused: const [], error: '421 try again later'),
            _delivery('d2', status: 'failed', isFinal: true, sent: const [], error: 'No address accepted this report'),
          ],
        },
      });
      await _mount(tester, api);
      await _openArea(tester);
      await _tap(tester, find.byKey(const ValueKey('email-delivery-d2')));
      expect(find.text(kWillRetryLabel), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.byKey(const ValueKey('email-delivery-retry-d1')), findsOneWidget);
      expect(find.text('The server tries again at 18 Sep, 02:05.'), findsOneWidget);
      expect(find.byKey(const ValueKey('email-delivery-retry-d2')), findsNothing);
      expect(api.writes, isEmpty);
    }, variant: _platforms);

    testWidgets('the history refreshes an unfinished row for fifteen minutes, then stops', (tester) async {
      int reads(_FakeApi api) => api.calls.where((c) => c.path.startsWith('/reports/deliveries?')).length;
      Map<String, dynamic> sending(Duration age) => {
            'deliveries': [
              _delivery('d1', status: 'sending', sent: const [], refused: const [],
                  createdAt: DateTime.now().toUtc().subtract(age).toIso8601String()),
            ],
          };

      final stale = _FakeApi(routes: {'/reports/deliveries': sending(const Duration(minutes: 16))});
      await _mount(tester, stale);
      await _openArea(tester);
      final before = reads(stale);
      await tester.pump(kPollInterval * 4);
      await tester.pumpAndSettle();
      expect(reads(stale), before, reason: 'a row that never settles must not re-read the history every six seconds forever');

      final live = _FakeApi(routes: {'/reports/deliveries': sending(const Duration(minutes: 1))});
      await _mount(tester, live);
      await _openArea(tester);
      final start = reads(live);
      await tester.pump(kPollInterval * 4);
      await tester.pumpAndSettle();
      expect(reads(live), greaterThan(start), reason: 'a recent one still turns into "Sent" by itself');
      await tester.pumpWidget(const SizedBox());
    });

  });

  group('phones', () {
    for (final system in DesignSystem.values) {
      for (final width in const [360.0, 400.0]) {
        testWidgets('nothing overflows at ${width.toInt()}dp and 1.3x (${system.name})', (tester) async {
          final api = _FakeApi(routes: {
            '/reports/deliveries': {
              'deliveries': [
                _delivery('d1', files: [
                  {'id': 'f1', 'report_key': 'bundle', 'format': 'xlsx', 'filename': 'a.xlsx', 'mime': 'x', 'bytes': 48000, 'rows': 3, 'truncated': true, 'purged': false},
                ]),
              ],
            },
          });
          await _mount(tester, api, width: width, height: 900, scale: 1.3, system: system);
          await _openSend(tester);
          await tester.drag(find.text('SEND NOW'), const Offset(0, -400));
          await tester.pumpAndSettle();
          await _tap(tester, find.byKey(const ValueKey('email-close-switch')));
          expect(tester.takeException(), isNull, reason: 'the Send sheet overflowed');
          await _tap(tester, find.byKey(const ValueKey('email-send-close')));

          await _openArea(tester);
          await _tap(tester, find.byKey(const ValueKey('email-delivery-d1')));
          expect(tester.takeException(), isNull, reason: 'the Email reports view overflowed');
          await _tap(tester, find.byKey(const ValueKey('email-new-schedule')));
          expect(find.text('New schedule'), findsWidgets);
          expect(tester.takeException(), isNull, reason: 'the schedule editor overflowed');
        }, variant: _platforms);
      }
    }
  });

  group('wiring', () {
    test('the area is reached only from Reports (and the Accounting pointer); writes are online only', () {
      final lib = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
      final users = <String>{};
      for (final f in lib) {
        final src = f.readAsStringSync();
        if (RegExp(r'_EmailReportsPanel\(|_openEmailSend\(').hasMatch(src)) {
          users.add(f.uri.pathSegments.last);
        }
      }
      expect(users, {'reports.dart', 'report_email.dart'});
      final reports = File('lib/screens/reports.dart').readAsStringSync();
      expect(reports, contains("key: const ValueKey('reports-email')"));
      expect(reports, contains('_EmailReportsPanel(rest: widget.rest)'));
      final modules = File('lib/screens/modules.dart').readAsStringSync();
      expect(modules, contains("part 'report_email.dart';"));
      expect(modules, contains('const _ScheduledReportsMovedCard()'));
      expect(modules, isNot(contains("getMap('/reports/schedules')")),
          reason: 'Accounting no longer reads the schedules it no longer shows');
    });
  });
}
