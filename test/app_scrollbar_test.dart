import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_scrollbar.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/theme/contrast.dart';

/// 6.2 — "Enlarge the scrollbar handle and track in the dashboard UI to make it
/// much easier to click and drag manually."
///
/// Pins the numbers, because a scrollbar is exactly the kind of thing a later
/// theme tidy-up quietly shrinks back to 5px: the web's 14px lane on desktop,
/// always visible, wider on hover, draggable; a thicker, draggable overlay on
/// phones; and a handle that reads against its lane on every palette an owner
/// can pick, dark and light.

const _hovered = <WidgetState>{WidgetState.hovered};
const _dragged = <WidgetState>{WidgetState.dragged};
const _idle = <WidgetState>{};

void _expectDesktop(ScrollbarThemeData t) {
  expect(t.thumbVisibility!.resolve(_idle), isTrue, reason: 'always visible on a desktop till');
  expect(t.trackVisibility!.resolve(_idle), isTrue, reason: 'the lane is drawn, not just the thumb');
  expect(t.interactive, isTrue);
  expect(t.thickness!.resolve(_idle), 10);
  expect(t.thickness!.resolve(_hovered), 14, reason: 'hover WIDENS the handle');
  expect(t.thickness!.resolve(_dragged), 14);
  expect(t.crossAxisMargin, 2);
  // Flutter paints the lane thickness + 2 × margin: the web's 14px.
  expect(t.thickness!.resolve(_idle)! + 2 * t.crossAxisMargin!, AppScrollbar.desktopTrack);
  expect(AppScrollbar.desktopTrack, 14);
  expect(t.minThumbLength, 48);
  expect(t.trackBorderColor!.resolve(_idle), Colors.transparent);
}

void _expectPhone(ScrollbarThemeData t) {
  expect(t.thumbVisibility!.resolve(_idle), isFalse, reason: 'a phone keeps the fading overlay');
  expect(t.trackVisibility!.resolve(_idle), isFalse);
  expect(t.interactive, isTrue, reason: 'Material makes Android bars non-draggable by default');
  expect(t.thickness!.resolve(_idle), 8, reason: 'thicker than the old 5px');
  expect(t.thickness!.resolve(_dragged), 12);
  expect(t.minThumbLength, 48);
}

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppearanceController.instance.debugReset();
  });

  group('the sizing', () {
    test('Windows: a 14px always-visible lane that widens under the pointer', () {
      _expectDesktop(AppScrollbar.theme(
          ink: Colors.white, track: Colors.black, radius: const Radius.circular(8), platform: TargetPlatform.windows));
      expect(AppScrollbar.isDesktop(TargetPlatform.macOS), isTrue);
      expect(AppScrollbar.isDesktop(TargetPlatform.linux), isTrue);
    });

    test('Android: a thicker, draggable overlay — no permanent lane', () {
      _expectPhone(AppScrollbar.theme(
          ink: Colors.white, track: Colors.black, radius: const Radius.circular(8), platform: TargetPlatform.android));
      expect(AppScrollbar.isDesktop(TargetPlatform.iOS), isFalse);
    });

    test('both design systems wear it, dark and light, on the platform they run on', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      _expectDesktop(AppTheme.dark().scrollbarTheme);
      _expectDesktop(GaiaTheme.dark().scrollbarTheme);
      AppColors.applyShell(AppLightPalettes.white);
      _expectDesktop(AppTheme.light().scrollbarTheme);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppearanceController.instance.debugReset();
      _expectPhone(AppTheme.dark().scrollbarTheme);
      _expectPhone(GaiaTheme.dark().scrollbarTheme);
      debugDefaultTargetPlatformOverride = null;
    });

    test('colours are the palette\'s own tokens, not a hardcoded grey', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppColors.applyShell(AppLightPalettes.beige);
      final t = AppTheme.light().scrollbarTheme;
      expect(t.thumbColor!.resolve(_hovered), AppLightPalettes.beige.textSecondary);
      expect(t.thumbColor!.resolve(_idle),
          AppLightPalettes.beige.textSecondary.withValues(alpha: AppScrollbar.restAlpha));
      expect(t.trackColor!.resolve(_idle), AppLightPalettes.beige.border);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the handle reads against its lane (WCAG 1.4.11, 3:1)', () {
    // The resting thumb is the hardest case: hover and drag are the opaque ink.
    void check(String name, {required Color ink, required Color track, required List<Color> grounds}) {
      for (final ground in grounds) {
        final lane = Color.alphaBlend(track, ground);
        final thumb = Color.alphaBlend(ink.withValues(alpha: AppScrollbar.restAlpha), lane);
        expect(contrastRatio(thumb, lane), greaterThanOrEqualTo(3.0),
            reason: '$name: resting thumb on its lane over $ground');
        final hot = Color.alphaBlend(ink, lane);
        expect(contrastRatio(hot, lane), greaterThan(contrastRatio(thumb, lane)),
            reason: '$name: hover must read stronger than rest');
      }
    }

    test('every dark scheme and every light palette', () {
      for (final s in [...AppSchemes.all, AppLightPalettes.white, AppLightPalettes.beige, AppLightPalettes.grey]) {
        check(s.id, ink: s.textSecondary, track: s.border, grounds: [s.bg, s.surface, s.card, s.cardRaised]);
      }
    });

    test('Gaia', () {
      final g = GaiaColors.ground;
      check('gaia', ink: GaiaColors.text2, track: g.line, grounds: [g.bg, g.surface, g.raised]);
    });
  });
}
