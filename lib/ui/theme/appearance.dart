import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';
import 'backdrop_style.dart';

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
      _backdrop = BackdropStyle(
        wash: _colorOf(prefs.getString(_washPrefsKey)),
        bloom: _colorOf(prefs.getString(_bloomPrefsKey)),
        angleDeg: (prefs.getDouble(_anglePrefsKey) ?? BackdropStyle.defaultAngle) % 360,
        intensity: (prefs.getDouble(_intensityPrefsKey) ?? 1.0).clamp(0.0, 1.0),
      );
    } catch (_) {
      _accentId = AppAccents.defaultId;
      _schemeId = AppSchemes.defaultId;
      _backdrop = const BackdropStyle();
    }
    AppColors.applyAccent(AppAccents.byId(_accentId));
    AppColors.applyShell(AppSchemes.byId(_schemeId));
    notifyListeners();
  }

  Future<void> setAccent(String id) async {
    final resolved = AppAccents.byId(id);
    if (resolved.id == _accentId) return;
    _accentId = resolved.id;
    AppColors.applyAccent(resolved);
    // Notify FIRST so the UI recolours instantly; persistence is best-effort
    // (a failed write only means the choice doesn't survive a restart).
    notifyListeners();
    await _persist(_prefsKey, resolved.id);
  }

  Future<void> setScheme(String id) async {
    final resolved = AppSchemes.byId(id);
    if (resolved.id == _schemeId) return;
    _schemeId = resolved.id;
    AppColors.applyShell(resolved);
    notifyListeners();
    await _persist(_schemePrefsKey, resolved.id);
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
    _backdrop = const BackdropStyle();
    AppColors.applyAccent(AppAccents.copper);
    AppColors.applyShell(AppSchemes.rustic);
    notifyListeners();
  }
}
