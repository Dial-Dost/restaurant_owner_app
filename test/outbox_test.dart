import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/get_cache.dart';
import 'package:restaurant_owner_app/services/idempotency.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/outbox_chip.dart';

/// The outbox exists for one shift: the line drops mid-service, the waiter keeps
/// taking orders, and everything they did lands exactly once when it comes back.
///
/// These tests hold the network down and prove (a) the work is saved and SAID to
/// be unsent — never implied to be done, (b) it replays in the order it was
/// taken, under the same key each attempt, (c) a rejection is parked in front of
/// a human instead of vanishing, (d) a bill settlement is refused rather than
/// quietly queued, and (e) with a live connection none of it is observable.

class _Call {
  _Call(this.method, this.path, this.body, this.outletId, this.idempotencyKey);
  final String method;
  final String path;
  final Object? body;
  final String? outletId;
  final String? idempotencyKey;
  @override
  String toString() => '$method $path';
}

class _FakeApi extends ApiClient {
  _FakeApi([Map<String, dynamic>? routes]) : routes = routes ?? <String, dynamic>{};
  final Map<String, dynamic> routes;

  /// Every request that actually reached "the server", in order.
  final List<_Call> calls = <_Call>[];

  /// While true, every request fails the way a dead line fails: no status.
  bool offline = false;

  /// path -> status to answer with instead of success (a real server refusal).
  final Map<String, int> failWith = <String, int>{};

  /// path -> a refusal with the server's own body, decoded by the production
  /// factory ([ApiException.fromBody]) — the words a parked chip will show.
  final Map<String, ({int status, Map<String, dynamic> body})> refuseWith = {};

  /// How many times a path has been answered — lets a test fail once then heal.
  final Map<String, int> hits = <String, int>{};

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
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
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (offline) {
      // A transport failure carries NO status — that is the whole signal the
      // seam keys on, and it is what a SocketException looks like once it has
      // crossed the client.
      throw ApiException('Connection refused', null);
    }
    calls.add(_Call(method, path, body, outletId, IdempotencyScope.key));
    hits[path] = (hits[path] ?? 0) + 1;
    final status = failWith[path];
    if (status != null) throw ApiException('Table already settled', status);
    final refusal = refuseWith[path];
    if (refusal != null) throw ApiException.fromBody(refusal.body, refusal.status);
    if (routes.containsKey(path)) {
      final route = routes[path];
      return route is dynamic Function() ? route() : route;
    }
    if (method != 'GET') return {'ok': true};
    throw ApiException('No fake route for $path', 404);
  }

  List<String> get writeLog => calls
      .where((c) => c.method != 'GET')
      .map((c) => '${c.method} ${c.path}')
      .toList();
}

