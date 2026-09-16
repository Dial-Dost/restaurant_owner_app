import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// THE BOX MUST SHOW THE ROW IT BELONGS TO — found by the item 3 (2.0.1) sweep.
///
/// Item 3 was a button that changed the screen's state while the text sat in a
/// field's private controller, out of the button's reach. The sweep found the
/// same shape in the app's editable LISTS: a row of `TextFormField(initialValue:)`
/// with a remove button beside it. `initialValue` is read ONCE, when the field's
/// state is created, and the rows had no keys — so removing any row but the
/// last shifted the DATA up while every field kept the text it already had. The
/// removed row stayed on screen, the last row vanished, and each field below
/// the cut wrote its edits into the row under it.
///
/// Where it mattered most:
///   * TAXES (Settings > Billing & taxes). Remove CGST from CGST/SGST/VAT and
///     the boxes still read CGST 2.5 / SGST 2.5 while Save wrote SGST 2.5 /
///     VAT 5, and a rate typed beside "SGST" became VAT's — the rate every bill
///     after the Save is taxed at.
///   * MODIFIER PRICES and RECIPE quantities in the menu item editor.
///   * POSTER captions — after a delete, Enter in a caption saved it onto the
///     NEXT poster.
///
/// Each row is now keyed on its own identity, so its fields follow it. These
/// tests remove a MIDDLE or FIRST row, then check what the boxes read against
/// what is saved.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'manager01',
          'role': 'admin',
          'actions_set': const ['*'],
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      final onWrite = routes['$method $path'];
      if (onWrite is void Function()) onWrite();
      return <String, dynamic>{'success': true};
    }
    final r = routes[path];
    if (r is dynamic Function()) return r();
    if (r != null) return r;
    return path == '/menu' || path == '/inventory' ? <dynamic>[] : <String, dynamic>{};
  }

  Object? lastBody(String method, String path) =>
      writes.lastWhere((w) => w.method == method && w.path == path).body;
}

Widget _host(Widget child, String label) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: [label],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'manager01', 'pw');
  return RestClient(auth);
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Every text field whose hint or label is [label], top to bottom, as the text
/// on screen.
List<String> _boxes(WidgetTester tester, String label) => [
      for (final e in find
          .byWidgetPredicate((w) =>
              w is TextField && (w.decoration?.hintText == label || w.decoration?.labelText == label))
          .evaluate())
        (e.widget as TextField).controller!.text,
    ];

Finder _field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && (w.decoration?.hintText == label || w.decoration?.labelText == label));

/// The tax RATE boxes, top to bottom. They share the '%' suffix and '0' hint
/// with the service charge box, which sits above them and is skipped.
final Finder _rateBoxes = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.suffixText == '%' && w.decoration?.hintText == '0');
List<String> _taxRates(WidgetTester tester) => [
      for (final e in _rateBoxes.evaluate().skip(1)) (e.widget as TextField).controller!.text,
    ];

/// Settings is one long lazy list: drag until [target] is built, then centre it.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  await tester.ensureVisible(target.first);
  await tester.pumpAndSettle();
}

