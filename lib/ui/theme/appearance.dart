import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gaia/gaia_colors.dart';
import 'app_colors.dart';
import 'backdrop_style.dart';
import 'contrast.dart';

/// Which complete visual language the app wears.
///
/// Not an accent and not a shell scheme — those are choices WITHIN a system.
/// This picks the system: its palette, its type, its shapes and its
/// primitives. The two are deliberately kept as separate axes so that turning
/// Gaia off restores the exact copper-on-rustic the device had before, rather
/// than leaving it on some half-migrated blend.
enum DesignSystem {
  /// The shipped look: near-black ground, copper accent, 14px radii, gradient
  /// cards, ambient shadow. Lives in `lib/ui/theme` + `lib/ui/widgets`.
  rustic('rustic', 'Rustic Fork'),

  /// The GAIA look: forest ground, champagne accent, Cormorant Garamond
  /// numerals over Instrument Sans, 2px edges, hairlines and no shadow at all.
  /// Lives in `lib/ui/gaia`.
  gaia('gaia', 'Gaia');

  const DesignSystem(this.id, this.label);

  final String id;
  final String label;

  static DesignSystem byId(String? id) =>
      DesignSystem.values.firstWhere((d) => d.id == id, orElse: () => rustic);
}

/// The curated accent set. Every `hi`/`base` stop clears WCAG AA 4.5:1 against
/// the near-black ground (bg #0C0A09) — measured, not hoped: hi ranges 8.4–13.2,
/// base 5.7–9.9 — so no choice here can make a label unreadable. Copper is the
/// shipped Rustic Fork default, byte-identical to the original constants.
abstract final class AppAccents {
  static const String defaultId = 'copper';

  // The shipped Rustic Fork copper — aliased from AppColors so the default is
  // byte-identical by construction, not by copy.
  static const copper = AppColors.rusticCopper;
  // hi 13.2:1, base 9.9:1 on the near-black ground
  static const brass = AppAccent(
    id: 'brass', label: 'Brass',
    hi: Color(0xFFE5D29A), base: Color(0xFFCBB676), mid: Color(0xFFB79C4E),
    deep: Color(0xFF8A773D), shadow: Color(0xFF544927), on: Color(0xFF221E11),
    glowBright: Color(0xFFC0930C), glowMid: Color(0xFF977611), glowDeep: Color(0xFF785E12),
  );
  // hi 13.0:1, base 9.4:1
  static const sage = AppAccent(
    id: 'sage', label: 'Sage',
    hi: Color(0xFFBBDBA3), base: Color(0xFF9CBD84), mid: Color(0xFF7CA460),
    deep: Color(0xFF5F7B4C), shadow: Color(0xFF3B4B30), on: Color(0xFF191F14),
    glowBright: Color(0xFF57C00C), glowMid: Color(0xFF499711), glowDeep: Color(0xFF3C7812),
  );
  // hi 13.1:1, base 9.6:1
  static const teal = AppAccent(
    id: 'teal', label: 'Teal',
    hi: Color(0xFFA1DED9), base: Color(0xFF81C1BB), mid: Color(0xFF5BA9A2),
    deep: Color(0xFF487F7B), shadow: Color(0xFF2D4D4A), on: Color(0xFF13201F),
    glowBright: Color(0xFF0CC0B1), glowMid: Color(0xFF11978C), glowDeep: Color(0xFF12786F),
  );
  // hi 10.4:1, base 7.3:1
  static const steel = AppAccent(
    id: 'steel', label: 'Steel',
    hi: Color(0xFF9EBFE0), base: Color(0xFF7DA1C5), mid: Color(0xFF5682AE),
    deep: Color(0xFF446383), shadow: Color(0xFF2B3D50), on: Color(0xFF121921),
    glowBright: Color(0xFF0C66C0), glowMid: Color(0xFF115497), glowDeep: Color(0xFF124578),
  );
  // hi 8.4:1, base 5.7:1
  static const lavender = AppAccent(
    id: 'lavender', label: 'Lavender',
    hi: Color(0xFFB39FDF), base: Color(0xFF937FC3), mid: Color(0xFF7259AB),
    deep: Color(0xFF584681), shadow: Color(0xFF362C4E), on: Color(0xFF171320),
    glowBright: Color(0xFF420CC0), glowMid: Color(0xFF391197), glowDeep: Color(0xFF301278),
  );
  // hi 9.2:1, base 6.3:1
  static const rose = AppAccent(
    id: 'rose', label: 'Rose',
    hi: Color(0xFFE09EB4), base: Color(0xFFC57D95), mid: Color(0xFFAE5673),
    deep: Color(0xFF834459), shadow: Color(0xFF502B37), on: Color(0xFF211217),
    glowBright: Color(0xFFC00C48), glowMid: Color(0xFF97113E), glowDeep: Color(0xFF781234),
  );
  // hi 9.7:1, base 6.8:1
  static const ember = AppAccent(
    id: 'ember', label: 'Ember',
    hi: Color(0xFFEBA593), base: Color(0xFFD5826D), mid: Color(0xFFC35B41),
    deep: Color(0xFF944633), shadow: Color(0xFF5A2C20), on: Color(0xFF25130E),
    glowBright: Color(0xFFC0300C), glowMid: Color(0xFF972C11), glowDeep: Color(0xFF782612),
  );

