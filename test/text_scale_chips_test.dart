import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/metric_tag.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// InfoChip / StatusChip / TickTag are `Row(mainAxisSize: min)` around a plain
/// Text. Given a bounded width they used to OVERFLOW — yellow-and-black stripes
/// — instead of truncating, and it kept recurring: the Valet tile one release,
/// the table tile the next. A 1.3x system text scale is an ordinary accessibility
/// setting, so every one of these is pumped at 1.0x AND 1.3x.
///
/// The bar is two-sided on purpose: no overflow, and the label must still be
/// READABLE afterwards. Trading an overflow for 4pt text is not a fix, so the
/// rendered font size is asserted alongside every layout case.
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
    if (method != 'GET') return <String, dynamic>{'success': true};
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
        visibleLabels: const ['Tables', 'Valet', 'Menu'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    );

void _size(WidgetTester tester, double width, double height, double scale) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _mount(WidgetTester tester, Widget Function(RestClient) module, Map<String, dynamic> routes) async {
  await tester.pumpWidget(const SizedBox());
  final rest = await _signIn(_FakeApi(routes));
  await tester.pumpWidget(_host(module(rest)));
  await tester.pumpAndSettle();
}

/// The rendered height of one line of [finder]'s text. A chip that "fits" by
/// shrinking its label to nothing is not a fix, so this is the legibility floor.
double _lineHeight(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return box.size.height;
}

/// Every width the widths that broke before: a portrait phone and the three
/// desktop column counts the grids produce.
const List<double> _widths = [390, 1100, 1200, 1700];
const List<double> _scales = [1.0, 1.3];

Map<String, dynamic> _tableRoutes(List<Map<String, dynamic>> tables) => {
      '/get-tables': tables,
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
    };

/// A table carrying every free-text field the tile can show at once: the long
/// seat label, an APC tick beside the status, covers, and a waiter's name.
Map<String, dynamic> _loadedTable(String name) => {
      'table_name': name,
      'capacity': 12,
      'max_capacity': 20,
      'section': 'Main',
      'occupied': true,
      'reserved': false,
      'covers': 14,
      'waiter_name': 'Ramachandran',
      'table_total': 4800,
      'table_apc': 342.85,
      'apc_status': 'yellow',
    };

Map<String, dynamic> _valetRoutes() => {
      '/valet-info': {
        'bays': <dynamic>[],
        'bookings': [
          {
            'booking_id': 'v1',
            'number_plate': 'MH12AB1001',
            'customer_name': 'Dr Anantharamakrishnan Venkataraghavan Subramanian',
            'status': 'Vehicle added',
            'bay_name': 'Front lot, kerbside row nearest the porte-cochere',
            'parking_location': 'Basement level 3, pillar B14, beside the service lift, nose out',
            'key_holder': 'Attendant Ramachandran (evening shift, desk two)',
            'active': true,
          },
        ],
      },
    };

