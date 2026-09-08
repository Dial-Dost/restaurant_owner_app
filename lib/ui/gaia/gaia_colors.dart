import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// One GAIA ground ladder. The mockup carries three (`.forest`, `.oxblood`,
/// `.petrol`) as screen-level classes over ONE shared ink/accent set, so the
/// ground is the only thing that varies — which is exactly what this holds.
///
/// From the mockup CSS:
/// ```
/// .forest {--bg:#0c1513;--surface:#132320;--raised:#182b27;--line:#243430;--line-2:#31443d}
/// .oxblood{--bg:#20110f;--surface:#2b171b;--raised:#35202a;--line:#46272c;--line-2:#59433c}
/// .petrol {--bg:#0b161b;--surface:#101f26;--raised:#162933;--line:#1f333c;--line-2:#2b4450}
/// ```
@immutable
class GaiaGround {
  const GaiaGround({
    required this.id,
    required this.label,
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.line2,
  });

  final String id;
  final String label;

  /// Page ground.
  final Color bg;

  /// Card / panel fill.
  final Color surface;

  /// The one step above `surface` — the focused coverflow card, an occupied
  /// table, a stratum band.
  final Color raised;

  /// Hairline. Every separation in this design is a 1px line of this colour;
  /// there are no shadows inside the phone frame.
  final Color line;

  /// The stronger hairline — control outlines, dashed cards, pills.
  final Color line2;
}

/// The GAIA palette, lifted verbatim from `gaia-ui-revamp.html`'s `:root` and
/// ground classes. Nothing here is interpolated or "close enough": the hexes
/// are the spec's own.
///
/// ## What this design does NOT have
///
/// No shadows, no gradients, no radii above 2px. Depth is carried entirely by
/// the `bg -> surface -> raised` ground ladder plus a 1px [GaiaGround.line]
/// hairline; the only round shapes are dots, avatars and the toggle knob.
/// The Rustic Fork system's vocabulary is the opposite (14px radii, vertical
/// card gradients, ambient drop shadows), which is why the two cannot share
/// primitives and each Gaia widget draws its own box.
///
/// ## Measured contrast on the forest ground (WCAG 2.1, 1px-accurate)
///
/// ```
///                    on bg     on surface  on raised
///   text     #ede6d6  14.92       13.10       11.95
///   text2    #b3ac99   8.19        7.20        6.56
///   text3    #7d7866   4.20        3.69        3.36   <-- BELOW AA 4.5
///   champagne#d3b88b   9.71        8.53        7.78
///   champagne2 #e2cfa6 12.11      10.64        9.70
///   coral    #d9705f   5.68        4.99        4.55
///   sage     #9bc4a0   9.54        8.38        7.64
///   amber    #d9b06a   9.16        8.04        7.33
///   ink      #1a1410 on champagne: 9.55        on champagne2: 11.91
/// ```
///
/// [text3] is the spec's own `--text-3` and it does not clear AA 4.5:1. It is
/// reproduced UNCHANGED because the mockup is the spec and quietly lifting it
/// would change the feel of every eyebrow and column head in the design. It is
/// therefore treated as a DECORATIVE ink here: [GaiaTheme] never uses it as the
/// sole carrier of a value, only for eyebrows and axis labels that repeat
/// information the AA-clearing ink beside them already states. `gaia_theme_test
/// .dart` measures the whole ladder so this stays a recorded decision rather
/// than a silent one. [text3AA] is the lifted alternative for anywhere that
/// needs a genuinely readable faint ink.
abstract final class GaiaColors {
  // ── Accent ──────────────────────────────────────────────────────────
  static const Color champagne = Color(0xFFD3B88B);
  static const Color champagne2 = Color(0xFFE2CFA6);
  static const Color champagneDim = Color(0xFFA08C67);

  /// Ink dark enough to sit on a champagne-filled control (`--ink`).
  static const Color ink = Color(0xFF1A1410);

  // ── Status ──────────────────────────────────────────────────────────
  static const Color coral = Color(0xFFD9705F); // bad
  static const Color sage = Color(0xFF9BC4A0); // good
  static const Color amber = Color(0xFFD9B06A); // warn

  // ── Ink ─────────────────────────────────────────────────────────────
  static const Color text = Color(0xFFEDE6D6);
  static const Color text2 = Color(0xFFB3AC99);
  static const Color text3 = Color(0xFF7D7866);