  static const List<AppAccent> all = [copper, brass, sage, teal, steel, lavender, rose, ember];

  static AppAccent byId(String? id) =>
      all.firstWhere((a) => a.id == id, orElse: () => copper);
}

/// The curated shell-scheme set: five complete dark shells, each the full
/// ground/surface/ink ladder re-tilted to a different temperature. Scheme and
/// accent compose FREELY — appearance_matrix_test.dart pre-checks the whole
/// 5x8 matrix (both body inks on every surface, both readable accent stops on
/// the grounds they sit on) at WCAG AA 4.5:1, so no combination an owner can
/// pick is allowed to exist unreadable. Rustic is the shipped Rustic Fork
/// shell, byte-identical by aliasing.
abstract final class AppSchemes {
  static const String defaultId = 'rustic';

  // The shipped Rustic Fork shell — aliased from AppColors so the default is
  // byte-identical by construction, not by copy.
  static const rustic = AppColors.rusticShell;

  // Deeper and cool: the rustic ladder pushed toward slate blue-grey.
  static const slate = AppShellScheme(
    id: 'slate', label: 'Slate',
    bg: Color(0xFF090B0E), bgDeep: Color(0xFF050708),
    surface: Color(0xFF10141A), card: Color(0xFF141A21),
    cardTop: Color(0xFF182028), cardBottom: Color(0xFF11161C),
    cardRaised: Color(0xFF1D2530), inset: Color(0xFF0C1015),
    textPrimary: Color(0xFFE8ECF1), textSecondary: Color(0xFF97A1AE),
    textTertiary: Color(0xFF5C6570),
  );

  // A touch lighter than rustic and warmer than graphite: charcoal with the
  // same R>B tilt the rustic surfaces carry.
  static const charcoal = AppShellScheme(
    id: 'charcoal', label: 'Charcoal',
    bg: Color(0xFF121110), bgDeep: Color(0xFF0C0B0A),
    surface: Color(0xFF1A1817), card: Color(0xFF201D1B),
    cardTop: Color(0xFF252220), cardBottom: Color(0xFF1B1917),
    cardRaised: Color(0xFF2A2624), inset: Color(0xFF161413),
    textPrimary: Color(0xFFEFEDEA), textSecondary: Color(0xFFA5A19A),
    textTertiary: Color(0xFF6A665F),
  );

  // The darkest ground of the set, blue-black — night-service chrome.
  static const midnight = AppShellScheme(
    id: 'midnight', label: 'Midnight',
    bg: Color(0xFF070A14), bgDeep: Color(0xFF04060D),
    surface: Color(0xFF0D1220), card: Color(0xFF101728),
    cardTop: Color(0xFF131B2E), cardBottom: Color(0xFF0E1421),
    cardRaised: Color(0xFF16203A), inset: Color(0xFF0A0E1A),
    textPrimary: Color(0xFFE7EBF4), textSecondary: Color(0xFF93A0B8),
    textTertiary: Color(0xFF57627A),
  );

