// THE OWNER'S "PRINT QR CODE ON THE BILL" SWITCH, ON THE APP (migration 047).
//
// The backend owns the paper: with `bill_show_qr` false, POST /print/bill hands
// escpos.ts no feedback URL and the renderer prints no QR sentence and no code.
// What the app owns is the switch that writes it and the preview that claims to
// show the paper. These tests pin three things:
//
//  * A MISSING KEY IS ON. The column is NULL for every tenant that predates the
//    migration and an older backend omits the key altogether; both have always
//    printed the QR, so neither the preview nor the switch may present it as off.
//  * OFF, THE PREVIEW ENDS WHERE THE ROLL IS CUT — no sentence, no code, and no
//    rule under the disclaimer either (escpos.ts draws that rule inside the same
//    block).
//  * THE SAVE CARRIES THE SWITCH as an explicit boolean, in the same POST as the
//    sentence — and carries the tenant's STORED legal name, GSTIN and sentence
//    with it. The "Bill details" card used to open blank on every tenant because
//    the settings loader never copied those keys in, so Save wiped them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.unknownIsEmpty = false});

  final Map<String, dynamic> routes;

  /// Settings mounts a page of cards that each read their own endpoint; like
  /// brand_contract_test, answer the ones a test does not care about with an
  /// empty document. The Tables screen instead 404s them, as the floor-plan
  /// tests do, so the logo lookups fall through exactly as on a tenant with none.
  final bool unknownIsEmpty;

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
          'action_names': const ['View Bills', 'View Tables'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    final bare = path.split('?').first;
    if (routes.containsKey(bare)) return routes[bare];
    if (unknownIsEmpty) return <String, dynamic>{};
    throw ApiException('No fake route for $path', 404);
  }
}

// --------------------------------------------------------------- fixtures --

/// What the tenant already has stored — the values a Save must NOT blank.
const _stored = <String, dynamic>{
  'bill_legal_name': 'NAVKRISH HOSPITALITY LLP',
  'bill_gstin': '29AAXFN2701Q1ZF',
  'bill_qr_note': 'Scan to call the valet',
  'bill_qr_note_default': 'For calling Valet kindly scan the below QR code',
  'bill_qr_note_max': 120,
};

/// An open bill. [serviceCharge] above zero puts the voluntary-charge
/// disclaimer on the paper, which is what the rule under it hangs off.
Map<String, dynamic> _bill({double serviceCharge = 0}) => {
      'bill_id': 'bill-1',
      'bill_no': '5910',
      'subtotal': 1200.0,
      'total_amt': 1200.0,
      'discount': 0.0,
      'service_charge': serviceCharge,
      'service_charge_percent': serviceCharge > 0 ? 10.0 : 0.0,
      'service_charge_waived': false,
      'taxes': const [],
      'grand_total': 1200.0 + serviceCharge,
      'covers': 3,
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 600.0, 'quantity': 2},
      ],
    };

Map<String, dynamic> _tableRoutes(Map<String, dynamic> settings, {double serviceCharge = 0}) => {
      '/get-tables': [
        {
          'table_name': 'T1',
          'capacity': 4,
          'max_capacity': 6,
          'section': 'Main',
          'occupied': true,
          'has_order': true,
          'reserved': false,
          'covers': 3,
          'table_total': 1200.0,
          'table_apc': 400.0,
          'apc_status': 'neutral',
        }
      ],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': _bill(serviceCharge: serviceCharge),
      '/restaurant/settings': {'kitchen_sections': <dynamic>[], ...settings},
      '/restaurant/profile': {'outlet_add': ''},
    };

// ------------------------------------------------------------------ hosts --

Widget _host(Widget child, List<String> labels) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: labels,
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<(_FakeApi, RestClient)> _signIn(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  return (api, RestClient(auth));
}

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

Finder _inPreview(Finder f) => find.descendant(of: find.byType(Dialog), matching: f);

/// Open T1's receipt preview on the Tables screen, the tenant's settings
/// answering with [settings].
Future<_FakeApi> _openPreview(WidgetTester tester, Map<String, dynamic> settings, {double serviceCharge = 0}) async {
  final (api, rest) = await _signIn(tester, _FakeApi(_tableRoutes(settings, serviceCharge: serviceCharge)));
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!), const ['Tables']));
  await tester.pumpAndSettle();
  await tester.tap(find.text('T1').first);
  await tester.pumpAndSettle();
  try {
    await tester.scrollUntilVisible(_button('Print bill'), 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* already on screen */}
  await tester.pumpAndSettle();
  await tester.tap(_button('Print bill'));
  await tester.pumpAndSettle();
  expect(find.text('Bill preview'), findsOneWidget, reason: 'the receipt preview did not open');
  return api;
}

