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
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';

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
///   * and, as a sweep, no text field in the app offers a suffix button over
///     text it does not own — the shape this bug had.

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

  test('no text field in the app offers a suffix button over text it does not own', () {
    // The bug's shape: a TextField/TextFormField with no `controller:` whose
    // decoration carries a suffix button. Whatever that button does, it cannot
    // reach the text in the box. A show/hide eye or a clear x both need the
    // field to be controlled; a field that only has a plain suffix label
    // (`suffixText`) is not a button and is not counted.
    final ctor = RegExp(r'(?<![\w.])(TextField|TextFormField)\s*\(');
    final offenders = <String>[];
    var fields = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in ctor.allMatches(src)) {
        var depth = 1;
        var i = m.end;
        while (i < src.length && depth > 0) {
          final c = src[i];
          if (c == '(' || c == '[' || c == '{') depth++;
          if (c == ')' || c == ']' || c == '}') depth--;
          i++;
        }
        final args = src.substring(m.end, i);
        fields++;
        final hasButton = RegExp(r'\bsuffix(Icon)?\s*:').hasMatch(args) &&
            RegExp(r'\b(IconButton|ForkIconButton|onPressed|onTap)\b').hasMatch(args);
        if (hasButton && !RegExp(r'\bcontroller\s*:').hasMatch(args)) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('${f.path}:$line');
        }
      }
    }
    expect(fields, greaterThan(50), reason: 'the scan must actually be reading the app');
    expect(offenders, isEmpty, reason: 'uncontrolled field with a suffix button');
  });

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
