// The Tables module after items 2, 3, 11, 21 and 22, on the REAL floor plan.
//
// WHAT IS PINNED HERE, and why each one is worth a test:
//
//   ITEM 2  — sections read in CREATION order by default. This REVERSES what
//     1.8.6 shipped (alphabetical), so the point is not only that the new order
//     appears but that a POSITION the owner chose still beats it, and that an
//     outlet whose birth instants cannot be read falls back to exactly the
//     alphabetical list it has always had.
//
//   ITEM 3  — the "long-press and drag" instruction is gone, and the drag it
//     described now REACHES a section below the fold. That last part is the
//     actual bug: the gesture always worked in a tall test window and never
//     worked on a real floor plan, because nothing scrolled while a card was
//     held and the destination was off screen.
//
//   ITEM 11 — Occupied means an order has been placed. A seated party with no
//     order is its own state. The seating itself is untouched (that is a money
//     question — see MoveTableParty), so this is asserted as a RENDERING, and
//     an older backend that sends no `has_order` must keep painting Occupied.
//
//   ITEMS 21/22 — Move table and Move an order issue ONE call each, to the
//     routes that do the whole thing in one transaction, and never a sequence
//     this screen composes itself. Neither may be queued offline.
//
// Both design systems, because the floor plan is not a Gaia signature screen
// and the same widgets have to produce the same states under either language.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;
  final List<({String method, String path, Object? body})> writes = [];

  /// What a write answers with, by path. Defaults to `{success: true}`.
  final Map<String, dynamic> writeReplies = {};

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult('test-token', _admin);

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return writeReplies[path] ?? <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Profile _profile({required List<String> actions, required List<String> names, String role = 'admin'}) =>
    Profile.fromJson(<String, dynamic>{
      'employeeId': 'e1',
      'restaurantName': 'CSR Organics',
      'role': role,
      'actions_set': actions,
      'action_names': names,
    });

final Profile _admin = _profile(actions: ['*'], names: const <String>[]);

/// The app's own scroll behaviour (lib/app.dart): mouse and stylus drag-scroll
/// every Scrollable. Included because the floor-plan drag has to survive it.
class _DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

Widget _host(Widget child, DesignSystem system) => GaiaScope(
      system: system,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        scrollBehavior: _DragScrollBehavior(),
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: AppColors.bg, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(
  WidgetTester tester,
  Map<String, dynamic> routes, {
  Profile? profile,
  DesignSystem system = DesignSystem.rustic,
  double width = 1200,
  double height = 4000,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, profile ?? _admin), system));
  await tester.pumpAndSettle();
  return api;
}

Map<String, dynamic> _table(
  String name, {
  String? section,
  int? position,
  String? sectionBorn,
  int capacity = 4,
  int? maxCapacity,
  bool occupied = false,
  bool? hasOrder,
  bool reserved = false,
  int covers = 2,
  num total = 0,
}) {
  final row = <String, dynamic>{
    'table_name': name,
    'capacity': capacity,
    'max_capacity': maxCapacity ?? capacity,
    'section': section,
    'section_position': position,
    'section_created_at': sectionBorn,
    'occupied': occupied,
    'seated': occupied,
    'reserved': reserved,
    'covers': covers,
    'table_total': total,
  };
  // Deliberately ABSENT when not given, so a test can reproduce an older
  // backend that has never heard of has_order.
  if (hasOrder != null) row['has_order'] = hasOrder;
  return row;
}

Map<String, dynamic> _routes(
  List<Map<String, dynamic>> tables, {
  List<Map<String, dynamic>>? roster,
  List<Map<String, dynamic>>? orders,
}) =>
    <String, dynamic>{
      '/get-tables': tables,
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/orders': orders ?? <Map<String, dynamic>>[],
      '/table-sections': {'sections': roster ?? <Map<String, dynamic>>[], 'unassigned': 0},
    };

