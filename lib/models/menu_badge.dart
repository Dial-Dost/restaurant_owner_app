/// Configurable menu badges, owner-app side.
///
/// The backend owns the rules (Restaurant_Backend/menu_badges.ts): which badges
/// a restaurant has, what they are called, and how a dish's tags plus its
/// allergen list resolve into the ordered list a diner sees. This file is the
/// client half — the model, the same ordering rule (so the owner previews what
/// a guest gets), and the colour each kind takes.
///
/// ABSENT = NOTHING. A restaurant that never opened the badges editor has an
/// empty catalogue, and every function here returns nothing for it rather than
/// falling back to a starter set. A badge is a claim; a claim nobody made must
/// not appear on a menu.
///
/// KIND IS NOT DECORATION. `alert` (contains nuts, spicy) and `diet` (Jain,
/// vegan) are facts a diner acts on: they sort first and a tight layout may not
/// trim them. Only `promo` — the restaurant's own recommendation — is ever cut,
/// and only after the count of what was cut is shown.
library;

import 'package:flutter/material.dart';

import '../ui/theme/app_colors.dart';

enum MenuBadgeKind { alert, diet, promo }

/// Sort order, and the order the three groups are shown in every editor.
const List<MenuBadgeKind> kMenuBadgeKinds = [MenuBadgeKind.alert, MenuBadgeKind.diet, MenuBadgeKind.promo];

const Map<MenuBadgeKind, String> kMenuBadgeKindLabel = {
  MenuBadgeKind.alert: 'Warning',
  MenuBadgeKind.diet: 'Dietary',
  MenuBadgeKind.promo: 'Highlight',
};

const Map<MenuBadgeKind, String> kMenuBadgeKindHint = {
  MenuBadgeKind.alert: 'Warn before ordering. Always shown to guests.',
  MenuBadgeKind.diet: 'What a guest can and cannot eat. Always shown.',
  MenuBadgeKind.promo: 'Your own recommendation. Trimmed first on a small card.',
};

MenuBadgeKind menuBadgeKindFrom(Object? raw) {
  final s = '${raw ?? ''}'.trim().toLowerCase();
  // Unknown falls to `promo`, the SAFE direction: a typo may demote a badge out
  // of the always-visible safety lane, never promote one into it.
  if (s == 'alert') return MenuBadgeKind.alert;
  if (s == 'diet') return MenuBadgeKind.diet;
  return MenuBadgeKind.promo;
}

String menuBadgeKindName(MenuBadgeKind k) => k.name;

class MenuBadge {
  /// Stable slug. Tags point at this, so renaming the label keeps every tag.
  final String id;
  final String label;
  final MenuBadgeKind kind;
  final bool enabled;

  /// `alert` only: the badge is DERIVED from the dish's allergen list rather
  /// than hand-tagged, so there is one store of "this dish contains nuts" and
  /// the tagger cannot switch it off.
  final String allergen;

  const MenuBadge({
    required this.id,
    required this.label,
    required this.kind,
    this.enabled = true,
    this.allergen = '',
  });

  bool get derived => kind == MenuBadgeKind.alert && allergen.isNotEmpty;

  /// Kinds a tenant may not quietly drop while dishes still carry them.
  bool get protected => kind != MenuBadgeKind.promo;

  MenuBadge copyWith({String? label, MenuBadgeKind? kind, bool? enabled}) => MenuBadge(
        id: id,
        label: label ?? this.label,
        kind: kind ?? this.kind,
        enabled: enabled ?? this.enabled,
        allergen: allergen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': menuBadgeKindName(kind),
        'enabled': enabled,
        if (allergen.isNotEmpty) 'allergen': allergen,
      };

  static MenuBadge? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final kind = menuBadgeKindFrom(raw['kind']);
    final label = '${raw['label'] ?? ''}'.trim();
    return MenuBadge(
      id: id,
      label: label.isEmpty ? id : label,
      kind: kind,
      // Absent means enabled — a payload from a client that predates the flag
      // must not silently switch every badge off.
      enabled: raw['enabled'] != false,
      // Only an alert may be allergen-derived; anywhere else the link would
      // wrongly suppress the dish's plain allergen chip on the guest page.
      allergen: kind == MenuBadgeKind.alert ? '${raw['allergen'] ?? ''}'.trim().toLowerCase() : '',
    );
  }
}

