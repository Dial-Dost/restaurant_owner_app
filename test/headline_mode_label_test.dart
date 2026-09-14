// THE OVERVIEW NAMES A PAYMENT MODE AS THE OWNER DOES.
//
// The headline's today_by_method rows carry the stored id AND the owner's label
// (Settings > Payments). The bar, its tooltip and the drill-down title all show
// the label ("UPI", "EasyDiner", a custom mode's name), matching Accounting.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult('t', Profile.fromJson(<String, dynamic>{
        'employeeId': 'e1', 'restaurantName': 'CSR Organics', 'role': 'admin',
        'actions_set': ['*'], 'action_names': <String>[],
      }));
  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

void main() {
  testWidgets('the by-method bar and its drill-down title show the owner label, not the stored id', (tester) async {
    tester.view.physicalSize = const Size(1600, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({
      '/analytics/headline': {
        'today': '2026-09-14', 'month_from': '2026-09-01', 'timezone': 'Asia/Kolkata',
        'today_net': {'value': 10000, 'label': "Today's net sale", 'hint': 'x'},
        'today_gross': {'value': 11000, 'label': "Today's gross sale", 'hint': 'x'},
        'cash_collection': {'value': 0, 'label': 'Cash collection', 'hint': 'x'},
        'today_bills': 3, 'month_bills': 3,
        // Exactly what backend release/cfb (0671850) sends: id + the owner's label.
        'today_by_method': [
          {'method': 'Upi', 'label': 'UPI', 'bills': 2, 'amount': 6000, 'share_pct': 54.5, 'refund': 0, 'net_amount': 6000},
          {'method': 'Eazydiner', 'label': 'EasyDiner', 'bills': 1, 'amount': 5000, 'share_pct': 45.5, 'refund': 0, 'net_amount': 5000},
        ],
        'today_split_bills': 0, 'today_unallocated': 0,
        'by_method': {'label': 'Collected by payment method', 'hint': 'x'},
      },
    });
    final auth = AuthController(api: api);
    await auth.login('CSR Organics', 'admin', 'admin123');
    final rest = RestClient(auth);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Overview', 'Accounting'],
        clearFocus: () {},
        child: m.overviewModule(rest, rest.auth.profile!),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('EasyDiner'), findsOneWidget);
    expect(find.text('Eazydiner'), findsNothing);
    expect(find.text('UPI'), findsOneWidget);
    await tester.tap(find.text('EasyDiner').first);
    await tester.pumpAndSettle();
    expect(find.text('EasyDiner · ₹5000.00'), findsOneWidget);
    expect(find.text('Eazydiner · ₹5000.00'), findsNothing);
  });
}
