import 'package:flutter/material.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

/// The GAIA ThemeData — the mirror image of [AppTheme.dark] so the two systems
/// are structurally comparable: same slots filled, same order, same job.
///
/// This file does most of the restyling work on its own. The ~30 modules read
/// their type off `Theme.of(context).textTheme`, so mapping the Material slots
/// onto the Gaia scale here is what turns a module's headline into Cormorant
/// and its labels into tracked Instrument Sans WITHOUT a per-module edit. The
/// Gaia widget branches handle shape and border; this handles voice.
///
/// The slot mapping is not arbitrary — it follows what each slot is USED for in
/// this app, which is why the display slots go serif (they carry figures) and
/// the body slots go sans (they carry sentences):
///
/// ```
///   displayLarge   .big        62 serif   hero figure
///   displayMedium  .big small  40 serif   StatCard's big number
///   displaySmall   .mid        32 serif   secondary figure
///   headlineMedium h1.title    34 serif   screen greeting / page title
///   titleLarge     .card .name 22 serif   a card's name
///   titleMedium    .item .t    16 sans    a row's own title
///   bodyLarge/Med  body        15/14 sans copy
///   labelSmall     .eyebrow    11 sans    TRACKED UPPERCASE micro label
/// ```
abstract final class GaiaTheme {
  static ThemeData dark() {
    final ground = GaiaColors.ground;

    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: GaiaColors.champagne,
        onPrimary: GaiaColors.ink,
        secondary: GaiaColors.champagne2,
        onSecondary: GaiaColors.ink,
        surface: Color(0xFF132320),
        onSurface: GaiaColors.text,
        onSurfaceVariant: GaiaColors.text2,
        outline: Color(0xFF31443D),
        outlineVariant: Color(0xFF243430),
        error: GaiaColors.coral,
      ),
      scaffoldBackgroundColor: ground.bg,
      // The whole app speaks Instrument Sans unless a style opts into the
      // serif; setting the family here catches every widget that builds a
      // TextStyle without going through the text theme.
      fontFamily: GaiaType.sansFamily,
      fontFamilyFallback: GaiaType.sansFallback,
    );

    final text = base.textTheme.copyWith(
      // ── Serif: figures, names, titles ────────────────────────────────
      displayLarge: GaiaType.big(),
      // StatCard's value lands here. 40px rather than the mockup's 62 because
      // a StatCard is a GRID tile, not the full-bleed hero — the mockup's own
      // in-card figure (`.card .h .name`, `.stratum .h .v`) runs 24-30.
      displayMedium: GaiaType.serif(
        size: 40,
        weight: 500,
        height: 1,
        color: GaiaColors.champagne2,
        letterSpacing: GaiaType.track(-0.01, 40),
      ),
      displaySmall: GaiaType.serif(
        size: 32,
        weight: 500,
        height: 1.0,
        color: GaiaColors.text,
      ),
      // The screen greeting. 34 not 40: `h1.title` is a phone hero with a line
      // break in it, and the app's headlineMedium sits in denser chrome.
      headlineMedium: GaiaType.serif(
        size: 34,
        weight: 400,
        height: 1.1,
        color: GaiaColors.text,
        letterSpacing: GaiaType.track(-0.005, 34),
      ),
      headlineSmall: GaiaType.serif(
        size: 26,
        weight: 500,
        color: GaiaColors.text,
      ),
      titleLarge: GaiaType.serif(
        size: 22,
        weight: 500,
        color: GaiaColors.text,
      ),

      // ── Sans: everything that is read as language ────────────────────
      titleMedium: GaiaType.sans(
        size: 16,
        weight: 500,
        color: GaiaColors.text,
      ),
      titleSmall: GaiaType.sans(
        size: 13.5,
        weight: 600,
        color: GaiaColors.text,
      ),
      bodyLarge: GaiaType.sans(
        size: 15,
        height: 1.45,
        color: GaiaColors.text,
      ),
      bodyMedium: GaiaType.sans(
        size: 13.5,
        height: 1.45,
        color: GaiaColors.text2,
      ),
      bodySmall: GaiaType.sans(
        size: 12.5,
        height: 1.4,
        color: GaiaColors.text2,
      ),

      // The tracked uppercase micro label. Call sites pass an already-uppercase
      // string in this design; where they do not, the tracking still reads as
      // the same voice.
      //
      // text2, NOT text3: the spec's `--text-3` measures 4.20:1 on the forest
      // ground (see GaiaColors), and labelSmall is where this app puts figures'
      // captions — ink that is the only thing naming a number has to clear AA.
      // Eyebrows that merely repeat a nearby heading use text3 explicitly via
      // GaiaEyebrow.
      labelSmall: GaiaType.sans(
        size: 11,
        color: GaiaColors.text2,
        letterSpacing: GaiaType.track(0.18, 11),
      ),
      labelMedium: GaiaType.sans(
        size: 12,
        color: GaiaColors.text2,
        letterSpacing: GaiaType.track(0.06, 12),
      ),
      labelLarge: GaiaType.sans(
        size: 12,
        weight: 600,
        color: GaiaColors.text,
        letterSpacing: GaiaType.track(0.2, 12),
      ),
    );

    return base.copyWith(
      textTheme: text,
      // No ink splash. This design has no soft edges and no ripples; feedback
      // is a border and a ground change, the way `.pk:hover` works in the
      // mockup's own chrome.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      dividerTheme: DividerThemeData(
        color: ground.line,
        thickness: GaiaRadius.hairline,
        space: GaiaRadius.hairline,
      ),
      iconTheme: const IconThemeData(color: GaiaColors.text2, size: 18),
      // Same reason AppTheme spells this out: an AppBar drops its icon colours
      // when iconButtonTheme is empty, and every IconButton then falls back to
      // the raw dark-theme default.
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: GaiaColors.text2),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ground.raised,
          borderRadius: GaiaRadius.all,
          border: Border.all(color: ground.line2),
        ),
        textStyle: GaiaType.sans(size: 12.5, color: GaiaColors.text),
        waitDuration: const Duration(milliseconds: 400),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(ground.line2),
        radius: const Radius.circular(GaiaRadius.edge),
        thickness: WidgetStateProperty.all(4),
      ),
      // `.search` / `.deno input`: transparent over the ground, hairline
      // outline, square. Not a filled pill.
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        hintStyle: GaiaType.sans(size: 14, color: GaiaColors.text3),
        labelStyle: GaiaType.eyebrow(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: GaiaRadius.all,
          borderSide: BorderSide(color: ground.line2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: GaiaRadius.all,
          borderSide: BorderSide(color: ground.line2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: GaiaRadius.all,
          borderSide: const BorderSide(color: GaiaColors.champagne),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: GaiaRadius.all,
          borderSide: const BorderSide(color: GaiaColors.coral),
        ),
      ),
      // `.toggle` — a 40x22 hairline capsule with a 14px knob that goes from
      // text3 to ink when it lights. Material's Switch is the closest shape;
      // the exact geometry lives in GaiaToggle for call sites that want it.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? GaiaColors.ink
                : GaiaColors.text3),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? GaiaColors.champagne
                : Colors.transparent),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? GaiaColors.champagne
                : ground.line2),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: GaiaColors.champagne,
        inactiveTrackColor: ground.line2,
        trackHeight: 1,
        thumbColor: ground.bg,
        overlayColor: GaiaColors.champagne.withValues(alpha: 0.10),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: GaiaRadius.all),
        side: BorderSide(color: ground.line2),
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? GaiaColors.champagne
                : Colors.transparent),
        checkColor: WidgetStateProperty.all(GaiaColors.ink),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? GaiaColors.champagne
                : ground.line2),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: GaiaColors.champagne,
        linearTrackColor: Color(0xFF243430),
        linearMinHeight: 3,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ground.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: GaiaRadius.all,
          side: BorderSide(color: ground.line2),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ground.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: GaiaColors.text2),
        titleTextStyle: GaiaType.serif(size: 20, color: GaiaColors.text),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: ground.bg,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: GaiaRadius.none),
      ),
      cardTheme: CardThemeData(
        color: ground.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: GaiaRadius.all,
          side: BorderSide(color: ground.line),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: ground.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: GaiaRadius.all,
          side: BorderSide(color: ground.line2),
        ),
        textStyle: GaiaType.sans(size: 14, color: GaiaColors.text),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ground.raised,
        contentTextStyle: GaiaType.sans(size: 14, color: GaiaColors.text),
        shape: RoundedRectangleBorder(
          borderRadius: GaiaRadius.all,
          side: BorderSide(color: ground.line2),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      // Unchanged from AppTheme: the transition is chrome behaviour, not a
      // design-language decision, and the two systems should navigate alike.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
