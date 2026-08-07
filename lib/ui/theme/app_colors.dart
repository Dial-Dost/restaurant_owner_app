import 'package:flutter/material.dart';

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

  // ── Copper accent ramp (sequential, light -> dark) ─────────────────
  // --- Backdrop orange -------------------------------------------------------
  // The copper ramp above is DESATURATED (~0.47) — it is an ink and metal
  // palette, and washing a whole screen in it reads as brown, not as the warm
  // orange the guest ordering page and the app icon (#ea580c) actually use.
  // These three are the brand orange walked darker while KEEPING its saturation
  // (~0.85-0.94), so the backdrop can be dimmed without turning to mud.
  // Backdrop only: controls and text keep the copper ramp.
  static const Color glowBright = Color(0xFFC2410C);
  static const Color glowMid = Color(0xFF9A3412);
  static const Color glowDeep = Color(0xFF7C2D12);

  static const Color copperHi = Color(0xFFE3B89B);
  static const Color copper = Color(0xFFC9997A);
  static const Color copperMid = Color(0xFFA9795C);
  static const Color copperDeep = Color(0xFF7D5B47);
  static const Color copperShadow = Color(0xFF4E3928);
  /// Ink dark enough to sit on a copper-filled control.
  static const Color onCopper = Color(0xFF221510);

  static const List<Color> copperRamp = [
    copperHi,
    copper,
    copperMid,
    copperDeep,
    copperShadow,
  ];

  static const LinearGradient copperGradient = LinearGradient(
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
