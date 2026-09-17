// SETTINGS > PAYMENTS ON A PHONE.
//
// Each switched-on till mode carries two options under its label box —
// "Require payment screenshot" and "Show on guest QR page" — each a checkbox
// beside its words. They sat in min-size Rows whose words could not wrap, so on
// a 360dp phone (the card's inner width is 274px) they ran 18-101px past the
// card's right edge, in both design systems, on Android and on Windows (36-49px
// even at 412dp). Flutter reports that as "A RenderFlex overflowed", and the
// words were cut off under the warning stripes.
//
// This mounts the real Settings screen at 360dp and pins two things:
//   * nothing INSIDE the Payments card reports an error while every one of its
//     rows is on screen — built-in, custom and online modes, switched on and
//     off — in Rustic and Gaia, on Android and Windows;
//   * the options still do what they did: a tap on a box flips the same field
//     of the same mode, the words are not a second switch, and Save sends the
//     same payment_methods document.
//
// Other Settings cards are laid out too while the screen scrolls. Their own
// errors are collected apart and are not this card's to answer for; an error
// that cannot be traced to a widget at all is counted against the card.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/payment_modes.dart';
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

class _FakeApi extends ApiClient {
  _FakeApi(this.settings);

  final Map<String, dynamic> settings;
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
      if (path == '/restaurant/settings' && body is Map) {
        settings.addAll(Map<String, dynamic>.from(body));
      }
      return <String, dynamic>{...settings};
    }
    final bare = path.split('?').first;
    if (bare == '/restaurant/settings') return <String, dynamic>{...settings};
    if (bare == '/restaurant/profile') return <String, dynamic>{'restaurant_name': 'Gaia Test'};
    return <String, dynamic>{};
  }
}

/// Every shape a row can take: the built-in modes (the online gateway with its
/// "online" chip and no options, then the till modes, each with both options),
/// a custom mode with a long label (so the "added" chip and the "Stored on
/// bills as" line), and a switched-off custom mode (no options) at the bottom.
List<Map<String, dynamic>> _modes() => [
      for (final d in PaymentModes.fallback) d.toJson(),
      const PaymentMode(
        id: 'HDFC card machine counter 2',
        label: 'HDFC card machine counter 2',
        requiresScreenshot: true,
        custom: true,
        showToGuests: true,
      ).toJson(),
      const PaymentMode(id: 'Magicpin', label: 'Magicpin', custom: true, enabled: false).toJson(),
    ];

Widget _host(DesignSystem system, Widget child) => GaiaScope(
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

const _shot = 'Require payment screenshot';
const _guests = 'Show on guest QR page';
// The Gaia skin sets button labels in capitals; the words are the same.
final _saveButton = find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').toLowerCase() == 'save payments & currency',
  description: 'the "Save payments & currency" button label',
);
final _list = find.byType(Scrollable).first;

Finder _row(String id) => find.byKey(ValueKey('payment-mode-row-$id'));

/// The option [label] inside the row of mode [id].
Finder _option(String id, String label) =>
    find.descendant(of: _row(id), matching: find.widgetWithText(Row, label));

Finder _checkbox(String id, String label) =>
    find.descendant(of: _option(id, label), matching: find.byType(Checkbox));

/// One reported Flutter error, and whether a widget inside the Payments card
/// reported it (worked out when it was reported, while that widget still
/// existed).
typedef _Reported = ({FlutterErrorDetails details, bool inCard});

/// Whether [d] was raised by a widget under the Payments card. A layout error
/// names the widget that built the failing render object; one that names none
/// is counted against the card, so nothing unexplained is waved through.
bool _raisedInCard(FlutterErrorDetails d) {
  final nodes = d.informationCollector?.call() ?? const <DiagnosticsNode>[];
  for (final n in nodes) {
    final creator = n is DiagnosticsDebugCreator ? n.value : null;
    if (creator is DebugCreator) {
      var inside = false;
      creator.element.visitAncestorElements((e) {
        if (e.widget.runtimeType.toString() == '_PaymentSettingsCard') {
          inside = true;
          return false;
        }
        return true;
      });
      return inside;
    }
  }
  return true;
}

/// Runs [body] with every reported Flutter error collected into [into]. The
/// binding's own handler is put back BEFORE this returns — the binding checks
/// that at the end of the test body, not after its tear-downs.
Future<void> _collecting(List<_Reported> into, Future<void> Function() body) async {
  final prior = FlutterError.onError;
  FlutterError.onError = (d) => into.add((details: d, inCard: _raisedInCard(d)));
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
}

List<String> _cardErrors(List<_Reported> errors) =>
    [for (final r in errors) if (r.inCard) r.details.exceptionAsString().split('\n').first];

