import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The "your server also offers …" banner, pinned.
///
/// WHY THIS FILE EXISTS. The owner saw that banner, updated the app, and saw it
/// again — because the shipped build genuinely had no editors for the keys it
/// named, so the message was honest and the update could not help. It has now
/// been paid off twice over (all nine colour roles plus the gradient stops and
/// angles), and this test is what stops it coming back: it drives the card with
/// the SERVER'S OWN live-field list and asserts the banner is absent.
///
/// The list below is `BRAND_LIVE_FIELDS` from Restaurant_Backend/brand_theme.ts,
/// copied verbatim rather than derived, ON PURPOSE: if the backend grows a key
/// this app cannot edit, the copy here goes stale, someone updates it, and the
/// staleness test below turns red the moment the two disagree — which is exactly
/// the moment a shipped app would start showing the banner again.
const _serverLiveFields = <String>[
  'scheme',
  'color_primary',
  'color_secondary',
  'color_accent',
  'color_bg',
  'color_card',
  'color_text',
  'color_success',
  'color_warning',
  'color_error',
  'font',
  'font_scale',
  'header_style',
  'button_shape',
  'surface_style',
  'card_shape',
  // BRAND_GRADIENT_KEYS
  'header_grad_from', 'header_grad_to', 'header_grad_angle',
  'button_grad_from', 'button_grad_to', 'button_grad_angle',
  'bg_grad_from', 'bg_grad_to', 'bg_grad_angle',
];

class _FakeApi extends ApiClient {
  _FakeApi(this.settings);
  final Map<String, dynamic> settings;
  final List<({String path, Object? body})> posts = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Test',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (method == 'POST') {
      posts.add((path: path, body: body));
      return <String, dynamic>{'ok': true};
    }
    if (path.startsWith('/restaurant/settings')) return settings;
    return <String, dynamic>{};
  }
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Settings'],
        clearFocus: () {},
        // No scroll wrapper: settingsModule returns a bare ListView, so wrapping
        // it in one gives the list unbounded height and the whole page fails
        // layout before a single assertion runs.
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

/// Mount the Settings module against a server advertising [live].
Future<_FakeApi> _mountSettings(WidgetTester tester, List<String> live) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final api = _FakeApi(<String, dynamic>{
    'brand_config': <String, dynamic>{},
    'brand_fields': <String, dynamic>{'live': live, 'legacy': <String>[]},
    'brand_field_options': <String, dynamic>{},
    'brand_schemes': <dynamic>[],
    'brand_fonts': <String>['Inter'],
  });
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Finder _banner() => find.textContaining('Your server also offers');

/// Settings is a long lazy ListView, so the branding card can sit below the
/// build cache. Scroll until [target] materialises (or the list ends) before
/// asserting ABSENCE — otherwise "not found" only means "not built yet".
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the full server contract leaves NO "update the app" banner', (tester) async {
    await _mountSettings(tester, _serverLiveFields);

    // Scroll to a control the branding card definitely renders FIRST (the
    // group title renders UPPERCASED, as this codebase does throughout). Asserting
    // the banner is absent from a lazy list you never scrolled proves only that
    // nothing was built yet — the anchor is what makes the absence meaningful.
    await _scrollTo(tester, find.text('BRAND COLOURS'));
    expect(find.text('BRAND COLOURS'), findsOneWidget,
        reason: 'never reached the branding card — the absence below would be vacuous');

    // The whole point. Every key the shipped backend advertises has an editor in
    // this build, so the banner must not exist anywhere on the page.
    expect(_banner(), findsNothing,
        reason: 'the app advertises editors for every live server key — a banner here means '
            'a key shipped without its editor, which is the exact defect the owner hit twice');
  });

  testWidgets('a key this build cannot edit brings the banner back, naming it', (tester) async {
    // The banner is not deleted — it is EARNED. A future backend that grows a
    // key must still be able to say so, otherwise the owner silently loses
    // access to a setting instead of being told to update.
    await _mountSettings(tester, [..._serverLiveFields, 'color_glow']);
    await _scrollTo(tester, _banner());

    expect(_banner(), findsOneWidget);
    expect(find.textContaining('color_glow'), findsOneWidget,
        reason: 'the banner must name the unknown key, so it is actionable');
  });

  testWidgets('the banner names ONLY the unknown key, not the ones we can edit', (tester) async {
    await _mountSettings(tester, [..._serverLiveFields, 'color_glow']);
    await _scrollTo(tester, _banner());

    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.contains('Your server also offers'), orElse: () => '');
    expect(text, isNot(contains('color_bg')));
    expect(text, isNot(contains('header_grad_from')));
    expect(text, contains('color_glow'));
  });
}
