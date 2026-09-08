import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_strata_math.dart';
import 'gaia_type.dart';

export 'gaia_strata_math.dart';

/// STRATA — the signature treatment for Analytics and History.
///
/// Two shapes, both from the mockup, both driven entirely by
/// [GaiaStrataMath] / [GaiaStrataStack] so the picture cannot drift from the
/// number:
///
///  * [GaiaStrataChart] — `.strata-chart`, the stacked area. Thickness at any
///    point is that reading's value on one shared linear scale, so a band that
///    is twice as thick is twice the money.
///  * [GaiaStrataList] — `.stratum`, the horizontal bands. In
///    [GaiaStrataMode.share] a band's HEIGHT is its share of the whole; in
///    [GaiaStrataMode.rank] no height claim is made at all and the order,
///    indent and ground tone carry the ranking instead.
///
/// ## Colour is never the channel that carries a value
///
/// These screens are read across a hot line and by people who cannot separate
/// coral from sage. So:
///
///  * Every band states its own figure and, in share mode, its own percentage.
///    The height is the fast read; the number is the exact one.
///  * Every chart key entry is numbered `01`, `02`, `03` in stacking order, so
///    a reader who cannot tell the three fills apart can still map key to band
///    by counting down from the top.
///  * Every status is a WORD (`ACTION`, `ON TARGET`, `ZERO`, `NEGATIVE`) as
///    well as an ink.
///  * A 1px ground-coloured hairline separates adjacent fills. The spec's own
///    ramp stops are only ~2.2:1 apart, below the 3:1 adjacent graphical
///    objects want, and the hairline is the design's existing answer to
///    "where does this end and that begin".
///
/// ## Which mode is honest for which data
///
/// [GaiaStrataMode.share] is only legitimate when the values are PARTS OF A
/// SUM. Revenue by month is (the months add up to the window). Average per
/// cover by staff is NOT — three waiters averaging ₹900 do not add up to
/// ₹2,700 of anything, and drawing thirds of a bar would invent a proportion.
/// There is no auto-detection here on purpose: the caller has to say which it
/// is, because only the caller knows.

/// One band's content. The value is separate from its formatted [display] so
/// the geometry uses the true number while the label keeps the screen's own
/// rounding and currency.
@immutable
class GaiaStratum {
  const GaiaStratum({
    required this.label,
    required this.value,
    required this.display,
    this.caption,
    this.unit,
    this.tagLabel,
    this.tagColor,
    this.onTap,
  });

  /// `.stratum .h .k` — the band's name, uppercased by the widget.
  final String label;

  /// The real number. Drives every pixel.
  final double value;

  /// The number as the screen writes it — "₹1,77,214", "107.9", "5".
  final String display;

  /// `.stratum .h .v small` — the unit hung off the serif figure.
  final String? unit;

  /// `.stratum p` — the sentence under the figure.
  final String? caption;

  /// `.stratum .tag` — `ACTION`, `49 CHEQUES`.
  final String? tagLabel;
  final Color? tagColor;

  final VoidCallback? onTap;
}

/// `.strata` — the band column.
class GaiaStrataList extends StatelessWidget {
  const GaiaStrataList({
    super.key,
    required this.strata,
    this.mode = GaiaStrataMode.rank,
    this.extent = 320,
    this.minHeight,
    this.caption,
  });

  final List<GaiaStratum> strata;

  /// See the class doc — [GaiaStrataMode.share] makes a claim about
  /// proportions and must only be used where one is true.
  final GaiaStrataMode mode;

  /// Total pixel height the share-mode bands divide between them. Ignored in
  /// rank mode, where the content decides.
  ///
  /// Size it with [extentFor] rather than by eye: too small a budget and the
  /// floors eat it, every band lands at the minimum, and the strata stops
  /// carrying a quantity at all.
  final double extent;

  /// A budget that leaves the proportional bands real room after the floors.
  ///
  /// The floors are the fixed cost — one per row that is too small to draw —
  /// so the budget has to be "enough for all of them, PLUS a span for the ones
  /// that are genuinely proportional". [headroom] is that span.
  static double extentFor(int rows, {double headroom = 320, double cap = 1200}) {
    final need = headroom + rows * GaiaStrataMath.defaultMinHeight;
    return need > cap ? cap : need;
  }

  /// Null means "the design's floor, scaled to the viewer's text size" — see
  /// [GaiaStrataMath.defaultMinHeight]. Pass a number only to pin it.
  final double? minHeight;

