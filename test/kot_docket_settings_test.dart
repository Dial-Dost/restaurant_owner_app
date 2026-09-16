// THE TWO KITCHEN DOCKET SETTINGS ON THE APP (migration 050).
//
// "Restaurant".kot_print_style picks the docket the kitchen printers print —
// the reference docket (an image) or the classic text docket, the escape hatch
// for a printer that feeds blank paper. "Restaurant".kot_text_size is the
// client's "The font sizes must be smaller in the KOT": Small / Standard (their
// reference ticket exactly) / Large, for the reference docket only.
//
// The web dashboard's "KOT print style" card has both; this pins the app's
// Settings screen to the same two controls in the same words, and to the things
// that go wrong while looking fine:
//   * a backend that never heard of a key must show what it prints — the
//     reference docket, standard size — never a blank or a guess;
//   * a pick is saved at once, ONE key per save, and put back if refused;
//   * an owner on the classic docket is told the size does nothing there;
//   * the card is actually on the Settings screen, seeded from the settings
//     document (built, and called).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/kot_docket_settings.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.settings, {this.refuse});

  final Map<String, dynamic> settings;

  /// When set, every write is refused with this.
  final ApiException? refuse;

  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'asha',
          'emp_Fname': 'Asha',
          'role': 'admin',
          'role_all': const ['admin'],
          'actions_set': const ['*'],
          'action_names': const <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      if (refuse != null) throw refuse!;
      // The real route answers with the whole settings document, the new value
      // in it.
      if (path == '/restaurant/settings' && body is Map) settings.addAll(body.cast<String, dynamic>());
      return <String, dynamic>{...settings};
    }
    final bare = path.split('?').first;
    if (bare == '/restaurant/settings') return <String, dynamic>{...settings};
    if (bare == '/restaurant/profile') return <String, dynamic>{'restaurant_name': 'Gaia Test'};
    // Every other card on the page reads its own endpoint; an empty document is
    // a tenant with nothing configured there.
    return <String, dynamic>{};
  }
}

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Settings'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Finder _choice(String key, String value) => find.byKey(ValueKey('$key-$value'));

bool _picked(WidgetTester tester, String key, String value) => tester.widget<ForkCard>(_choice(key, value)).selected;