/// The paper's solid rules (the dialog's `_rule`: full-ink containers) drawn
/// BELOW [anchor] on the preview.
int _rulesBelow(WidgetTester tester, Finder anchor) {
  final bottom = tester.getBottomLeft(_inPreview(anchor)).dy;
  final rules = _inPreview(find.byWidgetPredicate((w) => w is Container && w.color == Colors.black87));
  return rules.evaluate().where((e) => tester.getTopLeft(find.byElementPredicate((x) => x == e)).dy >= bottom).length;
}

final Finder _qrBlock = find.byKey(const ValueKey('bill-preview-qr'));
final Finder _qrNote = find.byKey(const ValueKey('bill-preview-qr-note'));
final Finder _disclaimer = find.byKey(const ValueKey('bill-preview-service-charge-note'));
final Finder _qrSwitch = find.byKey(const ValueKey('bill-show-qr-switch'));
final Finder _qrNoteField = find.byKey(const ValueKey('bill-qr-note-field'));

/// Mount Settings and bring the "Bill details" card's QR switch on screen.
/// Settings is a long lazy ListView; the card sits well below the first frame.
Future<_FakeApi> _openSettings(WidgetTester tester, Map<String, dynamic> settings) async {
  final (api, rest) = await _signIn(
      tester,
      _FakeApi({
        '/restaurant/profile': <String, dynamic>{'restaurant_name': 'Gaia Test'},
        '/restaurant/settings': settings,
      }, unknownIsEmpty: true));
  await tester.pumpWidget(_host(m.settingsModule(rest, rest.auth.profile!), const ['Settings']));
  await tester.pumpAndSettle();
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && _qrSwitch.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(_qrSwitch, findsOneWidget, reason: 'never reached the Bill details card');
  await tester.ensureVisible(_qrSwitch);
  await tester.pumpAndSettle();
  return api;
}

Finder _fieldHolding(String value) => find.byWidgetPredicate(
    (w) => w is TextField && w.controller?.text == value,
    description: 'TextField holding "$value"');

