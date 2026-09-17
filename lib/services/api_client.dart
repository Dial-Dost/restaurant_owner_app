import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/profile.dart';
import 'idempotency.dart';

/// A refusal (or failure) the server answered with.
///
/// [message] IS THE SENTENCE A HUMAN IS SHOWN. Every module in this app renders
/// a caught error as `'$e'`, which is [toString], which is this — so the ONE
/// place a refusal can be made to read like an instruction instead of a status
/// code is where the message is built, and that is [ApiException.fromBody].
class ApiException implements Exception {
  /// What to show a person. See [ApiException.fromBody] for where it comes from.
  final String message;
  final int? status;

  /// The server's own `details` sentence, verbatim, when it wrote one — the
  /// rupee value a release would destroy, who may reprint, the permission a
  /// settle needs. Null when the body carried none.
  final String? details;

  /// The server's short `error` token ("Forbidden", "Action not permitted").
  /// Kept SEPARATE from [message] so nothing has to parse the sentence to find
  /// out which refusal it was, and so a caller that wants the machine-readable
  /// half never has to reach for the human-readable one.
  final String? serverError;

  /// The decoded refusal body, whole, for the few refusals a screen ACTS on
  /// rather than only shows — client item 6's `{code: "bill_printed",
  /// next_party_table}` is the first. Null when the body was not JSON.
  final Map? body;

  ApiException(this.message, [this.status, this.details, this.serverError, this.body]);

  /// THE ONE PLACE A NON-2xx BODY BECOMES WORDS.
  ///
  /// THE DEFECT THIS CLOSES. The backend answers a refusal with
  /// `{error: "Forbidden", details: "<a sentence>"}` — "This table has ₹6,351
  /// unpaid…", "A reprint has to be made by a manager, admin — ask one of
  /// them", "Settling a bill requires the 'Close Bill' permission". This client
  /// read `error` and threw the rest away, so a waiter was shown the word
  /// "Forbidden" and walked off to fetch a manager to find out what it meant.
  /// The sentence is the whole point; the status is not.
  ///
  /// THE ORDER, and why each rung is where it is:
  ///
  ///   1. `details` — the sentence the server wrote for this exact refusal.
  ///   2. `error`, but only when it is itself a sentence. A bare HTTP title
  ///      ("Forbidden", "Unauthorized") is a STATUS wearing a word; showing it
  ///      is the defect. "Action not permitted", "Only an admin can …" and
  ///      every other real message still comes through untouched.
  ///   3. the caller's [fallback] ("Sign-in failed."), then a default written
  ///      for the status.
  ///
  /// WHAT IS DELIBERATELY NOT RENDERED. `requiredPermission` is an Action UUID
  /// and `requiredRoles` is a machine list; neither is language. They stay on
  /// the exception (read `details`/`serverError`, or the raw fields server-side)
  /// and never reach a snackbar. The server already names the permission in
  /// WORDS inside `details` where a human needs it.
  factory ApiException.fromBody(Object? decoded, int status, {String? fallback}) {
    final body = decoded is Map ? decoded : const <dynamic, dynamic>{};
    final rawDetails = body['details'];
    final details =
        rawDetails is String && rawDetails.trim().isNotEmpty ? rawDetails.trim() : null;
    final rawError = body['error'];
    final serverError =
        rawError is String && rawError.trim().isNotEmpty ? rawError.trim() : null;
    return ApiException(
      details ??
          (serverError != null && !_isBareHttpTitle(serverError) ? serverError : null) ??
          fallback ??
          _defaultFor(status),
      status,
      details,
      serverError,
      decoded is Map ? decoded : null,
    );
  }

  /// The SERVER'S sentence when it wrote one, else this screen's own line.
  ///
  /// For the handful of places that replace a refusal with bespoke wording
  /// because the generic answer ("You do not have permission for this action")
  /// was useless on that screen. Those lines are still right and still shown —
  /// they just stop overwriting a server that had something more specific to
  /// say, which is the whole defect this class was changed to fix, one level
  /// down.
  String sentenceOr(String fallback) => details ?? fallback;

  @override
  String toString() => message;
}

/// Words that are only ever a restatement of the status line. A body whose
/// `error` is one of these has told a person nothing, so it does not get to be
/// the message when something better exists — and when nothing better exists,
/// [_defaultFor] writes a sentence instead.
bool _isBareHttpTitle(String s) => const {
      'forbidden',
      'unauthorized',
      'bad request',
      'not found',
      'conflict',
      'internal server error',
      'error',
    }.contains(s.toLowerCase());

/// The sane default for a refusal that carried no body at all — a proxy's bare
/// 403, an older backend, a gateway page. Still not "Forbidden".
String _defaultFor(int status) {
  switch (status) {
    case 401:
      return 'Your session is no longer valid. Please sign in again.';
    case 403:
      return 'You do not have permission for this action. Ask an admin to grant it to your role.';
    default:
      return 'Request failed ($status).';
  }
}

class LoginResult {
  final String token;
  final Profile profile;
  LoginResult(this.token, this.profile);
}

