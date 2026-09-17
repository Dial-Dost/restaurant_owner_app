import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';

/// CLIENT ITEM 6 (2.0.2) — the search box CONTRACT, as an interaction.
///
/// Not a test itself (the runner only picks up `*_test.dart`): the rows live in
/// test/search_clear_registry_test.dart and, for the MIS reports, in
/// test/reports_module_test.dart, and every one of them is declared through
/// [searchContractRows] so the registry guard can count them.
///
/// The 2.0.1 guard for this complaint was a source scan, and it passed three
/// broken boxes planted beside the real ones: it skipped every field with a
/// controller, it could not see a debounce, and it never pressed anything. So
/// this presses. Every x is hit at the point on the screen where the glyph is
/// drawn — a mouse click on Windows, a finger on Android — never through a
/// callback and never via `tester.tap(find.byIcon(...))`, which would find a
/// widget however small, wherever it sits.
///
///  C1  an x is drawn as soon as the box holds text, before any debounce;
///  C2  the x is a real target: a button at least 40x40 inside the box's row;
///  C3  pressing it empties the BOX;
///  C4  ...and the x goes;
///  C5  ...and, after every debounce, nothing is filtered any more;
///  C6  ...and the box still has focus, so the next word goes straight in;
///  C7  the next word is a new search, not the old one plus a letter;
///  C8  an x pressed INSIDE the debounce window is not followed by the old word;
///  C9  what rebuilds the screen around the box (the phone keyboard coming and
///      going, the shell) keeps what was typed;
///  C10 Escape clears a box that has text, and leaves the screen (a dialog, a
///      sheet) where it was.
///
/// [checkSearchContract] returns the broken clauses rather than stopping at the
/// first, so a failing row says everything that is wrong with the box at once.

/// Every row runs on both: the same Dart ships to the Windows till and the
/// Android phone, and a click and a tap reach a suffix differently.
final searchPlatforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android, TargetPlatform.windows});

bool get onPhone => defaultTargetPlatform == TargetPlatform.android;

/// A phone at 360dp on Android, a till window on Windows.
Size get searchViewSize => onPhone ? const Size(360, 800) : const Size(1280, 900);

PointerDeviceKind get searchPointer => onPhone ? PointerDeviceKind.touch : PointerDeviceKind.mouse;

/// [home] under the design system's own theme, the way the app root mounts it.
Widget searchThemed(DesignSystem ds, Widget home) => GaiaScope(
      system: ds,
      child: MaterialApp(theme: ds == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(), home: home),
    );

/// Sizes the test view (reset after the test).
void useSearchView(WidgetTester tester, [Size? size]) {
  tester.view.physicalSize = size ?? searchViewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

EditableText _editable(WidgetTester tester, Finder field) =>
    tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)).first);

/// What the box shows — read off the EditableText, not a variable behind it.
String searchBoxText(WidgetTester tester, Finder field) => _editable(tester, field).controller.text;

bool searchBoxFocused(WidgetTester tester, Finder field) => _editable(tester, field).focusNode.hasFocus;

/// Case-insensitive text (Gaia upper-cases some labels).
Finder textAnyCase(String t) => find.byWidgetPredicate((w) {
      final d = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
      return d != null && d.toLowerCase() == t.toLowerCase();
    }, skipOffstage: false);

/// One search surface, as a row of the contract sees it.
class SearchSurface {
  SearchSurface({
    required this.field,
    required this.typed,
    required this.filtered,
    this.rebuild,
    this.stillOpen,
  });

  /// The TextField.
  final Finder field;

  /// A word that narrows this surface.
  final String typed;

  /// Whether what the surface shows (or last asked the server for) is narrowed
  /// by a search right now.
  final bool Function() filtered;

  /// What rebuilds the screen around the box, beyond the phone keyboard coming
  /// and going (which every row does).
  final Future<void> Function()? rebuild;

  /// For a box in a dialog or a sheet: whether that is still open.
  final bool Function()? stillOpen;
}

Future<void> _settle(WidgetTester tester, [Duration wait = const Duration(milliseconds: 600)]) async {
  await tester.pump();
  await tester.pump(wait); // outlasts every debounce in the app (300 / 350 / 450ms)
  await tester.pumpAndSettle();
}

/// The x a person would aim at: a close glyph drawn inside the box's row.
/// Found by what it looks like and where it is, never by key, so a box that
/// did not come from the shared widget is judged the same way.
List<Element> _xs(WidgetTester tester, Finder field) {
  final row = tester.getRect(field);
  return find
      .byWidgetPredicate((w) => w is Icon && (w.icon == Icons.close || w.icon == Icons.clear))
      .evaluate()
      .where((e) {
    final r = tester.getRect(find.byElementPredicate((x) => x == e));
    return r.center.dy >= row.top - 4 &&
        r.center.dy <= row.bottom + 4 &&
        r.left >= row.left &&
        r.right <= row.right + 48;
  }).toList();
}

Rect _rectOf(WidgetTester tester, Element e) => tester.getRect(find.byElementPredicate((x) => x == e));

/// The nearest thing above the glyph that takes a tap, and its size.
Size? _target(WidgetTester tester, Element glyph, Rect row) {
  Element? hit;
  glyph.visitAncestorElements((a) {
    final w = a.widget;
    if (w is IconButton || w is InkResponse || w is GestureDetector || w is ButtonStyleButton) {
      hit = a;
      return false;
    }
    return true;
  });
  if (hit == null) return null;
  final r = _rectOf(tester, hit!);
  // A tap handler as big as the screen is not a button on the x.
  if (r.height > row.height + 16 || r.width > 96) return null;
  return r.size;
}

Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at, kind: searchPointer);
}