  /// An extra sentence under the strata, joined to whatever the layout itself
  /// has to disclose (floored bands, no whole, refunds).
  final String? caption;

  /// The ground tone for a band.
  ///
  /// In rank mode this is simply the band's position, which is what the mockup
  /// does. In SHARE mode it follows the share instead — biggest share gets the
  /// lightest ground — so tone reinforces height rather than fighting it. That
  /// matters because a share-mode strata is usually ordered by TIME, not size:
  /// on History the newest month is on top whether it earned ₹2 or ₹2 lakh,
  /// and letting the ground lighten by date would say "recent means big".
  static List<int> tones(List<GaiaStratum> strata, GaiaStrataMode mode) {
    if (mode == GaiaStrataMode.rank) {
      return [for (var i = 0; i < strata.length; i++) i];
    }
    final order = [for (var i = 0; i < strata.length; i++) i]
      ..sort((a, b) => strata[b].value.abs().compareTo(strata[a].value.abs()));
    final tone = List<int>.filled(strata.length, 0);
    for (var pos = 0; pos < order.length; pos++) {
      tone[order[pos]] = pos;
    }
    return tone;
  }

  @override
  Widget build(BuildContext context) {
    if (strata.isEmpty) return const SizedBox.shrink();
    // The floor is what keeps a 1% band readable, so it has to grow with the
    // type. A fixed 64 at a 1.3x system text scale clips the very figure the
    // floor exists to protect.
    final minH = minHeight ??
        MediaQuery.textScalerOf(context).scale(GaiaStrataMath.defaultMinHeight);
    final layout = GaiaStrataMath.resolve(
      values: [for (final s in strata) s.value],
      extent: extent,
      minHeight: minH,
      mode: mode,
    );
    final tone = tones(strata, mode);

    // Everything the picture cannot say for itself gets said in words, once,
    // under the strata. Silence here is how a chart lies.
    final notes = <String>[
      ?caption,
      if (mode == GaiaStrataMode.share && !layout.hasWhole)
        'No positive total in this window, so no band is a share of anything —'
            ' these are drawn at equal height.',
      if (mode == GaiaStrataMode.share && layout.hasWhole && !layout.proportional)
        'Too many rows to give any band a height that means anything here —'
            ' every one is at its minimum, so read the percentages rather than'
            ' the thicknesses.'
      else if (mode == GaiaStrataMode.share && layout.hasWhole && layout.anyFloored)
        'Bands too small to hold a label are drawn at their minimum height and'
            ' marked with a dashed edge — read their percentage, not their'
            ' thickness.',
      if (layout.negativeCount > 0)
        '${layout.negativeCount} band${layout.negativeCount == 1 ? '' : 's'}'
            ' below zero, drawn at magnitude and excluded from the total the'
            ' shares are taken against.',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < strata.length; i++)
          _Band(
            stratum: strata[i],
            layout: layout.bands[i],
            tone: tone[i],
            mode: mode,
            hasWhole: layout.hasWhole,
            first: i == 0,
            minHeight: minH,
          ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: GaiaSpacing.md),
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(n, style: GaiaType.detail(color: GaiaColors.text2)),
            ),
        ],
      ],
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({
    required this.stratum,
    required this.layout,
    required this.tone,
    required this.mode,
    required this.hasWhole,
    required this.first,
    required this.minHeight,
  });

  final GaiaStratum stratum;
  final GaiaStratumLayout layout;
  final int tone;
  final GaiaStrataMode mode;
  final bool hasWhole;
  final bool first;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    // Two different questions, and conflating them is a bug: `drawsValue` is
    // "does this band's SIZE come from its number", `share` is "is there a
    // whole for a percentage to be a share OF". An all-zero window is the
    // first without the second — the zeros are real measurements and must
    // still be named, even though no percentage means anything.
    final drawsValue = mode == GaiaStrataMode.share;
    final share = drawsValue && hasWhole;
    // `.stratum{padding:14px 16px 12px}`.
    const pad = EdgeInsets.fromLTRB(16, 14, 16, 12);
    // Indent is the RANK channel and only exists in rank mode — see
    // GaiaStrataList.tones for why a share strata stays flush.
    final indent = mode == GaiaStrataMode.rank ? GaiaStrataColors.indent(tone) : 0.0;

    final valueColor = layout.isNegative
        ? GaiaStrataColors.tagCoral
        : layout.isZero
            ? GaiaColors.text2
            : GaiaColors.text;

    // Height is only forced in share mode. In rank mode the content decides,
    // which is the mockup's own behaviour and the only honest option when no
    // proportion is being claimed.
    final forced = mode == GaiaStrataMode.share ? layout.height : null;
    // A floored band is at the minimum and cannot hold a caption; only a band
    // with room for the figure AND two wrapped lines under it gets one. The
    // margin is generous on purpose — the caption is bottom-anchored below, and
    // a Column that overflows its band would paint stripes across a revenue
    // figure.
    final showCaption =
        stratum.caption != null && (forced == null || forced >= minHeight + 60);

    // A tall band brackets its height: the figure at the top edge, the caption
    // at the bottom one. Letting both sit at the top leaves a share-mode band
    // that is 70% of the strata looking like an empty box with a line of type
    // in the corner — the thickness is the point, and the content has to make
    // it look deliberate rather than unfinished.
    final bracket = forced != null && showCaption;

    Widget content = Padding(
      padding: pad,
      child: Column(
        mainAxisSize: bracket ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    Text(
                      stratum.label.toUpperCase(),
                      style: GaiaType.eyebrow(color: GaiaColors.text2),
                    ),
                    if (stratum.tagLabel != null)
                      _Tag(label: stratum.tagLabel!, color: stratum.tagColor),
                    // The two conditions the GEOMETRY cannot draw get a word —
                    // but only where geometry is making a claim at all. In
                    // rank mode nothing is drawn from the value, so tagging a
                    // band "ZERO" would be reporting a measurement the strata
                    // never took: a KPI whose value is null arrives here as 0
                    // and would have worn "NO DATA · ZERO" side by side, which
                    // is two different statements about the same missing
                    // number.
                    if (drawsValue && layout.isNegative)
                      const _Tag(label: 'Below zero', color: GaiaStrataColors.tagCoral),
                    if (drawsValue && layout.isZero) const _Tag(label: 'Zero'),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // The exact figure, always. The band's thickness is the fast
              // read; this is the one that has to be right.
              if (stratum.unit == null)
                Text(
                  stratum.display,
                  textAlign: TextAlign.right,
                  style: GaiaType.serif(size: 24, weight: 500, color: valueColor),
                )
              else
                RichText(
                  textAlign: TextAlign.right,
                  text: TextSpan(
                    text: stratum.display,
                    style: GaiaType.serif(size: 24, weight: 500, color: valueColor),
                    children: [
                      TextSpan(
                        text: ' ${stratum.unit}',
                        style: GaiaType.unit(color: GaiaColors.text2),
                      ),
                    ],
                  ),
                ),
              if (share) ...[
                const SizedBox(width: 12),
                // Stated on EVERY band, not just the floored ones: a reader who
                // cannot judge two similar thicknesses by eye should never have
                // to.
                SizedBox(
                  // Wide enough for a signed share — "-100.0%" is seven glyphs
                  // and a refund can genuinely exceed the positive total.
                  width: 54,
                  child: Text(
                    _pct(layout.share),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: GaiaType.unit(
                      color: layout.isNegative
                          ? GaiaStrataColors.tagCoral
                          : GaiaColors.text2,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (showCaption) ...[
            if (bracket) const Spacer() else const SizedBox(height: 4),
            Text(
              stratum.caption!,
              // text2, never text3: on the lightest band ground text3 measures
              // 3.12:1 and this sentence is the only thing that says it.
              style: GaiaType.detail(color: GaiaColors.text2),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );

    if (forced != null) {
      // A bracketed band is a bounded Column with a Spacer, so it fills its
      // height exactly and cannot overflow. A short one is wrapped in an
      // OverflowBox instead: its height comes from arithmetic and its content
      // from the viewer's font, and those two can disagree at an extreme text
      // scale. Clipping from the TOP DOWN keeps the figure — the first line —
      // which is the right way round; a plain Column in a SizedBox would
      // instead raise a layout overflow and paint stripes over the number.
      content = SizedBox(
        height: forced,
        child: ClipRect(
          child: bracket
              ? content
              : OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: content,
                ),
        ),
      );
    }

    // A floored band's top edge is DASHED, not solid. That one difference is
    // what tells a reader "this thickness is a minimum, not a measurement"
    // without making them find the sentence at the bottom of the strata — and
    // it survives greyscale, which the percentage's ink does not have to.
    final dashedTop = layout.floored && !first;

    Widget band = Container(
      margin: EdgeInsets.only(left: indent),
      foregroundDecoration: dashedTop
          ? _DashedTopEdge(color: GaiaColors.line2)
          : null,
      decoration: BoxDecoration(
        color: GaiaStrataColors.band(tone),
        border: Border(
          // `.stratum{border-top:1px solid var(--line)}`.
          top: first || dashedTop
              ? BorderSide.none
              : BorderSide(color: GaiaColors.line),
          // A refund is marked on its edge as well as in its ink and its word.
          left: layout.isNegative
              ? const BorderSide(
                  color: GaiaStrataColors.tagCoral,
                  width: GaiaRadius.railStroke,
                )
              : BorderSide.none,
        ),
      ),
      child: content,
    );

    if (stratum.onTap == null) return band;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: stratum.onTap,
        child: band,
      ),
    );
  }

  static String _pct(double share) {
    final v = share * 100;
    if (v == 0) return '0%';
    if (v.abs() < 0.1) return '<0.1%';
    return '${v.toStringAsFixed(1)}%';
  }
}

/// The dashed hairline a floored band wears instead of a solid top edge.
///
/// A [Decoration] rather than a CustomPaint so it can ride the same Container
/// as the band's fill and rail — one render object, no extra layer per band in
/// a list that can run to three dozen rows.
@immutable
class _DashedTopEdge extends Decoration {
  const _DashedTopEdge({required this.color});

  final Color color;

  /// The mockup's own dash rhythm — `stroke-dasharray="2 4"` on the chart's
  /// reference line, opened up a touch so a 1px edge still reads as broken at
  /// a normal viewing distance.
  static const double dash = 3;
  static const double gap = 3;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedTopPainter(this);
}

class _DashedTopPainter extends BoxPainter {
  _DashedTopPainter(this.spec);
  final _DashedTopEdge spec;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final width = cfg.size?.width ?? 0;
    final paint = Paint()
      ..color = spec.color
      ..strokeWidth = GaiaRadius.hairline;
    final y = offset.dy + 0.5;
    for (var x = 0.0; x < width; x += _DashedTopEdge.dash + _DashedTopEdge.gap) {
      canvas.drawLine(
        Offset(offset.dx + x, y),
        Offset(offset.dx + math.min(x + _DashedTopEdge.dash, width), y),
        paint,
      );
    }
  }
}

/// `.stratum .tag` — a hairline box in its own status ink.
class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? GaiaColors.text2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(border: Border.all(color: c)),
      child: Text(label.toUpperCase(), style: GaiaType.pill(color: c)),
    );
  }
}

