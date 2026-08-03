import 'package:flutter/material.dart';

/// The Rustic Fork palette — a near-black workspace with a single warm
/// copper accent, sampled from the reference design.
///
/// Rules of the system:
///  * Charts are single-hue sequential copper (light -> dark), never
///    multi-hue categorical.
///  * Status is never color-alone: every status surface pairs its tint
///    with a text label (and usually a dot).
///  * The navigation chrome inverts: light paper, dark ink (`chrome*`).
///    Nothing from the dark ink ramp may be painted on it.
abstract final class AppColors {
  // ── Surfaces ────────────────────────────────────────────────────────
  static const Color bg = Color(0xFF0A0A0B);
  static const Color bgDeep = Color(0xFF060607);
  static const Color surface = Color(0xFF121214);
  static const Color card = Color(0xFF17171A);
  static const Color cardTop = Color(0xFF1B1B1F);
  static const Color cardBottom = Color(0xFF141416);
  static const Color cardRaised = Color(0xFF1E1E23);
  static const Color inset = Color(0xFF0E0E10);

  // ── Strokes ─────────────────────────────────────────────────────────
  static const Color border = Color(0x12FFFFFF); //  7% white
  static const Color borderStrong = Color(0x1FFFFFFF); // 12% white
  static const Color divider = Color(0x0DFFFFFF); //  5% white

  // ── Ink ─────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFECEAE6);
  static const Color textSecondary = Color(0xFF9A978F);
  static const Color textTertiary = Color(0xFF615E57);

  // ── Copper accent ramp (sequential, light -> dark) ─────────────────
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

  // ── Chrome: the light navigation shell (sidebar, drawer, app bar) ──
  //
  // The chrome is deliberately INVERTED against the workspace — warm bone
  // paper carrying the dark content area — so the navigation reads as a frame
  // instead of dissolving into the modules it frames. Everything painted on
  // [chromeSurface] must take its colour from this block: the dark-theme ink
  // above is light, and light-on-light is the failure mode this inversion
  // invites. The ratios below are measured against [chromeSurface].
  static const Color chromeSurface = Color(0xFFF2EBE1);

  /// Nav labels, app-bar title. 13.6:1
  static const Color chromeText = Color(0xFF26201A);

  /// Inactive nav labels, eyebrow captions. 6.6:1
  static const Color chromeTextMuted = Color(0xFF5A5048);

  /// Nav and app-bar icons. 8.3:1
  static const Color chromeIcon = Color(0xFF4A423A);

  /// A disabled control in the chrome (the back button with an empty trail).
  /// 2.7:1 — WCAG exempts inactive controls, and the gap against the enabled
  /// 8.3:1 is what makes "you cannot press this" legible at a glance.
  static const Color chromeTextDisabled = Color(0x7326201A);

  /// The copper that survives paper — [copper] itself is only 2.1:1 here. 5.1:1
  static const Color chromeAccent = Color(0xFF7D5B47);

  /// Hairline rule *inside* the chrome.
  static const Color chromeDivider = Color(0x2926201A);

  /// The seam where the chrome meets the dark workspace: a deliberate rule,
  /// dark enough to read against the paper and lighter than the content
  /// behind it, so neither side looks torn.
  static const Color chromeEdge = Color(0xFF241C16);

  /// The selected nav item is a dark pill rather than a wash: a tint light
  /// enough to belong on paper tops out near 1.4:1, which is not a selection
  /// anyone can find at a glance. 11.3:1
  static const Color chromeActive = Color(0xFF3A2C22);

  /// Label on the selected pill. 11.3:1 on [chromeActive]
  static const Color onChromeActive = Color(0xFFF2EBE1);

  /// Tick and icon on the selected pill. 7.4:1 on [chromeActive]
  static const Color chromeActiveAccent = Color(0xFFE3B89B);

  /// Hover wash for an unselected nav item — 10% copper over the paper.
  static const Color chromeHover = Color(0x1A7D5B47);

  /// Scrollbar thumb for the nav list. The app-wide thumb is translucent white
  /// (1.03:1 on paper — a scrollbar nobody can see or grab), so the chrome
  /// overrides it with dark ink. 3.5:1
  static const Color chromeScrollThumb = Color(0x8C26201A);

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
