import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/profile.dart';

void main() {
  test('Profile.fromJson tolerates missing fields', () {
    final p = Profile.fromJson(<String, dynamic>{
      'employeeId': 'e1',
      'restaurantName': 'Demo',
      'role': 'admin',
      'action_names': ['View orders', 'Generate bills'],
      'limits': {'employees': 10},
    });
    expect(p.employeeId, 'e1');
    expect(p.restaurantName, 'Demo');
    expect(p.role, 'admin');
    expect(p.actionNames.length, 2);
    expect(p.limits['employees'], 10);
    expect(p.outletId, ''); // missing -> empty, no crash
  });

  test('Profile.can gates modules by permission', () {
    final admin = Profile.fromJson({'role': 'admin', 'actions_set': ['*'], 'action_names': []});
    expect(admin.can(['order']), isTrue); // admin sees everything
    expect(admin.can(['anything']), isTrue);

    final waiter = Profile.fromJson({
      'role': 'waiter',
      'actions_set': ['uuid-1'],
      'action_names': ['View orders', 'Create orders'],
    });
    expect(waiter.can([]), isTrue); // always-visible modules
    expect(waiter.can(['order']), isTrue); // matches "... orders"
    expect(waiter.can(['inventory', 'stock']), isFalse); // not permitted
  });
}
