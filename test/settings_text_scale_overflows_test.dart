// SETTINGS ON A 360dp PHONE AT LARGE TEXT.
//
// A sweep of the Settings screen at 360x800 with the text at 1.3x found rows
// that could not give way, in both design systems:
//
//   * Payments: each till mode's "Require payment screenshot" / "Show on guest
//     QR page" sat in a min-size Row whose words could not wrap;
//   * Messaging: the provider dropdown was as wide as its widest choice
//     ("Twilio (SMS / WhatsApp)"), over 200px wider than the card;
//   * Branding: the logo box and the "Upload logo" button sat in one Row;
//   * Appearance: at 2x, the design-system picker's miniatures (82px tall)
//     could not hold their sample figure.
//
// Each test mounts the real widget on a 360x800 phone, scrolls every part of
// the card through the screen (an overflow is only reported when it paints),
// and pins that nothing under THAT card overflowed, that its words are inside
// it, and that its controls still do what they did. Other Settings cards are
// laid out too; their errors are not these tests' business.

import 'dart:math' as math;

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
import 'package:restaurant_owner_app/ui/theme/app_spacing.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/appearance_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  final Map<String, dynamic> settings = <String, dynamic>{
    'payment_methods': [
      for (final d in PaymentModes.fallback) d.toJson(),
      const PaymentMode(
        id: 'HDFC card machine counter 2',
        label: 'HDFC card machine counter 2',
        requiresScreenshot: true,
        custom: true,
        showToGuests: true,
      ).toJson(),
    ],
    'msg_provider': 'none',
  };
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
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
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{...settings};
    }
    final bare = path.split('?').first;
    if (bare == '/restaurant/settings') return <String, dynamic>{...settings};
    if (bare == '/restaurant/profile') return <String, dynamic>{'restaurant_name': 'Gaia Test'};
    return <String, dynamic>{};
  }
}

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

/// A 360dp phone wearing [system] the way the running app does: the scope for
/// the primitives, the ThemeData for everything else, and the controller for
/// the widgets that read it directly (Appearance does).
Future<RestClient> _device(WidgetTester tester, DesignSystem system, _FakeApi api) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await AppearanceController.instance.setDesignSystem(system);
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  return RestClient(auth);
}

Widget _app(DesignSystem system, Widget home, {double scale = 1.3}) => GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );

Widget _settings(DesignSystem system, RestClient rest) => _app(
      system,
      ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Settings'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: m.settingsModule(rest, rest.auth.profile!)),
      ),
    );

/// Runs [body] while collecting every error the framework reports, then hands
/// back the overflows raised by a RenderFlex under any widget [roots] finds.
/// Overflows elsewhere are dropped (other Settings cards are not these tests'
/// business); any report that is not a RenderFlex overflow is thrown, so a
/// real failure is never swallowed with them.
Future<List<String>> _overflowsUnder(WidgetTester tester, Finder roots, Future<void> Function() body) async {
  final reports = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = reports.add;
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
  final tops = [for (final e in roots.evaluate()) e.renderObject!];
  bool under(RenderObject r) {
    for (RenderObject? p = r; p != null; p = p.parent) {
      if (tops.any((t) => identical(p, t))) return true;
    }
    return false;
  }

  final here = <String>[];
  for (final d in reports) {
    final flexes = [
      for (final node in d.informationCollector?.call() ?? const <DiagnosticsNode>[])
        if (node.value is RenderFlex) node.value! as RenderFlex,
    ];
    if (flexes.isEmpty || !d.exceptionAsString().startsWith('A RenderFlex overflowed')) {
      fail('an error that is not an overflow: ${d.exceptionAsString()}\n${d.stack}');
    }
    if (flexes.any(under)) here.add(d.exceptionAsString());
  }
  return here;
}

final _list = find.byType(Scrollable).first;

/// The Settings card titled [title].
Finder _card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ForkCard)).first;

/// Drags the Settings list until [title] is built, then walks its card through
/// the screen top to bottom, a frame at each step, so every row is painted.
/// The budget is raised from the default 50 drags: Settings on a phone at
/// large text grows whenever a row learns to wrap, and a test further down the
/// page ran out at 50 once the Payments options wrapped.
Future<void> _paintThrough(WidgetTester tester, String title) async {
  await tester.scrollUntilVisible(find.text(title), 300, scrollable: _list, maxScrolls: 200);
  final card = _card(title);
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  final pos = tester.state<ScrollableState>(_list).position;
  final top = pos.pixels;
  final height = tester.getSize(card).height;
  for (var y = top;; y += pos.viewportDimension / 2) {
    pos.jumpTo(math.min(y, pos.maxScrollExtent));
    await tester.pump();
    if (y + pos.viewportDimension >= top + height || y >= pos.maxScrollExtent) break;
  }
}

void _expectInside(Finder part, Rect box, String what) {
  for (final e in part.evaluate()) {
    final ro = e.renderObject! as RenderBox;
    final r = ro.localToGlobal(Offset.zero) & ro.size;
    expect(r.left >= box.left - 0.01 && r.right <= box.right + 0.01, isTrue,
        reason: '$what at $r runs past the sides of $box');
  }
}

