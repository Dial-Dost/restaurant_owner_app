import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// C3 — "ONLY ONCE" IS THE SERVER'S FACT, NOT THIS DEVICE'S MEMORY.
///
/// THE PROBLEM WITH WHERE IT USED TO LIVE. A rule about "once" that each device
/// answers privately means something different on each of them: it survives a
/// back-navigation and an app restart, and it does NOT survive a reinstall, a
/// second tablet, or a colleague's login. A waiter who wants a second bill only
/// has to walk to the other till. So the memory in [PrintedBills] is a courtesy
/// and says so; the answer, where there is one, comes off the wire.
///
/// THE FIELDS THIS CLIENT READS ARE THE CONTRACT — see
/// [m.serverSaysBillPrinted]. They are needed in TWO places, not one:
/// `/bill-for-table` (the sheet, which decides whether to draw the button) and
/// the `/get-tables` row (the grid, which decides whether the table is still on
/// this waiter's screen). Without the second, "clear from their view" survives
/// on the device that printed and nowhere else.
///
/// AND IT FAILS SAFE. Silence means NOT printed, so the waiter gets their
/// button. The alternative — reading silence as "already printed" — leaves
/// somebody standing at a table with a guest waiting and no way to produce a
/// bill, which is a worse outage than a second copy of one.

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.actions = const ['*'], this.role = 'admin', this.waiterOnly});

  final Map<String, dynamic> routes;
  final List<String> actions;
  final String role;
  final bool? waiterOnly;

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
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
          'actions_set': actions,
          'action_names': const ['View Orders', 'View Tables', 'Create Order'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') return <String, dynamic>{'success': true};
    if (routes.containsKey(path)) return routes[path];
    final prefixes = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (prefixes.isNotEmpty) return routes[prefixes.first];
    throw ApiException('No fake route for $path', 404);
  }
}

Map<String, dynamic> _table({Map<String, dynamic> printState = const {}}) => {
      'table_name': 'T1',
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': true,
      'reserved': false,
      'num_covers': 3,
      'covers': 3,
      'table_total': 1380.0,
      'table_apc': 460.0,
      'apc_status': 'red',
      'waiter_name': 'Ravi K',
      ...printState,
    };

/// CLIENT ITEM 6 — the next party's seat a current backend lists beside a
/// printed T1. Its own row, with its own (unprinted) print state.
const Map<String, dynamic> _nextPartySeat = {
  'table_name': 'T1 #2',
  'parent_table': 'T1',
  'party_no': 2,
  'display_name': 'T1',
  'capacity': 4,
  'max_capacity': 4,
  'section': 'Main',
  'occupied': false,
  'reserved': false,
  'print_count': 0,
  'bill_printed_at': null,
  'printed_at': null,
};

final Finder _printedRow = find.byKey(const ValueKey('table-title-T1'));
final Finder _nextPartyRow = find.byKey(const ValueKey('table-title-T1 #2'));

Map<String, dynamic> _routes({Map<String, dynamic> printState = const {}, bool nextParty = false}) => {
      '/get-tables': [_table(printState: printState), if (nextParty) _nextPartySeat],
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {
        'sections': [
          {'section': 'Main'},
        ],
      },
      '/bill-for-table': {
        'bill_id': 'bill-1',
        'total_amt': 1200.0,
        'subtotal': 1200.0,
        'discount': 0.0,
        'service_charge': 0.0,
        'service_charge_waived': false,
        'tax_total': 0.0,
        'grand_total': 1200.0,
        'nc_total': 0.0,
        'covers': 3,
        'apc': 400.0,
        'target_apc': 500.0,
        'apc_status': 'red',
        'order_ids': const ['order-1'],
        'items': const [
          {'name': 'Paneer Tikka', 'price': 320.0, 'quantity': 2},
        ],
        'first_order_at': '2026-09-11T10:00:00Z',
        'last_order_at': '2026-09-11T10:00:00Z',
        ...printState,
      },
      '/restaurant/settings': {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': {'outlet_add': ''},
      '/menu': const <dynamic>[],
    };

/// [deviceMemory] seeds [PrintedBills]' on-disk record for res-1/out-1 — the
/// per-device memory, as it would be found on a tablet that printed T1 earlier.
/// It is stored lower-cased because that is how [PrintedBills] keys it.
Future<RestClient> _signIn(_FakeApi api, {List<String> deviceMemory = const []}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (deviceMemory.isNotEmpty)
      'rd_printed_bills_v1:res-1/out-1': [
        for (final n in deviceMemory) n.toLowerCase(),
      ],
  });
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
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

