// ADVERSARIAL VERIFICATION — written by the reviewer, not the author.
//
// The author's fake goes offline by throwing BEFORE it records the call, so its
// whole suite only ever models "the request never arrived". The scenario the
// entire feature was built for is the OTHER one, and it is the one named in the
// first paragraph of migrations/033_idempotency_keys.sql:
//
//   "A POST /orders whose response was lost — Wi-Fi dropped between the write
//    landing and the 201 reaching the till [...] leaves the client with no way
//    to distinguish 'never applied' from 'applied, answer lost'."
//
// So: the server RECEIVES the order, APPLIES it, and the acknowledgement dies on
// the way back. These tests ask what key the client uses when it tries again.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/idempotency.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';

class _Call {
  _Call(this.method, this.path, this.key);
  final String method;
  final String path;
  final String? key;
  @override
  String toString() => '$method $path key=$key';
}

class _LossyApi extends ApiClient {
  /// Every request that REACHED the server and was applied, in order.
  final List<_Call> applied = <_Call>[];

  /// While true, the server applies the write and the ACK is lost on the way
  /// back — a statusless failure at the client, exactly like a timeout.
  bool loseAck = false;

  /// While true, nothing reaches the server at all.
  bool offline = false;

  /// When set, the server answers with this status instead of succeeding.
  int? answerWith;

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
    if (offline) throw ApiException('Connection refused', null);

    // THE SERVER APPLIES IT. This line is the difference between this fake and
    // the author's: the effect happens, and only then does the wire die.
    applied.add(_Call(method, path, IdempotencyScope.key));

    if (loseAck) {
      throw ApiException('Connection closed before full header was received', null);
    }
    final st = answerWith;
    if (st != null) {
      throw ApiException('A request with this Idempotency-Key is still in progress.', st);
    }
    if (method != 'GET') return {'ok': true};
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_LossyApi api) async {
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Future<void> _fresh() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await Outbox.instance.debugReset();
}

const _order = {
  'table': 'T4',
  'items': [
    {'id': 'm1', 'name': 'Dosa', 'price': 120, 'quantity': 2},
  ],
  'total': 240,
};

void main() {
  test(
      'LOST ACK: the order the server already applied is replayed under a '
      'DIFFERENT idempotency key', () async {
    await _fresh();
    final api = _LossyApi();
    final rest = await _signIn(api);

    // 1. The waiter sends the order. The server applies it; the 201 never lands.
    api.loseAck = true;
    Object? thrown;
    try {
      await rest.post('/orders', _order);
    } catch (e) {
      thrown = e;
    }

    // The client believes it never arrived, and queues it.
    expect(thrown, isA<OfflineQueued>());
    expect(api.applied, hasLength(1),
        reason: 'precondition: the server DID apply this order');
    final onlineKey = api.applied.single.key;
    expect(onlineKey, isNotNull,
        reason: 'the online attempt must carry a key or nothing can dedupe it');

    // 2. The line comes back and the queue drains.
    api.loseAck = false;
    final result = await rest.drainOutbox();
    expect(result.sent, 1);

    // 3. What key did the replay carry?
    expect(api.applied, hasLength(2),
        reason: 'precondition: the replay reached the server too');
    final replayKey = api.applied.last.key;

    // THE ASSERTION THAT MATTERS. For the server to collapse these into one
    // order, both attempts must present the SAME key.
    expect(replayKey, equals(onlineKey),
        reason: 'the replay of a write whose ack was lost MUST reuse the key '
            'the original attempt sent, or the server sees two distinct '
            'intents and rings the order twice');
  });

  test('CRASH MID-DRAIN: the entry survives restart and replays under the SAME '
      'key, so the server can collapse it', () async {
    await _fresh();
    final api = _LossyApi();
    final rest = await _signIn(api);

    // Queue an order while the line is down.
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    expect(Outbox.instance.pendingCount, 1);
    final queuedKey = Outbox.instance.entries.single.id;

    // The line returns; the server RECEIVES and applies the replay, and the app
    // is killed before the ack lands — so the entry is never removed from disk.
    api.offline = false;
    api.loseAck = true;
    await rest.drainOutbox();
    expect(api.applied, hasLength(1), reason: 'the server applied it');
    expect(api.applied.single.key, queuedKey);
    expect(Outbox.instance.pendingCount, 1,
        reason: 'unacked work must stay queued, never be dropped');

    // Restart: memory forgets, disk does not.
    await Outbox.instance.debugReset();
    expect(Outbox.instance.pendingCount, 0, reason: 'precondition: memory cleared');
    await rest.ensureOutboxScope();
    expect(Outbox.instance.pendingCount, 1, reason: 'the write survived the kill');

    // It replays under the ORIGINAL key — which is what lets the server return
    // the stored response instead of applying a second order.
    api.loseAck = false;
    await rest.drainOutbox();
    expect(api.applied, hasLength(2));
    expect(api.applied.last.key, equals(queuedKey),
        reason: 'a replay after a crash must reuse the key the server already saw');
    expect(Outbox.instance.pendingCount, 0);
  });

  test('409 CONTRACT: the backend calls 409 retryable, the drain parks it as a '
      'permanent failure', () async {
    await _fresh();
    final api = _LossyApi();
    final rest = await _signIn(api);

    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));

    // The server answers exactly as idempotency.ts does when a previous attempt
    // of this same key is still in flight: 409 + Retry-After + retryable:true.
    api.offline = false;
    api.answerWith = 409;
    await rest.drainOutbox();

    final entry = Outbox.instance.entries.single;
    expect(entry.failed, isFalse,
        reason: 'a 409 means "the same key is still being processed" — it is '
            'transient and the backend marks it retryable:true, so the entry '
            'must stay queued rather than be parked in front of a human');
  });

  test('CONTROL: a write that never reached the server keeps ONE key across '
      'every replay attempt', () async {
    await _fresh();
    final api = _LossyApi();
    final rest = await _signIn(api);

    // Nothing arrives at all — the author's scenario.
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    expect(api.applied, isEmpty);

    api.offline = false;
    await rest.drainOutbox();
    expect(api.applied, hasLength(1));
    final firstKey = api.applied.single.key;
    expect(firstKey, isNotNull);

    // Queue a second one and drain twice to show the key is stable per entry.
    api.offline = true;
    await expectLater(rest.post('/orders', _order), throwsA(isA<OfflineQueued>()));
    api.offline = false;
    await rest.drainOutbox();
    expect(api.applied, hasLength(2));
    expect(api.applied.last.key, isNot(equals(firstKey)),
        reason: 'two genuinely different orders must NOT share a key');
  });
}
