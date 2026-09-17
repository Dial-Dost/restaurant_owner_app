import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/menu_badge.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_spacing.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/empty_state.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/appearance_card.dart';
import 'package:restaurant_owner_app/widgets/menu_badges.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// FIXED-HEIGHT BOXES A PHONE AT LARGE TEXT OUTGREW.
///
/// Each place below put text in a box of a set height, sized on a desktop at
/// 1x. On a 360dp phone at 1.3x the text wraps and grows, and the box does not:
///
///   * the menu badges dialog squeezed its first-run empty state (and the
///     "Use the starter set" button in it) into whatever the dialog had left,
///     which cut the button off even on a desktop, and its add row was wider
///     than a phone's dialog;
///   * the backdrop preview in Appearance is 116px tall;
///   * the guest-page theme preview in Settings is 268px tall.
///
/// Held on a 360x800 phone at 1.3x, in both design systems and on Windows and
/// Android (the same Dart runs on both).

class _FakeApi extends ApiClient {
  _FakeApi({this.refuseBadges = false});

  /// Every badge save fails, so the dialog has an error to show.
  final bool refuseBadges;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') {
      if (refuseBadges && path == '/menu/badges') throw ApiException('Server said no', 500);
      return <String, dynamic>{'ok': true};
    }
    if (path.startsWith('/restaurant/settings')) {
      return <String, dynamic>{
        'brand_config': <String, dynamic>{},
        'brand_fields': <String, dynamic>{
          'live': <String>['scheme', 'color_primary', 'font', 'font_scale'],
          'legacy': <String>[],
        },
        'brand_field_options': <String, dynamic>{},
        'brand_schemes': <dynamic>[],
        'brand_fonts': <String>['Inter'],
      };
    }
    return <String, dynamic>{};
  }
}

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