Future<RestClient> _signIn(_FakeApi api) async {
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Future<void> _fresh([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
  await Outbox.instance.debugReset();
}

Widget _host(Widget child) =>
    MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

/// Mounts, then unmounts, so the chip's replay heartbeat is cancelled in
/// dispose() and no timer outlives the test.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

const _order = {
  'table': 'T4',
  'items': [
    {'id': 'm1', 'name': 'Dosa', 'price': 120, 'quantity': 2},
  ],
  'total': 240,
};

void main() {
  // ---------------------------------------------------------------- queueing --

  test('an order taken with no connection is SAVED, and says it is not sent', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;

    Object? thrown;
    try {
      await rest.post('/orders', _order);
    } catch (e) {
      thrown = e;
    }

    expect(thrown, isA<OfflineQueued>(),
        reason: 'an unreachable server must not look like a successful write');
    // The sentence the waiter actually reads at any of the ~128 call sites.
    expect('$thrown', contains('Saved on this device'));
    expect('$thrown', contains('kitchen has not seen it yet'));

    expect(Outbox.instance.pendingCount, 1);
    final entry = Outbox.instance.entries.single;
    expect(entry.method, 'POST');
    expect(entry.path, '/orders');
    expect(entry.what, 'Order for T4 · 1 item');
    expect(entry.tag, 'table:T4');
    expect(entry.outletHeader, isNull,
        reason: 'no outlet was explicitly selected, so the session default applies');
  });

  test('a queued action survives a restart', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    // Same store, brand-new process: the singleton forgets, the disk does not.
    await Outbox.instance.debugReset();
    expect(Outbox.instance.pendingCount, 0, reason: 'precondition: memory cleared');
    await rest.ensureOutboxScope();
    expect(Outbox.instance.pendingCount, 1);
    expect(Outbox.instance.entries.single.what, 'Order for T4 · 1 item');
  });

  test('nothing overtakes work already waiting, even once the line is back',
      () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);

    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    // The line comes back, but nothing has drained yet. A write that raced past
    // the queue would land BEFORE the order it describes.
    api.offline = false;
    await expectLater(
        rest.patch('/orders/o1/status', {'status': 'Served'}),
        throwsA(isA<OfflineQueued>()));
    expect(api.writeLog, isEmpty,
        reason: 'the second write jumped the queue instead of joining it');
    expect(Outbox.instance.pendingCount, 2);

    await rest.drainOutbox();
    expect(api.writeLog, ['POST /orders', 'PATCH /orders/o1/status']);
  });

  // ------------------------------------------------------------------ replay --

  test('reconnect replays in order, under the original key, and clears',
      () async {
    await _fresh();
    final api = _FakeApi({'/orders': <dynamic>[]});
    final rest = await _signIn(api);

    // Warm a saved GET so the post-replay cache bust is observable.
    await rest.getList('/orders');
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith(GetCache.keyPrefix)), isNotEmpty);

    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    await expectLater(rest.post('/orders', {..._order, 'table': 'T5'}),
        throwsA(isA<OfflineQueued>()));
    await expectLater(rest.patch('/orders/o1/status', {'status': 'Served'}),
        throwsA(isA<OfflineQueued>()));
    final queuedKeys = Outbox.instance.entries.map((e) => e.id).toList();
    expect(queuedKeys, hasLength(3));
    expect(List<String>.from(queuedKeys)..sort(), queuedKeys,
        reason: 'the keys must sort in the order the work was done');

    api.offline = false;
    final result = await rest.drainOutbox();

    expect(result.outcome, OutboxDrainOutcome.drained);
    expect(result.sent, 3);
    expect(api.writeLog,
        ['POST /orders', 'POST /orders', 'PATCH /orders/o1/status']);
    expect(api.calls.where((c) => c.method != 'GET').map((c) => c.idempotencyKey).toList(),
        queuedKeys,
        reason: 'each entry must replay under the key it was queued with');
    expect(Outbox.instance.entries, isEmpty);
    expect(Outbox.instance.pendingCount, 0);

    // The invariant is what an ordinary read SEES, not whether a key survives:
    // the replayed writes moved the server on, so nothing saved may be served
    // as current. The copy itself is kept and marked — that is the offline last
    // resort, and only a read that explicitly asks for a stale one can see it.
    expect(await GetCache.instance.read('res-1', 'out-1', '/orders'), isNull,
        reason: 'a successful replay must invalidate the read cache so screens refresh');
    final kept = await GetCache.instance.read('res-1', 'out-1', '/orders', allowStale: true);
    expect(kept, isNotNull,
        reason: 'the payload must survive as a last-known-good copy for offline');
    expect(kept!.superseded, isTrue, reason: 'and it must be MARKED as behind the server');

    prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith(Outbox.keyPrefix)), isEmpty,
        reason: 'a drained queue must not leave its key on disk');
  });

  test('a replay still down the line keeps everything queued and loses nothing',
      () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    final result = await rest.drainOutbox();
    expect(result.outcome, OutboxDrainOutcome.offline);
    expect(result.sent, 0);
    expect(Outbox.instance.pendingCount, 1);
    expect(Outbox.instance.failedCount, 0);
  });

  test('a retryable 5xx is retried under the SAME key, not re-queued', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    final key = Outbox.instance.entries.single.id;

    api.offline = false;
    api.failWith['/orders'] = 503;
    final first = await rest.drainOutbox();
    expect(first.outcome, OutboxDrainOutcome.retryLater);
    expect(Outbox.instance.pendingCount, 1, reason: 'a 5xx is not permanent');
    expect(Outbox.instance.failedCount, 0);
    expect(Outbox.instance.entries.single.attempts, 1);

    api.failWith.remove('/orders');
    final second = await rest.drainOutbox();
    expect(second.outcome, OutboxDrainOutcome.drained);
    expect(Outbox.instance.entries, isEmpty);
    final keys = api.calls.where((c) => c.method == 'POST').map((c) => c.idempotencyKey);
    expect(keys, everyElement(key),
        reason: 'the retry must be indistinguishable from the first attempt, '
            'or the server applies it twice');
  });

  test('a replay uses the outlet the work was taken on, not the one now selected',
      () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    rest.auth.selectOutlet('branch-a');
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    expect(Outbox.instance.entries.single.outletHeader, 'branch-a');

    // The manager switches branches before the line returns. Branch A's order
    // must neither show up on, nor land on, branch B.
    api.offline = false;
    rest.auth.selectOutlet('branch-b');
    await rest.ensureOutboxScope();
    expect(Outbox.instance.pendingCount, 0,
        reason: "branch B must not see branch A's unsent work");
    expect((await rest.drainOutbox()).sent, 0);

    rest.auth.selectOutlet('branch-a');
    await rest.drainOutbox();
    expect(api.calls.where((c) => c.method == 'POST').single.outletId, 'branch-a');
  });

  testWidgets('the chip follows an outlet switch instead of counting the wrong branch',
      (tester) async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    rest.auth.selectOutlet('branch-a');
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    await tester.pumpWidget(_host(OutboxChip(rest: rest)));
    await tester.pumpAndSettle();
    expect(find.text('1 waiting to send'), findsOneWidget);

    rest.auth.selectOutlet('branch-b');
    await tester.pumpAndSettle();
    expect(find.byType(StatusChip), findsNothing,
        reason: 'a count about a branch the user is not standing in is worse '
            'than no count');

    rest.auth.selectOutlet('branch-a');
    await tester.pumpAndSettle();
    expect(find.text('1 waiting to send'), findsOneWidget);
    await _unmount(tester);
  });

  // ------------------------------------------------------------- hard failure --

  test('a permanent 4xx is parked in front of a human, never dropped', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    await expectLater(rest.patch('/orders/o1/status', {'status': 'Served'}),
        throwsA(isA<OfflineQueued>()));

    api.offline = false;
    api.failWith['/orders'] = 400;
    final result = await rest.drainOutbox();

    expect(result.outcome, OutboxDrainOutcome.blocked);
    expect(result.sent, 0);
    expect(Outbox.instance.entries, hasLength(2),
        reason: 'a rejected action must never be silently discarded');
    final failed = Outbox.instance.entries.firstWhere((e) => e.failed);
    expect(failed.what, 'Order for T4 · 1 item',
        reason: 'the human has to be told WHAT failed, not just that something did');
    expect(failed.failureStatus, 400);
    expect(failed.failureMessage, 'Table already settled',
        reason: "the server's own words, verbatim");
    expect(Outbox.instance.failedCount, 1);
    expect(Outbox.instance.pendingCount, 1,
        reason: 'the drain halts rather than applying later work out of order');

    // And a human can put it back, or throw it away — deliberately, by hand.
    await Outbox.instance.retry(failed.id);
    expect(Outbox.instance.failedCount, 0);
    expect(Outbox.instance.entries.first.attempts, 0);
    await Outbox.instance.discard(failed.id);
    expect(Outbox.instance.entries, hasLength(1));
  });

  // CLIENT ITEM 3 (2.0.2). A waiter's cancel queued offline on an app that still
  // drew the button meets the server's new refusal when the line comes back. It
  // must be PARKED on the first answer — a 403 is not "retry" — with the
  // server's sentence on the chip, so the waiter learns who to ask; and a replay
  // of a cancel that DID land stays a quiet success (the server answers
  // unchanged:true before it judges the role).
  test('a queued waiter cancel refused with cancel_needs_senior is parked with the server\'s words', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(
        rest.patch('/orders/o1/status', {'status': 'Cancelled', 'reason': 'Aaa', 'cancel_kind': 'other'}),
        throwsA(isA<OfflineQueued>()));

    api.offline = false;
    const sentence = 'KOT-3 has gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.';
    api.refuseWith['/orders/o1/status'] = (
      status: 403,
      body: {
        'error': 'Forbidden',
        'code': 'cancel_needs_senior',
        'details': sentence,
        'allowed_roles': ['admin', 'manager', 'cashier', 'captain'],
        'order_id': 'o1',
        'kot_nos': [3],
      },
    );
    final result = await rest.drainOutbox();
    expect(result.outcome, OutboxDrainOutcome.blocked);
    expect(api.writeLog, ['PATCH /orders/o1/status'], reason: 'asked once, not retried');
    final parked = Outbox.instance.entries.single;
    expect(parked.failed, isTrue);
    expect(parked.failureStatus, 403);
    expect(parked.failureMessage, sentence);
  });

  test('a retryable failure is parked once it has spun long enough', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    api.offline = false;
    api.failWith['/orders'] = 500;
    for (var i = 0; i < Outbox.maxAttempts; i++) {
      await rest.drainOutbox();
    }
    expect(Outbox.instance.failedCount, 1,
        reason: 'a 5xx that never heals must stop spinning and face a human');
    expect(Outbox.instance.entries.single.failureStatus, 500);
  });

  test('a 401 during replay blames the session, not the order', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    api.offline = false;
    api.failWith['/orders'] = 401;
    final result = await rest.drainOutbox();
    expect(result.outcome, OutboxDrainOutcome.signedOut);
    expect(Outbox.instance.failedCount, 0,
        reason: 'the order is fine; the token is not — it must survive re-login');
    expect(Outbox.instance.pendingCount, 1);
  });

  // -------------------------------------------------- out of scope: settlement --

  test('settling a bill offline is REFUSED, never queued', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;

    Object? thrown;
    try {
      await rest.post('/bills/order/o1/waiter-confirm-payment', {'method': 'cash'});
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<OfflineUnavailable>());
    expect('$thrown', contains('Billing needs a connection'));
    expect('$thrown', contains('orders are saved'));
    expect(Outbox.instance.entries, isEmpty,
        reason: 'an invoice number cannot be minted on a device — GST expects a '
            'gap-free per-outlet series, so nothing may be queued here');
  });

  test('every bill-number and KOT-number path refuses offline', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;

    // Everything that reaches nextBillNo() or AllocateKotNumber() server-side.
    const minting = <String>[
      '/bills',
      '/bills/replace',
      '/bills/order/o1/waiter-confirm-payment',
      '/bills/order/o1/admin-approve-payment',
      '/bills/order/o1/close',
      '/bills/merge',
      '/bills/split',
      '/bills/discount',
      '/bills/apply-coupon',
      '/bills/refund',
      '/bills/remove-item',
      '/bills/move-item',
      '/bills/item-note',
      '/bills/b1/reopen',
      '/print/bill',
      '/publish/bill',
      '/billing/upload-payment-proof',
      '/billing/change-plan',
      '/payroll/pay',
      '/cash/open',
      '/cash/close',
    ];
    for (final path in minting) {
      await expectLater(rest.post(path, const {'table_name': 'T4'}),
          throwsA(isA<OfflineUnavailable>()),
          reason: '$path must not be queued');
    }
    expect(Outbox.instance.entries, isEmpty);
  });

  test('an ordinary order path is NOT caught by the refusal list', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    for (final path in const ['/orders', '/orders/takeaway', '/occupy-table']) {
      await expectLater(
          rest.post(path, const {'table': 'T4', 'items': []}),
          throwsA(isA<OfflineQueued>()),
          reason: '$path is ordinary state and must keep the shift running');
    }
    expect(Outbox.instance.pendingCount, 3);
  });

  test('a settle ONLINE is untouched — the refusal is an offline-only answer',
      () async {
    await _fresh();
    final api = _FakeApi({'/bills/order/o1/close': {'closed': true}});
    final rest = await _signIn(api);

    final out = await rest.post('/bills/order/o1/close');
    expect(out, {'closed': true});
    expect(api.writeLog, ['POST /bills/order/o1/close']);
    expect(Outbox.instance.entries, isEmpty);
  });

  // ---------------------------------------------------------- corrupt storage --

  test('a corrupt outbox degrades to empty instead of crashing', () async {
    await _fresh(<String, Object>{'${Outbox.keyPrefix}res-1|out-1': 'not json {{{'});
    final api = _FakeApi();
    final rest = await _signIn(api);

    await rest.ensureOutboxScope();
    expect(Outbox.instance.entries, isEmpty);

    // The app must still take an order on top of the wreckage.
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    expect(Outbox.instance.pendingCount, 1);
  });

  test('a parseable store of the wrong shape is dropped, not parsed', () async {
    await _fresh(<String, Object>{'${Outbox.keyPrefix}res-1|out-1': '{"a":1}'});
    final rest = await _signIn(_FakeApi());
    await rest.ensureOutboxScope();
    expect(Outbox.instance.entries, isEmpty);
  });

  test('junk entries are skipped and the good ones survive', () async {
    final good = {
      'i': '01J0000000AAAAAAAAAAAAAAAA',
      'm': 'POST',
      'p': '/orders',
      'b': {'table': 'T9'},
      'w': 'Order for T9 · 1 item',
      'g': 'table:T9',
      'q': 1750000000000,
      'a': 0,
    };
    await _fresh(<String, Object>{
      '${Outbox.keyPrefix}res-1|out-1': jsonEncode([
        good,
        'a bare string',
        {'m': 'POST'}, // no id
        {'i': 'x', 'p': '/orders'}, // no method
        42,
      ]),
    });
    final rest = await _signIn(_FakeApi());
    await rest.ensureOutboxScope();
    expect(Outbox.instance.entries, hasLength(1));
    expect(Outbox.instance.entries.single.what, 'Order for T9 · 1 item');
  });

  test('an older schema version is swept, never read', () async {
    await _fresh(<String, Object>{
      'rd_outbox_v0|res-1|out-1': jsonEncode([
        {'i': '01J0', 'm': 'POST', 'p': '/orders'}
      ]),
    });
    final rest = await _signIn(_FakeApi());
    await rest.ensureOutboxScope();
    expect(Outbox.instance.entries, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('rd_outbox_')), isEmpty);
  });

  test('a full outbox refuses new work rather than evicting it', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    for (var i = 0; i < Outbox.maxEntries; i++) {
      await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    }
    // Evicting the oldest here would be silent loss of a real order.
    await expectLater(rest.post('/orders', _order),
        throwsA(isA<OfflineUnavailable>()));
    expect(Outbox.instance.entries, hasLength(Outbox.maxEntries));
  });

  // ------------------------------------------------------------- online path --

  test('ONLINE: a write goes straight out, once, and leaves no trace behind',
      () async {
    await _fresh();
    final api = _FakeApi({'/orders': {'id': 'srv-1'}});
    final rest = await _signIn(api);

    final out = await rest.post('/orders', _order);

    expect(out, {'id': 'srv-1'}, reason: "the server's answer, unaltered");
    expect(api.calls, hasLength(1), reason: 'no probe, no retry, no extra round trip');
    expect(api.calls.single.method, 'POST');
    expect(api.calls.single.path, '/orders');
    expect(api.calls.single.body, _order, reason: 'the body must be byte-identical');
    expect(Outbox.instance.entries, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith(Outbox.keyPrefix)), isEmpty,
        reason: 'a healthy connection must not write an outbox key at all');
  });

  test('ONLINE: a real server refusal still surfaces as itself', () async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.failWith['/orders'] = 400;

    Object? thrown;
    try {
      await rest.post('/orders', _order);
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<ApiException>());
    expect((thrown as ApiException).status, 400);
    expect(Outbox.instance.entries, isEmpty,
        reason: 'a server that answered is not an outage — queuing it would '
            'replay a write the server may already have applied');
  });

  test('ONLINE: GET caching and write-busting behave exactly as before', () async {
    await _fresh();
    final api = _FakeApi({'/orders': <dynamic>[1, 2]});
    final rest = await _signIn(api);

    await rest.getList('/orders');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith(GetCache.keyPrefix)), hasLength(1));

    await rest.post('/occupy-table', {'table_name': 'T4', 'num_covers': 2});
    // Invalidated for every ordinary read — the online guarantee is unchanged —
    // while the payload stays behind as the offline last resort.
    expect(await GetCache.instance.read('res-1', 'out-1', '/orders'), isNull);
    expect((await GetCache.instance.read('res-1', 'out-1', '/orders', allowStale: true))?.superseded,
        isTrue);
  });

  test('ONLINE: every mutating request carries a key; GETs do not', () async {
    await _fresh();
    final api = _FakeApi({'/orders': <dynamic>[]});
    final rest = await _signIn(api);

    await rest.getList('/orders');
    await rest.post('/orders', _order);
    await rest.patch('/orders/o1/status', {'status': 'Served'});

    final get = api.calls.firstWhere((c) => c.method == 'GET');
    expect(get.idempotencyKey, isNull,
        reason: 'a read has nothing to apply twice');
    for (final c in api.calls.where((c) => c.method != 'GET')) {
      expect(c.idempotencyKey, isNotNull);
      expect(c.idempotencyKey, hasLength(26));
    }
    final keys = api.calls
        .where((c) => c.method != 'GET')
        .map((c) => c.idempotencyKey)
        .toSet();
    expect(keys, hasLength(2), reason: 'two different writes, two different keys');
  });

  // ------------------------------------------------------------ the key itself --

  test('idempotency keys sort by the moment the work was done', () {
    final keys = <String>[];
    for (var i = 0; i < 200; i++) {
      keys.add(newIdempotencyKey());
    }
    expect(keys.toSet(), hasLength(200), reason: 'no collisions');
    expect(keys.every((k) => k.length == 26), isTrue);
    final sorted = List<String>.from(keys)..sort();
    expect(sorted, keys,
        reason: 'the key doubles as the replay order — it must be monotonic '
            'even for two orders taken in the same millisecond');
  });

  test('a key generated later always sorts after an earlier one', () {
    final early = newIdempotencyKey(DateTime.fromMillisecondsSinceEpoch(1000));
    final late_ = newIdempotencyKey(DateTime.fromMillisecondsSinceEpoch(2000));
    expect(early.compareTo(late_), lessThan(0));
  });

  // ------------------------------------------------------------------- the UI --

  testWidgets('the AppBar chip is invisible online and counts unsent work offline',
      (tester) async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(OutboxChip(rest: rest)));
    await tester.pumpAndSettle();
    expect(find.byType(StatusChip), findsNothing,
        reason: 'a restaurant with a good connection must not be able to tell '
            'this shipped');

    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    await expectLater(rest.post('/orders', {..._order, 'table': 'T5'}),
        throwsA(isA<OfflineQueued>()));
    await tester.pumpAndSettle();
    expect(find.text('2 waiting to send'), findsOneWidget);

    // The replay clears it, and the chip goes back to nothing.
    api.offline = false;
    await rest.drainOutbox();
    await tester.pumpAndSettle();
    expect(find.byType(StatusChip), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a blocked action turns the chip red and names itself in the sheet',
      (tester) async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    api.offline = false;
    api.failWith['/orders'] = 400;
    await rest.drainOutbox();

    await tester.pumpWidget(_host(OutboxChip(rest: rest)));
    await tester.pumpAndSettle();
    expect(find.text("1 didn't send"), findsOneWidget);

    await tester.tap(find.byType(StatusChip));
    await tester.pumpAndSettle();
    expect(find.text('Waiting to send'), findsOneWidget);
    expect(find.text('Order for T4 · 1 item'), findsOneWidget,
        reason: 'a failed action must be shown WITH WHAT IT WAS');
    expect(find.textContaining('Server said (400): Table already settled'),
        findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _unmount(tester);
  });

  testWidgets('a table with an unsent order says so on the floor plan',
      (tester) async {
    await _fresh();
    final api = _FakeApi();
    final rest = await _signIn(api);

    await tester.pumpWidget(_host(const OutboxTagBadge(tag: 'table:T4')));
    await tester.pumpAndSettle();
    expect(find.byType(StatusChip), findsNothing);

    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    await tester.pumpAndSettle();
    expect(find.text('Not sent yet'), findsOneWidget);

    // A different table is unaffected — the badge is per-subject, not global.
    await tester.pumpWidget(_host(const OutboxTagBadge(tag: 'table:T9')));
    await tester.pumpAndSettle();
    expect(find.byType(StatusChip), findsNothing);
    await _unmount(tester);
  });
}
