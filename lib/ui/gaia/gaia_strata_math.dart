/// The arithmetic behind STRATA, kept apart from the painting.
///
/// The mockup's Analytics screen carries one instruction — *"Read the strata
/// top down · thickness is share"* — and that sentence is a promise about
/// NUMBERS, not a description of an ornament. These screens show settled
/// revenue; a band that is 40% of the ink for 25% of the money is not a style
/// choice, it is a wrong figure drawn large. So the geometry lives here, as
/// pure functions over doubles with no BuildContext and no Canvas, and
/// `gaia_strata_test.dart` pins it. The widgets in `gaia_strata.dart` do
/// nothing but map these numbers onto pixels.
///
/// Three rules the whole file exists to hold:
///
///  1. **A share is always taken against the true whole**, which is the sum of
///     the POSITIVE readings. Negatives are never allowed into the
///     denominator: one refunded month must not quietly shrink every other
///     month's share, and a series that nets to zero must not produce a
///     division that reports 400%.
///  2. **Zero renders.** A zero band keeps its row, its label and its "₹0";
///     it is drawn at the minimum readable height with its top edge dashed, so
///     it is visibly a floor rather than a measurement. A zero SERIES in a
///     stack has no thickness anywhere — geometry cannot show it — so its key
///     entry states its 0% instead.
///  3. **Negative renders.** A negative band is drawn at its magnitude, on the
///     far side of a marked zero, in its own ink and with its own word. It is
///     never clamped to zero and never silently dropped.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How a band's thickness is decided.
enum GaiaStrataMode {
  /// Thickness is the value's share of the whole. Only legitimate when the
  /// values are PARTS OF A SUM — revenue by month, covers by table. Applying
  /// it to an average (APC by staff) would draw a proportion that does not
  /// exist, so the widgets refuse to guess and the caller must say.
  share,

  /// No whole exists, so no thickness claim is made: bands are content-height
  /// and only their ORDER, indent and ground tone carry the ranking. This is
  /// what the mockup's own Analytics strata does — KPI health by severity is a
  /// ranking, not a partition.
  rank,
}

/// One resolved band.
@immutable
class GaiaStratumLayout {
  const GaiaStratumLayout({
    required this.rank,
    required this.value,
    required this.share,
    required this.height,
    required this.floored,
    required this.isZero,
    required this.isNegative,
  });

  /// 0 = top of the strata.
  final int rank;

  /// The reading, exactly as given (non-finite input arrives here as 0).
  final double value;

  /// Signed share of the positive whole, 0..1 for a positive band and negative
  /// for a refund. Zero when there is no whole to take a share of — read
  /// [GaiaStrataLayout.hasWhole] before showing it.
  final double share;

  /// Band height in logical pixels. Zero in [GaiaStrataMode.rank], where the
  /// content decides.
  final double height;

  /// True when the proportional height was below the readable minimum and the
  /// band was raised to it. A floored band's height is NOT its share, which is
  /// why the widget marks it and the strata says so once, in words.
  final bool floored;

  final bool isZero;
  final bool isNegative;
}

/// A resolved strata.
@immutable
class GaiaStrataLayout {
  const GaiaStrataLayout({
    required this.bands,
    required this.positiveTotal,
    required this.mode,
    required this.negativeCount,
    required this.zeroCount,
  });

  final List<GaiaStratumLayout> bands;

  /// The denominator every [GaiaStratumLayout.share] was taken against.
  final double positiveTotal;

  final GaiaStrataMode mode;
  final int negativeCount;
  final int zeroCount;

  /// Whether a share means anything here. False when nothing is positive —
  /// an all-zero window, or a window that only contains refunds.
  bool get hasWhole => positiveTotal > 0;

  bool get anyFloored => bands.any((b) => b.floored);

  /// True when at least one band's height is a genuine proportion. False when
  /// every band floored (they are all at the minimum and the picture carries
  /// no quantity), or in rank mode, where no thickness claim is made at all.
  bool get proportional =>
      mode == GaiaStrataMode.share && hasWhole && bands.any((b) => !b.floored);

