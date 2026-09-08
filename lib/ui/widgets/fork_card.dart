import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Base surface of the design system: subtle vertical gradient, hairline
/// border, 14px radius, soft ambient shadow. When [onTap] is given the card
/// lifts slightly and brightens its border on hover.
class ForkCard extends StatefulWidget {
  const ForkCard({
    super.key,
    required this.child,
    this.padding = AppSpacing.cardPad,
    this.onTap,
    this.selected = false,
    this.inset = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Draws the copper selection outline (like the highlighted row in the
  /// reference design).
  final bool selected;

  /// Renders as a darker recessed panel instead of a raised card.
  final bool inset;

  @override
  State<ForkCard> createState() => _ForkCardState();
}

class _ForkCardState extends State<ForkCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // The design-system fork. Everything below this line is the Rustic Fork
    // card, unchanged; GAIA's card is a different SHAPE (flat, hairlined, 2px)
    // rather than a recolour, so it cannot be expressed as tokens and gets its
    // own widget. Keeping the branch here — rather than at the ~200 call sites
    // — is what lets every module render in either language untouched.
    if (Gaia.of(context)) {
      return GaiaCard(
        padding: widget.padding,
        onTap: widget.onTap,
        selected: widget.selected,
        // `inset` means "recessed panel" in Rustic. Gaia has no recess; the
        // nearest thing it has is the raised step, which is what a panel
        // distinguished from its page uses there.
        raised: widget.inset,
        child: widget.child,
      );
    }

    final interactive = widget.onTap != null;

    final border = widget.selected
        ? AppColors.copper.withValues(alpha: 0.55)
        : _hovered && interactive
            ? AppColors.borderStrong
            : AppColors.border;

    Widget card = AnimatedContainer(
      duration: AppDurations.fast,
      curve: Curves.easeOut,
      padding: widget.padding,
      transform: Matrix4.translationValues(0, _hovered && interactive ? -2 : 0, 0),
      decoration: BoxDecoration(
        gradient: widget.inset ? null : AppColors.cardGradient,
        color: widget.inset ? AppColors.inset : null,
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: border),
        boxShadow: widget.inset
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _hovered && interactive ? 0.45 : 0.30),
                  blurRadius: _hovered && interactive ? 26 : 18,
                  offset: const Offset(0, 10),
                ),
                if (widget.selected)
                  BoxShadow(
                    color: AppColors.copper.withValues(alpha: 0.10),
                    blurRadius: 24,
                    offset: Offset.zero,
                  ),
              ],
      ),
      child: widget.child,
    );

    if (!interactive) return card;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: card,
      ),
    );
  }
}
