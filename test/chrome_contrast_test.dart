import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';

/// The navigation chrome is light while the workspace stays dark, so every
/// foreground in it is one careless edit away from light-on-light. These tests
/// read the colours the shell actually paints and measure them, rather than
/// asserting a list of hex values that would still pass if the surface were
/// flipped and the ink left behind.

// ---------------------------------------------------------------- contrast ---

double _channel(int v) {
  final c = v / 255.0;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// WCAG 2.1 relative luminance. Opaque colours only — composite first.
double _luminance(Color c) {
  final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
  return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);
}

/// WCAG 2.1 contrast ratio, 1.0 (identical) .. 21.0 (black on white).
double _contrast(Color fg, Color bg) {
  final a = _luminance(fg), b = _luminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// What the eye sees when [fg] is painted at its own alpha over opaque [bg].
Color _over(Color fg, Color bg) {
  final a = fg.a;
  return Color.fromARGB(
    255,
    ((fg.r * a + bg.r * (1 - a)) * 255).round(),
    ((fg.g * a + bg.g * (1 - a)) * 255).round(),
    ((fg.b * a + bg.b * (1 - a)) * 255).round(),
  );
}

void _expectContrast(String what, Color fg, Color bg, double min) {
  final ratio = _contrast(_over(fg, bg), bg);
  expect(ratio, greaterThanOrEqualTo(min),
      reason: '$what is ${ratio.toStringAsFixed(2)}:1, below the required $min:1');
}

// ------------------------------------------------------------------ harness ---

class _FakeApi extends ApiClient {
  _FakeApi({this.outlets = 0});

  /// How many branches the outlet switcher has to choose from. The switcher only
  /// exists above one.
  final int outlets;

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
    if (path == '/outlets') {
      return <String, dynamic>{
        'outlets': [
          for (var i = 0; i < outlets; i++)
            <String, dynamic>{'id': 'o$i', 'outlet_name': 'Branch $i', 'is_active': true},
        ],
      };
    }
    throw ApiException('No fake route for $path', 404);
  }
}

Future<AuthController> _signIn({int outlets = 0, bool collapsed = false}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{'sidebar_collapsed': collapsed});
  final auth = AuthController(api: _FakeApi(outlets: outlets));
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

