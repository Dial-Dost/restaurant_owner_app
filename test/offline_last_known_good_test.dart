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
import 'package:restaurant_owner_app/widgets/async_view.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// "Cannot reach the server when not connected to Wi-Fi."
///
/// THE MEASURED CAUSE. Every successful write busts the whole tenant's saved
/// GETs, and busting used to DELETE them. That is fine online — the network
/// refills the entry in the same second, so the cost is one skeleton — but a
/// restaurant writes constantly, so an evening of ordinary use ended with the
/// device holding nothing at all. The moment the Wi-Fi dropped, every module
/// had no saved copy and painted "Can't reach the server". Reproduced before
/// the fix: browse three modules (3 entries), take ONE order (0 entries), go
/// offline, open Tables -> error screen.
///
/// THE FIX, and what these tests pin. A bust MARKS an entry superseded instead
/// of deleting it. Nothing about freshness moves: an ordinary read still cannot
/// see a superseded entry, so the online path can still only ever cost one
/// skeleton and can never paint a stale bill. What the kept payload buys is the
/// case the old rule never covered — the network has been tried, it is
/// unreachable, and the choice is no longer skeleton-versus-stale but
/// last-known-good-with-a-date versus a blank screen.
///
/// THE HONESTY RULE runs through all of it: offline data is never presented as
/// live. Anything served this way wears the offline pill, carries the age of
/// the copy, and says when it predates changes the app itself made.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

  /// While true, every request fails the way a dead network does — no HTTP
  /// status, because nothing reached a server.
  bool offline = false;

  /// While set, every request fails with a REAL status. The server ANSWERED,
  /// so it is a refusal, not an outage.
  int? status;

  @override
  Future<LoginResult> login(String r, String u, String p, {String? outletId}) async => LoginResult(
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
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (offline) throw ApiException('Connection refused', null);
    final s = status;
    if (s != null) throw ApiException('Server said no', s);
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (!routes.containsKey(path)) throw ApiException('No fake route for $path', 404);
    final route = routes[path];
    return route is dynamic Function() ? route() : route;
  }

  int get gets => calls.where((c) => c.startsWith('GET ')).length;
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
        visibleLabels: const ['Waitlist', 'Tables'],
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

/// A minimal module in the shape every real one has: an AsyncView over a GET.
Widget _module(RestClient rest, {String path = '/tables'}) =>
    AsyncView<Map<String, dynamic>>(
      load: () => rest.getMap(path),
      builder: (context, data, reload) => Column(children: [
        Text('tables ${data['n']}'),
        TextButton(onPressed: reload, child: const Text('reload')),
      ]),
    );

/// A COMPOSED module — the Overview shape, several GETs stitched into one
/// payload. It is the case where a partial cache would be actively dangerous:
/// a missing endpoint renders as a confident zero.
Widget _composed(RestClient rest) => AsyncView<Map<String, dynamic>>(
      load: () async {
        final a = await rest.getMap('/tables');
        final b = await rest.getMap('/sales').catchError((_) => <String, dynamic>{});
        return {'n': a['n'], 'sales': b['total']};
      },
      builder: (context, data, reload) =>
          Column(children: [Text('tables ${data['n']}'), Text('sales ${data['sales']}')]),
    );

