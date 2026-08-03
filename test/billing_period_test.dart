import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';

/// The renewal line used to print `dt.difference(now).inDays` raw, so a live
/// tenant whose period ended yesterday read "Renews in -1 day(s)" — a countdown
/// that had run past zero and told the owner nothing they could act on.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
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

// Shape of GET /billing, copied from the live control plane (the Enterprise plan
// this tenant is actually on).
Map<String, dynamic> _billing({required String status, String? periodEnd, String? trialEnd}) => <String, dynamic>{
      'configured': true,
      'online_pay': false,
      'subscription': <String, dynamic>{
        'res_id': 'r1',
        'plan_id': 'p-ent',
        'status': status,
        'trial_ends_at': trialEnd,
        'current_period_end': periodEnd,
        'pending_plan_id': null,
      },
      'plan': <String, dynamic>{'id': 'p-ent', 'name': 'Enterprise', 'price_cents': 399900},
      'pending_plan': null,
      'plans': [
        <String, dynamic>{
          'id': 'p-ent',
          'name': 'Enterprise',
          'price_cents': 399900,
          'features': <String, dynamic>{},
          'limits': <String, dynamic>{},
        },
      ],
      'invoices': <dynamic>[],
    };

String _iso(Duration fromNow) => DateTime.now().toUtc().add(fromNow).toIso8601String();

Future<void> _pump(WidgetTester tester, Map<String, dynamic> billing) async {
  final rest = await _signIn(_FakeApi({'/billing': billing}));
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: m.billingModule(rest, rest.auth.profile!)),
  ));
  await tester.pumpAndSettle();
}

/// A re-pump inside one test would reuse the module's State (same type, same
/// position) and keep the first payload, so each case gets its own test.

// The caption is uppercased into the StatCard, so assert on that form.
Finder _caption(String needle) => find.textContaining(needle.toUpperCase());

void main() {
  testWidgets('a future period end counts down in whole days', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(days: 12))));
    expect(_caption('Renews in 12 days'), findsOneWidget);
    expect(_caption('Renews in -'), findsNothing);
  });

  testWidgets('a period ending inside a day rounds up instead of reading "0 days"', (tester) async {
    // .inDays truncates toward zero: 20 hours left used to render "0 day(s)".
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(hours: 20))));
    expect(_caption('Renews in 1 day'), findsOneWidget);
    expect(_caption('Renews in 1 days'), findsNothing);
    expect(_caption('Renews in 0'), findsNothing);
  });

  testWidgets('a period ending within the minute reads as today, not overdue', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(seconds: 30))));
    expect(_caption('Renews today'), findsOneWidget);
    expect(find.text('Renewal failed'), findsNothing);
  });

  testWidgets('a period end past the grace window reads as overdue, never a negative countdown',
      (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(hours: -73))));
    expect(_caption('Renews in'), findsNothing);
    expect(_caption('Payment overdue by 3 days'), findsOneWidget);
    // And the owner gets something to act on rather than a number.
    expect(find.text('Renewal failed'), findsOneWidget);
    expect(find.textContaining('did not renew'), findsOneWidget);
  });

  // The charge is presented on the due date and settles asynchronously, and the
  // platform re-tries a soft decline overnight. Calling that "failed" the minute
  // the period ends accuses the owner of something that has not happened.
  testWidgets('the hours right after the period ends read as renewing, not failed', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(hours: -3))));
    expect(find.text('Renewing'), findsOneWidget);
    expect(find.text('Renewal failed'), findsNothing);
    expect(_caption('Payment overdue'), findsNothing);
    expect(_caption('Renewing — payment not confirmed yet'), findsOneWidget);
  });

  testWidgets('the grace window is 48 hours, not indefinite', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(hours: -47))));
    expect(find.text('Renewing'), findsOneWidget);
    expect(find.text('Renewal failed'), findsNothing);
  });

  testWidgets('once the grace window is spent the wording escalates', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: _iso(const Duration(hours: -49))));
    expect(find.text('Renewing'), findsNothing);
    expect(find.text('Renewal failed'), findsOneWidget);
    expect(_caption('Payment overdue by 2 days'), findsOneWidget);
  });

  // The server's own verdict is not a guess and does not wait: once it has
  // managed to invoice a lapsed subscription, the grace window is irrelevant.
  testWidgets('a server-declared past_due skips the grace window entirely', (tester) async {
    await _pump(tester, _billing(status: 'past_due', periodEnd: _iso(const Duration(hours: -3))));
    expect(find.text('Renewing'), findsNothing);
    expect(find.text('Renewal failed'), findsOneWidget);
    // Under a day late, so it claims no whole days.
    expect(_caption('Payment overdue'), findsOneWidget);
    expect(_caption('Payment overdue by'), findsNothing);
  });

  testWidgets('past_due is overdue regardless of the period end', (tester) async {
    await _pump(tester, _billing(status: 'past_due', periodEnd: _iso(const Duration(days: 3))));
    expect(_caption('Renews in'), findsNothing);
    expect(_caption('Payment overdue'), findsOneWidget);
  });

  testWidgets('a null period end shows no renewal line at all', (tester) async {
    await _pump(tester, _billing(status: 'active', periodEnd: null));
    expect(_caption('Renews'), findsNothing);
    expect(_caption('Payment overdue'), findsNothing);
    expect(find.text('Enterprise'), findsWidgets);
  });

  testWidgets('a trial still counts down', (tester) async {
    await _pump(tester, _billing(status: 'trial', periodEnd: null, trialEnd: _iso(const Duration(days: 6))));
    expect(_caption('Trial — 6 days left'), findsOneWidget);
  });

  testWidgets('a trial that ran out says so', (tester) async {
    await _pump(tester, _billing(status: 'trial', periodEnd: null, trialEnd: _iso(const Duration(days: -2))));
    expect(_caption('Trial expired'), findsOneWidget);
  });
}