Future<void> _pumpShell(WidgetTester tester,
    {required Size size, int outlets = 0, bool collapsed = false}) async {
  final auth = await _signIn(outlets: outlets, collapsed: collapsed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // The printer agent opens a real socket and a keep-alive timer fake-async
  // cannot own.
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump(); // settle the preference + outlet futures from initState
  await tester.pump();
  // Past the collapse/expand animation, so a width read is the settled one.
  await tester.pump(const Duration(milliseconds: 400));
}

// --------------------------------------------------------------- inspection ---

/// The fixed sidebar's nav list. The narrow layout's copy lives in the Drawer,
/// behind the module's own lists, so it has to be scoped explicitly.
Finder _sidebarNav() => find.byType(ListView).first;

Finder _drawerNav() =>
    find.descendant(of: find.byType(Drawer), matching: find.byType(ListView)).first;

Finder _navLabel(Finder nav, String label) => find.descendant(of: nav, matching: find.text(label));

/// The paper the fixed sidebar is painted on.
Color _sidebarSurface(WidgetTester tester) {
  final sidebar = find.ancestor(of: _sidebarNav(), matching: find.byType(AnimatedContainer)).last;
  return (tester.widget<AnimatedContainer>(sidebar).decoration! as BoxDecoration).color!;
}

TextStyle _navLabelStyle(WidgetTester tester, Finder nav, String label) =>
    tester.widget<Text>(_navLabel(nav, label)).style!;

/// The colour an [Icon] resolves to once the ambient icon themes have had
/// their say — not the (usually null) `color` on the widget.
Color _paintedIconColor(WidgetTester tester, Finder icon) {
  final rich = tester.widget<RichText>(find.descendant(of: icon, matching: find.byType(RichText)));
  return rich.text.style!.color!;
}

Color _navIconColor(WidgetTester tester, Finder nav, String label) {
  final row = find.ancestor(of: _navLabel(nav, label), matching: find.byType(Row)).first;
  return _paintedIconColor(tester, find.descendant(of: row, matching: find.byType(Icon)).first);
}

/// The pill behind a nav entry.
Color? _navFill(WidgetTester tester, Finder nav, String label) {
  final container =
      find.ancestor(of: _navLabel(nav, label), matching: find.byType(AnimatedContainer)).first;
  return (tester.widget<AnimatedContainer>(container).decoration! as BoxDecoration).color;
}

/// The collapsed rail drops the labels, so its entries are addressed by icon.
Finder _railEntry(Finder nav, IconData icon) =>
    find.descendant(of: nav, matching: find.byIcon(icon));

Color? _railFill(WidgetTester tester, Finder nav, IconData icon) {
  final container =
      find.ancestor(of: _railEntry(nav, icon), matching: find.byType(AnimatedContainer)).first;
  return (tester.widget<AnimatedContainer>(container).decoration! as BoxDecoration).color;
}

/// Parks a mouse on [target] and leaves it there for the rest of the test.
Future<void> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

void main() {
  group('chrome tokens', () {
    test('the chrome surface is light and its ink is dark enough to read', () {
      // Light, not merely "not black" — the whole point of the inversion.
      expect(_luminance(AppColors.chromeSurface), greaterThan(0.7));

      _expectContrast('chromeText', AppColors.chromeText, AppColors.chromeSurface, 4.5);
      _expectContrast('chromeTextMuted', AppColors.chromeTextMuted, AppColors.chromeSurface, 4.5);
      _expectContrast('chromeIcon', AppColors.chromeIcon, AppColors.chromeSurface, 3.0);
      _expectContrast('chromeAccent', AppColors.chromeAccent, AppColors.chromeSurface, 3.0);
      _expectContrast('chromeDivider', AppColors.chromeDivider, AppColors.chromeSurface, 1.1);
      // The seam has to be visible from the paper side.
      _expectContrast('chromeEdge', AppColors.chromeEdge, AppColors.chromeSurface, 3.0);
    });

    test('the selected pill is unmistakable, and carries its own ink', () {
      _expectContrast('chromeActive vs chromeSurface', AppColors.chromeActive, AppColors.chromeSurface, 3.0);
      _expectContrast('onChromeActive', AppColors.onChromeActive, AppColors.chromeActive, 4.5);
      _expectContrast('chromeActiveAccent', AppColors.chromeActiveAccent, AppColors.chromeActive, 3.0);
    });

    test('the dark-theme ink is exactly what must never land on the chrome', () {
      // Guards the reason this block exists: if someone "simplifies" a chrome
      // token back to a workspace one, these stop being true.
      expect(_contrast(AppColors.textPrimary, AppColors.chromeSurface), lessThan(3.0));
      expect(_contrast(AppColors.textSecondary, AppColors.chromeSurface), lessThan(3.0));
      expect(_contrast(AppColors.copperHi, AppColors.chromeSurface), lessThan(3.0));
    });
  });

  testWidgets('the wide sidebar paints the light chrome with dark-on-light nav ink', (tester) async {
    await _pumpShell(tester, size: const Size(1280, 900));

    final nav = _sidebarNav();
    final surface = _sidebarSurface(tester);
    expect(surface, AppColors.chromeSurface);

    // Idle entry: dark ink on the paper, measured against the surface the
    // sidebar is actually painted with.
    final idle = _navLabelStyle(tester, nav, 'Orders');
    expect(idle.color, AppColors.chromeTextMuted);
    expect(_navFill(tester, nav, 'Orders'), Colors.transparent);
    _expectContrast('idle nav label', idle.color!, surface, 4.5);
    _expectContrast('idle nav icon', _navIconColor(tester, nav, 'Orders'), surface, 3.0);

    // Selected entry: the ink inverts because the pill does.
    final active = _navLabelStyle(tester, nav, 'Overview');
    final fill = _navFill(tester, nav, 'Overview')!;
    expect(active.color, AppColors.onChromeActive);
    expect(fill, AppColors.chromeActive);
    _expectContrast('selected pill vs chrome', fill, surface, 3.0);
    _expectContrast('selected nav label', active.color!, fill, 4.5);
    _expectContrast('selected nav icon', _navIconColor(tester, nav, 'Overview'), fill, 3.0);

    // Brand lockup and section eyebrow.
    for (final t in ['CSR Organics', 'OWNER WORKSPACE', 'WORKSPACE']) {
      _expectContrast('"$t"', tester.widget<Text>(find.text(t).first).style!.color!, surface, 4.5);
    }

    // The nav is taller than any window, so the thumb is a control the user has
    // to be able to see and grab — and the app-wide one is translucent white.
    final scrollbar = tester.widget<ScrollbarTheme>(
        find.ancestor(of: _sidebarNav(), matching: find.byType(ScrollbarTheme)).first);
    _expectContrast('sidebar scrollbar thumb',
        scrollbar.data.thumbColor!.resolve(<WidgetState>{})!, surface, 3.0);

    // Hover: the wash is translucent, so the ink is measured against what the
    // eye actually sees — the wash composited onto the paper.
    await _hover(tester, _navLabel(nav, 'Orders'));
    final hoverFill = _navFill(tester, nav, 'Orders')!;
    expect(hoverFill, AppColors.chromeHover);
    final hovered = _over(hoverFill, surface);
    _expectContrast('hovered nav label', _navLabelStyle(tester, nav, 'Orders').color!, hovered, 4.5);
    _expectContrast('hovered nav icon', _navIconColor(tester, nav, 'Orders'), hovered, 3.0);
  });

  testWidgets('the collapsed rail keeps its dark ink once the labels are gone', (tester) async {
    await _pumpShell(tester, size: const Size(1280, 900), collapsed: true);

    final nav = _sidebarNav();
    final surface = _sidebarSurface(tester);
    expect(surface, AppColors.chromeSurface);
    // Actually the rail, not the full sidebar with its labels clipped away.
    expect(find.descendant(of: nav, matching: find.text('Orders')), findsNothing);

    // Icons are all the rail has left; if they go light-on-light there is
    // nothing else to navigate by.
    _expectContrast('rail idle icon',
        _paintedIconColor(tester, _railEntry(nav, Icons.receipt_long)), surface, 3.0);
    final activeFill = _railFill(tester, nav, Icons.dashboard)!;
    expect(activeFill, AppColors.chromeActive);
    _expectContrast('rail selected pill', activeFill, surface, 3.0);
    _expectContrast('rail selected icon',
        _paintedIconColor(tester, _railEntry(nav, Icons.dashboard)), activeFill, 3.0);
    // The expand control at the head of the rail.
    _expectContrast('expand-sidebar toggle',
        _paintedIconColor(tester, find.byTooltip('Expand sidebar')), surface, 3.0);
  });

  testWidgets('the app bar is the same light chrome, and its icons survive it', (tester) async {
    await _pumpShell(tester, size: const Size(1280, 900));

    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.backgroundColor, AppColors.chromeSurface);
    final surface = bar.backgroundColor!;

    // The module title.
    final title = tester.widget<Text>(
        find.descendant(of: find.byType(AppBar), matching: find.text('Overview')));
    _expectContrast('app bar title', title.style!.color!, surface, 4.5);

    // An action the shell does not colour itself: it inherits through the
    // AppBar's actionsIconTheme, which only reaches an IconButton because the
    // theme spells out an iconButtonTheme. Regression guard for that plumbing.
    _expectContrast(
      'app bar action icon',
      _paintedIconColor(tester, find.widgetWithIcon(IconButton, Icons.refresh)),
      surface,
      3.0,
    );
    // Back is inert (and deliberately greyed) until something is behind it, so
    // it is measured in the state a user can actually press.
    await tester.tap(_navLabel(_sidebarNav(), 'Orders'));
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back)).onPressed,
        isNotNull);
    // Past the button's own enabled/disabled colour transition, so the ink
    // being measured is the settled one and not a frame mid-lerp.
    await tester.pump(const Duration(milliseconds: 250));
    _expectContrast(
      'back button icon',
      _paintedIconColor(tester, find.widgetWithIcon(IconButton, Icons.arrow_back)),
      surface,
      3.0,
    );
    // Sign out is a TextButton: without its own style it would inherit the
    // copper primary, which is 2.1:1 on paper.
    // byWidgetPredicate, not byType: TextButton.icon builds a private subclass.
    final signOut = tester.widget<TextButton>(find
        .ancestor(of: find.text('Sign out'), matching: find.byWidgetPredicate((w) => w is TextButton))
        .first);
    _expectContrast(
      'sign out',
      signOut.style!.foregroundColor!.resolve(<WidgetState>{})!,
      surface,
      4.5,
    );
  });

  testWidgets('the outlet switcher reads on the paper, and its menu on the card', (tester) async {
    await _pumpShell(tester, size: const Size(1280, 900), outlets: 2);

    final button = find.byTooltip('Switch outlet');
    expect(button, findsOneWidget);
    _expectContrast('outlet switcher icon', _paintedIconColor(tester, button),
        AppColors.chromeSurface, 3.0);

    await tester.tap(button);
    await tester.pumpAndSettle();

    // The menu is a DARK card opened from the light chrome, and a popup route
    // carries the InheritedThemes above its button into the overlay with it —
    // so chrome ink is one stray IconTheme away from landing on the card. The
    // checkmark is the only thing that says which outlet is active.
    final check = find.descendant(
        of: find.widgetWithText(CheckedPopupMenuItem<String>, 'Branch 0'),
        matching: find.byType(Icon));
    expect(check, findsOneWidget);
    _expectContrast('outlet menu checkmark', _paintedIconColor(tester, check),
        AppColors.cardRaised, 3.0);
  });

  testWidgets('the narrow drawer uses the same chrome as the sidebar', (tester) async {
    await _pumpShell(tester, size: const Size(420, 900));

    // No fixed sidebar at this width — the nav lives behind the drawer button.
    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    final nav = _drawerNav();
    final surface = tester.widget<Drawer>(find.byType(Drawer)).backgroundColor!;
    expect(surface, AppColors.chromeSurface);
    _expectContrast('drawer nav label', _navLabelStyle(tester, nav, 'Orders').color!, surface, 4.5);
    _expectContrast('drawer nav icon', _navIconColor(tester, nav, 'Orders'), surface, 3.0);
    _expectContrast('drawer selected label', _navLabelStyle(tester, nav, 'Overview').color!,
        _navFill(tester, nav, 'Overview')!, 4.5);
    // The drawer button that opened it sits on the same paper.
    _expectContrast('drawer button',
        _paintedIconColor(tester, find.byTooltip('Open navigation menu')), surface, 3.0);
  });
}
