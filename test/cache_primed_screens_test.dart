import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/get_cache.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/skeleton.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The owner's follow-up to the offline cache: "waitlist and purchase orders
/// are not being cached i think". They WERE being cached — every GET crosses
/// RestClient — but these screens hand-roll their own loaders instead of
/// AsyncView, so they fed the store and never painted from it. These tests
/// hold the network shut and prove the two named screens now paint their
/// saved copy anyway (via CachePrimedScreen), that the silent refresh lands
/// in place, that the staleness affordances show, and that the generation
/// guard still discards a slow stale refresh.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  /// Path -> static payload, or `dynamic Function()` for per-request control.
  final Map<String, dynamic> routes;

  final List<String> calls = <String>[];

  /// While set, every request hangs until the test opens it.
  Completer<void>? gate;

  /// While true, every request throws like a dead network.
  bool offline = false;

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
    calls.add('$method $path');
    if (offline) throw ApiException('Connection refused', null);
    if (gate != null) await gate!.future;
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (!routes.containsKey(path)) throw ApiException('No fake route for $path', 404);
    final route = routes[path];
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
        openModule: (label, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Waitlist', 'Bookings', 'Purchase Orders', 'Inventory'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _size(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, dynamic> _entry(String id, String name, int position) => <String, dynamic>{
      'id': id,
      'name': name,
      'position': position,
      'party_size': 2,
      'status': 'waiting',
      'phone': '9876543210',
      'minutes_waiting': 5,
      'pre_order': const <Map<String, dynamic>>[],
      'party_members': const <Map<String, dynamic>>[],
    };

Map<String, dynamic> _po(String id, String vendor) => <String, dynamic>{
      'id': id,
      'vendor_name': vendor,
      'status': 'ordered',
      'items': const <Map<String, dynamic>>[],
    };

