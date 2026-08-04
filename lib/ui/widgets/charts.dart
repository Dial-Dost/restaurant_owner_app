import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// ── Design notes ─────────────────────────────────────────────────────
/// Every chart in the system is single-hue sequential copper on a dark
/// surface: taller/greater = lighter copper, baseline-anchored marks with
/// 1.5px rounded data-ends, 2px gaps, no gridlines louder than 5% white.
/// Identity is carried by position + labels, never by extra hues.

/// How many bars the barcode painter will draw across [width]. Hit-testing has
/// to call this too: derive the count any other way and the hover card names a
/// different day than the bar sitting under the pointer.
int _barcodeCount(double width, double slot, double gap) =>
    math.max(1, ((width + gap) / slot).floor());

/// The point in the source series a resampled bar was drawn from — the inverse
/// of the painter's `srcPos`, rounded to the nearest real reading so a drill-in
/// lands on a day that exists rather than on an interpolated fiction.
int _barcodeSource(int bar, int count, int length) {
  if (length <= 1) return 0;
  final t = count == 1 ? 0.0 : bar / (count - 1);
  return (t * (length - 1)).round().clamp(0, length - 1);
}

/// Dense "barcode" strip — dozens of thin vertical bars, the most
/// recognizable chart in the reference design.
class CopperBarcode extends StatefulWidget {
  const CopperBarcode({
    super.key,
    required this.values,
    this.height = 46,
    this.barWidth = 2.6,
    this.gap = 2.4,
    this.dimmed = false,
    this.onTap,
    this.tooltipBuilder,
  });

  final List<double> values;
  final double height;
  final double barWidth;
  final double gap;

  /// Muted variant for secondary cards.
  final bool dimmed;

  /// Drill into the reading under the pointer. The index is into [values], not
  /// into the resampled bars, so callers never have to know how many bars fit.
  /// Null leaves the strip inert (and unhoverable).
  final ValueChanged<int>? onTap;

  /// What the hover card says, indexed the same way as [onTap]. Without it and
  /// without [onTap] there is nothing to say and nowhere to go, so the strip
  /// stays a plain visual.
  final String Function(int index)? tooltipBuilder;

  @override
  State<CopperBarcode> createState() => _CopperBarcodeState();
}