void main() {
  group('the read rule — a missing bill_show_qr is ON', () {
    test('absent, null or true shows the QR; only an explicit false hides it', () {
      expect(m.billShowsQr(const {}), isTrue, reason: 'an older backend omits the key');
      expect(m.billShowsQr(const {'bill_show_qr': null}), isTrue, reason: 'a pre-047 NULL column');
      expect(m.billShowsQr(const {'bill_show_qr': true}), isTrue);
      expect(m.billShowsQr(const {'bill_show_qr': false}), isFalse);
    });
  });

  group('the save payload', () {
    test('always carries bill_show_qr as an explicit boolean, beside the other fields', () {
      for (final on in [true, false]) {
        final body = m.billDetailsSettingsBody(
          legalName: '  NAVKRISH HOSPITALITY LLP ',
          gstin: '29AAXFN2701Q1ZF',
          qrNote: ' Scan to call the valet ',
          showQr: on,
        );
        expect(body['bill_show_qr'], same(on), reason: 'only a boolean writes on the server');
        expect(body, {
          'bill_legal_name': 'NAVKRISH HOSPITALITY LLP',
          'bill_gstin': '29AAXFN2701Q1ZF',
          // Kept while the QR is off — turning it back on brings the sentence back.
          'bill_qr_note': 'Scan to call the valet',
          'bill_show_qr': on,
        });
      }
    });

    test('blank fields are still sent, as the empty string that clears them', () {
      final body = m.billDetailsSettingsBody(legalName: '', gstin: ' ', qrNote: '', showQr: true);
      expect(body, {'bill_legal_name': '', 'bill_gstin': '', 'bill_qr_note': '', 'bill_show_qr': true});
    });
  });

  group('the bill preview mirrors the switch', () {
    testWidgets('settings without the key: the sentence and the QR are on the preview', (tester) async {
      await _openPreview(tester, const {});
      expect(_inPreview(_qrBlock), findsOneWidget);
      expect(_inPreview(_qrNote), findsOneWidget);
      expect(_inPreview(find.text('For calling Valet kindly scan the below QR code')), findsOneWidget,
          reason: 'no tenant sentence and no server default: the built-in valet line');
    });

    testWidgets('bill_show_qr: false — no sentence, no QR, the rest of the paper untouched', (tester) async {
      await _openPreview(tester, {..._stored, 'bill_show_qr': false});
      expect(_inPreview(_qrBlock), findsNothing, reason: 'the paper prints no QR when the owner switched it off');
      expect(_inPreview(_qrNote), findsNothing);
      expect(_inPreview(find.text('Scan to call the valet')), findsNothing,
          reason: 'the stored sentence is kept, but it is not printed');
      expect(_inPreview(find.text('Grand Total')), findsOneWidget);
      expect(_inPreview(find.text('GSTN : 29AAXFN2701Q1ZF')), findsOneWidget);
      expect(_button('Print'), findsOneWidget, reason: 'the preview still leads to the print');
    });

    testWidgets('bill_show_qr: true shows the tenant\'s own sentence over the QR', (tester) async {
      await _openPreview(tester, {..._stored, 'bill_show_qr': true});
      expect(_inPreview(_qrBlock), findsOneWidget);
      expect(_inPreview(find.text('Scan to call the valet')), findsOneWidget);
    });

    // escpos.ts: `if (opts.feedbackUrl) { if (opts.serviceChargeNote) rule(); … }`.
    // The rule between the disclaimer and the QR belongs to the QR block.
    testWidgets('with the disclaimer on the paper, the rule under it goes with the QR', (tester) async {
      await _openPreview(tester, const {}, serviceCharge: 120);
      expect(_inPreview(_disclaimer), findsOneWidget);
      expect(_rulesBelow(tester, _disclaimer), 1, reason: 'QR on: one rule between the disclaimer and the QR');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _openPreview(tester, const {'bill_show_qr': false}, serviceCharge: 120);
      expect(_inPreview(_disclaimer), findsOneWidget, reason: 'the disclaimer does not depend on the QR');
      expect(_inPreview(_qrBlock), findsNothing);
      expect(_rulesBelow(tester, _disclaimer), 0, reason: 'QR off: the paper ends at the disclaimer');
    });
  });

  group('the Bill details card carries the switch', () {
    testWidgets('settings without the key open the switch ON with the sentence box enabled', (tester) async {
      await _openSettings(tester, Map<String, dynamic>.from(_stored));
      expect(find.text('Print QR code on the bill'), findsOneWidget);
      expect(find.text('The feedback / valet QR at the bottom of every customer bill.'), findsOneWidget);
      expect(tester.widget<Switch>(_qrSwitch).value, isTrue);
      expect(tester.widget<TextField>(_qrNoteField).enabled, isTrue);
      // THE LOADER REGRESSION: the card opens on what the tenant has stored.
      expect(_fieldHolding('NAVKRISH HOSPITALITY LLP'), findsOneWidget);
      expect(_fieldHolding('29AAXFN2701Q1ZF'), findsOneWidget);
      expect(tester.widget<TextField>(_qrNoteField).controller!.text, 'Scan to call the valet');
    });

    testWidgets('bill_show_qr: false opens the switch OFF with the sentence box disabled, not hidden',
        (tester) async {
      await _openSettings(tester, {..._stored, 'bill_show_qr': false});
      expect(tester.widget<Switch>(_qrSwitch).value, isFalse);
      expect(_qrNoteField, findsOneWidget, reason: 'disabled, not hidden');
      final field = tester.widget<TextField>(_qrNoteField);
      expect(field.enabled, isFalse);
      expect(field.controller!.text, 'Scan to call the valet', reason: 'the wording stays visible');
    });

    testWidgets('the switch disables the box live, and Save posts bill_show_qr with the stored fields',
        (tester) async {
      final api = await _openSettings(tester, Map<String, dynamic>.from(_stored));
      await tester.tap(_qrSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(_qrSwitch).value, isFalse);
      expect(tester.widget<TextField>(_qrNoteField).enabled, isFalse);
      expect(api.writes, isEmpty, reason: 'the switch rides the card\'s Save; it does not write on the tap');

      await tester.ensureVisible(_button('Save bill details'));
      await tester.pumpAndSettle();
      await tester.tap(_button('Save bill details'));
      await tester.pumpAndSettle();

      final posts = api.writes.where((w) => w.method == 'POST' && w.path == '/restaurant/settings').toList();
      expect(posts, hasLength(1));
      expect(posts.single.body, {
        'bill_legal_name': 'NAVKRISH HOSPITALITY LLP',
        'bill_gstin': '29AAXFN2701Q1ZF',
        'bill_qr_note': 'Scan to call the valet',
        'bill_show_qr': false,
      });
    });
  });
}
