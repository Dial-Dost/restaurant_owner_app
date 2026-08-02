import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

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
    final primary = widget.kind == ForkButtonKind.primary;
    final ghost = widget.kind == ForkButtonKind.ghost;

    final fg = primary
        ? AppColors.onCopper
        : _hovered
            ? AppColors.textPrimary
            : AppColors.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
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
                    colors: _hovered
                        ? [AppColors.copperHi, AppColors.copper]
                        : [AppColors.copperHi, AppColors.copperMid],
                  )
                : null,
            color: !primary
                ? (_hovered
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.transparent)
                : null,
            borderRadius: AppRadius.controlAll,
            border: ghost ? Border.all(color: AppColors.borderStrong) : null,
            boxShadow: primary
                ? [
                    BoxShadow(
                      color: AppColors.copperShadow.withValues(alpha: 0.5),
                      blurRadius: _hovered ? 18 : 10,
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
              Text(
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
    Widget child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: AppRadius.controlAll,
            border: Border.all(
              color: _hovered ? AppColors.borderStrong : AppColors.border,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                widget.icon,
                size: 16,
                color:
                    _hovered ? AppColors.textPrimary : AppColors.textSecondary,
              ),
              if (widget.badge)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.copperHi,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
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
