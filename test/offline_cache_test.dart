import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/get_cache.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/skeleton.dart';
import 'package:restaurant_owner_app/widgets/async_view.dart';

/// The offline cache exists for one owner complaint: "with slow internet the
/// load times are horrible" — every module switch showed a spinner for the
/// length of the round trip. These tests hold the network open (or kill it)
/// and prove the saved copy paints anyway, that writes bust it, that a corrupt
/// store can only ever miss, and that the request-generation guard still
/// discards a slow stale response after a newer one has landed.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  int requests = 0;

  /// While set, every request hangs until the test opens it — the frames in
  /// which a cached paint either happens without the network or doesn't.
  Completer<void>? gate;

  /// While true, every request throws like a dead network.
  bool offline = false;

  /// When set, every request fails with a REAL HTTP status — the server
  /// answered, so it is a refusal and not an outage.
  int? status;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    requests++;
    if (offline) throw ApiException('Connection refused', null);
    final failWith = status;
    if (failWith != null) throw ApiException('Server error', failWith);
    if (gate != null) await gate!.future;
    if (!routes.containsKey(path)) {
      // Writes to unrouted paths succeed generically — the bust tests only
      // need "a successful write happened", not a real endpoint.
      if (method != 'GET') return null;
      throw ApiException('No fake route for $path', 404);
    }
    final route = routes[path];
    return route is dynamic Function() ? route() : route;
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: child),
    );

/// A minimal module: exactly the shape every real module has — an AsyncView
/// over a RestClient GET.
Widget _module(RestClient rest) => AsyncView<Map<String, dynamic>>(
      load: () => rest.getMap('/dishes'),
      builder: (context, data, reload) => Column(children: [
        Text('count ${((data['items'] as List?) ?? const []).length}'),
        TextButton(onPressed: reload, child: const Text('reload')),
      ]),
    );

/// Mount, let the first (network) load land, then unmount — the "user opened
/// this module earlier" precondition every cached-paint test starts from.
Future<void> _warmCache(WidgetTester tester, RestClient rest) async {
  await tester.pumpWidget(_host(_module(rest)));
  await tester.pumpAndSettle();
  expect(find.text('count 2'), findsOneWidget, reason: 'warm-up load failed');
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

Iterable<String> _cacheKeys(SharedPreferences p) =>
    p.getKeys().where((k) => k.startsWith(GetCache.keyPrefix));

/// [_module] as a page long enough to scroll, which is where a remount shows:
/// every row names the payload it was built from, so a row on screen after a
/// refresh proves which data it is showing.
Widget _longModule(RestClient rest, {Duration? pollEvery}) => AsyncView<Map<String, dynamic>>(
      load: () => rest.getMap('/dishes'),
      pollEvery: pollEvery,
      builder: (context, data, reload) {
        final n = ((data['items'] as List?) ?? const []).length;
        return ListView(children: [
          for (var i = 0; i < 60; i++) SizedBox(height: 48, child: Text('row $i of $n')),
        ]);
      },
    );

ScrollPosition _pagePosition(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable)).position;

