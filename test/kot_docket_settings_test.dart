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
//   * a backend that never heard of the keys (the one live before them, or
//     one rolled back to it) prints ONLY the classic docket and ignores a save
//     of them — so the card is not shown against it, and a save it answered
//     without the key is put back with a sentence, never confirmed;
//   * a pick is saved at once, ONE key per save, and put back if refused;
//   * an owner on the classic docket is told the size does nothing there;
//   * the card is actually on the Settings screen, seeded from the settings
//     document (built, and called).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/kot_docket_settings.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(
    this.settings, {
    this.refuse,
    this.ignores = const {},
    this.printReply,
    this.printRefuse,
    this.printOffline = false,
    this.printGate,
  });

  /// What POST /print/test answers (a directed slip by default).
  final Object? printReply;

  /// When set, POST /print/test is refused with this.
  final ApiException? printRefuse;

  /// When true, POST /print/test never reaches a server.
  final bool printOffline;

  /// When set, POST /print/test waits for it — a request still in flight.
  final Completer<void>? printGate;

  final Map<String, dynamic> settings;

  /// When set, every write is refused with this.
  final ApiException? refuse;

  /// Keys this backend's SAVE does not know: a write of them is answered 200
  /// with the settings document, but nothing is stored and the reply does not
  /// carry them — what the backend live before migration 050 does. (The GET
  /// still answers from [settings], so a page can load with both keys and then
  /// meet a backend that has been rolled back.)
  final Set<String> ignores;

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
      if (path == kotTestPrintPath) {
        if (printGate != null) await printGate!.future;
        if (printOffline) throw const SocketException('Network is unreachable');
        if (printRefuse != null) throw printRefuse!;
        return printReply ?? _directedReply;
      }
      if (refuse != null) throw refuse!;
      // The real route answers with the whole settings document, the new value
      // in it.
      if (path == '/restaurant/settings' && body is Map) {
        settings.addAll(Map<String, dynamic>.from(body)..removeWhere((k, _) => ignores.contains(k)));
      }
      return <String, dynamic>{...settings}..removeWhere((k, _) => ignores.contains(k));
    }
    final bare = path.split('?').first;
    if (bare == '/restaurant/settings') return <String, dynamic>{...settings};
    if (bare == '/restaurant/profile') return <String, dynamic>{'restaurant_name': 'Gaia Test'};
    // Every other card on the page reads its own endpoint; an empty document is
    // a tenant with nothing configured there.
    return <String, dynamic>{};
  }
}

/// POST /print/test's answer when the kitchen role is routed to a printer.
const Map<String, dynamic> _directedReply = {
  'results': [
    {'role': 'kot', 'jobId': 'job-1', 'mode': 'directed', 'reason': 'routed', 'destination': 'Kitchen Epson'},
  ],
  'skipped': 0,
};

Widget _host(Widget child, {DesignSystem system = DesignSystem.rustic}) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Settings'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Finder _choice(String key, String value) => find.byKey(ValueKey('$key-$value'));

/// What this backend's GET /restaurant/settings carries for a restaurant that
/// has never chosen: BOTH keys, at their defaults — it sends them even before
/// migration 050 is applied by hand.
Map<String, dynamic> _unchosen() => <String, dynamic>{'kot_print_style': 'reference', 'kot_text_size': 'standard'};

bool _picked(WidgetTester tester, String key, String value) => tester.widget<ForkCard>(_choice(key, value)).selected;

/// Mount Settings and scroll until [target] is built.
Future<void> _mountAndScrollTo(WidgetTester tester, _FakeApi api, Finder target, String what,
    {DesignSystem system = DesignSystem.rustic, Size logical = const Size(1400, 2600), double dpr = 1.0}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!), system: system));
  await tester.pumpAndSettle();
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(target, findsOneWidget, reason: 'never reached $what');
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Mount Settings and bring the KOT card's last choice on screen.
Future<_FakeApi> _openSettings(WidgetTester tester, _FakeApi api) async {
  await _mountAndScrollTo(tester, api, _choice(kotTextSizeKey, 'large'), 'the KOT print style card');
  return api;
}