/// Scroll the Settings list until [target] is built and on screen.
Future<void> _bringIn(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    // Rows above the viewport are not built; look up first, then down.
    for (final delta in const [-200.0, 200.0]) {
      if (target.evaluate().isNotEmpty) break;
      try {
        await tester.scrollUntilVisible(target, delta, scrollable: _list, maxScrolls: 200);
      } on StateError {
        // Not in that direction.
      } on TestFailure {
        // Not in that direction.
      }
    }
  }
  expect(target, findsOneWidget, reason: 'never reached $target');
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Mount Settings on a 360x780 phone (dpr 3), with every error collected.
Future<void> _mountPhone(WidgetTester tester, DesignSystem system, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(system, m.settingsModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
}

void main() {
  const phone = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android, TargetPlatform.windows});

  for (final system in [DesignSystem.rustic, DesignSystem.gaia]) {
    group('Settings > Payments at 360dp (${system.name})', () {
      testWidgets('no row of the card overflows, and every option sits inside it', (tester) async {
        final errors = <_Reported>[];
        final api = _FakeApi(<String, dynamic>{'currency': '₹', 'payment_methods': _modes()});
        var rowsSeen = 0;
        await _collecting(errors, () async {
          await _mountPhone(tester, system, api);
          for (final mode in PaymentModes.parse(_modes())) {
            await _bringIn(tester, _row(mode.id));
            rowsSeen++;
            final card = tester.getRect(find.ancestor(of: _row(mode.id), matching: find.byType(ForkCard)).first);
            final hasOptions = mode.enabled && !mode.online;
            for (final label in const [_shot, _guests]) {
              final o = _option(mode.id, label);
              expect(o, hasOptions ? findsOneWidget : findsNothing, reason: '${mode.id} / $label');
              if (hasOptions) {
                final r = tester.getRect(o);
                expect(r.right, lessThanOrEqualTo(card.right + 0.5), reason: '${mode.id} / $label runs past the card');
                expect(r.left, greaterThanOrEqualTo(card.left - 0.5), reason: '${mode.id} / $label starts outside the card');
              }
            }
          }
          await _bringIn(tester, _saveButton);
        });
        expect(rowsSeen, _modes().length);
        expect(_cardErrors(errors), isEmpty, reason: 'errors raised inside the Payments card');
      }, variant: phone);

      testWidgets('the options still flip the same field, and Save sends the same document', (tester) async {
        final errors = <_Reported>[];
        final api = _FakeApi(<String, dynamic>{'currency': '₹', 'payment_methods': _modes()});
        await _collecting(errors, () async {
          await _mountPhone(tester, system, api);

          // Each box starts where the parsed mode says, and one tap flips it.
          final parsed = {for (final p in PaymentModes.parse(_modes())) p.id: p};
          final taps = [
            (_checkbox('Upi', _shot), parsed['Upi']!.requiresScreenshot),
            (_checkbox('Upi', _guests), parsed['Upi']!.showToGuests),
            (_checkbox('HDFC card machine counter 2', _guests), parsed['HDFC card machine counter 2']!.showToGuests),
          ];
          for (final (box, before) in taps) {
            await _bringIn(tester, box);
            expect(tester.widget<Checkbox>(box).value, before, reason: '$box before the tap');
            await tester.tap(box);
            await tester.pumpAndSettle();
            expect(tester.widget<Checkbox>(box).value, !before, reason: '$box after the tap');
          }

          // Tapping the WORDS toggles nothing: only the box was ever the switch.
          final cashShot = _checkbox('Cash', _shot);
          final words = find.descendant(of: _row('Cash'), matching: find.text(_shot));
          await _bringIn(tester, words);
          final cashBefore = tester.widget<Checkbox>(cashShot).value;
          await tester.tap(words, warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(tester.widget<Checkbox>(cashShot).value, cashBefore, reason: 'the words flipped the box');

          await _bringIn(tester, _saveButton);
          await tester.tap(_saveButton);
          await tester.pumpAndSettle();
        });

        final saves = api.writes.where((w) => w.path == '/restaurant/settings').toList();
        expect(saves, hasLength(1));
        final body = saves.single.body! as Map;
        expect(body.keys.toSet(), {'currency', 'payment_methods'});
        final sent = {for (final j in body['payment_methods'] as List) (j as Map)['id']: j};
        // What the card has always sent: each mode as parsed, the three taps
        // applied to their own fields, labels tidied from their boxes.
        final expected = {
          for (final p in PaymentModes.parse(_modes()))
            p.id: switch (p.id) {
              'Upi' => p.copyWith(requiresScreenshot: !p.requiresScreenshot, showToGuests: !p.showToGuests),
              'HDFC card machine counter 2' => p.copyWith(showToGuests: !p.showToGuests),
              _ => p,
            }
                .copyWith(label: PaymentModes.tidy(p.label))
                .toJson(),
        };
        expect(sent.keys.toList(), expected.keys.toList(), reason: 'order and set of modes');
        for (final id in expected.keys) {
          expect(sent[id], expected[id], reason: 'mode $id');
        }
        expect(_cardErrors(errors), isEmpty, reason: 'errors raised inside the Payments card');
      }, variant: phone);
    });
  }
}
