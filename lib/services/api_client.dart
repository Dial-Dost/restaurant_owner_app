import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/profile.dart';
import 'idempotency.dart';

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, [this.status]);
  @override
  String toString() => message;
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
      throw ApiException(_errMsg(data, 'Sign-in failed.'), res.statusCode);
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
      throw ApiException(_errMsg(_decode(res), 'Session expired.'), res.statusCode);
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
    final msg = (decoded is Map && decoded['error'] is String)
        ? decoded['error'] as String
        : 'Request failed (${res.statusCode}).';
    throw ApiException(msg, res.statusCode);
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
    final msg = (decoded is Map && decoded['error'] is String)
        ? decoded['error'] as String
        : 'Request failed (${res.statusCode}).';
    throw ApiException(msg, res.statusCode);
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

  String _errMsg(Map<String, dynamic> data, String fallback) {
    final e = data['error'];
    return (e is String && e.isNotEmpty) ? e : fallback;
  }
}
