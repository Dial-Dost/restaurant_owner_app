// GAIA signature style: COVERFLOW.
//
// The mockup allocates this to Bookings and Waitlist — the two screens that
// are a QUEUE OF PEOPLE with an obvious "next one". From the mockup CSS:
//
// ```
// .coverflow{position:relative;height:270px;perspective:900px;perspective-origin:50% 50%}
// .cf {position:absolute;top:0;left:50%;width:250px;height:250px;margin-left:-125px;
//      background:var(--surface);border:1px solid var(--line-2);padding:22px}
// .cf.c  {background:var(--raised);border-color:var(--champagne-dim);transform:translateZ(60px);z-index:5}
// .cf.l1 {transform:translateX(-165px) rotateY( 38deg) scale(.84);opacity:.78;z-index:3}
// .cf.r1 {transform:translateX( 165px) rotateY(-38deg) scale(.84);opacity:.78;z-index:3}
// .cf.l2 {transform:translateX(-255px) rotateY( 46deg) scale(.72);opacity:.40;z-index:1}
// .cf.r2 {transform:translateX( 255px) rotateY(-46deg) scale(.72);opacity:.40;z-index:1}
// ```
//
// and the mockup's own JS, which is the whole interaction it ships: tapping any
// card re-labels every card so the tapped one becomes `.c`.
//
// ## What is reproduced, and what is not
//
// The GEOMETRY is reproduced exactly — the same offsets, angles, scales,
// opacities and the same 900px perspective, read as a five-stop table and
// interpolated so a half-dragged card sits halfway between two stops. Web
// coverflow snaps between discrete classes because CSS has no continuous
// position; a finger does, so this one is continuous and the snap is a spring
// at the end rather than the only state.
//
// What is NOT reproduced is "tap to advance" as the sole input. That is a
// mouse-less, keyboard-less demo affordance. This runs on a Windows till, so
// the same position is driven by: drag (touch AND mouse), flick with velocity,
// arrow keys / Home / End / Enter, the scroll wheel, a click on any off-centre
// card, and two chevron buttons that are always visible on a pointer device.
//
// ## The motion budget
//
// This is on cheap Android tills, so the per-frame cost is deliberately capped:
//
//  * The card faces are built ONCE per data change, in [build], and captured.
//    The animation lives in a [ValueListenableBuilder] on a [ValueNotifier] and
//    only ever constructs ~7 `Transform`/`Opacity`/`Container` wrappers around
//    those already-built widgets. Re-wrapping an IDENTICAL child widget makes
//    `Element.updateChild` short-circuit, so no card subtree is rebuilt while
//    the flow moves — the same identity rule documented in `gaia.dart`.
//  * Each face sits under a [RepaintBoundary], so its raster is cached and a
//    frame is a compositor transform + alpha, not a re-paint.
//  * At most [_windowRadius] * 2 + 1 = 7 cards exist at all, whatever the list
//    length. A 300-booking Saturday builds seven cards.
//  * `onIndexChanged` fires when a settle STARTS, not per frame, so the parent
//    screen rebuilds once per gesture rather than once per frame.
//
// ## The honest cost, stated up front
//
// A coverflow shows one record at a time. That is right for "who is next" and
// wrong for "find the 8pm party in a list of forty". Both screens that use it
// therefore keep a full, scannable, hairline list BELOW the flow, and a tap on
// a list row drives the flow to that record. The flow is the hero; the list is
// still how you find someone. See `GaiaCoverflowIndex` for the same reasoning
// applied to the mockup's dot strip, which does not survive past ~12 items.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

/// One stop on the coverflow's transform curve, read straight off the CSS
/// classes above. `d` is the signed distance from the focused card; every value
/// below is the RIGHT-hand side and is mirrored for negative `d`.
class _Stop {
  const _Stop(this.d, this.dx, this.deg, this.scale, this.opacity, this.dz);

  final double d;

  /// `translateX`, in the mockup's 430px-wide frame.
  final double dx;

