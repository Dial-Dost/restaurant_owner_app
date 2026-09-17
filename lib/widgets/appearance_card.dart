import 'package:flutter/material.dart';

import '../ui/gaia/gaia.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/theme/appearance.dart';
import '../ui/theme/backdrop_style.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/gradient_backdrop.dart';

/// "Appearance — this device": the owner-app shell scheme + accent picker.
///
/// Per-DEVICE on purpose (SharedPreferences, never the server): two tills of
/// one restaurant may deliberately wear different schemes/accents so staff can
/// tell the machines apart at a glance, and chrome has no business in the
/// tenant's audited settings. See AppearanceController for the full argument.
class AppearanceCard extends StatelessWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Listens directly so THIS card repaints its selection ring immediately;
    // the app root rebuilds the rest of the app from the same notifier.
    return AnimatedBuilder(
      animation: AppearanceController.instance,
      builder: (context, _) {
        final ctl = AppearanceController.instance;
        final gaiaOn = ctl.designSystem == DesignSystem.gaia;
        return ForkCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Appearance', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recolours this app on THIS device only — guests and other tills are untouched. '
              'Scheme and accent mix freely: every combination is pre-checked to stay readable (WCAG AA).',
              style: text.bodySmall,
            ),

            // ── 6.6 — the interface theme. Same three choices as the top
            // bar's toggle (and the web dashboard's dark/light switch).
            const SizedBox(height: AppSpacing.lg),
            Text('THEME', style: text.labelSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _ThemeSwatch(
                pick: 'dark',
                label: 'Dark',
                palette: AppColors.rusticShell,
                selected: ctl.themePick == 'dark',
                onTap: () => ctl.applyThemePick('dark'),
              ),
              for (final t in LightTone.values)
                _ThemeSwatch(
                  pick: t.id,
                  label: 'Light — ${t.label}',
                  palette: AppLightPalettes.of(t),
                  selected: ctl.themePick == t.id,
                  onTap: () => ctl.applyThemePick(t.id),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              ctl.lightMode && gaiaOn
                  ? 'Gaia keeps its own dark palette, so light is remembered '
                      'and applies when Rustic Fork is back on.'
                  : ctl.lightMode
                      ? 'Light keeps your accent (deepened so it stays readable on a pale page). '
                          'The shell schemes below are dark variants — remembered, and back when you pick Dark.'
                      : 'Picking a light colour switches to light; Dark remembers it for next time. '
                          'Same choices as the website.',
              style: text.bodySmall,
            ),

            // ── The design system, first: it is the biggest choice on this
            // card, and the two below it are choices WITHIN the Rustic system.
            const SizedBox(height: AppSpacing.lg),
            Text('DESIGN SYSTEM', style: text.labelSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final d in DesignSystem.values)
                _DesignSwatch(
                  system: d,
                  selected: d == ctl.designSystem,
                  onTap: () => ctl.setDesignSystem(d),
                ),
            ]),
            const SizedBox(height: 8),
            Text(
              gaiaOn
                  // Said plainly because it is the one surprising thing about
                  // the switch: the pickers below still WORK, they just do not
                  // paint anything while Gaia is on.
                  ? 'Gaia brings its own palette (forest and champagne) and its own type, '
                      'so the scheme and accent below are remembered but not applied. '
                      'Switch back to Rustic Fork and they return exactly as they were.'
                  : 'Rustic Fork is the shipped look. Gaia is a complete alternative — '
                      'different palette, type and shapes — and switching is instant and reversible.',
              style: text.bodySmall,
            ),

            const SizedBox(height: AppSpacing.lg),
            Opacity(
              opacity: gaiaOn ? 0.45 : 1,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SHELL SCHEME', style: text.labelSmall),
                const SizedBox(height: 8),
                // 6.6 — the schemes are dark shells; under a light theme they
                // are dimmed the way Gaia dims the whole block.
                Opacity(
                  opacity: ctl.lightActive ? 0.45 : 1,
                  child: Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final s in AppSchemes.all)
                      _SchemeSwatch(
                        scheme: s,
                        selected: s.id == ctl.schemeId,
                        onTap: () => ctl.setScheme(s.id),
                      ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('ACCENT', style: text.labelSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final a in AppAccents.all)
                    _AccentSwatch(
                      accent: a,
                      selected: a.id == ctl.accentId,
                      onTap: () => ctl.setAccent(a.id),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('BACKDROP', style: text.labelSmall),
            const SizedBox(height: 8),
            // The style is a FIELD, not read inside, so this subtree can never
            // be `const` — an identical instance would short-circuit
            // Element.updateChild and freeze the sliders/preview on their
            // first-build values while the controller moves on.
            if (gaiaOn)
              Text(
                'Gaia has no backdrop — its depth comes from flat grounds and hairlines, '
                'so there is nothing here to mix. These settings are kept for Rustic Fork.',
                style: text.bodySmall,
              )
            else
              _BackdropControls(style: ctl.backdrop),
          ]),
        );
      },
    );
  }
}

