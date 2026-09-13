import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Pill tab row with short copper tick separators — the
/// "Overview | Events | Guest Experience" pattern from the reference.
class ForkTabs extends StatelessWidget {
  const ForkTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    // Gaia's tabs are underlined, not pilled, and the row carries the rule the
    // pills' copper tick separators stand in for here.
    if (Gaia.of(context)) {
      return GaiaTabs(tabs: tabs, selected: selected, onSelected: onSelected);
    }

    final children = <Widget>[];
    for (var i = 0; i < tabs.length; i++) {
      if (i > 0) {
        children.add(Container(
          width: 1.5,
          height: 11,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: AppColors.copperDeep.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(1),
          ),
        ));
      }
      children.add(_TabPill(
        label: tabs[i],
        active: i == selected,
        onTap: () => onSelected(i),
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _TabPill extends StatefulWidget {
  const _TabPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_TabPill> createState() => _TabPillState();
}

class _TabPillState extends State<_TabPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: widget.active
                ? AppColors.overlay.withValues(alpha: 0.08)
                : _hovered
                    ? AppColors.overlay.withValues(alpha: 0.04)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.active ? AppColors.borderStrong : Colors.transparent,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0.2,
              color: widget.active
                  ? AppColors.textPrimary
                  : _hovered
                      ? AppColors.textPrimary.withValues(alpha: 0.85)
                      : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
