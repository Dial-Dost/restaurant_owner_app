import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/menu_badge.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/menu_badges.dart';

/// A MENU BADGE PILL IS A LEGAL WIDGET TREE.
///
/// `ChipLabel` is a `Flexible`, so it is only valid as a direct child of a
/// Row/Column. `MenuBadgePill` put it straight inside its Container (a Padding),
/// which is not a Flex:
///
///   * debug — every pill reported "Incorrect use of ParentDataWidget", and the
///     label only rendered because debug skips applying the bad parent data;
///   * release — there is no such check: `Flexible.applyParentData` casts the
///     Padding's `BoxParentData` to `FlexParentData`, the cast throws, and the
///     framework swaps the label for an ErrorWidget — a grey box that fills its
///     constraints, 100,000 px tall on a menu tile (measured in a Windows
///     release build).
///
/// Pills are on every menu tile with a badge, in the dish detail sheet, the
/// badge catalogue and the bulk tagger — all of which are pumped here, in both
/// design systems, as Windows and as Android.
///
/// The fix keeps the look: where the label fits, the pill is pixel-for-pixel
/// the plain padded label it always drew; where it does not, the label
/// ellipsises inside the pill instead of overflowing it.

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

/// Each design system with the theme the app root pairs it with.
final _systems = <DesignSystem, ThemeData Function()>{
  DesignSystem.rustic: AppTheme.dark,
  DesignSystem.gaia: GaiaTheme.dark,
};

const _catalogue = [
  MenuBadge(id: 'must_try', label: 'Must Try', kind: MenuBadgeKind.promo),
  MenuBadge(id: 'bestseller', label: 'Bestseller', kind: MenuBadgeKind.promo),
  MenuBadge(id: 'chef_special', label: "Chef's special", kind: MenuBadgeKind.promo),
  MenuBadge(id: 'jain', label: 'Jain', kind: MenuBadgeKind.diet),
  MenuBadge(id: 'spicy', label: 'Spicy', kind: MenuBadgeKind.alert),
  MenuBadge(id: 'contains_nuts', label: 'Contains nuts', kind: MenuBadgeKind.alert, allergen: 'nuts'),
];

/// A dish wearing every kind, with one promo more than a tile shows.
const _dish = <String, dynamic>{
  'id': 'mi-1',
  'name': 'Paneer Tikka',
  'category': 'Starters',
  'badges': ['must_try', 'bestseller', 'chef_special', 'jain', 'spicy'],
  'allergens': ['nuts'],
};

Widget _host(DesignSystem system, Widget child) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: _systems[system]!(),
        home: Scaffold(body: child),
      ),
    );

