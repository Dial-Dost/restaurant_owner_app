import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The label inside a pill, made to survive a narrow parent.
///
/// Every chip in this file is a `Row(mainAxisSize: min)`, which sizes its
/// children to their natural width and then overflows — yellow-and-black
/// stripes — the moment the parent is narrower than that. A tile column, a Wrap
/// run and a 1.3x system text scale all produce exactly that, and patching it at
/// one call site at a time is what let it recur on three different screens.
///
/// So it lives here, once. [Flexible] with a LOOSE fit is deliberate on both
/// sides of the choice:
///   * bounded parent — the label is capped at what is left and ellipsises, so
///     the chip degrades to "12 seats · ma…" instead of overflowing;
///   * unbounded parent (a plain Row, a horizontal scroller) — a loose flex
///     child under `MainAxisSize.min` is laid out at its natural width and does
///     NOT assert, so ample space renders exactly as before.
///
/// Truncation, never scaling: shrinking the glyphs would trade an overflow for
/// type nobody can read, which is the opposite of what a 1.3x scale was asked
/// for. Call sites that carry genuinely unbounded free text still cap the VALUE
/// (and keep the full one a tap away) — that is about meaning, not layout.
class ChipLabel extends StatelessWidget {
  const ChipLabel(this.label, {super.key, required this.style});

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Status chip — tinted pill with a solid dot and a text label.
/// Status is never conveyed by color alone; the label always ships.
///
/// Generic by design: the caller supplies the [color]. (The reference app's
/// enum-extension colors depend on template models that don't exist here.)
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    this.dense = false,
  });

  final String label;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: AppColors.tint(color),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.edge(color)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: dense ? 5 : 6,
            height: dense ? 5 : 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: dense ? 5 : 6),
          ChipLabel(
            label,
            style: TextStyle(
              fontSize: dense ? 10.5 : 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: Color.lerp(color, Colors.white, 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// Quiet metadata chip — icon + text on a recessed pill. Used for dates,
/// categories, table numbers ("📅 Oct 21" style chips in the reference).
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, this.icon, required this.label});

  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.inset,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppColors.textTertiary),
            const SizedBox(width: 5),
          ],
          ChipLabel(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
