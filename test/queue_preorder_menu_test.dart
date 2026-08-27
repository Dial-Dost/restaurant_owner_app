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
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The QUEUE PRE-ORDER MENU editor inside the Menu module.
///
/// A walk-in waiting in the queue can stage a pre-order before they sit down.
/// This screen decides WHICH dishes that list offers and HOW it reads — while
/// the dine-in menu stays exactly as it is.
///
/// What is being defended here:
///  * the editor is reachable and its controls are LIVE (this app has shipped
///    dead-looking controls before — see the dead_tap_sweep suite);
///  * a save sends the whole rule to /queue-menu-config in the shape the server
///    merges, and "back to the whole menu" sends `reset`, because an empty rule
///    object is NOT the same as no rule at all;
///  * the preview honours the same category order and price switch a queuing
///    guest gets, so an owner is never shown one thing and their guests another.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];
  final List<Object?> bodies = <Object?>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Kitchen',
          'restaurantUsername': 'gaia',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    bodies.add(body);
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Kitchen', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (label, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Menu'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

Map<String, dynamic> _item(String id, String name, num price, String category, {bool available = true}) =>
    <String, dynamic>{'id': id, 'name': name, 'price': price, 'category': category, 'available': available};

/// The menu the module lists, and the queue-config payload the dialog loads.
/// `queue_included` is what the SERVER computed — the editor reports it, it does
/// not decide it.
Map<String, dynamic> _routes({
  Map<String, dynamic>? config,
  bool configured = false,
  bool queueShowMenu = true,
  List<Map<String, dynamic>>? items,
}) {
  final menu = items ??
      <Map<String, dynamic>>[
        _item('m-biryani', 'Dum Biryani', 480, 'Mains'),
        _item('m-paneer', 'Paneer Tikka', 390, 'Starters'),
        _item('m-lassi', 'Sweet Lassi', 120, 'Drinks'),
      ];
  final cfg = <String, dynamic>{
    'mode': 'all',
    'items': <String>[],
    'categories': <String>[],
    'category_order': <String>[],
    'headline': '',
    'intro': '',
    'show_prices': true,
    ...?config,
  };
  return <String, dynamic>{
    '/menu': menu,
    '/menu/costing': {'items': <dynamic>[], 'ingredients': <dynamic>[]},
    '/restaurant/settings': {'kitchen_sections': <String>[]},
    '/queue-menu-config': {
      'config': cfg,
      'configured': configured,
      'queue_show_menu': queueShowMenu,
      'items': [
        for (final it in menu) <String, dynamic>{...it, 'queue_included': it['available'] != false},
      ],
      'categories': ['Drinks', 'Mains', 'Starters'],
    },
  };
}

