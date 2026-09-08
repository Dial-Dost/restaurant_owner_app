import 'package:flutter/material.dart';

import 'gaia_colors.dart';

/// The GAIA type system: Cormorant Garamond for display and numerals,
/// Instrument Sans for UI text. The pairing IS the signature of this design —
/// a serif that only ever carries figures and names, and a sans that only ever
/// carries labels — so both faces ship with the app rather than being resolved
/// at runtime.
///
/// ## The variable-font trap, and why every style here carries fontVariations
///
/// Both families are VARIABLE TTFs, lifted byte-for-byte out of the mockup's
/// own `@font-face` blocks. Their `fvar` defaults are:
///
/// ```
///   Cormorant Garamond   wght 300..700, default 300   (Light!)
///   Instrument Sans      wght 400..700, default 400
///                        wdth  75..100, default 100
/// ```
///
/// Flutter does NOT map [TextStyle.fontWeight] onto a variable axis — it uses
/// it to pick among the *manifest* entries, and there is one entry per family
/// here, so `fontWeight: FontWeight.w500` on Cormorant renders at the axis
/// default of **300**. Every serif in the design would come out a weight and a
/// half too light: the ₹1,77,213 hero, every card name, every table number.
/// That is exactly the silent substitution that changes the feel of a design
/// without anything looking broken.
///
/// So [serif] and [sans] always emit BOTH `fontWeight` (for Flutter's own
/// fallback/synthesis decisions) and `fontVariations: [wght]` (which is what
/// actually moves the axis). Nothing in the Gaia system should construct a
/// bare `TextStyle(fontFamily: ...)`; go through these two functions.
///
/// ## The second trap: figures
///
/// The mockup sets `font-variant-numeric: lining-nums` on `body` — one
/// declaration, easy to skim past, and it governs every number in the design.
/// It is there because Cormorant Garamond ships OLD-STYLE figures by default:
/// its 3, 4, 7 and 9 drop below the baseline and its 1 and 2 are x-height.
/// Beautiful in running prose, wrong for a till — a revenue total set in
/// old-style reads as decorative rather than as a figure, and a column of them
/// does not align.
///
/// The font carries `lnum` (verified in its GSUB), so both faces here request
/// it explicitly. Without this the app renders a visibly different — and
/// harder to read — set of numerals than the spec.
abstract final class GaiaType {
  static const String serifFamily = 'Cormorant Garamond';
  static const String sansFamily = 'Instrument Sans';

  /// Fallbacks. The mockup's own stacks are `--serif: ..., Georgia, serif` and
  /// `--sans: ..., "Helvetica Neue", Arial` — but those are BROWSER stacks
  /// backed by whatever the reader's machine has, and this app ships to a
  /// Windows till and an Android phone where that guarantee does not hold.
  ///
  /// ## Instrument Sans has no rupee sign
  ///
  /// Verified against its cmap: U+20B9 (₹) is ABSENT from both Instrument Sans
  /// faces, and present in both Cormorant faces. This app prices everything in
  /// rupees, so with a host-dependent fallback every `₹1,248` in body text —
  /// a bill line, an order detail, a chip — renders as a tofu box on any
  /// machine whose system fonts do not cover it. The first render of the Gaia
  /// Overview did exactly that.
  ///
  /// So the sans falls back FIRST to Cormorant Garamond, which this app
  /// bundles. That makes the glyph guaranteed rather than hoped for, at the
  /// cost of a serif ₹ sitting in front of sans digits in small text. It is a
  /// visible compromise and a deliberate one: a slightly mismatched currency
  /// mark is legible, a tofu box is not. Subsetting a ₹ into Instrument Sans
  /// would remove even that, and is the better long-term fix.
  ///
  /// Per-glyph fallback only engages for characters the primary face lacks, so
  /// nothing Instrument Sans DOES cover is affected.
  static const List<String> serifFallback = [
    'Georgia',
    'Times New Roman',
  ];
  static const List<String> sansFallback = [
    serifFamily, // bundled — guarantees ₹ and anything else Instrument lacks
    'Nirmala UI', // Windows' Indic face, has ₹
    'Noto Sans', // Android
    'Segoe UI',
    'Helvetica Neue',
    'Arial',
  ];