  /// [text3] walked up the same hue until it clears AA 4.5:1 on every Gaia
  /// ground — measured 5.79 / 5.09 / 4.64 on bg / surface / raised, the last
  /// being the worst case. Use where a faint ink is the ONLY thing saying
  /// something.
  static const Color text3AA = Color(0xFF95907C);

  // ── Grounds ─────────────────────────────────────────────────────────
  static const GaiaGround forest = GaiaGround(
    id: 'forest',
    label: 'Forest',
    bg: Color(0xFF0C1513),
    surface: Color(0xFF132320),
    raised: Color(0xFF182B27),
    line: Color(0xFF243430),
    line2: Color(0xFF31443D),
  );

  /// The mockup uses oxblood for the three GUEST-FACING pages only — screens
  /// 28 (guest order), 29 (guest queue) and 30 (guest reserve). It is the
  /// "this is the diner's view, not yours" signal, so it belongs to the guest
  /// surfaces and must not be offered as an owner-app ground.
  static const GaiaGround oxblood = GaiaGround(
    id: 'oxblood',
    label: 'Oxblood',
    bg: Color(0xFF20110F),
    surface: Color(0xFF2B171B),
    raised: Color(0xFF35202A),
    line: Color(0xFF46272C),
    line2: Color(0xFF59433C),
  );

  /// Used by exactly one screen in the mockup — 04 Kitchen (the KDS). Same
  /// idea as oxblood: a ground that says "you are on the pass", legible from
  /// across a hot line.
  static const GaiaGround petrol = GaiaGround(
    id: 'petrol',
    label: 'Petrol',
    bg: Color(0xFF0B161B),
    surface: Color(0xFF101F26),
    raised: Color(0xFF162933),
    line: Color(0xFF1F333C),
    line2: Color(0xFF2B4450),
  );

  /// The page behind the phone frame (`html{background:#050807}`) — the app's
  /// deepest ground.
  static const Color bgDeep = Color(0xFF050807);

  /// Input / recessed panel fill. The mockup's inputs are transparent over the
  /// page ground with a `--line-2` outline (`.deno input`), so this sits one
  /// step BELOW surface rather than above it.
  static const Color inset = Color(0xFF0E1A17);

  static const List<GaiaGround> all = [forest, oxblood, petrol];

  /// The owner app's ground. Every owner screen in the mockup except the KDS
  /// is `.forest`.
  static GaiaGround get ground => forest;

  static Color get bg => ground.bg;
  static Color get surface => ground.surface;
  static Color get raised => ground.raised;
  static Color get line => ground.line;
  static Color get line2 => ground.line2;

  // ── Bridges into the Rustic Fork token surface ──────────────────────
  // AppColors is already a swappable ladder — `applyShell` / `applyAccent`
  // exist precisely so a palette choice can recolour every one of the ~30
  // modules without a per-module edit. GAIA rides that same extension point,
  // which is why flipping the design system restyles screens this agent never
  // opened. Neither of these is registered in AppSchemes.all / AppAccents.all:
  // they are not owner-pickable presets, they are the Gaia system's colours,
  // and keeping them out of those lists leaves the existing appearance picker
  // and its 5x8 contrast matrix exactly as they were.

  /// Forest, expressed as a Rustic shell scheme.
  ///
  /// `cardTop` and `cardBottom` are deliberately IDENTICAL: they exist to feed
  /// `AppColors.cardGradient`, and a Gaia card is flat, so the gradient has to
  /// degenerate to a single colour rather than reintroduce a sheen the design
  /// does not have.
  static const AppShellScheme shellBridge = AppShellScheme(
    id: 'gaia-forest',
    label: 'Gaia Forest',
    bg: Color(0xFF0C1513),
    bgDeep: bgDeep,
    surface: Color(0xFF132320),
    card: Color(0xFF132320),
    cardTop: Color(0xFF132320),
    cardBottom: Color(0xFF132320),
    cardRaised: Color(0xFF182B27),
    inset: inset,
    textPrimary: text,
    textSecondary: text2,
    textTertiary: text3,
  );

