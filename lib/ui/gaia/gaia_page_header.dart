import 'package:flutter/material.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

/// The masthead every GAIA screen opens with — the mockup's `.top` + `h1.title`
/// + `.sub` block, which is the single most recognisable thing in the design:
///
/// ```html
/// <div class="top"><span class="wordmark">GAIA</span>
///                  <span class="meta">Dinner · Fri 4 Sep</span></div>
/// <h1 class="title">Good evening,<br><em>Gaia Test.</em></h1>
/// <div class="sub">Main outlet · service since 19:00</div>
/// ```
///
/// The italic champagne second line is the signature: a greeting that breaks
/// mid-phrase and finishes in the serif italic. It is why the Overview is worth
/// restyling first — nothing else in the app announces the design this loudly.
class GaiaPageHeader extends StatelessWidget {
  const GaiaPageHeader({
    super.key,
    required this.wordmark,
    required this.title,
    this.titleEmphasis,
    this.meta,
    this.sub,
  });

  /// Tracked serif, champagne — sits top-left. The restaurant's name here,
  /// where the mockup puts the product's.
  final String wordmark;

  /// Top-right micro label.
  final String? meta;

  /// The plain first line of the greeting ("Welcome,").
  final String title;

  /// The italic champagne second line ("Gaia Test."). Omitted when there is no
  /// name to say, in which case the title stands alone rather than leaving a
  /// dangling comma — the caller passes the punctuation it wants.
  final String? titleEmphasis;

  /// The tracked uppercase line under the title.
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final headline = Theme.of(context).textTheme.headlineMedium ??
        GaiaType.serif(size: 34, weight: 400, height: 1.1);
    final size = headline.fontSize ?? 34;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                wordmark.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GaiaType.wordmark(),
              ),
            ),
            if (meta != null) ...[
              const SizedBox(width: 12),
              Text(meta!.toUpperCase(), style: GaiaType.eyebrow()),
            ],
          ],
        ),
        const SizedBox(height: 18),
        RichText(
          text: TextSpan(
            text: title,
            style: headline,
            children: [
              if (titleEmphasis != null) ...[
                const TextSpan(text: '\n'),
                TextSpan(
                  text: titleEmphasis,
                  // Same size and tracking as the plain half, italic and
                  // champagne — the contrast is voice, never scale.
                  style: GaiaType.serif(
                    size: size,
                    weight: 400,
                    height: 1.1,
                    italic: true,
                    color: GaiaColors.champagne,
                    letterSpacing: GaiaType.track(-0.005, size),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 10),
          Text(sub!.toUpperCase(), style: GaiaType.eyebrow(color: GaiaColors.text2)),
        ],
        const SizedBox(height: GaiaSpacing.section),
      ],
    );
  }
}
