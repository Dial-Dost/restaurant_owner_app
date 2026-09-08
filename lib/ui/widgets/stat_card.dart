import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';
import 'fork_card.dart';
import 'metric_tag.dart';

/// The reference stat card: oversized light-weight value with a raised
/// unit, a "| Hig / | Lo" tick tag, a copper chart in the middle and a
/// quiet caption at the bottom.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.value,
    this.unit,
    required this.caption,
    this.tag,
    this.tagColor,
    this.chart,
    this.footer,
    this.onTap,
  });

  /// The big number, already formatted ("4,820", "87").
  final String value;

  /// Small raised unit after the value ("%", "Clients", "\$").
  final String? unit;

  /// Bottom caption ("Average Attendance (%)" style).
  final String caption;

  /// Corner tick-tag text ("Hig", "Lo", "Live").
  final String? tag;
  /// null = the active accent (AppColors.copperHi is a getter now — the
  /// device's appearance accent — so it cannot be a const default).
  final Color? tagColor;

  /// Chart slot — typically [CopperBarcode] or [WeekdayBars].
  final Widget? chart;

  /// Optional row under the caption (delta text, etc.).
  final Widget? footer;

  /// When set the tile becomes a control: the [ForkCard] hover lift, a
  /// brightened border and a click cursor. Used for drill-down stat tiles.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (Gaia.of(context)) return _gaia(context);

    final text = Theme.of(context).textTheme;
    return ForkCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  text: TextSpan(
                    text: value,
                    style: text.displayMedium,
                    children: [
                      if (unit != null)
                        TextSpan(
                          text: ' $unit',
                          style: text.bodySmall!.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (tag != null) TickTag(tag!, color: tagColor ?? AppColors.copperHi),
            ],
          ),
          if (chart != null) ...[
            const SizedBox(height: 16),
            chart!,
          ],
          const SizedBox(height: 12),
          Text(
            caption,
            style: text.bodySmall!.copyWith(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: 6),
            footer!,
          ],
        ],
      ),
    );
  }

  /// The Gaia tile. Same information, the design's own order and voice:
  /// the figure first and largest (serif, with the currency mark raised and
  /// the decimal tail dropped — see [GaiaBigNumber]), then the chart, then the
  /// caption as a tracked uppercase eyebrow beneath it. That is `.stats`'
  /// n-over-l reading order rather than Rustic's value-then-caption card.
  Widget _gaia(BuildContext context) {
    return GaiaCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      _GaiaFigure(value),
                      if (unit != null) ...[
                        const SizedBox(width: 5),
                        Text(unit!.toUpperCase(), style: GaiaType.unit()),
                      ],
                    ],
                  ),
                ),
              ),
              if (tag != null) TickTag(tag!, color: tagColor),
            ],
          ),
          if (chart != null) ...[
            const SizedBox(height: 16),
            chart!,
          ],
          const SizedBox(height: 14),
          Text(caption.toUpperCase(), style: GaiaType.eyebrow()),
          if (footer != null) ...[
            const SizedBox(height: 8),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// A StatCard figure at card scale. [GaiaBigNumber] is the 62px page hero; a
/// grid tile takes the same typesetting rule at the theme's `displayMedium`
/// (40px), which is where the mockup's own in-card figures sit.
class _GaiaFigure extends StatelessWidget {
  const _GaiaFigure(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final parts = GaiaBigNumber.splitNumber(value);
    final big = Theme.of(context).textTheme.displayMedium;
    final small = GaiaType.serif(
      size: (big?.fontSize ?? 40) * 0.52,
      weight: 400,
      color: GaiaColors.champagneDim,
    );
    return RichText(
      maxLines: 1,
      text: TextSpan(children: [
        if (parts.prefix.isNotEmpty) TextSpan(text: parts.prefix, style: small),
        TextSpan(text: parts.whole, style: big),
        if (parts.tail.isNotEmpty) TextSpan(text: parts.tail, style: small),
      ]),
    );
  }
}
