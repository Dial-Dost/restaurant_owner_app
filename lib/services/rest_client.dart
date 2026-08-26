import 'api_client.dart';
import 'auth_controller.dart';
import 'get_cache.dart';

/// Authenticated REST helper used by the feature modules. Pulls the token from
/// the [AuthController] and signs the caller out on a 401 so the app returns to
/// the login screen instead of showing stale errors.
///
/// It is also the single seam every module's traffic crosses, which is where
/// the offline cache lives: successful GETs are persisted per
/// restaurant+outlet+path ([GetCache]), successful writes bust that
/// restaurant's saved GETs, and a cache-only replay (see [GetCachePolicy])
/// answers from the store without ever touching the network.
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
    try {
      final data =
          await auth.api.request(method, path, token, body, auth.selectedOutletId);
      if (res != null) {
        if (_cacheableGet(method, path)) {
          await GetCache.instance.write(res, _cacheOutlet, path, data);
        } else if (method != 'GET') {
          // Any successful write may invalidate any saved read anywhere in
          // the restaurant (a settle changes /orders, the bill and half of
          // /analytics/* at once), so the whole tenant is busted. Coarse on
          // purpose: the worst case is one skeleton, not a stale bill.
          await GetCache.instance.bustRestaurant(res);
        }
      }
      return data;
    } on ApiException catch (e) {
      // 401 = the session itself is invalid/expired (per the backend contract):
      // clear the stored auth and route back to login with an explanation.
      // A 403 (authenticated but not permitted) must NOT sign the user out.
      if (e.status == 401) await auth.logout(expired: true);
      rethrow;
    }
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
