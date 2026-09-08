import 'package:flutter/widgets.dart';

/// GAIA spacing, read off the mockup's own rhythm rather than a 4px grid.
///
/// The design has ONE horizontal margin — 24px — and everything on a screen
/// hangs off it: `.sec`, `.list`, `.card`, `.stats`, `.rule`, `.tabs`, `.btns`,
/// `.grid-t` all use `padding:… 24px` or `margin:… 24px`. That single gutter is
/// what makes the hairlines line up down the page, and it is the first thing to
/// preserve.
///
/// Vertical rhythm is looser and deliberately uneven: 26 above a first section,
/// 22 between sections, 18 inside a card, 16 for a list row, 12 between cards.
abstract final class GaiaSpacing {
  /// `.sec{padding:26px 24px 0}` — the one gutter.
  static const double gutter = 24;

  /// `.sec+.sec{padding-top:22px}` — between stacked sections.
  static const double section = 22;

  /// `.sec{padding-top:26px}` — above the first section under a header.
  static const double sectionFirst = 26;

  /// `.card+.card{margin-top:12px}` / `.two{gap:12px}`.
  static const double cardGap = 12;

  /// `.item{padding:16px 0}` — a hairline list row's vertical padding.
  static const double rowY = 16;

  /// `.kv{padding:12px 0}` / `.tick{padding:12px 0}`.
  static const double kvY = 12;

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double xxl = 26;

  /// `.card{padding:18px 18px 16px}` — note the asymmetry; the design sets a
  /// card's floor one step tighter than its ceiling.
  static const EdgeInsets cardPad =
      EdgeInsets.only(left: 18, right: 18, top: 18, bottom: 16);

  /// The page gutter as insets. Vertical padding is 0 on purpose: sections
  /// bring their own top space, which is how the mockup avoids a double gap
  /// under the title block.
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: gutter);

  /// `.tabbar{height:92px;padding-top:18px}`.
  static const double tabBarHeight = 92;

  /// `.btn{height:52px}` / `.btn.sm{height:40px}`.
  static const double buttonHeight = 52;
  static const double buttonHeightDense = 40;

  /// `.search{height:46px}` / `.deno input{height:38px}`.
  static const double fieldHeight = 46;
  static const double fieldHeightDense = 38;
}

/// GAIA shape. There is essentially one radius in this design and it is 2px —
/// `.btn`, `.card`, `.pill`, `.plan`, `.tbl` and the sidebar rows all use it.
/// Anything rounder is a CIRCLE (dots, avatars, the toggle knob, the ring), not
/// a softened rectangle. Reproducing that literally is most of what separates
/// the Gaia look from the Rustic Fork one, whose radii run 10-14px.
abstract final class GaiaRadius {
  static const double edge = 2;
  static const double circle = 999;

  static const BorderRadius all = BorderRadius.all(Radius.circular(edge));
  static const BorderRadius none = BorderRadius.zero;

  /// The hairline weight. Every separation in the design is exactly 1px; the
  /// only 2px stroke is `.card.warn`'s left rail.
  static const double hairline = 1;
  static const double railStroke = 2;
}

abstract final class GaiaDurations {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);
}