  // Dead-neutral grey: for the owner who wants the accent to be the ONLY hue
  // the chrome speaks.
  static const graphite = AppShellScheme(
    id: 'graphite', label: 'Graphite',
    bg: Color(0xFF0B0B0C), bgDeep: Color(0xFF070708),
    surface: Color(0xFF131315), card: Color(0xFF19191B),
    cardTop: Color(0xFF1E1E20), cardBottom: Color(0xFF161618),
    cardRaised: Color(0xFF232326), inset: Color(0xFF0F0F10),
    textPrimary: Color(0xFFEBEBEC), textSecondary: Color(0xFF9B9B9E),
    textTertiary: Color(0xFF616163),
  );

  static const List<AppShellScheme> all = [rustic, slate, charcoal, midnight, graphite];

  static AppShellScheme byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => rustic);
}

/// 6.6 — the colour of light mode: which GROUND the interface wears while the
/// device is in light mode. Mirrors the web dashboard's `LIGHT_TONES`
/// (src/lib/light-tone.ts) id for id, label for label, so the till and the
/// browser offer the same three and say the same thing about them.
///
/// A separate axis from dark/light on purpose, as on the web: picking a tone
/// switches to light; picking Dark keeps the tone, so the next switch back to
/// light returns the colour somebody chose rather than resetting to white.
///
/// And a separate axis from [AppSchemes]: the five shell schemes are all DARK
/// re-tilts, so while light is on they are remembered but not applied —
/// exactly how Gaia treats them — and Dark returns the device's scheme.
enum LightTone {
  white('white', 'White', 'Plain white — light mode as it has always been.'),
  beige('beige', 'Beige', 'Warm cream — softer under warm restaurant lighting.'),
  grey('grey', 'Soft grey', 'A quiet grey — less glare than white, cooler than beige.');

  const LightTone(this.id, this.label, this.hint);

  final String id;
  final String label;
  final String hint;

  /// White, as on the web: it is what light mode already looked like there.
  static const LightTone defaultTone = white;

  static LightTone byId(String? id) =>
      LightTone.values.firstWhere((t) => t.id == id, orElse: () => defaultTone);
}

/// 6.6 — the light palettes, in ONE place. The named values are the web
/// dashboard's light tokens, verbatim (globals.css `:root` for White, the
/// `[data-light-tone]` blocks for Beige and Soft grey):
///
///   token (web)          -> AppShellScheme field
///   --background         -> bg
///   --card / --popover   -> surface, card, cardTop/Bottom, cardRaised
///   --secondary/--muted  -> inset, bgDeep
///   --foreground         -> textPrimary
///   --muted-foreground   -> textSecondary
///   --accent (hover)     -> divider
///   --border             -> border
///   --input              -> borderStrong
///   --destructive        -> danger
///
/// What the web does not name (the tertiary ink, and the success / warning /
/// info / neutral inks the app's reports use) is filled in on the same
/// temperature. The floor's five inks are the web's own light FLOOR_INKS
/// (src/lib/floor-state.ts), one set for all three palettes. light_theme_test.dart holds body inks, status inks, the
/// derived accent and the table-state washes to WCAG AA 4.5:1 on these
/// grounds, so a retune that makes anything unreadable fails CI.
abstract final class AppLightPalettes {
  // White — the web's plain light mode (globals.css `:root`). Two app-side
  // departures, both for AA: secondary ink is gray-600, one step darker than
  // the web's gray-500 --muted-foreground (which drops to 3.6:1 under the
  // table-state washes and 4.4:1 on --muted; gray-500 is kept as the tertiary
  // ink), and danger is the tones' #C32222 because the web's #EF4444 is 3.8:1
  // as text on white.
  static const white = AppShellScheme(
    id: 'light-white', label: 'White',
    brightness: Brightness.light,
    bg: Color(0xFFFFFFFF), bgDeep: Color(0xFFF3F4F6),
    surface: Color(0xFFFFFFFF), card: Color(0xFFFFFFFF),
    cardTop: Color(0xFFFFFFFF), cardBottom: Color(0xFFFFFFFF),
    cardRaised: Color(0xFFFFFFFF), inset: Color(0xFFF3F4F6),
    textPrimary: Color(0xFF030712), textSecondary: Color(0xFF4B5563),
    textTertiary: Color(0xFF6B7280),
    border: Color(0xFFE5E7EB), borderStrong: Color(0xFFD1D5DB),
    divider: Color(0xFFF3F4F6),
    success: Color(0xFF2B6326), warning: Color(0xFF8A5A00),
    danger: Color(0xFFC32222), info: Color(0xFF36648A),
    neutral: Color(0xFF5F6670),
    floorFree: Color(0xFF2B6326), floorSeated: Color(0xFF7A5B00),
    floorRunning: Color(0xFFB0283C), floorPrinted: Color(0xFFA84A06),
    floorReserved: Color(0xFF2F5F8F), floorNextParty: Color(0xFF5F6670),
  );

