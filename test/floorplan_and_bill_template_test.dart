// REQUIREMENTS 2.1 AND 5.1, ON THE APP.
//
// 2.1 — "In the Floor Plan, users can rearrange, group tables, and modify the
// layout. In the Tables Section, users are not permitted to move, change layout,
// format, or delete tables, and make sure what is seen in tables is not shown in
// the floor plan."
//
// D5 had already moved the CONTROLS apart. What it left behind was one tile for
// both screens, so the Floor plan still painted the live floor (Occupied, the
// bill, covers, the waiter) and a tap on it opened the service sheet with the
// order, the bill and Settle. These tests pin the Floor plan as a layout editor
// and the Tables screen as unchanged.
//
// 5.1 — "Ensure the restaurant's logo, address, and GSTIN number are clearly
// visible on both the print preview and the final printed customer bill." The
// app's preview drew no logo at all, and drew the address and GSTIN as the
// faintest type on the sheet.

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

/// A 1x1 PNG — enough for Image.memory to be handed real bytes.
const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];
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

  // EXACT paths only (query string ignored). A prefix match would answer
  // /restaurant/logo/bill with /restaurant/logo, which is the one distinction
  // the logo tests are about.
  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    final bare = path.split('?').first;
    if (routes.containsKey(bare)) return routes[bare];
    throw ApiException('No fake route for $path', 404);
  }
}

Map<String, dynamic> _occupiedTable({bool otp = false}) => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 6,
      'section': 'Main',
      'occupied': true,
      'has_order': true,
      'reserved': false,
      'covers': 3,
      'table_total': 1380.0,
      'table_apc': 460.0,
      'apc_status': 'red',
      // Only where a test needs it: on the TABLES tile a four-digit OTP pill
      // overflows the 168px card (a separate, pre-existing layout issue), and
      // the Floor plan test is the one that must prove it is NOT drawn.
      'order_otp': otp ? '4821' : null,
      'otp_required': otp,
    };

Map<String, dynamic> _bill() => {
      'bill_id': 'bill-1',
      'bill_no': '5910',
      'subtotal': 1200.0,
      'total_amt': 1200.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'taxes': const [],
      'grand_total': 1200.0,
      'covers': 3,
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Paneer Tikka', 'price': 600.0, 'quantity': 2},
      ],
    };

Map<String, dynamic> _routes({Map<String, dynamic> extra = const {}, bool otp = false}) => {
      '/get-tables': [_occupiedTable(otp: otp)],
      '/table-assignments': [
        {'table_name': 'T1', 'employee_name': 'Ravi K', 'employee_id': 'emp-9'},
      ],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': _bill(),
      '/restaurant/settings': {
        'kitchen_sections': <dynamic>[],
        'bill_legal_name': 'NAVKRISH HOSPITALITY LLP',
        'bill_gstin': '29AAXFN2701Q1ZF',
      },
      '/restaurant/profile': {'outlet_add': 'NO 283, 15TH CROSS ROAD\n100 FEET ROAD, JP NAGAR'},
      ...extra,
    };

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Floor plan'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(WidgetTester tester,
    {required bool plan, Map<String, dynamic> extra = const {}, bool otp = false}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(_routes(extra: extra, otp: otp));
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'asha', 'pw');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(
      plan ? m.floorPlanModule(rest, rest.auth.profile!) : m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

List<String> _painted(WidgetTester tester) => [
      for (final rt in tester.widgetList<RichText>(find.byType(RichText)))
        rt.text.toPlainText(includeSemanticsLabels: false, includePlaceholders: false),
    ];

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* already on screen, or not on this sheet at all */}
  await tester.pumpAndSettle();
}