  double get totalHeight => bands.fold<double>(0, (a, b) => a + b.height);
}

/// The share/thickness solver.
abstract final class GaiaStrataMath {
  /// A band shorter than this cannot hold its own label, so it is never drawn
  /// shorter than this. See [GaiaStratumLayout.floored].
  ///
  /// The number is the band's own chrome, not a guess: `.stratum` pads 14 above
  /// and 12 below, and its figure is a 24px serif whose line box is about 29.
  /// The first version of this used 34 and the first render clipped every
  /// floored band's rupee figure out of existence — the exact failure the floor
  /// exists to prevent, arriving through the floor itself. It is measured
  /// against the rendered band, not estimated: 14 + 12 of padding around a row
  /// whose tallest child is the 24px serif figure beside a tag.
  ///
  /// [GaiaStrataList] scales this by the viewer's text scale rather than using
  /// it raw, so a 1.3x system setting grows the floor instead of clipping the
  /// figure it exists to protect.
  static const double defaultMinHeight = 64;

  static double _finite(double v) => v.isFinite ? v : 0;

  /// Resolve [values] (top-first) into bands filling [extent] logical pixels.
  ///
  /// The allocation is a bounded fixed point, not a single pass. Raising a
  /// hairline band to [minHeight] takes pixels away from the pool the others
  /// share, which can push the NEXT-smallest band under the minimum in turn;
  /// one pass would leave that band at an unreadable height. So bands are
  /// floored in rounds until a round adds none, and the survivors always split
  /// what is left **in exact proportion to each other** — which is the property
  /// that makes the picture readable as a quantity at all.
  ///
  /// When the floors alone exceed [extent] the result is TALLER than [extent]
  /// rather than squeezed: text is never crushed out of existence to honour a
  /// height budget, and [GaiaStrataLayout.proportional] goes false so the
  /// caller stops claiming the thickness means anything.
  static GaiaStrataLayout resolve({
    required List<double> values,
    required double extent,
    double minHeight = defaultMinHeight,
    GaiaStrataMode mode = GaiaStrataMode.share,
  }) {
    final n = values.length;
    if (n == 0) {
      return const GaiaStrataLayout(
        bands: [],
        positiveTotal: 0,
        mode: GaiaStrataMode.share,
        negativeCount: 0,
        zeroCount: 0,
      );
    }

    final vs = [for (final v in values) _finite(v)];
    // The whole is the sum of the POSITIVE readings — see rule 1 in the
    // library doc. A refund does not make the months around it bigger.
    final positiveTotal = vs.where((v) => v > 0).fold<double>(0, (a, b) => a + b);
    final negatives = vs.where((v) => v < 0).length;
    final zeros = vs.where((v) => v == 0).length;

    List<GaiaStratumLayout> build(List<double> heights) => [
          for (var i = 0; i < n; i++)
            GaiaStratumLayout(
              rank: i,
              value: vs[i],
              share: positiveTotal > 0 ? vs[i] / positiveTotal : 0,
              height: heights[i],
              floored: mode == GaiaStrataMode.share &&
                  positiveTotal > 0 &&
                  _isFloor(heights[i], minHeight),
              isZero: vs[i] == 0,
              isNegative: vs[i] < 0,
            ),
        ];

    if (mode == GaiaStrataMode.rank) {
      // No thickness claim: the widget lets content decide the height.
      return GaiaStrataLayout(
        bands: build(List<double>.filled(n, 0)),
        positiveTotal: positiveTotal,
        mode: mode,
        negativeCount: negatives,
        zeroCount: zeros,
      );
    }

    if (positiveTotal <= 0) {
      // Nothing to be a share OF. Uniform bands, and `hasWhole` false so the
      // caller says "no revenue in this window" instead of drawing six equal
      // slabs that look like six equal amounts.
      final h = math.max(minHeight, extent / n);
      return GaiaStrataLayout(
        bands: build(List<double>.filled(n, h)),
        positiveTotal: 0,
        mode: mode,
        negativeCount: negatives,
        zeroCount: zeros,
      );
    }

    // Ink is allocated by MAGNITUDE — a refund of 20% of the whole occupies
    // 20% of the ink, on the other side of zero. The signed share is kept for
    // the label; only the height uses |v|.
    final weights = [for (final v in vs) v.abs() / positiveTotal];

    final floored = List<bool>.filled(n, false);
    // At most one band can be newly floored per round, so n rounds is a hard
    // bound; the loop exits on the first round that floors nothing.
    for (var round = 0; round <= n; round++) {
      final flooredCount = floored.where((f) => f).length;
      final pool = extent - minHeight * flooredCount;
      final liveWeight = [
        for (var i = 0; i < n; i++)
          if (!floored[i]) weights[i],
      ].fold<double>(0, (a, b) => a + b);

      if (liveWeight <= 0 || pool <= 0) {
        for (var i = 0; i < n; i++) {
          floored[i] = true;
        }
        break;
      }
      var addedOne = false;
      for (var i = 0; i < n; i++) {
        if (floored[i]) continue;
        if (pool * weights[i] / liveWeight < minHeight) {
          floored[i] = true;
          addedOne = true;
          break; // re-solve the pool before judging the next one
        }
      }
      if (!addedOne) break;
    }

    final flooredCount = floored.where((f) => f).length;
    final pool = math.max(0.0, extent - minHeight * flooredCount);
    final liveWeight = [
      for (var i = 0; i < n; i++)
        if (!floored[i]) weights[i],
    ].fold<double>(0, (a, b) => a + b);

    final heights = [
      for (var i = 0; i < n; i++)
        floored[i] || liveWeight <= 0
            ? minHeight
            : pool * weights[i] / liveWeight,
    ];

    // Everything floored means the picture no longer carries a quantity. Say so
    // rather than let a wall of equal bands imply equal money.
    final allFloored = flooredCount == n;
    return GaiaStrataLayout(
      bands: [
        for (var i = 0; i < n; i++)
          GaiaStratumLayout(
            rank: i,
            value: vs[i],
            share: vs[i] / positiveTotal,
            height: heights[i],
            floored: allFloored || floored[i],
            isZero: vs[i] == 0,
            isNegative: vs[i] < 0,
          ),
      ],
      positiveTotal: positiveTotal,
      mode: mode,
      negativeCount: negatives,
      zeroCount: zeros,
    );
  }

