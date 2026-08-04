import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The Waitlist board after the two-column redesign.
///
/// Two things are being defended here. The first is that nothing was traded for
/// the layout: every action the old card exposed as a button now lives in the
/// row's "..." menu, and each one still reaches the same endpoint. The second is
/// that the board survives hostile data at every width and text scale — this
/// screen has shipped an overflow twice, and the table is a new way to earn a
/// third.
class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.seatResponse});

  final Map<String, dynamic> routes;

  /// What POST /waitlist/:id/seat hands back — the held pre-order lives here.
  final Map<String, dynamic>? seatResponse;

  final List<String> calls = <String>[];
  final List<Object?> bodies = <Object?>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    bodies.add(body);
    if (method != 'GET') {
      if (path.endsWith('/seat') && seatResponse != null) return seatResponse;
      return <String, dynamic>{'success': true};
    }
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

Widget _host(Widget child, {List<String> visible = const ['Waitlist', 'Bookings'], List<String>? opened}) =>
    MaterialApp(
      theme: AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (label, {Map<String, dynamic>? target}) => opened?.add(label),
        visibleLabels: visible,
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

Map<String, dynamic> _entry({
  required String id,
  required String name,
  int position = 1,
  int partySize = 2,
  String status = 'waiting',
  String phone = '9876543210',
  int minutes = 12,
  List<Map<String, dynamic>> pre = const [],
  List<Map<String, dynamic>> members = const [],
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'position': position,
      'party_size': partySize,
      'status': status,
      'phone': phone,
      'minutes_waiting': minutes,
      'pre_order': pre,
      'party_members': members,
    };

Map<String, dynamic> _routes(List<Map<String, dynamic>> entries, {List<Map<String, dynamic>> pending = const []}) =>
    <String, dynamic>{
      '/waitlist': {'entries': entries},
      '/get-tables': [
        {'table_name': 'T1', 'occupied': false, 'reserved': false},
        {'table_name': 'T2', 'occupied': false, 'reserved': false},
        {'table_name': 'T3', 'occupied': true, 'reserved': false},
      ],
      '/waitlist/pending-preorders': {'entries': pending},
    };

Future<_FakeApi> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> entries, {
  List<Map<String, dynamic>> pending = const [],
  Map<String, dynamic>? seatResponse,
  List<String>? opened,
  List<String> visible = const ['Waitlist', 'Bookings'],
}) async {
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(_routes(entries, pending: pending), seatResponse: seatResponse);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(m.waitlistModule(rest, rest.auth.profile!), visible: visible, opened: opened));
  await tester.pumpAndSettle();
  return api;
}

/// Opens the "..." menu on the first queue row.
Future<void> _openRowMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz).first);
  await tester.pumpAndSettle();
}

/// A forty-party board is taller than any of the swept windows — and past the
/// list's cache extent nothing is even built — so scroll to it, then tap.
Future<void> _tapScrolled(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 400, maxScrolls: 400);
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

/// POST bodies are plain maps, and Map has no value equality — compare content.
bool _posted(_FakeApi api, String key, Object? value) =>
    api.bodies.whereType<Map>().any((b) => b[key] == value);

const List<double> _widths = [390, 1100, 1200, 1700];
const List<double> _scales = [1.0, 1.3];

