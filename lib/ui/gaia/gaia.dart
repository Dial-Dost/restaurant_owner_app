/// The GAIA design system.
///
/// A second, complete visual language living ALONGSIDE Rustic Fork rather than
/// replacing it — selectable at runtime, defaulting to Rustic, so trying it
/// costs a setting and abandoning it costs a setting back.
///
/// ```
///   gaia_colors.dart    palette + the AppColors bridges
///   gaia_coverflow.dart signature style: COVERFLOW (Bookings, Waitlist)
///   gaia_bokeh.dart     signature style: BOKEH    (Customers, Feedback)
///   gaia_type.dart      Cormorant Garamond / Instrument Sans, variable axes
///   gaia_spacing.dart   the 24px gutter, the 2px edge
///   gaia_theme.dart     ThemeData (mirrors AppTheme.dark)
///   gaia_widgets.dart   the primitives
///   gaia_strata.dart    STRATA  — Analytics, History  (+ gaia_strata_math)
///   gaia_bicolour.dart  BICOLOUR — Simulation
/// ```
///
/// ## The signature styles
///
/// The mockup gives four of its sections a treatment the rest of the app does
/// not have — COVERFLOW (Bookings, Waitlist), BOKEH (Customers, Feedback),
/// STRATA (Analytics, History) and BICOLOUR (Simulation). Each owns its own
/// file. The two DATA-LED ones carry an extra obligation, because the screens
/// they own show settled and projected money:
///
///  * **STRATA** draws a proportion as thickness. It is the one place in this
///    system where a visual makes an ARITHMETIC claim, so its geometry is a
///    pure, tested function in `gaia_strata_math.dart` rather than something a
///    painter improvises — and it will not claim a share for a series that is
///    not a partition (see [GaiaStrataMode]).
///  * **BICOLOUR** inverts the ground — a champagne slab with ink type — to
///    say "nothing on this screen is real". Inverting a ground inverts every
///    ink on it, and the dark-ground status inks measure 1.0-1.7:1 on
///    champagne, so [GaiaBicolour] is an InheritedWidget the primitives ask
///    rather than a colour passed down: a chip that carried its own colour
///    across would not look wrong, it would look absent.
///
/// ## How a screen restyles without being edited
///
/// Three layers do the work, in this order:
///
///  1. **Colour** — [GaiaColors.shellBridge] / [GaiaColors.accentBridge] are
///     pushed through the EXISTING `AppColors.applyShell` / `applyAccent`
///     extension points, so every `AppColors.bg` / `.copper` / `.textPrimary`
///     call site in all ~30 modules repaints. No module edit, no token edit.
///  2. **Voice** — [GaiaTheme.dark] maps the Material text slots onto the
///     Cormorant/Instrument scale, so anything reading
///     `Theme.of(context).textTheme` changes face.
///  3. **Shape** — the Fork* primitives branch on [isActive] and draw the flat,
///     hairlined, 2px-cornered Gaia box instead of the gradient-and-shadow
///     Rustic one.
///
/// Modules keep their existing widget names and need no changes.
library;

import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';

export 'gaia_bokeh.dart';
export 'gaia_bicolour.dart';
export 'gaia_colors.dart';
export 'gaia_coverflow.dart';
export 'gaia_page_header.dart';
export 'gaia_spacing.dart';
export 'gaia_strata.dart';
export 'gaia_theme.dart';
export 'gaia_type.dart';
export 'gaia_widgets.dart';

/// One-line question every Gaia-aware primitive asks at the top of `build`.
///
/// Deliberately a plain static read rather than an InheritedWidget lookup: the
/// primitives that need it are drawn inside `RichText` spans, `TextStyle`
/// builders and other places with no `BuildContext` to hand, and the app root
/// already rebuilds the whole tree on an [AppearanceController] notification —
/// so a context-free read cannot go stale.
abstract final class Gaia {
  /// The context-free read. Correct wherever the caller is ALREADY being
  /// rebuilt — the app root choosing a ThemeData, a widget that also depends
  /// on something else that changed.
  static bool get isActive =>
      AppearanceController.instance.designSystem == DesignSystem.gaia;

  /// The read every PRIMITIVE must use.
  ///
  /// Not a style preference — a correctness requirement, and a subtle one.
  /// `Element.updateChild` short-circuits when the new widget is IDENTICAL to
  /// the old one:
  ///
  /// ```dart
  ///   if (hasSameSuperclass && child.widget == newWidget) {
  ///     newChild = child;   // no update(), no rebuild
  ///   }
  /// ```
  ///
  /// A `const SectionHeader(title: 'Operations')` is the same instance on
  /// every rebuild of its parent, so rebuilding the app root does NOT rebuild
  /// it — and a primitive that decided its look from a static read would keep
  /// painting the old design system after a flip. There are 88 such const call
  /// sites across the modules today (30 SectionHeader, 43 StatusChip, 12
  /// InfoChip, 3 TickTag), and every one of them would have gone stale.
  ///
  /// Depending on an InheritedWidget fixes it at the root cause: a dependent
  /// ELEMENT is marked dirty when the inherited value changes, whatever the
  /// identity of its widget. Const call sites restyle correctly, and no module
  /// has to give up its `const`.
  ///
  /// Falls back to [isActive] when no scope is above — tests that pump a bare
  /// primitive, and any surface built outside the app root.
  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GaiaScope>();
    return scope == null ? isActive : scope.system == DesignSystem.gaia;
  }
}

/// Publishes the active design system to the widget tree. Mounted once, above
/// [MaterialApp], by the app root. See [Gaia.of] for why this exists rather
/// than everything reading the controller statically.
class GaiaScope extends InheritedWidget {
  const GaiaScope({super.key, required this.system, required super.child});

  final DesignSystem system;

  @override
  bool updateShouldNotify(GaiaScope oldWidget) => system != oldWidget.system;
}
