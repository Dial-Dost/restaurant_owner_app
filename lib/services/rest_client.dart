import 'dart:async';

import 'api_client.dart';
import 'auth_controller.dart';
import 'get_cache.dart';
import 'idempotency.dart';
import 'outbox.dart';

/// Authenticated REST helper used by the feature modules. Pulls the token from
/// the [AuthController] and signs the caller out on a 401 so the app returns to
/// the login screen instead of showing stale errors.
///
/// It is also the single seam every module's traffic crosses, which is where
/// both halves of offline live:
///   * READS — successful GETs are persisted per restaurant+outlet+path
///     ([GetCache]), successful writes bust that restaurant's saved GETs, and a
///     cache-only replay (see [GetCachePolicy]) answers from the store without
///     ever touching the network;
///   * WRITES — a mutating call that cannot reach the server is appended to the
///     persisted [Outbox] under a client-generated idempotency key and replayed
///     in order when the line returns. There are ~128 write call sites in the
///     modules; putting the queue here is what keeps that number at zero
///     edits, and it is the only place that can hold the ordering invariant.
class RestClient {
  final AuthController auth;
  RestClient(this.auth);

  Future<dynamic> get(String path) => _req('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _req('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _req('PUT', path, body);
  Future<dynamic> patch(String path, [Object? body]) => _req('PATCH', path, body);
  Future<dynamic> delete(String path, [Object? body]) => _req('DELETE', path, body);

  /// The restaurant half of the cache key, or null when there is nothing
  /// stable to key on (then the cache simply stays out of the way).
  String? get _cacheRes {
    final p = auth.profile;
    if (p == null) return null;
    if (p.resId.isNotEmpty) return p.resId;
    if (p.restaurantUsername.isNotEmpty) return p.restaurantUsername;
    return p.restaurantName.isNotEmpty ? p.restaurantName : null;
  }

  /// The outlet half. `home` = the session's own outlet when no explicit
  /// selection exists — switching outlets lands in a different namespace, so
  /// branch A's saved boards can never paint over branch B's.
  String get _cacheOutlet {
    final o = auth.selectedOutletId ?? auth.profile?.outletId ?? '';
    return o.isEmpty ? 'home' : o;
  }

  /// The outbox shares the read cache's scope exactly: branch A's unsent work
  /// must never replay against branch B.
  String? get outboxRes => _cacheRes;
  String get outboxOutlet => _cacheOutlet;

  /// Session/token endpoints are never cached: a saved /auth response could
  /// outlive the session that produced it.
  bool _cacheableGet(String method, String path) =>
      method == 'GET' && !path.startsWith('/auth');

  Future<dynamic> _req(String method, String path, [Object? body]) async {
    final token = auth.token;
    if (token == null) throw ApiException('Not signed in.', 401);
    final res = _cacheRes;
    if (GetCachePolicy.isCacheOnly) {
      // A cache replay must never reach the network — not for a GET the store
      // can't answer, and especially not for a write hiding inside a load
      // closure. The miss is recorded BEFORE throwing because composed loads
      // swallow errors internally (the Overview wraps each GET in catchError):
      // the stamp is how AsyncView learns the replayed payload has holes.
      if (res != null && _cacheableGet(method, path)) {
        final hit = await GetCache.instance.read(res, _cacheOutlet, path);
        if (hit != null) {
          GetCachePolicy.stamp?.recordHit(hit.savedAt);
          return hit.data;
        }
      }
      GetCachePolicy.stamp?.recordMiss();
      throw const CacheMiss();
    }

    final mutating = method != 'GET';
    // With no profile there is nothing to scope a queue to, so the outbox stays
    // out of the way entirely and this behaves exactly as it did before it
    // existed.
    final scoped = mutating && res != null;
    final decision =
        scoped ? OutboxPolicy.decide(method, path) : const OutboxDecision.refuse('');

    // Every mutating request carries a key, online included: a POST that times
    // out after the server applied it is indistinguishable from one that never
    // arrived, and the retry is what would double-apply it.
    //
    // MINTED HERE, ABOVE THE QUEUE CHECK, AND ONE PER LOGICAL WRITE. This is
    // the whole guarantee: whichever way this request ends — sent, queued
    // ahead of time, or queued after the line died mid-flight — it carries the
    // SAME key. Minting a second one at enqueue time would defeat the feature
    // in exactly the case it exists for: the server applies the order, the 201
    // dies on the way back, and a replay under a fresh key is a NEW order to
    // the server. Bill = sum of orders, so the guest is charged twice.
    final key = mutating ? newIdempotencyKey() : null;

    if (scoped && decision.queueable) {
      await Outbox.instance.ensureScope(res, _cacheOutlet);
      // THE ORDERING INVARIANT. While anything is still waiting, a new write
      // joins the back of the queue instead of racing past it — two orders for
      // one table must land in the sequence the waiter took them, and a status
      // change must not arrive before the order it describes. With an empty
      // queue (every online moment) this is a false boolean read and the
      // request goes straight out, unchanged.
      if (Outbox.instance.hasPending) {
        throw await _offlineOutcome(res, method, path, body, decision, key);
      }
    }

    try {
      Future<dynamic> call() =>
          auth.api.request(method, path, token, body, auth.selectedOutletId);
      final data = key == null ? await call() : await IdempotencyScope.run(key, call);
      if (res != null) {
        if (_cacheableGet(method, path)) {
          await GetCache.instance.write(res, _cacheOutlet, path, data);
        } else if (mutating) {
          // Any successful write may invalidate any saved read anywhere in
          // the restaurant (a settle changes /orders, the bill and half of
          // /analytics/* at once), so the whole tenant is busted. Coarse on
          // purpose: the worst case is one skeleton, not a stale bill.
          await GetCache.instance.bustRestaurant(res);
        }
      }
      // A request that completed is proof the line is back. This is the
      // reconnect signal — there is no connectivity plugin in this app, and the
      // screens already poll, so a landed response is both the earliest and the
      // most reliable evidence available. Costs nothing while the queue is
      // empty: `hasPending` is an in-memory list check.
      if (Outbox.instance.hasPending) unawaited(drainOutbox());
      return data;
    } on ApiException catch (e) {
      // 401 = the session itself is invalid/expired (per the backend contract):
      // clear the stored auth and route back to login with an explanation.
      // A 403 (authenticated but not permitted) must NOT sign the user out.
      if (e.status == 401) await auth.logout(expired: true);
      // A status means the server answered — it is a real refusal, not an
      // outage, and it must surface. Only a request with NO status never
      // reached anyone, and only that one is safe to hold: a 5xx may already
      // have been applied.
      if (e.status == null && scoped) {
        throw await _offlineOutcome(res, method, path, body, decision, key);
      }
      rethrow;
    } catch (e) {
      // SocketException / ClientException / TimeoutException — the transport,
      // not the server.
      if (scoped) throw await _offlineOutcome(res, method, path, body, decision, key);
      rethrow;
    }
  }

  /// What an unreachable server means for THIS request: queued (and say so
  /// honestly), or refused because it mints money or a number that only the
  /// server may issue. Returns the exception to throw so the caller keeps a
  /// single `throw` and no unreachable code.
  Future<Object> _offlineOutcome(
    String res,
    String method,
    String path,
    Object? body,
    OutboxDecision decision,
    // The key the online attempt already sent, when there was one. Reusing it
    // is what makes a lost acknowledgement replay as the SAME write instead of
    // a second one; see the minting site in _req.
    String? idemKey,
  ) async {
    if (!decision.queueable) return OfflineUnavailable(decision.refusal);
    final entry = await Outbox.instance.enqueue(
      id: idemKey,
      res: res,
      outlet: _cacheOutlet,
      method: method,
      path: path,
      body: body,
      // The outlet in force when the work was done, not whichever branch is
      // selected when the line returns.
      outletHeader: auth.selectedOutletId,
    );
    return OfflineQueued(entry.id, entry.what);
  }

  /// Loads this session's queue so the pending chip is accurate from launch —
  /// unsent work survives a restart and must be visible before anyone writes
  /// again.
  Future<void> ensureOutboxScope() async {
    final res = _cacheRes;
    if (res == null) return;
    await Outbox.instance.ensureScope(res, _cacheOutlet);
  }

  /// Replays the queue. Deliberately bypasses [_req]: a replayed write must not
  /// be re-queued, must reuse its ORIGINAL key (that is the whole point), and
  /// must go to the outlet it was taken on. The read cache is busted once at
  /// the end so every screen refreshes against what actually landed.
  Future<OutboxDrainResult> drainOutbox() async {
    final res = _cacheRes;
    if (res == null || auth.token == null) {
      return const OutboxDrainResult(OutboxDrainOutcome.signedOut, 0);
    }
    await Outbox.instance.ensureScope(res, _cacheOutlet);
    final result = await Outbox.instance.drain((entry) async {
      final t = auth.token;
      if (t == null) throw ApiException('Not signed in.', 401);
      await IdempotencyScope.run(
        entry.id,
        () => auth.api.request(entry.method, entry.path, t, entry.body, entry.outletHeader),
      );
    });
    if (result.sent > 0) await GetCache.instance.bustRestaurant(res);
    return result;
  }

  /// Authenticated GET returning the raw response body (non-JSON endpoints).
  Future<String> getText(String path) async {
    final token = auth.token;
    if (token == null) throw ApiException('Not signed in.', 401);
    if (GetCachePolicy.isCacheOnly) {
      // Raw-body responses (the Tally XML export) are downloads, not screens —
      // never cached, so a replay can only miss.
      GetCachePolicy.stamp?.recordMiss();
      throw const CacheMiss();
    }
    try {
      return await auth.api.getText(path, token, auth.selectedOutletId);
    } on ApiException catch (e) {
      if (e.status == 401) await auth.logout(expired: true);
      rethrow;
    }
  }

  /// Convenience: GET returning a List (or empty list).
  Future<List<dynamic>> getList(String path) async {
    final data = await get(path);
    return data is List ? data : <dynamic>[];
  }

  /// Convenience: GET returning a Map (or empty map).
  Future<Map<String, dynamic>> getMap(String path) async {
    final data = await get(path);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }
}
