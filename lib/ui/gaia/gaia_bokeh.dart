// GAIA signature style: BOKEH.
//
// The mockup allocates this to Customers and Feedback — the two screens that
// are about PEOPLE rather than operations, and the only two where nothing is
// urgent. From the mockup CSS:
//
// ```
// .bokeh   {position:absolute;inset:0;pointer-events:none;overflow:hidden}
// .bokeh i {position:absolute;border-radius:50%;filter:blur(34px);opacity:.55}
// .bokeh .a{background:#d3b88b} .b{background:#3d6a55}
// .bokeh .c{background:#8a6b3d} .d{background:#2e5a48}
//
// .bk-avatar{width:56px;height:56px;border-radius:50%;
//   background:radial-gradient(circle at 40% 35%,#e2cfa6,#a08c67 55%,#5c4d33);
//   box-shadow:0 0 0 6px rgba(211,184,139,.08), 0 0 0 14px rgba(211,184,139,.04)}
// .bk-avatar.cool{background:radial-gradient(...#9bc4a0,#3d6a55 55%,#1e3a2d)}
// .bk-avatar.dim {background:radial-gradient(...#3f4a44,#1f2a26 60%,#14201c);box-shadow:none}
//
// .ring{132px;border-radius:50%;background:conic-gradient(var(--champagne) 0 91%,var(--line) 91% 100%)}
// .ring::before{inset:6px;border-radius:50%;background:var(--bg)}
// ```
//
// and, in the mockup's own words on the Customers screen:
//
//   "Brightness follows spend and recency: a guest who dined this month glows,
//    a name that only ever booked stays dim."
//
// That sentence is the whole style. The blurred field behind the page is the
// out-of-focus background; the guests are the points of light in front of it,
// and how brightly a guest burns is DATA, not decoration.
//
// ## The one rule that keeps it honest
//
// Brightness is never the only carrier. Every row that has a glowing avatar
// also states, in words, the spend and the last visit that made it glow — so
// the style is a second reading of a value the row already prints, exactly the
// way the Rustic system's StatusChip always ships its label. A screen reader,
// a colour-blind owner and a bad projector all still get the number.
//
// ## The motion budget
//
// The blurred field is the expensive-looking part and is very nearly free:
//
//  * It is one [CustomPaint] with `shouldRepaint => false`, under a
//    [RepaintBoundary]. The four blurred circles rasterise ONCE for the life of
//    the screen. `MaskFilter.blur` at the paint, not `BackdropFilter` — a
//    backdrop filter re-reads and re-blurs the framebuffer every frame and on a
//    cheap till that alone can cost the frame.
//  * The parallax is a translation applied ABOVE that boundary, so a scroll
//    frame moves a cached layer. Nothing re-blurs, nothing repaints, and the
//    subtree under it is never rebuilt (the painter is passed as `child:`).
//  * Avatars are plain gradients and solid-spread shadows — no blur, no layer.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

// ─────────────────────────────────────────────────────────────────────
// The field
// ─────────────────────────────────────────────────────────────────────

/// One out-of-focus light. Positions are expressed as a FRACTION of the
/// viewport width and an absolute offset down the page, because the mockup's
/// pixel coordinates were measured in a 430px phone and a 1600px till window
/// would otherwise pile every blob into the left quarter.
@immutable
class GaiaBokehBlob {
  const GaiaBokehBlob({
    required this.fx,
    required this.dy,
    required this.diameter,
    required this.color,
    this.opacity = 0.55,
  });

  /// Centre x as a fraction of the width. May sit outside 0..1 — the mockup's
  /// `left:-80px` blobs bleed off the edge and that is most of the effect.
  final double fx;

  /// Centre y in logical pixels from the top of the scroll content.
  final double dy;

  final double diameter;
  final Color color;
  final double opacity;