void main() {
  group('2.1 — the Floor plan shows none of what Tables shows', () {
    testWidgets('an occupied, billed, waited table is just a table on the Floor plan', (tester) async {
      await _mount(tester, plan: true, otp: true);
      final painted = _painted(tester).join(' | ');

      expect(find.text('T1'), findsWidgets);
      expect(painted, contains('4 seats · max 6'));
      for (final live in ['Occupied', 'Seated', 'Reserved', 'Free', '₹', 'covers', 'APC', 'OTP', 'Ravi', 'PAID']) {
        expect(painted.contains(live), isFalse, reason: 'the Floor plan showed "$live": $painted');
      }
    });

    testWidgets('its header counts the layout, not the occupancy', (tester) async {
      await _mount(tester, plan: true);
      final painted = _painted(tester).join(' | ');
      expect(painted, contains('1 table'));
      expect(painted, contains('4 seats'));
      expect(RegExp(r'\d+\s+(Occupied|Seated|Reserved|Free)').hasMatch(painted), isFalse);
    });

    testWidgets('it does not even read who is waiting on a table or which booking it is in', (tester) async {
      final api = await _mount(tester, plan: true);
      expect(api.calls.where((c) => c.contains('/table-assignments')), isEmpty);
      expect(api.calls.where((c) => c.contains('/get-bookings')), isEmpty);
    });

    testWidgets('a tap opens the LAYOUT sheet: seats, zone, Edit seating — no order, bill or settle',
        (tester) async {
      final api = await _mount(tester, plan: true);
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();

      expect(find.text('Table T1'), findsOneWidget);
      expect(find.text('Main'), findsWidgets);
      expect(_button('Edit seating'), findsOneWidget);
      for (final service in ['Settle bill', 'Add order', 'Print bill', 'Release without payment', 'Move table', 'Refund']) {
        expect(_button(service), findsNothing, reason: '"$service" is a Tables act');
      }
      expect(api.calls.where((c) => c.contains('/bill-for-table')), isEmpty,
          reason: 'the layout sheet loaded the running bill');
    });

    testWidgets('Edit seating from the Floor plan still writes the seating PATCH', (tester) async {
      final api = await _mount(tester, plan: true);
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Edit seating'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      final save = find.descendant(of: find.byType(Dialog), matching: find.byType(FilledButton));
      await tester.tap(save.last);
      await tester.pumpAndSettle();
      expect(api.writes.where((w) => w.method == 'PATCH' && w.path == '/table/T1'), hasLength(1));
    });

    testWidgets('the Tables screen still shows the live floor, unchanged', (tester) async {
      await _mount(tester, plan: false);
      final painted = _painted(tester).join(' | ');
      expect(painted, contains('Occupied'));
      expect(painted, contains('3 covers'));
      expect(painted, contains('₹1380.00'));
      expect(_button('Edit seating'), findsNothing);
    });
  });

  group('5.1 — the logo decoder', () {
    test('reads logo_base64, with or without a data: prefix', () {
      expect(m.billLogoBytes({'logo_base64': _png1x1}), isNotNull);
      expect(m.billLogoBytes({'logo_base64': 'data:image/png;base64,$_png1x1'}), isNotNull);
    });

    test('no logo, a blank one, garbage or the wrong shape is null', () {
      expect(m.billLogoBytes(null), isNull);
      expect(m.billLogoBytes({'error': 'Logo not found'}), isNull);
      expect(m.billLogoBytes({'logo_base64': ''}), isNull);
      expect(m.billLogoBytes({'logo_base64': '%%% not base64 %%%'}), isNull);
      expect(m.billLogoBytes(['not', 'a', 'map']), isNull);
    });
  });

  group('5.1 — the bill preview carries the logo, address and GSTIN clearly', () {
    Future<void> openPreview(WidgetTester tester) async {
      await tester.tap(find.text('T1').first);
      await tester.pumpAndSettle();
      await _reveal(tester, _button('Print bill'));
      await tester.tap(_button('Print bill'));
      await tester.pumpAndSettle();
      expect(find.text('Bill preview'), findsOneWidget);
    }

    Finder inPreview(Finder f) => find.descendant(of: find.byType(Dialog), matching: f);

    testWidgets('the logo the roll prints is on the preview', (tester) async {
      final api = await _mount(tester, plan: false, extra: {
        '/restaurant/logo/bill': {'logo_base64': _png1x1},
      });
      await openPreview(tester);
      expect(inPreview(find.byKey(const ValueKey('bill-preview-logo'))), findsOneWidget);
      expect(api.calls.where((c) => c == 'GET /restaurant/logo'), isEmpty,
          reason: 'the bill logo answered; the branding logo is only the fallback');
    });

    testWidgets('an older backend falls back to the branding logo', (tester) async {
      final api = await _mount(tester, plan: false, extra: {
        '/restaurant/logo': {'logo_base64': _png1x1},
      });
      await openPreview(tester);
      expect(api.calls, contains('GET /restaurant/logo/bill'));
      expect(inPreview(find.byKey(const ValueKey('bill-preview-logo'))), findsOneWidget);
    });

    testWidgets('a tenant with no logo gets a clean preview, not a broken image', (tester) async {
      await _mount(tester, plan: false);
      await openPreview(tester);
      expect(inPreview(find.byKey(const ValueKey('bill-preview-logo'))), findsNothing);
      expect(inPreview(find.text('Gaia Test')), findsOneWidget);
    });

    testWidgets('address and GSTIN are in full ink at body size', (tester) async {
      await _mount(tester, plan: false);
      await openPreview(tester);
      for (final line in ['NAVKRISH HOSPITALITY LLP', 'NO 283, 15TH CROSS ROAD', '100 FEET ROAD, JP NAGAR', 'GSTN : 29AAXFN2701Q1ZF']) {
        final t = tester.widget<Text>(inPreview(find.text(line)));
        expect(t.style?.color, Colors.black87, reason: '"$line" was not drawn in full ink');
        expect(t.style?.fontSize, greaterThanOrEqualTo(12), reason: '"$line" was drawn too small');
      }
    });
  });
}
