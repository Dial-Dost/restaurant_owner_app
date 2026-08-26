import 'package:flutter/material.dart';

import 'contrast.dart';

/// One owner-app accent voice: the six-stop ramp every control/text accent is
/// drawn from, plus the three saturated "glow" tones the gradient backdrop
/// dims down. Same tonal recipe as the shipped Rustic Fork copper (a
/// desaturated ink-and-metal ramp with a high-saturation backdrop trio), so
/// every preset sits inside the design system instead of fighting it. The
/// curated catalogue + the per-device controller live in appearance.dart; this
/// type sits here so AppColors can hold one without an import cycle.
@immutable
class AppAccent {
  const AppAccent({
    required this.id,
    required this.label,
    required this.hi,
    required this.base,
    required this.mid,
    required this.deep,
    required this.shadow,
    required this.on,
    required this.glowBright,
    required this.glowMid,
    required this.glowDeep,
  });

  final String id;
  final String label;
  final Color hi;
  final Color base;
  final Color mid;
  final Color deep;
  final Color shadow;

  /// Ink dark enough to sit on an accent-filled control.
  final Color on;

  final Color glowBright;
  final Color glowMid;
  final Color glowDeep;
}

/// One complete dark shell voice: the ground -> surface -> card ladder plus
/// the ink that sits on it. The same tonal RECIPE as the shipped Rustic Fork
/// shell (a near-black page, hairline-separated warm surfaces, three ink
/// weights), re-tilted per scheme — warm, cool, blue, neutral — so every
/// choice stays inside the design system instead of fighting it. The curated
/// catalogue + the per-device controller live in appearance.dart; this type
/// sits here so AppColors can hold one without an import cycle (the same
/// arrangement as [AppAccent]).
@immutable
class AppShellScheme {
  const AppShellScheme({
    required this.id,
    required this.label,
    required this.bg,
    required this.bgDeep,
    required this.surface,
    required this.card,
    required this.cardTop,
    required this.cardBottom,
    required this.cardRaised,
    required this.inset,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
  });

  final String id;
  final String label;
  final Color bg;
  final Color bgDeep;
  final Color surface;
  final Color card;
  final Color cardTop;
  final Color cardBottom;
  final Color cardRaised;
  final Color inset;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
}

/// The Rustic Fork palette — a near-black workspace with a single warm
/// copper accent, sampled from the reference design.
///
/// Rules of the system:
///  * Charts are single-hue sequential copper (light -> dark), never
///    multi-hue categorical.
///  * Status is never color-alone: every status surface pairs its tint
///    with a text label (and usually a dot).
abstract final class AppColors {
  // ── Surfaces + ink: the active shell scheme ─────────────────────────
  // Historically eight const surfaces and three const inks; now backed by a
  // swappable AppShellScheme exactly the way the copper ramp is backed by a
  // swappable AppAccent: every call site keeps reading AppColors.bg /
  // AppColors.textPrimary and the device's scheme choice recolours the whole
  // app with no per-module edits. The default IS the original Rustic shell,
  // byte-identical by construction (aliased, not copied), applied before
  // anything can read these.
  //
  // On the rustic values themselves: warm-neutral, not grey. Every surface
  // used to lean COOL — B higher than R in all eight — which is invisible on
  // a black page and reads as grey the moment a warm backdrop sits behind it.
  // They lean warm by the same small amount, tilted toward the glow* orange,
  // holding G (which carries ~72% of relative luminance) so no contrast ratio
  // measured against them changed.
  static const AppShellScheme rusticShell = AppShellScheme(
    id: 'rustic',
    label: 'Rustic',
    bg: Color(0xFF0C0A09),
    bgDeep: Color(0xFF080605),
    surface: Color(0xFF151211),
    card: Color(0xFF1B1716),
    cardTop: Color(0xFF201B1A),
    cardBottom: Color(0xFF181412),
    cardRaised: Color(0xFF231E1E),
    inset: Color(0xFF110E0D),
    textPrimary: Color(0xFFECEAE6),
    textSecondary: Color(0xFF9A978F),
    textTertiary: Color(0xFF615E57),
  );

  static AppShellScheme _shell = rusticShell;

  /// The active shell scheme. Set ONLY by AppearanceController (which persists
  /// the per-device choice and notifies the app root to rebuild).
  static AppShellScheme get shell => _shell;
  static void applyShell(AppShellScheme s) => _shell = s;

  static Color get bg => _shell.bg;
  static Color get bgDeep => _shell.bgDeep;
  static Color get surface => _shell.surface;
  static Color get card => _shell.card;
  static Color get cardTop => _shell.cardTop;
  static Color get cardBottom => _shell.cardBottom;
  static Color get cardRaised => _shell.cardRaised;
  static Color get inset => _shell.inset;

  // ── Strokes ─────────────────────────────────────────────────────────
  // Alpha-white on purpose: a translucent hairline reads correctly over ANY
  // dark ground, so strokes need no per-scheme variants.
  static const Color border = Color(0x12FFFFFF); //  7% white
  static const Color borderStrong = Color(0x1FFFFFFF); // 12% white
  static const Color divider = Color(0x0DFFFFFF); //  5% white

