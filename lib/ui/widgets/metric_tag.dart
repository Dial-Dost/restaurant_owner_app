import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'status_chip.dart';

/// The reference design's "| Hig" / "| Lo" corner tag — a short copper tick
/// followed by a tiny label.
class TickTag extends StatelessWidget {
  const TickTag(this.label, {super.key, this.color});

  final String label;

  /// null = the active accent (AppColors.copperHi is a getter now — the
  /// device's appearance accent — so it cannot be a const default).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.copperHi;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 2.5,
          height: 11,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        // Same rule as the pills in status_chip.dart — a tick sits beside a
        // StatusChip in the same narrow tile row, so it has to give way too.
        ChipLabel(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

/// Tiny stacked metadata: value with a letter-spaced micro label underneath
/// (the "30,000 / CROWD SIZE" pattern from the reference top bar).
class MicroStat extends StatelessWidget {
  const MicroStat({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.alignEnd = false,
  });

  final String value;
  final String label;
  final IconData? icon;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: AppColors.textSecondary),
              const SizedBox(width: 5),
            ],
            ChipLabel(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        // The caption wraps rather than truncates — it is the only place the
        // stat says WHAT it is, and a Column child is already width-bounded.
        Text(label.toUpperCase(), style: text.labelSmall),
      ],
    );
  }
}

/// Small up/down delta text — "▲ 12.4% vs last week".
class DeltaText extends StatelessWidget {
  const DeltaText({
    super.key,
    required this.pct,
    this.suffix = '',
    this.invert = false,
  });

  /// Positive is good by default; set [invert] when a rise is bad.
  final double pct;
  final String suffix;
  final bool invert;

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final good = invert ? !up : up;
    final color = good ? AppColors.success : AppColors.danger;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
          size: 16,
          color: color,
        ),
        Text(
          '${pct.abs().toStringAsFixed(1)}%$suffix',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}
