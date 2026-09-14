// THE SETTINGS CARDS MUST SHOW — AND SAVE — THE LIVE SETTINGS, NOT A SAVED COPY.
//
// AsyncView keeps its subtree mounted when a live refresh lands over a saved copy
// (so pages never jump to the top). Settings cards seed themselves from the
// payload once, so they kept the saved copy: a mode switched off on the web came
// back on the next time Payments was saved here. settingsModule now keys its
// cards on the payload. Found by the integration review of the 1.9.8 merge.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/payment_modes.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/get_cache.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<({String method, String path, Object? body})> writes = [];
  Completer<void>? gate;

  @override
  Future<LoginResult> login(String restaurantName, String user, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
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
      if (path == '/restaurant/settings' && body is Map && body['payment_methods'] is List) {
        return <String, dynamic>{'payment_methods': body['payment_methods']};
      }
      return <String, dynamic>{'success': true};
    }
    if (gate != null) await gate!.future;
    if (routes.containsKey(path)) return routes[path];
    return <String, dynamic>{};
  }
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Settings'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

List<Map<String, dynamic>> _modes({bool webEdited = false}) => [
      for (final d in PaymentModes.fallback)
        {
          ...d.toJson(),
          // What another editor (web Settings > Payments) saved while this
          // device's copy of /restaurant/settings sat in the GET cache.
          if (webEdited && d.id == 'Card') 'enabled': false,
          if (webEdited && d.id == 'Upi') 'label': 'GPay',
          if (webEdited && d.id == 'Cash') 'requires_screenshot': true,
        },
    ];

Future<void> _ageCache(Duration by) async {
  final p = await SharedPreferences.getInstance();
  final oldMs = DateTime.now().subtract(by).millisecondsSinceEpoch;
  for (final k in p.getKeys().where((k) => k.startsWith(GetCache.keyPrefix)).toList()) {
    final d = (jsonDecode(p.getString(k)!) as Map)['d'];
    await p.setString(k, '{"t":$oldMs,"d":${jsonEncode(d)}}');
  }
}

void main() {
  testWidgets('an aged saved copy of Settings: the Payments card adopts the live list and saves it, not the copy',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = _FakeApi({
      '/restaurant/profile': <String, dynamic>{'restaurant_name': 'CSR Organics'},
      '/restaurant/settings': {'payment_methods': _modes(), 'currency': '₹'},
    });
    final auth = AuthController(api: api);
    await auth.login('CSR Organics', 'admin', 'admin123');
    final rest = RestClient(auth);

    // Earlier visit: the network load lands and is saved.
    await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await _ageCache(const Duration(minutes: 5));

    // Meanwhile the web dashboard edited the modes.
    api.routes['/restaurant/settings'] = {'payment_methods': _modes(webEdited: true), 'currency': '₹'};
    api.gate = Completer<void>();
    await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!)));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Updated'), findsWidgets, reason: 'precondition: the saved copy is on screen first');
    api.gate!.complete();
    api.gate = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('Updated'), findsNothing, reason: 'precondition: the live refresh landed');

    final list = find.byType(Scrollable).first;
    final save = find.text('Save payments & currency');
    for (var i = 0; i < 40 && save.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -400));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();

    final upi = tester.widget<TextField>(find.byKey(const ValueKey('payment-mode-label-Upi')));
    final card = tester.widget<Switch>(find.byKey(const ValueKey('payment-mode-enabled-Card')));
    expect(upi.controller!.text, 'GPay', reason: 'the card still shows the saved copy label');
    expect(card.value, isFalse, reason: 'the card still shows a mode the web switched off as on');

    await tester.tap(save);
    await tester.pumpAndSettle();
    final body = api.writes.lastWhere((w) => w.path == '/restaurant/settings').body as Map;
    final sent = (body['payment_methods'] as List).cast<Map>();
    Map pick(String id) => sent.firstWhere((x) => x['id'] == id);
    expect(pick('Upi')['label'], 'GPay');
    expect(pick('Card')['enabled'], isFalse, reason: 'saving wrote the stale copy over the web edit');
    expect(pick('Cash')['requires_screenshot'], isTrue);
  });
}