  // ── Ink ─────────────────────────────────────────────────────────────
  static Color get textPrimary => _shell.textPrimary;
  static Color get textSecondary => _shell.textSecondary;
  static Color get textTertiary => _shell.textTertiary;

  // ── Accent ramp (sequential, light -> dark) ────────────────────────
  // Historically a const copper ramp; now backed by a swappable AppAccent so
  // the device's appearance setting can recolour the whole app WITHOUT a
  // single per-module edit — every call site keeps reading AppColors.copper*
  // (the names stay, whatever hue is active; renaming them would touch every
  // module for zero behaviour). The default IS the original Rustic Fork
  // copper, byte-identical, applied before anything can read these.
  //
  // The backdrop "glow" trio rides along: it is the accent walked darker while
  // KEEPING high saturation (~0.74-0.88), because the ramp itself is
  // DESATURATED (~0.47) ink-and-metal and washing a whole screen in it reads
  // as mud. Backdrop only: controls and text keep the ramp.
  static const AppAccent rusticCopper = AppAccent(
    id: 'copper',
    label: 'Copper',
    hi: Color(0xFFE3B89B),
    base: Color(0xFFC9997A),
    mid: Color(0xFFA9795C),
    deep: Color(0xFF7D5B47),
    shadow: Color(0xFF4E3928),
    on: Color(0xFF221510),
    glowBright: Color(0xFFC2410C),
    glowMid: Color(0xFF9A3412),
    glowDeep: Color(0xFF7C2D12),
  );

  static AppAccent _accent = rusticCopper;

  /// The active accent. Set ONLY by AppearanceController (which persists the
  /// per-device choice and notifies the app root to rebuild).
  static AppAccent get accent => _accent;
  static void applyAccent(AppAccent a) => _accent = a;

  static Color get glowBright => _accent.glowBright;
  static Color get glowMid => _accent.glowMid;
  static Color get glowDeep => _accent.glowDeep;

  static Color get copperHi => _accent.hi;
  static Color get copper => _accent.base;
  static Color get copperMid => _accent.mid;
  static Color get copperDeep => _accent.deep;
  static Color get copperShadow => _accent.shadow;
  /// Ink dark enough to sit on an accent-filled control.
  static Color get onCopper => _accent.on;

  static List<Color> get copperRamp => [
        copperHi,
        copper,
        copperMid,
        copperDeep,
        copperShadow,
      ];

  static LinearGradient get copperGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [copperHi, copperMid],
      );

  // ── Shell chrome (nav rail + phone drawer) ─────────────────────────
  // These used to be FROZEN hexes in home_shell.dart — copper composites
  // sampled by hand from what the desktop rail paints over the backdrop. That
  // is exactly why the phone sidebar ignored the accent setting: the drawer
  // floats opaque above the page, so it cannot inherit the backdrop's glow the
  // way the translucent rail does, and its sampled stand-ins stayed copper
  // whatever ramp the device wore. Deriving the same composites from the LIVE
  // glow tokens keeps the two form factors reading as one product for EVERY
  // accent (and later scheme), not just the one that was sampled.
  //
  // The alphas re-create the shipped copper samples to within one display byte
  // per channel (0.43 -> #3A170B vs #3A170C, etc.), so the default look is
  // preserved; they are not new design decisions.
  //
  // drawerTop alone is clamped: it is the brightest chrome surface, and the
  // greener glows (sage, teal) run brighter than copper's at the same alpha —
  // measured 4.47–4.48:1 under secondary ink, a hair below the 4.5 floor the
  // rest of the shell holds. The clamp trades a whisper of glow for the floor
  // instead of trading readability for glow.
  static Color get drawerTop => Color.alphaBlend(
      glowDeep.withValues(
          alpha: maxAlphaForContrast(
              tint: glowDeep, ground: bgDeep, ink: textSecondary, max: 0.43)),
      bgDeep);
  static Color get drawerMid =>
      Color.alphaBlend(glowDeep.withValues(alpha: 0.125), bg);
  static Color get drawerBottom =>
      Color.alphaBlend(glowDeep.withValues(alpha: 0.205), bg);

  /// The rail's mid-height scrim: the warm near-black the desktop sidebar
  /// passes through between the hero wash and the floor glow, at 58% so the
  /// backdrop still reads through it. Previously the frozen #94140D0A.
  static Color get railScrimMid => Color.alphaBlend(glowDeep.withValues(alpha: 0.075), bg)
      .withValues(alpha: 0.58);

  /// The rail's floor glow — glowDeep at 10%, previously the frozen #1A7C2D12.
  static Color get railGlowFloor => glowDeep.withValues(alpha: 0.10);

  static LinearGradient get cardGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [cardTop, cardBottom],
      );

  // ── Status (always shipped with a text label, never color alone) ───
  static const Color success = Color(0xFF8FB27C);
  static const Color warning = Color(0xFFD9A962);
  static const Color danger = Color(0xFFC97B6E);
  static const Color info = Color(0xFF8FA3B8);
  static const Color neutral = Color(0xFF9A978F);

  /// 12% tint used behind status chips.
  static Color tint(Color c) => c.withValues(alpha: 0.12);

  /// 28% stroke used around status chips.
  static Color edge(Color c) => c.withValues(alpha: 0.28);
}
