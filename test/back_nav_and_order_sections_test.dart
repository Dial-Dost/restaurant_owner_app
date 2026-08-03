import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/section_header.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Canned responses in place of the network. Unknown routes throw, which every
/// module renders as its error state — enough to navigate between them.
class _FakeApi extends ApiClient {
  _FakeApi([this.routes = const {}]);
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

Future<AuthController> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

// The label the shell is currently showing, read off the AppBar rather than the
// sidebar (every module label appears in both).
String _activeTab(WidgetTester tester) {
  final titleRow = find.descendant(of: find.byType(AppBar), matching: find.byType(Text));
  return tester.widgetList<Text>(titleRow).first.data!;
}

IconButton _backBtn(WidgetTester tester) =>
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back));

// Taps a module in the fixed sidebar (the AppBar carries the same word).
Future<void> _tapNav(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(ListView).first,
    matching: find.text(label),
  ));
  await tester.pump();
}

Future<void> _pumpShell(WidgetTester tester, AuthController auth) async {
  // Wide enough for the fixed sidebar (the shell falls back to a drawer < 700).
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // The printer agent is off explicitly: it opens a real socket and a
  // keep-alive timer that fake-async cannot own.
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump();
}

// ---- orders fixtures --------------------------------------------------------

// An absolute instant `hours` ago. Ends in 'Z', so RestaurantTime converts it
// into restaurant wall time exactly as it does a real backend timestamp.
String _agoIso(double hours) => DateTime.now()
    .toUtc()
    .subtract(Duration(minutes: (hours * 60).round()))
    .toIso8601String();

Map<String, dynamic> _order(String id, String status, {double ageHours = 1, String table = 'T1'}) => {
      'id': id,
      'table': table,
      'customer': 'Guest $id',
      'status': status,
      'items': <dynamic>[],
      'total': 100,
      'barked_at': '2026-07-26T10:00:00Z',
      'created_at': _agoIso(ageHours),
    };

const _soloScope = <String, dynamic>{
  'outlet': {'id': 'a', 'name': 'Solo'},
  'is_all_outlets': false,
  'live_orders': 0,
  'other_outlet_orders': 0,
  'outlets': [
    {'outlet_id': 'a', 'outlet_name': 'Solo', 'live_orders': 0, 'tables': 4, 'is_current': true},
  ],
  'live_window_days': 3,
  'current_outlet_has_tables': true,
};

Widget _hostOrders(Widget child, {List<String> visible = const ['Orders', 'History']}) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: visible,
        clearFocus: () {},
        child: child,
      ),
    );

Future<RestClient> _ordersRest(List<Map<String, dynamic>> orders) async {
  final auth = await _signIn(_FakeApi({'/orders': orders, '/orders/scope': _soloScope}));
  return RestClient(auth);
}

List<String> _sectionTitles(WidgetTester tester) =>
    tester.widgetList<SectionHeader>(find.byType(SectionHeader)).map((h) => h.title).toList();

