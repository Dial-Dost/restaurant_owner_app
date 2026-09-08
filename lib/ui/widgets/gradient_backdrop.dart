import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';
import '../theme/appearance.dart';
import '../theme/backdrop_style.dart';

/// The guest ordering page's warmth, brought to the owner app.
///
/// A straight translation of what /order/[restaurant] paints, layer for layer,
/// so the two surfaces read as one product rather than two:
///
///   1. a near-black base                        (#08080A there, AppColors.bg here)
///   2. a hero wash                              linear-gradient(150deg, accDeep, #0b0b0d 78%)
///   3. a bloom off the top-right corner         radial accHi @ .30 -> transparent 62%
///
/// The wash uses the glow* tokens, NOT the copper ramp. Copper is an ink and
/// metal palette at ~0.47 saturation; spread across a whole screen it reads as
/// brown rather than as the warm orange the guest page and the app icon use.
/// glowDeep/glowBright are the brand orange (#ea580c) walked darker with its
/// saturation intact, so dimming it does not turn it to mud — which is exactly
/// what happened when this was first darkened down the copper ramp.
///   4. a downward darkening pass                180deg, rgba(6,6,7,.15) -> .40 @45% -> .96
///   5. two ambient orbs, top-left / bottom-right, at .20 and .22
///
/// The orbs on the web float on a 16-20s animation. They are STATIC here on
/// purpose: this sits behind every module, including a 40-row queue and a long
/// menu, and an animated backdrop repaints the whole tree every frame for
/// decoration nobody is looking at. One non-animated layer costs nothing.
///
/// Nothing inside is interactive, so the whole thing is wrapped in
/// [IgnorePointer] — a decorative layer must never eat a tap meant for the
/// content above it.
class GradientBackdrop extends StatelessWidget {
  const GradientBackdrop({
    super.key,
    required this.child,
    this.heroHeight,
  });

  final Widget child;

  /// How far the warm wash reaches before it has fully become the page.
  ///
  /// Null means "scale it", which is the right default: the guest hero is 172px
  /// of a ~430px phone viewport — about 40% — and pinning that pixel count to a
  /// 900px desktop window turns the same design into a thin band across the top.
  /// A caller can still pass an explicit height for a fixed-size surface.
  final double? heroHeight;

