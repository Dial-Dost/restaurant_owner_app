import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/menu_badge.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/menu_badges.dart';

/// Configurable menu badges, owner-app side.
///
/// Three claims are worth pinning, because getting any of them wrong is
/// invisible until it is on a real menu in front of a real diner:
///
///  1. ABSENT = NOTHING. Every existing restaurant has no catalogue. If parsing
///     or resolving ever fell back to the starter set, dishes would sprout
///     claims ("Bestseller", "Contains nuts") that nobody made.
///  2. TRIMMING MAY ONLY EVER DROP MARKETING. A tile that trims "Contains nuts"
///     to fit a "Bestseller" is the exact failure this design exists to stop.
///  3. AN ALLERGEN BADGE CANNOT BE UNTAGGED. It comes from the dish's allergen
///     list, so there is one store of the fact and no switch that hides it.
void main() {
  const catalogue = [
    MenuBadge(id: 'must_try', label: 'Must Try', kind: MenuBadgeKind.promo),
    MenuBadge(id: 'bestseller', label: 'Bestseller', kind: MenuBadgeKind.promo),
    MenuBadge(id: 'jain', label: 'Jain', kind: MenuBadgeKind.diet),
    MenuBadge(id: 'spicy', label: 'Spicy', kind: MenuBadgeKind.alert),
    MenuBadge(id: 'contains_nuts', label: 'Contains nuts', kind: MenuBadgeKind.alert, allergen: 'nuts'),
    MenuBadge(id: 'retired', label: 'Retired', kind: MenuBadgeKind.promo, enabled: false),
  ];

  group('parsing', () {
    test('anything unusable resolves to an EMPTY catalogue, never a default set', () {
      expect(parseMenuBadges(null), isEmpty);
      expect(parseMenuBadges('must_try'), isEmpty);
      expect(parseMenuBadges(<dynamic>[]), isEmpty);
      expect(parseMenuBadges(<dynamic>[null, 7, 'x', <String, dynamic>{}]), isEmpty);
      // An entry with no id has nothing for a tag to point at.
      expect(parseMenuBadges([<String, dynamic>{'label': 'No id'}]), isEmpty);
    });

    test('round-trips a catalogue and keeps the tenant order', () {
      final json = [for (final b in catalogue) b.toJson()];
      final back = parseMenuBadges(json);
      expect(back.map((b) => b.id).toList(), catalogue.map((b) => b.id).toList());
      expect(back.map((b) => b.label).toList(), catalogue.map((b) => b.label).toList());
      expect(back.map((b) => b.kind).toList(), catalogue.map((b) => b.kind).toList());
      expect(back.map((b) => b.enabled).toList(), catalogue.map((b) => b.enabled).toList());
      expect(back.firstWhere((b) => b.id == 'contains_nuts').allergen, 'nuts');
    });

    test('an unknown kind lands on promo — a typo may demote, never promote', () {
      expect(menuBadgeKindFrom('danger'), MenuBadgeKind.promo);
      expect(menuBadgeKindFrom(null), MenuBadgeKind.promo);
      expect(menuBadgeKindFrom('ALERT'), MenuBadgeKind.alert);
    });

    test('only an alert may be allergen-derived', () {
      final b = parseMenuBadges([
        {'id': 'v', 'label': 'Vegan', 'kind': 'diet', 'allergen': 'dairy'},
      ]).single;
      // A dietary badge that suppressed the dish's allergen chip would hide a
      // safety fact behind a label that does not state it.
      expect(b.allergen, '');
      expect(b.derived, isFalse);
    });

    test('an absent enabled flag means enabled, so no client can go dark', () {
      expect(parseMenuBadges([{'id': 'a', 'label': 'A'}]).single.enabled, isTrue);
      expect(parseMenuBadges([{'id': 'a', 'label': 'A', 'enabled': false}]).single.enabled, isFalse);
    });

    test('a blank label falls back to the id rather than rendering an empty pill', () {
      expect(parseMenuBadges([{'id': 'must_try', 'label': '  '}]).single.label, 'must_try');
    });

    test('the slug rule matches the server, so ids agree on both sides', () {
      expect(menuBadgeSlug("Chef's Special"), 'chefs_special');
      expect(menuBadgeSlug('  Must   Try!  '), 'must_try');
      expect(menuBadgeSlug('!!!'), '');
    });
  });

  group('resolution', () {
    test('an empty catalogue resolves to nothing, whatever the dish carries', () {
      expect(resolveMenuBadges(const [], ['must_try', 'jain'], ['nuts']), isEmpty);
    });

    test('an untagged dish with no allergens resolves to nothing', () {
      expect(resolveMenuBadges(catalogue, null, null), isEmpty);
      expect(resolveMenuBadges(catalogue, <dynamic>[], <dynamic>[]), isEmpty);
    });

    test('orders alert -> diet -> promo, then by catalogue position', () {
      final ids = resolveMenuBadges(catalogue, ['bestseller', 'must_try', 'jain', 'spicy'], <dynamic>[])
          .map((b) => b.id)
          .toList();
      expect(ids, ['spicy', 'jain', 'must_try', 'bestseller']);
    });

    test('unknown and disabled tags are dropped', () {
      expect(
        resolveMenuBadges(catalogue, ['ghost', 'retired', 'must_try'], <dynamic>[]).map((b) => b.id).toList(),
        ['must_try'],
      );
    });

    test('an allergen badge comes from the dish, and a tag cannot switch it off', () {
      expect(resolveMenuBadges(catalogue, <dynamic>[], ['Nuts']).map((b) => b.id).toList(), ['contains_nuts']);
      // Tagging it by hand conjures nothing: there is ONE store of this fact.
      expect(resolveMenuBadges(catalogue, ['contains_nuts'], <dynamic>[]), isEmpty);
      // Which is the property that matters — you cannot untag a nut warning.
      expect(resolveMenuBadges(catalogue, <dynamic>[], ['nuts', 'gluten']).map((b) => b.id).toList(), ['contains_nuts']);
    });

    test('covered allergens name the chips a badge already speaks for', () {
      expect(menuBadgeCoveredAllergens(catalogue), {'nuts'});
      final off = [
        for (final b in catalogue) b.id == 'contains_nuts' ? b.copyWith(enabled: false) : b,
      ];
      // A disabled derived badge covers nothing, so the fact falls back to the
      // dish's plain allergen list rather than disappearing entirely.
      expect(menuBadgeCoveredAllergens(off), isEmpty);
      expect(menuBadgeCoveredAllergens(const []), isEmpty);
    });
  });

  group('trimming for a tight tile', () {
    final resolved = resolveMenuBadges(catalogue, ['must_try', 'bestseller', 'jain', 'spicy'], ['nuts']);

    test('never drops an alert or a dietary badge, however tight', () {
      for (final limit in [0, 1, 2, 5]) {
        final capped = capMenuBadges(resolved, limit);
        expect(capped.shown.where((b) => b.kind == MenuBadgeKind.alert).map((b) => b.id).toList(),
            ['spicy', 'contains_nuts']);
        expect(capped.shown.where((b) => b.kind == MenuBadgeKind.diet).map((b) => b.id).toList(), ['jain']);
      }
    });

    test('trims highlights and counts what it trimmed', () {
      expect(capMenuBadges(resolved, 1).shown.map((b) => b.id).toList(),
          ['spicy', 'contains_nuts', 'jain', 'must_try']);
      expect(capMenuBadges(resolved, 1).hidden, 1);
      expect(capMenuBadges(resolved, 0).hidden, 2);
      expect(capMenuBadges(resolved, 9).hidden, 0);
    });

    test('a nonsense limit means zero highlights, not unlimited', () {
      expect(capMenuBadges(resolved, -3).shown.every((b) => b.kind != MenuBadgeKind.promo), isTrue);
    });
  });

  group('kinds', () {
    test('everything except marketing is protected from a quiet removal', () {
      expect(catalogue.where((b) => b.protected).map((b) => b.id).toList(), ['jain', 'spicy', 'contains_nuts']);
      expect(catalogue.where((b) => b.derived).map((b) => b.id).toList(), ['contains_nuts']);
    });

    test('only marketing wears the brand accent', () {
      // The app's copper reads as "look at this nice thing", which is exactly
      // wrong on a nut warning. Warnings and dietary badges take the semantic
      // tones instead, and the three are never the same colour.
      expect(menuBadgeColor(MenuBadgeKind.promo), AppColors.copperHi);
      expect(menuBadgeColor(MenuBadgeKind.alert), AppColors.warning);
      expect(menuBadgeColor(MenuBadgeKind.diet), AppColors.success);
      final colors = <Color>{for (final k in kMenuBadgeKinds) menuBadgeColor(k)};
      expect(colors.length, kMenuBadgeKinds.length);
    });

    test('renaming a badge keeps its id, so every existing tag survives', () {
      final renamed = catalogue.firstWhere((b) => b.id == 'must_try').copyWith(label: "Owner's Pick");
      expect(renamed.id, 'must_try');
      expect(
        resolveMenuBadges([renamed], ['must_try'], <dynamic>[]).single.label,
        "Owner's Pick",
      );
    });
  });

  group('drawing', () {
    // The pill's label is a ChipLabel, which is a Flexible. Put straight inside
    // the pill's Container it was an "Incorrect use of ParentDataWidget" on
    // every pill ever drawn — the tile's badges and the whole tag-dishes dialog
    // — and no test had ever drawn one. Found by the 2.0.2 search registry,
    // which opens that dialog.
    for (final ds in DesignSystem.values) {
      testWidgets('a pill, a tile row and a cramped pill all draw cleanly (${ds.id})', (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(GaiaScope(
          system: ds,
          child: MaterialApp(
            theme: ds == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
            home: Scaffold(
              body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const MenuBadgePill(badge: MenuBadge(id: 'must_try', label: 'Must Try', kind: MenuBadgeKind.promo)),
                const MenuBadgePill(
                  badge: MenuBadge(id: 'jain', label: 'Jain', kind: MenuBadgeKind.diet),
                  dense: false,
                  faded: true,
                ),
                const MenuBadgeChips(
                  catalogue: catalogue,
                  item: {'badges': ['must_try', 'bestseller', 'jain'], 'allergens': ['nuts']},
                ),
                const SizedBox(
                  width: 60,
                  child: MenuBadgePill(
                    badge: MenuBadge(id: 'long', label: 'Chef recommends this one', kind: MenuBadgeKind.promo),
                  ),
                ),
              ]),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Must Try'), findsNWidgets(2));
        expect(find.text('Contains nuts'), findsOneWidget, reason: 'the allergen always shows');
        // A narrow parent ellipsises the label rather than overflowing.
        final long = tester.widget<Text>(find.text('Chef recommends this one'));
        expect(long.overflow, TextOverflow.ellipsis);
        expect(tester.getSize(find.text('Chef recommends this one')).width, lessThan(60));
      }, variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android, TargetPlatform.windows}));
    }
  });
}