/// The backdrop mixer: pick the wash and bloom stops (accent-derived tones or
/// a custom hex), set the wash angle and the overall intensity — previewed
/// live in a miniature of the real backdrop, because the real backdrop sits
/// BEHIND the module being edited and the change there is easy to miss.
///
/// Every control writes straight through AppearanceController.setBackdrop, so
/// the preview, the shell behind it, and persistence can never disagree. The
/// wash/bloom extremes an owner can reach are AA-guarded in resolveBackdrop —
/// picking white does not buy an unreadable header, it buys as much white as
/// the ink can carry.
class _BackdropControls extends StatelessWidget {
  const _BackdropControls({required this.style});

  final BackdropStyle style;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ctl = AppearanceController.instance;
    final accent = ctl.accent;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // The miniature: the real GradientBackdrop (same widget, same resolver),
      // with the two body inks sitting on its brightest region so the owner
      // SEES the readability the guard is promising.
      //
      // It is 116px whatever the device, so its ink samples keep one line and
      // ignore the device's text size: on a 360dp phone they wrapped past the
      // bottom even at 1x, and by 82px at 1.3x.
      MediaQuery.withNoTextScaling(
        child: ClipRRect(
          key: const ValueKey('backdrop-preview'),
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 116,
            child: GradientBackdrop(
              heroHeight: 116,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Rustic Fork', style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('Covers 42 · APC ₹512 · 6 open bills',
                      style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: AppColors.cardGradient,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text('Live preview — this is your backdrop',
                        style: text.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _StopRow(
        label: 'WASH',
        current: style.wash,
        // The wash wants DEPTH: the glow trio plus the ramp's two dark ends.
        options: [accent.glowDeep, accent.glowMid, accent.glowBright, accent.shadow],
        defaultTone: accent.glowDeep,
        onPick: (c) => ctl.setBackdrop(style.copyWith(wash: c)),
      ),
      const SizedBox(height: 8),
      _StopRow(
        label: 'BLOOM',
        current: style.bloom,
        // The bloom wants LIGHT: the bright glows plus the ramp's readable top.
        options: [accent.glowBright, accent.glowMid, accent.glowDeep, accent.hi],
        defaultTone: accent.glowBright,
        onPick: (c) => ctl.setBackdrop(style.copyWith(bloom: c)),
      ),
      const SizedBox(height: 10),
      _SliderRow(
        label: 'ANGLE',
        value: style.angleDeg,
        min: 0,
        max: 360,
        display: '${style.angleDeg.round()}°',
        onChanged: (v) => ctl.setBackdrop(style.copyWith(angleDeg: v)),
      ),
      _SliderRow(
        label: 'INTENSITY',
        value: style.intensity,
        min: 0,
        max: 1,
        display: '${(style.intensity * 100).round()}%',
        onChanged: (v) => ctl.setBackdrop(style.copyWith(intensity: v)),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: style.isDefault
              ? null
              : () => ctl.setBackdrop(const BackdropStyle()),
          icon: const Icon(Icons.replay, size: 14),
          label: const Text('Back to scheme default'),
        ),
      ),
    ]);
  }
}