void main() {
  // --- The shared widget, in isolation ---------------------------------------

  group('InfoChip under a bounded width', () {
    testWidgets('ellipses instead of overflowing, and keeps its font size', (tester) async {
      for (final scale in _scales) {
        _size(tester, 800, 600, scale);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 90, // narrower than the label needs at either scale
                child: InfoChip(icon: Icons.event_seat_outlined, label: '12 seats · max 20'),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'InfoChip overflowed at ${scale}x');
        final label = tester.widget<Text>(find.text('12 seats · max 20'));
        expect(label.overflow, TextOverflow.ellipsis, reason: 'a clipped label must show it was clipped');
        expect(label.maxLines, 1);
        // Ellipsised, NOT scaled down: the glyphs are the same size they would
        // be with room to spare.
        expect(label.style?.fontSize, 11, reason: 'the fix must not shrink the type at ${scale}x');
      }
    });

    testWidgets('is unchanged when the space is ample', (tester) async {
      for (final scale in _scales) {
        _size(tester, 800, 600, scale);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Column(mainAxisSize: MainAxisSize.min, children: [
              // Unbounded: nothing constrains this one at all.
              Align(
                alignment: Alignment.centerLeft,
                child: InfoChip(
                    key: ValueKey('loose'), icon: Icons.event_seat_outlined, label: '12 seats · max 20'),
              ),
              // Bounded, but with room to spare.
              SizedBox(
                width: 400,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InfoChip(
                      key: ValueKey('roomy'), icon: Icons.event_seat_outlined, label: '12 seats · max 20'),
                ),
              ),
            ]),
          ),
        ));
        await tester.pumpAndSettle();

        final loose = tester.getSize(find.byKey(const ValueKey('loose'))).width;
        final roomy = tester.getSize(find.byKey(const ValueKey('roomy'))).width;
        // Ample space renders exactly as before the fix: the pill hugs its label
        // rather than stretching to the parent, and the two agree to the pixel.
        expect(roomy, loose, reason: 'a bounded-but-roomy chip must match the unbounded one at ${scale}x');
        expect(loose, lessThan(400), reason: 'the chip must still hug its text at ${scale}x');
      }
    });

    testWidgets('survives an unbounded width — a Row with no constraint at all', (tester) async {
      _size(tester, 800, 600, 1.3);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              const InfoChip(icon: Icons.badge_outlined, label: 'Ramachandran'),
              StatusChip(label: 'Occupied', color: AppColors.copper, dense: true),
              TickTag('APC close', color: AppColors.warning),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'a loose Flexible must not assert when unbounded');
      expect(find.text('Ramachandran'), findsOneWidget);
    });
  });

  group('StatusChip and TickTag under a bounded width', () {
    testWidgets('both ellipse rather than overflow, at either scale', (tester) async {
      for (final scale in _scales) {
        _size(tester, 800, 600, scale);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 60,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  StatusChip(label: 'Occupied', color: AppColors.copper, dense: true),
                  TickTag('APC close', color: AppColors.warning),
                ]),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'a chip overflowed at ${scale}x');
        expect(tester.widget<Text>(find.text('Occupied')).style?.fontSize, 10.5);
        expect(tester.widget<Text>(find.text('APC close')).style?.fontSize, 10.5);
      }
    });
  });

  // --- The tiles that actually broke -----------------------------------------

  testWidgets('Tables: the table tile takes a 1.3x scale at every width', (tester) async {
    for (final scale in _scales) {
      for (final width in _widths) {
        _size(tester, width, 1200, scale);
        await _mount(tester, (r) => m.tablesModule(r, r.auth.profile!),
            _tableRoutes([_loadedTable('T1'), _loadedTable('T2')]));

        expect(tester.takeException(), isNull,
            reason: 'the table tile overflowed at ${width}px / ${scale}x');
        // Still a usable tile: the name, the state and the seat guide survive.
        expect(find.text('T1'), findsOneWidget, reason: 'name lost at ${width}px / ${scale}x');
        // "Running" since 2.0.2 (client items 1 and 2), drawn as a FloorChip.
        expect(find.text('Running'), findsNWidgets(2), reason: 'status lost at ${width}px / ${scale}x');
        expect(find.text('12 seats · max 20'), findsNWidgets(2),
            reason: 'seat chip lost at ${width}px / ${scale}x');
        // Legible, not micro-typed away: the seat label is drawn at the scaled
        // size a 11pt chip should be, never shrunk to fit the box.
        expect(_lineHeight(tester, find.text('12 seats · max 20').first),
            greaterThanOrEqualTo(11 * scale),
            reason: 'the seat chip was shrunk below its own type size at ${width}px / ${scale}x');
      }
    }
  });

  testWidgets('Valet: the vehicle tile takes a 1.3x scale at every width', (tester) async {
    for (final scale in _scales) {
      for (final width in _widths) {
        _size(tester, width, 1200, scale);
        await _mount(tester, (r) => m.valetModule(r, r.auth.profile!), _valetRoutes());

        expect(tester.takeException(), isNull,
            reason: 'the vehicle tile overflowed at ${width}px / ${scale}x');
        expect(find.text('MH12AB1001'), findsOneWidget, reason: 'plate lost at ${width}px / ${scale}x');
        expect(find.text('Mark parked'), findsOneWidget,
            reason: 'stage action lost at ${width}px / ${scale}x');
      }
    }
  });

  // The order card puts the waiter's name in an InfoChip — free text with no
  // length limit on the way in, exactly like the valet's fields.
  testWidgets('Orders: the order card takes a 1.3x scale at every width', (tester) async {
    for (final scale in _scales) {
      for (final width in _widths) {
        _size(tester, width, 1600, scale);
        await _mount(tester, (r) => m.ordersModule(r, r.auth.profile!), {
          '/orders': [
            {
              'id': 'o1',
              'table': 'T1',
              'customer': 'Dr Anantharamakrishnan Venkataraghavan Subramanian',
              'status': 'Preparing',
              'items': <dynamic>[],
              'total': 1200,
              'barked_at': '2026-07-26T10:00:00Z',
              'created_at': '2026-07-26T10:00:00Z',
              'taken_by_employee_name': 'Ramachandran Subramanian (evening)',
            },
          ],
          '/orders/scope': {
            'outlet': {'id': 'a', 'name': 'Solo'},
            'is_all_outlets': false,
            'live_orders': 1,
            'other_outlet_orders': 0,
            'outlets': [
              {'outlet_id': 'a', 'outlet_name': 'Solo', 'live_orders': 1, 'tables': 4, 'is_current': true},
            ],
            'live_window_days': 3,
            'current_outlet_has_tables': true,
          },
        });

        expect(tester.takeException(), isNull,
            reason: 'the order card overflowed at ${width}px / ${scale}x');
        expect(find.text('Table T1'), findsWidgets, reason: 'table lost at ${width}px / ${scale}x');
      }
    }
  });

  // The waitlist card's action row held four natural-width buttons in a plain
  // Row: a Row hands every non-flex child maxWidth infinity, so no chip fix
  // could reach it and a portrait phone overflowed by 113px at 1.0x — no
  // accessibility setting involved.
  //
  // Now swept at 1.3x too. It used to fail there for a SECOND reason: the
  // header's waited-stat and status chip grow with the text scale while the
  // 40px position box does not, crushing the Expanded to 35.8px against an
  // InfoChip's 37px of irreducible icon+padding+border. That trailing pair is a
  // Wrap now, so it drops to its own run instead of starving the name.
  //
  // The four buttons live in the row's "..." menu since the table redesign, so
  // the sweep opens it. The guarantee is unchanged and now covers both states:
  // no overflow with the menu shut, no overflow with it open, and all four
  // actions still there and still on screen.
  testWidgets('Waitlist: the card fits a portrait phone at 1.0x and 1.3x', (tester) async {
    for (final width in _widths) {
      for (final scale in const [1.0, 1.3]) {
      _size(tester, width, 1200, scale);
      await _mount(tester, (r) => m.waitlistModule(r, r.auth.profile!), {
        '/waitlist': {
          'entries': [
            {
              'id': 'w1',
              'name': 'Ramachandran',
              'party_size': 4,
              'position': 1,
              'status': 'waiting',
              'phone': '9876543210',
              'minutes_waiting': 12,
              'pre_order': <dynamic>[],
              'party_members': <dynamic>[],
            },
          ],
        },
        '/get-tables': [
          {'table_name': 'T1', 'occupied': false, 'reserved': false},
        ],
        '/waitlist/pending-preorders': {'entries': <dynamic>[]},
      });

      expect(tester.takeException(), isNull,
          reason: 'the waitlist card overflowed at ${width}px / ${scale}x');
      // The party is readable without opening anything: the phone is mandatory
      // at join, so it must never be the field the layout drops.
      expect(find.text('Ramachandran'), findsOneWidget,
          reason: 'the name was lost at ${width}px / ${scale}x');
      expect(find.text('9876543210'), findsWidgets,
          reason: 'the phone was lost at ${width}px / ${scale}x');

      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'the actions menu overflowed at ${width}px / ${scale}x');
      // Every action survives — degrading must not drop the destructive pair.
      for (final label in ['Call', 'Seat', 'No-show', 'Remove']) {
        expect(find.text(label), findsOneWidget, reason: '$label lost at ${width}px / ${scale}x');
      }
      // The last item's right edge stays on screen. This is what a Row could
      // not promise: the overflowing children were laid out past the card.
      expect(tester.getBottomRight(find.text('Remove')).dx, lessThanOrEqualTo(width),
          reason: 'the actions menu ran off the ${width}px screen at ${scale}x');
      // A destructive item is never what the menu opens under: the harmless
      // work is above the divider, the two ways out of the queue below it.
      expect(tester.getTopLeft(find.text('Call')).dy,
          lessThan(tester.getTopLeft(find.text('Remove')).dy),
          reason: 'Remove climbed above Call at ${width}px / ${scale}x');
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('Menu: the section tag takes a 1.3x scale at every width', (tester) async {
    for (final scale in _scales) {
      for (final width in _widths) {
        _size(tester, width, 1200, scale);
        await _mount(tester, (r) => m.menuModule(r, r.auth.profile!), {
          '/menu': [
            {
              'id': 'menu-1',
              'name': 'Paneer Butter Masala with extra gravy',
              'price': 340,
              'category': 'Mains',
              'available': true,
              // A leftover label from a deleted section — the widest tag there is.
              'station': 'Tandoori grill and live counter',
            },
          ],
        });

        expect(tester.takeException(), isNull,
            reason: 'the menu tile overflowed at ${width}px / ${scale}x');
        expect(find.text('Available'), findsOneWidget, reason: 'status lost at ${width}px / ${scale}x');
      }
    }
  });
}