void main() {
  // ---- the layout itself ---------------------------------------------------

  testWidgets('the board survives 40 hostile parties at every width and scale', (tester) async {
    // 60-char names, a phone string nobody could fit in a column, and a queue
    // long enough to exercise both the preview cap and the expanded list.
    final entries = [
      for (var i = 1; i <= 40; i++)
        _entry(
          id: 'w$i',
          name: 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer $i',
          position: i,
          partySize: i % 9 + 1,
          minutes: i * 3,
          phone: '+91 98765 43210 ext. 4471 (ask for the front desk)',
          status: i % 5 == 0 ? 'called' : 'waiting',
          pre: i % 3 == 0
              ? [
                  {'name': 'Paneer Butter Masala with extra gravy', 'quantity': 2, 'price': 340},
                ]
              : const [],
          members: i % 4 == 0
              ? [
                  {'name': 'Venkataraghavan Subramanian', 'phone': '9876543210'},
                ]
              : const [],
        ),
    ];

    // A seated party still owing a yes/no rides above the queue at every width.
    const pending = [
      {
        'id': 'w99',
        'name': 'Anantharamakrishnan Venkataraghavan Subramanian Iyer',
        'table_name': 'Terrace table by the far window',
        'minutes_since_seated': 9,
        'phone': '+91 98765 43210 ext. 4471',
        'pre_order': [
          {'name': 'Paneer Butter Masala with extra gravy', 'quantity': 3, 'price': 340},
        ],
      },
    ];

    for (final width in _widths) {
      for (final scale in _scales) {
        _size(tester, width, 1400, scale);
        await _pump(tester, entries, pending: pending);
        expect(tester.takeException(), isNull, reason: 'the board overflowed at ${width}px / ${scale}x');

        // ...and on the walk-ins tab.
        await _tapScrolled(tester, find.text('Walk-ins'));
        expect(tester.takeException(), isNull,
            reason: 'the walk-ins tab overflowed at ${width}px / ${scale}x');

        // ...and with the whole forty-party queue on the page.
        await _tapScrolled(tester, find.textContaining('Queue ('));
        await _tapScrolled(tester, find.textContaining('View all waitlist'));
        expect(tester.takeException(), isNull,
            reason: 'the expanded queue overflowed at ${width}px / ${scale}x');
      }
    }
  });

  // The desktop table is the form factor most hosts use, and it used to render
  // the SAME groups icon on every row — so a party holding a pre-order looked
  // exactly like one that did not, and the only way to tell was to open the
  // overflow menu on each of up to 40 rows. The phone layout always showed it.
  testWidgets('the desktop row distinguishes a pre-ordered party from a plain one',
      (tester) async {
    final entries = [
      _entry(id: 'w1', name: 'HasPreOrder', position: 1, phone: '9876543210', pre: [
        {'name': 'Paneer Tikka', 'qty': 1},
        {'name': 'Cold Coffee', 'qty': 2},
      ], members: [
        {'name': 'Guest A'},
        {'name': 'Guest B'},
      ]),
      _entry(id: 'w2', name: 'PlainParty', position: 2, phone: '9876543211'),
    ];

    _size(tester, 1700, 1200, 1.0);
    await _pump(tester, entries);

    // Table mode, not the phone record fallback.
    expect(find.text('Position'), findsOneWidget);
    final withPre = tester.widgetList(find.byIcon(Icons.restaurant_menu)).length;
    final plainBadges = tester.widgetList(find.byIcon(Icons.groups_outlined)).length;
    expect(tester.takeException(), isNull);

    // Baseline: the SAME board with no pre-order anywhere. The page carries a
    // menu icon of its own in its chrome, so the assertion is the delta between
    // these two renders, not an absolute count.
    await _pump(tester, [
      _entry(id: 'w1', name: 'HasPreOrder', position: 1, phone: '9876543210'),
      _entry(id: 'w2', name: 'PlainParty', position: 2, phone: '9876543211'),
    ]);
    final withoutPre = tester.widgetList(find.byIcon(Icons.restaurant_menu)).length;
    final plainBadgesAfter = tester.widgetList(find.byIcon(Icons.groups_outlined)).length;

    expect(withPre, withoutPre + 1,
        reason: 'a pre-ordered party is indistinguishable from a plain one on a desktop row');
    expect(plainBadges, plainBadgesAfter - 1,
        reason: 'the pre-ordered row should stop showing the neutral groups badge');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone drops the grid for a record; a desktop keeps the columns', (tester) async {
    final entries = [_entry(id: 'w1', name: 'Ramachandran', partySize: 4)];

    _size(tester, 390, 900, 1.0);
    await _pump(tester, entries);
    // 390px across eight columns is ~35px each — narrower than the phone number
    // that has to be in one of them. No header, and the fields become chips.
    expect(find.text('Position'), findsNothing);
    expect(find.text('Ramachandran'), findsOneWidget);
    expect(find.text('9876543210'), findsWidgets);
    expect(find.text('Party of 4'), findsOneWidget);

    _size(tester, 1700, 1200, 1.0);
    await _pump(tester, entries);
    for (final col in ['Position', 'Party', 'Name', 'Phone', 'People', 'Wait Time', 'Status', 'Actions']) {
      expect(find.text(col), findsOneWidget, reason: '$col header missing on a desktop window');
    }
    expect(find.text('9876543210'), findsWidgets);
  });

  testWidgets('an empty queue reads calm, not broken', (tester) async {
    _size(tester, 1200, 1000, 1.0);
    await _pump(tester, const []);

    expect(find.text('Queue is empty'), findsOneWidget);
    expect(find.textContaining('appear here in arrival order'), findsOneWidget);
    // Nothing that reads as a fault.
    expect(find.textContaining('Could not load'), findsNothing);
    expect(find.textContaining('error'), findsNothing);
    // The way IN is still on the page — an empty queue is when the door QR
    // matters most.
    expect(find.text('Scan to join waitlist'), findsOneWidget);
    expect(find.textContaining('/queue/csrorganics'), findsWidgets);
    // Real zeros, not blanks.
    expect(find.text('Total in queue'), findsOneWidget);
    expect(find.textContaining('Nobody has been called yet'), findsOneWidget);
  });

  // ---- every old action still reaches its endpoint --------------------------

  testWidgets('Call, No-show and Remove all still post, from the "..." menu', (tester) async {
    _size(tester, 1400, 1000, 1.0);
    final api = await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran')]);

    await _openRowMenu(tester);
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /waitlist/w1/call'));

    await _openRowMenu(tester);
    await tester.tap(find.text('No-show'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /waitlist/w1/cancel'));
    expect(_posted(api, 'status', 'no_show'), isTrue);

    await _openRowMenu(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    // Remove asks first — it takes a guest's place with no undo.
    expect(find.textContaining('lose their place'), findsOneWidget);
    await tester.tap(find.text('Keep them'));
    await tester.pumpAndSettle();
    expect(_posted(api, 'status', 'cancelled'), isFalse);

    await _openRowMenu(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(_posted(api, 'status', 'cancelled'), isTrue);
  });

  testWidgets('the destructive pair is last in the menu, never the item on top', (tester) async {
    _size(tester, 1400, 1000, 1.0);
    await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran')]);
    await _openRowMenu(tester);

    final call = tester.getTopLeft(find.text('Call')).dy;
    final seat = tester.getTopLeft(find.text('Seat')).dy;
    final noShow = tester.getTopLeft(find.text('No-show')).dy;
    final remove = tester.getTopLeft(find.text('Remove')).dy;
    expect(call, lessThan(seat));
    expect(seat, lessThan(noShow));
    expect(noShow, lessThan(remove));
    // A divider separates them, so the two are not one careless flick apart.
    expect(find.byType(PopupMenuDivider), findsOneWidget);
  });

  testWidgets('a called party loses Call but keeps Seat', (tester) async {
    _size(tester, 1400, 1000, 1.0);
    await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran', status: 'called')]);

    expect(find.text('Notified'), findsWidgets);
    await _openRowMenu(tester);
    expect(find.text('Call'), findsNothing);
    expect(find.text('Seat'), findsOneWidget);
  });

  testWidgets('Seat picks a free table and then asks about the held pre-order', (tester) async {
    _size(tester, 1400, 1200, 1.0);
    final api = await _pump(
      tester,
      [_entry(id: 'w1', name: 'Ramachandran', partySize: 4)],
      seatResponse: <String, dynamic>{
        'pending_preorder': {
          'items': [
            {'name': 'Paneer Butter Masala', 'quantity': 2, 'price': 340},
          ],
          'subtotal': 680,
        },
      },
    );

    await _openRowMenu(tester);
    await tester.tap(find.text('Seat'));
    await tester.pumpAndSettle();
    // Only the tables that are actually free are offered.
    expect(find.textContaining('Seat Ramachandran (party of 4)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Seat'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /waitlist/w1/seat'));
    expect(_posted(api, 'table_name', 'T1'), isTrue);

    // Seating no longer places the pre-order, so the ask has to arrive here.
    expect(find.textContaining('pre-order?'), findsOneWidget);
    await tester.tap(find.text('Confirm & send'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /waitlist/w1/preorder/confirm'));
  });

  testWidgets('Party details still shows the pre-order lines and the party members', (tester) async {
    _size(tester, 1400, 1200, 1.0);
    await _pump(tester, [
      _entry(
        id: 'w1',
        name: 'Ramachandran',
        pre: [
          {'name': 'Paneer Butter Masala', 'quantity': 2, 'price': 340, 'note': 'no chilli'},
        ],
        members: [
          {'name': 'Venkataraghavan', 'phone': '9000000001'},
        ],
      ),
    ]);

    await _openRowMenu(tester);
    await tester.tap(find.text('Party details'));
    await tester.pumpAndSettle();

    expect(find.text('PRE-ORDER'), findsOneWidget);
    expect(find.text('Paneer Butter Masala ×2'), findsOneWidget);
    expect(find.text('no chilli'), findsOneWidget);
    expect(find.text('PARTY MEMBERS'), findsOneWidget);
    expect(find.text('Venkataraghavan'), findsOneWidget);
    expect(find.text('9000000001'), findsOneWidget);
  });

  testWidgets('the pending pre-order queue survives the redesign', (tester) async {
    _size(tester, 1400, 1200, 1.0);
    final api = await _pump(
      tester,
      const [],
      pending: [
        {
          'id': 'w9',
          'name': 'Seated party',
          'table_name': 'T4',
          'minutes_since_seated': 5,
          'pre_order': [
            {'name': 'Paneer Butter Masala', 'quantity': 2, 'price': 340},
          ],
        },
      ],
    );

    // Visible even with nobody left in the queue — an un-answered pre-order
    // outlives the queue entry it came from. (Twice: the section heading, and
    // the rail's count of the same thing.)
    expect(find.text('Pre-orders to confirm'), findsNWidgets(2));
    await tester.tap(find.text('Review pre-order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Let them change it'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /waitlist/w9/preorder/decline'));
  });

  // ---- the new furniture ----------------------------------------------------

  testWidgets('the stat strip and the summary count what is actually there', (tester) async {
    _size(tester, 1700, 1200, 1.0);
    await _pump(tester, [
      _entry(id: 'w1', name: 'A', partySize: 2, minutes: 5),
      _entry(id: 'w2', name: 'B', partySize: 4, minutes: 25, status: 'called'),
      _entry(id: 'w3', name: 'C', partySize: 6, minutes: 10),
    ]);

    // 3 groups, 12 guests, waits spanning 5–25 min, two free tables of three.
    expect(find.text('Current queue'.toUpperCase()), findsOneWidget);
    expect(find.textContaining('5–25'), findsOneWidget);
    expect(find.text('Tables ready to seat now'.toUpperCase()), findsOneWidget);
    expect(find.text('Average party size'.toUpperCase()), findsOneWidget);

    expect(find.text('Guests waiting'), findsOneWidget);
    expect(find.textContaining('12 people'), findsOneWidget);
    expect(find.text('Notified'), findsWidgets);
  });

  testWidgets('the rail lists the called parties and jumps to their tab', (tester) async {
    _size(tester, 1700, 1200, 1.0);
    await _pump(tester, [
      _entry(id: 'w1', name: 'Still waiting', minutes: 4),
      _entry(id: 'w2', name: 'Called party', status: 'called', minutes: 30),
    ]);

    expect(find.text('Walk-ins to be seated'), findsOneWidget);
    // Only the called party is in the rail; the state is stated in words, not
    // left to the dot beside it.
    expect(find.textContaining('Notified — waiting for a table'), findsWidgets);
    expect(find.text('Party of 2 · 30m ago'), findsOneWidget);

    await tester.tap(find.text('View all'));
    await tester.pumpAndSettle();
    expect(find.text('Called party'), findsWidgets);
    expect(find.text('Still waiting'), findsNothing);
  });

  testWidgets('the join link can be copied, and the guest preview shows the same QR', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    _size(tester, 1700, 1200, 1.0);
    await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran')]);

    await tester.tap(find.byTooltip('Copy the join link'));
    await tester.pumpAndSettle();
    expect(copied.single, contains('/queue/csrorganics'));

    await tester.tap(find.text('Preview guest experience'));
    await tester.pumpAndSettle();
    expect(find.text('Preview the guest experience'), findsOneWidget);
    expect(find.textContaining('/queue/csrorganics'), findsWidgets);
  });

  testWidgets('the Reservations tab points at Bookings instead of inventing rows', (tester) async {
    _size(tester, 1400, 1200, 1.0);
    final opened = <String>[];
    await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran')], opened: opened);

    await tester.tap(find.text('Reservations'));
    await tester.pumpAndSettle();
    expect(find.text('Reservations are booked ahead'), findsOneWidget);
    await tester.tap(find.text('Open Bookings'));
    await tester.pumpAndSettle();
    expect(opened, ['Bookings']);
  });

  testWidgets('the Bookings jump is hidden when that module is not this user\'s', (tester) async {
    _size(tester, 1400, 1200, 1.0);
    await _pump(tester, [_entry(id: 'w1', name: 'Ramachandran')], visible: const ['Waitlist']);

    await tester.tap(find.text('Reservations'));
    await tester.pumpAndSettle();
    expect(find.text('Reservations are booked ahead'), findsOneWidget);
    // An affordance that would no-op is not offered at all.
    expect(find.text('Open Bookings'), findsNothing);
  });
}