void main() {
  testWidgets('a revisited module paints the saved copy before the network answers, then updates in place',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);

    // The network now hangs. A spinner here is exactly the reported bug.
    api.gate = Completer<void>();
    api.routes['/dishes'] = {'items': [1, 2, 3]};
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();

    expect(find.text('count 2'), findsOneWidget,
        reason: 'the saved copy did not paint while the network was unanswered');
    expect(find.byType(SkeletonBox), findsNothing,
        reason: 'a module the user has already seen showed the skeleton anyway');
    expect(api.requests, greaterThan(1),
        reason: 'the silent refresh must still have been fired');

    // ...and when the refresh lands, the view updates in place.
    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.text('count 3'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('a successful write busts the saved GETs, so the next open is honest',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);

    await rest.post('/orders/anything', {'x': 1});

    // The invalidation is what an ordinary read SEES. The entry may survive on
    // disk as a last-known-good copy, but nothing on the online path may serve
    // it: that is the "one skeleton, never a stale bill" rule, unchanged.
    expect(await GetCache.instance.read('res-1', 'out-1', '/dishes'), isNull,
        reason: 'a write left a saved GET readable as though it were current');

    // With the cache busted and the network held open, there is nothing to
    // paint from — the skeleton (not a stale copy) is correct here.
    api.gate = Completer<void>();
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();
    expect(find.text('count 2'), findsNothing,
        reason: 'a payload from before the write was painted after it');
    expect(find.byType(SkeletonBox), findsWidgets);

    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.text('count 2'), findsOneWidget);
  });

  testWidgets('auth responses are never written to the store', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/auth/ping': {'ok': true}, '/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await rest.get('/auth/ping');
    await rest.get('/dishes');
    final p = await SharedPreferences.getInstance();
    expect(_cacheKeys(p).where((k) => k.contains('/auth/')), isEmpty,
        reason: 'a session-surface response was persisted');
    expect(_cacheKeys(p).where((k) => k.contains('/dishes')), isNotEmpty,
        reason: 'the control group was not cached, so the auth assertion proves nothing');
  });

  testWidgets('a corrupt store reads as a miss, never a crash', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);

    final p = await SharedPreferences.getInstance();
    expect(_cacheKeys(p), isNotEmpty, reason: 'nothing was cached to corrupt');
    for (final k in _cacheKeys(p).toList()) {
      await p.setString(k, '{definitely not json');
    }

    api.gate = Completer<void>();
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();
    // Miss, not crash: the skeleton path, exactly as if nothing were saved.
    expect(tester.takeException(), isNull);
    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.text('count 2'), findsNothing);

    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.text('count 2'), findsOneWidget);
  });

  testWidgets('offline with a saved copy: the copy stays up behind an offline banner, not an error screen',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);

    api.offline = true;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();

    expect(find.text('count 2'), findsOneWidget,
        reason: 'the saved copy was taken down because the refresh failed');
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.text("Can't reach the server"), findsNothing);
    expect(find.text('Retry'), findsNothing);

    // A manual reload while still offline keeps the copy + banner too — the
    // user asked for fresh, fresh is unreachable, and an error page would
    // throw away the one thing the app still has.
    await tester.tap(find.text('reload'));
    await tester.pumpAndSettle();
    expect(find.text('count 2'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.text("Can't reach the server"), findsNothing);

    // Back online: a reload clears the banner.
    api.offline = false;
    await tester.tap(find.text('reload'));
    await tester.pumpAndSettle();
    expect(find.text('count 2'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('offline with NOTHING saved says what the reader can do about it',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}})..offline = true;
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();

    // "Can't reach the server" named the APP's problem. This names the two
    // things that are in the reader's hands, and the conclusion to draw when
    // neither works.
    expect(find.text(offlineNothingSavedTitle), findsOneWidget);
    expect(find.text("Can't reach the server"), findsNothing);
    expect(find.textContaining('Wi-Fi'), findsOneWidget);
    expect(find.textContaining('hotspot'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a server that ANSWERS still shows its own words, not the offline copy',
      (tester) async {
    // The offline wording and the last-known-good copy are both gated on the
    // line being down. A 500 is a real answer: dressing it up as an outage
    // would send someone to check a router that is working perfectly.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);
    await rest.post('/orders/anything', {'x': 1}); // supersede the saved copy

    api.status = 500;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(find.text(offlineNothingSavedTitle), findsNothing);
    expect(find.text("Couldn't load this section."), findsOneWidget);
    expect(find.text('count 2'), findsNothing,
        reason: 'a superseded copy must never answer for a server that replied');
  });

  testWidgets('an old saved copy labels itself "Updated ... ago" while the refresh is in flight',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);

    // Age the entry five minutes: past the threshold where an unlabelled
    // stale copy could mislead (this is the affordance money screens rely on).
    final p = await SharedPreferences.getInstance();
    final oldMs = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    for (final k in _cacheKeys(p).toList()) {
      final d = (jsonDecode(p.getString(k)!) as Map)['d'];
      await p.setString(k, '{"t":$oldMs,"d":${jsonEncode(d)}}');
    }

    api.gate = Completer<void>();
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();
    expect(find.text('count 2'), findsOneWidget);
    expect(find.textContaining('Updated 5m ago'), findsOneWidget);

    // A landed refresh clears the label — the data on screen is live again.
    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('Updated'), findsNothing);
  });

  // The pill coming or going must not remount what is under it. AsyncView used
  // to return the bare builder output with no pill and a Stack with one, so the
  // moment an old copy's refresh landed the whole list was thrown away and
  // rebuilt at offset 0: a page scrolled down to a section jumped to the top by
  // itself (and undid the Analytics section chips' scroll-back).
  testWidgets('the "Updated" pill clearing leaves the list where it was scrolled', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await _warmCache(tester, rest);
    final p = await SharedPreferences.getInstance();
    final oldMs = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    for (final k in _cacheKeys(p).toList()) {
      final d = (jsonDecode(p.getString(k)!) as Map)['d'];
      await p.setString(k, '{"t":$oldMs,"d":${jsonEncode(d)}}');
    }

    api.gate = Completer<void>();
    api.routes['/dishes'] = {'items': [1, 2, 3]};
    await tester.pumpWidget(_host(_longModule(rest)));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Updated 5m ago'), findsOneWidget, reason: 'precondition: no pill over the copy');
    _pagePosition(tester).jumpTo(900);
    await tester.pump();
    final scrolled = _pagePosition(tester);

    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('Updated'), findsNothing, reason: 'precondition: the refresh never landed');
    expect(find.text('row 20 of 3'), findsOneWidget, reason: 'the live payload did not reach the list');
    expect(_pagePosition(tester).pixels, 900, reason: 'the refresh threw the list back to the top');
    expect(identical(_pagePosition(tester), scrolled), isTrue, reason: 'the list was remounted');
  });

  testWidgets('the offline pill coming and going over a polled list leaves it where it was scrolled',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({'/dishes': {'items': [1, 2]}});
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(_longModule(rest, pollEvery: const Duration(seconds: 10))));
    await tester.pumpAndSettle();
    _pagePosition(tester).jumpTo(900);
    await tester.pump();

    api.offline = true;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.textContaining('Offline'), findsOneWidget, reason: 'precondition: the failed poll showed no pill');
    expect(_pagePosition(tester).pixels, 900, reason: 'the pill appearing threw the list back to the top');

    api.offline = false;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.textContaining('Offline'), findsNothing, reason: 'precondition: the recovered poll kept the pill');
    expect(_pagePosition(tester).pixels, 900, reason: 'the pill clearing threw the list back to the top');

    await tester.pumpWidget(const SizedBox()); // stop the poll
  });

  testWidgets('a slow stale refresh cannot overwrite a newer manual reload (the generation guard holds)',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final answers = <Completer<dynamic>>[];
    final api = _FakeApi({});
    api.routes['/dishes'] = () {
      final c = Completer<dynamic>();
      answers.add(c);
      return c.future;
    };
    final rest = await _signIn(api);

    // First open: no cache yet, plain network load.
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    answers.single.complete({'items': [1]});
    await tester.pumpAndSettle();
    expect(find.text('count 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Reopen: cached paint, with the silent refresh (answers[1]) held open.
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();
    expect(find.text('count 1'), findsOneWidget);
    expect(answers.length, 2, reason: 'the silent refresh never fired');

    // The user reloads; the newer request answers FIRST.
    await tester.tap(find.text('reload'));
    await tester.pump();
    expect(answers.length, 3);
    answers[2].complete({'items': [1, 2, 3]});
    await tester.pumpAndSettle();
    expect(find.text('count 3'), findsOneWidget);

    // Now the OLD refresh finally lands. It must be discarded.
    answers[1].complete({'items': [9, 9]});
    await tester.pumpAndSettle();
    expect(find.text('count 3'), findsOneWidget,
        reason: 'a stale in-flight response overwrote newer data');
    expect(find.text('count 2'), findsNothing);
  });

  test('the store honours its entry cap by evicting, not crashing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    for (var i = 0; i < GetCache.maxEntries + 20; i++) {
      await GetCache.instance.write('res-1', 'out-1', '/p$i', {'i': i});
    }
    final p = await SharedPreferences.getInstance();
    final keys = _cacheKeys(p);
    expect(keys.length, lessThanOrEqualTo(GetCache.maxEntries));
    expect(keys, isNotEmpty);
  });

  test('busting one restaurant leaves another restaurant\'s entries alone', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await GetCache.instance.write('res-1', 'out-1', '/dishes', {'a': 1});
    await GetCache.instance.write('res-2', 'out-1', '/dishes', {'b': 2});
    await GetCache.instance.bustRestaurant('res-1');
    expect(await GetCache.instance.read('res-1', 'out-1', '/dishes'), isNull);
    final other = await GetCache.instance.read('res-2', 'out-1', '/dishes');
    expect(other, isNotNull);
    expect((other!.data as Map)['b'], 2);
  });
}
