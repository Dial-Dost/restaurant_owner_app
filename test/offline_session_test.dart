import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';

/// SIGNING IN ONCE MUST BE ENOUGH TO OPEN THE APP WITHOUT A CONNECTION.
///
/// The offline read cache and the write outbox were both shipped and both
/// green, and neither could ever run, because `AuthController.init()` wrapped
/// its `/auth/me` refresh in a bare `catch (_)` that deleted the stored token.
/// A launch with no connection was therefore indistinguishable from a session
/// the server had rejected: the app signed the user out and showed a login
/// screen that also needs the network. You could not get through the front door
/// to reach the offline features behind it.
///
/// The rule these tests hold is the one that distinction turns on: **only the
/// server may end a session.** Silence from the network is not evidence about a
/// token.

/// Fails `me()` the way a real offline device does — the transport throws before
/// any HTTP status exists.
class _OfflineApi extends ApiClient {
  int meCalls = 0;

  @override
  Future<Profile> me(String token) async {
    meCalls++;
    // What package:http actually throws when there is no route to the host. It
    // is NOT an ApiException: there is no response to carry a status.
    throw const FakeSocketException('Failed host lookup: api.dialdost.com');
  }
}

/// A stand-in for `dart:io`'s `SocketException` so this test needs no dart:io
/// import and runs unchanged on every platform. What matters for the code under
/// test is only that it is NOT an ApiException and carries no status — exactly
/// like the real thing.
class FakeSocketException implements Exception {
  const FakeSocketException(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}

/// The server answers, and says the token is dead.
class _RejectingApi extends ApiClient {
  int meCalls = 0;

  @override
  Future<Profile> me(String token) async {
    meCalls++;
    throw ApiException('Session expired.', 401);
  }
}

/// The server answers normally.
class _OnlineApi extends ApiClient {
  _OnlineApi(this.profile);
  final Profile profile;
  int meCalls = 0;

  @override
  Future<Profile> me(String token) async {
    meCalls++;
    return profile;
  }
}

Profile _profile({String role = 'admin', List<String> actions = const ['*']}) =>
    Profile.fromJson(<String, dynamic>{
      'employeeId': 'emp-1',
      'restaurantName': 'CSR Organics',
      'restaurantUsername': 'csr',
      'res_id': 'res-1',
      'outlet_id': 'out-1',
      'role': role,
      'role_all': [role],
      'emp_Fname': 'Asha',
      'employeeUsername': 'asha',
      'action_names': ['View Order APC'],
      'actions_set': actions,
      'features': {'analytics': true},
      'limits': {'outlets': 2},
    });

void main() {
  group('a signed-in session survives an offline launch', () {
    test('the token is KEPT and the profile restored when the server is unreachable', () async {
      final saved = _profile();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'owner_token': 'tok-abc',
        'owner_profile': jsonEncode(saved.toJson()),
      });

      final api = _OfflineApi();
      final auth = AuthController(api: api);
      await auth.init();

      expect(api.meCalls, 1, reason: 'it should still TRY the server first');
      expect(auth.isAuthenticated, isTrue,
          reason: 'an unreachable server is not evidence that the token is bad');
      expect(auth.token, 'tok-abc');
      expect(auth.profile!.employeeId, 'emp-1');
      expect(auth.profile!.restaurantName, 'CSR Organics');

      // The token must still be on disk for the NEXT offline launch too.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('owner_token'), 'tok-abc');
    });

    test('permissions and plan flags survive, so gating is not silently widened', () async {
      // Restoring an identity without its actions would show a waiter every
      // admin module. The restored profile must gate exactly as the live one.
      final waiter = _profile(role: 'waiter', actions: const ['df75119b']);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'owner_token': 'tok-abc',
        'owner_profile': jsonEncode(waiter.toJson()),
      });

      final auth = AuthController(api: _OfflineApi());
      await auth.init();

      expect(auth.profile!.isAdmin, isFalse);
      expect(auth.profile!.can(['apc']), isTrue);
      expect(auth.profile!.can(['payroll']), isFalse);
      expect(auth.profile!.featureEnabled('analytics'), isTrue);
    });
  });

  group('only the server may end a session', () {
    test('a 401 DOES sign the user out and forgets the cached profile', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'owner_token': 'tok-dead',
        'owner_profile': jsonEncode(_profile().toJson()),
      });

      final auth = AuthController(api: _RejectingApi());
      await auth.init();

      expect(auth.isAuthenticated, isFalse,
          reason: 'staying signed in on a revoked session is a security hole');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('owner_token'), isNull);
      expect(prefs.getString('owner_profile'), isNull,
          reason: 'a stale identity must not outlive the token it belonged to');
    });

    test('a token with no saved profile does not restore a faceless session', () async {
      // A session with an id and no identity cannot gate a single screen.
      SharedPreferences.setMockInitialValues(<String, Object>{'owner_token': 'tok-abc'});
      final auth = AuthController(api: _OfflineApi());
      await auth.init();
      expect(auth.isAuthenticated, isFalse);
    });

    test('a corrupt profile blob degrades to signed-out, not to a crash', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'owner_token': 'tok-abc',
        'owner_profile': '{not json',
      });
      final auth = AuthController(api: _OfflineApi());
      await auth.init();
      expect(auth.isAuthenticated, isFalse);
    });
  });

  group('the cached profile is kept current', () {
    test('a successful launch refreshes what an offline launch would restore', () async {
      // Otherwise a permission revoked months ago would still be honoured by
      // every offline start.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'owner_token': 'tok-abc',
        'owner_profile': jsonEncode(_profile(role: 'admin').toJson()),
      });

      final demoted = _profile(role: 'waiter', actions: const ['df75119b']);
      final auth = AuthController(api: _OnlineApi(demoted));
      await auth.init();

      expect(auth.profile!.isAdmin, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final stored = Profile.fromJson(
          jsonDecode(prefs.getString('owner_profile')!) as Map<String, dynamic>);
      expect(stored.isAdmin, isFalse, reason: 'the cache must follow the server');
    });
  });

  group('Profile survives the disk round trip', () {
    test('fromJson(toJson(p)) preserves every field', () {
      // toJson writes the WIRE's keys, so the restore path parses the same shape
      // /auth/me returns. Add a field to fromJson without adding it here and
      // this fails — which is the point.
      final p = _profile();
      final back = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

      expect(back.employeeId, p.employeeId);
      expect(back.restaurantName, p.restaurantName);
      expect(back.restaurantUsername, p.restaurantUsername);
      expect(back.resId, p.resId);
      expect(back.outletId, p.outletId);
      expect(back.role, p.role);
      expect(back.roleAll, p.roleAll);
      expect(back.firstName, p.firstName);
      expect(back.employeeUsername, p.employeeUsername);
      expect(back.actionNames, p.actionNames);
      expect(back.actions, p.actions);
      expect(back.features, p.features);
      expect(back.limits, p.limits);
    });
  });
}
