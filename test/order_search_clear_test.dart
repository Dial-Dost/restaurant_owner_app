import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';

import 'text_field_scan.dart';

/// ITEM 3 (2.0.1) — "When searching for an item while adding order the clear
/// text button does not clear the text, this needs to be fixed."
///
/// The order pad's search had no controller, so its text lived inside the
/// TextField and the x could only reset the filter behind it. What the waiter
/// saw: the x vanished, the whole menu came back, and the word stayed in the
/// box — so the next dish they typed was appended to it ("dal" + "n") and the
/// pad said "No items match your search." The only way out was backspace.
///
/// Held here, on Android AND Windows (the same Dart runs on both, and a tap
/// inside the field's suffix must not count as a tap outside it on desktop):
///
///   * the x empties the BOX, not just the filter, and the full menu is back;
///   * focus stays in the box, and the next word is a new search;
///   * clearing never touches the order being built;
///   * and, as a sweep (test/text_field_scan.dart), no clear button in the app
///     sits in or beside a text field it cannot reach: no uncontrolled field
///     with a suffix button, no uncontrolled field at all bar the keyed
///     initialValue rows, and no onClear that skips its own controller.

class _FakeApi extends ApiClient {
  _FakeApi(this.role);
  final String role;

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'ravi',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'actions_set': role == 'waiter' ? const ['a1'] : const ['*'],
          'action_names': const ['View Orders', 'Create Order', 'View Tables', 'Occupy Table', 'View Menu'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (path == '/menu') {
      return [
        {'id': 'mi-1', 'name': 'Paneer Tikka', 'price': 250.0, 'category': 'Starters'},
        {'id': 'mi-2', 'name': 'Dal Makhani', 'price': 220.0, 'category': 'Mains'},
        {'id': 'mi-3', 'name': 'Butter Naan', 'price': 60.0, 'category': 'Breads'},
      ];
    }
    // No '/bill-for-table': the table has no open bill yet.
    throw ApiException('No fake route for $path', 404);
  }
}

Future<void> _pumpPad(WidgetTester tester, {String role = 'waiter', String orderType = 'dine_in'}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: _FakeApi(role));
  await auth.login('Gaia Test', 'ravi', 'pw');
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: OrderEntryScreen(
      rest: RestClient(auth),
      tableName: orderType == 'dine_in' ? 'T1' : null,
      orderType: orderType,
    ),
  ));
  await tester.pumpAndSettle();
}

final Finder _search = find.byKey(const ValueKey('order-search'));
final Finder _clear = find.byKey(const ValueKey('order-search-clear'));