/// `.strata-chart` — the stacked area, with `.strata-key` and `.axis` under it.
class GaiaStrataChart extends StatelessWidget {
  const GaiaStrataChart({
    super.key,
    required this.series,
    required this.format,
    this.axisLabels = const [],
    this.height = 150,
    this.showKey = true,
    this.emptyMessage = 'Nothing recorded in this window.',
  });

  /// Stacked bottom-first, exactly as the key lists them.
  final List<GaiaStrataSeries> series;

  /// How a value is written — money, covers, minutes. Used for the reference
  /// line and the key.
  final String Function(double) format;

  /// `.axis` — the first and last labels under the chart. Anything longer than
  /// two is trimmed to its ends, which is what the mockup shows.
  final List<String> axisLabels;

  final double height;
  final bool showKey;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final layout = GaiaStrataStack.resolve(series);

    if (layout.isEmpty) {
      // Every reading is zero. A flat band at the baseline would look like a
      // measured floor; saying so is the honest render.
      return Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: GaiaColors.line),
        ),
        child: Text(emptyMessage, style: GaiaType.detail(color: GaiaColors.text2)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _StrataPainter(layout: layout, format: format),
            size: Size.infinite,
          ),
        ),
        if (axisLabels.length >= 2) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(axisLabels.first.toUpperCase(),
                  style: GaiaType.eyebrow(color: GaiaColors.text2)),
              Text(axisLabels.last.toUpperCase(),
                  style: GaiaType.eyebrow(color: GaiaColors.text2)),
            ],
          ),
        ],
        if (showKey) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (var i = 0; i < series.length; i++)
                _KeyEntry(
                  index: i,
                  label: series[i].label,
                  color: GaiaStrataColors.rampAt(i),
                  share: layout.shareOf(i),
                  total: format(layout.seriesPositiveTotals[i]),
                  hasWhole: layout.grandPositive > 0,
                ),
            ],
          ),
        ],
        if (layout.hasNegative) ...[
          const SizedBox(height: 10),
          Text(
            'Readings below zero are drawn under the marked baseline at their'
            ' own magnitude, and are left out of the shares above.',
            style: GaiaType.detail(color: GaiaColors.text2),
          ),
        ],
      ],
    );
  }
}