  // The four mockup fills.
  static const Color champagne = Color(0xFFD3B88B); // .a
  static const Color forest = Color(0xFF3D6A55); // .b
  static const Color bronze = Color(0xFF8A6B3D); // .c
  static const Color pine = Color(0xFF2E5A48); // .d

  /// Screen 08 Customers, converted from the mockup's own pixel positions in a
  /// 430px frame (`left + width/2`, `top + height/2`).
  static const List<GaiaBokehBlob> customers = [
    GaiaBokehBlob(fx: 0.837, dy: 150, diameter: 220, color: champagne),
    GaiaBokehBlob(fx: 0.116, dy: 310, diameter: 260, color: forest),
    GaiaBokehBlob(fx: 0.465, dy: 500, diameter: 160, color: bronze),
    GaiaBokehBlob(fx: 0.907, dy: 750, diameter: 220, color: pine),
  ];

  /// Screen 09 Feedback — a sparser, cooler field; the mockup dims two of the
  /// three (`opacity:.5` and `.4`) so the ring gauge stays the brightest thing.
  static const List<GaiaBokehBlob> feedback = [
    GaiaBokehBlob(fx: 0.744, dy: 240, diameter: 240, color: champagne, opacity: 0.5),
    GaiaBokehBlob(fx: 0.093, dy: 460, diameter: 280, color: pine),
    GaiaBokehBlob(fx: 0.744, dy: 790, diameter: 180, color: bronze, opacity: 0.4),
  ];
}

/// The blurred field that sits behind a bokeh screen's content.
///
/// Mount it as the FIRST child of a Stack, with the scrolling content over it.
/// It never takes a pointer (`pointer-events:none` in the mockup, an
/// [IgnorePointer] here), so every tap still reaches the list.
class GaiaBokehBackdrop extends StatelessWidget {
  const GaiaBokehBackdrop({
    super.key,
    required this.blobs,
    this.scroll,
    this.parallax = 0.28,
  });

  final List<GaiaBokehBlob> blobs;

  /// The list's controller. Given one, the field drifts against the content as
  /// you scroll — which is the entire motion of this style, and costs one
  /// layer offset per frame.
  final ScrollController? scroll;

  /// How far the field moves per pixel of scroll. Below 1 it lags the content,
  /// which is what reads as depth.
  final double parallax;

  @override
  Widget build(BuildContext context) {
    final field = RepaintBoundary(
      child: CustomPaint(
        painter: _BokehPainter(blobs),
        size: Size.infinite,
      ),
    );

    final c = scroll;
    if (c == null) return IgnorePointer(child: field);

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: c,
        // `child` is the whole cost story: the painter subtree is constructed
        // once and handed through, so a scroll frame builds a Transform and
        // nothing else.
        child: field,
        builder: (context, child) {
          final px = c.hasClients ? c.position.pixels : 0.0;
          return Transform.translate(
            offset: Offset(0, -px * parallax),
            child: child,
          );
        },
      ),
    );
  }
}