  // Beige — warm cream.
  static const beige = AppShellScheme(
    id: 'light-beige', label: 'Beige',
    brightness: Brightness.light,
    bg: Color(0xFFF5EFE3), bgDeep: Color(0xFFECE3D2),
    surface: Color(0xFFFBF7EF), card: Color(0xFFFBF7EF),
    cardTop: Color(0xFFFBF7EF), cardBottom: Color(0xFFFBF7EF),
    cardRaised: Color(0xFFFBF7EF), inset: Color(0xFFECE3D2),
    textPrimary: Color(0xFF2B2219), textSecondary: Color(0xFF6A5B4B),
    textTertiary: Color(0xFF8C7B69),
    border: Color(0xFFE0D3BE), borderStrong: Color(0xFFD4C4AA),
    divider: Color(0xFFE6DCC9),
    success: Color(0xFF2B6326), warning: Color(0xFF805300),
    danger: Color(0xFFC32222), info: Color(0xFF36648A),
    neutral: Color(0xFF625649),
    floorFree: Color(0xFF2B6326), floorSeated: Color(0xFF7A5B00),
    floorRunning: Color(0xFFB0283C), floorPrinted: Color(0xFFA84A06),
    floorReserved: Color(0xFF2F5F8F), floorNextParty: Color(0xFF5F6670),
  );

  // Soft grey — a neutral with less glare than white.
  static const grey = AppShellScheme(
    id: 'light-grey', label: 'Soft grey',
    brightness: Brightness.light,
    bg: Color(0xFFEEEFF1), bgDeep: Color(0xFFE3E5E8),
    surface: Color(0xFFF8F9FA), card: Color(0xFFF8F9FA),
    cardTop: Color(0xFFF8F9FA), cardBottom: Color(0xFFF8F9FA),
    cardRaised: Color(0xFFF8F9FA), inset: Color(0xFFE3E5E8),
    textPrimary: Color(0xFF1D2025), textSecondary: Color(0xFF575D66),
    textTertiary: Color(0xFF7D838C),
    border: Color(0xFFD9DCE1), borderStrong: Color(0xFFC9CDD4),
    divider: Color(0xFFE8E9EC),
    success: Color(0xFF2B6326), warning: Color(0xFF805300),
    danger: Color(0xFFC32222), info: Color(0xFF36648A),
    neutral: Color(0xFF575D66),
    floorFree: Color(0xFF2B6326), floorSeated: Color(0xFF7A5B00),
    floorRunning: Color(0xFFB0283C), floorPrinted: Color(0xFFA84A06),
    floorReserved: Color(0xFF2F5F8F), floorNextParty: Color(0xFF5F6670),
  );

  /// The palette a [LightTone] paints.
  static AppShellScheme of(LightTone t) => switch (t) {
        LightTone.white => white,
        LightTone.beige => beige,
        LightTone.grey => grey,
      };