/// Parse a catalogue payload. Anything unusable resolves to an EMPTY list.
List<MenuBadge> parseMenuBadges(Object? raw) {
  if (raw is! List) return const [];
  final out = <MenuBadge>[];
  for (final entry in raw) {
    final b = MenuBadge.tryParse(entry);
    if (b != null && !out.any((x) => x.id == b.id)) out.add(b);
  }
  return out;
}

/// Slug rule, mirroring the server's menuBadgeSlug so ids agree on both sides.
String menuBadgeSlug(String label) {
  final s = label
      .trim()
      .toLowerCase()
      .replaceAll(RegExp("['’]"), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return s.length > 32 ? s.substring(0, 32) : s;
}

/// The badges one dish wears, in the order a guest sees them.
///
/// Mirrors the server's resolveMenuBadges: tagged ids filtered to the enabled
/// catalogue (derived ones excluded — a tag is not how they get there), unioned
/// with every enabled allergen-derived alert the dish's allergens trigger, then
/// ordered by kind and by catalogue position.
List<MenuBadge> resolveMenuBadges(List<MenuBadge> catalogue, Object? tagged, Object? allergens) {
  final enabled = catalogue.where((b) => b.enabled).toList();
  if (enabled.isEmpty) return const [];
  final tags = <String>{
    if (tagged is List) ...tagged.map((t) => '$t'.trim()).where((t) => t.isNotEmpty),
  };
  final allergenTags = <String>{
    if (allergens is List) ...allergens.map((a) => '$a'.trim().toLowerCase()).where((a) => a.isNotEmpty),
  };
  final picked = <MapEntry<int, MenuBadge>>[];
  for (var i = 0; i < enabled.length; i++) {
    final b = enabled[i];
    final hit = b.derived ? allergenTags.contains(b.allergen) : tags.contains(b.id);
    if (hit) picked.add(MapEntry(i, b));
  }
  picked.sort((a, b) {
    final rank = kMenuBadgeKinds.indexOf(a.value.kind) - kMenuBadgeKinds.indexOf(b.value.kind);
    return rank != 0 ? rank : a.key - b.key;
  });
  return picked.map((e) => e.value).toList();
}

/// Allergen tags an enabled derived badge already states, so the dish's plain
/// allergen list can drop them and never print the same fact twice.
Set<String> menuBadgeCoveredAllergens(List<MenuBadge> catalogue) =>
    catalogue.where((b) => b.enabled && b.derived).map((b) => b.allergen).toSet();

/// Trim for a surface with no room. Only `promo` may be cut; the count of what
/// was cut comes back so a tile can say "+2" instead of swallowing them.
({List<MenuBadge> shown, int hidden}) capMenuBadges(List<MenuBadge> resolved, int promoLimit) {
  final limit = promoLimit > 0 ? promoLimit : 0;
  final shown = <MenuBadge>[];
  var promoSeen = 0;
  var hidden = 0;
  for (final b in resolved) {
    if (b.kind != MenuBadgeKind.promo) {
      shown.add(b);
      continue;
    }
    if (promoSeen < limit) {
      shown.add(b);
      promoSeen += 1;
    } else {
      hidden += 1;
    }
  }
  return (shown: shown, hidden: hidden);
}

/// The colour a kind takes.
///
/// Only `promo` wears the brand copper. A warning must not inherit the app's
/// accent, because an accent reads as "look at this nice thing" — which is
/// exactly wrong on "Contains nuts". Warnings take the warning tone, dietary
/// badges the success tone.
Color menuBadgeColor(MenuBadgeKind kind) {
  switch (kind) {
    case MenuBadgeKind.alert:
      return AppColors.warning;
    case MenuBadgeKind.diet:
      return AppColors.success;
    case MenuBadgeKind.promo:
      return AppColors.copperHi;
  }
}
