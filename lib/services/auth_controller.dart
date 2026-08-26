import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import 'api_client.dart';
import 'get_cache.dart';

/// Owns the signed-in session: token persistence, profile, and login/logout.
class AuthController extends ChangeNotifier {
  final ApiClient api;
  AuthController({ApiClient? api}) : api = api ?? ApiClient();

  static const _tokenKey = 'owner_token';
  static const _outletKey = 'selected_outlet_id';

  String? _token;
  Profile? _profile;
  String? _selectedOutletId;
  bool _initialized = false;
  bool _busy = false;
  String? _error;
  String? _notice;

  String? get token => _token;
  Profile? get profile => _profile;

  /// The admin/manager-selected active outlet (null = the session's home outlet).
  /// Sent as X-Outlet-Id on every request so the backend scopes to this branch.
  String? get selectedOutletId => _selectedOutletId;

  void selectOutlet(String? outletId) {
    _selectedOutletId = (outletId == null || outletId.isEmpty) ? null : outletId;
    SharedPreferences.getInstance().then((p) {
      if (_selectedOutletId == null) {
        p.remove(_outletKey);
      } else {
        p.setString(_outletKey, _selectedOutletId!);
      }
    });
    notifyListeners();
  }

  bool get initialized => _initialized;
  bool get busy => _busy;
  String? get error => _error;

  /// A one-shot message for the login screen — set when the session ended
  /// involuntarily (a 401 forced sign-out), so the user learns why they are
  /// back at login instead of seeing empty tabs. Read once then cleared via
  /// [consumeNotice].
  String? get notice => _notice;
  void consumeNotice() => _notice = null;

  bool get isAuthenticated => _token != null && _profile != null;

  /// Restore a persisted session on launch (validating it against /auth/me).
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString(_tokenKey);
      if (t != null && t.isNotEmpty) {
        try {
          _profile = await api.me(t);
          _token = t;
          _selectedOutletId = prefs.getString(_outletKey);
        } catch (_) {
          await prefs.remove(_tokenKey);
          _token = null;
          _profile = null;
        }
      }
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<bool> login(String restaurant, String username, String password, {String? outletId}) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final result = await api.login(restaurant.trim(), username.trim(), password, outletId: outletId);
      _token = result.token;
      _profile = result.profile;
      _notice = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Could not reach the server. Please check your connection and try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Ends the session and returns the app to the login screen. [expired] marks
  /// an involuntary sign-out (a 401 from the backend — invalid/expired session)
  /// so the login screen can explain why; a plain user sign-out clears any such
  /// notice.
  Future<void> logout({bool expired = false}) async {
    final t = _token;
    _token = null;
    _profile = null;
    _selectedOutletId = null;
    _error = null;
    _notice = expired ? 'Your session expired — please sign in again.' : null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_outletKey);
    // A voluntary sign-out is the "handing the device over" gesture, so the
    // saved GET cache goes with the token. An EXPIRED session keeps it: the
    // same person is about to sign straight back in, and the warm cache is
    // what makes that reopen instant.
    if (!expired) await GetCache.instance.clearAll();
    if (t != null) await api.logout(t);
  }
}