/// The strongest a blob may be painted before the ink on top of it stops
/// clearing WCAG AA.
///
/// ## Why the mockup's own numbers could not be used unchanged
///
/// `.bokeh i{opacity:.55}` is a fine number for the mockup, whose bokeh screens
/// carry a title, a caption and five list rows with acres of empty ground
/// between them. The real guest book has sixteen guests, a search field, five
/// segment pills and three leaderboards, so the field lands UNDER dense 13px
/// secondary type. Measured on the forest ground, a champagne blob at .55
/// composites to #796F55, and on that:
///
/// ```
///   text  #ede6d6   4.00 : 1     <- the PRIMARY ink, below AA
///   text2 #b3ac99   2.20 : 1     <- unreadable
/// ```
///
/// That is not a design decision anyone made; it is what happens when a
/// decorative layer meets a screen with real content on it. So each blob keeps
/// the mockup's opacity up to the point where [GaiaColors.text2] — the faintest
/// ink that carries meaning on these two screens — still clears 4.5:1, and is
/// clamped past it.
///
/// In practice the clamp bites on exactly one of the four fills:
///
/// ```
///   champagne #d3b88b   .55 -> .275
///   bronze    #8a6b3d   .55 -> .500
///   forest    #3d6a55   .55 -> .550   (its own ceiling is .591)
///   pine      #2e5a48   .55 -> .550   (its own ceiling is .736)
/// ```
///
/// The greens — which are most of the field, and all of its depth — are
/// untouched. Only the golds come back, and only as far as they have to.
double gaiaReadableAlpha(
  Color blob, {
  Color ground = const Color(0xFF0C1513),
  Color ink = GaiaColors.text2,
  // 4.55, not 4.50. The solver works in floating point and the framebuffer is
  // 8 bits per channel, so a cap solved exactly at 4.50 lands at 4.487 once the
  // composite is quantised. The extra twentieth is the rounding margin; it
  // costs about three thousandths of alpha.
  double ratio = 4.55,
}) {
  double lin(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double lum(double r, double g, double b) =>
      0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);

  final li = lum(ink.r, ink.g, ink.b);
  bool ok(double a) {
    final r = a * blob.r + (1 - a) * ground.r;
    final g = a * blob.g + (1 - a) * ground.g;
    final b = a * blob.b + (1 - a) * ground.b;
    final lg = lum(r, g, b);
    final hi = li > lg ? li : lg;
    final lo = li > lg ? lg : li;
    return (hi + 0.05) / (lo + 0.05) >= ratio;
  }

  if (ok(1)) return 1;
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (ok(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

class _BokehPainter extends CustomPainter {
  _BokehPainter(this.blobs)
      : _alpha = [
          for (final b in blobs)
            math.min(b.opacity, gaiaReadableAlpha(b.color)),
        ];

  final List<GaiaBokehBlob> blobs;

  /// Each blob's painted alpha — its own, capped at the point where the ink on
  /// top stops clearing AA. Computed once, in the constructor, because it is a
  /// property of the palette and must never cost anything per frame.
  final List<double> _alpha;

  /// CSS `filter: blur(34px)` is a Gaussian of standard deviation 34/2.
  static const double _sigma = 17;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < blobs.length; i++) {
      final b = blobs[i];
      final paint = Paint()
        ..color = b.color.withValues(alpha: _alpha[i])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _sigma);
      canvas.drawCircle(
        Offset(b.fx * size.width, b.dy),
        b.diameter / 2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BokehPainter old) => !identical(old.blobs, blobs);
}

// ─────────────────────────────────────────────────────────────────────
// The points of light
// ─────────────────────────────────────────────────────────────────────

/// How brightly a person burns. See [gaiaBokehTone] for the rule.
enum GaiaBokehTone {
  /// `.bk-avatar` — champagne, haloed. Someone who has actually been in.
  warm,

  /// `.bk-avatar.cool` — sage/forest, haloed. A real record with no recent
  /// visit: booked, queued, left feedback anonymously.
  cool,

  /// `.bk-avatar.dim` — a name and nothing else. No halo at all.
  dim,
}

/// The mockup's stated rule, applied to the fields the guest book actually
/// returns: "a guest who dined this month glows, a name that only ever booked
/// stays dim".
///
/// [daysSinceLastVisit] null means never visited.
GaiaBokehTone gaiaBokehTone({
  required int visits,
  required double spend,
  required int? daysSinceLastVisit,
}) {
  if (visits <= 0 && spend <= 0) return GaiaBokehTone.dim;
  final d = daysSinceLastVisit;
  if (d != null && d <= 30) return GaiaBokehTone.warm;
  return GaiaBokehTone.cool;
}

/// `.bk-avatar` — a soft-lit disc with the guest's initial in it.
///
/// The brightness is a SECOND reading of a value the row also prints. Never the
/// only one; see the file header.
class GaiaBokehAvatar extends StatelessWidget {
  const GaiaBokehAvatar({
    super.key,
    required this.initials,
    this.tone = GaiaBokehTone.warm,
    this.size = 44,
    this.halo = true,
  });

  final String initials;
  final GaiaBokehTone tone;
  final double size;

  /// The mockup drops the halo on `.dim`; a caller may drop it anywhere the
  /// avatar sits inside a tight row and the rings would collide.
  final bool halo;

  static const List<Color> _warm = [
    Color(0xFFE2CFA6),
    Color(0xFFA08C67),
    Color(0xFF5C4D33),
  ];
  static const List<Color> _cool = [
    Color(0xFF9BC4A0),
    Color(0xFF3D6A55),
    Color(0xFF1E3A2D),
  ];
  static const List<Color> _dim = [
    Color(0xFF3F4A44),
    Color(0xFF1F2A26),
    Color(0xFF14201C),
  ];

  @override
  Widget build(BuildContext context) {
    final dim = tone == GaiaBokehTone.dim;
    final colors = switch (tone) {
      GaiaBokehTone.warm => _warm,
      GaiaBokehTone.cool => _cool,
      GaiaBokehTone.dim => _dim,
    };
    final ink = switch (tone) {
      GaiaBokehTone.warm => GaiaColors.ink,
      GaiaBokehTone.cool => const Color(0xFFEAF2EC),
      GaiaBokehTone.dim => GaiaColors.text2,
    };
    // The mockup pushes the dim avatar's mid stop out to 60%, which is what
    // stops it reading as a hole.
    final stops = dim ? const [0.0, 0.6, 1.0] : const [0.0, 0.55, 1.0];
    // Rings scale with the avatar; the mockup's own pair is 6/14 at 56px and
    // 5/… at 44px.
    final r1 = size * 0.107;
    final r2 = size * 0.25;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          // `circle at 40% 35%` -> Alignment is -1..1.
          center: const Alignment(-0.2, -0.3),
          radius: 0.78,
          colors: colors,
          stops: stops,
        ),
        // CSS paints the FIRST listed shadow on top; Flutter paints the LAST
        // on top. Reversed here so the tighter, brighter ring wins, which is
        // what makes the halo read as falloff rather than a flat plate.
        boxShadow: (halo && !dim)
            ? [
                BoxShadow(
                  color: GaiaColors.champagne.withValues(alpha: 0.04),
                  spreadRadius: r2,
                ),
                BoxShadow(
                  color: GaiaColors.champagne.withValues(alpha: 0.08),
                  spreadRadius: r1,
                ),
              ]
            : null,
      ),
      child: Text(
        initials,
        maxLines: 1,
        style: GaiaType.serif(
          size: size * 0.39,
          weight: 500,
          height: 1,
          color: ink,
        ),
      ),
    );
  }
}

