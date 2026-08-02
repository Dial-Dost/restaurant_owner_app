import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Elegant empty state — bordered icon tile, title, quiet caption,
/// optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.caption,
    this.action,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x4l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.inset,
                borderRadius: AppRadius.tileAll,
                border: Border.all(color: AppColors.borderStrong),
              ),
              child: Icon(icon, size: 24, color: AppColors.copperHi),
            ),
            const SizedBox(height: 18),
            Text(title, style: text.titleMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                caption,
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
