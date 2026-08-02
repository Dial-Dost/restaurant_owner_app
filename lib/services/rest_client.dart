import 'api_client.dart';
import 'auth_controller.dart';

/// Authenticated REST helper used by the feature modules. Pulls the token from
/// the [AuthController] and signs the caller out on a 401 so the app returns to
/// the login screen instead of showing stale errors.
class RestClient {
  final AuthController auth;
  RestClient(this.auth);

  Future<dynamic> get(String path) => _req('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _req('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _req('PUT', path, body);
  Future<dynamic> patch(String path, [Object? body]) => _req('PATCH', path, body);
  Future<dynamic> delete(String path, [Object? body]) => _req('DELETE', path, body);

  Future<dynamic> _req(String method, String path, [Object? body]) async {
    final token = auth.token;
    if (token == null) throw ApiException('Not signed in.', 401);
    try {
      return await auth.api.request(method, path, token, body, auth.selectedOutletId);
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