/// One stop's choices: "follow the accent" first, the derived tones, then a
/// hex field for anything else. Selection is by VALUE (a pinned tone equal to
/// a derived one lights that swatch), and the default swatch is only "on"
/// while the stop is genuinely null — following, not merely matching.
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.label,
    required this.current,
    required this.options,
    required this.defaultTone,
    required this.onPick,
  });

  final String label;
  final Color? current; // null = follow the accent
  final List<Color> options;
  final Color defaultTone;
  final ValueChanged<Color?> onPick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget dot(Color c, {required bool selected, required VoidCallback onTap, String? tip}) {
      final swatch = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppDurations.fast,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              border: Border.all(
                color: selected ? AppColors.copperHi : AppColors.borderStrong,
                width: selected ? 2 : 1,
              ),
            ),
          ),
        ),
      );
      return tip == null ? swatch : Tooltip(message: tip, child: swatch);
    }

    return Row(children: [
      SizedBox(width: 64, child: Text(label, style: text.labelSmall)),
      dot(defaultTone,
          selected: current == null,
          onTap: () => onPick(null),
          tip: 'Follow the accent'),
      const SizedBox(width: 6),
      for (final c in options) ...[
        dot(c, selected: current == c, onTap: () => onPick(c)),
        const SizedBox(width: 6),
      ],
      const SizedBox(width: 4),
      Expanded(child: _HexField(current: current, onSubmit: onPick)),
    ]);
  }
}

/// A six-digit hex entry for a custom stop. Applies on submit; junk is
/// ignored rather than half-applied (the same posture the guest branding
/// editor takes with its hex field).
class _HexField extends StatefulWidget {
  const _HexField({required this.current, required this.onSubmit});

  final Color? current;
  final ValueChanged<Color?> onSubmit;

  @override
  State<_HexField> createState() => _HexFieldState();
}

class _HexFieldState extends State<_HexField> {
  final TextEditingController _text = TextEditingController();
  static final RegExp _hexRe = RegExp(r'^#?([0-9a-fA-F]{6})$');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _apply(String raw) {
    final m = _hexRe.firstMatch(raw.trim());
    if (m == null) return;
    widget.onSubmit(Color(0xFF000000 | int.parse(m.group(1)!, radix: 16)));
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    final hint = cur == null
        ? '#custom'
        : '#${(cur.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return TextField(
      controller: _text,
      onSubmitted: _apply,
      style: Theme.of(context).textTheme.bodySmall,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(children: [
      SizedBox(width: 64, child: Text(label, style: text.labelSmall)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: AppColors.copper,
          inactiveColor: AppColors.inset,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 44,
        child: Text(display, textAlign: TextAlign.right, style: text.bodySmall),
      ),
    ]);
  }
}

/// A miniature of the shell a scheme paints: its ground, one card with the
/// primary/secondary ink bars, so the choice is legible BEFORE it is applied —
/// five dark rectangles with bare labels would all read as "black".
class _SchemeSwatch extends StatelessWidget {
  const _SchemeSwatch({required this.scheme, required this.selected, required this.onTap});

  final AppShellScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget inkBar(Color c, double w) => Container(
          width: w,
          height: 3,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
        );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: selected ? null : onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: AppDurations.fast,
            width: 64,
            height: 44,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              // The selection ring wears the ACTIVE accent, exactly like the
              // accent swatches, so "selected" reads the same in both rows.
              border: Border.all(
                color: selected ? AppColors.copperHi : AppColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.card,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.border, width: 0.5),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      inkBar(scheme.textPrimary, 26),
                      const SizedBox(height: 3),
                      inkBar(scheme.textSecondary, 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            scheme.label,
            style: text.labelSmall!.copyWith(
              color: selected ? AppColors.textPrimary : AppColors.textTertiary,
              letterSpacing: 0.4,
            ),
          ),
        ]),
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.accent, required this.selected, required this.onTap});

  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: selected ? null : onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: AppDurations.fast,
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? accent.hi : AppColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent.hi, accent.mid],
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 18, color: accent.on)
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            accent.label,
            style: text.labelSmall!.copyWith(
              color: selected ? AppColors.textPrimary : AppColors.textTertiary,
              letterSpacing: 0.4,
            ),
          ),
        ]),
      ),
    );
  }
}