  /// Champagne, expressed as a Rustic accent ramp.
  ///
  /// `deep`/`shadow` continue the champagne ramp past `--champagne-dim` (the
  /// mockup only names three stops; the ramp needs five for charts). The
  /// `glow*` trio is NOT champagne: those three feed the gradient backdrop and
  /// the drawer composites, and washing a screen in gold reads as brass plate.
  /// They are the forest greens the bokeh layer uses (`.bokeh .b` #3d6a55,
  /// `.d` #2e5a48), walked darker — so un-ported chrome stays in the wood.
  static const AppAccent accentBridge = AppAccent(
    id: 'gaia-champagne',
    label: 'Gaia Champagne',
    hi: champagne2,
    base: champagne,
    mid: champagneDim,
    deep: Color(0xFF7A6A4D),
    shadow: Color(0xFF4C4231),
    on: ink,
    glowBright: Color(0xFF3D6A55),
    glowMid: Color(0xFF2E5A48),
    glowDeep: Color(0xFF1E3A2D),
  );

  /// Sequential champagne ramp for charts — light to dark, single hue, the
  /// same rule the Rustic system holds.
  static const List<Color> ramp = [
    champagne2,
    champagne,
    champagneDim,
    Color(0xFF7A6A4D),
    Color(0xFF4C4231),
  ];

  /// 12% tint behind a status chip, matching [AppColors.tint]'s contract.
  static Color tint(Color c) => c.withValues(alpha: 0.12);

  /// The chip stroke. Gaia pills outline in the STATUS COLOUR ITSELF at full
  /// strength (`.pill.coral{border-color:var(--coral)}`), not at 28% like the
  /// Rustic chips, which is what makes them read as engraved rather than
  /// tinted.
  static Color edge(Color c) => c;
}

/// The STRATA palette — the band grounds, the stacking ramp, and the two inks
/// that had to be lifted off the spec to stay readable inside a band.
///
/// From the mockup CSS:
/// ```
/// .stratum.s1{background:#1d3129}          .stratum.s4{background:#112019;margin-left:16px}
/// .stratum.s2{background:#182a26}          .stratum.s5{background:#0f1c18;margin-left:24px}
/// .stratum.s3{background:#142521;margin-left:8px}
/// .stratum.s6{background:#0d1816;margin-left:32px}
/// .strata-key .k1::before{background:#d3b88b}
/// .strata-key .k2::before{background:#8a7a58}
/// .strata-key .k3::before{background:#4f4a3a}
/// ```
///
/// ## Two measured problems with the spec's own values, and what was done
///
/// **1. `--text-3` is not readable on a band.** Measured on the six band
/// grounds it runs 3.12 / 3.40 / 3.61 / 3.82 / 3.96 / 4.10 — every one below
/// AA 4.5:1, and the LIGHTEST band (s1, the one at the top of every strata) is
/// the worst. A stratum's caption is the sentence that says why a KPI is red
/// or what a month's average cheque was; nothing else on the band repeats it.
/// So [GaiaStrataColors] never puts a caption in `text3`. Captions are
/// [GaiaColors.text2] (6.09 on s1, 8.00 on s6) and nothing quieter.
///
/// **2. `--coral` is 4.22 on the lightest band.** The `Action` tag is the
/// severity marker on a money screen; 4.22 is close but under. [tagCoral] is
/// the same hue walked up until it clears — #DB7969, measured 4.56 on s1 and
/// 5.99 on s6. Sage (7.09), amber (6.81) and champagne (7.22) already clear on
/// every band and are reproduced unchanged.
///
/// **3. Adjacent ramp stops are 2.2:1 apart** (#d3b88b vs #8a7a58 = 2.20,
/// #8a7a58 vs #4f4a3a = 2.11, #4f4a3a vs the forest ground = 2.10), all under
/// the 3:1 that adjacent graphical objects want. The ramp is the spec's and is
/// kept; the remedy is the design's own vocabulary — a 1px ground-coloured
/// hairline is drawn between every stacked band and around the stack, so each
/// band has a defined EDGE whatever its fill, and the key names every band
/// with a rank numeral, a label and its share so the colour is never the thing
/// carrying the identity.
abstract final class GaiaStrataColors {
  /// `.stratum.s1` .. `.s6`, lightest (top, most severe / largest) first.
  static const List<Color> bands = [
    Color(0xFF1D3129),
    Color(0xFF182A26),
    Color(0xFF142521),
    Color(0xFF112019),
    Color(0xFF0F1C18),
    Color(0xFF0D1816),
  ];

  /// `.stratum.s3{margin-left:8px}` .. `.s6{margin-left:32px}` — the first two
  /// bands are flush, then each step indents 8px further. Position is the
  /// second, non-colour channel carrying rank.
  static const List<double> indents = [0, 0, 8, 16, 24, 32];

