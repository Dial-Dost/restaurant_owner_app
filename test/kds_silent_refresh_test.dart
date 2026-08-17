import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/skeleton.dart';
import 'package:restaurant_owner_app/widgets/async_view.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The kitchen board polls every ten seconds and MUST keep doing so — there is no
/// realtime push for the KDS anywhere in the product, so a wall-mounted screen
/// nobody touches has no other way to learn that an order was barked or served.
/// What it must not do is show the refresh. The old tick called the AsyncView's
/// plain reload, which swapped in an unresolved future, so `FutureBuilder` fell out
/// of `done` and the whole board was replaced by the loading skeleton for the
/// length of the round trip — unmounting the ticket list, and with it a cook's
/// scroll position, every ten seconds during service.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// While this is set, a /orders request hangs until the test opens it. A fake
  /// that answers inside the same clock tick is useless here: the whole defect
  /// lives in the FRAMES BETWEEN asking and answering, and with an instant reply
  /// even the broken code never gets to draw one.
  Completer<void>? gate;

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
    if (path == '/orders' && gate != null) await gate!.future;
    if (!routes.containsKey(path)) throw ApiException('No fake route for $path', 404);
    final route = routes[path];
    // A callable route can answer differently per call — which is how a poll that
    // FAILS gets tested without a real network.
    return route is dynamic Function() ? route() : route;
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Kitchen'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Map<String, dynamic> _ticket(int i, {String station = 'Tandoor'}) => {
      'id': 'ord-$i',
      'table': 'T$i',
      'status': 'Preparing',
      'barked_at': '2026-08-01T10:00:00Z',
      'total': 500,
      'timing': {'order': {'started_at': '2026-08-01T10:00:00Z'}, 'items': <String, dynamic>{}},
      'items': [
        {'id': 'i$i-0', 'name': 'Ticket $i item', 'quantity': 2, 'station': station},
      ],
    };

Map<String, dynamic> _kdsRoutes(dynamic orders) => {
      '/orders': orders,
      '/orders/scope': <String, dynamic>{},
      '/restaurant/settings': {'kitchen_sections': ['Tandoor', 'Grill']},
      '/kds/expo': {'tables': <dynamic>[]},
    };

