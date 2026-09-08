import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/section_header.dart';
import 'package:restaurant_owner_app/ui/widgets/stat_card.dart';

/// The GAIA design system: the switch, the palette bridge, the variable-font
/// wiring, and the guarantee that Rustic Fork is untouched underneath it.
///
/// The whole point of building Gaia as a SWITCH rather than a replacement is
/// that abandoning it costs a setting, not a revert — so most of what is
/// tested here is that turning it off puts everything back exactly as it was.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppearanceController.instance.debugReset();
  });

  tearDown(() {
    // Gaia pins a global palette. Never leak it into another test file.
    AppearanceController.instance.debugReset();
  });

  double lum(Color c) {
    double chan(double v) =>
        v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b);
  }

  double contrast(Color a, Color b) {
    final la = lum(a), lb = lum(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  group('the switch', () {
    test('defaults to Rustic Fork — nothing changes until someone opts in', () {
      expect(AppearanceController.instance.designSystem, DesignSystem.rustic);
      expect(Gaia.isActive, isFalse);
      expect(DesignSystem.byId(null), DesignSystem.rustic);
      expect(DesignSystem.byId('junk'), DesignSystem.rustic);
      expect(DesignSystem.byId('gaia'), DesignSystem.gaia);
    });

    test('the shipped copper-on-rustic palette is live by default', () {
      expect(AppColors.bg, const Color(0xFF0C0A09));
      expect(AppColors.copper, AppColors.rusticCopper.base);
    });

    test('flipping to Gaia repaints the shared AppColors ladder', () async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);

      expect(Gaia.isActive, isTrue);
      // This is what makes ~30 un-edited modules restyle: they all read these.
      expect(AppColors.bg, GaiaColors.forest.bg);
      expect(AppColors.surface, GaiaColors.forest.surface);
      expect(AppColors.cardRaised, GaiaColors.forest.raised);
      expect(AppColors.copper, GaiaColors.champagne);
      expect(AppColors.copperHi, GaiaColors.champagne2);
      expect(AppColors.onCopper, GaiaColors.ink);
      expect(AppColors.textPrimary, GaiaColors.text);
    });

    test('flipping back restores the exact shipped palette', () async {
      final ctl = AppearanceController.instance;
      await ctl.setDesignSystem(DesignSystem.gaia);
      await ctl.setDesignSystem(DesignSystem.rustic);

      expect(Gaia.isActive, isFalse);
      expect(AppColors.bg, const Color(0xFF0C0A09));
      expect(AppColors.copper, AppColors.rusticCopper.base);
      expect(identical(AppColors.shell, AppColors.rusticShell), isTrue);
    });

    test('a card gradient degenerates to flat under Gaia', () async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      // cardTop == cardBottom, so any un-ported widget still reading
      // AppColors.cardGradient paints a flat surface rather than a sheen the
      // design does not have.
      expect(AppColors.cardTop, AppColors.cardBottom);
    });

    test('an accent picked while Gaia is on is stored, not applied, and lands '
        'the moment Gaia is turned off', () async {
      final ctl = AppearanceController.instance;
      await ctl.setDesignSystem(DesignSystem.gaia);

      await ctl.setAccent('teal');
      // Remembered...
      expect(ctl.accentId, 'teal');
      // ...but champagne still paints, because Gaia pins its own palette.
      expect(AppColors.copper, GaiaColors.champagne);

      await ctl.setDesignSystem(DesignSystem.rustic);
      expect(AppColors.copper, AppAccents.teal.base);
    });

    test('a scheme picked while Gaia is on behaves the same way', () async {
      final ctl = AppearanceController.instance;
      await ctl.setDesignSystem(DesignSystem.gaia);

      await ctl.setScheme('midnight');
      expect(ctl.schemeId, 'midnight');
      expect(AppColors.bg, GaiaColors.forest.bg);

      await ctl.setDesignSystem(DesignSystem.rustic);
      expect(AppColors.bg, AppSchemes.midnight.bg);
    });

    test('the choice persists and reloads', () async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance.designSystem'), 'gaia');

      AppearanceController.instance.debugReset();
      expect(Gaia.isActive, isFalse);

      await AppearanceController.instance.load();
      expect(Gaia.isActive, isTrue);
      expect(AppColors.bg, GaiaColors.forest.bg);
    });

    test('Gaia is NOT offered as a scheme or accent preset — the existing '
        'appearance matrix is untouched', () {
      expect(AppSchemes.all.length, 5);
      expect(AppAccents.all.length, 8);
      expect(AppSchemes.all.any((s) => s.id.startsWith('gaia')), isFalse);
      expect(AppAccents.all.any((a) => a.id.startsWith('gaia')), isFalse);
    });
  });

  group('palette fidelity to the mockup', () {
    test('the tokens are the spec hexes, verbatim', () {
      // Straight off gaia-ui-revamp.html's :root and .forest.
      expect(GaiaColors.champagne, const Color(0xFFD3B88B));
      expect(GaiaColors.champagne2, const Color(0xFFE2CFA6));
      expect(GaiaColors.champagneDim, const Color(0xFFA08C67));
      expect(GaiaColors.ink, const Color(0xFF1A1410));
      expect(GaiaColors.coral, const Color(0xFFD9705F));
      expect(GaiaColors.sage, const Color(0xFF9BC4A0));
      expect(GaiaColors.amber, const Color(0xFFD9B06A));
      expect(GaiaColors.text, const Color(0xFFEDE6D6));
      expect(GaiaColors.text2, const Color(0xFFB3AC99));
      expect(GaiaColors.text3, const Color(0xFF7D7866));

      expect(GaiaColors.forest.bg, const Color(0xFF0C1513));
      expect(GaiaColors.forest.surface, const Color(0xFF132320));
      expect(GaiaColors.forest.raised, const Color(0xFF182B27));
      expect(GaiaColors.forest.line, const Color(0xFF243430));
      expect(GaiaColors.forest.line2, const Color(0xFF31443D));

      expect(GaiaColors.oxblood.bg, const Color(0xFF20110F));
      expect(GaiaColors.petrol.bg, const Color(0xFF0B161B));
    });

    test('the bridges carry the ground and the accent unchanged', () {
      expect(GaiaColors.shellBridge.bg, GaiaColors.forest.bg);
      expect(GaiaColors.shellBridge.cardRaised, GaiaColors.forest.raised);
      expect(GaiaColors.accentBridge.base, GaiaColors.champagne);
      expect(GaiaColors.accentBridge.on, GaiaColors.ink);
    });

    /// The measured ladder, recorded rather than assumed. Held to the SAME
    /// standard the shipped system already holds itself to (see
    /// appearance_matrix_test.dart): body ink and readable accent stops clear
    /// AA 4.5:1; the tertiary "furniture" ink does not have to, and in fact
    /// Gaia's is BETTER than the shipped one (4.20 vs rustic's 3.05 on ground).
    test('body ink and accent stops clear WCAG AA on every Gaia ground', () {
      for (final g in GaiaColors.all) {
        for (final ground in [g.bg, g.surface, g.raised]) {
          expect(contrast(GaiaColors.text, ground), greaterThanOrEqualTo(4.5),
              reason: '${g.id}: primary ink');
          expect(contrast(GaiaColors.text2, ground), greaterThanOrEqualTo(4.5),
              reason: '${g.id}: secondary ink');
          expect(contrast(GaiaColors.champagne, ground), greaterThanOrEqualTo(4.5),
              reason: '${g.id}: accent base');
          expect(contrast(GaiaColors.champagne2, ground), greaterThanOrEqualTo(4.5),
              reason: '${g.id}: accent hi');
          for (final status in [GaiaColors.coral, GaiaColors.sage, GaiaColors.amber]) {
            expect(contrast(status, ground), greaterThanOrEqualTo(4.5),
                reason: '${g.id}: status ink');
          }
          expect(contrast(GaiaColors.text3AA, ground), greaterThanOrEqualTo(4.5),
              reason: '${g.id}: the lifted faint ink must actually be readable');
        }
      }
    });

    test('ink on a champagne-filled control is readable', () {
      expect(contrast(GaiaColors.ink, GaiaColors.champagne),
          greaterThanOrEqualTo(4.5));
      expect(contrast(GaiaColors.ink, GaiaColors.champagne2),
          greaterThanOrEqualTo(4.5));
    });

    test('text3 is the spec value and is recorded as sub-AA furniture', () {
      // Deliberately NOT lifted: the mockup is the spec. This test exists so
      // the number is a decision on the record rather than an accident, and so
      // it cannot drift without someone noticing.
      final c = contrast(GaiaColors.text3, GaiaColors.forest.bg);
      expect(c, greaterThan(4.0));
      expect(c, lessThan(4.5));
      // Still better than the ink the shipped system uses for the same job.
      expect(c, greaterThan(contrast(AppColors.rusticShell.textTertiary,
          AppColors.rusticShell.bg)));
    });
  });

  group('type — the variable-font trap', () {
    test('every serif style carries a wght FontVariation, not just a '
        'FontWeight', () {
      // Without this the axis sits at its default of 300 and the entire serif
      // half of the design renders Light. A fontWeight alone does NOT move a
      // variable axis in Flutter.
      final styles = <String, TextStyle>{
        'big': GaiaType.big(),
        'title': GaiaType.title(),
        'titleEm': GaiaType.titleEm(),
        'mid': GaiaType.mid(),
        'statNumber': GaiaType.statNumber(),
        'cardName': GaiaType.cardName(),
        'rowValue': GaiaType.rowValue(),
        'kvValue': GaiaType.kvValue(),
        'italNote': GaiaType.italNote(),
        'wordmark': GaiaType.wordmark(),
      };
      styles.forEach((name, s) {
        expect(s.fontFamily, GaiaType.serifFamily, reason: name);
        expect(s.fontVariations, isNotNull, reason: '$name has no fontVariations');
        final wght = s.fontVariations!.firstWhere((v) => v.axis == 'wght');
        expect(wght.value, greaterThanOrEqualTo(300), reason: name);
        expect(wght.value, lessThanOrEqualTo(700), reason: name);
      });
    });

    test('sans styles carry theirs too, clamped to the 400..700 axis', () {
      final styles = <String, TextStyle>{
        'body': GaiaType.body(),
        'eyebrow': GaiaType.eyebrow(),
        'button': GaiaType.button(),
        'pill': GaiaType.pill(),
        'navLabel': GaiaType.navLabel(),
        'rowTitle': GaiaType.rowTitle(),
      };
      styles.forEach((name, s) {
        expect(s.fontFamily, GaiaType.sansFamily, reason: name);
        final wght = s.fontVariations!.firstWhere((v) => v.axis == 'wght');
        expect(wght.value, greaterThanOrEqualTo(400), reason: name);
        expect(wght.value, lessThanOrEqualTo(700), reason: name);
      });
    });

    test('a weight outside a family axis is clamped onto it', () {
      // Cormorant has no 100; asking for one must land on 300, not fall off
      // the axis.
      expect(
        GaiaType.serif(size: 20, weight: 100)
            .fontVariations!
            .firstWhere((v) => v.axis == 'wght')
            .value,
        300,
      );
      expect(
        GaiaType.sans(size: 20, weight: 900)
            .fontVariations!
            .firstWhere((v) => v.axis == 'wght')
            .value,
        700,
      );
      // And Instrument Sans has no 300 either.
      expect(
        GaiaType.sans(size: 20, weight: 300)
            .fontVariations!
            .firstWhere((v) => v.axis == 'wght')
            .value,
        400,
      );
    });

    test('every style asks for LINING figures — Cormorant defaults to '
        'old-style, which the mockup overrides on body', () {
      for (final st in [GaiaType.big(), GaiaType.statNumber(), GaiaType.body(),
                        GaiaType.rowValue(), GaiaType.eyebrow()]) {
        expect(st.fontFeatures, isNotNull);
        expect(st.fontFeatures!.map((f) => f.feature), contains('lnum'));
      }
    });

    test('the sans falls back to a BUNDLED family first, because Instrument '
        'Sans has no rupee sign', () {
      // Verified against the font cmap: U+20B9 is absent from Instrument Sans
      // and present in Cormorant. A host-dependent fallback renders tofu for
      // every price in body text on a machine without a covering system font.
      expect(GaiaType.sansFallback.first, GaiaType.serifFamily);
      expect(GaiaType.sans(size: 14).fontFamilyFallback!.first,
          GaiaType.serifFamily);
    });

    test('em tracking is converted to pixels against its own size', () {
      // .wordmark is .42em at 15px.
      expect(GaiaType.wordmark().letterSpacing, closeTo(0.42 * 15, 0.001));
      // .eyebrow is .18em at 11px.
      expect(GaiaType.eyebrow().letterSpacing, closeTo(0.18 * 11, 0.001));
      // .btn is .2em at 12px.
      expect(GaiaType.button().letterSpacing, closeTo(0.2 * 12, 0.001));
    });
  });

  group('theme', () {
    test('the Gaia text theme is serif for figures and sans for language', () {
      final t = GaiaTheme.dark().textTheme;
      for (final s in [t.displayLarge, t.displayMedium, t.displaySmall,
                       t.headlineMedium, t.titleLarge]) {
        expect(s!.fontFamily, GaiaType.serifFamily);
        expect(s.fontVariations, isNotNull);
      }
      for (final s in [t.bodyLarge, t.bodyMedium, t.labelSmall, t.titleMedium]) {
        expect(s!.fontFamily, GaiaType.sansFamily);
      }
    });

    test('labelSmall — which captions figures — uses AA ink, not the spec '
        'faint ink', () {
      expect(GaiaTheme.dark().textTheme.labelSmall!.color, GaiaColors.text2);
    });

    test('the Rustic theme is unchanged by any of this', () {
      final t = AppTheme.dark().textTheme;
      // No family set: the shipped theme has always used the platform default.
      expect(t.displayMedium!.fontFamily, isNull);
      expect(t.displayMedium!.fontWeight, FontWeight.w300);
      expect(t.displayMedium!.fontSize, 32);
    });

    test('Gaia is square and flat; Rustic is round and lit', () {
      expect(GaiaRadius.edge, 2);
      final gaiaDialog = GaiaTheme.dark().dialogTheme.shape as RoundedRectangleBorder;
      expect((gaiaDialog.borderRadius as BorderRadius).topLeft.x, 2);
      expect(GaiaTheme.dark().appBarTheme.elevation, 0);
    });
  });

  group('primitives render in either language without a call-site edit', () {
    Widget host(Widget child) => MaterialApp(
          theme: Gaia.isActive ? GaiaTheme.dark() : AppTheme.dark(),
          home: Scaffold(body: Center(child: SizedBox(width: 320, child: child))),
        );

    testWidgets('ForkCard is a 14px gradient card with a shadow under Rustic',
        (tester) async {
      await tester.pumpWidget(host(const ForkCard(child: Text('x'))));
      final d = tester
          .widget<AnimatedContainer>(find.descendant(
              of: find.byType(ForkCard), matching: find.byType(AnimatedContainer)))
          .decoration as BoxDecoration;
      expect((d.borderRadius as BorderRadius).topLeft.x, 14);
      expect(d.gradient, isNotNull);
      expect(d.boxShadow, isNotNull);
    });

    testWidgets('the SAME ForkCard is a 2px flat hairline card under Gaia',
        (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(host(const ForkCard(child: Text('x'))));

      expect(find.byType(GaiaCard), findsOneWidget);
      final d = tester
          .widget<AnimatedContainer>(find.descendant(
              of: find.byType(GaiaCard), matching: find.byType(AnimatedContainer)))
          .decoration as BoxDecoration;
      expect((d.borderRadius as BorderRadius).topLeft.x, GaiaRadius.edge);
      expect(d.gradient, isNull, reason: 'Gaia cards are flat');
      expect(d.boxShadow, isNull, reason: 'Gaia has no shadows at all');
      expect(d.color, GaiaColors.forest.surface);
    });

    testWidgets('a StatCard keeps its value, unit and caption across the flip',
        (tester) async {
      const card = StatCard(
        value: '₹1,77,213.93',
        unit: 'net',
        caption: 'Revenue this month',
      );

      await tester.pumpWidget(host(card));
      expect(find.textContaining('1,77,213', findRichText: true), findsWidgets);

      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(host(card));
      await tester.pumpAndSettle();
      // Still the same figure, now set in the serif with the currency mark and
      // the decimal tail split off.
      expect(find.textContaining('1,77,213', findRichText: true), findsWidgets);
      expect(find.text('NET'), findsOneWidget);
      expect(find.text('REVENUE THIS MONTH'), findsOneWidget);
    });

    testWidgets('the Gaia toggle honours the mockup geometry', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      // Align, so the toggle is measured at its own size rather than being
      // stretched by the host SizedBox tight constraint.
      await tester.pumpWidget(host(
        Align(child: GaiaToggle(value: true, onChanged: (_) {})),
      ));

      final box = tester.getSize(find.byType(AnimatedContainer).first);
      expect(box.width, 40);
      expect(box.height, 22);
    });

    testWidgets('tabs switch from pills to an underlined row', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(host(
        GaiaTabs(tabs: const ['Sales', 'Covers'], selected: 0, onSelected: (_) {}),
      ));
      // Uppercased by the design, not by the caller.
      expect(find.text('SALES'), findsOneWidget);
      expect(find.text('COVERS'), findsOneWidget);
    });
  });

  group('flipping live', () {
    // The requirement is that the switch restyles the running app, not that it
    // restyles the next screen you happen to open. These are the two ways that
    // can quietly fail.

    Widget frame() => GaiaScope(
          system: AppearanceController.instance.designSystem,
          child: MaterialApp(
            theme: Gaia.isActive ? GaiaTheme.dark() : AppTheme.dark(),
            home: const Scaffold(
              body: Column(children: [
                // CONST on purpose — this is the case that used to go stale.
                SectionHeader(title: 'Operations', count: 3),
                ForkCard(child: Text('x')),
              ]),
            ),
          ),
        );

    testWidgets('a pumped tree restyles in place, and settles', (tester) async {
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(find.byType(GaiaCard), findsNothing);

      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(frame());
      // Settles: no animation is left running by the swap. (If this ever
      // hangs, the flip is not live — it is a restart wearing a disguise.)
      await tester.pumpAndSettle();

      expect(find.byType(GaiaCard), findsOneWidget);
    });

    testWidgets('a CONST primitive restyles too — Element.updateChild would '
        'otherwise skip it entirely', (tester) async {
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      // Rustic SectionHeader renders the title as given.
      expect(find.text('Operations'), findsOneWidget);

      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();

      // Gaia's section head is a tracked UPPERCASE eyebrow with the count
      // folded in. Seeing this at all proves the const widget was rebuilt.
      expect(find.byType(GaiaSectionHeader), findsOneWidget);
      expect(find.text('Operations'), findsNothing);
    });

    testWidgets('and flips back', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(find.byType(GaiaCard), findsOneWidget);

      await AppearanceController.instance.setDesignSystem(DesignSystem.rustic);
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(find.byType(GaiaCard), findsNothing);
      expect(find.text('Operations'), findsOneWidget);
    });

    testWidgets('with no GaiaScope above it, a primitive falls back to the '
        'controller rather than throwing', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(MaterialApp(
        theme: GaiaTheme.dark(),
        home: const Scaffold(body: ForkCard(child: Text('x'))),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(GaiaCard), findsOneWidget);
    });
  });

  group('the hero figure is typeset, not just enlarged', () {
    test('a currency mark and a decimal tail are split off the whole number',
        () {
      final p = GaiaBigNumber.splitNumber('₹1,77,213.93');
      expect(p.prefix, '₹');
      expect(p.whole, '1,77,213');
      expect(p.tail, '.93');
    });

    test('a bare integer stays whole', () {
      final p = GaiaBigNumber.splitNumber('4820');
      expect(p.prefix, '');
      expect(p.whole, '4820');
      expect(p.tail, '');
    });

    test('a trailing unit rides with the tail rather than breaking the split',
        () {
      final p = GaiaBigNumber.splitNumber('4.6');
      expect(p.whole, '4');
      expect(p.tail, '.6');
    });

    test('an em dash (the app renders one for "no value") does not crash it',
        () {
      final p = GaiaBigNumber.splitNumber('—');
      expect(p.prefix, '—');
      expect(p.whole, '');
      expect(p.tail, '');
    });
  });

  group('the page header', () {
    Widget host(Widget child) => MaterialApp(
          theme: GaiaTheme.dark(),
          home: Scaffold(body: SizedBox(width: 400, child: child)),
        );

    testWidgets('renders the wordmark, both title voices and the sub',
        (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(host(const GaiaPageHeader(
        wordmark: 'Gaia Test',
        meta: 'Overview',
        title: 'Welcome,',
        titleEmphasis: 'Asha.',
        sub: 'Owner',
      )));

      expect(find.text('GAIA TEST'), findsOneWidget);
      expect(find.text('OVERVIEW'), findsOneWidget);
      expect(find.text('OWNER'), findsOneWidget);

      final rich = tester.widget<RichText>(find.byType(RichText).at(2));
      final span = rich.text as TextSpan;
      expect(span.text, 'Welcome,');
      // The emphasis half is italic champagne at the same size — voice, not
      // scale.
      final em = span.children!.last as TextSpan;
      expect(em.text, 'Asha.');
      expect(em.style!.fontStyle, FontStyle.italic);
      expect(em.style!.color, GaiaColors.champagne);
      expect(em.style!.fontSize, span.style!.fontSize);
    });

    testWidgets('with no name, the greeting does not dangle a comma',
        (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await tester.pumpWidget(host(const GaiaPageHeader(
        wordmark: 'Gaia Test',
        title: 'Welcome',
      )));
      final rich = tester.widget<RichText>(find.byType(RichText).at(1));
      expect((rich.text as TextSpan).children, isEmpty);
    });
  });
}
