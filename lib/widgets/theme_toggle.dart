import 'package:flutter/material.dart';

import '../ui/theme/app_colors.dart';
import '../ui/theme/appearance.dart';

/// 6.6 — DARK OR LIGHT, AND WHICH LIGHT: the top bar's theme toggle.
///
/// The web dashboard's toggle (components/ThemeToggle.tsx) is one sun/moon
/// button in its header that opens a short menu:
///
///   Dark
///   ── Light ──
///   White | Beige | Soft grey   (each with a swatch of its real ground)
///
/// The client asked for the web and the app to match, so the app carries the
/// same button in the same place with the same rows, ticks and rules: picking a
/// tone switches to light, picking Dark keeps the tone for next time (see
/// AppearanceController.applyThemePick). It is a menu rather than a flip because
/// the tone only means something in light mode — a separate "beige" control
/// that did nothing in dark mode would look broken.
///
/// Per DEVICE, like the rest of appearance. The same choices also sit on the
/// Settings › Appearance card.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppearanceController.instance,
      builder: (context, _) {
        final ctl = AppearanceController.instance;
        return PopupMenuButton<String>(
          key: const ValueKey('theme-toggle'),
          tooltip: ctl.lightMode ? 'Theme: Light — ${ctl.lightTone.label}' : 'Theme: Dark',
          color: AppColors.cardRaised,
          icon: Icon(
            ctl.lightMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            color: AppColors.textSecondary,
          ),
          onSelected: ctl.applyThemePick,
          itemBuilder: (_) => themeMenuEntries<String>(context, valueOf: (pick) => pick),
        );
      },
    );
  }
}

/// The theme rows as popup entries, shared by [ThemeToggleButton] and the
/// phone chrome's folded overflow menu so the two can never list different
/// options. [valueOf] maps a pick (`'dark'` or a [LightTone] id) to the menu's
/// value (the overflow menu namespaces its string values).
List<PopupMenuEntry<T>> themeMenuEntries<T>(
  BuildContext context, {
  required T Function(String pick) valueOf,
}) {
  final ctl = AppearanceController.instance;
  final text = Theme.of(context).textTheme;
  final active = ctl.themePick;
  Widget tick(bool on) => on
      ? Icon(Icons.check, size: 16, color: AppColors.copperHi, semanticLabel: 'Selected')
      : const SizedBox(width: 16);

  return [
    PopupMenuItem<T>(
      key: const ValueKey('theme-option-dark'),
      value: valueOf('dark'),
      child: Row(children: [
        Icon(Icons.dark_mode_outlined, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 10),
        const Expanded(child: Text('Dark')),
        tick(active == 'dark'),
      ]),
    ),
    const PopupMenuDivider(),
    PopupMenuItem<T>(
      enabled: false,
      height: 32,
      child: Row(children: [
        Icon(Icons.light_mode_outlined, size: 14, color: AppColors.textTertiary),
        const SizedBox(width: 8),
        Text('LIGHT', style: text.labelSmall),
      ]),
    ),
    for (final t in LightTone.values)
      PopupMenuItem<T>(
        key: ValueKey('theme-option-${t.id}'),
        value: valueOf(t.id),
        height: 52,
        child: Row(children: [
          // The swatch is the real ground colour — "beige" and "soft grey"
          // are words, and this menu is where they are first seen.
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppLightPalettes.of(t).bg,
              border: Border.all(color: AppLightPalettes.of(t).borderStrong),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.label),
                Text(t.hint, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          tick(active == t.id),
        ]),
      ),
    // Said plainly, because it is the one case where picking does not repaint:
    // Gaia is a complete dark design with no light variant. The choice is kept
    // and lands the moment Rustic Fork is back on.
    if (ctl.designSystem == DesignSystem.gaia)
      PopupMenuItem<T>(
        enabled: false,
        height: 40,
        child: Text(
          'Gaia keeps its own dark palette — switch to Rustic Fork in Settings › Appearance to use light.',
          style: text.bodySmall,
        ),
      ),
  ];
}
