import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'status_chip.dart';

enum ForkButtonKind { primary, ghost, subtle }

/// The template's two button voices: a copper-filled primary and a quiet
/// hairline ghost. [ForkButtonKind.subtle] is a borderless hover-only variant
/// for "View all" style links.
class ForkButton extends StatefulWidget {
  const ForkButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.kind = ForkButtonKind.primary,
    this.dense = false,
  });

  const ForkButton.ghost({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.dense = false,
  }) : kind = ForkButtonKind.ghost;

  const ForkButton.subtle({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.dense = true,
  }) : kind = ForkButtonKind.subtle;

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ForkButtonKind kind;
  final bool dense;

  @override
  State<ForkButton> createState() => _ForkButtonState();
}

class _ForkButtonState extends State<ForkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (Gaia.of(context)) {
      return GaiaButton(
        label: widget.label,
        icon: widget.icon,
        onPressed: widget.onPressed,
        kind: switch (widget.kind) {
          ForkButtonKind.primary => GaiaButtonKind.primary,
          ForkButtonKind.ghost => GaiaButtonKind.ghost,
          ForkButtonKind.subtle => GaiaButtonKind.subtle,
        },
        // Gaia's own button is 52px tall — correct for a phone hero, far too
        // tall for the toolbars and card footers this app puts buttons in. The
        // dense variant (40px) is the honest match for the app's density, so
        // the non-dense Rustic button maps onto it rather than doubling the
        // height of every action row on flip.
        dense: true,
      );
    }

    final primary = widget.kind == ForkButtonKind.primary;
    final ghost = widget.kind == ForkButtonKind.ghost;

    // A NULL onPressed MUST LOOK LIKE ONE. This button used to render a disabled
    // control identically to a live one — same colour, same hover lift, same
    // click cursor — so "Comp an item" for a waiter, "Load more" with no next
    // page and "Export" with no rows were all buttons that invited a tap and
    // then did nothing. That is the dead-looking control this app has been
    // bitten by before, and every gated affordance in the product rides on this
    // one widget, so the honesty belongs here rather than at each call site.
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;

    final fg = primary
        ? AppColors.onCopper
        : hovered
            ? AppColors.textPrimary
            : AppColors.textSecondary;

    return MouseRegion(
      // `defer`, not `basic`: a disabled button sitting on a tappable card must
      // not override the card's own cursor.
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          padding: EdgeInsets.symmetric(
            horizontal: widget.dense ? 12 : 16,
            vertical: widget.dense ? 7 : 9,
          ),
          decoration: BoxDecoration(
            gradient: primary
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: hovered
                        ? [AppColors.copperHi, AppColors.copper]
                        : [AppColors.copperHi, AppColors.copperMid],
                  )
                : null,
            color: !primary
                ? (hovered
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.transparent)
                : null,
            borderRadius: AppRadius.controlAll,
            border: ghost ? Border.all(color: AppColors.borderStrong) : null,
            boxShadow: primary
                ? [
                    BoxShadow(
                      color: AppColors.copperShadow.withValues(alpha: 0.5),
                      blurRadius: hovered ? 18 : 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: widget.dense ? 14 : 15, color: fg),
                const SizedBox(width: 7),
              ],
              // Same rule as the chips: a button stacked in a narrow column
              // gives way rather than overflowing (see ChipLabel).
              ChipLabel(
                widget.label,
                style: TextStyle(
                  fontSize: widget.dense ? 12 : 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// Quiet square icon button used in bars and card corners.
class ForkIconButton extends StatefulWidget {
  const ForkIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.badge = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool badge;

  @override
  State<ForkIconButton> createState() => _ForkIconButtonState();
}

class _ForkIconButtonState extends State<ForkIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (Gaia.of(context)) {
      return GaiaIconButton(
        icon: widget.icon,
        onPressed: widget.onPressed,
        tooltip: widget.tooltip,
        badge: widget.badge,
      );
    }

    // Same rule as [ForkButton]: a disabled icon button must look disabled. The
    // −/+ stepper on a partial comp reaches its ends, and an inert "one fewer"
    // that still lights up on hover is a control the till learns to distrust.
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;
    Widget child = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: hovered
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: AppRadius.controlAll,
            border: Border.all(
              color: hovered ? AppColors.borderStrong : AppColors.border,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                widget.icon,
                size: 16,
                color:
                    hovered ? AppColors.textPrimary : AppColors.textSecondary,
              ),
              if (widget.badge)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: AppColors.copperHi,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, child: child);
    }
    return child;
  }
}
