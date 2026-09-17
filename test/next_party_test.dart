import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/next_party.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';
import 'package:restaurant_owner_app/widgets/outbox_chip.dart';
import 'package:restaurant_owner_app/widgets/table_bill.dart';

/// CLIENT ITEM 6 — THE NEXT PARTY AT A PRINTED TABLE.
///
/// "Table where bill is printed is disappearing from the waiter app. There
/// should be a duplicate table showing same number for order taking for the
/// next round of guests."
///
/// What this file holds, in the order of what it would cost to get wrong:
///
///   * AN ORDER FOR THE NEXT GUESTS NEVER LANDS ON THE PRINTED BILL. The tile
///     reads "T1", but every write it leads to — the seating, the order, the
///     outbox tag — names "T1 #2", the seat's own table row. And when the
///     server refuses an order on a printed bill (423 `bill_printed`), the pad
///     writes nothing and offers to take the SAME cart to the next party's seat;
///     a queued copy of that order is parked at once, never retried in front of
///     the device's other work.
///   * A MANAGER'S ADDITION TO A PRINTED BILL IS TOLD TO REPRINT — after an
///     order, a merge or an item moved onto it — with a Reprint that prints
///     that table.
///   * THE PRINTED PARTY STAYS, ORANGE, AND THE SEAT BESIDE IT IS GREEN (client
///     items 1 and 2 retired C3's "off their floor"; v3_client_block_test and
///     waiter_floor_printed_test pin the rest). Both tiles read "T1".
///   * THE ROOM HAS NO "T1 #2" IN IT: not on the floor plan, not in the
///     delete list, not in the Free count, and not makeable by hand.
///   * ONE VOCABULARY with the server and the web: "Next party", "T1 (next
///     party)", "Take it on T1 (next party)" — read here off the backend's
///     own source when the checkout is beside this one.

// ------------------------------------------------------------------ the fake

typedef _Route = Object? Function(String path);

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.role = 'admin', this.actions = const ['*'], this.waiterOnly});

  final Map<String, _Route> routes;
  final String role;
  final List<String> actions;
  final bool? waiterOnly;

  /// Every write the server APPLIED.
  final List<({String method, String path, Object? body})> writes = [];

  /// Every write that was ATTEMPTED, refused or not.
  final List<({String method, String path, Object? body})> attempts = [];

  /// Decides a write before it is applied: return an exception to refuse it.
  ApiException? Function(String path, Object? body)? refuse;

  /// While true, no write reaches the server at all (a statusless failure).
  bool offline = false;

  /// The server's answer to an applied write, when a screen reads it.
  final Map<String, Object? Function(Object? body)> replies = {};

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Global Vegetarian',
          'restaurantUsername': 'ggv',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'atsu',
          'emp_Fname': 'Atsu',
          'role': role,
          'role_all': [role],
          if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
          'actions_set': actions,
          'action_names': const [
            'View Orders', 'Create Order', 'View Tables', 'Occupy Table', 'View Menu', 'View Bills',
          ],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      if (offline) throw ApiException('Connection refused', null);
      attempts.add((method: method, path: path, body: body));
      final refusal = refuse?.call(path, body);
      if (refusal != null) throw refusal;
      writes.add((method: method, path: path, body: body));
      final reply = replies[path];
      return reply == null ? <String, dynamic>{'success': true} : reply(body);
    }
    final keys = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (keys.isEmpty) throw ApiException('No fake route for $path', 404);
    return routes[keys.first]!(path);
  }

  Iterable<({String method, String path, Object? body})> to(String path) =>
      writes.where((w) => w.path == path);
}

// ---------------------------------------------------------------- fixtures --

Map<String, dynamic> _root({bool printed = true, String name = 'T1', bool occupied = true}) => {
      'table_name': name,
      'parent_table': null,
      'party_no': null,
      'display_name': name,
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': occupied,
      'has_order': occupied,
      'reserved': false,
      'num_covers': occupied ? 4 : 1,
      'covers': occupied ? 4 : 1,
      'table_total': occupied ? 1050.0 : 0.0,
      'table_apc': occupied ? 262.5 : 0.0,
      'apc_status': 'neutral',
      'print_count': printed ? 1 : 0,
      'bill_printed_at': printed ? '2026-09-16T08:02:54.000Z' : null,
      'printed_at': printed ? '2026-09-16T08:02:54.000Z' : null,
    };

Map<String, dynamic> _seat({bool occupied = false}) => {
      'table_name': 'T1 #2',
      'parent_table': 'T1',
      'party_no': 2,
      'display_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': occupied,
      'has_order': false,
      'reserved': false,
      'num_covers': 1,
      'covers': 1,
      'table_total': 0.0,
      'table_apc': 0.0,
      'apc_status': 'neutral',
      'print_count': 0,
      'bill_printed_at': null,
      'printed_at': null,
    };

Map<String, dynamic> _printedBill() => {
      'bill_id': 'bill-12',
      'table_id': 'tbl-12',
      'total_amt': 1050.0,
      'subtotal': 1050.0,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'tax_total': 0.0,
      'grand_total': 1050.0,
      'nc_total': 0.0,
      'covers': 4,
      'apc': 262.5,
      'target_apc': 300.0,
      'apc_status': 'red',
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Thali', 'price': 525.0, 'quantity': 2},
      ],
      'first_order_at': '2026-09-16T07:58:00Z',
      'last_order_at': '2026-09-16T07:58:00Z',
      'print_count': 0,
      'bill_printed_at': null,
      'printed_at': null,
    };