  /// Every accent ramp is tuned for a near-black ground: its `hi` stop is the
  /// BRIGHT end, which on a white page is the unreadable end. Rather than hand
  /// a second catalogue of eight ramps, the light ramp is DERIVED from the
  /// owner's accent — same hue, lightness walked until each stop clears its
  /// contrast target against the darkest ground of [palette] — so the accent
  /// the device already wears carries into light mode, and every stop passes
  /// by construction instead of by hand-tuning.
  ///
  /// The ramp keeps its meaning ("hi" = the most emphatic ink, "mid" = the
  /// bottom of a filled control) and flips its direction: hi is the darkest.
  /// A filled control's ink becomes white, which clears AA on base and mid
  /// because both are held to 4.5:1 against grounds no brighter than white.
  /// The glow trio becomes pale tints of the hue, so the backdrop reads as a
  /// warm wash on paper rather than a brown stain.
  static AppAccent accentFor(AppAccent accent, AppShellScheme palette) {
    final grounds = [
      palette.bg, palette.bgDeep, palette.surface, palette.card,
      palette.cardTop, palette.cardBottom, palette.cardRaised, palette.inset,
    ];
    final darkest = grounds.reduce(
        (a, b) => relativeLuminance(a) <= relativeLuminance(b) ? a : b);
    final hsl = HSLColor.fromColor(accent.base);
    final sat = (hsl.saturation * 1.15).clamp(0.30, 0.70);

    // Largest lightness whose colour still clears [target] on the darkest
    // ground. Contrast against a light ground falls as lightness rises, so the
    // search converges from the passing side.
    Color stop(double target) {
      Color at(double l) => hsl.withSaturation(sat).withLightness(l).toColor();
      var lo = 0.0, hi = 1.0;
      for (var i = 0; i < 24; i++) {
        final mid = (lo + hi) / 2;
        if (contrastRatio(at(mid), darkest) >= target) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      return at(lo);
    }

    Color tint(double l, double s) =>
        hsl.withSaturation(s).withLightness(l).toColor();

    return AppAccent(
      id: accent.id,
      label: accent.label,
      hi: stop(7.0),
      base: stop(5.2),
      mid: stop(4.6),
      deep: stop(3.0),
      shadow: stop(1.6),
      on: const Color(0xFFFFFFFF),
      glowBright: tint(0.74, 0.80),
      glowMid: tint(0.82, 0.70),
      glowDeep: tint(0.88, 0.60),
    );
  }
}

/// Per-DEVICE appearance for the owner app: which accent the Rustic Fork shell
/// wears. Persisted in SharedPreferences, NOT on the server, on purpose:
///
///  * Two tills of the same restaurant are two different working contexts —
///    the bar till and the floor till may want different accents precisely so
///    staff can tell at a glance which machine they are on. Server state would
///    force them to match.
///  * It is pure chrome. Nothing about the business changes with it, so it has
///    no place in the tenant's audited settings document, and it must keep
///    working offline and before login.
///
/// The guest-facing branding (what CUSTOMERS see) is the opposite — tenant
/// state with audit history — and stays server-side in brand_config.
///
/// A compact/comfortable density toggle was considered and deliberately
/// skipped: AppSpacing is consumed as `const EdgeInsets` in every module, so
/// honest density would mean de-consting call sites across all 24 modules for
/// a marginal win. The accent, by contrast, flows through AppColors getters
/// with no per-module edits.
class AppearanceController extends ChangeNotifier {
  AppearanceController._();

  static final AppearanceController instance = AppearanceController._();

  static const String _prefsKey = 'appearance.accent';
  static const String _schemePrefsKey = 'appearance.scheme';
  static const String _designPrefsKey = 'appearance.designSystem';
  static const String _uiModePrefsKey = 'appearance.uiMode';
  static const String _lightTonePrefsKey = 'appearance.lightTone';
  static const String _washPrefsKey = 'appearance.backdrop.wash';
  static const String _bloomPrefsKey = 'appearance.backdrop.bloom';
  static const String _anglePrefsKey = 'appearance.backdrop.angle';
  static const String _intensityPrefsKey = 'appearance.backdrop.intensity';

  String _accentId = AppAccents.defaultId;
  String get accentId => _accentId;
  AppAccent get accent => AppAccents.byId(_accentId);

  String _schemeId = AppSchemes.defaultId;
  String get schemeId => _schemeId;
  AppShellScheme get scheme => AppSchemes.byId(_schemeId);

