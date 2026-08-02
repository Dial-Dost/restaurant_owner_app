import 'package:flutter/widgets.dart';

/// Spacing and shape constants — a strict 4px grid.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double x3l = 32;
  static const double x4l = 40;

  /// Outer padding for every screen body.
  static const EdgeInsets page = EdgeInsets.all(28);
  static const EdgeInsets pageNarrow = EdgeInsets.all(16);

  /// Standard interior padding for cards.
  static const EdgeInsets cardPad = EdgeInsets.all(18);
}

abstract final class AppRadius {
  static const double card = 14;
  static const double control = 10;
  static const double input = 12;
  static const double chip = 999;
  static const double tile = 12;

  static final BorderRadius cardAll = BorderRadius.circular(card);
  static final BorderRadius controlAll = BorderRadius.circular(control);
  static final BorderRadius inputAll = BorderRadius.circular(input);
  static final BorderRadius tileAll = BorderRadius.circular(tile);
}

abstract final class AppDurations {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 350);
}
