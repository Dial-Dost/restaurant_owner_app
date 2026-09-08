// A PREVIEW RENDERER for the two motion-led signature styles, not a test.
//
// Deliberately NOT named *_test.dart, for the same reason as `gaia_preview.dart`:
// it renders pictures and asserts nothing, so `flutter test` must never collect
// it. Run it by path:
//
//     flutter test test/gaia_signature_preview.dart
//
// It writes PNGs to build/gaia_preview/.
//
// It mounts the REAL modules against a fake API — the same `bookingsModule`,
// `waitlistModule`, `customersModule` and `feedbackModule` the app runs — under
// each design system in turn. So these are photographs of the shipping widgets,
// not of a mock-up of them.
//
// The fonts are loaded by hand because `flutter test` paints every glyph in
// Ahem (solid boxes) unless the real files are registered. Under Rustic Fork
// there is nothing to load: that system bundles no font, so its reference shots
// come out in Ahem boxes. That is expected, and it is why the Rustic pictures
// are here for LAYOUT comparison only.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      loader.addFont(
        File(p).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
    }
    await loader.load();
  }

  await load('Cormorant Garamond', [
    'assets/fonts/CormorantGaramond-Regular.ttf',
    'assets/fonts/CormorantGaramond-Italic.ttf',
  ]);
  await load('Instrument Sans', [
    'assets/fonts/InstrumentSans-Regular.ttf',
    'assets/fonts/InstrumentSans-Italic.ttf',
  ]);

  // The icon font, from the SDK's own cache. Without it every Icon in the
  // picture is an Ahem box, which is exactly the kind of "is that a bug or the
  // harness?" that makes a screenshot useless for judging a design. Best
  // effort: a differently-laid-out SDK just means boxes again, not a failure.
  final sdk = Platform.environment['FLUTTER_ROOT'];
  if (sdk != null) {
    for (final candidate in [
      '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await load('MaterialIcons', [candidate]);
        break;
      }
    }
  }
}

/// Rasterise the boundary and write it out.
///
/// MUST be called inside `tester.runAsync`. `RenderRepaintBoundary.toImage`
/// hands work to the raster thread and completes on the REAL event loop, which
/// the fake-async zone a widget test runs in cannot advance. Called directly it
/// still produces the PNG — the file lands, the `print` fires — and then the
/// test body never returns, so every picture costs the full ten-minute test
/// timeout and is reported as a failure. Ten minutes per screenshot, for output
/// that is already on disk. Measured, not guessed: the same shot inside
/// `runAsync` finishes in under a second.
Future<void> _shoot(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('build/gaia_preview')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote build/gaia_preview/$name.png');
}

// ── fixtures ─────────────────────────────────────────────────────────

Map<String, dynamic> _booking(String id, String name, int party, String table,
        String status, String at,
        {String notes = '', String source = ''}) =>
    {
      'booking_id': id,
      'customer_name': name,
      'number_of_people': party,
      'table_name': table,
      'table_names': [table],
      'status': status,
      'booking_date_time': at,
      'duration_mins': 120,
      'notes': notes,
      'source': source,
      'customer_phone': '7777777777',
    };

final Map<String, dynamic> _bookingRoutes = {
  '/get-bookings': [
    _booking('b1', 'Rohan', 2, 'T11', 'Confirmed', '2026-09-30T13:30:00.000Z',
        source: 'online', notes: 'Booked online, reminder due 29 Sep'),
    _booking('b2', 'Becky', 6, 'CT1', 'Requested', '2026-10-02T15:30:00.000Z',
        notes: 'Tasting menu'),
    _booking('b3', 'Priya S.', 4, 'T21', 'Confirmed', '2026-09-05T15:00:00.000Z',
        notes: 'Birthday, window seat'),
    _booking('b4', 'Aakash', 2, 'T14', 'Confirmed', '2026-09-05T13:30:00.000Z'),
    _booking('b5', 'Cody', 3, '', 'Requested', '2026-10-03T14:30:00.000Z'),
  ],
};

final Map<String, dynamic> _waitlistRoutes = {
  '/waitlist': {
    'entries': [
      {
        'id': 'w1',
        'name': 'Vicky',
        'party_size': 4,
        'phone': '8884999810',
        'position': 1,
        'status': 'waiting',
        'minutes_waiting': 18,
        'pre_order': [
          {'name': 'Hara dhaniya pulao', 'qty': 1},
          {'name': 'Subz tehri', 'qty': 1},
          {'name': 'Tandoori roti', 'qty': 1},
        ],
      },
      {
        'id': 'w2',
        'name': 'Reacher',
        'party_size': 1,
        'phone': '9635287452',
        'position': 2,
        'status': 'called',
        'minutes_waiting': 34,
      },
      {
        'id': 'w3',
        'name': 'Dipish',
        'party_size': 2,
        'phone': '9000000000',
        'position': 3,
        'status': 'waiting',
        'minutes_waiting': 6,
      },
    ],
  },
  '/get-tables': [
    {'table_name': 'T1', 'is_occupied': false},
    {'table_name': 'T2', 'is_occupied': false},
  ],
  '/waitlist/pending-preorders': {'entries': []},
};

