import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 6.2 — A SCROLLBAR YOU CAN ACTUALLY GRAB.
///
/// V3: "Enlarge the scrollbar handle and track in the dashboard UI to make it
/// much easier to click and drag manually when standard scrolling is difficult."
///
/// The website did this first (globals.css, "H3 — A SCROLLBAR YOU CAN ACTUALLY
/// GRAB"), and the client's instruction is that the two match, so the numbers
/// here are the web's numbers translated into Flutter's scrollbar geometry:
///
///  * THE TRACK IS 14px, as the web's `::-webkit-scrollbar { width: 14px }`.
///    Flutter paints the track `thickness + 2 × crossAxisMargin` wide, so a 10px
///    thumb inside a 2px margin is that same 14px lane. The old theme drew a
///    5px thumb and no track at all — a target most people miss first time.
///  * HOVER WIDENS IT, it does not only recolour it (web: the thumb's inset
///    border drops from 4px to 2px). "Am I on it" is the signal that matters
///    when you are aiming a mouse on a wet counter.
///  * A 48px MINIMUM HANDLE (web `min-height: 48px`), so a long menu or order
///    list never collapses the thumb to a sliver.
///  * ALWAYS VISIBLE ON DESKTOP. The Windows till is where the mouse is; a
///    scrollbar that only fades in after you have already scrolled is no help
///    to somebody who is reaching for it because scrolling is the difficulty.
///
/// PHONES KEEP AN OVERLAY. The web scopes its rules to the dashboard shell for
/// the same reason: on a phone a permanent grey lane down the side of every list
/// buys nothing. Android therefore gets the platform's fading overlay — but
/// thicker than the 4px Material default, and draggable, which it is not by
/// default on Android.
///
/// COLOURS ARE THE THEME'S OWN TOKENS, never a hardcoded grey: [ink] is the
/// palette's secondary ink (the web's `--muted-foreground`) and [track] its
/// hairline border, so the bar follows every dark scheme and 6.6's light
/// palettes. The resting alpha is 0.8 rather than the web's 0.55 because 0.55
/// falls under 3:1 against the track on Beige and Soft grey (WCAG 1.4.11's
/// floor for a control); app_scrollbar_test.dart pins that for every palette.
abstract final class AppScrollbar {
  /// The full lane on desktop — the web's 14px.
  static const double desktopTrack = 14;

  /// Gap between the thumb and the track's edge on each side.
  static const double crossAxisMargin = 2;

  /// Resting thumb on desktop: fills the 14px lane less its margins.
  static const double desktopThumb = desktopTrack - 2 * crossAxisMargin;

  /// Hovered / dragged thumb on desktop.
  static const double desktopThumbActive = 14;

  /// Phone overlay thumb — double the old 4–5px, still slim enough to sit over
  /// content while it fades.
  static const double phoneThumb = 8;

  /// Phone thumb while a finger is dragging it.
  static const double phoneThumbActive = 12;

  /// The web's `min-height: 48px`.
  static const double minThumbLength = 48;

  /// Resting thumb alpha over [track]; see the class note for why not 0.55.
  static const double restAlpha = 0.8;

  /// Windows, macOS and Linux: a mouse is the expected pointer.
  static bool isDesktop(TargetPlatform platform) => switch (platform) {
        TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
      };

  /// The one scrollbar theme both design systems wear. [platform] defaults to
  /// the one the app is running on; tests pass it explicitly.
  static ScrollbarThemeData theme({
    required Color ink,
    required Color track,
    required Radius radius,
    TargetPlatform? platform,
  }) {
    final desktop = isDesktop(platform ?? defaultTargetPlatform);
    bool active(Set<WidgetState> s) =>
        s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged);
    return ScrollbarThemeData(
      thumbVisibility: WidgetStateProperty.all(desktop),
      trackVisibility: WidgetStateProperty.all(desktop),
      interactive: true,
      thickness: WidgetStateProperty.resolveWith((s) => desktop
          ? (active(s) ? desktopThumbActive : desktopThumb)
          : (active(s) ? phoneThumbActive : phoneThumb)),
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => active(s) ? ink : ink.withValues(alpha: restAlpha)),
      trackColor: WidgetStateProperty.all(track),
      // No outline: the track's own fill is the lane, and a second stroke
      // down its edge reads as a divider between the list and the bar.
      trackBorderColor: WidgetStateProperty.all(Colors.transparent),
      radius: radius,
      crossAxisMargin: crossAxisMargin,
      minThumbLength: minThumbLength,
    );
  }
}