/// Open a module, let its network load land, close it — "the user has seen this
/// screen before", which is the precondition every one of these starts from.
Future<void> _warm(WidgetTester tester, Widget child, String probe) async {
  await tester.pumpWidget(_host(child));
  await tester.pumpAndSettle();
  expect(find.textContaining(probe), findsWidgets, reason: 'warm-up load failed');
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

Iterable<String> _keys(SharedPreferences p) =>
    p.getKeys().where((k) => k.startsWith(GetCache.keyPrefix));

/// Backdate every entry, marker and all, so the age label has something honest
/// to say. Rewrites the stamp only — never the `s` flag, which is the fact
/// under test.
Future<void> _ageCache(Duration by) async {
  final p = await SharedPreferences.getInstance();
  final old = DateTime.now().subtract(by).millisecondsSinceEpoch;
  for (final k in _keys(p).toList()) {
    final e = jsonDecode(p.getString(k)!) as Map;
    final mark = e['s'] == 1 ? ',"s":1' : '';
    await p.setString(k, '{"t":$old$mark,"d":${jsonEncode(e['d'])}}');
  }
}

void main() {
  // --------------------------------------------------------- the store ------

  test('a bust keeps the payload and marks it; only a stale read may see it',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cache = GetCache.instance;
    await cache.write('res-1', 'out-1', '/tables', {'n': 12});

    final fresh = await cache.read('res-1', 'out-1', '/tables');
    expect(fresh!.superseded, isFalse);
    expect(fresh.data, {'n': 12});

    await cache.bustRestaurant('res-1');

    expect(await cache.read('res-1', 'out-1', '/tables'), isNull,
        reason: 'an ordinary read must behave exactly as if the entry were deleted');
    final kept = await cache.read('res-1', 'out-1', '/tables', allowStale: true);
    expect(kept, isNotNull, reason: 'the payload is the offline last resort');
    expect(kept!.data, {'n': 12});
    expect(kept.superseded, isTrue);
    expect(kept.savedAt.isBefore(DateTime.now().add(const Duration(seconds: 1))), isTrue);
  });

  test('a later GET clears the mark, even when the bytes are identical', () async {
    // The unchanged-payload write skip must not apply to a marked entry: the
    // point of that write is to put a confirmed time back on the copy.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cache = GetCache.instance;
    await cache.write('res-1', 'out-1', '/tables', {'n': 12});
    await cache.bustRestaurant('res-1');
    await cache.write('res-1', 'out-1', '/tables', {'n': 12});

    final again = await cache.read('res-1', 'out-1', '/tables');
    expect(again, isNotNull, reason: 'a confirmed copy stayed hidden as superseded');
    expect(again!.superseded, isFalse);
  });

  test('busting one restaurant does not mark another', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cache = GetCache.instance;
    await cache.write('res-1', 'out-1', '/tables', {'n': 1});
    await cache.write('res-2', 'out-1', '/tables', {'n': 2});
    await cache.bustRestaurant('res-1');

    expect(await cache.read('res-1', 'out-1', '/tables'), isNull);
    expect((await cache.read('res-2', 'out-1', '/tables'))!.data, {'n': 2});
  });

  test('junk that cannot be marked is dropped, not left readable', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final p = await SharedPreferences.getInstance();
    await p.setString('${GetCache.keyPrefix}res-1|out-1|/junk', 'not json at all');
    await GetCache.instance.bustRestaurant('res-1');
    expect(p.getString('${GetCache.keyPrefix}res-1|out-1|/junk'), isNull);
    expect(await GetCache.instance.read('res-1', 'out-1', '/junk', allowStale: true), isNull);
  });

  // -------------------------------------------------- the reported bug ------

  testWidgets('THE BUG: an ordinary online write no longer empties the device',
      (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}, '/orders': {'n': 7}, '/menu': {'n': 40}});
    final rest = await _signIn(api);

    // The waiter browses three modules while online.
    for (final path in ['/tables', '/orders', '/menu']) {
      await tester.pumpWidget(_host(_module(rest, path: path)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
    final p = await SharedPreferences.getInstance();
    expect(_keys(p), hasLength(3));

    // They take ONE order. It succeeds — they are still on the Wi-Fi.
    await rest.post('/orders', {'x': 1});
    expect(_keys(p), hasLength(3),
        reason: 'the write emptied the device — this is the reported bug');

    // The Wi-Fi dies. Tables still opens.
    api.offline = true;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(find.text('tables 12'), findsOneWidget);
    expect(find.text(offlineNothingSavedTitle), findsNothing);
  });

  testWidgets('what it shows is labelled offline, dated, and says it is behind',
      (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});
    await _ageCache(const Duration(minutes: 9));

    api.offline = true;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();

    // Present, and never as if it were live: the pill names the outage, dates
    // the copy, and says the copy predates changes this app itself made.
    expect(find.text('tables 12'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('9m ago'), findsOneWidget);
    expect(find.textContaining('before your recent changes'), findsOneWidget);
  });

  testWidgets('a saved copy with no write behind it says only that it is saved',
      (tester) async {
    // The weaker sentence for the weaker claim: nothing has superseded this
    // copy, it is simply the last one the network confirmed.
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await _ageCache(const Duration(minutes: 4));

    api.offline = true;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline — showing saved data'), findsOneWidget);
    expect(find.textContaining('before your recent changes'), findsNothing);
  });

  // ------------------------------------------- the network comes first ------

  testWidgets('ONLINE, a superseded copy is never painted — the skeleton is',
      (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    // The network is merely SLOW, not down. Nothing may fill the gap.
    final gate = Completer<void>();
    api.routes['/tables'] = () async {
      await gate.future;
      return {'n': 99};
    };
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pump();
    await tester.pump();
    expect(find.text('tables 12'), findsNothing,
        reason: 'a copy a write invalidated was painted while the server was reachable');
    expect(find.byType(SkeletonBox), findsWidgets);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('tables 99'), findsOneWidget);
  });

  testWidgets('the network is tried before the saved copy, every time', (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    api.offline = true;
    final before = api.gets;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(api.gets, greaterThan(before),
        reason: 'the saved copy answered without the server ever being asked');
    expect(find.text('tables 12'), findsOneWidget);
  });

  testWidgets('a server that ANSWERS is a refusal, not an outage', (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    api.status = 500;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(find.text('tables 12'), findsNothing,
        reason: 'a 500 was papered over with a stale copy');
    expect(find.text(offlineNothingSavedTitle), findsNothing,
        reason: 'a working router must not be blamed for a server error');
    expect(find.text("Couldn't load this section."), findsOneWidget);
  });

  // ------------------------------------------------ holes stay honest -------

  testWidgets('a composed screen with a HOLE refuses the copy rather than showing zeros',
      (tester) async {
    // Half a saved Overview renders as a confident zero next to a real number.
    // An empty screen that says the line is down beats that.
    final api = _FakeApi({'/tables': {'n': 12}, '/sales': {'total': 5000}});
    final rest = await _signIn(api);
    await _warm(tester, _composed(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    // Drop ONE of the two saved endpoints, leaving the composition incomplete.
    final p = await SharedPreferences.getInstance();
    for (final k in _keys(p).where((k) => k.endsWith('/sales')).toList()) {
      await p.remove(k);
    }

    api.offline = true;
    await tester.pumpWidget(_host(_composed(rest)));
    await tester.pumpAndSettle();
    expect(find.text('tables 12'), findsNothing);
    expect(find.textContaining('sales'), findsNothing);
    expect(find.text(offlineNothingSavedTitle), findsOneWidget);
  });

  testWidgets('with genuinely nothing saved, the screen says what to DO about it',
      (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}})..offline = true;
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();

    expect(find.text(offlineNothingSavedTitle), findsOneWidget);
    expect(find.text("Can't reach the server"), findsNothing,
        reason: 'the old wording named the app\'s problem, not the reader\'s');
    expect(find.textContaining('Wi-Fi'), findsOneWidget);
    expect(find.textContaining('hotspot'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Retry while still offline keeps the copy and the pill', (tester) async {
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    api.offline = true;
    await tester.pumpWidget(_host(_module(rest)));
    await tester.pumpAndSettle();
    expect(find.text('tables 12'), findsOneWidget);

    await tester.tap(find.text('reload'));
    await tester.pumpAndSettle();
    expect(find.text('tables 12'), findsOneWidget,
        reason: 'a failed manual reload threw away the only copy the app had');
    expect(find.textContaining('Offline'), findsOneWidget);

    // Back on the Wi-Fi: the copy is replaced by live data and the pill goes.
    api.offline = false;
    api.routes['/tables'] = {'n': 20};
    await tester.tap(find.text('reload'));
    await tester.pumpAndSettle();
    expect(find.text('tables 20'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  // ------------------------------------------ the hand-rolled screens -------

  testWidgets('a CachePrimedScreen module gets the same last resort (Waitlist)',
      (tester) async {
    _size(tester, 1400, 1000);
    final api = _FakeApi({
      '/waitlist': {
        'entries': [
          {
            'id': 'w1', 'name': 'Asha', 'position': 1, 'party_size': 2,
            'status': 'waiting', 'phone': '9876543210', 'minutes_waiting': 5,
            'pre_order': <Map<String, dynamic>>[], 'party_members': <Map<String, dynamic>>[],
          },
        ],
      },
      '/get-tables': <dynamic>[
        {'table_name': 'T1', 'occupied': false, 'booked': false, 'reserved': false},
      ],
      '/waitlist/pending-preorders': {'entries': <dynamic>[]},
    });
    final rest = await _signIn(api);
    await _warm(tester, m.waitlistModule(rest, rest.auth.profile!), 'Asha');

    // A seat, a call, any write at all — then the Wi-Fi goes.
    await rest.post('/waitlist/w9/call', {});
    api.offline = true;
    await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Asha'), findsWidgets,
        reason: 'the queue the host was working from vanished when the line dropped');
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('Could not load the waitlist'), findsNothing);
    expect(find.text(offlineNothingSavedTitle), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a CachePrimedScreen with nothing saved still shows the actionable copy',
      (tester) async {
    _size(tester, 1400, 1000);
    final api = _FakeApi({})..offline = true;
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.text(offlineNothingSavedTitle), findsOneWidget);
    expect(find.textContaining('Could not load the waitlist'), findsNothing,
        reason: 'a raw ApiException is not something a host can act on');
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // ---------------------------------------------------------- sign-out ------

  testWidgets('signing out still takes the last-known-good copies with it',
      (tester) async {
    // Handing the till over must not leave a readable copy of the business on
    // the device, marked or otherwise.
    final api = _FakeApi({'/tables': {'n': 12}});
    final rest = await _signIn(api);
    await _warm(tester, _module(rest), 'tables 12');
    await rest.post('/orders', {'x': 1});

    await rest.auth.logout();
    expect(await GetCache.instance.read('res-1', 'out-1', '/tables', allowStale: true), isNull);
    final p = await SharedPreferences.getInstance();
    expect(_keys(p), isEmpty);
  });
}