  /// Floats never land exactly on the floor, so the comparison has to be
  /// tolerant — otherwise a band raised to exactly [minHeight] by arithmetic
  /// would sometimes report itself as proportional.
  static bool _isFloor(double h, double minHeight) => h <= minHeight + 1e-9;
}

/// One series in a stacked strata chart.
@immutable
class GaiaStrataSeries {
  const GaiaStrataSeries({required this.label, required this.values});

  final String label;

  /// One reading per x position. Every series in a chart must be the same
  /// length; [GaiaStrataStack.resolve] pads short ones with zero rather than
  /// throwing, because a short series is a backend that added a tender type
  /// mid-window, not a programming error.
  final List<double> values;
}

/// A band of one series at one x, in VALUE space (not pixels). `from <= to`
/// always; a positive reading sits above zero, a negative one below.
typedef GaiaStrataSpan = ({double from, double to});

/// The resolved geometry of a stacked strata chart.
@immutable
class GaiaStrataStackLayout {
  const GaiaStrataStackLayout({
    required this.length,
    required this.maxTop,
    required this.minBottom,
    required this.spans,
    required this.seriesPositiveTotals,
    required this.grandPositive,
    required this.hasNegative,
  });

  /// Points per series.
  final int length;

  /// The tallest positive stack across the window — where the reference line
  /// goes. Never below 0.
  final double maxTop;

  /// The deepest negative stack. Never above 0.
  final double minBottom;