/// `.ring` — the conic gauge the Feedback screen leads with.
///
/// A hard-stopped [SweepGradient] with a ground-coloured disc punched out of
/// the middle, which is exactly what the CSS `conic-gradient` +
/// `::before{inset:6px}` pair is.
class GaiaRing extends StatelessWidget {
  const GaiaRing({
    super.key,
    required this.fraction,
    required this.value,
    this.unit,
    this.size = 132,
    this.color,
    this.trackColor,
  });

  /// 0..1. The mockup's own example is 91%.
  final double fraction;

  /// The serif figure in the middle.
  final String value;

  /// The sans tail hung off it ("/5").
  final String? unit;

  final double size;
  final Color? color;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final f = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    final fill = color ?? GaiaColors.champagne;
    final track = trackColor ?? GaiaColors.line;
    // A sweep gradient starts at 3 o'clock; a CSS conic starts at 12.
    final gradient = SweepGradient(
      colors: [fill, fill, track, track],
      // The doubled stop is the hard edge. Nudged apart by a thousandth so the
      // rasteriser draws a seam rather than an antialiased smear at low values.
      stops: [0, f, f == 0 ? 0.001 : f, 1],
      transform: const GradientRotation(-math.pi / 2),
    );

    return Semantics(
      // One node saying "4.55 /5", not a serif fragment and a sans fragment
      // read out separately — the figure and its unit are one reading.
      container: true,
      excludeSemantics: true,
      label: unit == null ? value : '$value $unit',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
        child: Container(
          width: size - 12,
          height: size - 12,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            // The mockup's `.ring::before{background:var(--bg)}`. Spelled as
            // the forest constant rather than `GaiaColors.bg` so the whole
            // decoration stays const — the ring is the one shape on the
            // Feedback screen that repaints on every summary refresh.
            color: Color(0xFF0C1513),
          ),
          child: RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              text: value,
              style: GaiaType.serif(
                size: size * 0.288,
                weight: 500,
                height: 1,
                color: GaiaColors.champagne2,
              ),
              children: [
                if (unit != null)
                  TextSpan(text: unit, style: GaiaType.unit()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mockup's `.item` under bokeh: a hairline row led by a lit avatar.
///
/// Same job as `GaiaListRow`, but the left edge carries a person rather than a
/// status dot — which is the difference between the operations screens and
/// these two.
class GaiaBokehRow extends StatefulWidget {
  const GaiaBokehRow({
    super.key,
    required this.initials,
    required this.title,
    this.tone = GaiaBokehTone.warm,
    this.detail,
    this.value,
    this.valueUnit,
    this.valueTail,
    this.valueColor,
    this.trailing,
    this.onTap,
    this.first = false,
    this.selected = false,
  });

  final String initials;
  final GaiaBokehTone tone;
  final String title;
  final String? detail;

  /// `.item .v` — the serif figure on the right.
  final String? value;

  /// `.item .v small` — the uppercase caption under it.
  final String? valueUnit;

  /// The faint tail the Feedback rows hang off a score ("/5").
  final String? valueTail;

  final Color? valueColor;

  /// Anything the row needs after the figure — a chevron, a chip.
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool first;

  /// Draws the champagne left rail — the focus/notification highlight.
  final bool selected;

  @override
  State<GaiaBokehRow> createState() => _GaiaBokehRowState();
}

class _GaiaBokehRowState extends State<GaiaBokehRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;

    Widget row = AnimatedContainer(
      duration: GaiaDurations.fast,
      padding: EdgeInsets.only(
        top: GaiaSpacing.rowY,
        bottom: GaiaSpacing.rowY,
        left: widget.selected ? 10 : 0,
      ),
      decoration: BoxDecoration(
        color: _hover && interactive
            ? GaiaColors.champagne.withValues(alpha: 0.03)
            : null,
        border: Border(
          top: widget.first
              ? BorderSide.none
              : BorderSide(color: GaiaColors.line),
          left: widget.selected
              ? const BorderSide(
                  color: GaiaColors.champagne, width: GaiaRadius.railStroke)
              : BorderSide.none,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GaiaBokehAvatar(initials: widget.initials, tone: widget.tone),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.rowTitle(),
                ),
                if (widget.detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GaiaType.detail(),
                  ),
                ],
              ],
            ),
          ),
          if (widget.value != null) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    text: widget.value,
                    style: GaiaType.rowValue(color: widget.valueColor),
                    children: [
                      if (widget.valueTail != null)
                        TextSpan(
                          text: widget.valueTail,
                          style: GaiaType.sans(
                              size: 14, color: GaiaColors.text3AA),
                        ),
                    ],
                  ),
                ),
                if (widget.valueUnit != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.valueUnit!.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GaiaType.sans(
                      size: 11,
                      color: GaiaColors.text2,
                      letterSpacing: GaiaType.track(0.12, 11),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (widget.trailing != null) ...[
            const SizedBox(width: 8),
            widget.trailing!,
          ],
        ],
      ),
    );

    if (!interactive) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}