Map<String, dynamic> _guest(String id, String name, num spend, int visits,
        String? last, int? since) =>
    {
      'customer_id': id,
      'name': name,
      'total_spend': spend,
      'visits': visits,
      // `?value` drops the whole entry when the value is null — which is how a
      // guest who has never visited reaches the module.
      'last_visit': ?last,
      'days_since_last_visit': ?since,
      'segment': visits == 0 ? 'new' : 'regular',
      'phone': '86868686$id',
    };

final List<Map<String, dynamic>> _guests = [
  _guest('01', 'Amogh', 19091.65, 1, '2026-08-25T14:00:00.000Z', 12),
  _guest('02', 'Aakash', 0, 0, null, null),
  _guest('03', 'Advay', 0, 0, null, null),
  _guest('04', 'Becky', 4820.00, 3, '2026-05-02T14:00:00.000Z', 127),
  _guest('05', 'Cody', 1260.50, 2, '2026-08-30T14:00:00.000Z', 7),
  _guest('06', 'Priya S.', 8400.00, 6, '2026-08-19T14:00:00.000Z', 18),
];

/// The guest book asks this route TWICE with different shapes: the page read
/// (`meta=1`) wants the envelope, and each of the three leaderboards wants a
/// bare ranked list of five. One callable route answers both, which is what
/// makes the leaderboard constellations appear in the picture instead of the
/// (perfectly real, but not what we are looking at) "nothing to rank" state.
final Map<String, dynamic> _customerRoutes = {
  '/customers/segments': (String path) {
    List<Map<String, dynamic>> ranked() {
      final rows = [..._guests];
      if (path.contains('sort=spend')) {
        rows.sort((a, b) => (b['total_spend'] as num).compareTo(a['total_spend'] as num));
      } else if (path.contains('sort=visits')) {
        rows.sort((a, b) => (b['visits'] as int).compareTo(a['visits'] as int));
      }
      return rows;
    }

    // `meta=1` is the page read; everything else on this route is a
    // leaderboard. (Not `limit=5` — the page read asks for limit=50, and
    // `contains` says yes to that too.)
    if (!path.contains('meta=1')) return ranked().take(5).toList();
    return {
      'customers': _guests,
      'total': 16,
      'has_more': false,
      'segment': 'all',
      'segment_counts': {'new': 16, 'regular': 0, 'high-spend': 0, 'dormant': 0},
      'spend_basis': 'settled bills, pre-tax',
    };
  },
};

final Map<String, dynamic> _feedbackRoutes = {
  '/feedback/summary': {'totalResponses': 12, 'averageRating': 4.55},
  '/feedback/recovery': {
    'tickets': [
      {
        'id': 't1',
        'customer_name': 'Anonymous',
        'overall_rating': 2,
        'submitted_at': '2026-08-24T16:44:00.000Z',
        'comments': 'Starters took forty minutes on a quiet Tuesday.',
        'category_ratings': [
          {'label': 'Service', 'rating': 2, 'key': 'service'},
        ],
      },
    ],
  },
  '/feedback': {
    'items': [
      {
        'id': 'f1',
        'customer_name': 'Dipish',
        'overall_rating': 4,
        'submitted_at': '2026-08-25T15:02:00.000Z',
        'category_ratings': [
          {'label': 'Food', 'rating': 4, 'key': 'food', 'question': 'How was the food?'},
          {'label': 'Service', 'rating': 4, 'key': 'service'},
        ],
      },
      {
        'id': 'f2',
        'customer_name': 'Vicky',
        'overall_rating': 5,
        'submitted_at': '2026-08-25T14:40:00.000Z',
        'category_ratings': [
          {'label': 'Food', 'rating': 5, 'key': 'food'},
        ],
      },
      {
        'id': 'f3',
        'customer_name': 'Reacher',
        'overall_rating': 5,
        'submitted_at': '2026-06-25T14:18:00.000Z',
        'category_ratings': [
          {'label': 'Food', 'rating': 5, 'key': 'food'},
        ],
      },
      {
        'id': 'f4',
        'customer_name': '',
        'overall_rating': 4,
        'submitted_at': '2026-08-24T16:44:00.000Z',
        'source': 'table QR',
        'category_ratings': [
          {'label': 'Food', 'rating': 4, 'key': 'food'},
        ],
      },
    ],
  },
  '/restaurant/users': {'users': []},
};