/// Mount Settings and bring the KOT card's last choice on screen.
Future<_FakeApi> _openSettings(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  final last = _choice(kotTextSizeKey, 'large');
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && last.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(last, findsOneWidget, reason: 'never reached the KOT print style card');
  await tester.ensureVisible(last);
  await tester.pumpAndSettle();
  return api;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('reading the settings document', () {
    test('a document without either key is the reference docket at the standard size', () {
      expect(readKotPrintStyle(const {}), 'reference');
      expect(readKotTextSize(const {}), 'standard');
      expect(kotPrintStyleDefault, 'reference');
      expect(kotTextSizeDefault, 'standard');
    });

    test('only the exact words the backend stores are read; anything else is the default', () {
      for (final s in ['reference', 'classic']) {
        expect(readKotPrintStyle({'kot_print_style': s}), s);
      }
      for (final s in ['small', 'standard', 'large']) {
        expect(readKotTextSize({'kot_text_size': s}), s);
      }
      for (final v in [null, '', 'Classic', ' classic', 'text', 1, true, const <String, dynamic>{}]) {
        expect(readKotPrintStyle({'kot_print_style': v}), 'reference', reason: '$v');
      }
      for (final v in [null, '', 'SMALL', ' large', 'medium', 24, false]) {
        expect(readKotTextSize({'kot_text_size': v}), 'standard', reason: '$v');
      }
    });

    test('the sizes are offered smallest first, the styles recommended first', () {
      expect(kotTextSizes, ['small', 'standard', 'large']);
      expect(kotPrintStyles, ['reference', 'classic']);
      expect(kotTextSizeOptions.map((o) => o.value), kotTextSizes);
      expect(kotPrintStyleOptions.map((o) => o.value), kotPrintStyles);
    });
  });

  group('the words — the web card\'s, letter for letter', () {
    // Restaurant_Dashboard_UI src/lib/kot-print-style.ts pins the same strings
    // in its own test (kot-print-style.test.ts). An owner who reads one thing on
    // the web and another here would reasonably ask whether it is one setting.
    test('the style choices and the sentence under them', () {
      expect(kotPrintStyleOptions.map((o) => o.label), [
        'Match the reference docket (recommended)',
        'Classic text docket',
      ]);
      expect(kotPrintStyleOptions.map((o) => o.detail), [
        'Clear type, laid out like the printed ticket you approved. Its size is set below.',
        'The plain ticket this system printed before. Use it if the new one does not print.',
      ]);
      expect(
          kotPrintStyleHelp,
          'The new docket prints as an image, which almost every thermal printer supports. '
          'If a kitchen printer prints a blank ticket, switch back to the classic text docket here '
          'and the next KOT prints as text again.');
      expect(kotPrintStyleTitle, 'KOT print style');
      expect(kotPrintStyleDescription, 'How kitchen dockets are printed. This does not change the customer bill.');
    });

    test('Small / Standard — matches your reference docket / Large', () {
      expect(kotTextSizeTitle, 'KOT text size');
      expect(kotTextSizeOptions.map((o) => o.label), [
        'Small',
        'Standard — matches your reference docket',
        'Large',
      ]);
      expect(kotTextSizeOptions.map((o) => o.detail), [
        'A size down: more of a long order fits on less paper.',
        'The same size as the printed ticket you approved.',
        'A size up, for a pass read from further away. Long dish names wrap sooner.',
      ]);
    });

    test('the size says it is for the new docket only, and the classic docket ignores it', () {
      expect(kotTextSizeHelp,
          "Applies to the new docket only. The classic text docket prints in the printer's own font and ignores this setting.");
      expect(kotTextSizeClassicNote,
          'Your kitchens are on the classic text docket, so this size is not used until you switch back.');
      // The style's detail no longer promises LARGER type: the size is a choice now.
      expect(kotPrintStyleOptions.first.detail, isNot(contains(RegExp('larger', caseSensitive: false))));
    });

    test('a stored word is shown by its label', () {
      expect(kotDocketOptionLabel(kotTextSizeOptions, 'standard'), 'Standard — matches your reference docket');
      expect(kotDocketOptionLabel(kotPrintStyleOptions, 'classic'), 'Classic text docket');
      expect(kotDocketOptionLabel(kotTextSizeOptions, 'huge'), 'huge');
    });
  });

  group('what a save stored, and what it says', () {
    test('the reply is the settings document: the stored word is read back from it', () {
      expect(kotDocketSaved({'kot_text_size': 'large'}, kotTextSizeKey, 'large'), 'large');
      expect(kotDocketSaved({'kot_print_style': 'classic'}, kotPrintStyleKey, 'classic'), 'classic');
      // A reply that disagrees wins — it is what the server holds.
      expect(kotDocketSaved({'kot_text_size': 'standard'}, kotTextSizeKey, 'small'), 'standard');
    });

    test('a reply without the key proves nothing, so the word sent stands', () {
      expect(kotDocketSaved({'success': true}, kotTextSizeKey, 'small'), 'small');
      expect(kotDocketSaved(null, kotPrintStyleKey, 'classic'), 'classic');
      expect(kotDocketSaved('ok', kotTextSizeKey, 'large'), 'large');
    });

    test('the confirmations are the web card\'s', () {
      expect(kotDocketSavedMessage(kotPrintStyleKey, 'classic', style: 'classic'),
          'The next kitchen docket prints as plain text.');
      expect(kotDocketSavedMessage(kotPrintStyleKey, 'reference', style: 'reference'),
          'The next kitchen docket prints in the reference layout.');
      expect(kotDocketSavedMessage(kotTextSizeKey, 'small', style: 'reference'),
          'The next kitchen docket prints at the small size.');
      expect(kotDocketSavedMessage(kotTextSizeKey, 'small', style: 'classic'),
          'Saved. It applies when the kitchen is back on the new docket.');
    });
  });

  group('the Settings screen', () {
    testWidgets('a backend without either key shows the reference docket, standard size', (tester) async {
      await _openSettings(tester, _FakeApi(<String, dynamic>{}));
      expect(find.text('KOT print style'), findsOneWidget);
      expect(find.text('KOT text size'), findsOneWidget);
      expect(_picked(tester, kotPrintStyleKey, 'reference'), isTrue);
      expect(_picked(tester, kotPrintStyleKey, 'classic'), isFalse);
      expect(_picked(tester, kotTextSizeKey, 'standard'), isTrue);
      expect(_picked(tester, kotTextSizeKey, 'small'), isFalse);
      expect(_picked(tester, kotTextSizeKey, 'large'), isFalse);
      expect(find.text(kotTextSizeHelp), findsOneWidget);
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsNothing);
      for (final o in [...kotPrintStyleOptions, ...kotTextSizeOptions]) {
        expect(find.text(o.label), findsOneWidget, reason: o.label);
      }
    });

    testWidgets('seeded from what the restaurant stored', (tester) async {
      await _openSettings(tester, _FakeApi({'kot_print_style': 'classic', 'kot_text_size': 'small'}));
      expect(_picked(tester, kotPrintStyleKey, 'classic'), isTrue);
      expect(_picked(tester, kotPrintStyleKey, 'reference'), isFalse);
      expect(_picked(tester, kotTextSizeKey, 'small'), isTrue);
      expect(_picked(tester, kotTextSizeKey, 'standard'), isFalse);
      // On classic, the owner is told the size is not in use.
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsOneWidget);
      expect(find.text(kotTextSizeClassicNote), findsOneWidget);
    });

    testWidgets('picking a size saves that one key, at once', (tester) async {
      final api = await _openSettings(tester, _FakeApi(<String, dynamic>{}));
      await _tap(tester, _choice(kotTextSizeKey, 'small'));
      expect(api.writes, hasLength(1));
      expect(api.writes.single.method, 'POST');
      expect(api.writes.single.path, '/restaurant/settings');
      expect(api.writes.single.body, {'kot_text_size': 'small'});
      expect(_picked(tester, kotTextSizeKey, 'small'), isTrue);
      expect(_picked(tester, kotTextSizeKey, 'standard'), isFalse);
      expect(find.text('The next kitchen docket prints at the small size.'), findsOneWidget);
    });

    testWidgets('picking the size already chosen sends nothing', (tester) async {
      final api = await _openSettings(tester, _FakeApi(<String, dynamic>{}));
      await _tap(tester, _choice(kotTextSizeKey, 'standard'));
      await _tap(tester, _choice(kotPrintStyleKey, 'reference'));
      expect(api.writes, isEmpty);
    });

    testWidgets('switching to classic saves the style alone, and the size note appears', (tester) async {
      final api = await _openSettings(tester, _FakeApi({'kot_text_size': 'large'}));
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsNothing);
      await _tap(tester, _choice(kotPrintStyleKey, 'classic'));
      expect(api.writes.single.body, {'kot_print_style': 'classic'});
      expect(_picked(tester, kotPrintStyleKey, 'classic'), isTrue);
      expect(_picked(tester, kotTextSizeKey, 'large'), isTrue, reason: 'the size is untouched');
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsOneWidget);
      expect(find.text('The next kitchen docket prints as plain text.'), findsOneWidget);
      // A size picked while on classic is kept for later, and says so.
      await _tap(tester, _choice(kotTextSizeKey, 'small'));
      expect(api.writes.last.body, {'kot_text_size': 'small'});
      expect(find.text('Saved. It applies when the kitchen is back on the new docket.'), findsOneWidget);
    });

    testWidgets('a refused save puts the old choice back and says why', (tester) async {
      final api = await _openSettings(
          tester,
          _FakeApi(
            {'kot_print_style': 'reference', 'kot_text_size': 'standard'},
            refuse: ApiException('You do not have permission for this action', 403,
                'You need "Manage Restaurant Settings" to change this.'),
          ));
      await _tap(tester, _choice(kotTextSizeKey, 'large'));
      expect(api.writes.single.body, {'kot_text_size': 'large'});
      expect(_picked(tester, kotTextSizeKey, 'standard'), isTrue, reason: 'reverted');
      expect(_picked(tester, kotTextSizeKey, 'large'), isFalse);
      expect(find.text('You need "Manage Restaurant Settings" to change this.'), findsOneWidget);

      await _tap(tester, _choice(kotPrintStyleKey, 'classic'));
      expect(_picked(tester, kotPrintStyleKey, 'reference'), isTrue, reason: 'reverted');
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsNothing);
    });

    test('the card is built from the settings document and rendered on the screen', () {
      // Source guard, CRLF-safe: the loader copies both keys through the read
      // rules, and the page renders the card from them.
      final src = File('lib/screens/modules.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final start = src.indexOf('Widget settingsModule(RestClient rest, Profile p)');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n    );\n', start));
      expect(body, contains('kotPrintStyleKey: readKotPrintStyle(settings),'));
      expect(body, contains('kotTextSizeKey: readKotTextSize(settings),'));
      expect(body, contains('_KotDocketCard(\n              rest: rest,\n              initialStyle: readKotPrintStyle(m),\n'
          '              initialTextSize: readKotTextSize(m),'));
      // One save path, through the settings write.
      final card = src.substring(src.indexOf('class _KotDocketCardState'));
      expect(card, contains("widget.rest.post('/restaurant/settings', {key: value})"));
    });
  });
}
