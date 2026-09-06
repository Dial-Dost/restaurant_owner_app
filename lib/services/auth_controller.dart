import 'dart:convert';

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
  /// The last profile this device saw from the server, kept so a launch with no
  /// connection can restore the session instead of signing the user out. Written
  /// on login and on every successful /auth/me; removed only when the SERVER
  /// rejects the token, never merely because it could not be reached.
  static const _profileKey = 'owner_profile';

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

  /// Restore a persisted session on launch, refreshing it against /auth/me when
  /// the server can be reached.
  ///
  /// THE OFFLINE CASE IS THE WHOLE POINT OF THIS METHOD'S SHAPE. It used to wrap
  /// `api.me()` in a bare `catch (_)` that deleted the stored token, which meant
  /// a launch with no connection was indistinguishable from a rejected session:
  /// the app signed the user out, showed the login screen, and login needs the
  /// network too. The read cache and the offline outbox were both unreachable —
  /// not broken, just never given a chance to run, because you could not get
  /// past the front door without a connection.
  ///
  /// So the two failures are now told apart by whether the SERVER ANSWERED:
  ///   * an ApiException carrying a status is the backend saying no (401 = this
  ///     token is dead). Clear it. Staying signed in on a revoked session would
  ///     be a real security hole.
  ///   * anything else — SocketException, TimeoutException, an ApiException with
  ///     a null status — means we never reached anyone. That is not evidence
  ///     about the token, so KEEP it and restore the profile saved beside it.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString(_tokenKey);
      if (t != null && t.isNotEmpty) {
        try {
          final fresh = await api.me(t);
          _profile = fresh;
          _token = t;
          _selectedOutletId = prefs.getString(_outletKey);
          // Refresh the cached copy on every successful launch, so an offline
          // start reflects the permissions and plan flags as of the last time
          // this device actually spoke to the server.
          await prefs.setString(_profileKey, jsonEncode(fresh.toJson()));
        } on ApiException catch (e) {
          if (e.status == null) {
            _restoreOffline(prefs, t);
          } else {
            await _forgetSession(prefs);
          }
        } catch (_) {
          // Transport-level: SocketException, ClientException, TimeoutException.
          // The server was never reached.
          _restoreOffline(prefs, t);
        }
      }
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  /// Bring the session back from disk when the server is unreachable. Falls back
  /// to signing out only if there is no saved profile to restore — a session
  /// with a token and no identity cannot gate a single screen, and pretending
  /// otherwise would put a user in front of modules their role may not allow.
  void _restoreOffline(SharedPreferences prefs, String token) {
    final raw = prefs.getString(_profileKey);
    if (raw == null || raw.isEmpty) {
      _token = null;
      _profile = null;
      return;
    }
    try {
      _profile = Profile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _token = token;
      _selectedOutletId = prefs.getString(_outletKey);
    } catch (_) {
      // A corrupt or half-written blob is not a session.
      _token = null;
      _profile = null;
    }
  }

  /// The server said this token is no longer valid. Forget everything about it.
  Future<void> _forgetSession(SharedPreferences prefs) async {
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
    _token = null;
    _profile = null;
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
      // Saved with the token, not later: a user who signs in and immediately
      // loses connectivity must still be able to reopen the app.
      await prefs.setString(_profileKey, jsonEncode(result.profile.toJson()));
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
    // The cached identity goes with the session. Leaving it behind would let the
    // next launch restore a profile whose token is already gone.
    await prefs.remove(_profileKey);
    // A voluntary sign-out is the "handing the device over" gesture, so the
    // saved GET cache goes with the token. An EXPIRED session keeps it: the
    // same person is about to sign straight back in, and the warm cache is
    // what makes that reopen instant.
    if (!expired) await GetCache.instance.clearAll();
    if (t != null) await api.logout(t);
  }
}
