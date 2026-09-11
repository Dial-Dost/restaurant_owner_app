// THE SCOPING IS THE SERVER'S DECISION, NOT THE CLIENT'S GUESS.
//
// It used to be the client's, derived by asking whether every role string was
// literally "waiter", and it was live and wrong: a waiter granted any CUSTOM
// ROLE carries its UUID in role_all, `every` failed, and every restriction
// lifted — including the money gate, since showsMoney is `!isWaiterOnly`. The
// app looked correct on a tenant whose waiters had one clean role and wrong on
// the tenant next door, which is the definition of a rule nobody can rely on.
//
// The server now ships `scope.waiter_only`. These tests pin BOTH halves: that
// the answer is obeyed when given, and that the local fallback — for an app
// pointed at an older backend — no longer has the defect.
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';

const customRoleId = 'd2b1f0c4-5a97-4e40-b8d3-7e02a9c4f156';

Profile who({
  String role = 'waiter',
  List<String> roleAll = const ['waiter'],
  List<String> actions = const ['a1'],
  bool? serverSays,
}) =>
    Profile.fromJson(<String, dynamic>{
      'role': role,
      'role_all': roleAll,
      'actions_set': actions,
      'action_names': const <String>[],
      if (serverSays != null) 'scope': <String, dynamic>{'waiter_only': serverSays},
    });

void main() {
  group('the server has the last word', () {
    test('its answer is obeyed even when the roles would say otherwise', () {
      // Roles that the local heuristic would read as senior, but the server —
      // which knows what the custom role actually grants — says scoped.
      final p = who(roleAll: ['waiter', customRoleId, 'employee'], serverSays: true);
      expect(RoleScope.isWaiterOnly(p), isTrue);
      expect(RoleScope.showsMoney(p), isFalse);
    });

    test('and in the other direction', () {
      final p = who(roleAll: ['waiter'], serverSays: false);
      expect(RoleScope.isWaiterOnly(p), isFalse);
      expect(RoleScope.showsMoney(p), isTrue);
    });

    test('an admin is never scoped, whatever the server said', () {
      expect(RoleScope.isWaiterOnly(who(actions: ['*'], serverSays: true)), isFalse);
    });

    test('the answer survives a round trip through disk', () {
      // The offline restore writes the profile back in the wire's shape; if the
      // scope did not survive, a waiter would silently widen on a cold launch.
      final p = who(roleAll: ['waiter', customRoleId], serverSays: true);
      final restored = Profile.fromJson(p.toJson());
      expect(restored.waiterOnly, isTrue);
      expect(RoleScope.isWaiterOnly(restored), isTrue);
    });

    test('a server that never said leaves no scope key behind', () {
      // Absent must stay absent: a restore must not invent an answer.
      expect(who().toJson().containsKey('scope'), isFalse);
      expect(who().waiterOnly, isNull);
    });
  });

  group('the fallback, for an app ahead of its backend', () {
    test('THE BUG: a waiter with a custom role is still a waiter', () {
      final p = who(roleAll: ['waiter', customRoleId]);
      expect(p.waiterOnly, isNull, reason: 'no server answer — this is the fallback path');
      expect(RoleScope.isWaiterOnly(p), isTrue);
      expect(RoleScope.showsMoney(p), isFalse);
    });

    test('THE BUG: the "employee" placeholder does not un-scope anybody', () {
      expect(RoleScope.isWaiterOnly(who(role: 'employee', roleAll: ['employee', 'waiter'])), isTrue);
    });

    test('a genuinely senior role still lifts it', () {
      for (final senior in ['manager', 'admin', 'cashier', 'captain']) {
        expect(RoleScope.isWaiterOnly(who(roleAll: ['waiter', senior])), isFalse,
            reason: 'waiter + $senior is $senior on shift');
      }
    });

    test('a valet does not outrank a waiter', () {
      expect(RoleScope.isWaiterOnly(who(roleAll: ['waiter', 'valet'])), isTrue);
    });

    test('somebody who is not a waiter at all is not scoped by this', () {
      expect(RoleScope.isWaiterOnly(who(role: 'manager', roleAll: ['manager'])), isFalse);
    });

    test('an empty role set fails safe — the owner keeps every screen', () {
      expect(RoleScope.isWaiterOnly(who(role: '', roleAll: const [])), isFalse);
    });
  });
}
