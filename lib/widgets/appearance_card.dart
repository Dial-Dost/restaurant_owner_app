import 'package:flutter/material.dart';

import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/theme/appearance.dart';
import '../ui/widgets/fork_card.dart';

/// "Appearance — this device": the owner-app accent picker.
///
/// Per-DEVICE on purpose (SharedPreferences, never the server): two tills of
/// one restaurant may deliberately wear different accents so staff can tell
/// the machines apart at a glance, and chrome has no business in the tenant's
/// audited settings. See AppearanceController for the full argument.
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
        final current = AppearanceController.instance.accentId;
        return ForkCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('App accent', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recolours this app on THIS device only — guests and other tills are untouched. '
              'Every choice keeps the dark Rustic Fork ground and stays readable (all pass WCAG AA).',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final a in AppAccents.all)
                _AccentSwatch(
                  accent: a,
                  selected: a.id == current,
                  onTap: () => AppearanceController.instance.setAccent(a.id),
                ),
            ]),
          ]),
        );
      },
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