/// Thin client for the Restaurant Dash backend (tenant auth surface).
class ApiClient {
  final String? _explicitBaseUrl;
  ApiClient({String? baseUrl}) : _explicitBaseUrl = baseUrl;

  /// Live getter so a runtime server override (login-screen dialog) applies
  /// immediately, without recreating clients or restarting the app.
  String get baseUrl => _explicitBaseUrl ?? AppConfig.backendUrl;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// Public: list the restaurant's outlets so the login screen can offer a
  /// picker. Returns [{id, name}] ordered oldest-first (outlets[0] = default).
  /// Never throws to the UI — any error yields an empty list (login still works
  /// against the default outlet).
  Future<List<Map<String, String>>> fetchOutlets(String restaurant) async {
    try {
      final res = await http.get(
        _u('/auth/outlets?restaurant=${Uri.encodeQueryComponent(restaurant)}'),
      );
      if (res.statusCode != 200) return const [];
      final data = _tryJson(res.body);
      if (data is! Map) return const [];
      final list = data['outlets'];
      if (list is! List) return const [];
      final out = <Map<String, String>>[];
      for (final o in list) {
        if (o is Map) {
          final id = (o['id'] ?? '').toString();
          final name = (o['name'] ?? '').toString();
          if (id.isNotEmpty) out.add({'id': id, 'name': name});
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<LoginResult> login(
    String restaurantName,
    String username,
    String password, {
    String? outletId,
  }) async {
    final res = await http.post(
      _u('/auth/employee-login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'restaurantName': restaurantName,
        'employeeUsername': username,
        'password': password,
        if (outletId != null && outletId.isNotEmpty) 'outletId': outletId,
      }),
    );
    final data = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException.fromBody(data, res.statusCode, fallback: 'Sign-in failed.');
    }
    final token = (data['token'] ?? '').toString();
    if (token.isEmpty) {
      throw ApiException('The server did not return a session token.');
    }
    return LoginResult(token, Profile.fromJson(data));
  }

  /// Public: ask the restaurant's admin to reset this user's password. Always
  /// resolves quietly (the backend never reveals whether the account exists).
  Future<void> forgotPassword(String restaurantName, String username) async {
    try {
      await http.post(
        _u('/auth/forgot-password'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'restaurant': restaurantName, 'username': username}),
      );
    } catch (_) {
      // Best-effort — the user is told to contact their admin regardless.
    }
  }

  Future<Profile> me(String token) async {
    final res = await http.get(
      _u('/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException.fromBody(_decode(res), res.statusCode, fallback: 'Session expired.');
    }
    return Profile.fromJson(_decode(res));
  }

  Future<void> logout(String token) async {
    try {
      await http.post(
        _u('/auth/logout'),
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (_) {
      // Best-effort; the local session is cleared regardless.
    }
  }

  /// Generic authenticated request. Returns decoded JSON (List or Map or null).
  /// Throws [ApiException] with the status on non-2xx (401 signals re-auth).
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    final uri = _u(path);
    // The idempotency key rides on EVERY mutating request, online and queued
    // alike, so a retry the client cannot distinguish from a first attempt (a
    // request that timed out after the server applied it) can be collapsed
    // server-side. Read from the ambient zone, so no caller's signature — and
    // no fake's override — had to change to carry it.
    final idempotencyKey = method == 'GET' ? null : IdempotencyScope.key;
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
      if (outletId != null && outletId.isNotEmpty) 'X-Outlet-Id': outletId,
      'Idempotency-Key': ?idempotencyKey,
    };
    final encoded = body == null ? null : jsonEncode(body);
    http.Response res;
    switch (method) {
      case 'POST':
        res = await http.post(uri, headers: headers, body: encoded);
        break;
      case 'PUT':
        res = await http.put(uri, headers: headers, body: encoded);
        break;
      case 'PATCH':
        res = await http.patch(uri, headers: headers, body: encoded);
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: headers, body: encoded);
        break;
      default:
        res = await http.get(uri, headers: headers);
    }
    final decoded = res.body.isEmpty ? null : _tryJson(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
    // The server's own sentence, where it wrote one. This is the seam every
    // module's error text crosses — see [ApiException.fromBody].
    throw ApiException.fromBody(decoded, res.statusCode);
  }

  /// Authenticated GET that returns the raw response body (for non-JSON
  /// endpoints like the Tally XML export). Throws [ApiException] on non-2xx.
  Future<String> getText(String path, String token, [String? outletId]) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      if (outletId != null && outletId.isNotEmpty) 'X-Outlet-Id': outletId,
    };
    final res = await http.get(_u(path), headers: headers);
    if (res.statusCode >= 200 && res.statusCode < 300) return res.body;
    final decoded = res.body.isEmpty ? null : _tryJson(res.body);
    throw ApiException.fromBody(decoded, res.statusCode);
  }

  dynamic _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.body.isEmpty) return <String, dynamic>{};
    try {
      final d = jsonDecode(res.body);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

}