  /// The ordinal ramp a stack is drawn in — `.strata-key`'s k1/k2/k3, extended
  /// past the mockup's three stops for a longer composition. Single hue,
  /// light-to-dark, so "brighter = earlier in the key" is the only reading.
  static const List<Color> ramp = [
    Color(0xFFD3B88B),
    Color(0xFF8A7A58),
    Color(0xFF4F4A3A),
    Color(0xFF35322A),
    Color(0xFF262520),
  ];

  /// A band's ground for its rank. Ranks past the ramp reuse the darkest,
  /// which is what the mockup's own `.s6` does for "Earlier".
  static Color band(int rank) => bands[rank.clamp(0, bands.length - 1)];

  static double indent(int rank) => indents[rank.clamp(0, indents.length - 1)];

  static Color rampAt(int i) => ramp[i.clamp(0, ramp.length - 1)];

  /// [GaiaColors.coral] lifted to clear AA 4.5:1 on the LIGHTEST band ground
  /// (measured 4.56 on #1D3129). See the class doc.
  static const Color tagCoral = Color(0xFFDB7969);
}

/// The BICOLOUR inks — the ink ramp for the champagne-ground panel.
///
/// ```
/// .bico{background:var(--champagne);color:var(--ink)}
/// .bico .eyebrow{color:#6b5634}
/// .bico .lever p{color:#5a4a32}
/// .bico .slider{background:rgba(26,20,16,.28)}
/// .bico .btn{border-color:var(--ink);color:var(--ink)}
/// .bico .btn.primary{background:var(--ink);color:var(--champagne)}
/// ```
///
/// ## The spec's two supporting inks do not clear AA, and here they had to
///
/// Measured on `--champagne` #D3B88B: the eyebrow #6B5634 is **3.66:1** and
/// the explainer #5A4A32 is **4.47:1**. Both are under AA 4.5, and unlike
/// `--text-3` on the dark ground neither is decorative — inside this panel the
/// eyebrow is the lever CATEGORY header and the `p` is the only sentence that
/// says what a lever does to the projection. On a screen that models money,
/// with the panel filling half the viewport in the brightest colour the system
/// owns, that is not a place to reproduce a near-miss.
///
/// So [label] and [body] are the spec's own hues walked one step darker until
/// they clear: **#5A482C (4.59)** and **#584931 (4.56)**. The difference from
/// the mockup is a couple of percent of lightness and is not visible side by
/// side; the difference in a bright kitchen is legible versus not.
///
/// ## Status colour cannot survive the inversion
///
/// The dark-ground status inks are catastrophic here — coral #D9705F measures
/// **1.71:1** on champagne and sage #9BC4A0 measures **1.02:1**, which is
/// invisible, not merely low. A chip or a delta that keeps its colour across
/// the inversion would silently stop existing. [statusBad] / [statusGood] /
/// [statusWarn] are the same three hues taken down to the champagne side of
/// the fence (4.50 / 4.55 / 4.59), so the meaning survives the ground change.
abstract final class GaiaBicolourColors {
  /// The panel ground — `--champagne`.
  static const Color ground = GaiaColors.champagne;

  /// Primary ink on the panel — `--ink`, 9.55:1.
  static const Color ink = GaiaColors.ink;

  /// `.bico .eyebrow`, lifted to 4.59:1. See the class doc.
  static const Color label = Color(0xFF5A482C);

  /// `.bico .lever p` / `.bico .note`, lifted to 4.56:1.
  static const Color body = Color(0xFF584931);

  /// `.bico .lever{border-top:1px solid rgba(26,20,16,.16)}`.
  static Color get line => GaiaColors.ink.withValues(alpha: 0.16);

  /// `.bico .slider{background:rgba(26,20,16,.28)}`.
  static Color get line2 => GaiaColors.ink.withValues(alpha: 0.28);

  /// Status, re-inked for the champagne ground. See the class doc. Measured
  /// against #D3B88B: 4.50 / 4.55 / 4.59 / 4.61.
  static const Color statusBad = Color(0xFF872E20);
  static const Color statusGood = Color(0xFF315335);
  static const Color statusWarn = Color(0xFF614619);
  static const Color statusInfo = Color(0xFF3C4C5E);

  /// The dark half of the split — the same forest ground the rest of the app
  /// stands on, so the two halves read as one screen cut in two rather than as
  /// a card floating on a page.
  static Color get darkGround => GaiaColors.bg;
}