  /// `spans[series][x]`.
  final List<List<GaiaStrataSpan>> spans;

  /// Sum of each series' positive readings — what its key entry's share is.
  final List<double> seriesPositiveTotals;

  final double grandPositive;
  final bool hasNegative;

  /// The value range the chart's height maps onto.
  double get span => maxTop - minBottom;

  /// Nothing to draw: every reading is zero, so there is no scale and a
  /// flat line would be a claim about a shape that does not exist.
  bool get isEmpty => span <= 0;

  /// Share of the whole window for one series. Zero when nothing is positive.
  double shareOf(int series) => grandPositive > 0
      ? seriesPositiveTotals[series] / grandPositive
      : 0;

  /// Map a value onto a y offset in a box [height] tall, y growing downward.
  double y(double value, double height) =>
      isEmpty ? height : (maxTop - value) / span * height;
}

abstract final class GaiaStrataStack {
  static double _finite(double v) => v.isFinite ? v : 0;

  /// Stack [series] in order: the first series sits against zero, each later
  /// one on top of the running total. Negative readings stack DOWNWARD from
  /// the same zero, so a stack that mixes signs still shows every magnitude at
  /// its true thickness on the correct side of a drawn baseline — rather than
  /// the usual fudge of clamping negatives to zero, which erases a refund.
  static GaiaStrataStackLayout resolve(List<GaiaStrataSeries> series) {
    final n = series.length;
    final length = series.fold<int>(0, (a, s) => math.max(a, s.values.length));
    if (n == 0 || length == 0) {
      return const GaiaStrataStackLayout(
        length: 0,
        maxTop: 0,
        minBottom: 0,
        spans: [],
        seriesPositiveTotals: [],
        grandPositive: 0,
        hasNegative: false,
      );
    }

    final spans = [for (var s = 0; s < n; s++) <GaiaStrataSpan>[]];
    final totals = List<double>.filled(n, 0);
    var maxTop = 0.0;
    var minBottom = 0.0;
    var hasNegative = false;

    // WHERE A ZERO SITS, and why it is not a free choice.
    //
    // A zero reading has no thickness, so its stacking anchor looks like it
    // cannot matter. It matters a great deal: a band is drawn as ONE polygon
    // across the whole window, and the edge between two adjacent points runs
    // from anchor to anchor. Park a refund series' zero on top of the positive
    // stack at Monday and at the baseline on Tuesday, and the polygon sweeps a
    // wedge across half the chart — a large filled shape standing for a day
    // with no refunds at all. The first render of the mixed-sign specimen drew
    // exactly that: two big crossing triangles over a five-point window whose
    // real refunds were 0, -12, 0, -38, -5.
    //
    // So a zero joins the side its OWN SERIES actually uses: the diverging
    // baseline for a series that ever goes below zero, and the running positive
    // total for one that never does (which keeps an all-positive stack
    // continuous through a zero day).
    final dips = [
      for (final s in series) s.values.any((v) => _finite(v) < 0),
    ];

    for (var x = 0; x < length; x++) {
      var up = 0.0;
      var down = 0.0;
      for (var s = 0; s < n; s++) {
        final vs = series[s].values;
        final v = x < vs.length ? _finite(vs[x]) : 0.0;
        if (v > 0 || (v == 0 && !dips[s])) {
          spans[s].add((from: up, to: up + v));
          up += v;
          totals[s] += v;
        } else if (v == 0) {
          spans[s].add((from: down, to: down));
        } else {
          spans[s].add((from: down + v, to: down));
          down += v;
          hasNegative = true;
        }
      }
      if (up > maxTop) maxTop = up;
      if (down < minBottom) minBottom = down;
    }

    return GaiaStrataStackLayout(
      length: length,
      maxTop: maxTop,
      minBottom: minBottom,
      spans: spans,
      seriesPositiveTotals: totals,
      grandPositive: totals.fold<double>(0, (a, b) => a + b),
      hasNegative: hasNegative,
    );
  }
}