/// `.strata-key span` — swatch plus label, with a stacking numeral in front so
/// the key can be matched to a band by COUNTING rather than by hue.
class _KeyEntry extends StatelessWidget {
  const _KeyEntry({
    required this.index,
    required this.label,
    required this.color,
    required this.share,
    required this.total,
    required this.hasWhole,
  });

  final int index;
  final String label;
  final Color color;
  final double share;
  final String total;
  final bool hasWhole;

  @override
  Widget build(BuildContext context) {
    final pct = hasWhole ? '${(share * 100).toStringAsFixed(0)}%' : 'no share';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${(index + 1).toString().padLeft(2, '0')} ',
            style: GaiaType.pill(color: GaiaColors.text2)),
        // `.strata-key span::before{width:14px;height:6px}`.
        Container(width: 14, height: 6, color: color),
        const SizedBox(width: 7),
        Text(
          '${label.toUpperCase()} · $pct · $total',
          style: GaiaType.pill(color: GaiaColors.text2),
        ),
      ],
    );
  }
}

class _StrataPainter extends CustomPainter {
  _StrataPainter({required this.layout, required this.format});

  final GaiaStrataStackLayout layout;
  final String Function(double) format;

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.isEmpty) return;
    final n = layout.length;
    double xAt(int i) => n == 1 ? size.width / 2 : i / (n - 1) * size.width;
    double yAt(double v) => layout.y(v, size.height);

    for (var s = 0; s < layout.spans.length; s++) {
      final spans = layout.spans[s];
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = GaiaStrataColors.rampAt(s);

      if (n == 1) {
        // A single reading has no area to sweep, so it is drawn as a column
        // rather than as nothing.
        final w = math.min(size.width, 48.0);
        final left = (size.width - w) / 2;
        canvas.drawRect(
          Rect.fromLTRB(left, yAt(spans[0].to), left + w, yAt(spans[0].from)),
          fill,
        );
        continue;
      }

      final path = Path()..moveTo(xAt(0), yAt(spans[0].to));
      for (var i = 1; i < n; i++) {
        path.lineTo(xAt(i), yAt(spans[i].to));
      }
      for (var i = n - 1; i >= 0; i--) {
        path.lineTo(xAt(i), yAt(spans[i].from));
      }
      path.close();
      canvas.drawPath(path, fill);

      // The adjacent-fill fix: a 1px ground-coloured seam along each band's
      // top edge, so two ramp stops only ~2.2:1 apart still read as two bands.
      final seam = Path()..moveTo(xAt(0), yAt(spans[0].to));
      for (var i = 1; i < n; i++) {
        seam.lineTo(xAt(i), yAt(spans[i].to));
      }
      canvas.drawPath(
        seam,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = GaiaRadius.hairline
          ..color = GaiaColors.bg,
      );
    }

    // The zero baseline, drawn only when something crosses it — an always-on
    // baseline on an all-positive chart is just another gridline.
    if (layout.hasNegative) {
      final y = yAt(0);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..strokeWidth = GaiaRadius.hairline
          ..color = GaiaColors.text2,
      );
      _label(canvas, '0', Offset(0, y - 14), GaiaColors.text2, left: true);
    }

    // `<line stroke-dasharray="2 4">` at the peak, with the scale spelled out.
    final peakY = yAt(layout.maxTop);
    _dashed(canvas, peakY, size.width);
    _label(
      canvas,
      format(layout.maxTop),
      Offset(size.width, peakY - 14),
      // The spec puts this in --text-3 (4.20:1 on the forest ground). It is
      // the ONLY statement of the chart's scale, so it goes one step up.
      GaiaColors.text2,
    );
  }

  void _dashed(Canvas canvas, double y, double width) {
    final paint = Paint()
      ..strokeWidth = GaiaRadius.hairline
      ..color = GaiaColors.line2;
    for (var x = 0.0; x < width; x += 6) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 2, width), y), paint);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color,
      {bool left = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: GaiaType.sans(size: 10, color: color, letterSpacing: 1.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(left ? at.dx : at.dx - tp.width, at.dy));
  }

  @override
  bool shouldRepaint(_StrataPainter old) =>
      old.layout != layout || old.format != format;
}
