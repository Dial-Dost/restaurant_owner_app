import 'dart:math' as math;
import 'dart:ui';

/// WCAG 2.x contrast math, shared by the LIVE theme — not just the tests.
///
/// The accent and shell-scheme catalogues are AA-checked offline, but two
/// surfaces are COMPOSED at runtime from owner choices (accent x scheme x
/// backdrop), so their worst case cannot be enumerated at design time:
///
///  * the phone drawer's opaque glow, derived from whatever glow ramp the
///    device wears (sage/teal glows run brighter than copper's and graze the
///    4.5:1 floor at the copper-tuned alpha), and
///  * the gradient backdrop's hero wash, whose stop the owner can set to any
///    hex at all.
///
/// Those call sites clamp with [maxAlphaForContrast] instead of hoping,
/// mirroring what the backend's brand_theme.ts does for guest text/bg pairs.
double relativeLuminance(Color c) {
  double chan(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b);
}

double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a), lb = relativeLuminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// The largest alpha (<= [max]) at which [tint] blended over [ground] still
/// leaves [ink] readable at [floor]. Alpha up = surface brighter = contrast
/// with a light ink down, monotonically, so a binary search converges from the
/// passing side — the answer PASSES the floor by construction, it does not
/// merely approach it. Rounding to display bytes happens inside the probe
/// (Color.alphaBlend), so the guarantee holds for the pixels actually painted.
double maxAlphaForContrast({
  required Color tint,
  required Color ground,
  required Color ink,
  double floor = 4.5,
  double max = 1.0,
}) {
  bool passes(double a) =>
      contrastRatio(ink, Color.alphaBlend(tint.withValues(alpha: a), ground)) >= floor;
  if (passes(max)) return max;
  var lo = 0.0, hi = max;
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    if (passes(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}