  BackdropStyle _backdrop = const BackdropStyle();
  BackdropStyle get backdrop => _backdrop;

  /// Which visual language is on. Defaults to [DesignSystem.rustic] — the
  /// shipped look — so nothing changes for anyone who does not opt in.
  DesignSystem _designSystem = DesignSystem.rustic;
  DesignSystem get designSystem => _designSystem;

  /// 6.6 — light mode on/off. Off (Dark, the shipped look) by default.
  bool _lightMode = false;
  bool get lightMode => _lightMode;

  /// 6.6 — the ground light mode wears. Kept while Dark is on.
  LightTone _lightTone = LightTone.defaultTone;
  LightTone get lightTone => _lightTone;

  /// The menu row that carries the tick — `'dark'` or a [LightTone] id — the
  /// same value space as the web's `activeAppearance`.
  String get themePick => _lightMode ? _lightTone.id : 'dark';

  /// True when light mode is chosen AND actually painted. Gaia brings its own
  /// dark palette, so under Gaia the choice is remembered, not applied.
  bool get lightActive => _lightMode && _designSystem != DesignSystem.gaia;

  /// The single place the AppColors ladder is set, so accent/scheme/design
  /// can never disagree about what is currently painted.
  ///
  /// While Gaia is on, its palette PINS the ladder: the owner's accent and
  /// scheme choices are still remembered (and still shown in their pickers),
  /// they simply are not applied, because a champagne-on-forest design does
  /// not have a copper variant. Turning Gaia off re-applies exactly what was
  /// stored, which is what makes this reversible rather than destructive.
  void _applyPalette() {
    if (_designSystem == DesignSystem.gaia) {
      AppColors.applyShell(GaiaColors.shellBridge);
      AppColors.applyAccent(GaiaColors.accentBridge);
    } else if (_lightMode) {
      final light = AppLightPalettes.of(_lightTone);
      // 6.6 — a light palette pins the shell (the schemes are all dark) and
      // re-derives the owner's accent for a light ground.
      AppColors.applyShell(light);
      AppColors.applyAccent(
          AppLightPalettes.accentFor(AppAccents.byId(_accentId), light));
    } else {
      AppColors.applyShell(AppSchemes.byId(_schemeId));
      AppColors.applyAccent(AppAccents.byId(_accentId));
    }
  }

  // '#RRGGBB' <-> Color. Prefs-only: anything unparseable loads as null
  // ("follow the accent"), never as a junk colour.
  static String _hexOf(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  static Color? _colorOf(String? hex) {
    if (hex == null) return null;
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
    if (m == null) return null;
    return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
  }

  /// Restore the device's appearance before the first frame (called from
  /// main()). Any failure (fresh install, corrupt prefs) lands on the shipped
  /// copper-on-rustic default.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _accentId = AppAccents.byId(prefs.getString(_prefsKey)).id;
      _schemeId = AppSchemes.byId(prefs.getString(_schemePrefsKey)).id;
      _designSystem = DesignSystem.byId(prefs.getString(_designPrefsKey));
      _lightMode = prefs.getString(_uiModePrefsKey) == 'light';
      _lightTone = LightTone.byId(prefs.getString(_lightTonePrefsKey));
      _backdrop = BackdropStyle(
        wash: _colorOf(prefs.getString(_washPrefsKey)),
        bloom: _colorOf(prefs.getString(_bloomPrefsKey)),
        angleDeg: (prefs.getDouble(_anglePrefsKey) ?? BackdropStyle.defaultAngle) % 360,
        intensity: (prefs.getDouble(_intensityPrefsKey) ?? 1.0).clamp(0.0, 1.0),
      );
    } catch (_) {
      _accentId = AppAccents.defaultId;
      _schemeId = AppSchemes.defaultId;
      _designSystem = DesignSystem.rustic;
      _lightMode = false;
      _lightTone = LightTone.defaultTone;
      _backdrop = const BackdropStyle();
    }
    _applyPalette();
    notifyListeners();
  }

