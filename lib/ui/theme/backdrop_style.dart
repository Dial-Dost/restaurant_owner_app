import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'contrast.dart';

/// The owner's backdrop knobs: which two tones the shell's gradient wears,
/// which way the wash runs, and how much of it there is.
///
/// Per-DEVICE like the rest of appearance (see AppearanceController). All four
/// knobs default to "whatever the accent says" — `null` stops mean the glow
/// ramp keeps driving, so picking a new accent keeps restyling the backdrop
/// until the owner deliberately pins a colour.
@immutable
class BackdropStyle {
  const BackdropStyle({
    this.wash,
    this.bloom,
    this.angleDeg = defaultAngle,
    this.intensity = 1.0,
  });

  /// The guest page's hero runs at CSS 150deg (top-left toward bottom-right);
  /// that stays the untouched default.
  static const double defaultAngle = 150;

  /// Stop A — the hero wash (and the far ambient orb). Null = accent glowDeep.
  final Color? wash;

  /// Stop B — the corner bloom (and the near ambient orb). Null = accent
  /// glowBright for the bloom, glowMid for the orb — the shipped trio.
  final Color? bloom;

  /// CSS convention (0° points up, clockwise), because the default IS the
  /// guest page's CSS gradient and the two must keep meaning the same thing.
  final double angleDeg;

  /// 0..1: how hard the warmth is allowed to lean on the page. 1 is the
  /// shipped look; 0 is a flat scheme ground.
  final double intensity;

  bool get isDefault =>
      wash == null && bloom == null && angleDeg == defaultAngle && intensity == 1.0;

  static const Object _unset = Object();

  BackdropStyle copyWith({
    Object? wash = _unset,
    Object? bloom = _unset,
    double? angleDeg,
    double? intensity,
  }) =>
      BackdropStyle(
        wash: identical(wash, _unset) ? this.wash : wash as Color?,
        bloom: identical(bloom, _unset) ? this.bloom : bloom as Color?,
        angleDeg: angleDeg ?? this.angleDeg,
        intensity: intensity ?? this.intensity,
      );

  @override
  bool operator ==(Object other) =>
      other is BackdropStyle &&
      other.wash == wash &&
      other.bloom == bloom &&
      other.angleDeg == angleDeg &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(wash, bloom, angleDeg, intensity);
}

/// What the backdrop actually paints once the style, the active glow ramp and
/// the active shell scheme are composed — with the AA guard already applied.
///
/// A pure value computed by [resolveBackdrop] so the guard is TESTABLE against
/// the whole matrix plus arbitrary custom stops, instead of living as
/// arithmetic buried in a build method.
@immutable
class ResolvedBackdrop {
  const ResolvedBackdrop({
    required this.washColor,
    required this.washBegin,
    required this.washEnd,
    required this.bloomColor,
    required this.bloomOpacity,
    required this.orbNearColor,
    required this.orbNearOpacity,
    required this.orbFarColor,
    required this.orbFarOpacity,
  });

  /// The hero wash's opaque top stop: the chosen tone pre-composited onto the
  /// scheme ground at the guarded alpha. Text can sit directly on THIS.
  final Color washColor;
  final Alignment washBegin;
  final Alignment washEnd;

  final Color bloomColor;
  final double bloomOpacity;
  final Color orbNearColor;
  final double orbNearOpacity;
  final Color orbFarColor;
  final double orbFarOpacity;
}

/// Compose style x glow ramp x scheme, clamping the two places a hand-picked
/// stop could put text on an unreadable extreme:
///
///  * the wash's top stop — an owner can type #FFFFFF; at full strength that
///    is a white page under warm-white ink. Its blend alpha is capped so the
///    composite keeps [ink] at AA 4.5:1 (the shipped glow tones pass at full
///    alpha, so the default look does not move);
///  * the corner bloom — its centre sits on screen under the app bar, so its
///    opacity is capped against the wash it floats on, same floor.
///
/// The ambient orbs get the same cap against the ground for symmetry; at
/// their shipped 0.22 they never hit it.
ResolvedBackdrop resolveBackdrop({
  required BackdropStyle style,
  required Color glowBright,
  required Color glowMid,
  required Color glowDeep,
  required Color bg,
  required Color ink,
}) {
  final washStop = style.wash ?? glowDeep;
  final bloomStop = style.bloom ?? glowBright;
  final orbNearStop = style.bloom ?? glowMid;
  final orbFarStop = style.wash ?? glowDeep;
  final intensity = style.intensity.clamp(0.0, 1.0);

  final washAlpha = maxAlphaForContrast(tint: washStop, ground: bg, ink: ink, max: intensity);
  final washColor = Color.alphaBlend(washStop.withValues(alpha: washAlpha), bg);

  final bloomOpacity = maxAlphaForContrast(
      tint: bloomStop, ground: washColor, ink: ink, max: 0.34 * intensity);
  final orbNearOpacity =
      maxAlphaForContrast(tint: orbNearStop, ground: bg, ink: ink, max: 0.22 * intensity);
  final orbFarOpacity =
      maxAlphaForContrast(tint: orbFarStop, ground: bg, ink: ink, max: 0.22 * intensity);

  // CSS angle -> the same axis the way Flutter wants it: 0° points up, so the
  // paint direction is (sin a, -cos a) with screen-y running down; scale so
  // the longer component reaches the edge, which is how CSS corners behave.
  final rad = style.angleDeg * math.pi / 180;
  var dx = math.sin(rad), dy = -math.cos(rad);
  final m = math.max(dx.abs(), dy.abs());
  if (m < 1e-9) {
    dx = 0;
    dy = 1;
  } else {
    dx /= m;
    dy /= m;
  }

  return ResolvedBackdrop(
    washColor: washColor,
    washBegin: Alignment(-dx, -dy),
    washEnd: Alignment(dx, dy),
    bloomColor: bloomStop,
    bloomOpacity: bloomOpacity,
    orbNearColor: orbNearStop,
    orbNearOpacity: orbNearOpacity,
    orbFarColor: orbFarStop,
    orbFarOpacity: orbFarOpacity,
  );
}