/// Bring [f] on screen, then tap it — the lists here are taller than the view.
Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, Finder f, String text) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, text);
  await tester.pumpAndSettle();
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final f = find.widgetWithText(ForkButton, label).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------- taxes --

  group('Settings > taxes', () {
    Future<_FakeApi> openTaxes(WidgetTester tester) async {
      _bigView(tester);
      final api = _FakeApi({
        '/restaurant/profile': <String, dynamic>{'restaurant_name': 'Gaia Test'},
        '/restaurant/settings': <String, dynamic>{
          'taxes': [
            {'name': 'CGST', 'percentage': 2.5},
            {'name': 'SGST', 'percentage': 2.5},
            {'name': 'VAT', 'percentage': 5},
          ],
          'service_charge': 0,
        },
      });
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!), 'Settings'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Save taxes'));
      expect(_boxes(tester, 'Tax name'), ['CGST', 'SGST', 'VAT']);
      expect(_taxRates(tester), ['2.5', '2.5', '5.0']);
      return api;
    }

    testWidgets('removing the FIRST tax leaves the boxes reading the two that remain, and Save sends those',
        (tester) async {
      final api = await openTaxes(tester);

      await _tap(tester, find.byTooltip('Remove tax').first);

      expect(_boxes(tester, 'Tax name'), ['SGST', 'VAT'], reason: 'the removed tax must leave the screen');
      expect(_taxRates(tester), ['2.5', '5.0']);

      await _tapButton(tester, 'Save taxes');
      final body = api.lastBody('POST', '/restaurant/settings')! as Map;
      expect(body['taxes'], [
        {'name': 'SGST', 'percentage': 2.5},
        {'name': 'VAT', 'percentage': 5.0},
      ]);
    });

    testWidgets('an edit below a removed tax lands on the tax it is typed into', (tester) async {
      final api = await openTaxes(tester);

      await _tap(tester, find.byTooltip('Remove tax').at(1)); // SGST
      expect(_boxes(tester, 'Tax name'), ['CGST', 'VAT']);

      expect(_taxRates(tester), ['2.5', '5.0']);

      // Retype the rate on the row that reads "VAT". It must be VAT's rate that
      // changes (index 2: the service charge box comes first).
      await _type(tester, _rateBoxes.at(2), '12');

      await _tapButton(tester, 'Save taxes');
      final body = api.lastBody('POST', '/restaurant/settings')! as Map;
      expect(body['taxes'], [
        {'name': 'CGST', 'percentage': 2.5},
        {'name': 'VAT', 'percentage': 12.0},
      ]);
    });
  });

  // ------------------------------------------------------ menu item editor --

  group('Menu > item editor', () {
    Future<_FakeApi> openEditor(WidgetTester tester) async {
      _bigView(tester);
      final api = _FakeApi({
        '/menu': [
          <String, dynamic>{
            'id': 'mi-1',
            'name': 'Cold Coffee',
            'price': 150,
            'category': 'Drinks',
            'modifiers': [
              {
                'name': 'Size',
                'multi': false,
                'required': true,
                'options': [
                  {'name': 'Small', 'price': 0},
                  {'name': 'Medium', 'price': 40},
                  {'name': 'Large', 'price': 80},
                ],
              },
              {
                'name': 'Extras',
                'multi': true,
                'required': false,
                'options': [
                  {'name': 'Ice cream', 'price': 60},
                ],
              },
            ],
            'recipe': [
              {'inventory_id': 'inv-milk', 'qty': 0.25},
              {'inventory_id': 'inv-coffee', 'qty': 0.02},
              {'inventory_id': 'inv-sugar', 'qty': 0.01},
            ],
          },
        ],
        '/inventory': [
          {'id': 'inv-milk', 'name': 'Milk', 'stock': 10, 'unit': 'l'},
          {'id': 'inv-coffee', 'name': 'Coffee', 'stock': 2, 'unit': 'kg'},
          {'id': 'inv-sugar', 'name': 'Sugar', 'stock': 5, 'unit': 'kg'},
        ],
        '/menu/costing': {'items': <dynamic>[], 'ingredients': <dynamic>[]},
        '/restaurant/settings': {'kitchen_sections': <String>[]},
      });
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(m.menuModule(rest, rest.auth.profile!), 'Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cold Coffee').first);
      await tester.pumpAndSettle();
      await _tapButton(tester, 'Edit item');
      expect(find.text('Edit menu item'), findsOneWidget);
      return api;
    }

    Map<String, dynamic> saved(_FakeApi api) => Map<String, dynamic>.from(api.lastBody('POST', '/menu')! as Map);

    testWidgets('removing a middle option keeps each name beside its own price', (tester) async {
      final api = await openEditor(tester);
      expect(_boxes(tester, 'Option'), ['Small', 'Medium', 'Large', 'Ice cream']);
      expect(_boxes(tester, '+₹'), ['0', '40', '80', '60']);

      await _tap(tester, find.byTooltip('Remove option').at(1)); // Medium

      expect(_boxes(tester, 'Option'), ['Small', 'Large', 'Ice cream']);
      expect(_boxes(tester, '+₹'), ['0', '80', '60'], reason: 'Large must still read +80, not Medium\'s +40');

      // The price typed into the box that reads "Large" is Large's price.
      await _type(tester, _field('+₹').at(1), '90');
      await _tapButton(tester, 'Save');
      final size = (saved(api)['modifiers'] as List).first as Map;
      expect(size['options'], [
        {'name': 'Small', 'price': 0},
        {'name': 'Large', 'price': 90.0},
      ]);
    });

    testWidgets('removing the first group moves its fields out with it', (tester) async {
      final api = await openEditor(tester);

      await _tap(tester, find.byTooltip('Remove group').first); // Size

      expect(_boxes(tester, 'Group (e.g. Size)'), ['Extras']);
      expect(_boxes(tester, 'Option'), ['Ice cream']);
      expect(_boxes(tester, '+₹'), ['60']);

      await _tapButton(tester, 'Save');
      expect(saved(api)['modifiers'], [
        {
          'name': 'Extras',
          'multi': true,
          'required': false,
          'options': [
            {'name': 'Ice cream', 'price': 60},
          ],
        },
      ]);
    });

    testWidgets('removing the first ingredient keeps each quantity beside its own ingredient', (tester) async {
      final api = await openEditor(tester);
      expect(_boxes(tester, 'Qty/unit'), ['0.25', '0.02', '0.01']);

      await _tap(tester, find.byTooltip('Remove ingredient').first); // Milk

      expect(_boxes(tester, 'Qty/unit'), ['0.02', '0.01'], reason: 'Coffee must still read 0.02, not Milk\'s 0.25');

      await _type(tester, _field('Qty/unit').at(1), '0.015');
      await _tapButton(tester, 'Save');
      expect(saved(api)['recipe'], [
        {'inventory_id': 'inv-coffee', 'qty': 0.02},
        {'inventory_id': 'inv-sugar', 'qty': 0.015},
      ]);
    });
  });

  // -------------------------------------------------------------- posters --

  testWidgets('Settings > posters: after a delete, each caption box belongs to the poster beside it', (tester) async {
    _bigView(tester);
    Map<String, dynamic> poster(String id, String title) => <String, dynamic>{
          'id': id,
          'title': title,
          'image_url': 'https://example.invalid/$id.jpg',
          'placement': 'menu',
          'active': true,
          'width': 1600,
          'height': 900,
        };
    var posters = [poster('p1', 'Sunday brunch'), poster('p2', 'Happy hour'), poster('p3', 'Monsoon menu')];
    final api = _FakeApi({
      '/restaurant/profile': <String, dynamic>{'restaurant_name': 'Gaia Test'},
      '/restaurant/settings': <String, dynamic>{},
      '/posters': () => <String, dynamic>{
            'posters': posters,
            'placements': [
              {'value': 'menu', 'label': 'Menu', 'hint': 'above the dishes'},
            ],
            'today': '2026-09-16',
            'timezone': 'Asia/Kolkata',
            'max_posters': 6,
          },
    });
    api.routes['DELETE /posters/p1'] = () => posters = posters.where((p) => p['id'] != 'p1').toList();
    final rest = await _signIn(api);
    await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!), 'Settings'));
    await tester.pumpAndSettle();
    const caption = 'Caption (also the image description for screen readers)';
    await _scrollTo(tester, _field(caption));
    expect(_boxes(tester, caption), ['Sunday brunch', 'Happy hour', 'Monsoon menu']);

    await _tap(tester, find.byTooltip('Delete poster').first);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.writes.map((w) => '${w.method} ${w.path}'), contains('DELETE /posters/p1'));

    expect(_boxes(tester, caption), ['Happy hour', 'Monsoon menu']);

    // Enter in the first caption box saves THAT poster's caption.
    await _type(tester, _field(caption).first, 'Happy hour 5–7');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.writes.last.method, 'PATCH');
    expect(api.writes.last.path, '/posters/p2');
    expect(api.writes.last.body, {'title': 'Happy hour 5–7'});
  });

  // --------------------------------------------------------- the wiring --

  test('every editable list row with initialValue fields is keyed on its own identity', () {
    final src = File('lib/screens/modules.dart').readAsStringSync();
    for (final key in [
      'key: ObjectKey(_taxes[i]),',
      'key: ObjectKey(_recipe[i]),',
      'key: ObjectKey(g),',
      'key: ObjectKey(options[oi]),',
      "key: ValueKey('poster-\${p['id']}'),",
    ]) {
      expect(src.contains(key), isTrue, reason: 'row key missing: $key');
    }
    // Seven initialValue fields live in keyed rows; a new one needs a key too.
    // Comment lines are left out: the fix's own comments name the pattern.
    final code = src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(RegExp(r'TextFormField\(\s*initialValue:').allMatches(code).length, 7,
        reason: 'a new TextFormField(initialValue:) in a list needs its row keyed — then update this count');
  });
}
