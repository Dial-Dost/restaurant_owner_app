import 'package:flutter/material.dart';

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

/// The Rustic Fork palette — a near-black workspace with a single warm
/// copper accent, sampled from the reference design.
///
/// Rules of the system:
///  * Charts are single-hue sequential copper (light -> dark), never
///    multi-hue categorical.
///  * Status is never color-alone: every status surface pairs its tint
///    with a text label (and usually a dot).
abstract final class AppColors {
  // ── Surfaces ────────────────────────────────────────────────────────
  // Warm-neutral, not grey. Every one of these used to lean COOL — B was higher
  // than R in all eight (bg -1, cardRaised -5) — which is invisible on a black
  // page and reads as grey the moment a warm backdrop sits behind it. They now
  // lean warm by the same small amount, tilted toward the glow* orange.
  //
  // The tilt raises R and drops B while HOLDING G, which carries ~72% of
  // relative luminance: every surface below moves by less than 0.0006, so no
  // contrast ratio measured against these changes.
  static const Color bg = Color(0xFF0C0A09);
  static const Color bgDeep = Color(0xFF080605);
  static const Color surface = Color(0xFF151211);
  static const Color card = Color(0xFF1B1716);
  static const Color cardTop = Color(0xFF201B1A);
  static const Color cardBottom = Color(0xFF181412);
  static const Color cardRaised = Color(0xFF231E1E);
  static const Color inset = Color(0xFF110E0D);

  // ── Strokes ─────────────────────────────────────────────────────────
  static const Color border = Color(0x12FFFFFF); //  7% white
  static const Color borderStrong = Color(0x1FFFFFFF); // 12% white
  static const Color divider = Color(0x0DFFFFFF); //  5% white

  // ── Ink ─────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFECEAE6);
  static const Color textSecondary = Color(0xFF9A978F);
  static const Color textTertiary = Color(0xFF615E57);

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

  static const LinearGradient cardGradient = LinearGradient(
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