class _CopperBarcodeState extends State<CopperBarcode> {
  /// Resampled bar index, because that is what the painter highlights.
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final live = widget.onTap != null || widget.tooltipBuilder != null;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chart = CustomPaint(
            painter: _BarcodePainter(
                widget.values, widget.barWidth, widget.gap, widget.dimmed, _hover),
          );
          // Under an unbounded width the painter's bar count is unknowable here,
          // so there is nothing honest to hit-test against.
          if (!live ||
              widget.values.isEmpty ||
              !constraints.maxWidth.isFinite ||
              constraints.maxWidth <= 0) {
            return chart;
          }
          final slot = widget.barWidth + widget.gap;
          final count = _barcodeCount(constraints.maxWidth, slot, widget.gap);
          return Stack(
            children: [
              Positioned.fill(child: chart),
              for (var i = 0; i < count; i++)
                if (constraints.maxWidth - i * slot > 0)
                  Positioned(
                    left: i * slot,
                    top: 0,
                    bottom: 0,
                    // The last slot can run past the edge; clamp it so the hit
                    // area matches what is actually on screen.
                    width: math.min(slot, constraints.maxWidth - i * slot),
                    child: _ChartHitBox(
                      onTap: widget.onTap == null
                          ? null
                          : () => widget.onTap!(
                              _barcodeSource(i, count, widget.values.length)),
                      tooltip: widget.tooltipBuilder
                          ?.call(_barcodeSource(i, count, widget.values.length)),
                      onHover: (h) => setState(
                          () => _hover = h ? i : (_hover == i ? null : _hover)),
                      child: const SizedBox.expand(),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  _BarcodePainter(
      this.values, this.barWidth, this.gap, this.dimmed, this.hoveredBar);

  final List<double> values;
  final double barWidth;
  final double gap;
  final bool dimmed;

  /// Resampled bar index under the pointer, or null when nothing is hovered.
  final int? hoveredBar;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce(math.max);
    if (maxV <= 0) return;

    final slot = barWidth + gap;
    final count = _barcodeCount(size.width, slot, gap);
    // Resample values to the available bar count.
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.0 : i / (count - 1);
      final srcPos = t * (values.length - 1);
      final lo = srcPos.floor();
      final hi = math.min(lo + 1, values.length - 1);
      final v = values[lo] + (values[hi] - values[lo]) * (srcPos - lo);

      final frac = (v / maxV).clamp(0.06, 1.0);
      final h = frac * size.height;
      // Taller bars read lighter — sequential light -> dark by magnitude.
      final color = Color.lerp(
        AppColors.copperShadow,
        AppColors.copperHi,
        math.pow(frac, 1.3).toDouble(),
      )!;
      final hot = i == hoveredBar;
      paint.color =
          hot ? AppColors.copperHi : (dimmed ? color.withValues(alpha: 0.45) : color);

      final x = i * slot;
      if (hot) {
        // A 2.6px bar cannot carry a hover state on colour alone, so the whole
        // slot lights up behind it — a luminance change, not a second hue.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - gap / 2, 0, slot, size.height),
            const Radius.circular(2),
          ),
          Paint()..color = Colors.white.withValues(alpha: 0.07),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barWidth, h),
          const Radius.circular(1.4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) =>
      old.values != values ||
      old.dimmed != dimmed ||
      old.hoveredBar != hoveredBar;
}

/// Seven (or n) bars with single-letter labels underneath —
/// the "S M T W T F S" weekday chart from the stat cards.
class WeekdayBars extends StatefulWidget {
  const WeekdayBars({
    super.key,
    required this.values,
    this.labels = const ['S', 'M', 'T', 'W', 'T', 'F', 'S'],
    this.highlight,
    this.height = 56,
    this.onTap,
    this.tooltipBuilder,
  });

  final List<double> values;
  final List<String> labels;

  /// Index rendered in bright copper (e.g. today).
  final int? highlight;
  final double height;

  /// Drill into one bar. Null leaves the chart inert (and unhoverable), so a
  /// chart that leads nowhere never pretends to be a control.
  final ValueChanged<int>? onTap;

  /// What the hover card says for a bar. Without it there is nothing worth
  /// showing on hover, so no tooltip is attached.
  final String Function(int index)? tooltipBuilder;

  @override
  State<WeekdayBars> createState() => _WeekdayBarsState();
}

class _WeekdayBarsState extends State<WeekdayBars> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    // A bar chart where every value is 0 has no meaningful scale. Dividing by
    // that max yields NaN, and a NaN height is a hard layout error rather than
    // an ugly chart -- so the empty day has to be handled, not assumed away.
    final rawMax = widget.values.isEmpty ? 0.0 : widget.values.reduce(math.max);
    final maxV = rawMax > 0 ? rawMax : 1.0;
    return SizedBox(
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < widget.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: _ChartHitBox(
                onTap: widget.onTap == null ? null : () => widget.onTap!(i),
                tooltip: widget.tooltipBuilder?.call(i),
                onHover: (h) => setState(() => _hover = h ? i : (_hover == i ? null : _hover)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: 0,
                        end: (widget.values[i] / maxV).clamp(0.05, 1.0),
                      ),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, _) => AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        // Hover lifts the bar a little as well as brightening it:
                        // colour alone would not register for a colour-blind user.
                        // The 4px lift is taken out of the bar's own budget, not
                        // added to it — the 6px gap and the label line spend the
                        // rest of the fixed box, so an unreserved lift overflowed
                        // and clipped the weekday letter.
                        height: t * (widget.height - 22) + (_hover == i ? 4 : 0),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2.5)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: _hover == i || i == widget.highlight
                                ? [AppColors.copperHi, AppColors.copperMid]
                                : [
                                    AppColors.copperDeep,
                                    AppColors.copperShadow
                                        .withValues(alpha: 0.8),
                                  ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      i < widget.labels.length ? widget.labels[i] : '',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: _hover == i || i == widget.highlight
                            ? AppColors.copperHi
                            : AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared hover/tap wrapper for every mark in this file. Keeping it in one
/// place is what stops the charts drifting apart: a bar, a column and a row all
/// answer the pointer the same way, and a mark with no [onTap] stays a plain
/// visual so the cursor never promises a drill-down that does not exist.
class _ChartHitBox extends StatelessWidget {
  const _ChartHitBox({
    required this.child,
    this.onTap,
    this.tooltip,
    this.onHover,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    // With nothing to tap and nothing to say, the mark is a plain visual: no
    // hover callback, so no lift or brightening, and no opaque hit box eating
    // pointers on behalf of a control that does not exist.
    if (onTap == null && (tooltip == null || tooltip!.isEmpty)) return child;
    Widget out = MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => onHover?.call(true),
      onExit: (_) => onHover?.call(false),
      child: GestureDetector(
        onTap: onTap,
        // Opaque so the whole slot answers the pointer, not just the pixels the
        // mark happens to cover — a short bar is still easy to hit.
        behavior: HitTestBehavior.opaque,
        child: child,
      ),
    );
    if (tooltip != null && tooltip!.isNotEmpty) {
      out = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 250),
        child: out,
      );
    }
    return out;
  }
}

/// Thin ring gauge with the value in the center — the small circular
/// meters on the reference venue cards.
class DonutGauge extends StatefulWidget {
  const DonutGauge({
    super.key,
    required this.fraction,
    this.size = 52,
    this.stroke = 4,
    this.color,
    this.center,
    this.label,
    this.onTap,
    this.tooltip,
  });

  final double fraction;
  final double size;
  final double stroke;
  final Color? color;

  /// Center content; defaults to the percentage.
  final Widget? center;

  /// Optional micro label under the gauge.
  final String? label;

  /// Drill in from the gauge. One figure means one target, so there is no
  /// per-mark index to report. Null keeps the gauge a plain readout.
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<DonutGauge> createState() => _DonutGaugeState();
}

class _DonutGaugeState extends State<DonutGauge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ring = widget.color ?? AppColors.copperHi;
    final gauge = SizedBox(
      width: widget.size,
      height: widget.size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: widget.fraction.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _DonutPainter(
            t,
            widget.stroke,
            _hover ? Color.lerp(ring, Colors.white, 0.28)! : ring,
            _hover,
          ),
          child: Center(
            child: widget.center ??
                Text(
                  '${(widget.fraction * 100).round()}%',
                  style: TextStyle(
                    fontSize: widget.size * 0.24,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                    color: AppColors.textPrimary,
                  ),
                ),
          ),
        ),
      ),
    );
    Widget content = gauge;
    if (widget.label != null) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          gauge,
          const SizedBox(height: 6),
          Text(
            widget.label!.toUpperCase(),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      );
    }
    // An inert gauge keeps exactly the tree it had before interaction existed:
    // no hit box, no transform, nothing to change how it looks or hit-tests.
    final live = widget.onTap != null ||
        (widget.tooltip != null && widget.tooltip!.isNotEmpty);
    if (!live) return content;
    return _ChartHitBox(
      onTap: widget.onTap,
      tooltip: widget.tooltip,
      onHover: (h) => setState(() => _hover = h),
      // Scale rather than a real size change: these gauges sit in fixed-height
      // stat cards, where growing by 6% would shove the card's text around.
      child: AnimatedScale(
        scale: _hover ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: content,
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.fraction, this.stroke, this.color, [this.hovered = false]);

  final double fraction;
  final double stroke;
  final Color color;
  final bool hovered;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inner = rect.deflate(stroke / 2);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: hovered ? 0.14 : 0.07);
    canvas.drawArc(inner, 0, math.pi * 2, false, track);

    if (fraction <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: [Color.lerp(color, AppColors.copperDeep, 0.55)!, color],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(inner, -math.pi / 2, math.pi * 2 * fraction, false, arc);
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.fraction != fraction || old.color != color || old.hovered != hovered;
}

