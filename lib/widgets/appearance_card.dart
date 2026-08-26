import 'package:flutter/material.dart';

import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/theme/appearance.dart';
import '../ui/widgets/fork_card.dart';

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
        return ForkCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Appearance', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recolours this app on THIS device only — guests and other tills are untouched. '
              'Scheme and accent mix freely: every combination is pre-checked to stay readable (WCAG AA).',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('SHELL SCHEME', style: text.labelSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final s in AppSchemes.all)
                _SchemeSwatch(
                  scheme: s,
                  selected: s.id == ctl.schemeId,
                  onTap: () => ctl.setScheme(s.id),
                ),
            ]),
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
        );
      },
    );
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