  @override
  Widget build(BuildContext context) {
    // GAIA has no backdrop. Its depth is the flat ground ladder and a
    // hairline — a warm wash and two ambient orbs are precisely the vocabulary
    // it does not use, and leaving them on would read as the old look bleeding
    // through the new one. So the layer stack collapses to the page ground.
    if (Gaia.of(context)) {
      return ColoredBox(color: GaiaColors.bg, child: child);
    }

    final h = heroHeight ?? (MediaQuery.sizeOf(context).height * 0.42).clamp(180.0, 520.0);
    final style = AppearanceController.instance.backdrop;

    // The shipped copper-on-rustic look, verbatim. Untouched knobs on the
    // shipped scheme AND the shipped accent paint EXACTLY the layer stack that
    // shipped in 1.8.0 — including its guest-page neutrals (#0B0B0D, #060607)
    // that are near but not equal to the rustic tokens — so "default" stays a
    // promise, not an approximation. Everything else (an owner-moved knob, a
    // non-rustic scheme, a non-copper accent) takes the computed path below,
    // where the AA guard runs: copper's glow passes the guard untouched at
    // full alpha (measured 7.79:1 under primary ink), so gating on copper here
    // skips no clamp that would ever have engaged — while teal's brighter glow,
    // which grazes the floor, gets the trim the shipped constants never did.
    if (style.isDefault && AppColors.shell.id == 'rustic' && AppColors.accent.id == 'copper') {
      return _layers(
        h: h,
        base: AppColors.bg,
        orbNear: _Orb(size: 360, color: AppColors.glowMid, opacity: 0.22),
        orbFar: _Orb(size: 340, color: AppColors.glowDeep, opacity: 0.22),
        wash: LinearGradient(
          // 150deg in CSS runs top-left -> bottom-right; these alignments
          // are the same axis expressed the way Flutter wants it.
          begin: const Alignment(-0.7, -1),
          end: const Alignment(0.7, 1),
          colors: [AppColors.glowDeep, const Color(0xFF0B0B0D)],
          stops: const [0.0, 0.78],
        ),
        bloom: _Orb(size: 340, color: AppColors.glowBright, opacity: 0.34, stop: 0.62),
        darken: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x26060607),
            Color(0x66060607),
            Color(0xF508080A),
          ],
          stops: [0.0, 0.45, 1.0],
        ),
      );
    }

    // The owner-mixed (or non-rustic-scheme) backdrop: same five layers, tones
    // and axis resolved from style x glow ramp x scheme — with the AA guard
    // already applied (resolveBackdrop clamps the wash's top stop and the
    // bloom so body ink stays >= 4.5:1 on the brightest thing they compose).
    final r = resolveBackdrop(
      style: style,
      glowBright: AppColors.glowBright,
      glowMid: AppColors.glowMid,
      glowDeep: AppColors.glowDeep,
      bg: AppColors.bg,
      ink: AppColors.textPrimary,
    );
    return _layers(
      h: h,
      base: AppColors.bg,
      orbNear: _Orb(size: 360, color: r.orbNearColor, opacity: r.orbNearOpacity),
      orbFar: _Orb(size: 340, color: r.orbFarColor, opacity: r.orbFarOpacity),
      wash: LinearGradient(
        begin: r.washBegin,
        end: r.washEnd,
        // The top stop is pre-composited onto the scheme ground (opaque), so
        // fading to the scheme's own bg keeps the wash landing on the page
        // whatever ground the scheme wears.
        colors: [r.washColor, AppColors.bg],
        stops: const [0.0, 0.78],
      ),
      bloom: _Orb(size: 340, color: r.bloomColor, opacity: r.bloomOpacity, stop: 0.62),
      darken: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppColors.bgDeep.withValues(alpha: 0.15),
          AppColors.bgDeep.withValues(alpha: 0.40),
          AppColors.bg.withValues(alpha: 0.96),
        ],
        stops: const [0.0, 0.45, 1.0],
      ),
    );
  }

  /// The one five-layer recipe both paths share, so "custom" can never drift
  /// structurally from "shipped" — only the tones differ.
  Widget _layers({
    required double h,
    required Color base,
    required _Orb orbNear,
    required _Orb orbFar,
    required LinearGradient wash,
    required _Orb bloom,
    required LinearGradient darken,
  }) {
    return Stack(
      children: [
        // 1 — the base every other layer sits on.
        Positioned.fill(child: ColoredBox(color: base)),

        // 5 — ambient orbs. Painted before the hero so the hero reads as the
        // brighter event and these stay atmosphere.
        Positioned(top: -120, left: -80, child: orbNear),
        Positioned(bottom: -140, right: -60, child: orbFar),

        // 2 — the hero wash: the warm event at the top, gone by ~78% of its
        // own height.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: h,
          child: DecoratedBox(decoration: BoxDecoration(gradient: wash)),
        ),

        // 3 — the bright bloom spilling off the top-right corner. This is the
        // part that makes the header feel lit rather than merely tinted.
        Positioned(top: -120, right: -70, child: bloom),

        // 4 — the darkening pass that lands the wash back on the page colour.
        // Without it the wash stays milky where content begins.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: h,
          child: DecoratedBox(decoration: BoxDecoration(gradient: darken)),
        ),

        // The app itself, over all of it.
        Positioned.fill(child: child),
      ],
    );
  }
}

/// One soft circular glow. The web blurs these with a CSS filter; a radial stop
/// reaches the same look without a saveLayer, which matters when the thing is
/// full-screen and behind a scrolling list.
class _Orb extends StatelessWidget {
  const _Orb({
    required this.size,
    required this.color,
    required this.opacity,
    this.stop = 0.65,
  });

  final double size;
  final Color color;
  final double opacity;
  final double stop;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0)],
              stops: [0.0, stop],
              tileMode: ui.TileMode.decal,
            ),
          ),
        ),
      ),
    );
  }
}
