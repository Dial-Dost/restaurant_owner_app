import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Dish photo placeholder — a recessed gradient tile with a faint copper
/// glow behind the glyph. Keeps imagery consistent without bundling photos.
class FoodTile extends StatelessWidget {
  const FoodTile({
    super.key,
    required this.emoji,
    this.size = 44,
    this.radius,
  });

  final String emoji;
  final double size;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius ?? AppRadius.tile),
        border: Border.all(color: AppColors.border),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // 6.6 — the charcoal tile on dark; the palette's own card-to-inset
          // step on a light palette, where a black square would read as a hole.
          colors: AppColors.isLight
              ? [AppColors.cardTop, AppColors.inset]
              : const [Color(0xFF232326), Color(0xFF121214)],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft copper glow so the glyph sits in the palette.
          Container(
            width: size * 0.62,
            height: size * 0.62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.copperDeep.withValues(alpha: 0.35),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          Text(emoji, style: TextStyle(fontSize: size * 0.44)),
        ],
      ),
    );
  }
}

/// Initials avatar for people — copper-tinted ring on a dark disc.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.initials,
    this.size = 38,
    this.color,
  });

  final String initials;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.copper;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.inset,
        border: Border.all(color: c.withValues(alpha: 0.35), width: 1.2),
      ),
      child: Center(
        child: Text(
          initials.toUpperCase(),
          style: TextStyle(
            fontSize: size * 0.32,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: AppColors.lift(c, 0.35),
          ),
        ),
      ),
    );
  }
}