/// A button by its label; Gaia sets button labels in capitals.
Finder _button(String label) => find.byWidgetPredicate(
    (w) => w is ForkButton && w.label == label, description: 'the "$label" button');

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  for (final system in DesignSystem.values) {
    // ------------------------------------------------------------ payments ---

    testWidgets('payments: the till options wrap inside the card at 1.3x (${system.label})', (tester) async {
      final rest = await _device(tester, system, _FakeApi());
      const title = 'Payments & currency';
      final overflows = await _overflowsUnder(tester, _card(title), () async {
        await tester.pumpWidget(_settings(system, rest));
        await tester.pumpAndSettle();
        await _paintThrough(tester, title);
      });
      expect(overflows, isEmpty);

      final card = tester.getRect(_card(title));
      for (final words in ['Require payment screenshot', 'Show on guest QR page']) {
        final found = find.descendant(of: _card(title), matching: find.text(words, skipOffstage: false));
        // Every switched-on till mode carries both options.
        expect(found, findsNWidgets(PaymentModes.fallback.where((d) => d.enabled && !d.online).length + 1));
        _expectInside(found, card, '"$words"');
      }
    }, variant: _platforms);

    // ----------------------------------------------------------- messaging ---

    testWidgets('messaging: the provider dropdown fits the card at 1.3x and still switches (${system.label})',
        (tester) async {
      final api = _FakeApi();
      final rest = await _device(tester, system, api);
      const title = 'Guest messaging (SMS / WhatsApp)';
      final dropdown = find.byType(DropdownButton<String>);
      final choices = ['Off (log only)', 'Twilio (SMS / WhatsApp)', 'Meta WhatsApp Cloud API'];

      final overflows = await _overflowsUnder(tester, _card(title), () async {
        await tester.pumpWidget(_settings(system, rest));
        await tester.pumpAndSettle();
        await _paintThrough(tester, title);

        // Pick the Meta provider the way an owner does, with the dropdown on screen.
        await tester.ensureVisible(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Meta WhatsApp Cloud API').last);
        await tester.pumpAndSettle();
      });
      expect(overflows, isEmpty);
      expect(tester.widget<DropdownButton<String>>(dropdown).value, 'meta');
      // The Meta form, not the Twilio one.
      expect(find.text('ACCOUNT SID (TWILIO)'), findsNothing);

      // What the closed dropdown shows sits inside its field, whichever is chosen.
      // (A form-field dropdown draws its own InputDecorator, inside itself.)
      final field = tester.getRect(find.descendant(of: dropdown, matching: find.byType(InputDecorator)));
      for (final c in choices) {
        // All three are laid out (an IndexedStack); only the chosen one is onstage.
        final shown = find.descendant(
            of: find.byType(DropdownButton<String>, skipOffstage: false),
            matching: find.text(c, skipOffstage: false),
            skipOffstage: false);
        expect(shown, findsOneWidget);
        _expectInside(shown, field, '"$c"');
      }

      // And Save still sends the chosen provider.
      final save = _button('Save messaging settings');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final sent = api.writes.where((w) => w.path == '/restaurant/settings').toList();
      expect(sent, hasLength(1));
      expect((sent.single.body! as Map)['msg_provider'], 'meta');
    }, variant: _platforms);

    // ------------------------------------------------------------ branding ---

    testWidgets('branding: the logo and its upload button fit the card at 1.3x (${system.label})', (tester) async {
      final rest = await _device(tester, system, _FakeApi());
      const title = 'Customer ordering page branding';
      final overflows = await _overflowsUnder(tester, _card(title), () async {
        await tester.pumpWidget(_settings(system, rest));
        await tester.pumpAndSettle();
        await _paintThrough(tester, title);
      });
      expect(overflows, isEmpty);

      final upload = _button('Upload logo');
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      final card = tester.getRect(_card(title));
      _expectInside(upload, card, 'the upload button');
      _expectInside(
          find.descendant(of: _card(title), matching: find.byIcon(Icons.storefront)), card, 'the logo');
      expect(upload.hitTestable(), findsOneWidget, reason: 'the upload button is on screen but cannot be tapped');
    }, variant: _platforms);

    // ---------------------------------------------------------- appearance ---

    testWidgets('appearance: the design-system miniatures hold their figure at 2x (${system.label})',
        (tester) async {
      await _device(tester, system, _FakeApi());
      final swatches = find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('design-swatch-'),
          description: 'the design-system swatches');
      final overflows = await _overflowsUnder(tester, swatches, () async {
        await tester.pumpWidget(_app(
          system,
          Scaffold(body: ListView(padding: AppSpacing.pageNarrow, children: const [AppearanceCard()])),
          scale: 2.0,
        ));
        await tester.pumpAndSettle();
        await tester.ensureVisible(swatches.first);
        await tester.pumpAndSettle();
      });
      expect(swatches, findsNWidgets(DesignSystem.values.length));
      expect(overflows, isEmpty);

      // Each still names its system under the picture, and a tap still picks it.
      final other = DesignSystem.values.firstWhere((d) => d != system);
      for (final d in DesignSystem.values) {
        expect(find.descendant(of: find.byKey(ValueKey('design-swatch-${d.id}')), matching: find.text(d.label)),
            findsOneWidget);
      }
      // The tap lands on the picture: at 2x the name under it can be wider than
      // it, and the space beside the picture was never part of the tap target.
      // Picking Rustic brings in its backdrop preview, whose overflows are not
      // this test's.
      final otherSwatch = find.byKey(ValueKey('design-swatch-${other.id}'));
      final afterTap = await _overflowsUnder(tester, swatches, () async {
        await tester.tapAt(tester.getTopLeft(otherSwatch) + const Offset(20, 20));
        await tester.pumpAndSettle();
      });
      expect(AppearanceController.instance.designSystem, other);
      expect(afterTap, isEmpty);
    }, variant: _platforms);
  }
}
