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

/// Guest book / Menu / Valet / Kitchen were converted from one full-width row
/// per record to the compact card grid. These tests pin the three sizes that
/// actually broke layouts before — nothing, one, and a realistic full service —
/// plus the kitchen's own rule: a chef must be able to read EVERY line of a
/// ticket without tapping, however narrow the column gets.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Orders', 'Bookings', 'Menu', 'Kitchen', 'Valet'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

/// A desktop-sized window — the whole point of the grids is the space a wide
/// window used to waste, so every case is pumped at a real owner-app size.
void _desktop(WidgetTester tester, {double width = 1700, double height = 1200}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Mounts a module on a clean tree. The blank pump matters: the modules are
/// AsyncViews, so re-pumping the same widget type would keep the previous
/// State — and its already-loaded payload — instead of fetching the new one.
/// It also disposes the outgoing screen, which is how the kitchen board's poll
/// timer gets cancelled between cases.
Future<void> _mount(WidgetTester tester, Widget Function(RestClient) module, Map<String, dynamic> routes) async {
  await tester.pumpWidget(const SizedBox());
  final rest = await _signIn(_FakeApi(routes));
  await tester.pumpWidget(_host(module(rest)));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _guest(int i) => {
      'customer_id': 'c$i',
      'name': 'Guest $i Lastname',
      'phone_number': '90000000$i',
      'email': 'guest$i@example.com',
      'booking_count': i % 5,
      'has_booking': i % 3 == 0,
    };

Map<String, dynamic> _dish(int i) => {
      'id': 'menu-$i',
      'name': 'Dish $i',
      'price': 100 + i,
      'category': 'Mains',
      'available': i % 4 != 0,
      'station': 'Tandoor',
    };

Map<String, dynamic> _vehicle(int i) => {
      'booking_id': 'v$i',
      'number_plate': 'MH12AB${1000 + i}',
      'customer_name': 'Owner $i',
      'status': 'Vehicle added',
      'bay_name': 'Front Lot',
      'parking_location': 'P2 / Slot $i',
      'key_holder': 'Attendant',
      'active': true,
    };

Map<String, dynamic> _ticket(int i, {int items = 3}) => {
      'id': 'ord-$i',
      'table': 'T$i',
      'status': 'Preparing',
      'barked_at': '2026-08-01T10:00:00Z',
      'total': 500,
      'timing': {'order': {'started_at': '2026-08-01T10:00:00Z'}, 'items': <String, dynamic>{}},
      'items': [
        for (var k = 0; k < items; k++)
          {'id': 'i$i-$k', 'name': 'Ticket $i item $k', 'quantity': k + 1, 'station': 'Tandoor'},
      ],
    };

void main() {
  // --- Guest book ------------------------------------------------------------

  testWidgets('Guest book: empty, one guest, and a full book all render', (tester) async {
    _desktop(tester);

    await _mount(tester, (r) => m.customersModule(r, r.auth.profile!), {'/get-customers': <dynamic>[]});
    expect(find.text('Nothing to show'), findsOneWidget);
    expect(find.text('Guest book'), findsNothing);

    await _mount(tester, (r) => m.customersModule(r, r.auth.profile!), {'/get-customers': [_guest(1)]});
    expect(find.text('Guest 1 Lastname'), findsOneWidget);
    expect(find.text('900000001'), findsOneWidget);

    await _mount(tester, (r) => m.customersModule(r, r.auth.profile!),
        {'/get-customers': [for (var i = 0; i < 40; i++) _guest(i)]});
    // Every guest is built, not just the first screenful.
    expect(find.text('Guest 0 Lastname'), findsOneWidget);
    expect(find.text('Guest 39 Lastname'), findsOneWidget);
  });

  testWidgets('Guest book: the tap opens the contact details the tile ellipses', (tester) async {
    _desktop(tester);
    await _mount(tester, (r) => m.customersModule(r, r.auth.profile!), {'/get-customers': [_guest(1)]});

    await tester.tap(find.text('Guest 1 Lastname'));
    await tester.pumpAndSettle();
    expect(find.text('GUEST BOOK'), findsOneWidget);
    expect(find.text('EMAIL'), findsOneWidget);
    expect(find.text('guest1@example.com'), findsWidgets);
  });

  // --- Menu ------------------------------------------------------------------

  testWidgets('Menu: empty, one dish, and a 40-dish menu all render', (tester) async {
    _desktop(tester);

    await _mount(tester, (r) => m.menuModule(r, r.auth.profile!), {'/menu': <dynamic>[]});
    expect(find.text('No menu items yet'), findsOneWidget);

    await _mount(tester, (r) => m.menuModule(r, r.auth.profile!), {'/menu': [_dish(1)]});
    expect(find.text('Dish 1'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);

    await _mount(tester, (r) => m.menuModule(r, r.auth.profile!),
        {'/menu': [for (var i = 0; i < 40; i++) _dish(i)]});
    expect(find.text('Dish 0'), findsOneWidget);
    expect(find.text('Dish 39'), findsOneWidget);
    // Sold-out dishes keep their labelled chip on the tile — never colour alone.
    expect(find.text('Sold out'), findsNWidgets(10));
  });

  testWidgets('Menu: delete and section-assign moved into the tap, not onto the tile', (tester) async {
    _desktop(tester);
    await _mount(tester, (r) => m.menuModule(r, r.auth.profile!), {'/menu': [_dish(1)]});

    // A mis-tap on a dense grid must not be able to reach delete.
    expect(find.byTooltip('Delete item'), findsNothing);
    // 86-ing a dish is the mid-service action, so it stays on the tile.
    expect(find.byTooltip('Mark sold out'), findsOneWidget);

    await tester.tap(find.text('Dish 1'));
    await tester.pumpAndSettle();
    expect(find.text('Delete item'), findsOneWidget);
    expect(find.text('Kitchen section'), findsOneWidget);
    expect(find.text('Edit item'), findsOneWidget);
  });

  // --- Valet -----------------------------------------------------------------

  testWidgets('Valet: empty, one vehicle, and a full lot all render', (tester) async {
    _desktop(tester);

    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {'bays': <dynamic>[], 'bookings': <dynamic>[]},
    });
    expect(find.text('No vehicles on valet'), findsOneWidget);

    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {'bays': <dynamic>[], 'bookings': [_vehicle(1)]},
    });
    expect(find.text('MH12AB1001'), findsOneWidget);
    // The stage action never moves behind a tap — a guest is at the desk.
    expect(find.text('Mark parked'), findsOneWidget);

    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {'bays': <dynamic>[], 'bookings': [for (var i = 0; i < 40; i++) _vehicle(i)]},
    });
    expect(find.text('MH12AB1000'), findsOneWidget);
    expect(find.text('MH12AB1039'), findsOneWidget);
  });

  testWidgets('Valet: the ops actions survive the move into the tap', (tester) async {
    _desktop(tester);
    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {'bays': <dynamic>[], 'bookings': [_vehicle(1)]},
    });

    await tester.tap(find.text('MH12AB1001'));
    await tester.pumpAndSettle();
    for (final label in ['Bay', 'Location', 'Hand over', 'Condition', 'Charge']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" must not be dropped');
    }
  });

  // The vehicle tile carries four FREE-TEXT fields in chips — the guest's name,
  // the bay, the parking spot an attendant types by hand, the key holder — and
  // none of them has a length limit on the way in. Before the grid conversion
  // that row had the full window; a tile column is ~340px, and a plain chip
  // overflows rather than truncating. Every column count the grid produces is
  // pinned, because the widest tile is not the safe one: it is the one where the
  // owner's window is wide enough for FOUR columns.
  testWidgets('Valet: a 60-char name and location do not overflow the tile', (tester) async {
    for (final width in [1100.0, 1200.0, 1700.0]) {
      _desktop(tester, width: width, height: 1200);
      await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
        '/valet-info': {
          'bays': <dynamic>[],
          'bookings': [
            {
              ..._vehicle(1),
              'customer_name': 'Dr Anantharamakrishnan Venkataraghavan Subramanian',
              // What an attendant actually types into a field with no maxLength.
              'parking_location': 'Basement level 3, pillar B14, beside the service lift, nose out',
              'key_holder': 'Attendant Ramachandran (evening shift, desk two)',
              'bay_name': 'Front lot, kerbside row nearest the porte-cochere',
            },
          ],
        },
      });

      expect(tester.takeException(), isNull, reason: 'vehicle tile overflowed at ${width}px');
      // Still a usable tile, not a blank one: the plate and the stage action are
      // exactly what a degraded chip must not cost.
      expect(find.text('MH12AB1001'), findsOneWidget, reason: 'plate lost at ${width}px');
      expect(find.text('Mark parked'), findsOneWidget, reason: 'stage action lost at ${width}px');
    }
  });

  testWidgets('Valet: the bay sheet takes the same long values without overflowing', (tester) async {
    _desktop(tester, width: 1100, height: 1200);
    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {
        'bays': [
          {'Bay_id': 'b1', 'Bay_name': 'Kerbside', 'current_capacity': 1, 'total_capacity': 4},
        ],
        'bookings': [
          {
            ..._vehicle(2),
            'bay_id': 'b1',
            'customer_name': 'Dr Anantharamakrishnan Venkataraghavan Subramanian',
            'parking_location': 'Basement level 3, pillar B14, beside the service lift, nose out',
            'key_holder': 'Attendant Ramachandran (evening shift, desk two)',
          },
        ],
      },
    });

    await tester.tap(find.text('Kerbside').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'bay sheet overflowed on free text');
    expect(find.text('MH12AB1002'), findsWidgets);
  });

  testWidgets('Valet: the full untruncated location is one tap away', (tester) async {
    const spot = 'Basement level 3, pillar B14, beside the service lift, nose out';
    _desktop(tester, width: 1200, height: 1200);
    await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), {
      '/valet-info': {
        'bays': <dynamic>[],
        'bookings': [
          {..._vehicle(3), 'parking_location': spot},
        ],
      },
    });

    // Capped on the tile…
    expect(find.text(spot), findsNothing);
    await tester.tap(find.text('MH12AB1003'));
    await tester.pumpAndSettle();
    // …and spelled out in full on the detail sheet, so nothing is actually lost.
    expect(find.text(spot), findsOneWidget);
  });

  // --- Kitchen ---------------------------------------------------------------

  testWidgets('Kitchen: empty, one ticket, and a full board all render', (tester) async {
    _desktop(tester);

    await _mount(tester, (r) => m.kdsModule(r, r.auth.profile!), {'/orders': <dynamic>[]});
    expect(find.text('No active kitchen tickets'), findsOneWidget);

    await _mount(tester, (r) => m.kdsModule(r, r.auth.profile!), {'/orders': [_ticket(1)]});
    expect(find.text('Table T1'), findsOneWidget);
    expect(find.text('Ticket 1 item 0'), findsOneWidget);
    // Bump / hold stay ON the ticket.
    expect(find.text('Mark Served'), findsOneWidget);
    expect(find.text('Hold'), findsOneWidget);

    await _mount(tester, (r) => m.kdsModule(r, r.auth.profile!),
        {'/orders': [for (var i = 0; i < 40; i++) _ticket(i)]});
    expect(find.text('Table T0'), findsOneWidget);
    expect(find.text('Table T39'), findsOneWidget);
    // 40 tickets x 3 lines, every one of them built.
    expect(find.textContaining('Ticket 39 item'), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Kitchen: a 15-item ticket shows every line on the card, untruncated', (tester) async {
    // 1620 is exactly where the board goes to three across, so each ticket gets
    // the NARROWEST column the kitchen ever produces (~520px). The whole point
    // of the kitchen exception is that shrinking a ticket horizontally must not
    // cost the chef a single line.
    _desktop(tester, width: 1620, height: 1400);
    await _mount(tester, (r) => m.kdsModule(r, r.auth.profile!), {
      '/orders': [
        {
          'id': 'ord-long',
          'table': 'T7',
          'status': 'Preparing',
          'barked_at': '2026-08-01T10:00:00Z',
          'timing': {'order': {'started_at': '2026-08-01T10:00:00Z'}, 'items': <String, dynamic>{}},
          'items': [
            for (var k = 0; k < 18; k++)
              {
                'id': 'li-$k',
                // Long on purpose — a real dish name is what used to ellipse.
                'name': 'Paneer Butter Masala with extra gravy $k',
                'quantity': k + 1,
                'station': 'Tandoor',
              },
          ],
        },
      ],
    });

    for (var k = 0; k < 18; k++) {
      final name = 'Paneer Butter Masala with extra gravy $k';
      final line = find.text(name);
      expect(line, findsOneWidget, reason: 'line $k must be on the ticket, not behind a tap');
      // Not "+3 more", not an ellipsis: the name wraps and the card grows.
      final widget = tester.widget<Text>(line);
      expect(widget.maxLines, isNull, reason: 'line $k must not be clipped to a line count');
      expect(widget.overflow, anyOf(isNull, TextOverflow.clip),
          reason: 'line $k must not ellipse when the column narrows');
    }
    // And the ticket still carries its own actions.
    expect(find.text('Mark Served'), findsOneWidget);
    expect(find.byTooltip('Print KOT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