Future<void> _mountFloor(WidgetTester tester, _FakeApi api,
    {List<String> deviceMemory = const []}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api, deviceMemory: deviceMemory);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
}

/// The backend checkout, when it is next to this one. Absent in a Flutter-only
/// build, where the contract group skips with a stated reason rather than
/// failing — the same rule simulation_catalogue_pin_test.dart runs on.
File _backend(String rel) => File('../Restaurant_Backend/$rel');

void main() {
  setUp(PrintedBills.instance.resetForTest);
  tearDown(PrintedBills.instance.resetForTest);

  group('what counts as "the server said it is printed"', () {
    test('an instant under any of the accepted names', () {
      for (final k in const ['bill_printed_at', 'printed_at', 'last_printed_at']) {
        expect(m.serverSaysBillPrinted({k: '2026-09-11T10:42:00Z'}), isTrue,
            reason: k);
      }
    });

    test('a positive count, for a server that counts rather than stamps', () {
      expect(m.serverSaysBillPrinted({'print_count': 1}), isTrue);
      expect(m.serverSaysBillPrinted({'print_count': '2'}), isTrue);
      expect(m.serverSaysBillPrinted({'print_count': 0}), isFalse);
    });

    test('silence, a null and an empty string all mean NOT printed', () {
      // FAILING SAFE. Every one of these is a backend that has not shipped the
      // fields yet, and every one of them must leave the waiter able to bill the
      // table they are standing at.
      expect(m.serverSaysBillPrinted(null), isFalse);
      expect(m.serverSaysBillPrinted(<String, dynamic>{}), isFalse);
      expect(m.serverSaysBillPrinted({'bill_printed_at': null}), isFalse);
      expect(m.serverSaysBillPrinted({'bill_printed_at': '  '}), isFalse);
      expect(m.serverSaysBillPrinted({'print_count': 'lots'}), isFalse);
    });
  });

  group('the grid retires a table on the server\'s word, not this device\'s', () {
    testWidgets('a waiter loses a table the SERVER says is printed', (tester) async {
      // NOTHING WAS PRINTED ON THIS DEVICE. The record can only have come from
      // the other till, or from before this app was reinstalled — which is
      // exactly the case a per-device memory cannot answer.
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'bill_printed_at': '2026-09-11T10:42:00Z'}),
            role: 'waiter', actions: const ['a1'], waiterOnly: true),
      );
      expect(find.text('T1'), findsNothing);
    });

    // CHANGED ON PURPOSE FOR CLIENT ITEM 6: the PRINTED PARTY leaves, and the
    // number stays as the next party's seat, decided on that row's own print
    // state — which the server says is not printed.
    testWidgets('…and keeps its NUMBER through the next party\'s seat', (tester) async {
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'bill_printed_at': '2026-09-11T10:42:00Z'}, nextParty: true),
            role: 'waiter', actions: const ['a1'], waiterOnly: true),
      );
      expect(_printedRow, findsNothing);
      expect(_nextPartyRow, findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('Next party'), findsOneWidget);
    });

    testWidgets('and keeps it when the server has said nothing', (tester) async {
      await _mountFloor(
        tester,
        _FakeApi(_routes(), role: 'waiter', actions: const ['a1'], waiterOnly: true),
      );
      expect(find.text('T1'), findsOneWidget);
    });

    testWidgets('an owner keeps the table either way', (tester) async {
      // C3 retires a table from the WAITER's view. Nobody else loses a row, a
      // control or a reprint — the bill is still owing and still on every
      // manager's screen, which is the whole difference between "clear from
      // their view" and "clear the table".
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'bill_printed_at': '2026-09-11T10:42:00Z'}),
            actions: const ['*']),
      );
      expect(find.text('T1'), findsOneWidget);
      // …and sees the next party's seat BESIDE it, not instead of it.
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'bill_printed_at': '2026-09-11T10:42:00Z'}, nextParty: true),
            actions: const ['*']),
      );
      expect(_printedRow, findsOneWidget);
      expect(_nextPartyRow, findsOneWidget);
    });
  });

  // ==========================================================================
  // THREE ANSWERS, NOT TWO — and which one wins when they disagree
  // ==========================================================================

  group('printed / not printed / nobody asked', () {
    test('a row carrying NONE of the keys is "nobody asked"', () {
      // The only case the per-device memory is allowed to fill. A backend older
      // than these fields, and nothing else.
      expect(m.serverBillPrintState(null), isNull);
      expect(m.serverBillPrintState(<String, dynamic>{}), isNull);
      expect(m.serverBillPrintState({'table_name': 'T1', 'occupied': true}), isNull);
    });

    test('a row carrying a key HAS answered, even when the answer is no', () {
      // THE WHOLE DEFECT IN ONE LINE. `print_count: 0` is the server describing
      // an unprinted bill — the ordinary case on every table in the restaurant —
      // and reading it as silence hands the answer straight back to the device.
      expect(m.serverBillPrintState({'print_count': 0}), isFalse);
      expect(m.serverBillPrintState({'bill_printed_at': null}), isFalse);
      expect(m.serverBillPrintState({'printed_at': ''}), isFalse);
      expect(m.serverBillPrintState({'print_count': 'lots'}), isFalse);
    });

    test('and a positive answer under any accepted spelling', () {
      for (final k in const ['bill_printed_at', 'printed_at', 'last_printed_at']) {
        expect(m.serverBillPrintState({k: '2026-09-11T10:42:00Z'}), isTrue, reason: k);
      }
      expect(m.serverBillPrintState({'print_count': 1}), isTrue);
      expect(m.serverBillPrintState({'print_count': '2'}), isTrue);
    });

    test('every key the client reads is on the published list', () {
      // The list is what the contract test below pins the backend against, so
      // it may not drift from what the reader actually accepts.
      for (final k in m.billPrintStateKeys) {
        expect(m.serverBillPrintState({k: 'x'}), isNotNull, reason: k);
      }
    });
  });

  group('when the server and this tablet disagree, the SERVER decides', () {
    testWidgets('server says NOT printed, this device remembers printing it',
        (tester) async {
      // HOW A REAL TABLET GETS HERE: T1 was printed and settled at 19:10, the
      // table turned over at 19:25, and the new party's bill has never been
      // printed. The server says so (`print_count: 0`). The old `||` read the
      // stale local record and kept T1 off this waiter's floor for the rest of
      // the evening — on this tablet only, so nobody else could see the fault.
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'print_count': 0}),
            role: 'waiter', actions: const ['a1'], waiterOnly: true),
        deviceMemory: const ['T1'],
      );
      expect(find.text('T1'), findsOneWidget,
          reason: 'the server is describing the bill the guest is sitting in '
              'front of; a tablet memory does not get to overrule it');
    });

    testWidgets('server says PRINTED, this device has no memory of it',
        (tester) async {
      // The other direction, and the reason the server had to be asked at all:
      // the print happened on the till at the pass, not here.
      await _mountFloor(
        tester,
        _FakeApi(_routes(printState: const {'print_count': 2}, nextParty: true),
            role: 'waiter', actions: const ['a1'], waiterOnly: true),
      );
      // CHANGED ON PURPOSE FOR CLIENT ITEM 6: the printed PARTY is gone and the
      // next party's seat is what reads "T1".
      expect(_printedRow, findsNothing);
      expect(_nextPartyRow, findsOneWidget);
    });

    testWidgets('no print state at all — the device memory still answers',
        (tester) async {
      // THE FALLBACK, EXERCISED. An app that auto-updated ahead of its backend
      // must behave exactly as it did the day before.
      await _mountFloor(
        tester,
        _FakeApi(_routes(), role: 'waiter', actions: const ['a1'], waiterOnly: true),
        deviceMemory: const ['T1'],
      );
      expect(find.text('T1'), findsNothing);
    });

    testWidgets('and an owner keeps the row through every one of those',
        (tester) async {
      // AN ADMIN MUST LOSE NOTHING. C3 retires a table from a WAITER's view;
      // the bill is still owing and still on every manager's screen.
      for (final state in const <Map<String, dynamic>>[
        {'print_count': 0},
        {'print_count': 2},
        <String, dynamic>{},
      ]) {
        await _mountFloor(
          tester,
          _FakeApi(_routes(printState: state), actions: const ['*']),
          deviceMemory: const ['T1'],
        );
        expect(find.text('T1'), findsOneWidget, reason: '$state');
        PrintedBills.instance.resetForTest();
      }
    });
  });

  // ==========================================================================
  // THE FIELD MUST ACTUALLY BE SENT
  // ==========================================================================

  group('the backend really ships print state on both payloads', () {
    // WHY THIS TEST EXISTS AND NOT A COMMENT. Four times in this project
    // something was built against a field nobody sent, and every time the
    // client "worked" — it just quietly answered from somewhere worse. A reader
    // with a fallback cannot fail loudly by itself, so the loud failure has to
    // be here: this parses the BACKEND'S OWN SOURCE and goes red the day either
    // payload stops carrying print state.
    //
    // It reads the TypeScript as text on purpose. A generated snapshot would be
    // a third source of truth to keep in step, and the point is to have none.

    // Line endings normalised: the backend checkout is CRLF on Windows and LF
    // in CI, and the reader below anchors on a newline.
    String? read(String rel) {
      final f = _backend(rel);
      if (!f.existsSync()) return null;
      // Carriage returns dropped: the backend checkout is CRLF on Windows and
      // LF in CI, and the reader below anchors on a newline.
      return f.readAsStringSync().replaceAll(String.fromCharCode(13), '');
    }

    /// One exported function, whole — its declaration (where a TypeScript
    /// return type lives) AND its body (where a row is actually assembled),
    /// from its name to the next top-level `export`.
    ///
    /// BOTH HALVES ON PURPOSE. A field can be promised in the return type and a
    /// field can be spread into the row; either counts as sending it, and
    /// insisting on one spelling would make this a test of style rather than of
    /// contract.
    String? sourceOf(String source, String fn) {
      final at = source.indexOf('export async function $fn(');
      if (at < 0) return null;
      final end = source.indexOf('\nexport ', at + 1);
      return end < 0 ? source.substring(at) : source.substring(at, end);
    }

    /// One top-level statement, whole — from [start] to the next line that
    /// begins a new one. Used for an Express handler, which is a call
    /// expression rather than a function declaration.
    String? blockFrom(String source, String start) {
      final at = source.indexOf(start);
      if (at < 0) return null;
      final end = source.indexOf('\napp.', at + 1);
      return end < 0 ? source.substring(at) : source.substring(at, end);
    }

    test("GetBillForTable — the sheet's answer", () {
      final src = read('database_supabase.ts');
      if (src == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      final decl = sourceOf(src, 'GetBillForTable');
      expect(decl, isNotNull, reason: 'GetBillForTable is gone or renamed');
      expect(m.billPrintStateKeys.any(decl!.contains), isTrue,
          reason: 'the bill payload must carry one of ${m.billPrintStateKeys}, '
              "or the sheet silently falls back to this device's memory");
    });

    test("/get-tables — the floor grid's answer", () {
      // THE ONE THAT WAS MISSING, AND THE FOURTH TIME IN THIS PROJECT SOMETHING
      // WAS BUILT AGAINST A FIELD NOBODY SENT. /get-tables sends GetTables'
      // rows, so print state has to be put on them in one of exactly two
      // places: the row itself (database_supabase.ts) or the handler that
      // sends it (routes/tables.ts). BOTH are searched so this pins the
      // CONTRACT and not a choice of file.
      //
      // Until one of them carries it, the floor grid is reading a field nobody
      // sends and quietly answering from a per-device memory that survives
      // neither a reinstall nor a second tablet — which is precisely the
      // failure this test exists to make loud.
      final db = read('database_supabase.ts');
      final routes = read('routes/tables.ts');
      if (db == null && routes == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      final getTables = db == null ? null : sourceOf(db, 'GetTables');
      final handler = routes == null ? null : blockFrom(routes, 'app.get("/get-tables"');
      expect(getTables ?? handler, isNotNull,
          reason: 'neither GetTables nor the /get-tables handler was found — '
              'one of them has been renamed');
      final searched = '${getTables ?? ''}\n${handler ?? ''}';
      expect(m.billPrintStateKeys.any(searched.contains), isTrue,
          reason: 'the /get-tables row must carry one of '
              '${m.billPrintStateKeys}. Until it does, the floor grid is '
              'reading a field nobody sends and answering from per-device '
              'memory that survives neither a reinstall nor a second device.');
    });
  });
}