/// The contract, driven like a person would. Returns the broken clauses; an
/// empty list is a box that honours all of them.
Future<List<String>> checkSearchContract(WidgetTester tester, SearchSurface s) async {
  final broken = <String>[];
  final field = s.field;
  expect(field, findsOneWidget, reason: 'the row must find exactly one search box');
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();

  // Focus by touching the box, then type.
  await _tapAt(tester, tester.getCenter(field));
  await tester.pump();
  await tester.enterText(field, s.typed);
  await tester.pump(const Duration(milliseconds: 16));

  // C1 — before any debounce has had time to fire.
  var xs = _xs(tester, field);
  if (xs.isEmpty) {
    await _settle(tester);
    xs = _xs(tester, field);
    if (xs.isEmpty) {
      broken.add('C1 no x is drawn while the box holds "${s.typed}"');
      return broken;
    }
    broken.add('C1 the x only appears after the debounce');
  }
  await _settle(tester);
  if (!s.filtered()) broken.add('(precondition) typing "${s.typed}" did not narrow anything');

  // C2
  xs = _xs(tester, field);
  final row = tester.getRect(field);
  final size = _target(tester, xs.first, row);
  if (size == null) {
    broken.add('C2 the x is not a button of its own');
  } else if (size.width < 40 || size.height < 40) {
    broken.add('C2 the x is a ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} target');
  }

  // C3-C6 — the x, where it is drawn.
  await _tapAt(tester, _rectOf(tester, xs.first).center);
  await _settle(tester);
  final after = searchBoxText(tester, field);
  if (after.isNotEmpty) broken.add('C3 the box still reads "$after"');
  if (after.isEmpty && _xs(tester, field).isNotEmpty) broken.add('C4 the x is still drawn on an empty box');
  if (s.filtered()) broken.add('C5 still filtered after the x');
  if (!searchBoxFocused(tester, field)) broken.add('C6 the box lost focus');

  // C7 — a keyboard appends to whatever the box holds.
  await tester.enterText(field, '${searchBoxText(tester, field)}q');
  await _settle(tester);
  final next = searchBoxText(tester, field);
  if (next != 'q') broken.add('C7 the next word reads "$next"');

  // C8 — the x pressed 100ms after typing, inside every debounce window.
  await tester.enterText(field, s.typed);
  await tester.pump(const Duration(milliseconds: 16));
  xs = _xs(tester, field);
  if (xs.isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 84));
    await _tapAt(tester, _rectOf(tester, xs.first).center);
    await _settle(tester);
    if (searchBoxText(tester, field).isNotEmpty || s.filtered()) {
      broken.add('C8 an x inside the debounce window: box "${searchBoxText(tester, field)}", '
          'filtered ${s.filtered()}');
    }
  }

  // C9 — the phone keyboard slides up and away (a MediaQuery change the whole
  // tree rebuilds on), then whatever else this surface names.
  await tester.enterText(field, s.typed);
  await _settle(tester);
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  await tester.pumpAndSettle();
  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
  if (s.rebuild != null) {
    await s.rebuild!();
    await _settle(tester);
  }
  if (field.evaluate().isEmpty) {
    broken.add('C9 the box is gone after a rebuild');
    return broken;
  }
  if (searchBoxText(tester, field) != s.typed || !s.filtered()) {
    broken.add('C9 a rebuild left the box "${searchBoxText(tester, field)}", filtered ${s.filtered()}');
  }

  // C10 — Escape, with the caret in a box that has text.
  if (searchBoxText(tester, field).isEmpty) {
    await tester.enterText(field, s.typed);
    await _settle(tester);
  }
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await _tapAt(tester, tester.getCenter(field));
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await _settle(tester);
  if (s.stillOpen != null && !s.stillOpen!()) {
    broken.add('C10 Escape on a box with text closed the screen around it');
    return broken;
  }
  if (field.evaluate().isEmpty) {
    broken.add('C10 the box is gone after Escape');
    return broken;
  }
  if (searchBoxText(tester, field).isNotEmpty || s.filtered()) {
    broken.add('C10 Escape left the box "${searchBoxText(tester, field)}", filtered ${s.filtered()}');
  }
  return broken;
}

/// One contract row per design system for the box keyed [testId], each run on
/// Android and Windows. [mount] pumps the real screen and says how to read it.
///
/// test/search_clear_registry_test.dart counts these calls: an AppSearchField
/// in lib/ whose testId has no row here fails the build.
void searchContractRows(
  String testId,
  Future<SearchSurface> Function(WidgetTester tester, DesignSystem ds) mount,
) {
  for (final ds in DesignSystem.values) {
    testWidgets('search contract: $testId (${ds.id})', (tester) async {
      final surface = await mount(tester, ds);
      expect(surface.field, findsOneWidget);
      // The box under test is the shared one, not a look-alike.
      expect(find.byKey(ValueKey(testId)), findsOneWidget);
      final broken = await checkSearchContract(tester, surface);
      expect(broken, isEmpty, reason: '$testId (${ds.id}, ${defaultTargetPlatform.name})');
      expect(tester.takeException(), isNull);
    }, variant: searchPlatforms);
  }
}