  /// `rotateY`, degrees. CSS's sign: a card to the RIGHT of centre turns its
  /// right edge away from the viewer, so the value is negated for d > 0.
  final double deg;
  final double scale;
  final double opacity;

  /// `translateZ` — only the focused card has any (60px).
  final double dz;
}

/// The five CSS stops, plus two the CSS does not need.
///
/// `.c`, `.l1/.r1` and `.l2/.r2` are the mockup's own. The 3.0 and 3.9 stops
/// exist because the CSS demo only ever holds five cards: it can dump every
/// further card onto `.l2`/`.r2` and stack them invisibly. A real list has
/// hundreds, and a card must therefore be able to leave the stage — so the
/// ramp continues past `.l2` and reaches zero opacity, which is where the
/// build window closes.
const List<_Stop> _stops = [
  _Stop(0, 0, 0, 1.00, 1.00, 60),
  _Stop(1, 165, 38, 0.84, 0.78, 0),
  _Stop(2, 255, 46, 0.72, 0.40, 0),
  _Stop(3, 330, 48, 0.62, 0.16, 0),
  _Stop(3.9, 396, 48, 0.58, 0.00, 0),
];

/// Cards built either side of the focus. 3 covers every stop with a visible
/// opacity plus the one fading out.
const int _windowRadius = 3;

/// `perspective:900px`.
const double _perspective = 900;

/// The frame the mockup's pixel offsets were measured in.
const double _designWidth = 430;

@immutable
class _Frame {
  const _Frame(this.dx, this.deg, this.scale, this.opacity, this.dz);
  final double dx;
  final double deg;
  final double scale;
  final double opacity;
  final double dz;

  /// Interpolate the stop table at an arbitrary (fractional, signed) distance.
  static _Frame at(double d) {
    final sign = d.isNegative ? -1.0 : 1.0;
    final a = d.abs();
    if (a >= _stops.last.d) {
      final s = _stops.last;
      return _Frame(s.dx * sign, -s.deg * sign, s.scale, 0, s.dz);
    }
    var i = 0;
    while (i < _stops.length - 2 && a > _stops[i + 1].d) {
      i++;
    }
    final lo = _stops[i];
    final hi = _stops[i + 1];
    final t = ((a - lo.d) / (hi.d - lo.d)).clamp(0.0, 1.0);
    return _Frame(
      lerpDouble(lo.dx, hi.dx, t)! * sign,
      -lerpDouble(lo.deg, hi.deg, t)! * sign,
      lerpDouble(lo.scale, hi.scale, t)!,
      lerpDouble(lo.opacity, hi.opacity, t)!,
      lerpDouble(lo.dz, hi.dz, t)!,
    );
  }
}

/// A GAIA coverflow.
///
/// Controlled: the parent owns [index] and is told about changes through
/// [onIndexChanged]. That is deliberate — both screens using this need the
/// focused record to drive a detail block and a list highlight, and a widget
/// that owned its own index would have to be reached into.
class GaiaCoverflow extends StatefulWidget {
  const GaiaCoverflow({
    super.key,
    required this.itemCount,
    required this.index,
    required this.onIndexChanged,
    required this.itemBuilder,
    this.onActivate,
    this.semanticsBuilder,
    this.cardWidth = 250,
    this.cardHeight = 250,
    this.dashedBuilder,
  });

  final int itemCount;

  /// The focused card. Clamped into range, so a parent may hand over a stale
  /// index after a refetch shortens the list.
  final int index;

  /// Fired when the flow commits to a new card — at the START of the settle,
  /// so a detail block below updates on release rather than a beat later.
  final ValueChanged<int> onIndexChanged;

  /// The card FACE only: contents, no box. The box (ground, hairline, focus
  /// outline) is drawn by the flow itself so it can change with the continuous
  /// position without rebuilding the face. See the file header.
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// Tapping the FOCUSED card, or pressing Enter/Space on it. An off-centre tap
  /// always means "bring this one to the front" and never activates.
  final ValueChanged<int>? onActivate;

  /// Screen-reader label for a card. Falls back to "Item n of m".
  final String Function(int index)? semanticsBuilder;

