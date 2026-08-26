import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/gradient_backdrop.dart';

/// The owner's report: "changing the accent does not recolour the sidebar on my
/// phone." The mechanism was CAPTURED colour, not a broken rebuild boundary —
/// the drawer floats opaque above the page, so it carried hand-sampled copper
/// composites in a `const BoxDecoration`, and no amount of rebuilding recolours
/// a frozen hex. (The boundary itself is fine: the root AnimatedBuilder rebuilds
/// MaterialApp, `NavigatorState.didUpdateWidget` calls `changedExternalState()`
/// on every open route, and `_ModalScope._forceRebuildPage()` drops the cached
/// page — so dialogs and sheets already re-run their builders.)
///
/// These tests pin BOTH halves: the drawer now derives its glow from the live
/// accent (recolouring while OPEN, without reopening), and the modal-route path
/// keeps reaching open dialogs and bottom sheets, so no overlay can quietly
/// fall back to captured colour again.
class _FakeApi extends ApiClient {
  _FakeApi();

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
    throw ApiException('No fake route for $path', 404);
  }
}

Future<AuthController> _signIn() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi());
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

/// The tree exactly as lib/app.dart builds it: the ONE AnimatedBuilder on the
/// appearance controller wrapping MaterialApp. The bug (and the fix) only mean
/// anything under the app's real rebuild boundary.
///
/// `home` is a BUILDER, not a widget, for the same reason app.dart constructs
/// `HomeShell(auth: auth)` inside its builder closure: hand the same instance
/// back on every rebuild and `Element.updateChild` short-circuits on identity —
/// the shell subtree never rebuilds and the test would pass or fail on harness
/// wiring instead of on the app's behaviour.
Widget _appRoot(Widget Function() home) => AnimatedBuilder(
      animation: AppearanceController.instance,
      builder: (context, _) => MaterialApp(theme: AppTheme.dark(), home: home()),
    );

/// The drawer's own glow gradient: the one three-stop LinearGradient in the
/// drawer subtree. Matching on shape rather than position keeps the probe from
/// silently reading some other DecoratedBox if the drawer grows children.
LinearGradient _drawerGlow(WidgetTester tester) {
  final boxes = tester.widgetList<DecoratedBox>(
    find.descendant(of: find.byType(Drawer), matching: find.byType(DecoratedBox)),
  );
  for (final b in boxes) {
    final deco = b.decoration;
    if (deco is BoxDecoration && deco.gradient is LinearGradient) {
      final g = deco.gradient! as LinearGradient;
      if (g.colors.length == 3) return g;
    }
  }
  fail('no three-stop drawer glow gradient found');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppearanceController.instance.debugReset();
  });

  tearDown(() {
    AppearanceController.instance.debugReset();
  });

  testWidgets('phone drawer recolours with the accent while it is OPEN', (tester) async {
    final auth = await _signIn();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appRoot(() => HomeShell(auth: auth, startPrinterAgent: false)));
    await tester.pump();
    await tester.pump();

    // Open the drawer and let its slide-in finish.
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(Drawer), findsOneWidget);

    final before = _drawerGlow(tester).colors;
    expect(before, [AppColors.drawerTop, AppColors.drawerMid, AppColors.drawerBottom]);

    // The owner's gesture: change the accent (from anywhere) with the drawer up.
    await AppearanceController.instance.setAccent('teal');
    await tester.pump();

    // Still the SAME open drawer — nothing was closed or reopened — and its
    // glow now derives from teal, not the copper it was born under.
    expect(find.byType(Drawer), findsOneWidget);
    final after = _drawerGlow(tester).colors;
    expect(after, [AppColors.drawerTop, AppColors.drawerMid, AppColors.drawerBottom]);
    expect(after, isNot(orderedEquals(before)),
        reason: 'the open drawer must not keep wearing the previous accent');

    // And the derivation really tracks the ramp: teal glow in, copper glow out.
    expect(AppColors.glowDeep, AppAccents.teal.glowDeep);
  });

  testWidgets('scheme change repaints the shell ground live', (tester) async {
    final auth = await _signIn();
    await tester.pumpWidget(_appRoot(() => HomeShell(auth: auth, startPrinterAgent: false)));
    await tester.pump();
    await tester.pump();

    // The backdrop's base layer is the page every other layer sits on — if it
    // tracks the scheme, the shell ground genuinely moved.
    Color ground() => tester
        .widget<ColoredBox>(find
            .descendant(of: find.byType(GradientBackdrop), matching: find.byType(ColoredBox))
            .first)
        .color;
    expect(ground(), AppSchemes.rustic.bg);

    await AppearanceController.instance.setScheme('graphite');
    await tester.pump();
    expect(ground(), AppSchemes.graphite.bg);
    expect(AppColors.textPrimary, AppSchemes.graphite.textPrimary);
  });

  testWidgets('an OPEN dialog recolours with the accent', (tester) async {
    await tester.pumpWidget(_appRoot(() => const Scaffold(body: SizedBox())));
    await tester.pump();

    final ctx = tester.element(find.byType(Scaffold));
    showDialog<void>(
      context: ctx,
      // Reads the accent the way every module does: straight off the getters.
      builder: (_) => AlertDialog(
        content: Icon(Icons.circle, color: AppColors.copperHi),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<Icon>(find.byIcon(Icons.circle)).color, AppAccents.copper.hi);

    await AppearanceController.instance.setAccent('steel');
    await tester.pump();

    // The dialog was never closed; the modal route re-ran its builder.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Icons.circle)).color, AppAccents.steel.hi);
  });

  testWidgets('an OPEN bottom sheet recolours with the accent', (tester) async {
    await tester.pumpWidget(_appRoot(() => const Scaffold(body: SizedBox())));
    await tester.pump();

    final ctx = tester.element(find.byType(Scaffold));
    showModalBottomSheet<void>(
      context: ctx,
      builder: (_) => Icon(Icons.square, color: AppColors.copper),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<Icon>(find.byIcon(Icons.square)).color, AppAccents.copper.base);

    await AppearanceController.instance.setAccent('rose');
    await tester.pump();

    expect(find.byIcon(Icons.square), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Icons.square)).color, AppAccents.rose.base);
  });
}
