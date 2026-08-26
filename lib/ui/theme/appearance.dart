import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';

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

  String _accentId = AppAccents.defaultId;
  String get accentId => _accentId;
  AppAccent get accent => AppAccents.byId(_accentId);

  /// Restore the device's accent before the first frame (called from main()).
  /// Any failure (fresh install, corrupt prefs) lands on the copper default.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _accentId = AppAccents.byId(prefs.getString(_prefsKey)).id;
    } catch (_) {
      _accentId = AppAccents.defaultId;
    }
    AppColors.applyAccent(AppAccents.byId(_accentId));
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, resolved.id);
    } catch (_) {/* keep the in-memory choice */}
  }

  /// Test hook: reset the in-memory state without touching persistence.
  @visibleForTesting
  void debugReset() {
    _accentId = AppAccents.defaultId;
    AppColors.applyAccent(AppAccents.copper);
    notifyListeners();
  }
}