/// The Ordering cards either side of where the KOT docket card sits.
final _autoPrintCard = find.text('Print the KOT when an order is barked');
final _queueMenuCard = find.text('Show menu & pre-order in the queue');

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('reading the settings document', () {
    test('the defaults are the reference docket at the standard size', () {
      expect(kotPrintStyleDefault, 'reference');
      expect(kotTextSizeDefault, 'standard');
      expect(readKotPrintStyle(_unchosen()), 'reference');
      expect(readKotTextSize(_unchosen()), 'standard');
    });

    test('the settings exist only on a backend whose document carries BOTH keys', () {
      // The backend live before migration 050 sends neither, and prints only
      // the classic docket; this one always sends both.
      expect(kotDocketSettingsSupported(_unchosen()), isTrue);
      expect(kotDocketSettingsSupported({'kot_print_style': 'classic', 'kot_text_size': null}), isTrue);
      expect(kotDocketSettingsSupported(const <String, dynamic>{}), isFalse);
      expect(kotDocketSettingsSupported({'currency': '₹', 'kot_auto_print': true}), isFalse);
      expect(kotDocketSettingsSupported({'kot_print_style': 'reference'}), isFalse);
      expect(kotDocketSettingsSupported({'kot_text_size': 'small'}), isFalse);
      expect(kotDocketSettingsSupported(null), isFalse);
      expect(kotDocketSettingsSupported(const ['kot_print_style', 'kot_text_size']), isFalse);
      // The loader's own key is not one a backend sends.
      expect(kotDocketSupportedKey, isNot(anyOf(kotPrintStyleKey, kotTextSizeKey)));
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
        // Client item 5: the classic docket is no longer the stretched one it
        // printed before — it prints at the printer's normal size.
        "Plain text in the printer's own font, at its normal size. Use it if the new one does not print.",
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
          "Applies to the new docket only. The classic text docket prints in the printer's own font at its normal size, and ignores this setting.");
      expect(kotTextSizeClassicNote,
          'Your kitchens are on the classic text docket, so this size is not used until you switch back.');
      // The style's detail no longer promises LARGER type: the size is a choice now.
      expect(kotPrintStyleOptions.first.detail, isNot(contains(RegExp('larger', caseSensitive: false))));
    });

    test('the test KOT button, in the web card\'s words', () {
      expect(kotTestPrintLabel, 'Print a test KOT');
      expect(kotTestPrintSending, 'Sending a test KOT…');
      expect(kotTestPrintHelp,
          'Sends one test docket to the kitchen printer in the style and size chosen above, so you can check the paper before service.');
      expect(kotTestPrintSentTitle, 'Test KOT sent');
      expect(kotTestPrintFailedTitle, "Couldn't print a test KOT");
      expect(kotTestPrintOffline, 'A test KOT needs a connection — reconnect and try again.');
      expect(kotTestPrintPath, '/print/test');
      expect(kotTestPrintBody, {'role': 'kot'});
    });

    test('the not-stored sentence is the web card\'s', () {
      expect(kotDocketNotSupported, 'This server does not support this setting yet, so nothing was saved.');
      expect('${const KotDocketNotStored()}', kotDocketNotSupported);
    });
  });

  group('what a save stored, and what it says', () {
    test('the reply is the settings document: the stored word is read back from it', () {
      expect(kotDocketSaved({'kot_text_size': 'large'}, kotTextSizeKey, 'large'), 'large');
      expect(kotDocketSaved({'kot_print_style': 'classic'}, kotPrintStyleKey, 'classic'), 'classic');
      // A reply that disagrees wins — it is what the server holds.
      expect(kotDocketSaved({'kot_text_size': 'standard'}, kotTextSizeKey, 'small'), 'standard');
    });

    test('a settings document WITHOUT the key stored nothing: it throws, it does not confirm', () {
      // The backend live before migration 050 answers a save of a key it does
      // not know with 200 and its settings document — which lacks the key.
      expect(() => kotDocketSaved({'currency': '₹'}, kotTextSizeKey, 'small'), throwsA(isA<KotDocketNotStored>()));
      expect(() => kotDocketSaved(<String, dynamic>{}, kotPrintStyleKey, 'classic'),
          throwsA(isA<KotDocketNotStored>()));
      // The OTHER key being there does not count.
      expect(() => kotDocketSaved({'kot_print_style': 'reference'}, kotTextSizeKey, 'large'),
          throwsA(isA<KotDocketNotStored>()));
      expect(() => kotDocketSaved({'kot_text_size': 'small'}, kotPrintStyleKey, 'classic'),
          throwsA(isA<KotDocketNotStored>()));
    });

    test('a reply that is not a document says nothing either way, so the word sent stands', () {
      expect(kotDocketSaved(null, kotPrintStyleKey, 'classic'), 'classic');
      expect(kotDocketSaved('ok', kotTextSizeKey, 'large'), 'large');
      expect(kotDocketSaved(const ['kot_text_size'], kotTextSizeKey, 'small'), 'small');
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

  group('what a test KOT did — the web card\'s sentences', () {
    Map<String, dynamic> reply(Map<String, dynamic> r) => {
          'results': [
            {'role': 'kot', 'jobId': 'j1', ...r},
          ],
          'skipped': 0,
        };

    test('names where the slip went', () {
      expect(kotTestPrintOutcome(reply({'mode': 'directed', 'reason': 'routed', 'destination': 'Kitchen Epson'})),
          'Sent to Kitchen Epson. Check the paper there.');
      expect(kotTestPrintOutcome(reply({'mode': 'directed', 'reason': 'routed', 'destination': null})),
          'Sent to the kitchen printer. Check the paper there.');
      expect(
          kotTestPrintOutcome(reply({'mode': 'broadcast', 'reason': 'no_device_online', 'destination': 'Kitchen Epson'})),
          'Kitchen Epson is not online, so every connected device with a kitchen printer was asked to print it. '
          'Check the paper.');
      for (final reason in ['no_route', 'flag_off', 'schema_missing', 'unpersisted', 'route_lookup_failed']) {
        expect(kotTestPrintOutcome(reply({'mode': 'broadcast', 'reason': reason, 'destination': null})),
            'Every connected device with a kitchen printer was asked to print it. Check the paper.',
            reason: reason);
      }
      expect(kotTestPrintOutcome({'results': <Object>[], 'skipped': 0}), 'Nothing was sent to print.');
      for (final odd in <Object?>[null, 'ok', 1, <Object>[], <String, dynamic>{}, {'results': 'x'}]) {
        expect(kotTestPrintOutcome(odd), "Sent. Check the kitchen printer's paper.", reason: '$odd');
      }
    });

    test('the snackbar lines carry the web toast\'s title and sentence', () {
      expect(kotTestPrintSentMessage(_directedReply), 'Test KOT sent — Sent to Kitchen Epson. Check the paper there.');
      expect(kotTestPrintFailedMessage(kotTestPrintOffline),
          "Couldn't print a test KOT — A test KOT needs a connection — reconnect and try again.");
    });

    test('a test KOT is never saved to send later', () {
      // Every /print write is refused offline — a slip printed an hour late
      // tests nothing, and the kitchen printer would print it mid-service.
      final d = OutboxPolicy.decide('POST', kotTestPrintPath);
      expect(d.queueable, isFalse);
      expect(d.refusal, OutboxPolicy.printing);
    });
  });

  final platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});
  final testButton = find.byKey(const ValueKey('kot-test-print'));
  // The button's own words, whatever the theme does to them (Gaia sets button
  // labels in capitals).
  String label(WidgetTester tester) => tester.widget<ForkButton>(testButton).label;
  bool enabled(WidgetTester tester) => tester.widget<ForkButton>(testButton).onPressed != null;

  for (final system in DesignSystem.values) {
    group('the test KOT button — ${system.name}', () {
      testWidgets('ONE TAP SENDS EXACTLY ONE POST /print/test, and says where the slip went', (tester) async {
        final gate = Completer<void>();
        final api = _FakeApi(_unchosen(), printGate: gate);
        await _mountAndScrollTo(tester, api, testButton, 'the test KOT button', system: system);
        expect(label(tester), kotTestPrintLabel);
        expect(enabled(tester), isTrue);
        expect(find.text(kotTestPrintHelp), findsOneWidget);

        await tester.tap(testButton);
        await tester.pump();
        // In flight: the button says so and does not take a second tap.
        expect(label(tester), kotTestPrintSending);
        expect(enabled(tester), isFalse);
        await tester.tap(testButton, warnIfMissed: false);
        await tester.pump();
        expect(api.writes, hasLength(1));

        gate.complete();
        await tester.pumpAndSettle();
        expect(api.writes.single.method, 'POST');
        expect(api.writes.single.path, '/print/test');
        expect(api.writes.single.body, {'role': 'kot'});
        expect(find.text(kotTestPrintSentMessage(_directedReply)), findsOneWidget);
        expect(label(tester), kotTestPrintLabel, reason: 'ready again');
        expect(enabled(tester), isTrue);
        // Nothing else was written: the settings are untouched.
        expect(api.writes.where((w) => w.path == '/restaurant/settings'), isEmpty);

        // A second press afterwards is a second slip.
        await _tap(tester, testButton);
        expect(api.writes, hasLength(2));
      }, variant: platforms);

      testWidgets("a refusal is shown in the server's own sentence", (tester) async {
        const sentence =
            'Your role does not have permission for this action. Ask an admin to grant it in Roles & Permissions.';
        final api = _FakeApi(_unchosen(),
            printRefuse: ApiException(sentence, 403, sentence, 'Action not permitted'));
        await _mountAndScrollTo(tester, api, testButton, 'the test KOT button', system: system);
        await _tap(tester, testButton);
        expect(api.writes.single.path, kotTestPrintPath);
        expect(find.text(kotTestPrintFailedMessage(sentence)), findsOneWidget);
        expect(label(tester), kotTestPrintLabel, reason: 'ready again');
        expect(enabled(tester), isTrue);
      }, variant: platforms);

      testWidgets('a broadcast slip says where it went instead', (tester) async {
        final reply = <String, dynamic>{
          'results': [
            {'role': 'kot', 'jobId': 'job-2', 'mode': 'broadcast', 'reason': 'no_device_online', 'destination': 'Kitchen Epson'},
          ],
          'skipped': 0,
        };
        final api = _FakeApi(_unchosen(), printReply: reply);
        await _mountAndScrollTo(tester, api, testButton, 'the test KOT button', system: system);
        await _tap(tester, testButton);
        expect(find.text(kotTestPrintSentMessage(reply)), findsOneWidget);
        expect(kotTestPrintSentMessage(reply), contains('Kitchen Epson is not online'));
      }, variant: platforms);

      testWidgets('offline, it says a test KOT needs a connection and saves nothing for later', (tester) async {
        await Outbox.instance.debugReset();
        final api = _FakeApi(_unchosen(), printOffline: true);
        await _mountAndScrollTo(tester, api, testButton, 'the test KOT button', system: system);
        await _tap(tester, testButton);
        expect(api.writes, hasLength(1), reason: 'one attempt');
        expect(find.text(kotTestPrintFailedMessage(kotTestPrintOffline)), findsOneWidget);
        expect(Outbox.instance.hasPending, isFalse);
        expect(label(tester), kotTestPrintLabel, reason: 'ready again');
      }, variant: platforms);

      testWidgets('fits a 360dp phone: nothing on the card runs past its edge', (tester) async {
        // THIS CARD ONLY. At this width the Settings page's payment-mode rows
        // already overflow (a separate, known defect in _PaymentSettingsCard), so
        // an error counts here only when it was raised against a widget this
        // card's source built — and, independently of any error, every box the
        // card lays out must sit inside the card.
        final src = File('lib/screens/modules.dart').readAsStringSync().replaceAll('\r\n', '\n').split('\n');
        final from = src.indexWhere((l) => l.startsWith('class _KotDocketCard ')) + 1;
        final to = src.indexWhere((l) => l.startsWith('class _TimezoneCard ')) + 1;
        expect(from, greaterThan(0));
        expect(to, greaterThan(from));
        final ours = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          final text = details.toString();
          final hit = RegExp(r'modules\.dart:(\d+):').allMatches(text).any((m) {
            final line = int.parse(m.group(1)!);
            return line >= from && line < to;
          });
          if (hit || text.contains('_KotDocketCard')) ours.add(text);
        };
        try {
          final api = _FakeApi({'kot_print_style': 'classic', 'kot_text_size': 'small'});
          await _mountAndScrollTo(tester, api, testButton, 'the test KOT button',
              system: system, logical: const Size(360, 780), dpr: 3.0);
          // The classic note (the longest line on the card) is laid out with it.
          await tester.ensureVisible(find.byKey(const ValueKey('kot-text-size-classic-note')));
          await tester.pumpAndSettle();
          await _tap(tester, testButton);
          expect(api.writes.single.body, {'role': 'kot'});

          final card = find.ancestor(of: testButton, matching: find.byType(ForkCard)).first;
          final cardBox = tester.renderObject<RenderBox>(card);
          final cardRect = cardBox.localToGlobal(Offset.zero) & cardBox.size;
          expect(cardRect.left, greaterThanOrEqualTo(0));
          expect(cardRect.right, lessThanOrEqualTo(360));
          final outside = <String>[];
          var measured = 0;
          for (final e in find.descendant(of: card, matching: find.byWidgetPredicate((_) => true)).evaluate()) {
            final ro = e.renderObject;
            if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
            measured++;
            final r = ro.localToGlobal(Offset.zero) & ro.size;
            if (r.left < cardRect.left - 0.5 || r.right > cardRect.right + 0.5) {
              outside.add('${e.widget.runtimeType} $r outside $cardRect');
            }
          }
          expect(measured, greaterThan(20));
          expect(outside, isEmpty);
        } finally {
          FlutterError.onError = previous;
        }
        expect(ours, isEmpty);
      }, variant: platforms);
    });
  }

  group('the Settings screen', () {
    testWidgets('A BACKEND WITHOUT THE KEYS SHOWS NO KOT DOCKET CARD — it prints classic and stores neither',
        (tester) async {
      // The backend live before migration 050. Showing "Match the reference
      // docket" / "Standard" here would describe a docket it does not print.
      final api = _FakeApi(<String, dynamic>{'kot_auto_print': true}, ignores: {kotPrintStyleKey, kotTextSizeKey});
      await _mountAndScrollTo(tester, api, _autoPrintCard, 'the KOT auto-print card');
      // The card that follows the KOT docket card is next, with nothing between.
      expect(_queueMenuCard, findsOneWidget, reason: 'the rest of Ordering still renders');
      expect(find.text(kotPrintStyleTitle), findsNothing);
      expect(find.text(kotTextSizeTitle), findsNothing);
      expect(_choice(kotPrintStyleKey, 'reference'), findsNothing);
      expect(_choice(kotTextSizeKey, 'standard'), findsNothing);
      expect(api.writes, isEmpty);
    });

    testWidgets('a document carrying only one of the keys shows no card either', (tester) async {
      await _mountAndScrollTo(tester, _FakeApi({'kot_print_style': 'classic'}), _autoPrintCard, 'the KOT auto-print card');
      expect(_queueMenuCard, findsOneWidget);
      expect(find.text(kotPrintStyleTitle), findsNothing);
    });

    testWidgets('a restaurant that has never chosen shows the reference docket, standard size', (tester) async {
      await _openSettings(tester, _FakeApi(_unchosen()));
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
      final api = await _openSettings(tester, _FakeApi(_unchosen()));
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
      final api = await _openSettings(tester, _FakeApi(_unchosen()));
      await _tap(tester, _choice(kotTextSizeKey, 'standard'));
      await _tap(tester, _choice(kotPrintStyleKey, 'reference'));
      expect(api.writes, isEmpty);
    });

    testWidgets('switching to classic saves the style alone, and the size note appears', (tester) async {
      final api = await _openSettings(tester, _FakeApi({'kot_print_style': 'reference', 'kot_text_size': 'large'}));
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

    testWidgets('A BACKEND ROLLED BACK SINCE THE PAGE LOADED: a pick it ignored is put back, never confirmed',
        (tester) async {
      // The page loaded with both keys; the save then meets a backend that
      // ignores them and answers 200 with a document that lacks the key.
      final api = await _openSettings(tester, _FakeApi(_unchosen(), ignores: {kotTextSizeKey, kotPrintStyleKey}));
      await _tap(tester, _choice(kotTextSizeKey, 'small'));
      expect(api.writes.single.body, {'kot_text_size': 'small'});
      expect(_picked(tester, kotTextSizeKey, 'standard'), isTrue, reason: 'put back');
      expect(_picked(tester, kotTextSizeKey, 'small'), isFalse);
      expect(find.text(kotDocketNotSupported), findsOneWidget);
      expect(find.text('The next kitchen docket prints at the small size.'), findsNothing);

      await _tap(tester, _choice(kotPrintStyleKey, 'classic'));
      expect(api.writes.last.body, {'kot_print_style': 'classic'});
      expect(_picked(tester, kotPrintStyleKey, 'reference'), isTrue, reason: 'put back');
      expect(_picked(tester, kotPrintStyleKey, 'classic'), isFalse);
      expect(find.byKey(const ValueKey('kot-text-size-classic-note')), findsNothing);
      expect(find.text('The next kitchen docket prints as plain text.'), findsNothing);
      expect(find.text(kotDocketNotSupported), findsOneWidget);
    });

    test('the card is built from the settings document and rendered on the screen', () {
      // Source guard, CRLF-safe: the loader copies both keys through the read
      // rules, and the page renders the card from them.
      final src = File('lib/screens/modules.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final start = src.indexOf('Widget settingsModule(RestClient rest, Profile p)');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n    );\n', start));
      expect(body, contains('kotDocketSupportedKey: kotDocketSettingsSupported(settings),'));
      expect(body, contains('kotPrintStyleKey: readKotPrintStyle(settings),'));
      expect(body, contains('kotTextSizeKey: readKotTextSize(settings),'));
      expect(
          body,
          contains('if (m[kotDocketSupportedKey] == true) ...[\n'
              '              _KotDocketCard(\n                rest: rest,\n                initialStyle: readKotPrintStyle(m),\n'
              '                initialTextSize: readKotTextSize(m),'));
      // Rendered exactly once, and only inside that guard.
      expect('_KotDocketCard('.allMatches(body).length, 1);
      // One save path, through the settings write.
      final card = src.substring(src.indexOf('class _KotDocketCardState'));
      expect(card, contains("widget.rest.post('/restaurant/settings', {key: value})"));
      // …and the test KOT goes to the existing route, once per press, from a
      // button that is off while it is in flight.
      expect('widget.rest.post(kotTestPrintPath, kotTestPrintBody)'.allMatches(src).length, 1);
      expect(card, contains('onPressed: _testing ? null : _testPrint,'));
      expect(card, contains("key: const ValueKey('kot-test-print'),"));
    });
  });
}