/// Mount [child], let the first (network) load land, then unmount — the "user
/// opened this module earlier" precondition every cached-paint test starts from.
Future<void> _warm(WidgetTester tester, Widget child, String probe) async {
  await tester.pumpWidget(_host(child));
  await tester.pumpAndSettle();
  expect(find.textContaining(probe), findsWidgets, reason: 'warm-up load failed');
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// Backdate every persisted cache entry so the "Updated Xm ago" affordance has
/// something honest to say.
Future<void> _ageCache(Duration by) async {
  final p = await SharedPreferences.getInstance();
  final oldMs = DateTime.now().subtract(by).millisecondsSinceEpoch;
  for (final k in p.getKeys().where((k) => k.startsWith(GetCache.keyPrefix)).toList()) {
    final d = (jsonDecode(p.getString(k)!) as Map)['d'];
    await p.setString(k, '{"t":$oldMs,"d":${jsonEncode(d)}}');
  }
}

void main() {
  group('waitlist (hand-rolled loader + 10s poll)', () {
    Map<String, dynamic> routes({required List entries}) => <String, dynamic>{
          '/waitlist': {'entries': entries},
          '/get-tables': <dynamic>[
            {'table_name': 'T1', 'occupied': false, 'booked': false, 'reserved': false},
          ],
          '/waitlist/pending-preorders': {'entries': <dynamic>[]},
        };

    testWidgets('paints the saved queue before the network answers, then the refresh lands in place',
        (tester) async {
      _size(tester, 1400, 1000);
      final api = _FakeApi(routes(entries: [_entry('w1', 'Asha', 1), _entry('w2', 'Vikram', 2)]));
      final rest = await _signIn(api);
      await _warm(tester, m.waitlistModule(rest, rest.auth.profile!), 'Asha');

      // The network now hangs; the queue grew while the screen was closed.
      api.gate = Completer<void>();
      api.routes['/waitlist'] = {
        'entries': [_entry('w1', 'Asha', 1), _entry('w2', 'Vikram', 2), _entry('w3', 'Meera', 3)],
      };
      final callsBefore = api.calls.length;
      await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Asha'), findsWidgets,
          reason: 'the saved queue did not paint while the network was unanswered');
      expect(find.textContaining('Vikram'), findsWidgets);
      expect(find.byType(SkeletonBox), findsNothing,
          reason: 'a queue the host has already seen showed the skeleton anyway');
      expect(api.calls.length, greaterThan(callsBefore),
          reason: 'the silent refresh must still have been fired');

      // The refresh lands: the new party appears in place, nothing blinks away.
      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.textContaining('Meera'), findsWidgets);
      expect(find.textContaining('Asha'), findsWidgets);
      expect(find.textContaining('Offline'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('offline: the saved queue stays up behind the offline pill, not an error screen',
        (tester) async {
      _size(tester, 1400, 1000);
      final api = _FakeApi(routes(entries: [_entry('w1', 'Asha', 1)]));
      final rest = await _signIn(api);
      await _warm(tester, m.waitlistModule(rest, rest.auth.profile!), 'Asha');

      api.offline = true;
      await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Asha'), findsWidgets,
          reason: 'the saved queue was taken down because the refresh failed');
      expect(find.textContaining('Offline — showing saved data'), findsOneWidget);
      expect(find.textContaining('Could not load the waitlist'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a slow stale silent refresh cannot overwrite what a newer poll painted (generation guard)',
        (tester) async {
      _size(tester, 1400, 1000);
      final answers = <Completer<dynamic>>[];
      final api = _FakeApi(routes(entries: const []));
      api.routes['/waitlist'] = () {
        final c = Completer<dynamic>();
        answers.add(c);
        return c.future;
      };
      final rest = await _signIn(api);

      // First open: cold store, plain network load (request 0).
      await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
      await tester.pump();
      answers.single.complete({'entries': [_entry('w1', 'Asha', 1)]});
      await tester.pumpAndSettle();
      expect(find.textContaining('Asha'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // Reopen: cached paint, with the silent refresh (request 1) held open.
      await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Asha'), findsWidgets);
      expect(answers.length, 2, reason: 'the silent refresh never fired');

      // The 10s poll fires a NEWER request (2), and it answers first.
      await tester.pump(const Duration(seconds: 10));
      expect(answers.length, 3, reason: 'the poll never fired');
      answers[2].complete({'entries': [_entry('w1', 'Asha', 1), _entry('w3', 'Meera', 2)]});
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Meera'), findsWidgets);

      // Now the OLD silent refresh finally lands. It must be discarded.
      answers[1].complete({'entries': [_entry('w9', 'Junk', 1)]});
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Junk'), findsNothing,
          reason: 'a stale in-flight refresh overwrote newer data');
      expect(find.textContaining('Meera'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('purchase orders (hand-rolled loader)', () {
    Map<String, dynamic> routes({required List orders}) => <String, dynamic>{
          '/purchase-orders': {'orders': orders},
          '/vendors': {'vendors': <dynamic>[]},
          '/inventory': <dynamic>[],
        };

    testWidgets('paints the saved POs before the network answers, then the refresh lands in place',
        (tester) async {
      _size(tester, 1200, 900);
      final api = _FakeApi(routes(orders: [_po('po1', 'Acme Foods')]));
      final rest = await _signIn(api);
      await _warm(tester, m.purchaseOrdersModule(rest, rest.auth.profile!), 'Acme Foods');

      api.gate = Completer<void>();
      api.routes['/purchase-orders'] = {
        'orders': [_po('po1', 'Acme Foods'), _po('po2', 'Bharat Dairy')],
      };
      final callsBefore = api.calls.length;
      await tester.pumpWidget(_host(m.purchaseOrdersModule(rest, rest.auth.profile!)));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Acme Foods'), findsWidgets,
          reason: 'the saved PO list did not paint while the network was unanswered');
      expect(find.byType(SkeletonBox), findsNothing,
          reason: 'a PO list the owner has already seen showed the skeleton anyway');
      expect(api.calls.length, greaterThan(callsBefore),
          reason: 'the silent refresh must still have been fired');

      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.textContaining('Bharat Dairy'), findsWidgets);
      expect(find.textContaining('Acme Foods'), findsWidgets);
      expect(find.textContaining('Offline'), findsNothing);
    });

    testWidgets('an old saved copy labels itself "Updated ... ago" while the refresh is in flight',
        (tester) async {
      _size(tester, 1200, 900);
      final api = _FakeApi(routes(orders: [_po('po1', 'Acme Foods')]));
      final rest = await _signIn(api);
      await _warm(tester, m.purchaseOrdersModule(rest, rest.auth.profile!), 'Acme Foods');
      await _ageCache(const Duration(minutes: 5));

      api.gate = Completer<void>();
      await tester.pumpWidget(_host(m.purchaseOrdersModule(rest, rest.auth.profile!)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Acme Foods'), findsWidgets);
      expect(find.textContaining('Updated 5m ago'), findsOneWidget);

      // The refresh lands: the label clears — the list on screen is live again.
      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.textContaining('Updated'), findsNothing);
    });

    // cacheStaleOverlay had AsyncView's shape swap: bare screen without the pill,
    // a Stack with it. Its clearing remounted the screen's list at offset 0, so
    // an owner scrolled down the POs was thrown to the top when the refresh
    // landed. Same one-tree fix as AsyncView (_StaleFrame).
    testWidgets('the "Updated" pill clearing leaves a scrolled PO list where it was', (tester) async {
      _size(tester, 1200, 600);
      final many = [for (var i = 0; i < 30; i++) _po('po$i', 'Vendor $i')];
      final api = _FakeApi(routes(orders: many));
      final rest = await _signIn(api);
      await _warm(tester, m.purchaseOrdersModule(rest, rest.auth.profile!), 'Vendor 0');
      await _ageCache(const Duration(minutes: 5));

      api.gate = Completer<void>();
      await tester.pumpWidget(_host(m.purchaseOrdersModule(rest, rest.auth.profile!)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Updated 5m ago'), findsOneWidget, reason: 'precondition: no pill over the copy');
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(list.maxScrollExtent, greaterThan(600), reason: 'precondition: the PO list must scroll');
      list.jumpTo(600);
      await tester.pump();

      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.textContaining('Updated'), findsNothing, reason: 'precondition: the refresh never landed');
      final after = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(after.pixels, 600, reason: 'the refresh threw the PO list back to the top');
      expect(identical(after, list), isTrue, reason: 'the PO list was remounted');
    });

    testWidgets('offline: the saved POs stay up behind the offline pill, not an error screen',
        (tester) async {
      _size(tester, 1200, 900);
      final api = _FakeApi(routes(orders: [_po('po1', 'Acme Foods')]));
      final rest = await _signIn(api);
      await _warm(tester, m.purchaseOrdersModule(rest, rest.auth.profile!), 'Acme Foods');

      api.offline = true;
      await tester.pumpWidget(_host(m.purchaseOrdersModule(rest, rest.auth.profile!)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Acme Foods'), findsWidgets);
      expect(find.textContaining('Offline — showing saved data'), findsOneWidget);
      expect(find.textContaining('Could not load purchase orders'), findsNothing);
    });
  });
}
