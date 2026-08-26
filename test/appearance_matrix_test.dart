import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/theme/backdrop_style.dart';
import 'package:restaurant_owner_app/ui/theme/contrast.dart';

/// The whole appearance matrix, pre-checked: every shell scheme x every accent
/// an owner can pick, measured — not hoped — at WCAG AA 4.5:1.
///
/// Scheme and accent compose FREELY in the UI, so the set of combinations that
/// can exist is exactly this product. Checking the matrix here means a new
/// scheme (or a retuned accent) that would make ANY combination unreadable
/// fails CI instead of failing on a till.
///
/// What is held to 4.5:1 and what is not:
///  * body ink (textPrimary, textSecondary) on every scheme surface — the
///    floor the shipped rustic shell already clears;
///  * accent hi/base on bg and surface — the readable accent stops, on the
///    grounds accent text actually sits on (the same guarantee the accent
///    catalogue has always tested against the rustic ground, now per scheme);
///  * secondary ink and accent hi on the DERIVED drawer glow (the phone
///    sidebar is opaque chrome — its brightest band is clamped in AppColors
///    precisely so this holds for every glow ramp).
///  * textTertiary is NOT held to 4.5: it is deliberately muted furniture
///    (labels the shipped shell also renders below AA), not body text.
void main() {
  tearDown(() {
    AppColors.applyAccent(AppAccents.copper);
    AppColors.applyShell(AppSchemes.rustic);
  });

  test('catalogue shape: 5 schemes x 8 accents, rustic/copper defaults', () {
    expect(AppSchemes.all.length, 5);
    expect(AppAccents.all.length, 8);
    expect(AppSchemes.defaultId, 'rustic');
    expect(AppSchemes.byId('junk').id, 'rustic');
    expect(AppSchemes.byId(null).id, 'rustic');
  });

  test('rustic is byte-identical to the shipped shell constants', () {
    const s = AppSchemes.rustic;
    expect(identical(s, AppColors.rusticShell), isTrue);
    expect(s.bg, const Color(0xFF0C0A09));
    expect(s.bgDeep, const Color(0xFF080605));
    expect(s.surface, const Color(0xFF151211));
    expect(s.card, const Color(0xFF1B1716));
    expect(s.cardTop, const Color(0xFF201B1A));
    expect(s.cardBottom, const Color(0xFF181412));
    expect(s.cardRaised, const Color(0xFF231E1E));
    expect(s.inset, const Color(0xFF110E0D));
    expect(s.textPrimary, const Color(0xFFECEAE6));
    expect(s.textSecondary, const Color(0xFF9A978F));
    expect(s.textTertiary, const Color(0xFF615E57));
  });

  test('every scheme x accent combination clears WCAG AA 4.5:1', () {
    final failures = <String>[];
    void check(String what, double ratio) {
      if (ratio < 4.5) failures.add('$what = ${ratio.toStringAsFixed(2)}');
    }

    for (final s in AppSchemes.all) {
      final surfaces = <String, Color>{
        'bg': s.bg,
        'bgDeep': s.bgDeep,
        'surface': s.surface,
        'card': s.card,
        'cardTop': s.cardTop,
        'cardBottom': s.cardBottom,
        'cardRaised': s.cardRaised,
        'inset': s.inset,
      };
      for (final e in surfaces.entries) {
        check('${s.id}: textPrimary/${e.key}', contrastRatio(s.textPrimary, e.value));
        check('${s.id}: textSecondary/${e.key}', contrastRatio(s.textSecondary, e.value));
      }
      for (final a in AppAccents.all) {
        check('${s.id} x ${a.id}: hi/bg', contrastRatio(a.hi, s.bg));
        check('${s.id} x ${a.id}: base/bg', contrastRatio(a.base, s.bg));
        check('${s.id} x ${a.id}: hi/surface', contrastRatio(a.hi, s.surface));
        check('${s.id} x ${a.id}: base/surface', contrastRatio(a.base, s.surface));

        // The composed chrome: apply the pair and read the LIVE derivations,
        // so the clamp in AppColors.drawerTop is itself under test.
        AppColors.applyShell(s);
        AppColors.applyAccent(a);
        check('${s.id} x ${a.id}: textSecondary/drawerTop',
            contrastRatio(s.textSecondary, AppColors.drawerTop));
        check('${s.id} x ${a.id}: textSecondary/drawerMid',
            contrastRatio(s.textSecondary, AppColors.drawerMid));
        check('${s.id} x ${a.id}: textSecondary/drawerBottom',
            contrastRatio(s.textSecondary, AppColors.drawerBottom));
        check('${s.id} x ${a.id}: hi/drawerTop', contrastRatio(a.hi, AppColors.drawerTop));
      }
    }

    expect(failures, isEmpty,
        reason: 'unreadable scheme x accent combinations:\n${failures.join('\n')}');
  });

  test('backdrop guard: text never sits on an unreadable gradient extreme', () {
    // The owner can type ANY hex into the wash/bloom fields. The guard's job
    // is that the WORST reachable stop — pure white, a hot pink, a bright
    // amber — still composes a surface primary ink clears at 4.5:1, for every
    // scheme x accent it could be mixed with. Checked at the two extremes text
    // actually meets: the wash's opaque top stop, and the bloom's centre
    // floating on that wash.
    const worstStops = <String, Color>{
      'white': Color(0xFFFFFFFF),
      'black': Color(0xFF000000),
      'hotpink': Color(0xFFFF69B4),
      'amber': Color(0xFFFFC107),
    };
    final failures = <String>[];
    void check(String what, double ratio) {
      if (ratio < 4.5) failures.add('$what = ${ratio.toStringAsFixed(2)}');
    }

    for (final s in AppSchemes.all) {
      for (final a in AppAccents.all) {
        final stops = <String, Color?>{
          ...worstStops,
          'glowBright': a.glowBright,
          'accent-default': null, // follow the accent
        };
        for (final e in stops.entries) {
          final r = resolveBackdrop(
            style: BackdropStyle(wash: e.value, bloom: e.value, angleDeg: 37, intensity: 1.0),
            glowBright: a.glowBright,
            glowMid: a.glowMid,
            glowDeep: a.glowDeep,
            bg: s.bg,
            ink: s.textPrimary,
          );
          check('${s.id} x ${a.id} wash=${e.key}', contrastRatio(s.textPrimary, r.washColor));
          final underBloom = Color.alphaBlend(
              r.bloomColor.withValues(alpha: r.bloomOpacity), r.washColor);
          check('${s.id} x ${a.id} bloom=${e.key}', contrastRatio(s.textPrimary, underBloom));
        }
      }
    }

    expect(failures, isEmpty,
        reason: 'backdrop extremes an owner could make unreadable:\n${failures.join('\n')}');
  });

  test('backdrop guard does not touch the shipped copper default', () {
    // Copper glowDeep at full strength already clears the floor (7.79:1 under
    // rustic primary ink), so the guarded resolution of the DEFAULT style must
    // be the unclamped blend — the guard exists for the extremes, not to
    // quietly dim the look that shipped.
    final r = resolveBackdrop(
      style: const BackdropStyle(),
      glowBright: AppAccents.copper.glowBright,
      glowMid: AppAccents.copper.glowMid,
      glowDeep: AppAccents.copper.glowDeep,
      bg: AppSchemes.rustic.bg,
      ink: AppSchemes.rustic.textPrimary,
    );
    expect(r.washColor,
        Color.alphaBlend(AppAccents.copper.glowDeep.withValues(alpha: 1.0), AppSchemes.rustic.bg));
    expect(r.bloomOpacity, closeTo(0.34, 1e-9));
    expect(r.orbNearOpacity, closeTo(0.22, 1e-9));
    expect(r.orbFarOpacity, closeTo(0.22, 1e-9));
    // And intensity 0 means a genuinely flat page: the wash IS the ground.
    final flat = resolveBackdrop(
      style: const BackdropStyle(intensity: 0),
      glowBright: AppAccents.copper.glowBright,
      glowMid: AppAccents.copper.glowMid,
      glowDeep: AppAccents.copper.glowDeep,
      bg: AppSchemes.rustic.bg,
      ink: AppSchemes.rustic.textPrimary,
    );
    expect(flat.washColor, AppSchemes.rustic.bg);
    expect(flat.bloomOpacity, 0.0);
  });

  test('backdrop angle maps CSS degrees onto the Flutter axis', () {
    ResolvedBackdrop at(double deg) => resolveBackdrop(
          style: BackdropStyle(angleDeg: deg),
          glowBright: AppAccents.copper.glowBright,
          glowMid: AppAccents.copper.glowMid,
          glowDeep: AppAccents.copper.glowDeep,
          bg: AppSchemes.rustic.bg,
          ink: AppSchemes.rustic.textPrimary,
        );
    // 0° points up: the wash begins at the bottom and runs upward.
    expect(at(0).washBegin.y, closeTo(1, 1e-9));
    expect(at(0).washEnd.y, closeTo(-1, 1e-9));
    // 90° points right: left -> right.
    expect(at(90).washBegin.x, closeTo(-1, 1e-9));
    expect(at(90).washEnd.x, closeTo(1, 1e-9));
    // 180° points down: top -> bottom.
    expect(at(180).washBegin.y, closeTo(-1, 1e-9));
    expect(at(180).washEnd.y, closeTo(1, 1e-9));
    // 150° (the default) runs top-left -> bottom-right, like the guest hero.
    final d = at(150);
    expect(d.washBegin.x, lessThan(0));
    expect(d.washBegin.y, closeTo(-1, 1e-9));
    expect(d.washEnd.x, greaterThan(0));
    expect(d.washEnd.y, closeTo(1, 1e-9));
  });
}
