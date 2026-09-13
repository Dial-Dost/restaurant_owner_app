import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_scrollbar.dart';
import 'app_spacing.dart';

/// Material 3 dark theme tuned to the reference design language:
/// near-black surfaces, hairline borders, warm-white ink, copper accent,
/// oversized light-weight display numbers and letter-spaced micro labels.
///
/// The reference template uses google_fonts (Inter); this app must not add
/// dependencies, so the identical type scale is replicated with plain
/// [TextStyle]s (default fontFamily, same size/weight/letterSpacing/height).
abstract final class AppTheme {
  /// The shipped dark theme. Reads the live AppColors ladder, so it is the
  /// same ThemeData it always was on every dark scheme.
  static ThemeData dark() => _build(Brightness.dark);

  /// 6.6 — the light interface theme. Identical structure and type scale; the
  /// colours come from whichever light palette AppearanceController applied
  /// (White or Beige), so this needs no palette argument of its own.
  static ThemeData light() => _build(Brightness.light);

  /// The Rustic Fork ThemeData for whatever the device is painting right now:
  /// light when a light palette is applied, dark otherwise. The app root calls
  /// this on every appearance change.
  static ThemeData active() => AppColors.isLight ? light() : dark();

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: (isLight ? ColorScheme.light : ColorScheme.dark)(
        primary: AppColors.copper,
        onPrimary: AppColors.onCopper,
        secondary: AppColors.copperHi,
        onSecondary: AppColors.onCopper,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        onSurfaceVariant: AppColors.textSecondary,
        outline: AppColors.borderStrong,
        outlineVariant: AppColors.border,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: AppColors.bg,
    );

    final text = base.textTheme.copyWith(
      // Oversized stat numbers — light weight, tight tracking.
      displayLarge: TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w300,
        letterSpacing: -1.2,
        color: AppColors.textPrimary,
        height: 1.0,
      ),
      displayMedium: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.8,
        color: AppColors.textPrimary,
        height: 1.0,
      ),
      displaySmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.5,
        color: AppColors.textPrimary,
        height: 1.05,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
        color: AppColors.textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: AppColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: AppColors.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.45,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.4,
      ),
      // Letter-spaced uppercase micro label ("CROWD SIZE" style).
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
        color: AppColors.textTertiary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: AppColors.textSecondary,
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: AppColors.textPrimary,
      ),
    );

    return base.copyWith(
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: AppColors.textSecondary, size: 18),
      // Same colour an M3 IconButton already resolves to (colorScheme
      // .onSurfaceVariant), so nothing moves — but it must be spelled out.
      // AppBar hands its iconTheme/actionsIconTheme down as
      // `iconButtonTheme.style?.copyWith(...)`, which evaluates to null when
      // the app leaves this theme empty; the AppBar's icon colours are then
      // silently dropped and every IconButton falls back to the dark-theme
      // default. On the light chrome that is invisible ink.
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: AppColors.textSecondary),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.cardRaised,
          borderRadius: AppRadius.controlAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        textStyle: text.bodySmall!.copyWith(color: AppColors.textPrimary),
        waitDuration: const Duration(milliseconds: 400),
      ),
      // 6.2 — a 14px lane with a handle you can hit, the web's H3 sizing. The
      // old 5px thumb at 15% ink was the thing being complained about. Ink and
      // lane are the palette's own tokens, so dark schemes and the light
      // palettes each get a bar that reads on them; see [AppScrollbar].
      scrollbarTheme: AppScrollbar.theme(
        ink: AppColors.textSecondary,
        track: AppColors.border,
        radius: const Radius.circular(8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.inset,
        hintStyle: text.bodyMedium!.copyWith(color: AppColors.textTertiary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AppRadius.inputAll,
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputAll,
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputAll,
          borderSide: BorderSide(color: AppColors.copper.withValues(alpha: 0.5)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.onCopper
                : AppColors.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.copper
                : AppColors.inset),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.transparent
                : AppColors.borderStrong),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
