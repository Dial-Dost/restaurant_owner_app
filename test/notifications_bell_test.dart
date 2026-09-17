import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/notifications_bell.dart';

/// Canned backend. `targets` maps a notification id to the
/// GET /notifications/:id/target answer; a missing entry 404s, which is how the
/// fallback path is exercised.
class _FakeApi extends ApiClient {
  _FakeApi({required this.notifications, this.targets = const {}});
  final List<Map<String, dynamic>> notifications;
  final Map<String, Map<String, dynamic>> targets;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult('t', Profile.fromJson({'role': 'admin', 'actions_set': ['*'], 'action_names': <String>[]}));

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (path == '/notifications') {
      return {
        'notifications': notifications,
        'unread': notifications.where((n) => n['read_at'] == null).length,
      };
    }
    final target = RegExp(r'^/notifications/([^/]+)/target$').firstMatch(path);
    if (target != null) {
      final t = targets[target.group(1)];
      if (t == null) throw ApiException('Notification not found', 404);
      return t;
    }
    if (path.endsWith('/read')) return {'ok': true};
    if (path.startsWith('/notifications/')) return {'ok': true}; // delete
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

void main() {
  // One live-shaped QR-order notification (meta exactly as the backend writes it).
  List<Map<String, dynamic>> notifs() => [
        {
          'id': 'n1',
          'type': 'order',
          'title': 'New order · Table T4',
          'body': 'T4 · 2 items',
          'created_at': '2026-07-26T10:00:00Z',
          'read_at': null,
          'outlet_id': 'a5390f5a',
          'meta': {'table': 'T4', 'order_id': 'ord-2', 'needs_approval': false},
        },
      ];

  Future<void> pumpBell(
    WidgetTester tester,
    RestClient rest, {
    required void Function(String, {Map<String, dynamic>? target}) onOpen,
    void Function(String)? onSwitch,
    List<String> visible = const ['Orders', 'Bookings', 'History'],
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        appBar: AppBar(actions: [
          NotificationsBell(rest: rest, onOpenModule: onOpen, onSwitchOutlet: onSwitch, visibleLabels: visible),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
  }

  // Tears the bell down so its 25s poll timer does not outlive the test.
  Future<void> teardownBell(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  testWidgets('a live notification opens its module AND carries the record id', (tester) async {
    final api = _FakeApi(notifications: notifs(), targets: {
      'n1': {
        'notification_id': 'n1',
        'type': 'order',
        'module': 'Orders',
        'entity': {'type': 'order', 'id': 'ord-2'},
        'still_exists': true,
        'visible_here': true,
        'switch_outlet_id': null,
        'meta': {'table': 'T4', 'order_id': 'ord-2'},
      },
    });
    final rest = await _signIn(api);
    String? openedModule;
    Map<String, dynamic>? openedTarget;

    await pumpBell(tester, rest, onOpen: (label, {Map<String, dynamic>? target}) {
      openedModule = label;
      openedTarget = target;
    });
    await tester.tap(find.text('New order · Table T4'));
    await tester.pumpAndSettle();

    expect(openedModule, 'Orders');
    expect(openedTarget?['entity_id'], 'ord-2');
    expect(openedTarget?['entity_type'], 'order');
    expect(openedTarget?['table'], 'T4'); // meta preserved for table focus
    expect(api.calls, contains('POST /notifications/n1/read'));
    expect(api.calls, contains('GET /notifications/n1/target'));
    await teardownBell(tester);
  });

  testWidgets("a record on another outlet offers Switch outlet, not an empty screen", (tester) async {
    final api = _FakeApi(notifications: notifs(), targets: {
      'n1': {
        'notification_id': 'n1',
        'type': 'order',
        'module': 'Orders',
        'entity': {'type': 'order', 'id': 'ord-2'},
        'outlet_name': 'CSR Organics Main Outlet',
        'still_exists': true,
        'visible_here': false,
        'switch_outlet_id': 'a5390f5a',
        'reason_gone': 'other_outlet',
        'message': 'This is in CSR Organics Main Outlet, not the outlet you are viewing. Switch outlet to open it.',
        'meta': {'table': 'T4', 'order_id': 'ord-2'},
      },
    });
    final rest = await _signIn(api);
    final opened = <String>[];
    final switched = <String>[];

    await pumpBell(tester, rest,
        onOpen: (label, {Map<String, dynamic>? target}) => opened.add(label), onSwitch: switched.add);
    await tester.tap(find.text('New order · Table T4'));
    await tester.pumpAndSettle();

    // Explained, not navigated.
    expect(find.text("Can't open that yet"), findsOneWidget);
    expect(find.textContaining('not the outlet you are viewing'), findsOneWidget);
    expect(opened, isEmpty);

    await tester.tap(find.text('Switch outlet'));
    await tester.pumpAndSettle();
    expect(switched, ['a5390f5a']);
    expect(opened, ['Orders']); // and then it lands on the record
    await teardownBell(tester);
  });

  testWidgets('a deleted record says so and can be cleared', (tester) async {
    final api = _FakeApi(notifications: notifs(), targets: {
      'n1': {
        'notification_id': 'n1',
        'type': 'order',
        'module': 'Orders',
        'entity': {'type': 'order', 'id': 'ord-2'},
        'still_exists': false,
        'visible_here': false,
        'switch_outlet_id': null,
        'reason_gone': 'deleted',
        'message': 'The record this notification was about no longer exists — it was deleted.',
        'meta': {'order_id': 'ord-2'},
      },
    });
    final rest = await _signIn(api);
    final opened = <String>[];

    await pumpBell(tester, rest, onOpen: (label, {Map<String, dynamic>? target}) => opened.add(label));
    await tester.tap(find.text('New order · Table T4'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no longer exists'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('Clear notification'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('DELETE /notifications/n1'));
    await teardownBell(tester);
  });

  testWidgets('a settled order past the live window points at History', (tester) async {
    final api = _FakeApi(notifications: notifs(), targets: {
      'n1': {
        'notification_id': 'n1',
        'type': 'order',
        'module': 'Orders',
        'entity': {'type': 'order', 'id': 'ord-2'},
        'still_exists': true,
        'visible_here': false,
        'switch_outlet_id': null,
        'reason_gone': 'outside_live_window',
        'message': 'That order is settled and older than the live grid shows — look in History.',
        'meta': {'order_id': 'ord-2'},
      },
    });
    final rest = await _signIn(api);
    final opened = <String>[];

    await pumpBell(tester, rest, onOpen: (label, {Map<String, dynamic>? target}) => opened.add(label));
    await tester.tap(find.text('New order · Table T4'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open History'));
    await tester.pumpAndSettle();
    expect(opened, ['History']);
    await teardownBell(tester);
  });

  testWidgets('resolver unreachable: falls back to the old type -> module jump', (tester) async {
    // No target route registered -> 404, i.e. an older backend or offline.
    final api = _FakeApi(notifications: notifs());
    final rest = await _signIn(api);
    String? openedModule;
    Map<String, dynamic>? openedTarget;

    await pumpBell(tester, rest, onOpen: (label, {Map<String, dynamic>? target}) {
      openedModule = label;
      openedTarget = target;
    });
    await tester.tap(find.text('New order · Table T4'));
    await tester.pumpAndSettle();

    expect(openedModule, 'Orders');
    expect(openedTarget?['order_id'], 'ord-2'); // raw meta still focuses the row
    await teardownBell(tester);
  });

  testWidgets('a report bell opens Reports with the delivery, resolver or not (client item 9)', (tester) async {
    List<Map<String, dynamic>> reportNotifs() => [
          {
            'id': 'r1',
            'type': 'report',
            'title': 'Daily reports sent — Wed 16 Sep (2 recipients)',
            'body': 'Open Reports → Email reports to see where it went and download the files.',
            'created_at': '2026-09-16T20:31:00Z',
            'read_at': null,
            'outlet_id': null,
            'meta': {'module': 'Reports', 'delivery_id': 'd1', 'schedule_id': 's1'},
          },
        ];
    for (final resolver in [true, false]) {
      final api = _FakeApi(notifications: reportNotifs(), targets: {
        if (resolver)
          'r1': {
            'notification_id': 'r1',
            'type': 'report',
            'module': 'Reports',
            'entity': null,
            'still_exists': true,
            'visible_here': true,
            'switch_outlet_id': null,
            'meta': {'module': 'Reports', 'delivery_id': 'd1'},
          },
      });
      final rest = await _signIn(api);
      String? openedModule;
      Map<String, dynamic>? openedTarget;
      await pumpBell(tester, rest, visible: const ['Reports'], onOpen: (label, {Map<String, dynamic>? target}) {
        openedModule = label;
        openedTarget = target;
      });
      await tester.tap(find.textContaining('Daily reports sent'));
      await tester.pumpAndSettle();
      expect(openedModule, 'Reports', reason: resolver ? 'resolved' : 'fallback');
      expect(openedTarget?['delivery_id'], 'd1', reason: 'the Reports module opens Email reports on it');
      await teardownBell(tester);
    }
  });

  testWidgets('"Scheduled email reports are waiting" opens Reports on the Email reports view, resolver or not', (tester) async {
    const meta = {'module': 'Reports', 'view': 'email', 'kind': 'mail_not_configured', 'day': '2026-09-17'};
    List<Map<String, dynamic>> notifs() => [
          {
            'id': 'm1',
            'type': 'report',
            'title': 'Scheduled email reports are waiting',
            'body': 'Email is not set up on this server, so scheduled reports are not being sent.',
            'created_at': '2026-09-17T02:31:00Z',
            'read_at': null,
            'outlet_id': null,
            'meta': meta,
          },
        ];
    for (final resolver in [true, false]) {
      final api = _FakeApi(notifications: notifs(), targets: {
        if (resolver)
          'm1': {
            'notification_id': 'm1',
            'type': 'report',
            'module': 'Reports',
            'entity': null,
            'still_exists': true,
            'visible_here': true,
            'switch_outlet_id': null,
            'meta': meta,
          },
      });
      final rest = await _signIn(api);
      String? openedModule;
      Map<String, dynamic>? openedTarget;
      await pumpBell(tester, rest, visible: const ['Reports'], onOpen: (label, {Map<String, dynamic>? target}) {
        openedModule = label;
        openedTarget = target;
      });
      await tester.tap(find.textContaining('Scheduled email reports are waiting'));
      await tester.pumpAndSettle();
      expect(openedModule, 'Reports', reason: resolver ? 'resolved' : 'fallback');
      expect(openedTarget?['view'], 'email', reason: 'Reports opens Email reports on it, not the report grid');
      await teardownBell(tester);
    }
  });

  testWidgets('a KPI alert opens Analytics with nothing to focus', (tester) async {
    final api = _FakeApi(
      notifications: [
        {
          'id': 'n9',
          'type': 'warning',
          'title': 'APC below target',
          'body': 'Yesterday',
          'created_at': '2026-07-26T10:00:00Z',
          'read_at': '2026-07-26T10:05:00Z',
          'outlet_id': 'a5390f5a',
          'meta': {'alert_key': 'apc_low'},
        }
      ],
      targets: {
        'n9': {
          'notification_id': 'n9',
          'type': 'warning',
          'module': 'Analytics',
          'entity': null,
          'still_exists': true,
          'visible_here': false,
          'switch_outlet_id': null,
          'reason_gone': 'no_target',
          'message': 'This is a restaurant-wide alert, not a single record.',
          'meta': {'alert_key': 'apc_low'},
        },
      },
    );
    final rest = await _signIn(api);
    String? openedModule;
    Map<String, dynamic>? openedTarget;

    await pumpBell(tester, rest,
        onOpen: (label, {Map<String, dynamic>? target}) {
          openedModule = label;
          openedTarget = target;
        },
        visible: const ['Orders', 'Analytics']);
    await tester.tap(find.text('APC below target'));
    await tester.pumpAndSettle();

    expect(openedModule, 'Analytics');
    expect(openedTarget, isNull); // nothing to highlight — and we do not pretend
    await teardownBell(tester);
  });
}