/// A miniature of what each design system paints: its ground, a card on it,
/// its accent, and — the thing that actually distinguishes them — a figure set
/// in that system's own display face. Someone choosing between these is
/// choosing about type as much as colour, so the swatch has to show type.
class _DesignSwatch extends StatelessWidget {
  const _DesignSwatch({
    required this.system,
    required this.selected,
    required this.onTap,
  });

  final DesignSystem system;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gaia = system == DesignSystem.gaia;

    // Each swatch paints its OWN system's colours, not the live ones, so both
    // previews stay truthful whichever system is currently on.
    final ground = gaia ? GaiaColors.bg : AppColors.rusticShell.bg;
    final surface = gaia ? GaiaColors.surface : AppColors.rusticShell.card;
    final accent = gaia ? GaiaColors.champagne : AppColors.rusticCopper.base;
    final line = gaia ? GaiaColors.line : const Color(0x12FFFFFF);
    final ink = gaia ? GaiaColors.text : AppColors.rusticShell.textPrimary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('design-swatch-${system.id}'),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A picture of the system at a fixed 122x82, so its sample figure
            // keeps the size it was drawn at: at 2x text it grew taller than the
            // box. The name under it scales with the device.
            MediaQuery.withNoTextScaling(
              child: Container(
                width: 122,
                height: 82,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: ground,
                  // The selection ring wears the ACTIVE accent, the same rule
                  // the scheme and accent swatches follow.
                  border: Border.all(
                    color: selected ? AppColors.copperHi : AppColors.border,
                    width: selected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(gaia ? 2 : 10),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(
                    color: surface,
                    border: Border.all(color: line),
                    // The corner radius is itself part of the preview: 2px vs
                    // 14px is the most visible single difference between them.
                    borderRadius: BorderRadius.circular(gaia ? 2 : 8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '1,248',
                        maxLines: 1,
                        style: gaia
                            ? GaiaType.serif(
                                size: 26,
                                weight: 500,
                                height: 1,
                                color: GaiaColors.champagne2)
                            : TextStyle(
                                fontSize: 24,
                                height: 1,
                                fontWeight: FontWeight.w300,
                                letterSpacing: -0.8,
                                color: ink,
                              ),
                      ),
                      const SizedBox(height: 7),
                      Container(width: 44, height: 3, color: accent),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              system.label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 6.6 — a miniature of each interface theme: its page ground, a card with the
/// two body inks, and a stroke of the accent as it would paint there. Each
/// swatch draws its OWN palette (not the live one), so all four stay truthful
/// whichever is on.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.pick,
    required this.label,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final String pick;
  final String label;
  final AppShellScheme palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = palette.brightness == Brightness.light
        ? AppLightPalettes.accentFor(AppColors.rusticCopper, palette)
        : AppColors.rusticCopper;
    Widget inkBar(Color c, double w) => Container(
          width: w,
          height: 3,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
        );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('theme-swatch-$pick'),
        onTap: selected ? null : onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: AppDurations.fast,
            width: 88,
            height: 52,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected ? AppColors.copperHi : AppColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: palette.border, width: 0.5),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      inkBar(palette.textPrimary, 34),
                      const SizedBox(height: 3),
                      inkBar(palette.textSecondary, 22),
                      const SizedBox(height: 3),
                      inkBar(accent.base, 14),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: text.labelSmall!.copyWith(
              color: selected ? AppColors.textPrimary : AppColors.textTertiary,
              letterSpacing: 0.4,
            ),
          ),
        ]),
      ),
    );
  }
}