/// 2px copper line with a soft fade fill — compact trend spark.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.height = 40,
    this.color,
  });

  final List<double> values;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(values, color ?? AppColors.copperHi),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = (maxV - minV) == 0 ? 1.0 : maxV - minV;

    final pts = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height -
          ((values[i] - minV) / span) * (size.height * 0.82) -
          size.height * 0.06;
      pts.add(Offset(x, y));
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final prev = pts[i - 1];
      final cur = pts[i];
      final midX = (prev.dx + cur.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, cur.dy, cur.dx, cur.dy);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    // End dot with a 2px surface ring so it separates from the line.
    canvas.drawCircle(
      pts.last,
      4.5,
      Paint()..color = AppColors.card,
    );
    canvas.drawCircle(pts.last, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}

/// Labeled horizontal magnitude bar — "Butter Chicken ───────── 214".
/// Used for best-sellers, category share, kitchen load, stock levels.
class HBarRow extends StatelessWidget {
  const HBarRow({
    super.key,
    required this.label,
    required this.fraction,
    required this.value,
    this.color,
    this.sub,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final double fraction;
  final String value;
  final Color? color;
  final String? sub;

  /// Drill into this row. Null keeps it a plain readout.
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = color ?? AppColors.copper;
    return _ChartHitBox(
      onTap: onTap,
      tooltip: tooltip,
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: text.bodyMedium!.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sub != null) ...[
                Text(sub!, style: text.bodySmall!.copyWith(fontSize: 11)),
                const SizedBox(width: 8),
              ],
              Text(
                value,
                style: text.bodyMedium!.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: Stack(
                children: [
                  Container(color: Colors.white.withValues(alpha: 0.05)),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, _) => FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: t,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color.lerp(c, AppColors.copperShadow, 0.45)!,
                              c,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// Vertical bar chart with value + axis labels — used by Reports for
/// monthly revenue and peak hours. Marks stay copper; the peak bar is
/// lighter (sequential by magnitude).
class CopperColumns extends StatefulWidget {
  const CopperColumns({
    super.key,
    required this.values,
    required this.labels,
    this.height = 140,
    this.valueFormatter,
    this.onTap,
    this.tooltipBuilder,
  });

  final List<double> values;
  final List<String> labels;
  final double height;
  final String Function(double)? valueFormatter;

  /// Drill into one column (e.g. open that month's breakdown).
  final ValueChanged<int>? onTap;
  final String Function(int index)? tooltipBuilder;

  @override
  State<CopperColumns> createState() => _CopperColumnsState();
}

class _CopperColumnsState extends State<CopperColumns> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    // Same NaN guard as WeekdayBars: an all-zero series would otherwise divide
    // by zero and hand Flutter a NaN height, which is a layout crash.
    final rawMax = widget.values.isEmpty ? 0.0 : widget.values.reduce(math.max);
    final maxV = rawMax > 0 ? rawMax : 1.0;
    final peak = rawMax > 0 ? widget.values.indexOf(rawMax) : -1;
    return SizedBox(
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < widget.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _ChartHitBox(
                onTap: widget.onTap == null ? null : () => widget.onTap!(i),
                tooltip: widget.tooltipBuilder?.call(i),
                onHover: (h) => setState(
                    () => _hover = h ? i : (_hover == i ? null : _hover)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // The peak column always shows its value; hovering any other
                    // column reveals its own, so a reading is one pointer away
                    // instead of hidden behind a drill-down.
                    if ((i == peak || _hover == i) && widget.valueFormatter != null) ...[
                      Text(
                        widget.valueFormatter!(widget.values[i]),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: _hover == i
                              ? AppColors.textPrimary
                              : AppColors.copperHi,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 5),
                    ],
                    TweenAnimationBuilder<double>(
                      tween: Tween(
                          begin: 0,
                          end: (widget.values[i] / maxV).clamp(0.04, 1.0)),
                      duration: Duration(milliseconds: 400 + i * 40),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, _) => AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        height: t * (widget.height - 40) + (_hover == i ? 5 : 0),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: i == peak || _hover == i
                                ? [AppColors.copperHi, AppColors.copperMid]
                                : [
                                    Color.lerp(
                                        AppColors.copperDeep,
                                        AppColors.copperHi,
                                        widget.values[i] / maxV * 0.4)!,
                                    AppColors.copperShadow,
                                  ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      i < widget.labels.length ? widget.labels[i] : '',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        color: _hover == i
                            ? AppColors.copperHi
                            : AppColors.textTertiary,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