Map<String, _Route> _floor(List<Map<String, dynamic>> tables) => {
      '/get-tables': (_) => tables,
      '/table-assignments': (_) => <dynamic>[],
      '/get-bookings': (_) => <dynamic>[],
      '/table-sections': (_) => {
            'sections': [
              {'section': 'Main'},
            ],
          },
      // The seat has no bill yet; the root has the printed one.
      '/bill-for-table': (path) => path.contains('%23') ? <String, dynamic>{'items': const []} : _printedBill(),
      '/restaurant/settings': (_) => {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': (_) => {'outlet_add': ''},
      '/menu': (_) => const [
            {'id': 'mi-1', 'name': 'Gulab Jamun', 'price': 120.0, 'category': 'Desserts'},
          ],
    };

_FakeApi _waiter(Map<String, _Route> routes) =>
    _FakeApi(routes, role: 'waiter', actions: const ['a1'], waiterOnly: true);

_FakeApi _owner(Map<String, _Route> routes) => _FakeApi(routes);

/// The refusal the server answers an order on a printed bill with —
/// next_party.ts' billPrintedRefusal, verbatim, at BILL_PRINTED_STATUS.
ApiException _billPrinted({String? nextParty = 'T1 #2', bool guest = false, int status = billPrintedStatus}) =>
    ApiException.fromBody({
      'error': guest
          ? "This table's bill has already been printed, so nothing more can be ordered on it here. Please ask a member of staff."
          : nextParty == null
              ? "T1's bill has already been printed, so nothing more can be added to it. Ask a manager to add it and reprint the bill."
              : "T1's bill has already been printed, so nothing more can be added to it. Take a new party's order on T1 (next party). If it is for the same guests, ask a manager to add it and reprint the bill.",
      'code': 'bill_printed',
      'table': 'T1',
      'next_party_table': nextParty,
      'next_party_action': nextParty == null || guest ? null : 'Take it on T1 (next party)',
      'print_count': 1,
    }, status);

// ------------------------------------------------------------------- hosts --

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Global Vegetarian', 'atsu', 'pw');
  return RestClient(auth);
}

Widget _host(Widget child) => GaiaScope(
      system: DesignSystem.rustic,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<void> _mountFloor(WidgetTester tester, _FakeApi api, {bool plan = false}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  final p = rest.auth.profile!;
  await tester.pumpWidget(_host(plan ? m.floorPlanModule(rest, p) : m.tablesModule(rest, p)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* not on this sheet at all */}
  await tester.pumpAndSettle();
}

final Finder _rootTile = find.byKey(const ValueKey('table-title-T1'));
final Finder _seatTile = find.byKey(const ValueKey('table-title-T1 #2'));

/// The pad, pushed from a host route so a test can see it close.
Future<(_FakeApi, List<bool?>)> _pumpPad(WidgetTester tester, _FakeApi api,
    {String table = 'T1', bool occupyOnSend = false, Size size = const Size(420, 900)}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  final closed = <bool?>[];
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              closed.add(await Navigator.push<bool>(
                ctx,
                MaterialPageRoute(
                  builder: (_) => OrderEntryScreen(rest: rest, tableName: table, occupyOnSend: occupyOnSend),
                ),
              ));
            },
            child: const Text('open pad'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open pad'));
  await tester.pumpAndSettle();
  return (api, closed);
}

Future<void> _addAndSend(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('order-send')));
  await tester.pumpAndSettle();
}

/// Would a finger on [finder]'s centre land on it? False when it is clipped out
/// of its box or drawn under something else — a control on screen in the tree
/// and out of reach on the glass.
bool _reachable(WidgetTester tester, Finder finder) {
  final target = tester.renderObject(finder);
  return tester.hitTestOnBinding(tester.getCenter(finder)).path.any((e) => identical(e.target, target));
}

Future<void> _answerCovers(WidgetTester tester, String covers) async {
  expect(find.text('How many guests at this table?'), findsOneWidget);
  await tester.enterText(find.byType(TextField).last, covers);
  await tester.tap(find.widgetWithText(FilledButton, 'Send order'));
  await tester.pumpAndSettle();
}

const String _reprintT1 =
    "T1's bill was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.";

/// A senior role's answer to a write that grew a printed bill.
Map<String, dynamic> _reprintReply(Map<String, dynamic> base, {String table = 'T1'}) => {
      ...base,
      'reprint_needed': true,
      'reprint_message': _reprintT1.replaceAll('T1', table),
      'reprint_table': table,
    };

const Map<String, dynamic> _orderBody = {
  'items': [
    {'id': 'mi-1', 'name': 'Gulab Jamun', 'price': 120.0, 'quantity': 1},
  ],
  'subtotal': 120.0,
  'total': 120.0,
  'status': 'Preparing',
};

/// The backend checkout, when it is next to this one.
File _backend(String rel) => File('../Restaurant_Backend/$rel');

