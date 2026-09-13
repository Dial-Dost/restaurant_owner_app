import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/theme/contrast.dart';
import 'package:restaurant_owner_app/widgets/appearance_card.dart';
import 'package:restaurant_owner_app/widgets/theme_toggle.dart';

/// 6.6 — the interface theme toggle: Dark (default, untouched), or Light in
/// White, Beige or Soft grey. Persistence, ThemeData selection, the dark default staying
/// byte-identical, readability of the light palettes, and the toggle actually
/// repainting the page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppearanceController.instance.debugReset();
  });

  tearDown(() {
    // Never leak a light palette into other test files.
    AppearanceController.instance.debugReset();
  });

  group('LightTone', () {
    test('dark is the default, white the default tone, junk falls back', () {
      final ctl = AppearanceController.instance;
      expect(ctl.lightMode, isFalse);
      expect(ctl.themePick, 'dark');
      expect(ctl.lightTone, LightTone.white);
      expect(LightTone.byId('beige'), LightTone.beige);
      expect(LightTone.byId('grey'), LightTone.grey);
      expect(LightTone.byId('sepia'), LightTone.white);
      expect(LightTone.byId(null), LightTone.white);
      // Same ids and labels as the web's LIGHT_TONES.
      expect([for (final t in LightTone.values) t.id], ['white', 'beige', 'grey']);
      expect([for (final t in LightTone.values) t.label], ['White', 'Beige', 'Soft grey']);
    });

    test('palettes carry the web tokens verbatim', () {
      const b = AppLightPalettes.beige;
      expect(b.bg, const Color(0xFFF5EFE3));
      expect(b.card, const Color(0xFFFBF7EF));
      expect(b.textPrimary, const Color(0xFF2B2219));
      expect(b.inset, const Color(0xFFECE3D2));
      expect(b.textSecondary, const Color(0xFF6A5B4B));
      expect(b.divider, const Color(0xFFE6DCC9));
      expect(b.border, const Color(0xFFE0D3BE));
      expect(b.borderStrong, const Color(0xFFD4C4AA));
      expect(b.danger, const Color(0xFFC32222));

      const g = AppLightPalettes.grey;
      expect(g.bg, const Color(0xFFEEEFF1));
      expect(g.card, const Color(0xFFF8F9FA));
      expect(g.textPrimary, const Color(0xFF1D2025));
      expect(g.inset, const Color(0xFFE3E5E8));
      expect(g.textSecondary, const Color(0xFF575D66));
      expect(g.divider, const Color(0xFFE8E9EC));
      expect(g.border, const Color(0xFFD9DCE1));
      expect(g.borderStrong, const Color(0xFFC9CDD4));
      expect(g.danger, const Color(0xFFC32222));

      const w = AppLightPalettes.white;
      expect(w.bg, const Color(0xFFFFFFFF));
      expect(w.card, const Color(0xFFFFFFFF));
      expect(w.textPrimary, const Color(0xFF030712));
      expect(w.inset, const Color(0xFFF3F4F6));
      expect(w.textTertiary, const Color(0xFF6B7280));
      expect(w.border, const Color(0xFFE5E7EB));

      for (final t in LightTone.values) {
        expect(AppLightPalettes.of(t).brightness, Brightness.light);
      }
    });
  });

  group('persistence and pick rules', () {
    test('picking a tone switches to light and persists; load restores it', () async {
      final ctl = AppearanceController.instance;
      await ctl.applyThemePick('beige');
      expect(ctl.lightMode, isTrue);
      expect(ctl.themePick, 'beige');
      expect(AppColors.bg, AppLightPalettes.beige.bg);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance.uiMode'), 'light');
      expect(prefs.getString('appearance.lightTone'), 'beige');

      // Cold start.
      ctl.debugReset();
      expect(AppColors.bg, AppColors.rusticShell.bg);
      await ctl.load();
      expect(ctl.themePick, 'beige');
      expect(AppColors.bg, AppLightPalettes.beige.bg);
      expect(AppColors.isLight, isTrue);
    });

    test('picking Dark keeps the tone for the next switch to light', () async {
      final ctl = AppearanceController.instance;
      await ctl.applyThemePick('grey');
      await ctl.applyThemePick('dark');
      expect(ctl.lightMode, isFalse);
      expect(ctl.lightTone, LightTone.grey);
      expect(AppColors.isLight, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance.uiMode'), 'dark');
      expect(prefs.getString('appearance.lightTone'), 'grey');

      ctl.debugReset();
      await ctl.load();
      expect(ctl.themePick, 'dark');
      expect(ctl.lightTone, LightTone.grey);
    });

    test('a stored light mode is applied by load() — before any frame', () async {
      SharedPreferences.setMockInitialValues({
        'appearance.uiMode': 'light',
        'appearance.lightTone': 'grey',
      });
      await AppearanceController.instance.load();
      expect(AppColors.bg, AppLightPalettes.grey.bg);
      expect(AppTheme.active().scaffoldBackgroundColor, const Color(0xFFEEEFF1));
    });

    test('corrupt stored values load as dark / white', () async {
      SharedPreferences.setMockInitialValues({
        'appearance.uiMode': 'sepia',
        'appearance.lightTone': 'mauve',
      });
      await AppearanceController.instance.load();
      expect(AppearanceController.instance.themePick, 'dark');
      expect(AppearanceController.instance.lightTone, LightTone.white);
      expect(AppColors.isLight, isFalse);
    });

    test('switching back to Dark restores the remembered scheme and accent', () async {
      final ctl = AppearanceController.instance;
      await ctl.setScheme('slate');
      await ctl.setAccent('teal');
      await ctl.applyThemePick('white');
      // The dark scheme is remembered, not painted.
      expect(AppColors.bg, AppLightPalettes.white.bg);
      expect(ctl.schemeId, 'slate');
      // The accent is carried, re-derived for the light ground.
      expect(AppColors.accent.id, 'teal');
      expect(AppColors.copper, isNot(AppAccents.teal.base));

      await ctl.applyThemePick('dark');
      expect(AppColors.bg, AppSchemes.slate.bg);
      expect(AppColors.copper, AppAccents.teal.base);
    });

    test('under Gaia a light choice is remembered but not applied', () async {
      final ctl = AppearanceController.instance;
      await ctl.setDesignSystem(DesignSystem.gaia);
      await ctl.applyThemePick('beige');
      expect(ctl.themePick, 'beige');
      expect(ctl.lightActive, isFalse);
      expect(AppColors.isLight, isFalse);

      await ctl.setDesignSystem(DesignSystem.rustic);
      expect(ctl.lightActive, isTrue);
      expect(AppColors.bg, AppLightPalettes.beige.bg);
    });
  });

  group('ThemeData selection', () {
    test('dark stays the shipped theme, byte for byte', () {
      final t = AppTheme.active();
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, const Color(0xFF0C0A09));
      expect(t.colorScheme.onSurface, const Color(0xFFECEAE6));
      // The strokes and status inks that used to be consts are unchanged.
      expect(AppColors.border, const Color(0x12FFFFFF));
      expect(AppColors.borderStrong, const Color(0x1FFFFFFF));
      expect(AppColors.divider, const Color(0x0DFFFFFF));
      expect(AppColors.success, const Color(0xFF8FB27C));
      expect(AppColors.warning, const Color(0xFFD9A962));
      expect(AppColors.danger, const Color(0xFFC97B6E));
      expect(AppColors.info, const Color(0xFF8FA3B8));
      expect(AppColors.neutral, const Color(0xFF9A978F));
      expect(AppColors.copper, AppAccents.copper.base);
      expect(AppColors.overlay, Colors.white);
      expect(AppColors.lift(AppColors.success, 0.25),
          Color.lerp(AppColors.success, Colors.white, 0.25));
    });

    for (final tone in LightTone.values) {
      test('${tone.id} selects a light ThemeData on its palette', () async {
        await AppearanceController.instance.applyThemePick(tone.id);
        final palette = AppLightPalettes.of(tone);
        final t = AppTheme.active();
        expect(t.brightness, Brightness.light);
        expect(t.colorScheme.brightness, Brightness.light);
        expect(t.scaffoldBackgroundColor, palette.bg);
        expect(t.colorScheme.surface, palette.surface);
        expect(t.colorScheme.onSurface, palette.textPrimary);
        expect(t.textTheme.bodyMedium!.color, palette.textSecondary);
        expect(t.dividerTheme.color, palette.divider);
        expect(AppColors.overlay, Colors.black);
      });
    }
  });

  group('light palettes stay readable (WCAG AA 4.5:1)', () {
    // Mirrors modules.dart's table-state washes (2.2): _kOccupiedWash 0.20,
    // _kSeatedWash 0.16, _kReservedWash 0.13, composited over AppColors.card.
    const occupiedWash = 0.20, seatedWash = 0.16, reservedWash = 0.13;

    for (final palette in [for (final t in LightTone.values) AppLightPalettes.of(t)]) {
      final grounds = {
        'bg': palette.bg, 'bgDeep': palette.bgDeep, 'surface': palette.surface,
        'card': palette.card, 'cardTop': palette.cardTop,
        'cardBottom': palette.cardBottom, 'cardRaised': palette.cardRaised,
        'inset': palette.inset,
      };

      test('${palette.id}: body and status inks on every ground', () {
        final failures = <String>[];
        void check(String what, Color ink, Color ground) {
          final r = contrastRatio(ink, ground);
          if (r < 4.5) failures.add('$what ${r.toStringAsFixed(2)}');
        }

        grounds.forEach((g, c) {
          check('textPrimary/$g', palette.textPrimary, c);
          check('textSecondary/$g', palette.textSecondary, c);
          check('success/$g', palette.success, c);
          check('warning/$g', palette.warning, c);
          check('danger/$g', palette.danger, c);
          check('info/$g', palette.info, c);
          check('neutral/$g', palette.neutral, c);
        });
        expect(failures, isEmpty);
      });

      test('${palette.id}: every derived accent, and table washes + money ink', () {
        final failures = <String>[];
        void check(String what, Color ink, Color ground) {
          final r = contrastRatio(ink, ground);
          if (r < 4.5) failures.add('$what ${r.toStringAsFixed(2)}');
        }

        for (final a in AppAccents.all) {
          final l = AppLightPalettes.accentFor(a, palette);
          grounds.forEach((g, c) {
            check('${a.id}.hi/$g', l.hi, c);
            check('${a.id}.base/$g', l.base, c);
            check('${a.id}.mid/$g', l.mid, c);
          });
          // A filled primary control: its ink over both gradient stops.
          check('${a.id}.on/base', l.on, l.base);
          check('${a.id}.on/mid', l.on, l.mid);

          // The floor: each table state's wash, with the ink that sits on it —
          // the name and figures (primary), the waiter/covers line
          // (secondary), accent money/OTP (hi) and the status chip label.
          final washes = {
            'occupied': Color.alphaBlend(l.base.withValues(alpha: occupiedWash), palette.card),
            'seated': Color.alphaBlend(palette.warning.withValues(alpha: seatedWash), palette.card),
            'reserved': Color.alphaBlend(palette.info.withValues(alpha: reservedWash), palette.card),
          };
          final stateColour = {'occupied': l.base, 'seated': palette.warning, 'reserved': palette.info};
          washes.forEach((state, wash) {
            check('${a.id}/$state textPrimary', palette.textPrimary, wash);
            check('${a.id}/$state textSecondary', palette.textSecondary, wash);
            check('${a.id}/$state copperHi', l.hi, wash);
            check('${a.id}/$state success', palette.success, wash);
            final c = stateColour[state]!;
            // StatusChip: 12% tint of its colour over the wash, label lifted
            // 25% toward the primary ink (AppColors.lift on a light palette).
            final chip = Color.alphaBlend(c.withValues(alpha: 0.12), wash);
            check('${a.id}/$state chip label',
                Color.lerp(c, palette.textPrimary, 0.25)!, chip);
          });
        }
        expect(failures, isEmpty);
      });
    }
  });

  group('toggle UI', () {
    Widget harness() => AnimatedBuilder(
          animation: AppearanceController.instance,
          // The same root wiring as app.dart: the theme is re-read on every
          // appearance change.
          builder: (context, _) => MaterialApp(
            theme: AppTheme.active(),
            home: Scaffold(
              appBar: AppBar(actions: const [ThemeToggleButton()]),
              body: const Text('page'),
            ),
          ),
        );

    Color scaffoldPaint(WidgetTester tester) => tester
        .widget<Material>(find
            .descendant(of: find.byType(Scaffold), matching: find.byType(Material))
            .first)
        .color!;

    Future<void> pick(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('theme-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('theme-option-$id')));
      await tester.pumpAndSettle();
    }

    testWidgets('picking a palette in the top-bar toggle repaints the scaffold', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(scaffoldPaint(tester), AppColors.rusticShell.bg);
      expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);

      // The menu mirrors the web: Dark, a Light section, three tones, one tick.
      await tester.tap(find.byKey(const ValueKey('theme-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('LIGHT'), findsOneWidget);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Beige'), findsOneWidget);
      expect(find.text('Soft grey'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-option-beige')));
      await tester.pumpAndSettle();

      expect(AppearanceController.instance.themePick, 'beige');
      expect(scaffoldPaint(tester), AppLightPalettes.beige.bg);
      expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);

      await pick(tester, 'grey');
      expect(scaffoldPaint(tester), AppLightPalettes.grey.bg);

      await pick(tester, 'white');
      expect(scaffoldPaint(tester), AppLightPalettes.white.bg);

      await pick(tester, 'dark');
      expect(scaffoldPaint(tester), AppColors.rusticShell.bg);
      expect(AppearanceController.instance.lightTone, LightTone.white);
    });

    testWidgets('the Appearance card offers the same choices', (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: SingleChildScrollView(child: AppearanceCard())),
      ));
      await tester.pump();

      for (final id in ['dark', 'white', 'beige', 'grey']) {
        expect(find.byKey(ValueKey('theme-swatch-$id')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('theme-swatch-grey')));
      await tester.pump();
      expect(AppearanceController.instance.themePick, 'grey');
      expect(AppColors.bg, AppLightPalettes.grey.bg);

      await tester.tap(find.byKey(const ValueKey('theme-swatch-dark')));
      await tester.pump();
      expect(AppearanceController.instance.themePick, 'dark');
      expect(AppColors.bg, AppColors.rusticShell.bg);
    });
  });
}