void main() {
  // ---------------------------------------------------------------- TASK A ---

  testWidgets('Back returns to the previously visited tab', (tester) async {
    final auth = await _signIn(_FakeApi());
    await _pumpShell(tester, auth);

    expect(_activeTab(tester), 'Overview');
    // Nothing visited yet: the control is present but inert, not a no-op button.
    expect(_backBtn(tester).onPressed, isNull);
    expect(find.byTooltip('No previous tab'), findsOneWidget);

    await _tapNav(tester, 'Orders');
    expect(_activeTab(tester), 'Orders');
    expect(find.byTooltip('Back to Overview'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to Overview'));
    await tester.pump();
    expect(_activeTab(tester), 'Overview');
    // The trail is spent, so Back goes inert again rather than looping.
    expect(_backBtn(tester).onPressed, isNull);
  });

  testWidgets('Back walks a multi-hop trail one tab at a time', (tester) async {
    final auth = await _signIn(_FakeApi());
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Orders');
    await _tapNav(tester, 'Tables');
    await _tapNav(tester, 'Menu');
    expect(_activeTab(tester), 'Menu');

    for (final expected in ['Tables', 'Orders', 'Overview']) {
      await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_back));
      await tester.pump();
      expect(_activeTab(tester), expected);
    }
    expect(_backBtn(tester).onPressed, isNull);
  });

  testWidgets('re-opening the tab already open pushes nothing', (tester) async {
    final auth = await _signIn(_FakeApi());
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Orders');
    await _tapNav(tester, 'Orders');
    await _tapNav(tester, 'Orders');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_back));
    await tester.pump();
    expect(_activeTab(tester), 'Overview');
    expect(_backBtn(tester).onPressed, isNull);
  });

  testWidgets('a focus-driven jump is undoable by Back', (tester) async {
    final auth = await _signIn(_FakeApi());
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Orders');
    // Exactly what a tapped notification does — the shell's own openModule,
    // carrying a record to highlight.
    tester.widget<ModuleNavigator>(find.byType(ModuleNavigator)).openModule('Tables', target: {'table': 'T4'});
    await tester.pump();
    expect(_activeTab(tester), 'Tables');

    await tester.tap(find.byTooltip('Back to Orders'));
    await tester.pump();
    expect(_activeTab(tester), 'Orders');
  });

  testWidgets('Escape goes back, and is inert with an empty trail', (tester) async {
    final auth = await _signIn(_FakeApi());
    await _pumpShell(tester, auth);

    // Empty trail: Escape must not move us anywhere.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_activeTab(tester), 'Overview');

    await _tapNav(tester, 'Orders');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_activeTab(tester), 'Overview');
  });

  // ---------------------------------------------------------------- TASK B ---

  testWidgets('orders split into Upcoming / Current / Paid, in that order', (tester) async {
    final rest = await _ordersRest([
      _order('o1', 'Pending'),
      _order('o2', 'Preparing'),
      _order('o3', 'Served'),
      _order('o4', 'Bill Verification'),
      _order('o5', 'Paid'),
      _order('o6', 'Closed'),
      _order('o7', 'Cancelled'),
    ]);

    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(_sectionTitles(tester), ['Upcoming', 'Current', 'Paid']);
    final headers = tester.widgetList<SectionHeader>(find.byType(SectionHeader)).toList();
    expect(headers[0].count, 1); // Pending
    expect(headers[1].count, 3); // Preparing + Served + Bill Verification
    expect(headers[2].count, 3); // Paid + Closed + Cancelled
    // Cancelled is never dropped, and the section says it holds more than sales.
    expect(find.text('Settled, closed and cancelled'), findsOneWidget);
    expect(find.textContaining('Guest o7'), findsOneWidget);
  });

  testWidgets('a section with nothing in it collapses away', (tester) async {
    final rest = await _ordersRest([_order('o1', 'Preparing')]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(_sectionTitles(tester), ['Current']);
  });

  testWidgets('a settled order older than 24h is hidden; a 23h one stays', (tester) async {
    final rest = await _ordersRest([
      _order('old', 'Paid', ageHours: 25),
      _order('new', 'Paid', ageHours: 23),
    ]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Guest new'), findsOneWidget);
    expect(find.textContaining('Guest old'), findsNothing);
    // Nothing cancelled in there, so the header makes no claim about it.
    expect(find.text('Settled, closed and cancelled'), findsNothing);
    // Hidden, not deleted — and the page says where it went.
    expect(find.textContaining('1 settled order placed over 24 hours ago is hidden'), findsOneWidget);
    expect(find.textContaining('they are in History'), findsOneWidget);
  });

  // History is permissioned. A user who cannot open it must not be told to go
  // there — the reassurance that nothing was deleted still has to land, but the
  // sentence has to be true for the person reading it.
  testWidgets('the hidden-orders note does not promise History to a user without it', (tester) async {
    final rest = await _ordersRest([
      _order('old', 'Paid', ageHours: 25),
      _order('new', 'Paid', ageHours: 23),
    ]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!), visible: const ['Orders']));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 settled order placed over 24 hours ago is hidden'), findsOneWidget);
    expect(find.textContaining('they are in History'), findsNothing);
    // Still accounted for, and it says what the user can actually do about it.
    expect(find.textContaining('Nothing was deleted'), findsOneWidget);
    expect(find.textContaining('anyone with History access'), findsOneWidget);
    // And no button to a module this user cannot open.
    expect(find.widgetWithText(ForkButton, 'History'), findsNothing);
  });

  testWidgets('an unpaid order past 24h is never hidden — it is flagged', (tester) async {
    final rest = await _ordersRest([
      _order('stale', 'Served', ageHours: 30),
      _order('fresh', 'Preparing', ageHours: 2),
    ]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Guest stale'), findsOneWidget);
    expect(find.text('Over 24h · unsettled'), findsOneWidget);
    // Nothing was removed, so the page makes no claim that anything was.
    expect(find.textContaining('hidden here'), findsNothing);
  });

  testWidgets('an order with no created_at is never aged out', (tester) async {
    final rest = await _ordersRest([
      {'id': 'x', 'table': 'T1', 'customer': 'Guest x', 'status': 'Paid', 'items': <dynamic>[], 'total': 10},
    ]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Guest x'), findsOneWidget);
    expect(_sectionTitles(tester), ['Paid']);
  });

  testWidgets('every order aged out leaves an explanation, not a blank page', (tester) async {
    final rest = await _ordersRest([_order('o1', 'Paid', ageHours: 40)]);
    await tester.pumpWidget(_hostOrders(m.ordersModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();

    expect(find.text('No orders yet'), findsOneWidget);
    expect(find.textContaining('hidden here'), findsOneWidget);
  });
}