void _viewport(WidgetTester tester, {Size size = const Size(1280, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

class _FakeApi extends ApiClient {
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Global Vegetarian',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  /// The catalogue editor saves on every action; the server answers with the
  /// catalogue it now holds.
  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    writes.add((method: method, path: path, body: body));
    if (path == '/menu/badges' && body is Map) return {'badges': body['badges']};
    return <String, dynamic>{'success': true};
  }
}

Future<(RestClient, _FakeApi)> _signIn() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi();
  final auth = AuthController(api: api);
  await auth.login('Gaia Global Vegetarian', 'admin', 'pw');
  return (RestClient(auth), api);
}

/// Opens [dialog] from a button, the way the menu module does.
Future<void> _open(WidgetTester tester, DesignSystem system, Widget dialog) async {
  await tester.pumpWidget(_host(
    system,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showDialog<bool>(context: context, builder: (_) => dialog),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final system in _systems.keys) {
    group('${system.name}:', () {
      testWidgets('a pill on its own, in a Wrap run and in a Row lays out without an error', (tester) async {
        _viewport(tester);
        await tester.pumpWidget(_host(
          system,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MenuBadgePill(badge: _catalogue.first),
            MenuBadgePill(badge: _catalogue.first, dense: false),
            MenuBadgePill(badge: _catalogue.first, faded: true),
            Wrap(spacing: 5, children: [for (final b in _catalogue) MenuBadgePill(badge: b)]),
            // The catalogue editor's row: pill, then an Expanded caption.
            Row(children: [
              MenuBadgePill(badge: _catalogue.last, dense: false),
              const Expanded(child: Text('Automatic — on any dish listing "nuts"')),
            ]),
          ]),
        ));
        expect(tester.takeException(), isNull);
        expect(find.byType(MenuBadgePill), findsNWidgets(4 + _catalogue.length));
        expect(find.text('Must Try'), findsNWidgets(4));
      }, variant: _platforms);

      testWidgets('the chips on a menu tile and in the dish sheet lay out without an error', (tester) async {
        _viewport(tester);
        await tester.pumpWidget(_host(
          system,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // A tile's name column is narrow; the sheet is not, and shows all.
            const SizedBox(width: 180, child: MenuBadgeChips(catalogue: _catalogue, item: _dish)),
            const SizedBox(height: 20),
            const MenuBadgeChips(catalogue: _catalogue, item: _dish, promoLimit: 99),
          ]),
        ));
        expect(tester.takeException(), isNull);
        expect(find.text('Contains nuts'), findsNWidgets(2), reason: 'a warning is never trimmed');
        expect(find.text('+1'), findsOneWidget, reason: 'the tile trims one promo');
        expect(find.byType(MenuBadgePill), findsNWidgets(5 + 6));
      }, variant: _platforms);

      testWidgets('squeezed, the label ellipsises inside the pill instead of overflowing', (tester) async {
        _viewport(tester);
        const long = MenuBadge(id: 'long', label: 'Contains tree nuts and sesame', kind: MenuBadgeKind.alert);
        await tester.pumpWidget(_host(
          system,
          const Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 90, child: Wrap(children: [MenuBadgePill(badge: long)])),
          ),
        ));
        expect(tester.takeException(), isNull, reason: 'no parent-data error and no overflow stripes');
        expect(tester.getSize(find.byType(MenuBadgePill)).width, lessThanOrEqualTo(90));
        final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: find.byType(MenuBadgePill), matching: find.byType(RichText)));
        expect(paragraph.didExceedMaxLines, isTrue, reason: 'the label is cut with an ellipsis');
        expect(paragraph.size.width, lessThan(90));
      }, variant: _platforms);

      testWidgets('where the label fits, the pill draws exactly the plain padded label', (tester) async {
        _viewport(tester);
        final pills = [
          MenuBadgePill(badge: _catalogue[0]),
          MenuBadgePill(badge: _catalogue[3], dense: false),
          MenuBadgePill(badge: _catalogue[4], faded: true),
        ];
        await tester.pumpWidget(_host(
          system,
          Wrap(spacing: 10, children: [
            for (final (i, p) in pills.indexed) RepaintBoundary(key: ValueKey('pill-$i'), child: p),
          ]),
        ));
        expect(tester.takeException(), isNull);

        // What the pill has always drawn — its own padding, decoration and
        // text style around a bare one-line label — read off the pill itself.
        final references = <Widget>[];
        for (final (i, p) in pills.indexed) {
          final pill = find.byKey(ValueKey('pill-$i'));
          final box = tester.widget<Container>(find.descendant(of: pill, matching: find.byType(Container)).first);
          final label = tester.widget<Text>(find.descendant(of: pill, matching: find.byType(Text)));
          references.add(RepaintBoundary(
            key: ValueKey('ref-$i'),
            child: Container(
              padding: box.padding,
              decoration: box.decoration,
              child: Text(p.badge.label, style: label.style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ));
        }
        await tester.pumpWidget(_host(
          system,
          Wrap(spacing: 10, children: [
            for (final (i, p) in pills.indexed) RepaintBoundary(key: ValueKey('pill-$i'), child: p),
            ...references,
          ]),
        ));
        expect(tester.takeException(), isNull);

        for (var i = 0; i < pills.length; i++) {
          final pill = find.byKey(ValueKey('pill-$i'));
          final ref = find.byKey(ValueKey('ref-$i'));
          expect(tester.getSize(pill), tester.getSize(ref), reason: pills[i].badge.label);
          final image = tester.renderObject<RenderRepaintBoundary>(ref).toImageSync();
          addTearDown(image.dispose);
          await expectLater(pill, matchesReferenceImage(image));
        }
      }, variant: _platforms);

      testWidgets('the catalogue list after "Use the starter set" lays out without an error', (tester) async {
        _viewport(tester);
        final (rest, api) = await _signIn();
        await _open(
          tester,
          system,
          MenuBadgesDialog(
            rest: rest,
            initial: const [],
            presets: _catalogue,
            labelMax: 24,
            usage: (id) => id == 'jain' ? 3 : 0,
          ),
        );
        expect(tester.takeException(), isNull, reason: 'the empty state fits or scrolls; it never overflows');
        expect(find.text('No badges yet'), findsOneWidget);

        // Gaia's label is upper-case, and the button may sit below the fold of
        // the (scrolling) empty state.
        final starter = find.textContaining(RegExp('use the starter set', caseSensitive: false));
        await tester.ensureVisible(starter);
        await tester.pumpAndSettle();
        await tester.tap(starter);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(api.writes.where((w) => w.method == 'PUT' && w.path == '/menu/badges'), hasLength(1));
        expect(find.text('No badges yet'), findsNothing);
        expect(find.byType(MenuBadgePill), findsWidgets);

        // The list is lazy: walk it in the order it is drawn (by kind).
        final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));
        final drawn = [for (final k in kMenuBadgeKinds) ..._catalogue.where((b) => b.kind == k)];
        for (final b in drawn) {
          final pill = find.widgetWithText(MenuBadgePill, b.label);
          await tester.scrollUntilVisible(pill, 40, scrollable: list);
          expect(pill, findsOneWidget);
          if (b.id == 'jain') expect(find.text('3 dishes'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: b.label);
        }
      }, variant: _platforms);

      testWidgets('on a phone the empty catalogue scrolls, and its starter-set button stays reachable', (tester) async {
        // Real fonts overflow here too (Rustic at 360 wide, Gaia at 412): an
        // overflowing Column put the button outside its own bounds, where no
        // tap could land.
        _viewport(tester, size: const Size(360, 740));
        final (rest, _) = await _signIn();
        await _open(
          tester,
          system,
          MenuBadgesDialog(rest: rest, initial: const [], presets: _catalogue, labelMax: 24, usage: (_) => 0),
        );
        expect(tester.takeException(), isNull, reason: 'the empty state scrolls instead of overflowing');
        final starter = find.textContaining(RegExp('use the starter set', caseSensitive: false));
        await tester.ensureVisible(starter);
        await tester.pumpAndSettle();
        expect(starter.hitTestable(), findsOneWidget);
      }, variant: _platforms);

      testWidgets('the bulk tagger lays out without an error', (tester) async {
        _viewport(tester);
        final (rest, _) = await _signIn();
        await _open(
          tester,
          system,
          MenuBadgeTagDialog(
            rest: rest,
            items: [
              Map<dynamic, dynamic>.from(_dish),
              {'id': 'mi-2', 'name': 'Dal Makhani', 'category': 'Mains', 'badges': <dynamic>[]},
            ],
            catalogue: _catalogue,
            perItemMax: 8,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Dal Makhani'), findsOneWidget);
        expect(find.byType(MenuBadgePill), findsWidgets);
      }, variant: _platforms);
    });
  }

  // A Flexible is only legal as a Flex child, which is always an element of a
  // `children:` list. A ChipLabel handed to any named slot (`child:`,
  // `title:`, ...) is sitting in something that is not a Row or Column.
  test('ChipLabel is never passed to a single-child slot', () {
    final slot = RegExp(r'\b(\w+)\s*:\s*(?:const\s+)?ChipLabel\(');
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final m = slot.firstMatch(lines[i]);
        if (m != null) offenders.add('${file.path}:${i + 1}  ${m.group(1)}: ChipLabel(');
      }
    }
    expect(offenders, isEmpty,
        reason: 'wrap the label in Row(mainAxisSize: MainAxisSize.min, children: [ChipLabel(...)])');
  });
}
