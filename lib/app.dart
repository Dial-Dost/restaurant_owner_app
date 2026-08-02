import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/auth_controller.dart';
import 'ui/theme/app_colors.dart';
import 'ui/theme/app_theme.dart';

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
    return MaterialApp(
      title: 'Restaurant Dash — Owner',
      debugShowCheckedModeBanner: false,
      scrollBehavior: _DragScrollBehavior(),
      theme: AppTheme.dark(),
      home: AnimatedBuilder(
        animation: auth,
        builder: (context, _) {
          if (!auth.initialized) {
            return const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(
                child: CircularProgressIndicator(color: AppColors.copper),
              ),
            );
          }
          return auth.isAuthenticated ? HomeShell(auth: auth) : LoginScreen(auth: auth);
        },
      ),
    );
  }
}
