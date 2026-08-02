import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Canned backend that also records request bodies, so the timezone save can be
/// asserted field-by-field (only `timezone` may be written).
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];
  final List<Object?> bodies = <Object?>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method == 'POST') {
      bodies.add(body);
      // Behave like the server: a saved setting is visible to the next GET, so
      // the reload the card triggers reads back what was just written.
      if (path == '/restaurant/settings' && body is Map) {
        (routes[path] as Map<String, dynamic>).addAll(Map<String, dynamic>.from(body));
      }
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

// Mirrors how HomeShell mounts a module: inside a Scaffold, under a
// ModuleNavigator. (settingsModule returns a bare ListView, so the Scaffold is
// what supplies the Material ancestor its TextFields need.)
Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Orders', 'Settings'],
          clearFocus: () {},
          child: child,
        ),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RestaurantTime.adopt(RestaurantTime.defaultZone);
  });

  testWidgets('Settings states the zone in force and saves a new one', (tester) async {
    final api = _FakeApi({
      '/restaurant/profile': <String, dynamic>{'restaurant_name': 'CSR Organics'},
      '/restaurant/settings': <String, dynamic>{'timezone': 'Asia/Kolkata', 'currency': '₹'},
      '/restaurant/timezones': <String, dynamic>{
        'timezones': ['Asia/Kolkata', 'America/New_York', 'UTC'],
        'current': 'Asia/Kolkata',
        'default': 'Asia/Kolkata',
      },
    });
    final rest = await _signIn(api);

    // Settings is one long scroller and a Sliver only builds what is on screen;
    // give the test a tall surface so the card is in the element tree.
    await tester.binding.setSurfaceSize(const Size(1100, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    // The card states the zone, its offset, and what it governs.
    expect(find.text('Restaurant timezone'), findsOneWidget);
    expect(find.text('Asia/Kolkata'), findsOneWidget);
    expect(find.text('UTC+05:30'), findsOneWidget);
    // …and the session adopted it, so every other screen formats in it.
    expect(RestaurantTime.zone, 'Asia/Kolkata');

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('GET /restaurant/timezones'));

    // Each row previews that zone's own offset — the picker is not showing one
    // number for everything.
    expect(find.textContaining('UTC-0', findRichText: true), findsWidgets);

    await tester.tap(find.text('America/New_York'));
    await tester.pumpAndSettle();

    // ONLY the timezone key is written — never the rest of the settings document.
    expect(api.calls, contains('POST /restaurant/settings'));
    expect(api.bodies.last, <String, dynamic>{'timezone': 'America/New_York'});
    expect(RestaurantTime.zone, 'America/New_York');
  });

  testWidgets('a zone this build cannot render is not selectable', (tester) async {
    final api = _FakeApi({
      '/restaurant/profile': <String, dynamic>{'restaurant_name': 'CSR Organics'},
      '/restaurant/settings': <String, dynamic>{'timezone': 'Asia/Kolkata'},
      '/restaurant/timezones': <String, dynamic>{
        'timezones': ['Asia/Kolkata', 'Mars/Olympus_Mons'],
        'current': 'Asia/Kolkata',
      },
    });
    final rest = await _signIn(api);

    await tester.binding.setSurfaceSize(const Size(1100, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();

    expect(find.text('not in this app build'), findsOneWidget);
    await tester.tap(find.text('Mars/Olympus_Mons'));
    await tester.pumpAndSettle();
    // Still in the picker, nothing saved: silently degrading to device time is
    // exactly what this guard exists to prevent.
    expect(find.text('Mars/Olympus_Mons'), findsOneWidget);
    expect(api.calls.where((c) => c == 'POST /restaurant/settings'), isEmpty);
  });

  testWidgets('an order row shows when it was placed, in restaurant time', (tester) async {
    final api = _FakeApi({
      '/orders': <dynamic>[
        <String, dynamic>{
          'id': 'o1',
          'table': '7',
          'customer': 'Walk-in',
          'status': 'Preparing',
          'order_type': 'dine_in',
          'items': <dynamic>[],
          'total': 480,
          'taken_by_employee_name': 'Admin',
          // 14:36 UTC — 20:06 in Asia/Kolkata, 10:36 in America/New_York (EDT).
          'created_at': '2026-07-28T14:36:07.942Z',
        },
      ],
      '/orders/scope': <String, dynamic>{
        'outlet': {'id': 'a', 'name': 'Main'},
        'is_all_outlets': false,
        'live_orders': 1,
        'other_outlet_orders': 0,
        'outlets': <dynamic>[],
        'live_window_days': 3,
        'current_outlet_has_tables': true,
      },
    });
    final rest = await _signIn(api);

    RestaurantTime.adopt('Asia/Kolkata');
    await tester.pumpWidget(_host(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();
    expect(find.text('Placed Jul 28, 20:06'), findsOneWidget);

    // Same instant, different restaurant: the row follows the setting, not the
    // machine the app is running on.
    RestaurantTime.adopt('America/New_York');
    await tester.pumpWidget(_host(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();
    expect(find.text('Placed Jul 28, 10:36'), findsOneWidget);
  });
}
