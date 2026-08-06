import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// Nothing on Concerns, Inventory or the Waitlist board is a dead end.
///
/// Three failure modes are being pinned, and they are the ones that make an
/// affordance worse than none at all:
///   * a tap that does nothing — so every element asserted here names the sheet
///     it opens or the module it reaches, and the elements deliberately left
///     inert are asserted to open NOTHING;
///   * a sheet that only repeats the card it came from — so each assertion is on
///     something the card could not hold (the sixth offender, the ledger, the
///     spread behind an average);
///   * an action fired by accident — tapping a waitlist row must open a
///     read-only sheet and must never post.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);

  final Map<String, dynamic> routes;
  final List<String> calls = <String>[];

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
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    // Longest matching prefix, so one route answers a query-carrying family.
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }

  List<String> get writes => calls.where((c) => !c.startsWith('GET ')).toList();
  List<String> to(String prefix) => calls.where((c) => c.contains(prefix)).toList();
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return RestClient(auth);
}

const List<String> _allLabels = [
  'Overview', 'Concerns', 'Orders', 'Menu', 'Inventory', 'Purchase Orders',
  'Tables', 'Waitlist', 'Bookings', 'Feedback', 'Employees', 'Customers',
];

Future<_FakeApi> _mount(
  WidgetTester tester,
  Widget Function(RestClient, Profile) module,
  Map<String, dynamic> routes, {
  List<String> labels = _allLabels,
  void Function(String, Map<String, dynamic>?)? onOpen,
}) async {
  // Blank pump first: these screens hold their own State, so re-pumping the
  // same widget type would keep the previously loaded payload.
  await tester.pumpWidget(const SizedBox());
  final api = _FakeApi(routes);
  final rest = await _signIn(api);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (label, {Map<String, dynamic>? target}) => onOpen?.call(label, target),
      visibleLabels: labels,
      clearFocus: () {},
      child: Scaffold(backgroundColor: Colors.transparent, body: module(rest, rest.auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void _size(WidgetTester tester, double width, {double height = 1600, double scale = 1.0}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Long boards scroll past the cache extent, so bring the target into the tree
/// before tapping it.
///
/// The rewind matters: `ensureVisible` on an earlier tap parks the page's list
/// with that row at the leading edge, which can leave a target ABOVE it — and
/// hunting forward from there would never reach it.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final page = find.byType(Scrollable).first;
  if (finder.evaluate().isEmpty) {
    await tester.drag(page, const Offset(0, 6000), warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250, scrollable: page, maxScrolls: 200);
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

/// The rail cards repeat words the queue table also uses ("Notified"), so a
/// rail assertion has to be scoped to the card it lives in.
Finder _inCard(String cardTitle, Finder inner) => find.descendant(
      of: find.ancestor(of: find.text(cardTitle), matching: find.byType(ForkCard)).last,
      matching: inner,
    );

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
}

// ------------------------------------------------------------------ concerns --

Map<String, dynamic> _concern({
  required String key,
  required String title,
  required String severity,
  required String module,
  required int count,
  String advice = 'Do the thing.',
  String detail = '',
  List<Map<String, dynamic>> items = const [],
  Map<String, dynamic> params = const {},
  num? amount,
}) =>
    {
      'key': key,
      'title': title,
      'severity': severity,
      'module': module,
      'count': count,
      'what_to_do': advice,
      if (detail.isNotEmpty) 'detail': detail,
      'items': items,
      'amount': ?amount,
      'deep_link': {'module': module, 'params': params},
    };

Map<String, dynamic> _concernsRoute(List<Map<String, dynamic>> concerns, Map<String, int> totals) => {
      '/analytics/concerns': {
        'window_days': 30,
        'timezone': 'Asia/Kolkata',
        'generated_at': '2026-08-03T04:30:00.000Z',
        'totals': totals,
        'concerns': concerns,
      },
    };

// ----------------------------------------------------------------- inventory --

Map<String, dynamic> _item(String id, String name, String category, int stock, String status,
        {String unit = 'kg', String? expiry}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'stock': stock,
      'unit': unit,
      'status': status,
      'expiry_date': expiry,
    };

Map<String, dynamic> _inventoryRoutes(
  List<Map<String, dynamic>> items, {
  List<String> categories = const ['Produce', 'Spices'],
  List<Map<String, dynamic>> movements = const [],
}) =>
    {
      '/inventory/movements': {'movements': movements},
      '/inventory': items,
      '/restaurant/settings': {'inventory_categories': categories},
    };

// ------------------------------------------------------------------ waitlist --

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
    {
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

Map<String, dynamic> _waitlistRoutes(
  List<Map<String, dynamic>> entries, {
  List<Map<String, dynamic>> pending = const [],
}) =>
    {
      '/waitlist/pending-preorders': {'entries': pending},
      '/waitlist': {'entries': entries},
      '/get-tables': [
        {'table_name': 'T1', 'occupied': false, 'reserved': false},
        {'table_name': 'T2', 'occupied': false, 'reserved': false},
        {'table_name': 'T3', 'occupied': true, 'reserved': false},
      ],
    };

void main() {
  // ================================================================ concerns ==

  testWidgets('a concern card opens the whole concern, not just the five the card had room for',
      (tester) async {
    _size(tester, 1400);
    String? opened;
    Map<String, dynamic>? target;
    await _mount(
      tester,
      m.concernsModule,
      _concernsRoute([
        _concern(
          key: 'unresolved_feedback',
          title: 'Bad reviews nobody has followed up',
          severity: 'high',
          module: 'Feedback',
          count: 8,
          advice: 'Call each of these guests back.',
          detail: 'Eight one-star reviews are still unanswered.',
          params: {'entity_id': 'f1', 'filter': 'open'},
          items: [for (var i = 1; i <= 8; i++) {'label': 'Guest $i', 'sub': '${i % 5 + 1}/5'}],
        ),
      ], {'high': 1, 'medium': 0, 'low': 0}),
      onOpen: (label, t) {
        opened = label;
        target = t;
      },
    );

    // The card stops at five offenders and drops the prose the moment it has
    // any of them — both are the reason the sheet exists.
    expect(find.text('Guest 6'), findsNothing);
    expect(find.textContaining('still unanswered'), findsNothing);

    await _tap(tester, find.text('Bad reviews nobody has followed up'));

    expect(find.text('AFFECTED'), findsOneWidget);
    expect(find.text('Guest 6'), findsOneWidget);
    expect(find.text('Guest 8'), findsOneWidget);
    expect(find.textContaining('still unanswered'), findsOneWidget);
    expect(find.text('Measured over'), findsOneWidget);
    expect(find.text('Last 30 days'), findsWidgets);

    // The jump carries ONLY the key Feedback actually reads — `filter` would
    // land the owner there and have the screen deny the record exists.
    await tester.tap(find.text('View in Feedback'));
    await tester.pumpAndSettle();
    expect(opened, 'Feedback');
    expect(target, {'entity_id': 'f1'});
  });

  testWidgets('a concern with no reachable module still opens its sheet, without a jump',
      (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.concernsModule,
      _concernsRoute([
        _concern(
          key: 'late_shifts',
          title: 'Shifts nobody clocked out of',
          severity: 'medium',
          module: 'Attendance',
          count: 2,
          items: [
            {'label': 'Asha', 'sub': '2 shifts'},
          ],
        ),
      ], {'high': 0, 'medium': 1, 'low': 0}),
      labels: const ['Concerns'],
    );

    await _tap(tester, find.text('Shifts nobody clocked out of'));
    expect(find.text('Affected'), findsOneWidget);
    // No module for this user means no jump at all — never a button that no-ops.
    expect(find.textContaining('View in'), findsNothing);
    await _closeSheet(tester);
  });

  testWidgets('the severity pills and the band headings are the same filter', (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.concernsModule,
      _concernsRoute([
        _concern(key: 'a', title: 'Open bills', severity: 'high', module: 'Orders', count: 1),
        _concern(key: 'b', title: 'Low stock', severity: 'medium', module: 'Inventory', count: 1),
        _concern(key: 'c', title: 'Slow movers', severity: 'low', module: 'Menu', count: 1),
      ], {'high': 1, 'medium': 1, 'low': 1}),
    );

    expect(find.text('Open bills'), findsOneWidget);
    expect(find.text('Slow movers'), findsOneWidget);

    // The summary pill narrows the list, and says so in words rather than
    // leaving the tint to carry it.
    await _tap(tester, find.text('1 medium'));
    expect(find.text('1 medium · only'), findsOneWidget);
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Open bills'), findsNothing);
    expect(find.text('Slow movers'), findsNothing);
    expect(find.text('Showing only this band'), findsOneWidget);

    await _tap(tester, find.text('Show every severity'));
    expect(find.text('Open bills'), findsOneWidget);

    // The band heading is the same control from the other end.
    await _tap(tester, find.text('Low — worth a look'));
    expect(find.text('Slow movers'), findsOneWidget);
    expect(find.text('Open bills'), findsNothing);
    // ...and it toggles back off.
    await _tap(tester, find.text('Low — worth a look'));
    expect(find.text('Open bills'), findsOneWidget);
  });

  testWidgets('a band with nothing in it is an inert pill, not a tap onto an empty list',
      (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.concernsModule,
      _concernsRoute([
        _concern(key: 'a', title: 'Open bills', severity: 'high', module: 'Orders', count: 1),
      ], {'high': 1, 'medium': 0, 'low': 0}),
    );

    await _tap(tester, find.text('0 low'));
    expect(find.text('0 low · only'), findsNothing);
    expect(find.text('Open bills'), findsOneWidget, reason: 'an inert pill must not filter');
  });

  testWidgets('the all-clear state still leads somewhere', (tester) async {
    _size(tester, 1400);
    String? opened;
    await _mount(
      tester,
      m.concernsModule,
      _concernsRoute(const [], {'high': 0, 'medium': 0, 'low': 0}),
      onOpen: (label, _) => opened = label,
    );

    expect(find.text('Nothing needs your attention'), findsOneWidget);
    await _tap(tester, find.text('Back to Overview'));
    expect(opened, 'Overview');
  });

  // =============================================================== inventory ==

  testWidgets('an item card opens its own sheet, and the ledger is fetched only then',
      (tester) async {
    _size(tester, 1400);
    final api = await _mount(
      tester,
      m.inventoryModule,
      _inventoryRoutes(
        [_item('i1', 'Tomatoes', 'Produce', 4, 'Low Stock', expiry: '2026-08-20')],
        movements: [
          {
            'id': 'mv1',
            'inventory_id': 'i1',
            'delta': -3,
            'kind': 'wastage',
            'reason': 'spoiled',
            'created_at': '2026-08-01T04:30:00.000Z',
          },
          {
            'id': 'mv2',
            'inventory_id': 'i9',
            'delta': 40,
            'kind': 'receive',
            'created_at': '2026-08-01T04:30:00.000Z',
          },
        ],
      ),
    );

    // The module's own load must not have grown a round-trip.
    expect(api.to('/inventory/movements'), isEmpty);

    await _tap(tester, find.text('Tomatoes'));

    expect(api.to('/inventory/movements'), isNotEmpty, reason: 'the ledger is a lazy fetch');
    expect(find.text('On hand'), findsOneWidget);
    // Twice: the row behind the sheet states the level too.
    expect(find.text('4 kg'), findsWidgets);
    // The two things the row has no column for.
    expect(find.text('Expiry'), findsOneWidget);
    expect(find.text('MOVEMENTS · LAST 30 DAYS'), findsOneWidget);
    expect(find.text('wastage · spoiled'), findsOneWidget);
    // Another item's movement must not leak into this item's history.
    expect(find.text('receive'), findsNothing);
    // A short item's next step is a purchase order; that is the only jump.
    expect(find.text('View in Purchase Orders'), findsOneWidget);
    await _closeSheet(tester);
  });

  testWidgets('an item in stock is offered no purchase-order jump', (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.inventoryModule,
      _inventoryRoutes([_item('i1', 'Rice', 'Produce', 90, 'In Stock')]),
    );

    await _tap(tester, find.text('Rice'));
    expect(find.text('On hand'), findsOneWidget);
    expect(find.textContaining('View in'), findsNothing);
    await _closeSheet(tester);
  });

  testWidgets('the stock tiles open the set they count, and a zero tile opens nothing',
      (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.inventoryModule,
      _inventoryRoutes([
        _item('i1', 'Tomatoes', 'Produce', 4, 'Low Stock'),
        _item('i2', 'Rice', 'Produce', 90, 'In Stock'),
      ]),
    );

    // Nothing is out of stock, so that tile is inert.
    await _tap(tester, find.text('OUT OF STOCK'));
    expect(find.text('Out of stock'), findsNothing, reason: 'a zero tile must not open a sheet');

    await _tap(tester, find.text('LOW STOCK'));
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('View in Purchase Orders'), findsOneWidget);

    // ...and each line in it is the way into that item.
    await _tap(tester, find.text('Tomatoes').last);
    expect(find.text('On hand'), findsOneWidget);
    expect(find.text('MOVEMENTS · LAST 30 DAYS'), findsOneWidget);
    await _closeSheet(tester);
  });

  testWidgets('ITEMS TRACKED carries the split the page only shows by scrolling', (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.inventoryModule,
      _inventoryRoutes([
        _item('i1', 'Tomatoes', 'Produce', 4, 'Low Stock'),
        _item('i2', 'Rice', 'Produce', 90, 'In Stock'),
        _item('i3', 'Napkins', '', 12, 'In Stock'),
      ]),
    );

    await _tap(tester, find.text('ITEMS TRACKED'));
    expect(find.text('3 items tracked'), findsOneWidget);
    expect(find.text('1 short'), findsOneWidget);

    // Every line opens that section.
    await _tap(tester, find.text('Produce').last);
    expect(find.text('Need restocking'), findsOneWidget);
    await _closeSheet(tester);
  });

  testWidgets('a section heading opens that section; an empty one stays inert', (tester) async {
    _size(tester, 1400);
    await _mount(
      tester,
      m.inventoryModule,
      _inventoryRoutes(
        [_item('i1', 'Tomatoes', 'Produce', 4, 'Low Stock')],
        categories: const ['Produce', 'Spices'],
      ),
    );

    // "Spices" is a saved category holding nothing — there is no section to open.
    await _tap(tester, find.text('Spices'));
    expect(find.text('Items'), findsNothing, reason: 'an empty section heading must not open a sheet');

    await _tap(tester, find.text('Produce'));
    expect(find.text('Items'), findsOneWidget);
    expect(find.text('Need restocking'), findsOneWidget);
    await _closeSheet(tester);
  });

  // ================================================================ waitlist ==

  testWidgets('tapping a queue row opens the party and posts nothing', (tester) async {
    _size(tester, 1700);
    final api = await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([
        _entry(id: 'w1', name: 'Ramachandran', partySize: 4, pre: [
          {'name': 'Paneer Butter Masala', 'quantity': 2, 'price': 340},
        ]),
      ]),
    );

    await _tap(tester, find.text('Ramachandran').first);

    // The read-only record, not one of the row's actions.
    expect(find.text('IN THE QUEUE'), findsOneWidget);
    expect(find.text('Party size'), findsOneWidget);
    expect(find.text('PRE-ORDER'), findsOneWidget);
    expect(api.writes, isEmpty, reason: 'a row tap must never call, seat, cancel or remove');
    await _closeSheet(tester);
  });

  testWidgets('reaching for the "..." menu does not fire the row underneath it', (tester) async {
    _size(tester, 1700);
    final api = await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([_entry(id: 'w1', name: 'Ramachandran')]),
    );

    await _tap(tester, find.byIcon(Icons.more_horiz));

    // The menu is open and the row's sheet is NOT.
    expect(find.text('Party details'), findsOneWidget);
    expect(find.text('Party size'), findsNothing);
    expect(api.writes, isEmpty);
  });

  testWidgets('the phone row opens the same party as the desktop row', (tester) async {
    _size(tester, 390, height: 900);
    final api = await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([_entry(id: 'w1', name: 'Ramachandran', partySize: 4)]),
    );

    // The phone drops the grid for a record — the tap has to survive that.
    expect(find.text('Position'), findsNothing);
    await _tap(tester, find.text('Ramachandran').first);
    expect(find.text('Party size'), findsOneWidget);
    expect(api.writes, isEmpty);
  });

  testWidgets('each stat tile reaches what it summarises', (tester) async {
    _size(tester, 1700);
    String? opened;
    await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([
        _entry(id: 'w1', name: 'Aarti', partySize: 2, minutes: 5, position: 1),
        _entry(id: 'w2', name: 'Bhavna', partySize: 6, minutes: 41, position: 2),
      ]),
      onOpen: (label, _) => opened = label,
    );

    // The panel is ordered by ARRIVAL, so "who has waited longest" is a ranking
    // that exists nowhere else on the page.
    await _tap(tester, find.text('WAITED SO FAR, SHORTEST TO LONGEST'));
    expect(find.text('Who has waited how long'), findsOneWidget);
    expect(find.text('41m'), findsWidgets);
    // Ranked by wait, not by the arrival order the panel behind it uses.
    expect(tester.getTopLeft(find.text('Bhavna').last).dy,
        lessThan(tester.getTopLeft(find.text('Aarti').last).dy));
    await _closeSheet(tester);

    // WHICH tables are free, not just how many — plus the way to the floor plan.
    await _tap(tester, find.text('TABLES READY TO SEAT NOW'));
    expect(find.text('2 tables ready'), findsOneWidget);
    expect(find.text('T1'), findsOneWidget);
    await tester.tap(find.text('View in Tables'));
    await tester.pumpAndSettle();
    expect(opened, 'Tables');

    // An average of 4 hides whether that is two pairs or one large booking.
    await _tap(tester, find.text('AVERAGE PARTY SIZE'));
    expect(find.text('Party sizes'), findsOneWidget);
    expect(find.text('6 people'), findsOneWidget);
    await _closeSheet(tester);
  });

  // The tile used to expand the list in place, which did nothing whenever the
  // queue already fitted inside the eight-row preview — i.e. for most services.
  // It opens the whole queue as a sheet now, which is observable at any length.
  testWidgets('the current-queue tile opens the whole queue, however short it is',
      (tester) async {
    _size(tester, 1700, height: 2400);
    await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([
        for (var i = 1; i <= 12; i++) _entry(id: 'w$i', name: 'Party $i', position: i),
      ]),
    );

    // The panel below is capped at eight, so the 11th is proof the sheet is not
    // just the same list.
    expect(find.text('Party 11'), findsNothing);
    await _tap(tester, find.text('CURRENT QUEUE'));
    expect(find.text('12 groups waiting'), findsOneWidget);
    expect(find.text('Party 11'), findsWidgets);
    await _closeSheet(tester);
  });

  // The regression that made this a rule: a SHORT queue fits the preview, so the
  // old in-place expansion changed nothing at all and the tap read as broken.
  testWidgets('the current-queue tile still opens with a queue shorter than the preview',
      (tester) async {
    _size(tester, 1700, height: 2400);
    await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([
        for (var i = 1; i <= 3; i++) _entry(id: 'w$i', name: 'Party $i', position: i),
      ]),
    );

    await _tap(tester, find.text('CURRENT QUEUE'));
    expect(find.text('3 groups waiting'), findsOneWidget);
    await _closeSheet(tester);
  });

  testWidgets('the queue summary rail drills into each set it counts', (tester) async {
    _size(tester, 1700, height: 2000);
    await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes(
        [
          _entry(id: 'w1', name: 'Aarti', partySize: 2),
          _entry(id: 'w2', name: 'Bhavna', partySize: 4, status: 'called'),
        ],
        pending: [
          {
            'id': 'w9',
            'name': 'Chandran',
            'table_name': 'T4',
            'minutes_since_seated': 5,
            'pre_order': [
              {'name': 'Paneer Butter Masala', 'quantity': 2, 'price': 340},
            ],
          },
        ],
      ),
    );

    await _reveal(tester, find.text('Queue summary'));
    await _tap(tester, _inCard('Queue summary', find.text('Guests waiting')));
    expect(find.text('6 guests waiting'), findsOneWidget);
    await _closeSheet(tester);

    // The held LINES, which the cards above the queue only ever count.
    await _reveal(tester, find.text('Queue summary'));
    await _tap(tester, _inCard('Queue summary', find.text('Pre-orders to confirm')));
    expect(find.text('Held pre-orders'), findsOneWidget);
    expect(find.text('Paneer Butter Masala ×2'), findsOneWidget);
    await _closeSheet(tester);

    // "Notified" is the walk-ins tab, which is where those parties are acted on.
    await _reveal(tester, find.text('Queue summary'));
    await _tap(tester, _inCard('Queue summary', find.text('Notified')));
    expect(find.text('Bhavna'), findsWidgets);
    expect(find.text('Aarti'), findsNothing);
  });

  testWidgets('a summary figure counting nothing opens nothing', (tester) async {
    _size(tester, 1700);
    await _mount(tester, m.waitlistModule, _waitlistRoutes([_entry(id: 'w1', name: 'Aarti')]));

    // Nothing is held, so the figure is inert rather than opening an empty sheet.
    await _reveal(tester, find.text('Queue summary'));
    await _tap(tester, _inCard('Queue summary', find.text('Pre-orders to confirm')));
    expect(find.text('Held pre-orders'), findsNothing);
  });

  testWidgets('a walk-in rail line opens that party', (tester) async {
    _size(tester, 1700, height: 2000);
    final api = await _mount(
      tester,
      m.waitlistModule,
      _waitlistRoutes([
        _entry(id: 'w2', name: 'Bhavna', status: 'called', partySize: 3, phone: '9000000002'),
      ]),
    );

    await _reveal(tester, find.text('Walk-ins to be seated'));
    await _tap(tester, _inCard('Walk-ins to be seated', find.text('Bhavna')));
    expect(find.text('Party size'), findsOneWidget);
    expect(find.text('9000000002'), findsWidgets);
    expect(api.writes, isEmpty, reason: 'the rail line must not seat anybody');
    await _closeSheet(tester);
  });

  // =================================================================== sweep ==

  // Every one of these screens grew drill-downs, and a dialog is exactly where a
  // 460px card meets a 390px window. Hostile strings at every width and scale.
  testWidgets('every new drill-down survives each window and text scale', (tester) async {
    const hostile = 'Dr Anantharamakrishnan Venkataraghavan Subramanian Iyer';

    for (final width in [390.0, 1100.0, 1200.0, 1700.0]) {
      for (final scale in [1.0, 1.3]) {
        _size(tester, width, height: 2000, scale: scale);
        final why = 'at ${width}px / ${scale}x';

        // -- concerns
        await _mount(
          tester,
          m.concernsModule,
          _concernsRoute([
            _concern(
              key: 'unsettled_bills',
              title: 'Bills left open on tables that have already gone home',
              severity: 'high',
              module: 'Orders',
              count: 9,
              amount: 18450.75,
              advice: 'Chase these tables and close the bills. This is money already '
                  'earned and not yet collected.',
              detail: 'Nine bills across seven tables, the oldest open for two days.',
              items: [
                for (var i = 1; i <= 9; i++)
                  {'label': '$hostile $i', 'sub': '₹98,765,432.10 · open 2 days'},
              ],
            ),
          ], {'high': 1, 'medium': 0, 'low': 0}),
        );
        expect(tester.takeException(), isNull, reason: 'concerns board overflowed $why');
        await _tap(tester, find.textContaining('Bills left open'));
        expect(tester.takeException(), isNull, reason: 'concern sheet overflowed $why');
        await _closeSheet(tester);

        // -- inventory
        await _mount(
          tester,
          m.inventoryModule,
          _inventoryRoutes(
            [
              _item('i1', '$hostile tomatoes', 'Produce grown on the far terrace', 4, 'Low Stock',
                  unit: 'kilograms, net of trim', expiry: '2026-08-20'),
            ],
            movements: [
              {
                'id': 'mv1',
                'inventory_id': 'i1',
                'delta': -3,
                'kind': 'wastage',
                'reason': 'spoiled in the walk-in over the long weekend',
                'created_at': '2026-08-01T04:30:00.000Z',
              },
            ],
          ),
        );
        expect(tester.takeException(), isNull, reason: 'inventory list overflowed $why');
        await _tap(tester, find.textContaining('$hostile tomatoes'));
        expect(tester.takeException(), isNull, reason: 'item sheet overflowed $why');
        await _closeSheet(tester);
        await _tap(tester, find.text('LOW STOCK'));
        expect(tester.takeException(), isNull, reason: 'low-stock sheet overflowed $why');
        await _closeSheet(tester);

        // -- waitlist
        await _mount(
          tester,
          m.waitlistModule,
          _waitlistRoutes(
            [
              for (var i = 1; i <= 6; i++)
                _entry(
                  id: 'w$i',
                  name: '$hostile $i',
                  position: i,
                  partySize: i % 9 + 1,
                  minutes: i * 7,
                  phone: '+91 98765 43210 ext. 4471 (ask for the front desk)',
                  pre: [
                    {'name': 'Paneer Butter Masala with extra gravy', 'quantity': 2, 'price': 340},
                  ],
                ),
            ],
            pending: [
              {
                'id': 'w9',
                'name': hostile,
                'table_name': 'Terrace table by the far window',
                'minutes_since_seated': 9,
                'pre_order': [
                  {'name': 'Paneer Butter Masala with extra gravy', 'quantity': 3, 'price': 340},
                ],
              },
            ],
          ),
        );
        expect(tester.takeException(), isNull, reason: 'waitlist board overflowed $why');
        await _tap(tester, find.textContaining('$hostile 1'));
        expect(tester.takeException(), isNull, reason: 'party sheet overflowed $why');
        await _closeSheet(tester);
        await _tap(tester, find.text('WAITED SO FAR, SHORTEST TO LONGEST'));
        expect(tester.takeException(), isNull, reason: 'longest-waits sheet overflowed $why');
        await _closeSheet(tester);
        await _reveal(tester, find.text('Queue summary'));
        await _tap(tester, _inCard('Queue summary', find.text('Pre-orders to confirm')));
        expect(tester.takeException(), isNull, reason: 'held pre-orders sheet overflowed $why');
        await _closeSheet(tester);
      }
    }
  });
}