List<String> _headerOrder(WidgetTester tester, List<String> labels) {
  final tops = <String, double>{};
  for (final label in labels) {
    final f = find.text(label.toUpperCase());
    if (f.evaluate().isEmpty) continue;
    tops[label] = tester.getTopLeft(f.first).dy;
  }
  return tops.keys.toList()..sort((a, b) => tops[a]!.compareTo(tops[b]!));
}

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

/// A StatusChip by its LABEL, not by its rendered text.
///
/// Gaia draws a status as an engraved outline and upper-cases it; Rustic draws
/// a tinted capsule and does not. Matching the widget keeps one assertion true
/// of the same call site in both design systems, which is the point being made.
Finder _statusChip(String label) => find.byWidgetPredicate(
      (w) => w is StatusChip && w.label == label,
      description: 'StatusChip "$label"',
    );

/// Open a table's bottom sheet by tapping its card.
Future<void> _openSheet(WidgetTester tester, String table) async {
  await tester.tap(find.text(table).first);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  // ---------------------------------------------------------------- ITEM 2 ---
  group('item 2 — sections in creation order', () {
    testWidgets('an outlet nobody has rearranged reads OLDEST FIRST, not A-to-Z', (tester) async {
      // Alphabetical would be Bar, Entrance, Terrace. The restaurant was built
      // Entrance, then Bar, then Terrace, and that is the order it is read in.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', sectionBorn: '2023-05-01T00:00:00Z'),
          _table('T2', section: 'Bar', sectionBorn: '2022-03-01T00:00:00Z'),
          _table('T3', section: 'Entrance', sectionBorn: '2021-01-01T00:00:00Z'),
        ]),
      );
      expect(_headerOrder(tester, ['Bar', 'Entrance', 'Terrace']), ['Entrance', 'Bar', 'Terrace']);
    });

    testWidgets('a CHOSEN position still wins outright over age', (tester) async {
      // The promise 1.8.6 made that this change must not break: an owner who has
      // dragged something keeps it exactly where they put it.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'New Deck', position: 1, sectionBorn: '2026-08-01T00:00:00Z'),
          _table('T2', section: 'Old Room', sectionBorn: '2019-01-01T00:00:00Z'),
        ]),
      );
      expect(_headerOrder(tester, ['New Deck', 'Old Room']), ['New Deck', 'Old Room']);
    });

    testWidgets('with no birth instants at all it is 1.8.5 alphabetical', (tester) async {
      // The degradation path: a backend that does not send section_created_at
      // (or a schema that cannot answer) must render the order this app has
      // always rendered, not an arbitrary one.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace'),
          _table('T2', section: 'Bar'),
          _table('T3', section: 'Garden'),
        ]),
      );
      expect(_headerOrder(tester, ['Bar', 'Garden', 'Terrace']), ['Bar', 'Garden', 'Terrace']);
    });

    testWidgets('an EMPTY zone is placed by the roster instant, and Unassigned is last', (tester) async {
      // An empty zone has no table to be dated by, so its instant has to come
      // off the roster or it would sink to the bottom of every floor plan.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', sectionBorn: '2024-01-01T00:00:00Z'),
          _table('T4'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': null, 'created_at': '2024-01-01T00:00:00Z'},
          {'section': 'Old Snug', 'tables': 0, 'seats': 0, 'sort_order': null, 'created_at': '2020-06-01T00:00:00Z'},
        ]),
      );
      expect(_headerOrder(tester, ['Old Snug', 'Terrace', 'Unassigned']),
          ['Old Snug', 'Terrace', 'Unassigned']);
    });

    testWidgets('the SAME data reads in the SAME order under Gaia', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', sectionBorn: '2023-05-01T00:00:00Z'),
          _table('T3', section: 'Entrance', sectionBorn: '2021-01-01T00:00:00Z'),
        ]),
        system: DesignSystem.gaia,
      );
      expect(_headerOrder(tester, ['Entrance', 'Terrace']), ['Entrance', 'Terrace']);
    });
  });

  // ---------------------------------------------------------------- ITEM 3 ---
  group('item 3 — the instruction is gone and the drag reaches', () {
    testWidgets('no screen tells anyone to long-press and drag', (tester) async {
      await _mount(tester, _routes([_table('T1', section: 'Bar'), _table('T2', section: 'Garden')]));
      expect(find.textContaining('ong-press'), findsNothing);
      expect(find.textContaining('drag it onto another section'), findsNothing);
      expect(find.textContaining('drag a table in'), findsNothing);
      // What is left describes the screen instead of instructing a gesture.
      expect(find.text('Tables are grouped by their floor section.'), findsOneWidget);
    });

    testWidgets('an empty zone says what it is, without a gesture to perform', (tester) async {
      await _mount(
        tester,
        _routes([_table('T1', section: 'Bar')], roster: [
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Snug', 'tables': 0, 'seats': 0, 'sort_order': null},
        ]),
      );
      expect(find.text('Nothing here yet.'), findsOneWidget);
    });

    testWidgets('THE BUG: a card held at the edge scrolls the floor plan to a zone below the fold',
        (tester) async {
      // Seven zones at ~240px each is ~1680px of floor plan in an 800px window,
      // which is an ordinary restaurant. Before the fix, holding a card at the
      // bottom edge did nothing at all: the Draggable had won the gesture arena,
      // the Scrollable was receiving nothing, and the destination could not be
      // brought on screen. That is what "the drag does nothing" was.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Bar'),
          _table('T3', section: 'Courtyard'),
          _table('T4', section: 'Deck'),
          _table('T5', section: 'Entrance'),
          _table('T6', section: 'Garden'),
          _table('T7', section: 'Terrace'),
        ]),
        height: 800,
      );
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(scroll.pixels, 0);
      expect(scroll.maxScrollExtent, greaterThan(0), reason: 'the floor plan must be taller than the window');

      final from = tester.getCenter(find.text('T1'));
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 700)); // clear the long-press delay
      await gesture.moveTo(Offset(from.dx, 780)); // into the bottom edge band
      await tester.pump();
      // Hold there. Each pump advances the auto-scroll ticker.
      for (var i = 0; i < 40; i++) {
        await gesture.moveTo(Offset(from.dx, 780));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.pixels, greaterThan(0),
          reason: 'holding a dragged card at the edge must scroll the floor plan');
      await gesture.up();
      await tester.pumpAndSettle();
      // ...and it stops when the drag does, rather than running on forever.
      final settled = scroll.pixels;
      await tester.pump(const Duration(milliseconds: 500));
      expect(scroll.pixels, settled);
    });

    testWidgets('the drag still writes ONE section PATCH when it lands', (tester) async {
      // The fix must not have cost the thing that did work.
      final api = await _mount(
        tester,
        _routes([_table('T1', section: 'Bar'), _table('T2', section: 'Garden')]),
      );
      final from = tester.getCenter(find.text('T1'));
      final to = tester.getCenter(find.text('GARDEN'));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset(from.dx + (to.dx - from.dx) * i / 8, from.dy + (to.dy - from.dy) * i / 8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(api.writes.where((w) => w.path == '/table/T1'), hasLength(1));
      expect(api.writes.first.body, {'section': 'Garden'});
    });
  });

  // --------------------------------------------------------------- ITEM 11 ---
  group('item 11 — Occupied means an order has been placed', () {
    testWidgets('seated with no order reads SEATED; seated with an order reads OCCUPIED', (tester) async {
      await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: false),
          _table('T2', occupied: true, hasOrder: true, total: 450),
          _table('T3'),
          _table('T4', reserved: true),
        ]),
      );
      // Four distinct states on one floor.
      expect(_statusChip('Seated'), findsOneWidget);
      expect(_statusChip('Occupied'), findsOneWidget);
      expect(_statusChip('Reserved'), findsOneWidget);
      expect(_statusChip('Free'), findsOneWidget);
      // And the actionable line that goes with the new state.
      expect(find.text('Seated — no order yet'), findsOneWidget);
    });

    testWidgets('the legend counts the same states the cards paint', (tester) async {
      await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: false),
          _table('T2', occupied: true, hasOrder: false),
          _table('T3', occupied: true, hasOrder: true, total: 100),
          _table('T4'),
        ]),
      );
      expect(find.text('1 Occupied'), findsOneWidget);
      expect(find.text('2 Seated'), findsOneWidget);
      expect(find.text('1 Free'), findsOneWidget);
    });

    testWidgets('with nobody waiting, no Seated chip clutters the legend', (tester) async {
      await _mount(tester, _routes([_table('T1', occupied: true, hasOrder: true, total: 50), _table('T2')]));
      expect(find.textContaining('Seated'), findsNothing);
      expect(find.text('1 Occupied'), findsOneWidget);
    });

    testWidgets('an OLDER backend that never sends has_order still reads Occupied', (tester) async {
      // Missing data must degrade to the behaviour that shipped, never to a new
      // claim that nobody in the restaurant has ordered anything.
      await _mount(tester, _routes([_table('T1', occupied: true)]));
      expect(_statusChip('Occupied'), findsOneWidget);
      expect(_statusChip('Seated'), findsNothing);
    });

    testWidgets('a SEATED table still offers every seated action, money included', (tester) async {
      // The states are a rendering. The seating is real, so the sheet must not
      // treat a party who has not ordered as an empty table.
      await _mount(tester, _routes([_table('T1', occupied: true, hasOrder: false, covers: 4)]));
      await _openSheet(tester, 'T1');
      expect(_button('Settle bill'), findsOneWidget);
      expect(_button('Add order'), findsOneWidget);
      expect(_button('Release without payment'), findsOneWidget);
      expect(_button('Seat guests & take order'), findsNothing);
      // The covers behind APC are counted and shown, exactly as before.
      expect(find.textContaining('4 covers'), findsWidgets);
    });

    testWidgets('the three states render under Gaia too', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: false),
          _table('T2', occupied: true, hasOrder: true, total: 90),
          _table('T3'),
        ]),
        system: DesignSystem.gaia,
      );
      expect(_statusChip('Seated'), findsOneWidget);
      expect(_statusChip('Occupied'), findsOneWidget);
      expect(_statusChip('Free'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ ITEMS 21/22 ---
  group('items 21/22 — moving a party, and moving one ticket', () {
    testWidgets('Move table posts ONE call to the transactional route', (tester) async {
      // The whole safety argument is that this screen never composes a sequence
      // of its own: one request, one transaction, everything or nothing.
      final api = await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: true, covers: 2, total: 500),
          _table('T2', capacity: 6),
        ]),
      );
      await _openSheet(tester, 'T1');
      await tester.tap(_button('Move table'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table T2'));
      await tester.pumpAndSettle();
      // The consequences are named before anything happens.
      expect(find.textContaining('every order and the running bill move together'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      final moves = api.writes.where((w) => w.path == '/tables/move').toList();
      expect(moves, hasLength(1));
      expect(moves.first.body, {'from_table': 'T1', 'to_table': 'T2'});
      // Nothing else was written — no separate occupy, release or bill call.
      expect(api.writes, hasLength(1));
    });

    testWidgets('an OCCUPIED table is never offered as a move destination', (tester) async {
      // Putting a party onto an occupied table is Merge, and it is a different
      // act with a different effect on the bill.
      await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: true, covers: 2),
          _table('T2', occupied: true, hasOrder: true, covers: 2),
          _table('T3'),
        ]),
      );
      await _openSheet(tester, 'T1');
      await tester.tap(_button('Move table'));
      await tester.pumpAndSettle();
      expect(find.text('Table T3'), findsOneWidget);
      expect(find.text('Table T2'), findsNothing);
    });

    testWidgets('a table the party does not fit is never offered either', (tester) async {
      await _mount(
        tester,
        _routes([
          _table('T1', occupied: true, hasOrder: true, covers: 6, capacity: 6),
          _table('T2', capacity: 2),
        ]),
      );
      await _openSheet(tester, 'T1');
      await tester.tap(_button('Move table'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No free table seats 6'), findsOneWidget);
    });

    testWidgets('Move an order says what the KITCHEN will see before it does it', (tester) async {
      // The kitchen may already hold paper for the wrong table. Saying so in the
      // confirm is what stops a silent move being worse than the mis-key.
      final api = await _mount(
        tester,
        _routes([
          _table('T4', occupied: true, hasOrder: true, covers: 2, total: 450),
          _table('T7', occupied: true, hasOrder: true, covers: 4),
        ], orders: [
          {
            'id': 'o-1',
            'table_name': 'T4',
            'status': 'Preparing',
            'barked_at': '2026-09-09T12:10:00Z',
            'food': {'total': 450, 'items': [{'name': 'Paneer Tikka', 'quantity': 2}]},
          },
        ]),
      );
      api.writeReplies['/tables/move-order'] = {
        'success': true,
        'from_table': 'T4',
        'to_table': 'T7',
        'print': {'printed': true, 'kot_no': 26, 'tickets': 1},
      };
      await _openSheet(tester, 'T4');
      await tester.tap(_button('Move an order'));
      await tester.pumpAndSettle();
      // One live ticket, so no order picker — straight to the destination.
      await tester.tap(find.text('Table T7'));
      await tester.pumpAndSettle();
      expect(find.textContaining('correction docket prints'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      final moves = api.writes.where((w) => w.path == '/tables/move-order').toList();
      expect(moves, hasLength(1));
      expect(moves.first.body, {'order_id': 'o-1', 'to_table': 'T7'});
      // The KOT number is reported back, so whoever pressed it can tell the pass.
      expect(find.textContaining('KOT-26'), findsOneWidget);
    });

    testWidgets('an UNBARKED order says nothing will print', (tester) async {
      final api = await _mount(
        tester,
        _routes([
          _table('T4', occupied: true, hasOrder: true, covers: 2),
          _table('T7'),
        ], orders: [
          {
            'id': 'o-2',
            'table_name': 'T4',
            'status': 'Preparing',
            'barked_at': null,
            'food': {'total': 200, 'items': []},
          },
        ]),
      );
      api.writeReplies['/tables/move-order'] = {
        'success': true,
        'print': {'printed': false, 'kot_no': null, 'reason': 'never_ticketed'},
      };
      await _openSheet(tester, 'T4');
      await tester.tap(_button('Move an order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table T7'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nothing prints now'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no docket printed'), findsOneWidget);
    });

    testWidgets('a table with no live order says so instead of opening an empty picker', (tester) async {
      await _mount(
        tester,
        _routes([_table('T4', occupied: true, hasOrder: false, covers: 2), _table('T7')]),
      );
      await _openSheet(tester, 'T4');
      await tester.tap(_button('Move an order'));
      await tester.pumpAndSettle();
      expect(find.text('No live order on this table to move.'), findsOneWidget);
    });

    testWidgets('both moves render, and are reachable, under Gaia', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await _mount(
        tester,
        _routes([_table('T1', occupied: true, hasOrder: true, covers: 2), _table('T2')]),
        system: DesignSystem.gaia,
      );
      await _openSheet(tester, 'T1');
      expect(_button('Move table'), findsOneWidget);
      expect(_button('Move an order'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ the offline rule ---
  group('neither move may be queued offline', () {
    test('both routes REFUSE, and say to reconnect', () {
      // Deliberate, and the reason is timing rather than duplication: a move
      // held on a till and replayed twenty minutes later lands on a floor that
      // has changed — a destination somebody else has since seated — while the
      // person who pressed it walked away believing it happened. Same rule
      // settle and KOT printing already follow.
      for (final path in const ['/tables/move', '/tables/move-order']) {
        final d = OutboxPolicy.decide('POST', path);
        expect(d.queueable, isFalse, reason: '$path must not be queued offline');
        expect(d.refusal, OutboxPolicy.unsupported);
      }
    });
  });
}