  final double cardWidth;
  final double cardHeight;

  /// `.cf.dash` — true for a card that is a placeholder rather than a record.
  final bool Function(int index)? dashedBuilder;

  @override
  State<GaiaCoverflow> createState() => _GaiaCoverflowState();
}

class _GaiaCoverflowState extends State<GaiaCoverflow>
    with SingleTickerProviderStateMixin {
  /// The continuous position, in cards. Held in a notifier rather than State so
  /// a drag frame repaints the transforms WITHOUT calling setState — which
  /// would rebuild every card face, and on a till that is the difference
  /// between a flick and a stutter.
  late final ValueNotifier<double> _pos;

  late final AnimationController _settle;
  double _from = 0;
  double _to = 0;

  /// Accumulated wheel/trackpad delta; a notch is rarely a whole card.
  double _wheel = 0;

  final FocusNode _focus = FocusNode(debugLabel: 'GaiaCoverflow');

  int get _max => math.max(0, widget.itemCount - 1);

  @override
  void initState() {
    super.initState();
    _pos = ValueNotifier<double>(widget.index.clamp(0, _max).toDouble());
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(_tick);
  }

  void _tick() {
    final t = Curves.easeOutCubic.transform(_settle.value);
    _pos.value = lerpDouble(_from, _to, t)!;
  }

  @override
  void didUpdateWidget(GaiaCoverflow old) {
    super.didUpdateWidget(old);
    final target = widget.index.clamp(0, _max).toDouble();
    // The parent moved the focus (a list row was tapped, the data reloaded).
    // Animate there unless we are already going.
    if (target != _to || widget.itemCount != old.itemCount) {
      if ((_pos.value - target).abs() > 0.001) {
        _animateTo(target, notify: false);
      } else {
        _to = target;
        _pos.value = target;
      }
    }
  }

  @override
  void dispose() {
    _settle
      ..removeListener(_tick)
      ..dispose();
    _pos.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _animateTo(double target, {bool notify = true}) {
    _from = _pos.value;
    _to = target.clamp(0, _max.toDouble());
    if (notify && _to.round() != widget.index) widget.onIndexChanged(_to.round());
    if (_from == _to) {
      _pos.value = _to;
      return;
    }
    _settle
      ..stop()
      ..value = 0
      ..forward();
  }

  /// One card in [delta]'s direction.
  ///
  /// Measured from the SETTLE TARGET while a settle is running, not from where
  /// the cards happen to be. Holding the right arrow, or hammering the chevron,
  /// otherwise stalls: each press would re-read a position that has barely
  /// moved and re-aim at the same card.
  void _step(int delta) {
    final from = _settle.isAnimating ? _to : _pos.value.round().toDouble();
    _animateTo(from + delta);
  }

  // ── Pointer drag ─────────────────────────────────────────────────────
  // The card the finger is on tracks the finger 1:1, which is what makes it
  // feel like a physical stack rather than a paging list.

  void _dragStart(DragStartDetails _) {
    _settle.stop();
    _focus.requestFocus();
  }

  void _dragUpdate(DragUpdateDetails d, double slot) {
    final next = _pos.value - d.primaryDelta! / slot;
    // Hard clamp with a half-card of give at each end: rubber-banding past the
    // first booking suggests there is another one, and there is not.
    _pos.value = next.clamp(-0.4, _max + 0.4);
  }

  void _dragEnd(DragEndDetails d, double slot) {
    final v = d.primaryVelocity ?? 0;
    // A flick throws exactly one card. Multi-card momentum on a 250px card
    // overshoots the record you were aiming at, and this is a list of people,
    // not a photo roll.
    final target = v.abs() > 320
        ? (v < 0 ? _pos.value.floor() + 1 : _pos.value.ceil() - 1)
        : _pos.value.round();
    _animateTo(target.toDouble());
  }

  void _wheelEvent(PointerScrollEvent e) {
    // Vertical wheel (a mouse) and horizontal (a trackpad swipe) both drive it;
    // whichever axis carries more is the one meant.
    final d = e.scrollDelta;
    final v = d.dx.abs() > d.dy.abs() ? d.dx : d.dy;
    _wheel += v;
    if (_wheel.abs() < 40) return;
    _step(_wheel > 0 ? 1 : -1);
    _wheel = 0;
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _step(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _step(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _animateTo(0);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        _animateTo(_max.toDouble());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        _step(-3);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        _step(3);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.numpadEnter:
        widget.onActivate?.call(_pos.value.round().clamp(0, _max));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : _designWidth;
      // The mockup's offsets were measured in a 430px phone. On a desktop
      // window the fan opens out rather than the cards growing: a booking card
      // is a fixed-size object (like an album cover), and a 900px-wide one
      // would be a poster. Capped at 1.9 so a 2560px monitor does not throw the
      // neighbours off-screen.
      final spread = (width / _designWidth).clamp(1.0, 1.9);
      // How far a finger travels for one card.
      final slot = _stops[1].dx * spread;

      // Built ONCE per data change and captured by the listener below — this is
      // the whole per-frame budget story. See the file header.
      final faces = <int, Widget>{};
      final focus = _pos.value.round().clamp(0, _max);
      for (var i = focus - _windowRadius; i <= focus + _windowRadius; i++) {
        if (i < 0 || i > _max) continue;
        faces[i] = RepaintBoundary(child: widget.itemBuilder(context, i));
      }

      final flow = SizedBox(
        // Explicitly the FULL width, not the intrinsic width of the card stack.
        // A Stack sizes to its largest child, which would make the flow exactly
        // one card wide — and a RenderBox refuses hit tests outside its own
        // bounds, so the drag would only answer in the middle 250px and the
        // fanned-out neighbours would be un-clickable. Both are invisible
        // failures: the pixels look right and half the surface is dead.
        width: width,
        height: widget.cardHeight + 12,
        child: ValueListenableBuilder<double>(
          valueListenable: _pos,
          builder: (context, pos, _) {
            final live = <int>[];
            final centre = pos.round().clamp(0, _max);
            for (var i = centre - _windowRadius; i <= centre + _windowRadius; i++) {
              if (i < 0 || i > _max) continue;
              if (!faces.containsKey(i)) continue; // beyond the built window
              live.add(i);
            }
            // Painter's order: farthest first, so the focused card is on top.
            // This is `z-index` in the CSS; a Stack has no z, only order.
            live.sort((a, b) => (b - pos).abs().compareTo((a - pos).abs()));

            return Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                for (final i in live)
                  _card(i, pos, spread, faces[i]!),
              ],
            );
          },
        ),
      );

      final gestures = Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _wheelEvent(e);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onHorizontalDragStart: _dragStart,
          onHorizontalDragUpdate: (d) => _dragUpdate(d, slot),
          onHorizontalDragEnd: (d) => _dragEnd(d, slot),
          child: flow,
        ),
      );

      return Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: Stack(
          alignment: Alignment.center,
          children: [
            gestures,
            // Always present, not hover-revealed. On a Windows till with no
            // touchscreen a coverflow whose only affordance is a flick is an
            // ornament; these two make it a control. They sit outside the
            // drag detector so a click cannot be read as a 0px drag.
            Positioned(left: 0, child: _chevron(-1, Icons.chevron_left)),
            Positioned(right: 0, child: _chevron(1, Icons.chevron_right)),
          ],
        ),
      );
    });
  }

  Widget _chevron(int delta, IconData icon) {
    return ValueListenableBuilder<double>(
      valueListenable: _pos,
      builder: (context, pos, child) {
        final at = delta < 0 ? pos <= 0.01 : pos >= _max - 0.01;
        return IgnorePointer(
          ignoring: at,
          child: AnimatedOpacity(
            duration: GaiaDurations.fast,
            opacity: at ? 0.18 : 1,
            child: child,
          ),
        );
      },
      child: _ChevronButton(
        icon: icon,
        onPressed: () => _step(delta),
        tooltip: delta < 0 ? 'Previous' : 'Next',
      ),
    );
  }

  Widget _card(int i, double pos, double spread, Widget face) {
    final d = i - pos;
    final f = _Frame.at(d);
    if (f.opacity <= 0.001) return const SizedBox.shrink();

    final focused = d.abs() < 0.5;
    // The box is drawn HERE, not in the face, so `.cf.c`'s raised ground and
    // champagne hairline can cross-fade with the continuous position without
    // rebuilding the card's contents. `t` is 1 dead centre, 0 by the neighbours.
    final t = (1 - d.abs()).clamp(0.0, 1.0);
    final dashed = widget.dashedBuilder?.call(i) ?? false;

    final matrix = Matrix4.identity()
      // CSS `perspective:900px` on the container. Flutter's sign convention is
      // the opposite of CSS's — a positive entry makes +z recede — so this is
      // negated to make the mockup's own angles produce the mockup's own look.
      ..setEntry(3, 2, -1 / _perspective)
      ..translateByDouble(f.dx * spread, 0, f.dz, 1)
      ..rotateY(f.deg * math.pi / 180)
      ..scaleByDouble(f.scale, f.scale, 1, 1);

    return Transform(
      transform: matrix,
      alignment: Alignment.center,
      child: Opacity(
        opacity: f.opacity.clamp(0.0, 1.0),
        child: SizedBox(
          width: widget.cardWidth,
          height: widget.cardHeight,
          child: Semantics(
            selected: focused,
            button: true,
            label: widget.semanticsBuilder?.call(i) ??
                'Item ${i + 1} of ${widget.itemCount}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // An off-centre card ALWAYS just comes to the front. Activating a
              // record you can only half see is how a mis-tap cancels somebody
              // else's booking.
              onTap: () {
                _focus.requestFocus();
                if (focused) {
                  widget.onActivate?.call(i);
                } else {
                  _animateTo(i.toDouble());
                }
              },
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Color.lerp(GaiaColors.surface, GaiaColors.raised, t),
                  border: dashed
                      ? Border.all(color: GaiaColors.line2)
                      : Border.all(
                          color: Color.lerp(
                              GaiaColors.line2, GaiaColors.champagneDim, t)!,
                        ),
                  borderRadius: GaiaRadius.all,
                ),
                foregroundDecoration: dashed
                    ? _DashedEdge(color: GaiaColors.line2)
                    : null,
                child: face,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.card.dash` on a coverflow card. A Decoration rather than a painter so it
/// can ride `foregroundDecoration` and leave the solid border underneath doing
/// the layout.
class _DashedEdge extends Decoration {
  const _DashedEdge({required this.color});
  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedEdgePainter(color);
}

class _DashedEdgePainter extends BoxPainter {
  _DashedEdgePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final size = cfg.size;
    if (size == null) return;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = GaiaRadius.hairline;
    const dash = 5.0;
    const gap = 4.0;
    final r = (offset & size).deflate(0.5);
    void run(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      var t = 0.0;
      while (t < total) {
        final end = math.min(t + dash, total);
        canvas.drawLine(a + dir * t, a + dir * end, p);
        t = end + gap;
      }
    }

    run(r.topLeft, r.topRight);
    run(r.topRight, r.bottomRight);
    run(r.bottomRight, r.bottomLeft);
    run(r.bottomLeft, r.topLeft);
  }
}

class _ChevronButton extends StatefulWidget {
  const _ChevronButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  State<_ChevronButton> createState() => _ChevronButtonState();
}

class _ChevronButtonState extends State<_ChevronButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: GaiaColors.bg.withValues(alpha: _hover ? 0.92 : 0.66),
              border: Border.all(
                  color: _hover ? GaiaColors.champagneDim : GaiaColors.line),
              borderRadius: GaiaRadius.all,
            ),
            child: Icon(widget.icon,
                size: 20,
                color: _hover ? GaiaColors.champagne : GaiaColors.text2),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// The card face
// ─────────────────────────────────────────────────────────────────────

/// `.cf`'s contents — who, when, two lines of detail, a footed rule.
///
/// Contents only: the box belongs to [GaiaCoverflow]. See the file header.
class GaiaCoverflowCard extends StatelessWidget {
  const GaiaCoverflowCard({
    super.key,
    required this.who,
    required this.when,
    this.detail = const [],
    this.footLeft,
    this.footRight,
    this.footRightColor,
    this.whenColor,
    this.dim = false,
  });

  /// `.cf .who` — 30px serif. The one thing readable from the far side of the
  /// pass, and the reason the serif exists in this design.
  final String who;

  /// `.cf .when` — uppercase, tracked, champagne.
  final String when;

  /// `.cf .d` — up to three lines; anything longer is the detail block's job.
  final List<String> detail;

  /// `.cf .foot span` / `.cf .foot b`.
  final String? footLeft;
  final String? footRight;
  final Color? footRightColor;
  final Color? whenColor;

  /// `style="opacity:.45"` on the waitlist's already-seated card.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final fade = dim ? 0.55 : 1.0;
    Color a(Color c) => dim ? c.withValues(alpha: fade) : c;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          who,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GaiaType.serif(
            size: 30,
            weight: 500,
            height: 1,
            color: a(dim ? GaiaColors.text2 : GaiaColors.text),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          when.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GaiaType.eyebrow(
              color: a(whenColor ?? (dim ? GaiaColors.text3AA : GaiaColors.champagne))),
        ),
        // Expanded, not Flexible-next-to-a-Spacer. Both are flex children, so
        // the Spacer took HALF the free space and left the detail 2.9 lines for
        // its `maxLines: 3` — and Text CLIPS vertical overflow silently rather
        // than ellipsising it, so the last line came out sliced in half. This
        // gives the detail all the room and lets the foot sit on the floor.
        Expanded(
          child: detail.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      detail.join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: GaiaType.sans(
                          size: 13, height: 1.5, color: a(GaiaColors.text2)),
                    ),
                  ),
                ),
        ),
        if (footLeft != null || footRight != null) ...[
          Container(height: 1, color: GaiaColors.line),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  (footLeft ?? '').toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.sans(
                    size: 11,
                    color: a(GaiaColors.text2),
                    letterSpacing: GaiaType.track(0.16, 11),
                  ),
                ),
              ),
              if (footRight != null) ...[
                const SizedBox(width: 10),
                Text(
                  footRight!.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.sans(
                    size: 11,
                    color: a(footRightColor ?? GaiaColors.champagne),
                    letterSpacing: GaiaType.track(0.16, 11),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// The index strip
// ─────────────────────────────────────────────────────────────────────

/// `.cfdots` — a dot per card, the current one drawn as a champagne bar.
///
/// With one caveat the mockup never meets: it holds five cards, and forty dots
/// on a 430px phone is a 4px-pitch smear that says nothing. Past [_dotLimit]
/// this becomes a position counter instead, which is the same information at a
/// size a host can read across a pass.
class GaiaCoverflowIndex extends StatelessWidget {
  const GaiaCoverflowIndex({
    super.key,
    required this.count,
    required this.index,
    this.onTap,
  });

  final int count;
  final int index;
  final ValueChanged<int>? onTap;

  static const int _dotLimit = 12;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox(height: 8);
    if (count > _dotLimit) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Center(
          child: Text(
            '${index + 1} of $count',
            style: GaiaType.eyebrow(color: GaiaColors.text3AA),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: EdgeInsets.only(right: i == count - 1 ? 0 : 8),
              child: GestureDetector(
                onTap: onTap == null ? null : () => onTap!(i),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  // The dot is 4px; the TARGET is 20px. A 4px tap target is not
                  // a control, it is a decoration that punishes you for trying.
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: AnimatedContainer(
                    duration: GaiaDurations.fast,
                    width: i == index ? 14 : 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: i == index ? GaiaColors.champagne : GaiaColors.line2,
                      borderRadius: BorderRadius.circular(i == index ? 2 : 999),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