  /// Clamped to each family's real axis range — asking for a weight outside it
  /// is a no-op in some engines and an error in others, so it is pinned here.
  static double _clampSerif(double w) => w.clamp(300, 700);
  static double _clampSans(double w) => w.clamp(400, 700);

  /// `font-variant-numeric: lining-nums`, which the mockup sets on `body` and
  /// which therefore applies to every figure in the design. See the class doc:
  /// Cormorant defaults to old-style and would otherwise render the whole
  /// app's numbers wrong.
  static const List<FontFeature> _liningFigures = [FontFeature.liningFigures()];

  /// Cormorant Garamond. Display, numerals, names, prices — never body copy.
  static TextStyle serif({
    required double size,
    double weight = 500,
    Color? color,
    double? height,
    double? letterSpacing,
    bool italic = false,
    FontStyle? fontStyle,
  }) {
    final w = _clampSerif(weight);
    return TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: serifFallback,
      fontSize: size,
      // Both, deliberately — see the class doc.
      fontWeight: _nearestWeight(w),
      fontVariations: [FontVariation('wght', w)],
      fontFeatures: _liningFigures,
      fontStyle: fontStyle ?? (italic ? FontStyle.italic : FontStyle.normal),
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Instrument Sans. Everything the serif does not carry.
  static TextStyle sans({
    required double size,
    double weight = 400,
    Color? color,
    double? height,
    double? letterSpacing,
    bool italic = false,
  }) {
    final w = _clampSans(weight);
    return TextStyle(
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      fontSize: size,
      fontWeight: _nearestWeight(w),
      fontVariations: [FontVariation('wght', w)],
      fontFeatures: _liningFigures,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static FontWeight _nearestWeight(double w) {
    final i = ((w / 100).round() - 1).clamp(0, 8);
    return FontWeight.values[i];
  }

  // ── The scale, read off the mockup CSS ──────────────────────────────
  // Letter-spacing in the CSS is in `em`; Flutter's is in logical pixels, so
  // every tracked style below is `em * fontSize`. That conversion is the
  // reason these are functions of a size rather than a table of constants.

  /// `em` tracking -> Flutter's pixel tracking.
  static double track(double em, double size) => em * size;

  /// `.wordmark` — GAIA, 15px serif at .42em. The widest tracking in the
  /// design and the thing that makes the chrome read as a masthead.
  static TextStyle wordmark({Color? color}) => serif(
        size: 15,
        weight: 500,
        color: color ?? GaiaColors.champagne,
        letterSpacing: track(0.42, 15),
      );

  /// `h1.title` — 40px serif 400, line-height 1.05, -.005em.
  static TextStyle title({Color? color}) => serif(
        size: 40,
        weight: 400,
        height: 1.05,
        color: color ?? GaiaColors.text,
        letterSpacing: track(-0.005, 40),
      );

  /// `h1.title em` — the italic champagne half of a greeting.
  static TextStyle titleEm() => serif(
        size: 40,
        weight: 400,
        height: 1.05,
        italic: true,
        color: GaiaColors.champagne,
        letterSpacing: track(-0.005, 40),
      );

  /// `.big` — the hero figure. 62px serif 500, champagne-2, -.01em.
  static TextStyle big({Color? color}) => serif(
        size: 62,
        weight: 500,
        height: 1,
        color: color ?? GaiaColors.champagne2,
        letterSpacing: track(-0.01, 62),
      );

  /// `.big .r` — the raised currency mark before a hero figure.
  static TextStyle bigCurrency() =>
      serif(size: 32, weight: 400, color: GaiaColors.champagneDim);

  /// `.big .dec` — the decimal tail, dropped a step.
  static TextStyle bigDecimal() =>
      serif(size: 24, weight: 500, color: GaiaColors.champagneDim);

  /// `.mid` — 36px serif 500 in body ink.
  static TextStyle mid({Color? color}) =>
      serif(size: 36, weight: 500, height: 1, color: color ?? GaiaColors.text);

  /// `.stats .n` / `.stratum .h .v` — 32px and 24px serif 500.
  static TextStyle statNumber({Color? color}) =>
      serif(size: 32, weight: 500, height: 1, color: color ?? GaiaColors.text);

  /// `.card .h .name` / `.plan .h .n` — 26-30px serif 500. The name voice.
  static TextStyle cardName({double size = 26, Color? color}) =>
      serif(size: size, weight: 500, color: color ?? GaiaColors.text);

  /// `.item .v` — 22px serif 500, the value at the end of a list row.
  static TextStyle rowValue({Color? color}) =>
      serif(size: 22, weight: 500, color: color ?? GaiaColors.text);

  /// `.kv .v` — 20px serif 500.
  static TextStyle kvValue({Color? color}) =>
      serif(size: 20, weight: 500, color: color ?? GaiaColors.text);

  /// `.ital` / `.note` — 17px serif italic. The design's editorial aside.
  static TextStyle italNote({Color? color}) => serif(
        size: 17,
        weight: 400,
        italic: true,
        height: 1.45,
        color: color ?? GaiaColors.text2,
      );

  // ── Sans ────────────────────────────────────────────────────────────

  /// `body` — 15px / 1.45.
  static TextStyle body({Color? color}) =>
      sans(size: 15, height: 1.45, color: color ?? GaiaColors.text);

  /// `.item .t` — 16px, a list row's own title.
  static TextStyle rowTitle({Color? color}) =>
      sans(size: 16, color: color ?? GaiaColors.text);

  /// `.item .d` / `.card .sub2` — 13.5px secondary detail.
  static TextStyle detail({Color? color}) =>
      sans(size: 13.5, height: 1.45, color: color ?? GaiaColors.text2);

  /// `.meta,.eyebrow,.cap` — 11px, .18em, UPPERCASE. The workhorse micro
  /// label; the caller uppercases the string (see `GaiaEyebrow`).
  static TextStyle eyebrow({Color? color}) => sans(
        size: 11,
        color: color ?? GaiaColors.text2,
        letterSpacing: track(0.18, 11),
      );

  /// `.tabs span` — 11.5px, .18em, UPPERCASE.
  static TextStyle tabLabel({Color? color}) => sans(
        size: 11.5,
        color: color ?? GaiaColors.text2,
        letterSpacing: track(0.18, 11.5),
      );

  /// `.btn` — 12px, .2em, UPPERCASE, 600.
  static TextStyle button({Color? color, bool dense = false}) => sans(
        size: dense ? 11 : 12,
        weight: 600,
        color: color ?? GaiaColors.champagne,
        letterSpacing: track(0.2, dense ? 11 : 12),
      );

  /// `.pill` / `.stratum .tag` — 10.5px, .14em, UPPERCASE.
  static TextStyle pill({Color? color}) => sans(
        size: 10.5,
        color: color ?? GaiaColors.text2,
        letterSpacing: track(0.14, 10.5),
      );

  /// `.tabbar a` — 10px, .2em, UPPERCASE. The smallest type in the design.
  static TextStyle navLabel({Color? color}) => sans(
        size: 10,
        color: color ?? GaiaColors.text2,
        letterSpacing: track(0.2, 10),
      );

  /// `.stats .n small` / `.item .v small` — the unit hung off a serif figure,
  /// which always switches back to the sans.
  static TextStyle unit({Color? color}) => sans(
        size: 11,
        color: color ?? GaiaColors.text2,
        letterSpacing: track(0.06, 11),
      );
}
