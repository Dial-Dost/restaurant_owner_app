import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The app bar on a PHONE. No test in this suite had ever mounted the shell
/// narrower than 600px — which is `narrow` (so it took the drawer branch) but
/// still leaves 352px of title room — so the one layout that could not fit was
/// the one nobody measured. The owner's screenshot is the result: the module name
/// printed straight through the outlet icon, because the title lived in a bare
/// `Row` whose non-flex `Text` was laid out at its natural width and painted past
/// the Row's own box (a Flex clips nothing).
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

/// Two outlets, so the app bar carries the outlet switcher — the fourth action,
/// and the 48dp that tipped the title over the edge.
const _twoOutlets = <String, dynamic>{
  '/outlets': {
    'outlets': [
      {'id': 'o1', 'outlet_name': 'Main kitchen', 'is_active': true},
      {'id': 'o2', 'outlet_name': 'Airport counter', 'is_active': true},
    ],
  },
};

Future<AuthController> _signIn([Map<String, dynamic> routes = _twoOutlets]) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi(routes));
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

Future<void> _pumpShell(WidgetTester tester, AuthController auth, {required double width}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Printer agent off: it opens a real socket and a keep-alive timer that
  // fake-async cannot own.
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  // Two pumps: /outlets is fetched in initState, so the switcher only exists once
  // that has landed.
  await tester.pump();
  await tester.pump();
}

/// Jumps the shell to a module by name — the shell's own openModule, which is
/// also what a tapped notification uses. Far steadier than reaching into the
/// drawer for a row that may be below the fold on a 320px screen.
Future<void> _open(WidgetTester tester, String label) async {
  tester.widget<ModuleNavigator>(find.byType(ModuleNavigator)).openModule(label);
  await tester.pump();
  await tester.pump();
}

Finder _inBar(Finder matching) =>
    find.descendant(of: find.byType(AppBar), matching: matching);

Rect _titleRect(WidgetTester tester, String label) =>
    tester.getRect(find.descendant(of: find.byType(AppBar), matching: find.text(label)).first);

/// The left edge of the leftmost trailing control — anything in the bar that sits
/// to the right of where the title text starts. The back button and the drawer
/// button are excluded by construction: both are to the LEFT of the label.
double _actionsLeftEdge(WidgetTester tester, double titleLeft) {
  var edge = double.infinity;
  final bar = find.byType(AppBar);
  for (final matching in <Finder>[find.byType(IconButton), find.byType(TextButton)]) {
    final found = find.descendant(of: bar, matching: matching);
    for (var i = 0; i < found.evaluate().length; i++) {
      final rect = tester.getRect(found.at(i));
      if (rect.left > titleLeft && rect.left < edge) edge = rect.left;
    }
  }
  return edge;
}

// Every label that overflowed a 360dp phone in the diagnosis, plus the two that
// were merely close. Anything the shell can show has to fit or truncate — never
// paint over a control.
const _longLabels = ['Overview', 'Analytics', 'Attendance', 'Cash register', 'Purchase Orders'];

void main() {
  // 320 is the narrowest Android phone still in service and the floor the fix has
  // to hold; 360 is the owner's device; 390/411 are the common portrait sizes.
  for (final width in [320.0, 360.0, 390.0, 411.0]) {
    testWidgets('the app bar lays out with no overflow at ${width.toInt()}dp', (tester) async {
      final auth = await _signIn();
      await _pumpShell(tester, auth, width: width);

      for (final label in _longLabels) {
        await _open(tester, label);
        // A widget test FAILS on a RenderFlex overflow, so this is the real
        // assertion, not a smoke test.
        expect(tester.takeException(), isNull,
            reason: '"$label" overflowed the app bar at ${width.toInt()}dp');
      }
    });

    testWidgets('the title never reaches an action at ${width.toInt()}dp', (tester) async {
      final auth = await _signIn();
      await _pumpShell(tester, auth, width: width);

      for (final label in _longLabels) {
        await _open(tester, label);
        final title = _titleRect(tester, label);
        final actions = _actionsLeftEdge(tester, title.left);
        expect(actions.isFinite, isTrue,
            reason: 'no trailing action found at ${width.toInt()}dp');
        expect(title.right, lessThanOrEqualTo(actions),
            reason: '"$label" ran into the actions at ${width.toInt()}dp '
                '(title ends ${title.right}, first action starts $actions)');
      }
    });
  }

  testWidgets('a phone folds the low-priority actions away but loses none of them',
      (tester) async {
    final auth = await _signIn();
    await _pumpShell(tester, auth, width: 360);

    // The three that moved: the outlet switcher, Refresh and Sign out. (Scoped to
    // the AppBar — the nav list carries an "Outlets" entry with the same glyph.)
    expect(_inBar(find.byIcon(Icons.store_mall_directory)), findsNothing);
    expect(_inBar(find.byIcon(Icons.refresh)), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    // The bell stays on the bar — it is the one action that carries a count.
    expect(_inBar(find.byIcon(Icons.notifications_outlined)), findsOneWidget);
    expect(_inBar(find.byIcon(Icons.more_vert)), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    // Nothing was dropped: every folded control is one tap away, including the
    // route to the combined view, which is only reachable from this menu.
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('All outlets (combined)'), findsOneWidget);
    expect(find.text('Main kitchen'), findsOneWidget);
    expect(find.text('Airport counter'), findsOneWidget);
  });

  testWidgets('the folded switcher still selects an outlet', (tester) async {
    final auth = await _signIn();
    await _pumpShell(tester, auth, width: 360);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // The tap target is the menu item's ink, not the label itself.
    await tester.tap(find.text('Airport counter'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(auth.selectedOutletId, 'o2');
  });

  testWidgets('the desktop chrome is untouched', (tester) async {
    final auth = await _signIn();
    await _pumpShell(tester, auth, width: 1280);

    // All four actions still spelled out, and no overflow button in sight.
    expect(_inBar(find.byIcon(Icons.store_mall_directory)), findsOneWidget);
    expect(_inBar(find.byIcon(Icons.refresh)), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(_inBar(find.byIcon(Icons.more_vert)), findsNothing);

    await _open(tester, 'Purchase Orders');
    expect(tester.takeException(), isNull);
    final title = _titleRect(tester, 'Purchase Orders');
    expect(title.right, lessThanOrEqualTo(_actionsLeftEdge(tester, title.left)));
  });
}