void main() {
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // THE WORDS AND THE SHAPE
  // ==========================================================================

  group('the words and the shape', () {
    test('a reserved name is " #<digits>" at the end, and nothing else', () {
      for (final n in ['12 #2', 'Patio 4 #13', ' 7 #2 ']) {
        expect(isReservedPartyName(n), isTrue, reason: n);
      }
      for (final n in ['12', '12#2', '12-2', '31A', 'T #', '#2', '12 #2a', '', null]) {
        expect(isReservedPartyName(n), isFalse, reason: '$n');
      }
    });

    test('the tile reads the root; a sentence says "(next party)"; the handle is untouched', () {
      final seat = _seat();
      expect(isNextPartyRow(seat), isTrue);
      expect(tableDisplayName(seat), 'T1');
      expect(tableSentenceNameOf(seat), 'T1 (next party)');
      expect(isNextPartyRow(_root()), isFalse);
      expect(tableDisplayName(_root()), 'T1');
      expect(tableSentenceNameOf(_root()), 'T1');
      // The parent decides, even without (or against) a display name.
      expect(tableDisplayName({'table_name': 'T1 #2', 'parent_table': 'T1'}), 'T1');
      expect(tableDisplayName({'table_name': 'T1 #2', 'parent_table': 'T1', 'display_name': 'T1 #2'}), 'T1');
      // An older backend: no new fields at all, and the row's own name stands.
      expect(tableDisplayName({'table_name': 'T1 #2'}), 'T1 #2');
      expect(isNextPartyRow({'table_name': 'T1 #2'}), isFalse);
      // A sentence about a bare handle still says it in words.
      expect(tableSentenceName('12 #2'), '12 (next party)');
      expect(tableSentenceName('12'), '12');
      expect(parseNextPartyName('Patio 4 #13'), (root: 'Patio 4', seq: 13));
      expect(parseNextPartyName('12 #1'), isNull, reason: 'the root is party 1');
      expect(takeItOnLabel('12 #2'), 'Take it on 12 (next party)');
    });

    test('the room is counted once: 12 is in use while it, or its next party, is', () {
      bool busy(Map r) => r['occupied'] == true;
      final free12 = _root(printed: false, occupied: false);
      expect(countRoomsInUse([_root(), _seat()], busy), (inUse: 1, rooms: 1));
      expect(countRoomsInUse([free12, _seat(occupied: true)], busy), (inUse: 1, rooms: 1));
      expect(countRoomsInUse([free12, _seat()], busy), (inUse: 0, rooms: 1));
      expect(countRoomsInUse([_root(), _seat(occupied: true), _root(name: 'T2', occupied: false)], busy),
          (inUse: 1, rooms: 2));
      // An older backend: every row is a room.
      expect(countRoomsInUse([{'table_name': 'T1 #2', 'occupied': true}], busy), (inUse: 1, rooms: 1));
    });

    test('a print answer is read for the seat, the server\'s sentence first', () {
      expect(nextPartyAfterPrint({'next_party_table': '12 #2', 'next_party_message': 'Seat them.'}),
          (table: '12 #2', message: 'Seat them.'));
      expect(nextPartyAfterPrint({'next_party_table': '12 #2'}),
          (table: '12 #2', message: 'Seat the next party at 12 (next party).'));
      // The root itself is free again: named as it is.
      expect(nextPartyAfterPrint({'next_party_table': '12'}).message, 'Seat the next party at 12.');
      for (final none in [null, 'x', <String, dynamic>{}, {'next_party_table': null}, {'next_party_table': ' '}]) {
        expect(nextPartyAfterPrint(none), (table: null, message: null), reason: '$none');
      }
    });

    test('a reprint is read off a senior role\'s answer, in the server\'s words, for the table it names', () {
      final r = ReprintNeeded.parse(_reprintReply({'id': 'o-1'}), fallbackTable: 'T9')!;
      expect(r.table, 'T1', reason: 'the server named the table; the fallback is only a fallback');
      expect(r.message, _reprintT1);
      // A server that flagged it without the sentence or the table.
      final bare = ReprintNeeded.parse({'reprint_needed': true}, fallbackTable: 'T1 #2')!;
      expect(bare.table, 'T1 #2');
      expect(bare.message,
          "T1 (next party)'s bill was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.");
      expect(reprintNeededMessage('T1'), _reprintT1);
      // Not flagged, or nothing to reprint: no line.
      for (final none in [null, 'x', <String, dynamic>{}, {'reprint_needed': false}, {'reprint_needed': 'true'}]) {
        expect(ReprintNeeded.parse(none, fallbackTable: 'T1'), isNull, reason: '$none');
      }
      expect(ReprintNeeded.parse({'reprint_needed': true}), isNull);
    });

    test('revenue by table is TABLE-WISE: a next-party seating is added in under its table, as the web does', () {
      final rows = [
        {'table_name': 'T1', 'table_label': 'T1', 'total': 1050},
        {'table_name': 'T1 #2', 'table_label': 'T1', 'total': '630'},
        {'table_name': 'T2', 'total': 400.0}, // an older backend: no label
        {'table_name': 'T3', 'table_label': 'T3', 'total': 0},
        {'table_label': '', 'table_name': '', 'total': 50},
        'junk',
      ];
      expect(tableWiseLabel(rows[1] as Map), 'T1');
      expect(tableWiseLabel(rows[2] as Map), 'T2');
      expect(revenueByTable(rows), [
        (label: 'Table T1', value: 1680.0),
        (label: 'Table T2', value: 400.0),
        (label: 'Table —', value: 50.0),
      ]);
      expect(revenueByTable(const []), isEmpty);
    });

    test('the refusal is read for its action; anything else is not a bill_printed refusal', () {
      final r = BillPrintedRefusal.parse(_billPrinted().body)!;
      expect(r.table, 'T1');
      expect(r.nextPartyTable, 'T1 #2');
      expect(r.actionLabel, 'Take it on T1 (next party)');
      expect(r.message, startsWith("T1's bill has already been printed"));

      // No seat to point at, or the seat IS the table: a sentence and no button.
      final none = BillPrintedRefusal.parse(_billPrinted(nextParty: null).body)!;
      expect([none.nextPartyTable, none.actionLabel], [null, null]);
      final self = BillPrintedRefusal.parse({..._billPrinted().body!, 'next_party_table': 'T1'})!;
      expect([self.nextPartyTable, self.actionLabel], [null, null]);
      // An older server that named the seat without the label still gets one.
      final bare = BillPrintedRefusal.parse({..._billPrinted().body!, 'next_party_action': null})!;
      expect(bare.actionLabel, 'Take it on T1 (next party)');

      expect(BillPrintedRefusal.parse({'error': 'Forbidden'}), isNull);
      expect(BillPrintedRefusal.parse({'code': 'otp_required'}), isNull);
      expect(BillPrintedRefusal.parse(null), isNull);
    });

    test('the waiver print says where the next party sits — only when paper came out', () {
      final printed = m.serviceChargeRemovalOutcome({
        'waiver_created': true,
        'printed': true,
        'service_charge_removed': true,
        'grand_total_before': 1155.0,
        'grand_total_after': 1050.0,
        'next_party_table': 'T1 #2',
        'next_party_message': 'Seat the next party at T1 (next party).',
      });
      expect(printed.message, endsWith('Printing bill… Seat the next party at T1 (next party).'));
      expect(printed.shown, const Duration(seconds: 6));

      final failed = m.serviceChargeRemovalOutcome({
        'waiver_created': true,
        'printed': false,
        'grand_total_before': 1155.0,
        'grand_total_after': 1050.0,
        'next_party_table': 'T1 #2',
      });
      expect(failed.message, isNot(contains('next party')));

      // No seat named: exactly the 2.0.0 sentence.
      final plain = m.serviceChargeRemovalOutcome({'printed': true, 'grand_total_after': 1050.0});
      expect(plain.message, 'Reprinting without the service charge — total ₹1050.00.');
    });
  });

  // ==========================================================================
  // ONE VOCABULARY — the server's own source
  // ==========================================================================

  group('the same words as the server (Restaurant_Backend/next_party.ts)', () {
    String? source() {
      final f = _backend('next_party.ts');
      return f.existsSync() ? f.readAsStringSync().replaceAll(String.fromCharCode(13), '') : null;
    }

    String tsString(String src, String name) {
      final m = RegExp('export const $name =\\s*"((?:[^"\\\\]|\\\\.)*)";').firstMatch(src);
      expect(m, isNotNull, reason: '$name is gone from next_party.ts');
      return m!.group(1)!.replaceAll(r'\"', '"');
    }

    test('chip, code, refusal sentence and the reserved shape', () {
      final src = source();
      if (src == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      expect(tsString(src, 'NEXT_PARTY_CHIP'), nextPartyChip);
      expect(tsString(src, 'BILL_PRINTED_CODE'), billPrintedCode);
      expect(tsString(src, 'RESERVED_TABLE_NAME_ERROR'), reservedTableNameError);
      expect(src, contains(r'const RESERVED_TAIL = /\s#\d+$/;'));
      expect(src, contains('export const NEXT_PARTY_SEPARATOR = " #";'));
    });

    test('the sentences this app builds for itself are the server\'s', () {
      final src = source();
      if (src == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      expect(src, contains('return `\${String(root ?? "").trim()} (next party)`;'));
      expect(src, contains('return `Take it on \${tableSentenceName(next, parent)}`;'));
      expect(src, contains('return `Seat the next party at \${'));
      expect(src, contains("was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.`;"));
      expect(reprintNeededMessage('T1'), endsWith('was already printed, so the paper no longer shows this. Reprint the bill before the guest pays.'));
    });

    test('the refusal\'s status is the server\'s, and it is one this app\'s outbox parks', () {
      final src = source();
      if (src == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      expect(src, contains('export const BILL_PRINTED_STATUS = $billPrintedStatus;'));
      expect(billPrintedStatus, isNot(409));
      expect(const [401, 408, 409, 429], isNot(contains(billPrintedStatus)));
    });

    test('the /get-tables row carries the three fields this app reads', () {
      final f = _backend('database_supabase.ts');
      if (!f.existsSync()) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      final src = f.readAsStringSync();
      final at = src.indexOf('export async function GetTables(');
      expect(at, greaterThan(-1));
      final body = src.substring(at, src.indexOf('\nexport ', at + 1));
      for (final field in ['parent_table:', 'party_no:', 'display_name:']) {
        expect(body, contains(field), reason: field);
      }
    });
  });

  // ==========================================================================
  // THE WAITER'S FLOOR
  // ==========================================================================

  group('a waiter\'s floor after a print', () {
    // CHANGED ON PURPOSE FOR CLIENT ITEMS 1 AND 2. This used to pin that the
    // printed T1 was OFF the waiter's floor and only its seat was left. "If a
    // bill is not settled, the table completely vanishes" was the complaint:
    // the printed T1 now stays, orange, and the seat beside it is green.
    testWidgets('two "T1"s: the printed one orange, the next party\'s green with its "#2"', (tester) async {
      await _mountFloor(tester, _waiter(_floor([_root(), _seat()])));
      expect(_rootTile, findsOneWidget, reason: 'the printed party left the waiter\'s floor');
      expect(_seatTile, findsOneWidget);
      expect(find.text('T1'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('table-T1-Bill printed')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-T1 #2-Free')), findsOneWidget);
      expect(find.byKey(const ValueKey('next-party-chip-T1 #2')), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.byTooltip(nextPartyChip), findsOneWidget, reason: 'the chip still says what it is');
      expect(find.text('T1 #2'), findsNothing, reason: 'the handle is not what the tile says');
      // The per-table outbox badge is keyed by the HANDLE, which is what an
      // order queued for the seat is tagged with — and the printed T1 keeps its
      // own.
      final badges = tester.widgetList<OutboxTagBadge>(find.byType(OutboxTagBadge)).map((b) => b.tag);
      expect(badges, containsAll(['table:T1 #2', 'table:T1']));
      expect(OutboxPolicy.tagFor('/orders', {'table': 'T1 #2'}), 'table:T1 #2');
    });

    testWidgets('tapping it takes the order for the NEXT party: seat and order both name "T1 #2"',
        (tester) async {
      final api = _waiter(_floor([_root(), _seat()]));
      await _mountFloor(tester, api);
      await tester.tap(_seatTile);
      await tester.pumpAndSettle();

      // The sheet says which T1 this is, and what its paper will read.
      expect(find.text('Table T1 (next party)'), findsOneWidget);
      expect(find.text('Bill reads T1 #2'), findsOneWidget);

      await _reveal(tester, find.byKey(const ValueKey('table-add-order')));
      await tester.tap(find.byKey(const ValueKey('table-add-order')));
      await tester.pumpAndSettle();
      expect(find.byType(OrderEntryScreen), findsOneWidget);
      expect(find.text('New order · T1 (next party)'), findsOneWidget);

      await _addAndSend(tester);
      await _answerCovers(tester, '3');

      expect(api.writes.map((w) => w.path).toList(), ['/occupy-table', '/orders']);
      expect((api.to('/occupy-table').single.body as Map)['table_name'], 'T1 #2');
      expect((api.to('/occupy-table').single.body as Map)['num_covers'], 3);
      expect((api.to('/orders').single.body as Map)['table'], 'T1 #2',
          reason: 'the next party\'s order went to the printed bill');
    });

    testWidgets('an owner sees both, and the idle seat is not counted as a free table', (tester) async {
      await _mountFloor(tester, _owner(_floor([_root(), _seat(), _root(name: 'T2', printed: false, occupied: false)])));
      expect(_rootTile, findsOneWidget);
      expect(_seatTile, findsOneWidget);
      // T1 and its seat sit side by side, in the server's order.
      final rootAt = tester.getTopLeft(_rootTile);
      final seatAt = tester.getTopLeft(_seatTile);
      expect(seatAt.dy, closeTo(rootAt.dy, 4), reason: 'not on the same row');
      expect(seatAt.dx, greaterThan(rootAt.dx));
      expect(tester.getTopLeft(find.byKey(const ValueKey('table-title-T2'))).dx, greaterThan(seatAt.dx),
          reason: 'the seat is listed straight after its table');
      // Free is T2 alone; the printed T1 is the night-settle backlog.
      expect(find.text('1 Free'), findsOneWidget);
      expect(find.text('1 Bill printed'), findsOneWidget);
    });

    testWidgets('a seated next party is a party like any other on the legend', (tester) async {
      await _mountFloor(tester, _owner(_floor([_root(), {..._seat(occupied: true), 'has_order': true}])));
      expect(find.text('1 Bill printed'), findsOneWidget);
      expect(find.text('1 Running'), findsOneWidget);
      // A state with no table is left out, as "0 Seated" always was.
      expect(find.byKey(const ValueKey('floor-legend-free')), findsNothing);
      expect(find.text('0 Free'), findsNothing);
    });
  });

  // ==========================================================================
  // THE ROOM
  // ==========================================================================

  group('the floor plan is the room: no "T1 #2" in it', () {
    testWidgets('the layout editor draws T1 and not its next-party seat', (tester) async {
      await _mountFloor(tester, _owner(_floor([_root(), _seat(), _root(name: 'T2', printed: false, occupied: false)])),
          plan: true);
      expect(find.byKey(const ValueKey('plan-table-T1')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-table-T2')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-table-T1 #2')), findsNothing);
      // The legend and the zone header both count the room: two tables.
      expect(find.text('2 tables'), findsWidgets);
      expect(find.text('3 tables'), findsNothing);
    });

    testWidgets('the delete list offers the room\'s free tables, never the seat', (tester) async {
      final api = _owner(_floor([_root(), _seat(), _root(name: 'T2', printed: false, occupied: false)]));
      await _mountFloor(tester, api, plan: true);
      await tester.tap(find.byKey(const ValueKey('floor-delete-table')));
      await tester.pumpAndSettle();
      expect(find.text('Delete which table?'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('T2')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('T1 #2')), findsNothing);
      expect(api.writes, isEmpty);
    });

    testWidgets('"T1 #2" cannot be typed into Add table — the server\'s sentence, and no write',
        (tester) async {
      final api = _owner(_floor([_root(printed: false, occupied: false)]));
      await _mountFloor(tester, api, plan: true);
      await tester.tap(find.text('Add table'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Table name (e.g. T7)'), '12 #2');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text(reservedTableNameError), findsOneWidget);
      expect(api.to('/add-table'), isEmpty);

      // An ordinary name still goes through.
      await tester.enterText(find.widgetWithText(TextField, 'Table name (e.g. T7)'), 'T9');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(api.to('/add-table'), hasLength(1));
      expect(((api.to('/add-table').single.body as Map)['table'] as Map)['name'], 'T9');
    });
  });

  // ==========================================================================
  // THE PAD ON A PRINTED BILL
  // ==========================================================================

  group('the pad, when the server refuses an order on a printed bill', () {
    _FakeApi refusingT1({String? nextParty = 'T1 #2'}) {
      final api = _waiter(_floor([_root(), _seat()]));
      api.refuse = (path, body) =>
          path == '/orders' && (body as Map)['table'] == 'T1' ? _billPrinted(nextParty: nextParty) : null;
      return api;
    }

    testWidgets('nothing is written, the cart stays, and the sentence says where the order goes',
        (tester) async {
      final (api, closed) = await _pumpPad(tester, refusingT1());
      await _addAndSend(tester);

      expect(api.writes, isEmpty);
      expect(closed, isEmpty, reason: 'the pad closed on a refusal');
      expect(find.byKey(const ValueKey('order-bill-printed')), findsOneWidget);
      expect(find.textContaining("T1's bill has already been printed"), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('order-take-on-next-party')),
              matching: find.text('Take it on T1 (next party)')),
          findsOneWidget);
      // The cart is exactly as it was.
      expect(find.text('Send order · 1 item'), findsOneWidget);
    });

    testWidgets('"Take it on T1 (next party)": the SAME cart, seated and sent on "T1 #2"', (tester) async {
      final (api, closed) = await _pumpPad(tester, refusingT1());
      await _addAndSend(tester);
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await _answerCovers(tester, '2');

      expect(api.attempts.map((w) => '${w.path} ${(w.body as Map)['table'] ?? (w.body as Map)['table_name']}').toList(),
          ['/orders T1', '/occupy-table T1 #2', '/orders T1 #2']);
      expect(api.writes.map((w) => w.path).toList(), ['/occupy-table', '/orders']);
      final sent = api.to('/orders').single.body as Map;
      expect(sent['table'], 'T1 #2');
      expect([for (final i in sent['items'] as List) (i as Map)['name']], ['Gulab Jamun']);
      expect(closed, [true]);
    });

    testWidgets('cancelling the covers question leaves the pad on "T1 #2", nothing written', (tester) async {
      final (api, closed) = await _pumpPad(tester, refusingT1());
      await _addAndSend(tester);
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(closed, isEmpty);
      expect(find.text('New order · T1 (next party)'), findsOneWidget);
      // A second try still asks for covers and still goes to the seat.
      await tester.tap(find.byKey(const ValueKey('order-send')));
      await tester.pumpAndSettle();
      await _answerCovers(tester, '2');
      expect((api.to('/orders').single.body as Map)['table'], 'T1 #2');
    });

    testWidgets('the late answer for T1\'s bill is not drawn once the pad is on "T1 #2"', (tester) async {
      // T1's running bill is slow to come back; the refusal and the move to
      // the seat happen first. When it lands, it is the PRINTED party's bill,
      // and drawing it would show the next party somebody else's money.
      final late = Completer<Object?>();
      final routes = _floor([_root(), _seat()]);
      routes['/bill-for-table'] = (path) => path.contains('%23')
          ? throw ApiException('Nothing on this table yet', 404)
          : late.future;
      final api = _waiter(routes);
      api.refuse = (path, body) =>
          path == '/orders' && (body as Map)['table'] == 'T1' ? _billPrinted() : null;
      await _pumpPad(tester, api);
      await _addAndSend(tester);
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('New order · T1 (next party)'), findsOneWidget);
      expect(find.byType(TableApcStrip), findsNothing);

      late.complete(_printedBill());
      await tester.pumpAndSettle();
      expect(find.byType(TableApcStrip), findsNothing,
          reason: "T1's bill was drawn as the next party's");
    });

    testWidgets('the search keeps its word and x while the running-bill strip goes and comes back', (tester) async {
      // "Take it on" drops T1's bill from the pad before the seat's is read,
      // so the strip above the search goes, and comes back when the seat's
      // (empty) bill lands. The unkeyed search row used to be rebuilt empty
      // each time, over a list still filtered on "gul".
      final seatBill = Completer<Object?>();
      final routes = _floor([_root(), _seat()]);
      routes['/bill-for-table'] = (path) => path.contains('%23') ? seatBill.future : _printedBill();
      routes['/menu'] = (_) => const [
            {'id': 'mi-1', 'name': 'Gulab Jamun', 'price': 120.0, 'category': 'Desserts'},
            {'id': 'mi-2', 'name': 'Masala Chai', 'price': 60.0, 'category': 'Drinks'},
          ];
      final api = _waiter(routes);
      api.refuse = (path, body) => path == '/orders' && (body as Map)['table'] == 'T1' ? _billPrinted() : null;
      await _pumpPad(tester, api);
      final search = find.byKey(const ValueKey('order-search'));
      final x = find.byKey(const ValueKey('order-search-clear'));
      String box() =>
          tester.widget<EditableText>(find.descendant(of: search, matching: find.byType(EditableText))).controller.text;
      expect(find.byType(TableApcStrip), findsOneWidget);

      await tester.enterText(search, 'gul');
      await tester.pumpAndSettle();
      expect(find.text('Masala Chai'), findsNothing);
      await _addAndSend(tester);
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('New order · T1 (next party)'), findsOneWidget);
      expect(find.byType(TableApcStrip), findsNothing, reason: "the seat's bill is still on its way");
      expect(box(), 'gul', reason: 'the strip going wiped the box');
      expect(x, findsOneWidget);
      expect(find.text('Masala Chai'), findsNothing);

      seatBill.complete(<String, dynamic>{'items': const []});
      await tester.pumpAndSettle();
      expect(find.byType(TableApcStrip), findsOneWidget);
      expect(box(), 'gul', reason: 'the strip coming back wiped the box');
      expect(x, findsOneWidget);
      expect(find.text('Masala Chai'), findsNothing);

      // And the x there clears the word and the filter together.
      await tester.tapAt(tester.getCenter(x),
          kind: defaultTargetPlatform == TargetPlatform.windows ? PointerDeviceKind.mouse : PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(box(), isEmpty);
      expect(find.text('Masala Chai'), findsOneWidget);
      expect(api.writes, isEmpty);
    }, variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android, TargetPlatform.windows}));

    // A PHONE. The tests above pump the pad at 420x900 with no keyboard, and
    // the refusal fitted there. At 360dp the server's sentence runs to seven
    // lines, and the usual flow (type in the search, Add, Send) left the
    // keyboard up when the refusal arrived: the header, capped at 55% of a
    // body the keyboard had halved, overflowed by 143px, and "Take it on" and
    // "Send order" were clipped out of reach.
    const phone = Size(360, 640);
    const keyboard = FakeViewPadding(bottom: 260);

    Future<void> searchAddSend(WidgetTester tester) async {
      await tester.showKeyboard(find.byKey(const ValueKey('order-search')));
      await tester.enterText(find.byKey(const ValueKey('order-search')), 'gul');
      await tester.pumpAndSettle();
      await _addAndSend(tester);
    }

    testWidgets('a 360dp phone with the keyboard up: nothing overflows, and both buttons are within reach',
        (tester) async {
      final (api, closed) = await _pumpPad(tester, refusingT1(), size: phone);
      tester.view.viewInsets = keyboard;
      await tester.pumpAndSettle();
      await searchAddSend(tester);

      expect(tester.takeException(), isNull, reason: 'the header overflowed');
      expect(find.byKey(const ValueKey('order-bill-printed')), findsOneWidget);
      expect(_reachable(tester, find.byKey(const ValueKey('order-take-on-next-party'))), isTrue,
          reason: '"Take it on T1 (next party)" is clipped out of reach');
      expect(_reachable(tester, find.byKey(const ValueKey('order-send'))), isTrue,
          reason: '"Send order" is clipped out of reach');

      // And it works from there.
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await _answerCovers(tester, '2');
      expect(api.writes.map((w) => w.path).toList(), ['/occupy-table', '/orders']);
      expect((api.to('/orders').single.body as Map)['table'], 'T1 #2');
      expect(closed, [true]);
    });

    testWidgets('Send puts the keyboard away, and the covers question does not bring it back', (tester) async {
      await _pumpPad(tester, refusingT1());
      await searchAddSend(tester);
      expect(find.byKey(const ValueKey('order-bill-printed')), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse, reason: 'the refusal arrived under the keyboard');

      // "Take it on", then Cancel: the dialog's own field had the keyboard, and
      // closing it must not hand the focus back to the search box.
      await tester.tap(find.byKey(const ValueKey('order-take-on-next-party')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse, reason: 'the search box took the keyboard back');
    });

    testWidgets('the sentence is scrolled into view, and the search is still there above it', (tester) async {
      await _pumpPad(tester, refusingT1(), size: phone);
      await searchAddSend(tester);
      expect(tester.takeException(), isNull);
      final sentence = find.byKey(const ValueKey('order-bill-printed'));
      final top = tester.getTopLeft(sentence) + const Offset(24, 16);
      final hit = tester.hitTestOnBinding(top).path.map((e) => e.target).toSet();
      expect(hit.contains(tester.renderObject(sentence)), isTrue,
          reason: 'the start of the sentence is below the fold of the header');

      // The fields above it scroll back: the search is squeezed, not gone.
      final search = find.byKey(const ValueKey('order-search'));
      await tester.drag(sentence, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(_reachable(tester, search), isTrue, reason: 'the search box cannot be reached while the refusal stands');
      expect(_reachable(tester, find.byKey(const ValueKey('order-take-on-next-party'))), isTrue);
    });

    testWidgets('with no seat to point at: the sentence, and no button', (tester) async {
      final (api, _) = await _pumpPad(tester, refusingT1(nextParty: null));
      await _addAndSend(tester);
      expect(find.textContaining('Ask a manager to add it and reprint the bill.'), findsOneWidget);
      expect(find.byKey(const ValueKey('order-take-on-next-party')), findsNothing);
      expect(api.writes, isEmpty);
    });

    testWidgets('read by its CODE: an older server\'s 409 refusal still gets the banner', (tester) async {
      final api = _waiter(_floor([_root(), _seat()]));
      api.refuse = (path, body) => path == '/orders' ? _billPrinted(status: 409) : null;
      await _pumpPad(tester, api);
      await _addAndSend(tester);
      expect(find.byKey(const ValueKey('order-take-on-next-party')), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('any other refusal is shown as before, with no next-party action', (tester) async {
      final api = _waiter(_floor([_root()]));
      api.refuse = (path, _) => path == '/orders' ? ApiException('Table is unoccupied', 400) : null;
      await _pumpPad(tester, api);
      await _addAndSend(tester);
      expect(find.text('Table is unoccupied'), findsWidgets);
      expect(find.byKey(const ValueKey('order-bill-printed')), findsNothing);
    });
  });

  // ==========================================================================
  // THE OUTBOX AND A PRINTED BILL
  // ==========================================================================

  group('a queued order the server refuses for a printed bill', () {
    Future<RestClient> queuedOrderForT1(_FakeApi api) async {
      final rest = await _signIn(api);
      await Outbox.instance.debugReset();
      api.offline = true;
      await expectLater(rest.post('/orders', {..._orderBody, 'table': 'T1'}), throwsA(isA<OfflineQueued>()));
      expect(Outbox.instance.pendingCount, 1);
      api.offline = false;
      return rest;
    }

    tearDown(() => Outbox.instance.debugReset());

    test('is PARKED on its first answer, with the server\'s sentence — and the next order goes straight out',
        () async {
      final api = _waiter(_floor([_root(), _seat()]));
      final rest = await queuedOrderForT1(api);
      api.refuse = (path, body) =>
          path == '/orders' && (body as Map)['table'] == 'T1' ? _billPrinted() : null;

      final drained = await rest.drainOutbox();

      expect(drained.outcome, OutboxDrainOutcome.blocked);
      final entry = Outbox.instance.entries.single;
      expect(entry.failed, isTrue);
      expect(entry.attempts, 0, reason: 'parked, not retried');
      expect(entry.failureStatus, billPrintedStatus);
      expect(entry.failureMessage, startsWith("T1's bill has already been printed"));
      expect(api.attempts.where((a) => a.path == '/orders'), hasLength(1));
      expect(Outbox.instance.hasPending, isFalse);

      // THE ORDERING RULE IS NOT HOLDING ANYTHING: an order for another table
      // is sent now, not queued behind the refusal.
      await rest.post('/orders', {..._orderBody, 'table': 'T2'});
      expect([for (final w in api.to('/orders')) (w.body as Map)['table']], ['T2']);
    });

    test('CONTROL — why the server does not answer 409: a 409 is retried, and holds every later write', () async {
      final api = _waiter(_floor([_root(), _seat()]));
      final rest = await queuedOrderForT1(api);
      api.refuse = (path, body) =>
          path == '/orders' && (body as Map)['table'] == 'T1' ? _billPrinted(status: 409) : null;

      final drained = await rest.drainOutbox();

      expect(drained.outcome, OutboxDrainOutcome.retryLater);
      final entry = Outbox.instance.entries.single;
      expect([entry.failed, entry.attempts], [false, 1]);
      await expectLater(rest.post('/orders', {..._orderBody, 'table': 'T2'}), throwsA(isA<OfflineQueued>()));
      expect(api.to('/orders'), isEmpty);
    });
  });

  // ==========================================================================
  // A MANAGER'S ADDITION TO A PRINTED BILL
  // ==========================================================================

  group('a senior role adds to a printed bill: told to reprint, with the Reprint', () {
    testWidgets('from the pad: it closes as sent, the line stays, and Reprint prints THAT table', (tester) async {
      final api = _owner(_floor([_root(), _seat()]));
      api.replies['/orders'] = (_) => _reprintReply({'id': 'o-9'});
      final (_, closed) = await _pumpPad(tester, api);
      await _addAndSend(tester);

      expect(closed, [true]);
      expect(find.byType(OrderEntryScreen), findsNothing);
      expect(find.text(_reprintT1), findsOneWidget);
      expect(api.to('/print/bill'), isEmpty, reason: 'nothing prints until it is asked for');

      await tester.tap(find.byKey(const ValueKey('reprint-needed-action')));
      await tester.pumpAndSettle();
      expect(api.to('/print/bill').single.body, {'table_name': 'T1'});
      expect(find.text('Printing bill…'), findsOneWidget);
    });

    testWidgets('from the pad: an answer with no flag closes exactly as before, no line', (tester) async {
      final api = _owner(_floor([_root(printed: false)]));
      api.replies['/orders'] = (_) => {'id': 'o-9'};
      final (_, closed) = await _pumpPad(tester, api);
      await _addAndSend(tester);
      expect(closed, [true]);
      expect(find.byKey(const ValueKey('reprint-needed')), findsNothing);
    });

    testWidgets('a MERGE into the printed table: one line says both, and Reprint prints it', (tester) async {
      final api = _owner(_floor([_root(), _root(name: 'T5', printed: false)]));
      api.replies['/bills/merge'] = (_) => _reprintReply({'success': true, 'total_amt': 1650, 'moved_orders': 1});
      await _mountFloor(tester, api);
      await tester.tap(_rootTile);
      await tester.pumpAndSettle();
      await _reveal(tester, find.widgetWithText(ForkButton, 'Merge'));
      await tester.tap(find.widgetWithText(ForkButton, 'Merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table T5'));
      await tester.pumpAndSettle();

      expect(api.to('/bills/merge').single.body, {'from_table': 'T5', 'to_table': 'T1'});
      // Asked ABOVE the sheet — a snackbar would sit under its barrier.
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Merged Table T5 into T1. $_reprintT1')),
          findsOneWidget);
      expect(api.to('/print/bill'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('reprint-needed-action')));
      await tester.pumpAndSettle();
      expect(api.to('/print/bill').single.body, {'table_name': 'T1'});
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('…and "Not now" prints nothing', (tester) async {
      final api = _owner(_floor([_root(), _root(name: 'T5', printed: false)]));
      api.replies['/bills/merge'] = (_) => _reprintReply({'success': true, 'total_amt': 1650, 'moved_orders': 1});
      await _mountFloor(tester, api);
      await tester.tap(_rootTile);
      await tester.pumpAndSettle();
      await _reveal(tester, find.widgetWithText(ForkButton, 'Merge'));
      await tester.tap(find.widgetWithText(ForkButton, 'Merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table T5'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Not now'));
      await tester.pumpAndSettle();
      expect(api.to('/print/bill'), isEmpty);
    });

    testWidgets('a MERGE with no flag reads exactly as it did', (tester) async {
      final api = _owner(_floor([_root(printed: false), _root(name: 'T5', printed: false)]));
      api.replies['/bills/merge'] = (_) => {'success': true, 'total_amt': 1650, 'moved_orders': 1};
      await _mountFloor(tester, api);
      await tester.tap(_rootTile);
      await tester.pumpAndSettle();
      await _reveal(tester, find.widgetWithText(ForkButton, 'Merge'));
      await tester.tap(find.widgetWithText(ForkButton, 'Merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table T5'));
      await tester.pumpAndSettle();
      expect(find.text('Merged Table T5 into T1.'), findsOneWidget);
      expect(find.byKey(const ValueKey('reprint-needed')), findsNothing);
    });

    test('the wiring: every write that can grow a printed bill reads the flag', () {
      String read(String rel) => File(rel).readAsStringSync().replaceAll(String.fromCharCode(13), '');
      final pad = read('lib/screens/order_entry.dart');
      // 2.0.2 (client items 1 and 2): the same post, carrying the confirmed
      // "add to printed bill" flag when — and only when — it was chosen.
      expect(pad, contains("final sent = await widget.rest.post('/orders', {\n"
          '          ...base,\n'
          "          'table': _table,\n"
          '          if (_addsToPrinted) addToPrintedBillKey: true,\n'
          '        });\n'
          '        reprint = ReprintNeeded.parse(sent, fallbackTable: _table);'));
      expect(pad, contains('showReprintNeeded(ScaffoldMessenger.of(context), widget.rest, reprint);'));
      // The refusal is keyed on its code, never on a status.
      expect(pad, contains('final refusal = e is ApiException ? BillPrintedRefusal.parse(e.body) : null;'));
      expect(pad, isNot(contains('e.status == 409')));
      final mod = read('lib/screens/modules.dart');
      expect(mod, contains("final res = await widget.rest.post('/bills/move-item',"));
      // Client item 4: both moves read EVERY reprint their answer asks for (a
      // move changes two bills) through one helper, which offers each in turn.
      expect(mod, contains('await _afterMoveReprints(messenger, res, fallbackTable: dest, lead: said);'));
      expect(mod, contains('final reprints = ReprintNeeded.parseAll(res, fallbackTable: fallbackTable);'));
      expect(mod, contains("final res = await widget.rest.post(\n        '/tables/move-order',"));
      expect(mod, contains('await askToReprint(context, widget.rest, reprint,\n          messenger: messenger,\n          lead: first ? lead : null,'));
      expect(mod, contains("final res = await widget.rest.post('/bills/merge',"));
      expect(mod, contains('final reprint = ReprintNeeded.parse(res, fallbackTable: _name);'));
      expect(mod, contains('printHere: reprint.table == _name ? () => _thermalPrint(messenger) : null);'));
      // …and the table-wise chart folds through the shared helper.
      expect(mod, contains('final tableRevenue = revenueByTable(orders);'));
      expect(mod, isNot(contains("'Table \${_s(o as Map, 'table_name', '—')}'")));
    });
  });

  // ==========================================================================
  // THE PRINT SAYS WHERE THE NEXT PARTY SITS
  // ==========================================================================

  group('a print names the next party\'s seat', () {
    testWidgets('an owner\'s print: the till is told, and the floor behind the sheet is re-read',
        (tester) async {
      final tables = <Map<String, dynamic>>[_root(printed: false)];
      final routes = _floor(tables);
      final api = _owner(routes);
      api.replies['/print/bill'] = (_) {
        tables.add(_seat());
        return {
          'success': true,
          'next_party_table': 'T1 #2',
          'next_party_message': 'Seat the next party at T1 (next party).',
        };
      };
      await _mountFloor(tester, api);
      expect(_seatTile, findsNothing);
      await tester.tap(_rootTile);
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();

      expect(api.to('/print/bill'), hasLength(1));
      expect(find.text('Printing bill… Seat the next party at T1 (next party).'), findsOneWidget);
      // The sheet stays open for the manager; the floor under it now has the seat.
      expect(find.text('Table T1'), findsOneWidget);
      expect(_seatTile, findsOneWidget);
    });

    testWidgets('a print with no seat named reads exactly as it did', (tester) async {
      final api = _owner(_floor([_root(printed: false)]));
      await _mountFloor(tester, api);
      await tester.tap(_rootTile);
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.tap(find.byKey(const ValueKey('table-manager-print-bill')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(find.text('Printing bill…'), findsOneWidget);
    });
  });
}