/// A phone-ish board: one column, so twenty tickets genuinely scroll.
Future<_FakeApi> _mountKds(WidgetTester tester, Map<String, dynamic> routes,
    {double width = 500, double height = 700}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _FakeApi(routes);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(m.kdsModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Finder _ticketList() => find.byType(ListView);

double _scrollOffset(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: _ticketList(), matching: find.byType(Scrollable)))
    .position
    .pixels;

void main() {
  group('the kitchen board refreshes without showing it', () {
    testWidgets('a poll tick shows no loading state and does not move the scroll',
        (tester) async {
      final api = await _mountKds(tester, _kdsRoutes([for (var i = 0; i < 20; i++) _ticket(i)]));

      expect(find.text('Table T0'), findsOneWidget);
      expect(find.byType(SkeletonBox), findsNothing);

      await tester.drag(_ticketList(), const Offset(0, -400));
      await tester.pumpAndSettle();
      final scrolled = _scrollOffset(tester);
      expect(scrolled, greaterThan(0), reason: 'the board has to be scrolled for this to prove anything');

      // Hold the next /orders open, then tick. These are the frames a cook is
      // looking at while the refetch is in flight — the ones the old code filled
      // with the loading skeleton for as long as the round trip took.
      api.gate = Completer<void>();
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(find.byType(SkeletonBox), findsNothing,
          reason: 'the poll went through the loading state — the board blinked');
      expect(find.text('Table T0'), findsOneWidget,
          reason: 'the tickets were taken off screen mid-service');
      expect(_scrollOffset(tester), scrolled,
          reason: 'the list was remounted, so the cook was thrown back to the top');

      // …and once the refetch has landed, still no blink and still in place.
      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.byType(SkeletonBox), findsNothing);
      expect(_scrollOffset(tester), scrolled);
      expect(find.text('Table T19'), findsOneWidget);
    });

    testWidgets('the selected station filter survives a tick', (tester) async {
      await _mountKds(tester, _kdsRoutes([
        _ticket(1, station: 'Tandoor'),
        _ticket(2, station: 'Grill'),
        _ticket(3, station: 'Grill'),
      ]));

      // The chips are uppercase on the ticket badges, so this hits the filter.
      await tester.tap(find.text('Grill'));
      await tester.pumpAndSettle();
      expect(find.text('Table T1'), findsNothing);
      expect(find.text('Table T2'), findsOneWidget);

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();

      expect(find.text('Table T1'), findsNothing, reason: 'the poll reset the station filter');
      expect(find.text('Table T2'), findsOneWidget);
      expect(find.text('Table T3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The Expo/Pass tab polls the same way, and it used to have a second, nastier
    // problem: the home state kept the DISPOSED ticket view's reload callback and
    // went on calling it every ten seconds, which is a setState on a defunct State.
    // Owning the timer inside the view it refreshes is what makes that impossible.
    testWidgets('switching to Expo leaves no timer firing at the disposed ticket view',
        (tester) async {
      await _mountKds(tester, _kdsRoutes([_ticket(1)]));

      await tester.tap(find.text('Expo / Pass'));
      await tester.pumpAndSettle();
      expect(find.text('No active tables on the pass.'), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'a timer fired against the ticket view after it was disposed');
      }
      expect(find.byType(SkeletonBox), findsNothing);
    });
  });

  // The primitive itself, with futures the test holds open — the only way to
  // observe the in-flight window rather than hoping to catch it.
  group('AsyncView.pollEvery', () {
    Widget host(List<Completer<String>> pending) => MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: AsyncView<String>(
              pollEvery: const Duration(seconds: 10),
              load: () {
                final c = Completer<String>();
                pending.add(c);
                return c.future;
              },
              builder: (context, data, reload) => Column(children: [
                Text(data),
                TextButton(onPressed: reload, child: const Text('reload')),
              ]),
            ),
          ),
        );

    testWidgets('a poll keeps the old data on screen; an explicit reload does not',
        (tester) async {
      final pending = <Completer<String>>[];
      await tester.pumpWidget(host(pending));
      await tester.pump();

      // First load: the skeleton is right, there is nothing else to show yet.
      expect(find.byType(SkeletonBox), findsWidgets);
      pending.last.complete('one');
      await tester.pumpAndSettle();
      expect(find.text('one'), findsOneWidget);

      // Poll: a second request is in flight and the first payload is still up.
      await tester.pump(const Duration(seconds: 11));
      expect(pending.length, 2, reason: 'the poll must still fire — the kitchen needs it');
      expect(pending.last.isCompleted, isFalse);
      expect(find.byType(SkeletonBox), findsNothing);
      expect(find.text('one'), findsOneWidget);
      pending.last.complete('two');
      await tester.pumpAndSettle();
      expect(find.text('two'), findsOneWidget);

      // A reload the user asked for keeps its skeleton: that one is not a surprise.
      await tester.tap(find.text('reload'));
      await tester.pump();
      expect(find.byType(SkeletonBox), findsWidgets);
      pending.last.complete('three');
      await tester.pumpAndSettle();
      expect(find.text('three'), findsOneWidget);
    });

    testWidgets('a poll that fails leaves the good data alone', (tester) async {
      final pending = <Completer<String>>[];
      await tester.pumpWidget(host(pending));
      await tester.pump();
      pending.last.complete('one');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 11));
      pending.last.completeError(Exception('offline for a moment'));
      await tester.pumpAndSettle();

      // No error screen, no blank board — the next tick will try again.
      expect(find.text('one'), findsOneWidget);
      expect(find.textContaining("Couldn't load"), findsNothing);
      expect(find.text('Retry'), findsNothing);

      // And it does recover.
      await tester.pump(const Duration(seconds: 11));
      pending.last.complete('two');
      await tester.pumpAndSettle();
      expect(find.text('two'), findsOneWidget);
    });

    testWidgets('the poll timer dies with the view', (tester) async {
      final pending = <Completer<String>>[];
      await tester.pumpWidget(host(pending));
      await tester.pump();
      pending.last.complete('one');
      await tester.pumpAndSettle();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final before = pending.length;
      await tester.pump(const Duration(seconds: 60));
      // A leaked Timer.periodic would also fail this test at teardown; asserting
      // the request count says WHY.
      expect(pending.length, before);
      expect(tester.takeException(), isNull);
    });
  });
}
