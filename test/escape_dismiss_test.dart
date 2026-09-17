import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printer_service.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';

/// Canned responses in place of the network; unknown routes throw, which every
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

Future<AuthController> _signIn([Map<String, dynamic> routes = const {}]) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi(routes));
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

// The label the shell is showing, read off the AppBar (every module label also
// appears in the sidebar).
String _activeTab(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(AppBar), matching: find.byType(Text)))
    .first
    .data!;

Future<void> _pumpShell(WidgetTester tester, AuthController auth, {double width = 1280}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Printer agent off: it opens a real socket and a keep-alive timer that
  // fake-async cannot own.
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump();
}

Future<void> _tapNav(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(ListView).first, matching: find.text(label)));
  await tester.pumpAndSettle();
}

const _menuRoutes = <String, dynamic>{
  '/menu': [
    {'id': 'm1', 'name': 'Paneer Tikka', 'price': 320, 'category': 'Starters', 'available': true},
    {'id': 'm2', 'name': 'Dal Makhani', 'price': 280, 'category': 'Mains', 'available': true},
  ],
};

// The Menu module's search box, located by its hint rather than by position so
// another field appearing on the screen cannot silently retarget the test.
Finder _searchField() =>
    find.ancestor(of: find.text('Search menu…'), matching: find.byType(TextField));

void main() {
  // CLIENT ITEM 6 (2.0.2): the search box opted in, as this shell always
  // allowed a field to — Escape on a box with text now CLEARS it. What has not
  // changed: Escape while typing never navigates, whether the box has text or
  // has just been emptied.
  testWidgets('Escape while typing in a search box clears it, and never navigates',
      (tester) async {
    final auth = await _signIn(_menuRoutes);
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Menu');
    expect(_activeTab(tester), 'Menu');

    await tester.enterText(_searchField(), 'pan');
    await tester.pumpAndSettle();
    expect(find.text('Search results'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Still on Menu, the box is empty and the whole menu is back.
    expect(_activeTab(tester), 'Menu');
    expect(find.widgetWithText(TextField, 'pan'), findsNothing);
    expect(find.text('Search results'), findsNothing);
    final box = tester.widget<EditableText>(find.descendant(of: _searchField(), matching: find.byType(EditableText)));
    expect(box.controller.text, isEmpty);
    expect(box.focusNode.hasFocus, isTrue, reason: 'the caret stays for the next word');

    // A second Escape, on the empty box the caret is still in: still Menu.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_activeTab(tester), 'Menu');
  });

  testWidgets('Escape outside a text field still walks the back trail', (tester) async {
    final auth = await _signIn(_menuRoutes);
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Orders');
    expect(_activeTab(tester), 'Orders');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_activeTab(tester), 'Overview');
  });

  // Regression: the shell's Actions used to sit only OUTSIDE the Scaffold, but
  // Scaffold registers its own DismissIntent and Actions.maybeFind stops at the
  // first MAPPING rather than the first ENABLED one. So the moment focus moved
  // into the body -- one Tab was enough -- Scaffold's disabled drawer action was
  // found, the key was reported unhandled, and Escape-as-Back was dead for the
  // rest of the session. Every earlier test passed because none of them ever
  // moved focus off the shell root.
  testWidgets('Escape still walks back after focus has moved into the body',
      (tester) async {
    final auth = await _signIn(_menuRoutes);
    await _pumpShell(tester, auth);

    await _tapNav(tester, 'Orders');
    expect(_activeTab(tester), 'Orders');

    // Move primary focus off the shell root and into the Scaffold's subtree.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_activeTab(tester), 'Overview');
  });

  testWidgets('Escape with the drawer open closes the drawer and leaves the tab alone',
      (tester) async {
    final auth = await _signIn();
    // Narrow: nav lives in a drawer instead of the fixed sidebar.
    await _pumpShell(tester, auth, width: 600);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Orders')));
    await tester.pumpAndSettle();
    expect(_activeTab(tester), 'Orders');

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // One keypress, one undo: the drawer closes and the tab underneath stays.
    expect(find.byType(Drawer), findsNothing);
    expect(_activeTab(tester), 'Orders');

    // The trail is untouched, so the next Escape does the navigating.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_activeTab(tester), 'Overview');
  });

  testWidgets('the printer agent is gated by an explicit flag, not the environment',
      (tester) async {
    // `flutter test` sets FLUTTER_TEST in this very process — the shipped
    // default must not care.
    expect(Platform.environment.containsKey('FLUTTER_TEST'), isTrue,
        reason: 'the test runner is expected to set FLUTTER_TEST');
    final auth = await _signIn();
    expect(HomeShell(auth: auth).startPrinterAgent, isTrue);

    // And the flag is what actually keeps the agent out of a test: with it off
    // nothing connects, so the agent's log stays empty.
    await _pumpShell(tester, auth);
    await tester.pumpAndSettle();
    expect(PrinterService.instance.logs, isEmpty);
  });
}