Future<_FakeApi> _openDialog(
  WidgetTester tester, {
  Map<String, dynamic>? config,
  bool configured = false,
  bool queueShowMenu = true,
  List<Map<String, dynamic>>? items,
}) async {
  tester.view.physicalSize = const Size(1500, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(_routes(config: config, configured: configured, queueShowMenu: queueShowMenu, items: items));
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(m.menuModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Queue pre-order menu'));
  await tester.pumpAndSettle();
  return api;
}

/// Tap a ForkButton by its label (the design system's buttons are gesture
/// detectors, not Material buttons).
Future<void> _tapButton(WidgetTester tester, String label) async {
  final f = find.widgetWithText(ForkButton, label).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The preview's own copy, keyed so it cannot be confused with the editor field
/// that feeds it (both render the same placeholder).
String _previewText(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

/// The category chip the preview shows FIRST — the tab a guest lands on.
String _firstPreviewTab(WidgetTester tester) => tester
    .widget<StatusChip>(find
        .descendant(of: find.byKey(const Key('queue_preview_tabs')), matching: find.byType(StatusChip))
        .first)
    .label;

Object? _lastBodyFor(_FakeApi api, String call) {
  for (var i = api.calls.length - 1; i >= 0; i--) {
    if (api.calls[i] == call) return api.bodies[i];
  }
  return null;
}

void main() {
  testWidgets('the editor opens from the Menu module and loads the current rule', (tester) async {
    final api = await _openDialog(tester);

    expect(api.calls, contains('GET /queue-menu-config'));
    // Three modes are the whole vocabulary — an owner never types a rule.
    expect(find.text('Everything'), findsOneWidget);
    expect(find.text('Only what I pick'), findsOneWidget);
    expect(find.text('Everything except'), findsOneWidget);
    // The preview is there from the first frame, showing the built-in copy.
    expect(find.text('WHAT A QUEUING GUEST SEES'), findsOneWidget);
    expect(_previewText(tester, 'queue_preview_headline'), 'Get a head start');
    expect(find.textContaining('3 of 3 dishes offered'), findsOneWidget);
  });

  testWidgets('choosing a mode reveals the dish picker, and excluding one drops it from the preview', (tester) async {
    await _openDialog(tester);

    await tester.tap(find.text('Everything except'));
    await tester.pumpAndSettle();
    expect(find.text('KEEP THESE OFF'), findsOneWidget);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Dum Biryani'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 of 3 dishes offered'), findsOneWidget);
  });

  testWidgets('ticking a whole category decides its dishes, and their rows stop pretending to be tappable', (tester) async {
    await _openDialog(tester);
    await tester.tap(find.text('Everything except'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('queue_cat_Starters')));
    await tester.pumpAndSettle();

    // The Paneer row is now decided BY ITS CATEGORY. Leaving it enabled would be
    // a control that looks live and changes nothing — the bug class this app has
    // shipped before.
    final row = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Paneer Tikka'));
    expect(row.value, isTrue);
    expect(row.onChanged, isNull);
    expect(find.textContaining('2 of 3 dishes offered'), findsOneWidget);
  });

  testWidgets('custom wording replaces the built-in line in the preview', (tester) async {
    await _openDialog(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Heading'), 'Order while you wait');
    await tester.pumpAndSettle();

    // The built-in heading is gone — the restaurant's own words replace it.
    expect(_previewText(tester, 'queue_preview_headline'), 'Order while you wait');
  });

  testWidgets('turning prices off takes them out of the preview', (tester) async {
    await _openDialog(tester);
    // Scoped to the preview: the menu list behind the dialog prices the same
    // dish, and that list is not what this switch governs.
    Finder priceInPreview() => find.descendant(
          of: find.byKey(const Key('queue_preview')),
          matching: find.text('₹120.00'),
        );
    expect(priceInPreview(), findsOneWidget); // Drinks leads alphabetically

    final priceSwitch = find.byType(Switch).first;
    await tester.ensureVisible(priceSwitch);
    await tester.pumpAndSettle();
    await tester.tap(priceSwitch);
    await tester.pumpAndSettle();

    expect(priceInPreview(), findsNothing);
  });

  testWidgets('re-ordering categories moves the tab in the preview and travels in the save', (tester) async {
    final api = await _openDialog(tester);

    // Alphabetical to begin with: Drinks, Mains, Starters.
    final up = find.byTooltip('Move Mains up');
    await tester.ensureVisible(up);
    await tester.pumpAndSettle();
    await tester.tap(up);
    await tester.pumpAndSettle();
    // The preview's leading tab follows immediately.
    expect(_firstPreviewTab(tester), 'Mains');
    await _tapButton(tester, 'Save');

    final body = _lastBodyFor(api, 'POST /queue-menu-config')! as Map;
    expect(body['category_order'], ['Mains', 'Drinks', 'Starters']);
    // The whole rule travels, so the server's merge-on-omit has nothing to
    // guess at.
    expect(body.keys, containsAll(<String>['mode', 'items', 'categories', 'headline', 'intro', 'show_prices']));
  });

  testWidgets('a save carries the exclusion the owner ticked', (tester) async {
    final api = await _openDialog(tester);
    await tester.tap(find.text('Everything except'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Dum Biryani'));
    await tester.pumpAndSettle();

    await _tapButton(tester, 'Save');

    final body = _lastBodyFor(api, 'POST /queue-menu-config')! as Map;
    expect(body['mode'], 'exclude');
    expect(body['items'], ['m-biryani']);
  });

  testWidgets('"back to the whole menu" is inert until something IS configured', (tester) async {
    // An un-configured tenant has nothing to undo; a live-looking button that
    // did nothing would be worse than a disabled one.
    await _openDialog(tester);
    final button = tester.widget<ForkButton>(find.widgetWithText(ForkButton, 'Back to the whole menu'));
    expect(button.onPressed, isNull);
  });

  testWidgets('"back to the whole menu" sends the reset the server needs', (tester) async {
    final api = await _openDialog(tester, configured: true, config: {
      'mode': 'exclude',
      'items': ['m-biryani'],
    });

    await _tapButton(tester, 'Back to the whole menu');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    // `reset` is its own flag: clearing every key by hand would leave an empty
    // object behind, which still reads as "this tenant configured something".
    expect(_lastBodyFor(api, 'POST /queue-menu-config'), <String, dynamic>{'reset': true});
  });

  testWidgets('a sold-out dish is reported as not offered, with the reason on the row', (tester) async {
    await _openDialog(tester, items: [
      _item('m-biryani', 'Dum Biryani', 480, 'Mains'),
      _item('m-fish', 'Fish Curry', 520, 'Mains', available: false),
    ]);

    await tester.tap(find.text('Everything except'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sold out'), findsOneWidget);
    expect(find.textContaining('1 of 2 dishes offered'), findsOneWidget);
  });

  testWidgets('the master queue-menu switch being off is called out — none of this shows otherwise', (tester) async {
    await _openDialog(tester, queueShowMenu: false);
    expect(find.textContaining('show no menu at all'), findsOneWidget);
  });
}
