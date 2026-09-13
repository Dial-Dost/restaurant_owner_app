import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/auth_controller.dart';
import 'ui/gaia/gaia.dart';
import 'ui/theme/app_colors.dart';
import 'ui/theme/app_scrollbar.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/appearance.dart';

// Desktop mice can't drag-scroll a horizontal ScrollView by default (only the
// wheel/trackpad do). Add mouse (and stylus) to the accepted drag devices so
// every horizontal chip/tab row — analytics view picker, KDS station filter —
// scrolls by click-drag app-wide.
class _DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  // 6.2 — Material draws a scrollbar on desktop only; on a phone a list simply
  // has none, so there was nothing to grab however hard scrolling got. Phones
  // now get one too: the theme's fading overlay (see [AppScrollbar]), which is
  // invisible — and not hit-testable — until the list moves. Vertical only, as
  // on desktop: a chip row's bar would sit on top of the chips.
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (axisDirectionToAxis(details.direction) == Axis.vertical &&
        !AppScrollbar.isDesktop(getPlatform(context))) {
      return Scrollbar(controller: details.controller, child: child);
    }
    return super.buildScrollbar(context, child, details);
  }
}

class OwnerApp extends StatefulWidget {
  const OwnerApp({super.key});

  @override
  State<OwnerApp> createState() => _OwnerAppState();
}

class _OwnerAppState extends State<OwnerApp> {
  final AuthController auth = AuthController();

  @override
  void initState() {
    super.initState();
    auth.init();
  }

  @override
  void dispose() {
    auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole tree when the device accent changes: AppTheme
    // and every module read the accent through AppColors getters, so one
    // rebuild here recolours the app with no per-module wiring.
    //
    // The same rebuild is what makes the DESIGN SYSTEM switch live. Handing
    // MaterialApp the other ThemeData restyles in place — Flutter tweens
    // between the two themes and every module re-reads its text theme on the
    // next build — so flipping Gaia on needs no restart and no route reset.
    return AnimatedBuilder(
      animation: AppearanceController.instance,
      // Above MaterialApp, so every primitive below can DEPEND on the design
      // system rather than reading it statically. That dependency is what
      // makes const call sites (there are 88 of them) restyle on a flip —
      // see Gaia.of.
      builder: (context, _) => GaiaScope(
        system: AppearanceController.instance.designSystem,
        child: MaterialApp(
      title: 'Restaurant Dash — Owner',
      debugShowCheckedModeBanner: false,
      scrollBehavior: _DragScrollBehavior(),
      // 6.6 — AppTheme.active() is the light theme while a light palette
      // (White / Beige) is applied, the shipped dark theme otherwise. The
      // palette itself was applied by AppearanceController.load() before
      // runApp, so a light till's first frame is already light.
      theme: Gaia.isActive ? GaiaTheme.dark() : AppTheme.active(),
      home: AnimatedBuilder(
        animation: auth,
        builder: (context, _) {
          if (!auth.initialized) {
            return Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(
                child: CircularProgressIndicator(color: AppColors.copper),
              ),
            );
          }
          return auth.isAuthenticated ? HomeShell(auth: auth) : LoginScreen(auth: auth);
        },
      ),
        ),
      ),
    );
  }
}