// ── harness ──────────────────────────────────────────────────────────

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
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
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (routes.containsKey(path)) return _resolve(routes[path], path);
    // Longest matching prefix, so one entry answers a whole query-carrying
    // family — and a CALLABLE entry can vary its reply by query string, which
    // is how the guest book's three leaderboard reads (limit=5) get a list
    // while the page read gets the paged envelope.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return _resolve(routes[prefixes.first], path);
    throw ApiException('No fake route for $path', 404);
  }

  dynamic _resolve(dynamic route, String path) =>
      route is dynamic Function(String) ? route(path) : route;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> shot(
    WidgetTester tester, {
    required String name,
    required Widget Function(RestClient, Profile) module,
    required Map<String, dynamic> routes,
    required bool gaia,
    Size size = const Size(430, 1180),
  }) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = Size(size.width * 2, size.height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    AppearanceController.instance.debugReset();
    if (gaia) {
      // unawaited on purpose: setDesignSystem flips the in-memory state and
      // notifies BEFORE it awaits persistence, so the design is already live
      // here. Awaiting its SharedPreferences write after tester.runAsync()
      // stalls in flutter_test's fake-async zone — a harness wrinkle, covered
      // properly by gaia_design_system_test.dart.
      // ignore: unawaited_futures
      AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
    }

    await tester.pumpWidget(const SizedBox());
    final api = _FakeApi(routes);
    final auth = AuthController(api: api);
    await auth.login('Gaia Test', 'admin', 'admin123');
    final rest = RestClient(auth);

    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: GaiaScope(
        system: AppearanceController.instance.designSystem,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: gaia ? GaiaTheme.dark() : AppTheme.dark(),
            home: ModuleNavigator(
              openModule: (label, {Map<String, dynamic>? target}) {},
              visibleLabels: const [
                'Overview', 'Bookings', 'Waitlist', 'Customers', 'Feedback',
              ],
              clearFocus: () {},
              child: Scaffold(
                backgroundColor: AppColors.bg,
                body: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: module(rest, rest.auth.profile!),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => _shoot(tester, name));
    AppearanceController.instance.debugReset();
  }

  // ── COVERFLOW ──────────────────────────────────────────────────────

  testWidgets('Bookings under Gaia (coverflow)', (tester) async {
    await shot(tester,
        name: '20-bookings-gaia',
        module: m.bookingsModule,
        routes: _bookingRoutes,
        gaia: true);
  });

  testWidgets('Bookings under Rustic Fork', (tester) async {
    await shot(tester,
        name: '21-bookings-rustic',
        module: m.bookingsModule,
        routes: _bookingRoutes,
        gaia: false);
  });

  testWidgets('Bookings under Gaia, desktop width', (tester) async {
    await shot(tester,
        name: '22-bookings-gaia-desktop',
        module: m.bookingsModule,
        routes: _bookingRoutes,
        gaia: true,
        size: const Size(1120, 900));
  });

  testWidgets('Waitlist under Gaia (coverflow)', (tester) async {
    await shot(tester,
        name: '23-waitlist-gaia',
        module: m.waitlistModule,
        routes: _waitlistRoutes,
        gaia: true);
  });

  testWidgets('Waitlist under Rustic Fork', (tester) async {
    await shot(tester,
        name: '24-waitlist-rustic',
        module: m.waitlistModule,
        routes: _waitlistRoutes,
        gaia: false);
  });

  // ── BOKEH ──────────────────────────────────────────────────────────

  testWidgets('Customers under Gaia (bokeh)', (tester) async {
    await shot(tester,
        name: '25-customers-gaia',
        module: m.customersModule,
        routes: _customerRoutes,
        gaia: true,
        size: const Size(430, 1500));
  });

  testWidgets('Customers under Rustic Fork', (tester) async {
    await shot(tester,
        name: '26-customers-rustic',
        module: m.customersModule,
        routes: _customerRoutes,
        gaia: false,
        size: const Size(430, 1500));
  });

  testWidgets('Feedback under Gaia (bokeh)', (tester) async {
    await shot(tester,
        name: '27-feedback-gaia',
        module: m.feedbackModule,
        routes: _feedbackRoutes,
        gaia: true,
        size: const Size(430, 1400));
  });

  testWidgets('Feedback under Rustic Fork', (tester) async {
    await shot(tester,
        name: '28-feedback-rustic',
        module: m.feedbackModule,
        routes: _feedbackRoutes,
        gaia: false,
        size: const Size(430, 1400));
  });
}