/// What the box holds and whether it has focus, read from the EditableText the
/// field renders — i.e. what the waiter sees, not a variable behind it.
EditableText _box(WidgetTester tester) =>
    tester.widget<EditableText>(find.descendant(of: _search, matching: find.byType(EditableText)));

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android, TargetPlatform.windows});

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Outbox.instance.debugReset();
  });

  testWidgets('the x empties the box, brings the whole menu back, and keeps focus', (tester) async {
    await _pumpPad(tester);
    expect(_search, findsOneWidget);
    expect(_clear, findsNothing, reason: 'nothing to clear yet');

    await tester.tap(_search);
    await tester.enterText(_search, 'paneer');
    await tester.pumpAndSettle();
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.text('Dal Makhani'), findsNothing);
    expect(_clear, findsOneWidget);
    expect(find.descendant(of: _search, matching: find.byTooltip('Clear search')), findsOneWidget);

    await tester.tap(_clear);
    await tester.pumpAndSettle();

    expect(_box(tester).controller.text, isEmpty, reason: 'the clear button must clear the TEXT');
    expect(_clear, findsNothing);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.text('Dal Makhani'), findsOneWidget);
    expect(find.text('Butter Naan'), findsOneWidget);
    expect(_box(tester).focusNode.hasFocus, isTrue, reason: 'the waiter types the next dish straight away');
  }, variant: _platforms);

  testWidgets('the next word after a clear is a new search, not the old one plus a letter', (tester) async {
    await _pumpPad(tester);
    await tester.tap(_search);
    await tester.enterText(_search, 'dal');
    await tester.pumpAndSettle();
    expect(find.text('Dal Makhani'), findsOneWidget);
    expect(find.text('Paneer Tikka'), findsNothing);

    await tester.tap(_clear);
    await tester.pumpAndSettle();

    // A keyboard appends to what the box holds. Before the fix that was "dal",
    // so the "n" of naan made "daln" and the pad matched nothing.
    await tester.enterText(_search, '${_box(tester).controller.text}n');
    await tester.pumpAndSettle();
    expect(_box(tester).controller.text, 'n');
    expect(find.text('No items match your search.'), findsNothing);
    await tester.enterText(_search, 'naan');
    await tester.pumpAndSettle();
    expect(find.text('Butter Naan'), findsOneWidget);
    expect(find.text('Paneer Tikka'), findsNothing);
    expect(find.text('Dal Makhani'), findsNothing);
  }, variant: _platforms);

  testWidgets('clearing the search never touches the order being built (takeaway, header grown)', (tester) async {
    await _pumpPad(tester, role: 'admin', orderType: 'takeaway');
    await tester.enterText(_search, 'naan');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('order-send')), findsOneWidget);
    expect(find.textContaining('Send order · 1 item'), findsOneWidget);

    await tester.tap(_clear);
    await tester.pumpAndSettle();
    expect(_box(tester).controller.text, isEmpty);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.textContaining('Send order · 1 item'), findsOneWidget, reason: 'the cart is untouched');
  }, variant: _platforms);

  // ------------------------------------------------------------ the sweep --

  test('no text field in the app has a clear button that cannot reach its text', () {
    // The bug's shape is text the button cannot reach. Read with
    // test/text_field_scan.dart (every file under lib/, comments left out,
    // each argument found wherever it falls), it can come back three ways:
    //
    //  1. a field with no `controller:` whose decoration carries a suffix
    //     button. Whatever that button does, it cannot reach the box. A plain
    //     suffix label (`suffixText`) is not a button and is not counted.
    //  2. a field with no `controller:` and a button BESIDE it (a clear x in
    //     the same Row, a reset elsewhere on the screen), which this scan could
    //     not see from the field's own arguments. So no uncontrolled field is
    //     allowed at all, except the `initialValue:` boxes in keyed list rows,
    //     and those are pinned one by one, key and all, in
    //     test/row_remove_keeps_fields_in_step_test.dart.
    //  3. a box that is controlled, but through a widget whose x sits beside
    //     the field and calls back for the clearing (GaiaSearchField, used by
    //     the Guests book). The widget cannot clear the text itself, so every
    //     call that passes `controller: X` and `onClear:` must clear that
    //     same X in its onClear, inline or in the method it names.
    final offenders = <String>[];
    final fields = libTextFields;
    for (final f in fields) {
      if (f.args.containsKey('controller')) continue;
      final hasButton = RegExp(r'\bsuffix(Icon)?\s*:').hasMatch(f.argText) &&
          RegExp(r'\b(IconButton|ForkIconButton|onPressed|onTap)\b').hasMatch(f.argText);
      if (hasButton) {
        offenders.add('${f.where}: a suffix button over text the field does not own');
      } else if (!f.args.containsKey('initialValue')) {
        offenders.add('${f.where}: no controller, so no button beside it can clear or reset its text');
      }
    }
    expect(fields.length, greaterThan(100), reason: 'the scan must actually be reading the app');
    expect(fields.where((f) => f.args.containsKey('controller')).length, greaterThan(100));

    var clearCalls = 0;
    for (final s in libSources) {
      for (final m in RegExp(r'(?<![\w.])onClear\s*:').allMatches(s.code)) {
        final call = s.callAround(m.start);
        final onClear = call?.args['onClear'];
        final controller = call?.args['controller'];
        if (onClear == null || controller == null) continue;
        clearCalls++;
        final body = RegExp(r'^[\w.]+$').hasMatch(onClear) ? s.bodyOf(onClear.split('.').last) ?? '' : onClear;
        final clears = RegExp(RegExp.escape(controller) + r'''\s*\.\s*(clear\s*\(\s*\)|text\s*=\s*(''|""))''');
        if (!clears.hasMatch(body)) {
          offenders.add('${call!.where}: ${call.name}(controller: $controller) has an onClear that never clears $controller');
        }
      }
    }
    expect(clearCalls, greaterThanOrEqualTo(1), reason: 'the Guests book search is one; the scan must find it');
    expect(offenders, isEmpty, reason: 'a clear button that cannot reach the text it sits by');
  });

  testWidgets('the Gaia search box shows its x only while the box has text, and cannot clear it by itself', (tester) async {
    // GaiaSearchField's x sits BESIDE its TextField and hands the clearing to
    // the screen, which is why the sweep above reads every onClear. Here: the
    // Guests book's wiring empties the box and the x goes; a callback that
    // forgets the controller leaves the word, and the x, on screen.
    final ctl = TextEditingController();
    addTearDown(ctl.dispose);
    final searched = <String>[];
    Future<void> pump(VoidCallback onClear) async {
      await tester.pumpWidget(MaterialApp(
        theme: GaiaTheme.dark(),
        home: Scaffold(
          body: GaiaSearchField(
            controller: ctl,
            hint: 'Find a guest by name, phone or email',
            onChanged: searched.add,
            onClear: onClear,
          ),
        ),
      ));
    }

    final field = find.byType(TextField);
    final x = find.byIcon(Icons.close);
    String box() => tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).controller.text;

    // As modules.dart wires it for the Guests book.
    await pump(() {
      ctl.clear();
      searched.add('');
    });
    expect(x, findsNothing, reason: 'nothing to clear yet');
    await tester.enterText(field, 'asha');
    await tester.pump();
    expect(x, findsOneWidget);
    await tester.tap(x);
    await tester.pump();
    expect(box(), isEmpty);
    expect(x, findsNothing);
    expect(searched.last, '', reason: 'the list is searched again with nothing');
    await tester.enterText(field, '${box()}r');
    await tester.pump();
    expect(box(), 'r', reason: 'the next word is a new search');

    // A callback that only resets the search.
    await pump(() => searched.add(''));
    await tester.tap(x);
    await tester.pump();
    expect(box(), 'r');
    expect(x, findsOneWidget);
  }, variant: _platforms);

  test('the pad wires its search through the controller, both ways', () {
    final src = File('lib/screens/order_entry.dart').readAsStringSync();
    expect(src, contains('final TextEditingController _searchCtrl = TextEditingController();'));
    expect(src, contains('_searchCtrl.dispose();'));
    final field = RegExp(r"key: const ValueKey\('order-search'\),[\s\S]*?onChanged: \(v\) => setState\(\(\) => _query = v\),")
        .firstMatch(src)
        ?.group(0);
    expect(field, isNotNull);
    expect(field, contains('controller: _searchCtrl,'));
    expect(field, matches(RegExp(r'_searchCtrl\.clear\(\);\s*setState\(\(\) => _query = \x27\x27\);')));
    // Any other writer of _query would have to set the box too; there are none
    // (the declaration aside, the two writes are onChanged and the x).
    expect(RegExp(r'(?<!String )_query = ').allMatches(src).length, 2);
  });
}