  Future<void> setAccent(String id) async {
    final resolved = AppAccents.byId(id);
    if (resolved.id == _accentId) return;
    _accentId = resolved.id;
    // Through _applyPalette, not applyAccent directly: while Gaia is on this
    // stores the choice without repainting, so the picker stays honest about
    // what the device will wear when Gaia is turned back off.
    _applyPalette();
    // Notify FIRST so the UI recolours instantly; persistence is best-effort
    // (a failed write only means the choice doesn't survive a restart).
    notifyListeners();
    await _persist(_prefsKey, resolved.id);
  }

  Future<void> setScheme(String id) async {
    final resolved = AppSchemes.byId(id);
    if (resolved.id == _schemeId) return;
    _schemeId = resolved.id;
    _applyPalette();
    notifyListeners();
    await _persist(_schemePrefsKey, resolved.id);
  }

  /// Flip the whole visual language. Live: the app root listens to this
  /// controller and rebuilds its MaterialApp with the other ThemeData, so the
  /// switch restyles in place with no restart.
  Future<void> setDesignSystem(DesignSystem system) async {
    if (system == _designSystem) return;
    _designSystem = system;
    _applyPalette();
    notifyListeners();
    await _persist(_designPrefsKey, system.id);
  }

  /// 6.6 — what picking a row of the theme menu does: [pick] is `'dark'` or a
  /// [LightTone] id (the web's `applyAppearancePick`, same rules):
  ///
  ///  * picking a TONE also switches to light — somebody in dark mode who taps
  ///    "Beige" wants to see beige, not a menu that seemed to do nothing;
  ///  * picking DARK leaves the tone alone, so light comes back in the colour
  ///    they chose.
  ///
  /// Live, like [setDesignSystem]: the app root rebuilds MaterialApp with the
  /// matching ThemeData. Persisted per device and restored by [load] before
  /// the first frame, so a light till never flashes dark on a cold start.
  Future<void> applyThemePick(String pick) async {
    final toLight = pick != 'dark';
    final tone = toLight ? LightTone.byId(pick) : _lightTone;
    if (toLight == _lightMode && tone == _lightTone) return;
    _lightMode = toLight;
    _lightTone = tone;
    _applyPalette();
    notifyListeners();
    await _persist(_uiModePrefsKey, toLight ? 'light' : 'dark');
    if (toLight) await _persist(_lightTonePrefsKey, tone.id);
  }

  /// One entry point for every backdrop knob (stops, angle, intensity), so the
  /// Appearance card's controls and the one-tap "back to scheme default"
  /// (`setBackdrop(const BackdropStyle())`) walk the same path.
  Future<void> setBackdrop(BackdropStyle style) async {
    final normalized = BackdropStyle(
      wash: style.wash,
      bloom: style.bloom,
      angleDeg: style.angleDeg % 360,
      intensity: style.intensity.clamp(0.0, 1.0),
    );
    if (normalized == _backdrop) return;
    _backdrop = normalized;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      // A null stop means "follow the accent" — persisted as ABSENCE so a
      // future default change reaches devices that never pinned a colour.
      if (normalized.wash == null) {
        await prefs.remove(_washPrefsKey);
      } else {
        await prefs.setString(_washPrefsKey, _hexOf(normalized.wash!));
      }
      if (normalized.bloom == null) {
        await prefs.remove(_bloomPrefsKey);
      } else {
        await prefs.setString(_bloomPrefsKey, _hexOf(normalized.bloom!));
      }
      await prefs.setDouble(_anglePrefsKey, normalized.angleDeg);
      await prefs.setDouble(_intensityPrefsKey, normalized.intensity);
    } catch (_) {/* keep the in-memory choice */}
  }

  Future<void> _persist(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {/* keep the in-memory choice */}
  }

  /// Test hook: reset the in-memory state without touching persistence.
  @visibleForTesting
  void debugReset() {
    _accentId = AppAccents.defaultId;
    _schemeId = AppSchemes.defaultId;
    _designSystem = DesignSystem.rustic;
    _lightMode = false;
    _lightTone = LightTone.defaultTone;
    _backdrop = const BackdropStyle();
    _applyPalette();
    notifyListeners();
  }
}