/// A 360dp phone (or [size]) wearing [system] the way the running app does:
/// the scope for the primitives, the ThemeData for everything else, and the
/// controller for the widgets that read it directly (Appearance does).
Future<RestClient> _device(WidgetTester tester, DesignSystem system, _FakeApi api,
    {Size size = const Size(360, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await AppearanceController.instance.setDesignSystem(system);
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _app(DesignSystem system, Widget home, {double scale = 1.3}) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );

/// Runs [body] while collecting every error the framework reports. Hands back
/// the overflows raised by a RenderFlex under [root], and every report that is
/// not a RenderFlex overflow at all. Overflows elsewhere are dropped: the
/// Settings page has other cards that overflow on a phone at large text, they
/// are not this test's business, and a whole-page `takeException` could not
/// tell them apart.
Future<({List<String> here, List<String> other})> _overflowsUnder(
    WidgetTester tester, Finder root, Future<void> Function() body) async {
  final reports = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = reports.add;
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
  final top = tester.renderObject(root);
  bool under(RenderObject r) {
    for (RenderObject? p = r; p != null; p = p.parent) {
      if (identical(p, top)) return true;
    }
    return false;
  }

  final here = <String>[];
  final other = <String>[];
  for (final d in reports) {
    final flexes = [
      for (final node in d.informationCollector?.call() ?? const <DiagnosticsNode>[])
        if (node.value is RenderFlex) node.value! as RenderFlex,
    ];
    if (flexes.isEmpty || !d.exceptionAsString().startsWith('A RenderFlex overflowed')) {
      other.add(d.exceptionAsString());
    } else if (flexes.any(under)) {
      here.add(d.exceptionAsString());
    }
  }
  return (here: here, other: other);
}

/// Opens the badge catalogue on a first run: nothing saved yet, two presets.
Future<void> _openBadges(WidgetTester tester, DesignSystem system, RestClient rest, {double scale = 1.3}) async {
  await tester.pumpWidget(_app(
    system,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => MenuBadgesDialog(
                rest: rest,
                initial: const [],
                presets: const [
                  MenuBadge(id: 'spicy', label: 'Spicy', kind: MenuBadgeKind.alert),
                  MenuBadge(id: 'veg', label: 'Veg', kind: MenuBadgeKind.diet),
                ],
                labelMax: 18,
                usage: (_) => 0,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    scale: scale,
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The enabled starter-set button, by label rather than text: Gaia sets button
/// labels in capitals.
final _starter = find.byWidgetPredicate(
    (w) => w is ForkButton && w.label.startsWith('Use the starter set') && w.onPressed != null,
    description: 'the enabled starter-set button');

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  for (final system in DesignSystem.values) {
    // ------------------------------------------------------- menu badges ---

    for (final (device, size, scale) in const [
      ('a 360dp phone at 1.3x', Size(360, 800), 1.3),
      ('a desktop at 1x', Size(1400, 1000), 1.0),
    ]) {
      testWidgets('menu badges: the first-run starter set is on screen and takes a tap on $device (${system.label})',
          (tester) async {
        final rest = await _device(tester, system, _FakeApi(), size: size);
        await _openBadges(tester, system, rest, scale: scale);
        expect(tester.takeException(), isNull);

        // The empty state sat in whatever height the dialog had left. On a
        // desktop that cut its button off; on a phone at large text it was
        // nothing at all, and a zero-height column is never painted, so it
        // raised no error either. Scrolled to, the button must be there AND
        // take a tap.
        final empty = find.byType(EmptyState, skipOffstage: false);
        expect(empty, findsOneWidget);
        final starter = _starter;
        await tester.ensureVisible(starter);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(empty).height, greaterThan(0));
        expect(starter.hitTestable(), findsOneWidget, reason: 'the starter set is on screen but cannot be tapped');

        // Every control in the add row is inside the dialog's panel.
        final dialog = tester.getRect(find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first);
        for (final control in [find.byType(TextField), find.byType(DropdownButton<MenuBadgeKind>), find.byTooltip('Add badge')]) {
          final r = tester.getRect(control);
          expect(r.left, greaterThanOrEqualTo(dialog.left));
          expect(r.right, lessThanOrEqualTo(dialog.right), reason: '$control runs past the dialog');
        }
        // And they stay pinned under whatever scrolls, with Done.
        expect(find.byTooltip('Add badge').hitTestable(), findsOneWidget);
        expect(find.byWidgetPredicate((w) => w is ForkButton && w.label == 'Done').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: _platforms);
    }

    testWidgets('menu badges: turning a phone keeps the name being typed, and its focus (${system.label})',
        (tester) async {
      final rest = await _device(tester, system, _FakeApi());
      await _openBadges(tester, system, rest);
      // Portrait puts the name on a line of its own; landscape puts it back
      // beside the kind menu. The field must be the same field either way.
      final field = find.byType(EditableText);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Gluten free');
      await tester.pump();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);

      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue, reason: 'focus lost turning to landscape');
      expect(tester.widget<EditableText>(field).controller.text, 'Gluten free');

      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue, reason: 'focus lost turning back');
      expect(tester.takeException(), isNull);
    }, variant: _platforms);

    testWidgets('menu badges: a refused save stays in sight on a landscape phone (${system.label})',
        (tester) async {
      final rest = await _device(tester, system, _FakeApi(refuseBadges: true), size: const Size(800, 360));
      await _openBadges(tester, system, rest);
      await tester.ensureVisible(_starter);
      await tester.pumpAndSettle();
      await tester.tap(_starter.hitTestable());
      await tester.pumpAndSettle();

      // The header scrolls, so the error is pinned with the add row instead:
      // however far the owner scrolled to reach the button, the reason it did
      // nothing is on screen.
      expect(find.text('Server said no').hitTestable(), findsOneWidget);
      expect(find.byType(EmptyState), findsOneWidget, reason: 'the refused starter set is rolled back');
      expect(tester.takeException(), isNull);
    }, variant: _platforms);

    // --------------------------------------------------------- appearance ---

    testWidgets('appearance: the backdrop preview holds its text (${system.label})', (tester) async {
      await _device(tester, system, _FakeApi());
      await tester.pumpWidget(_app(
        system,
        Scaffold(body: ListView(padding: AppSpacing.pageNarrow, children: const [AppearanceCard()])),
      ));
      await tester.pump();

      final preview = find.byKey(const ValueKey('backdrop-preview'), skipOffstage: false);
      if (system == DesignSystem.gaia) {
        // Gaia draws no backdrop, so there is no preview to overflow — only
        // the line that says so.
        expect(preview, findsNothing);
        expect(find.textContaining('Gaia has no backdrop', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);
        return;
      }

      expect(preview, findsOneWidget);
      await tester.ensureVisible(preview);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final box = tester.getRect(preview);
      for (final t in ['Rustic Fork', 'Covers 42', 'Live preview']) {
        final r = tester.getRect(find.descendant(of: preview, matching: find.textContaining(t)));
        expect(r.top, greaterThanOrEqualTo(box.top), reason: '"$t" starts above the preview');
        expect(r.bottom, lessThanOrEqualTo(box.bottom), reason: '"$t" runs past the bottom of the preview');
        expect(r.right, lessThanOrEqualTo(box.right), reason: '"$t" runs past the side of the preview');
      }
    }, variant: _platforms);

    // -------------------------------------------------- guest-page theme ---

    testWidgets('settings: the guest-page theme preview holds its text (${system.label})', (tester) async {
      final rest = await _device(tester, system, _FakeApi());
      final preview = find.byKey(const ValueKey('guest-theme-preview'), skipOffstage: false);

      final overflows = await _overflowsUnder(tester, preview, () async {
        await tester.pumpWidget(_app(
          system,
          ModuleNavigator(
            openModule: (_, {Map<String, dynamic>? target}) {},
            visibleLabels: const ['Settings'],
            clearFocus: () {},
            child: Scaffold(backgroundColor: Colors.transparent, body: m.settingsModule(rest, rest.auth.profile!)),
          ),
        ));
        await tester.pumpAndSettle();
        // Settings is a long lazy list: drag until the preview is built, then
        // bring it fully on screen so every part of it paints.
        await tester.scrollUntilVisible(find.text('Add to cart'), 300, scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(preview);
        await tester.pumpAndSettle();
      });

      expect(preview, findsOneWidget);
      expect(overflows.here, isEmpty);
      expect(overflows.other, isEmpty, reason: 'only overflows elsewhere on the page may be set aside');

      // The miniature fits the phone, and the parts a guest reads are inside
      // it, not clipped off it.
      final box = tester.getRect(preview);
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(360));
      for (final t in ['Your restaurant', 'Sample dish', 'Ready', 'Failed', 'Add to cart', 'Rate us']) {
        final r = tester.getRect(find.descendant(of: preview, matching: find.text(t)));
        expect(box.contains(r.topLeft) && box.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
            reason: '"$t" at $r is outside the preview at $box');
      }
    }, variant: _platforms);
  }
}
