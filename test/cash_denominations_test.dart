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

/// Closing the drawer means counting it: so many ₹500s, so many ₹10 coins. The
/// register had one "Counted cash" box and nothing to count into, so the arithmetic
/// happened on paper.
///
/// The counts themselves are NOT persisted and cannot be — `CashSessions` has no
/// denomination column and POST /cash/close reads only counted_cash, cash_payouts
/// and notes — so what is asserted here is what the feature actually promises: the
/// tally adds up correctly, it fills the field that IS stored, and the number the
/// server receives is the number the closer counted.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// Every write the module made, so the test can check what was submitted.
  final List<({String path, Object? body})> posts = [];

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
    if (method == 'POST') {
      posts.add((path: path, body: body));
      return <String, dynamic>{'variance': 0};
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

// An open register with ₹18,500 expected in the drawer.
const _openSession = <String, dynamic>{
  '/cash/current': {
    'session': {
      'id': 'cs1',
      'status': 'open',
      'opened_at': '2026-08-17T04:00:00Z',
      'opening_float': 2000,
      'live_cash_sales': 17000,
      'live_cash_refunds': 500,
      'live_expected': 18500,
    },
  },
  '/cash/sessions': {'sessions': <dynamic>[]},
};

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Cash register'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<_FakeApi> _mountCash(WidgetTester tester, {double width = 390}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(_openSession);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.cashModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

/// The count field for one denomination. Keyed rather than found by its label: ₹20
/// and ₹10 are each both a note and a coin, and a row's own subtotal can read "₹10"
/// too, so the label is not a unique handle.
Finder _countField(int value, {bool coin = false}) =>
    find.byKey(ValueKey('denom-${coin ? 'coin' : 'note'}-$value'));

Future<void> _count(WidgetTester tester, int value, String howMany, {bool coin = false}) async {
  await tester.enterText(_countField(value, coin: coin), howMany);
  await tester.pumpAndSettle();
}

String _countedCash(WidgetTester tester) => tester
    .widget<TextField>(
        find.ancestor(of: find.text('Counted cash (₹)'), matching: find.byType(TextField)))
    .controller!
    .text;

void main() {
  testWidgets('the close card offers every Indian denomination', (tester) async {
    await _mountCash(tester);

    expect(find.text('COUNT THE DRAWER'), findsOneWidget);
    expect(find.text('NOTES'), findsOneWidget);
    expect(find.text('COINS'), findsOneWidget);
    for (final note in ['₹2000', '₹500', '₹200', '₹100', '₹50']) {
      expect(find.text(note), findsOneWidget, reason: '$note note row missing');
    }
    // ₹20 and ₹10 are both a note and a coin.
    expect(find.text('₹20'), findsNWidgets(2));
    expect(find.text('₹10'), findsNWidgets(2));
    for (final coin in ['₹5', '₹2', '₹1']) {
      expect(find.text(coin), findsOneWidget, reason: '$coin coin row missing');
    }
    // And it says plainly what it does and does not keep.
    expect(find.textContaining('not saved with the session'), findsOneWidget);
  });

  testWidgets('counts add up, per line and in the total', (tester) async {
    await _mountCash(tester);

    // 12×2000 + 8×500 + 3×100 = 24000 + 4000 + 300 = 28300
    await _count(tester, 2000, '12');
    await _count(tester, 500, '8');
    await _count(tester, 100, '3');

    // Each line shows its own subtotal, so a miscount is findable without redoing
    // the whole drawer.
    expect(find.text('₹24000'), findsOneWidget);
    expect(find.text('₹4000'), findsOneWidget);
    expect(find.text('₹300'), findsOneWidget);

    expect(find.text('₹28300.00'), findsWidgets, reason: 'the tally total');
    // The total is what goes into the field the backend actually stores.
    expect(_countedCash(tester), '28300');
  });

  testWidgets('coins are counted separately from the note of the same value',
      (tester) async {
    await _mountCash(tester);

    await _count(tester, 20, '5'); // note: 100
    await _count(tester, 20, '7', coin: true); // coin: 140
    expect(_countedCash(tester), '240');

    await _count(tester, 10, '1'); // note: 10
    await _count(tester, 10, '9', coin: true); // coin: 90
    expect(_countedCash(tester), '340');
  });

  testWidgets('the tally is checked against the expected cash, either way out',
      (tester) async {
    await _mountCash(tester);
    expect(find.text('₹18500.00'), findsWidgets, reason: 'expected in drawer');

    // 36×500 = 18000 — five hundred short.
    await _count(tester, 500, '36');
    expect(find.text('Short ₹500.00'), findsOneWidget);

    // 37×500 = 18500 — dead on.
    await _count(tester, 500, '37');
    expect(find.text('Balanced ₹0.00'), findsOneWidget);

    // 38×500 = 19000 — over.
    await _count(tester, 500, '38');
    expect(find.text('Over ₹500.00'), findsOneWidget);
  });

  testWidgets('cash paid out is netted off before the tally is judged', (tester) async {
    // The server stores variance = counted - (float + sales - refunds - payouts),
    // but live_expected does NOT net payouts off. Judging the tally against
    // live_expected alone reads "Balanced" on a drawer the server then records as
    // short by exactly the payout. On a cash screen that is the worst possible
    // reading, so the tally has to net it the same way the server does.
    await _mountCash(tester);

    // 37×500 = 18500, dead on live_expected while nothing is paid out.
    await _count(tester, 500, '37');
    expect(find.text('Balanced ₹0.00'), findsOneWidget);

    // ₹500 leaves the drawer as a payout. The same 18500 counted is now ₹500 OVER
    // what should be left, and the chip must say so.
    await tester.enterText(
      find.ancestor(of: find.text('Cash paid out (₹)'), matching: find.byType(TextField)),
      '500',
    );
    await tester.pumpAndSettle();
    expect(find.text('Balanced ₹0.00'), findsNothing,
        reason: 'a payout moved the target — the tally cannot still read balanced');
    expect(find.text('Over ₹500.00'), findsOneWidget);

    // Counting 500 less again agrees with the payout.
    await _count(tester, 500, '36');
    expect(find.text('Balanced ₹0.00'), findsOneWidget);
  });

  testWidgets('closing submits the counted total, and nothing the backend cannot store',
      (tester) async {
    final api = await _mountCash(tester);

    await _count(tester, 500, '30'); // 15000
    await _count(tester, 100, '35'); // 3500  -> 18500 exactly
    expect(_countedCash(tester), '18500');

    await tester.tap(find.text('Close register'));
    await tester.pumpAndSettle();

    final close = api.posts.where((p) => p.path == '/cash/close').toList();
    expect(close.length, 1);
    final body = close.single.body as Map;
    expect(body['counted_cash'], 18500);
    // The breakdown is deliberately NOT sent: /cash/close drops unknown keys, so a
    // `denominations` payload would 200 and vanish. Sending it would be a lie about
    // what got saved.
    expect(body.keys.toSet(), {'counted_cash', 'cash_payouts', 'notes'});
  });

  testWidgets('the tally can be folded away, and typing the total by hand still works',
      (tester) async {
    await _mountCash(tester);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(find.text('₹2000'), findsNothing);
    // The check against the register survives the fold.
    expect(find.text('Counted from tally'), findsOneWidget);

    await tester.enterText(
        find.ancestor(of: find.text('Counted cash (₹)'), matching: find.byType(TextField)), '17999');
    await tester.pumpAndSettle();
    expect(_countedCash(tester), '17999');
  });

  testWidgets('the tally rows lay out on a 320dp phone', (tester) async {
    await _mountCash(tester, width: 320);
    await _count(tester, 2000, '99');
    expect(find.text('₹198000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
