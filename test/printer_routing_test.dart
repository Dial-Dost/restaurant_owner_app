import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/net_raw_printer.dart';
import 'package:restaurant_owner_app/services/printer_service.dart';

/// TWO THINGS THIS FILE PINS DOWN.
///
/// 1. PRINTER ROLES. A real restaurant has more than one thermal printer and
///    each prints a different thing — the pass, the bar, the till. The backend
///    has always stamped every `bill:print` with the facts needed to tell them
///    apart (`kind`, and on a kitchen docket the `station` buildKotBase64 split
///    it by), so routing is a lookup. The property that matters is not that a
///    rule works; it is that the ABSENCE of a rule is safe: an outlet that
///    configures nothing must print exactly what it printed before this existed,
///    and a docket for a station nobody wrote a rule for must come out somewhere
///    rather than be held or dropped.
///
/// 2. PRINTING FROM A PHONE. `PrinterService.supported` used to be
///    `WinRawPrinter.supported`, so the app answered "Printing is only supported
///    on Windows." everywhere else. That was a statement about the TRANSPORT.
///    The backend renders the finished ESC/POS docket itself and pushes the
///    bytes down `bill:print`; a Windows till writes them to a spooler queue and
///    a phone can write the same bytes to a printer's port 9100 socket. The
///    danger in making that true is the CLAIM: a device that takes jobs off the
///    outlet's queue and then cannot print them loses every one of those
///    receipts. So a phone with no printer configured must stay a viewer, and
///    must become a real client the moment it has somewhere to print.

class _FakeApi extends ApiClient {
  final List<Map<String, dynamic>> acks = <Map<String, dynamic>>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'outlet-1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    if (path == '/print/ack') {
      acks.add(Map<String, dynamic>.from(body as Map));
      return <String, dynamic>{'success': true};
    }
    throw ApiException('No fake route for $path', 404);
  }
}

/// A Windows spooler that records the queue name it was handed and accepts
/// everything. A spooler that REFUSES is spelled `write: (_, _) => false` at the
/// two tests that need one — a flag here would be one more thing to read past in
/// the dozen that do not.
class _Spooler {
  final List<String> printers = <String>[];
  bool call(String printer, List<int> bytes) {
    printers.add(printer);
    return true;
  }
}

/// A network printer that records the address it was dialled at, and can be told
/// to fail with a specific, human-readable reason.
class _Net {
  _Net({this.error});

  /// Non-null makes every send fail with this message — the shape a real
  /// SocketException is turned into by NetworkPrinter.
  String? error;
  final List<String> dialled = <String>[];
  final List<int> byteCounts = <int>[];

  Future<String?> call(String host, int port, List<int> bytes) async {
    dialled.add('$host:$port');
    byteCounts.add(bytes.length);
    return error;
  }
}

Future<AuthController> _signIn(_FakeApi api) async {
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

Map<String, dynamic> _event({
  required String billId,
  String? jobId,
  String? station,
  bool kot = false,
}) =>
    <String, dynamic>{
      'billId': billId,
      'escBase64': base64Encode(utf8.encode('DOCKET')),
      if (kot || station != null) 'kind': 'kot',
      'station': ?station,
      'jobId': jobId,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // -------------------------------------------------------------------------
  // 1. The shipped state: no rules at all.
  // -------------------------------------------------------------------------

  group('an outlet that configures nothing prints exactly as it did before', () {
    test('bills and every kitchen docket go to the one default printer', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(installed: <String>['Test Printer', 'Bar Printer']);

      await svc.onPrintEvent(_event(billId: 'B-1', jobId: 'j1'));
      await svc.onPrintEvent(_event(billId: 'B-2', jobId: 'j2', station: 'TANDOOR'));
      await svc.onPrintEvent(_event(billId: 'B-3', jobId: 'j3', station: 'BAR'));
      await pumpEventQueue();

      // One printer, everything on it — which is the right answer for the small
      // place this app mostly runs in, and the behaviour that shipped.
      expect(spooler.printers, <String>['Test Printer', 'Test Printer', 'Test Printer']);
    });

    test('a docket for a station with no rule falls through to the default, never nowhere', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(
        routes: <String, String>{PrintRole.kotStation('BAR'): 'Bar Printer'},
        installed: <String>['Test Printer', 'Bar Printer'],
      );

      await svc.onPrintEvent(_event(billId: 'B-4', jobId: 'j4', station: 'TANDOOR'));
      await pumpEventQueue();

      // THE SAFETY PROPERTY OF THE WHOLE FEATURE. A rule for the bar must not
      // turn the tandoor's docket into a held job or a dropped one.
      expect(spooler.printers.single, 'Test Printer');
      expect(svc.queue, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 2. Rules, most specific first.
  // -------------------------------------------------------------------------

  group('what each printer prints', () {
    test('bill, any-kitchen and per-station rules resolve in that order', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(
        routes: <String, String>{
          PrintRole.bill: 'Till Printer',
          PrintRole.anyKot: 'Pass Printer',
          PrintRole.kotStation('BAR'): 'Bar Printer',
        },
        installed: <String>['Test Printer', 'Till Printer', 'Pass Printer', 'Bar Printer'],
      );

      await svc.onPrintEvent(_event(billId: 'B-5', jobId: 'j5'));
      await svc.onPrintEvent(_event(billId: 'B-6', jobId: 'j6', station: 'TANDOOR'));
      await svc.onPrintEvent(_event(billId: 'B-7', jobId: 'j7', station: 'BAR'));
      await pumpEventQueue();

      expect(spooler.printers, <String>['Till Printer', 'Pass Printer', 'Bar Printer']);
    });

    test('a station typed in any case is one rule', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(
        routes: <String, String>{PrintRole.kotStation(' bar '): 'Bar Printer'},
        installed: <String>['Test Printer', 'Bar Printer'],
      );

      // groupKotItemsByStation keys its buckets on the menu's own spelling, so
      // the rule has to survive "Bar", "bar " and "BAR" being the same station.
      await svc.onPrintEvent(_event(billId: 'B-8', jobId: 'j8', station: 'Bar'));
      await pumpEventQueue();
      expect(spooler.printers.single, 'Bar Printer');
    });

    test('one printer may hold several roles', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(
        routes: <String, String>{
          PrintRole.bill: 'One Printer',
          PrintRole.anyKot: 'One Printer',
        },
        installed: <String>['Test Printer', 'One Printer'],
      );

      await svc.onPrintEvent(_event(billId: 'B-9', jobId: 'j9'));
      await svc.onPrintEvent(_event(billId: 'B-10', jobId: 'j10', station: 'TANDOOR'));
      await pumpEventQueue();
      expect(spooler.printers, <String>['One Printer', 'One Printer']);
    });

    test('a rule naming a printer that is not installed falls back to the default', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(
        // The bar till's printer, on a rule that was copied to this machine — or
        // a queue somebody uninstalled. Honouring it would hand the spooler a
        // name it must refuse: three failed attempts and a 'failed' ack for a
        // receipt that could have printed perfectly well at the till.
        routes: <String, String>{PrintRole.anyKot: 'Printer That Left'},
        installed: <String>['Test Printer'],
      );

      await svc.onPrintEvent(_event(billId: 'B-11', jobId: 'j11', station: 'TANDOOR'));
      await pumpEventQueue();
      expect(spooler.printers.single, 'Test Printer');
    });

    test('a rule is saved per outlet, so a second branch does not inherit it', () async {
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: _Spooler().call);
      svc.debugSetRouting(installed: <String>['Test Printer', 'Bar Printer']);
      await svc.setRoute(PrintRole.anyKot, 'Bar Printer');

      final prefs = await SharedPreferences.getInstance();
      // The values are WINDOWS QUEUE NAMES and printer addresses — facts about
      // one machine on one LAN — so they are stored on the device and keyed by
      // the outlet it joined, never on the server.
      expect(prefs.getStringList('printer_routes_outlet-1'), <String>['kot=Bar Printer']);
      expect(prefs.getStringList('printer_routes_outlet-2'), isNull);
    });

    test('clearing a rule sends its jobs back to the default, not to nowhere', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(auth: await _signIn(_FakeApi()), write: spooler.call);
      svc.debugSetRouting(installed: <String>['Test Printer', 'Bar Printer']);
      await svc.setRoute(PrintRole.anyKot, 'Bar Printer');
      await svc.clearRoute(PrintRole.anyKot);

      await svc.onPrintEvent(_event(billId: 'B-12', jobId: 'j12', station: 'BAR'));
      await pumpEventQueue();
      expect(spooler.printers.single, 'Test Printer');
      expect(svc.routes, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 3. Printing from a phone.
  // -------------------------------------------------------------------------

  group('a phone is a print client, not a viewer', () {
    test('with no printer configured it claims nothing and advertises no version', () async {
      final phone = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => false,
        spooler: false, // Android: winspool does not exist
      );

      // It CAN print in principle — the socket transport exists on this platform
      // — but it has nowhere to send anything, so it must not be handed the
      // outlet's backlog. Claiming there would take jobs off the queue the real
      // till is waiting on and fail every one of them.
      expect(phone.supported, isTrue);
      expect(phone.hasSpooler, isFalse);
      expect(phone.canClaimJobs, isFalse);
      expect(phone.joinPayload('res-1', 'outlet-1').containsKey('agentVersion'), isFalse);
    });

    test('adding a printer address turns it into a claiming agent', () async {
      final phone = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => false,
        netWrite: _Net().call,
        spooler: false,
        printer: null,
      );
      expect(phone.canClaimJobs, isFalse);

      expect(await phone.addNetworkPrinter('192.168.1.50', 9100), isNull);

      expect(phone.canClaimJobs, isTrue);
      expect(phone.joinPayload('res-1', 'outlet-1')['agentVersion'], PrinterService.agentVersion);
      expect(phone.networkPrinters, <String>['tcp://192.168.1.50:9100']);
      // AND IT ACTUALLY PRINTS. The first printer on a device that has no other
      // becomes its default — otherwise adding one is a dead control: the
      // address is saved, the agent connects, and every docket sits in the queue
      // saying "No printer selected" because nothing routes to it yet.
      expect(phone.selectedPrinter, 'tcp://192.168.1.50:9100');
    });

    test('adding a printer to a till never steals its existing default', () async {
      final net = _Net();
      final till = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => true,
        netWrite: net.call,
        printer: 'Till Printer',
      );
      till.debugSetRouting(installed: <String>['Till Printer']);

      await till.addNetworkPrinter('10.0.0.7', 9100);

      // A till whose default is a USB printer must not silently start sending
      // its bills across the network because somebody added a kitchen printer.
      expect(till.selectedPrinter, 'Till Printer');
      expect(till.targets, <String>['Till Printer', 'tcp://10.0.0.7:9100']);
    });

    test('a Windows till still claims with no printer selected, exactly as it always did', () async {
      // The rule is capability, not configuration: a till holds its jobs until a
      // queue is chosen and then prints them. Requiring a selection before it
      // could claim would be a behaviour change dressed as a safety fix.
      final till = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => true,
        printer: null,
      );
      expect(till.canClaimJobs, isTrue);
    });

    test('a docket routed to an address goes over the socket, not the spooler', () async {
      final spooler = _Spooler();
      final net = _Net();
      final api = _FakeApi();
      final svc = PrinterService.forTest(
        auth: await _signIn(api),
        write: spooler.call,
        netWrite: net.call,
        spooler: false,
        printer: null,
        networkPrinters: const <String>['tcp://192.168.1.50:9100'],
      );
      svc.debugSetRouting(routes: <String, String>{PrintRole.anyKot: 'tcp://192.168.1.50:9100'});

      await svc.onPrintEvent(_event(billId: 'B-13', jobId: 'j13', station: 'TANDOOR'));
      await pumpEventQueue();

      expect(net.dialled.single, '192.168.1.50:9100');
      expect(net.byteCounts.single, utf8.encode('DOCKET').length);
      expect(spooler.printers, isEmpty);
      // The ack follows the transport accepting the bytes, on this path exactly
      // as on the spooler path — one contract, two transports.
      expect(api.acks.single, <String, dynamic>{'jobId': 'j13', 'result': 'printed'});
    });

    test('a mixed till can send bills to a USB queue and dockets to an address', () async {
      final spooler = _Spooler();
      final net = _Net();
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: spooler.call,
        netWrite: net.call,
        networkPrinters: const <String>['tcp://10.0.0.7:9100'],
      );
      svc.debugSetRouting(
        routes: <String, String>{
          PrintRole.bill: 'Till Printer',
          PrintRole.anyKot: 'tcp://10.0.0.7:9100',
        },
        installed: <String>['Test Printer', 'Till Printer'],
      );

      await svc.onPrintEvent(_event(billId: 'B-14', jobId: 'j14'));
      await svc.onPrintEvent(_event(billId: 'B-15', jobId: 'j15', station: 'TANDOOR'));
      await pumpEventQueue();

      expect(spooler.printers.single, 'Till Printer');
      expect(net.dialled.single, '10.0.0.7:9100');
    });
  });

  // -------------------------------------------------------------------------
  // 4. A socket that fails is a docket the kitchen never saw. It has to say so.
  // -------------------------------------------------------------------------

  group('a failed send is loud, not silent', () {
    test('it is retried, then settled as failed, carrying the reason', () async {
      final api = _FakeApi();
      final net = _Net(error: 'No answer from 192.168.1.50:9100. The printer may be switched off.');
      final svc = PrinterService.forTest(
        auth: await _signIn(api),
        write: (_, _) => false,
        netWrite: net.call,
        spooler: false,
        printer: 'tcp://192.168.1.50:9100',
        networkPrinters: const <String>['tcp://192.168.1.50:9100'],
      );

      await svc.onPrintEvent(_event(billId: 'B-16', jobId: 'j16', station: 'TANDOOR'));
      await pumpEventQueue();

      // Three tries at the address, and then an explicit 'failed' — a settled,
      // queryable record that this docket never printed, rather than a job the
      // server replays at a dead printer on every reconnect for ever.
      expect(net.dialled.length, 3);
      expect(api.acks.single, <String, dynamic>{'jobId': 'j16', 'result': 'failed'});

      // AND IT SAYS WHY, in words. "Print failed" is the same silent drop
      // durable printing exists to remove: switched off, wrong port and wrong
      // Wi-Fi need three different people to do three different things.
      expect(svc.logs.any((l) => l.contains('switched off')), isTrue);
      expect(svc.logs.any((l) => l.contains('Gave up on B-16')), isTrue);
    });

    test('a job still waiting between attempts carries the reason on the queue card', () async {
      final net = _Net(error: 'This device cannot reach 192.168.1.50.');
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => false,
        netWrite: net.call,
        spooler: false,
        printer: 'tcp://192.168.1.50:9100',
        networkPrinters: const <String>['tcp://192.168.1.50:9100'],
        // Long enough that the job is observable BETWEEN attempts, which is
        // exactly the state the printer screen renders while the kitchen is
        // waiting and someone is trying to work out why.
        retryDelay: const Duration(seconds: 5),
      );

      unawaited(svc.onPrintEvent(_event(billId: 'B-17', jobId: 'j17')));
      await pumpEventQueue();

      final job = svc.queue.single;
      expect(job.attempts, 1);
      expect(job.lastError, 'This device cannot reach 192.168.1.50.');
      expect(svc.logs.any((l) => l.contains('cannot reach 192.168.1.50')), isTrue);
    });

    test('a network printer gets a longer breath between tries than a spooler', () async {
      // A queue that refuses a job refuses it NOW; a printer that is rebooting,
      // roaming between access points or renewing a DHCP lease is simply not
      // there YET, and three tries two seconds apart would write it off while it
      // was still coming up.
      //
      // Asserted on the decision rather than on the wall clock: a test that
      // measured elapsed time would be a stopwatch race with the machine it runs
      // on, and would eventually fail for a reason that has nothing to do with
      // printing.
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => false,
        retryDelay: const Duration(seconds: 2), // the shipped value
      );
      expect(svc.retryDelayFor('Till Printer'), const Duration(seconds: 2));
      expect(svc.retryDelayFor('tcp://10.0.0.7:9100'), const Duration(seconds: 8));
    });

    test('forgetting a printer takes its rules with it', () async {
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => true,
        netWrite: _Net().call,
        spooler: false,
        printer: null,
        networkPrinters: const <String>['tcp://10.0.0.7:9100'],
      );
      await svc.setRoute(PrintRole.anyKot, 'tcp://10.0.0.7:9100');
      expect(svc.routes, isNotEmpty);

      await svc.removeNetworkPrinter('tcp://10.0.0.7:9100');

      // A rule pointing at an address this device no longer has is a rule that
      // silently falls through to the default — which is the shape of bug where
      // the bar's dockets quietly start coming out at the till.
      expect(svc.networkPrinters, isEmpty);
      expect(svc.routes, isEmpty);
      expect(svc.canClaimJobs, isFalse);
    });

    test('a stale network default is not dialled', () async {
      final net = _Net();
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => false,
        netWrite: net.call,
        spooler: false,
        // Left over from a printer that has since been removed.
        printer: 'tcp://10.0.0.7:9100',
      );

      await svc.onPrintEvent(_event(billId: 'B-18', jobId: 'j18'));
      await pumpEventQueue();

      // Better held and visible than three attempts at a socket that cannot
      // exist, followed by a 'failed' ack for a bill nobody ever tried to print.
      expect(net.dialled, isEmpty);
      expect(svc.queue.length, 1);
      expect(svc.logs.any((l) => l.contains('No printer selected')), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // 5. The address itself.
  // -------------------------------------------------------------------------

  group('a printer address', () {
    test('round-trips through the stored target form', () {
      const target = 'tcp://192.168.1.50:9100';
      expect(PrintTarget.network('192.168.1.50', 9100), target);
      expect(PrintTarget.isNetwork(target), isTrue);
      expect(PrintTarget.parse(target), (host: '192.168.1.50', port: 9100));
      expect(PrintTarget.label(target), '192.168.1.50:9100');
    });

    test('a bare name is still a Windows queue, so old rules keep working', () {
      // Every routing entry written before network printing existed is a bare
      // spooler name. Nothing about them may change meaning.
      const name = 'EPSON TM-T82 Receipt';
      expect(PrintTarget.isNetwork(name), isFalse);
      expect(PrintTarget.parse(name), isNull);
      expect(PrintTarget.label(name), name);
    });

    test('is checked before it can be saved as a rule that prints nowhere', () {
      expect(NetworkPrinter.validate('192.168.1.50', 9100), isNull);
      expect(NetworkPrinter.validate('', 9100), isNotNull);
      expect(NetworkPrinter.validate('192.168.1.50', 0), isNotNull);
      expect(NetworkPrinter.validate('192.168.1.50', 70000), isNotNull);
      // The port has its own box; pasting the whole thing into the address is
      // the mistake most likely to be made and hardest to see afterwards.
      expect(NetworkPrinter.validate('192.168.1.50:9100', 9100), isNotNull);
      expect(NetworkPrinter.validate('192.168.1 50', 9100), isNotNull);
    });

    test('a corrupted saved address fails as itself, not as a missing Windows queue', () async {
      final spooler = _Spooler();
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: spooler.call,
        netWrite: _Net().call,
      );

      final err = await svc.testPrintTo('tcp://not-a-real-target');
      // Falling through would hand winspool the literal string "tcp://…", and a
      // queue-not-found is the least informative way this could fail.
      expect(err, contains('cannot be read'));
      expect(spooler.printers, isEmpty);
    });

    test('a duplicate is refused rather than silently added twice', () async {
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => true,
        netWrite: _Net().call,
        spooler: false,
        printer: null,
      );
      expect(await svc.addNetworkPrinter('192.168.1.50', 9100), isNull);
      expect(await svc.addNetworkPrinter('192.168.1.50', 9100), isNotNull);
      expect(svc.networkPrinters.length, 1);
    });

    test('the test slip goes over the address it names, and reports the failure verbatim', () async {
      final net = _Net();
      final svc = PrinterService.forTest(
        auth: await _signIn(_FakeApi()),
        write: (_, _) => true,
        netWrite: net.call,
        spooler: false,
        printer: null,
      );

      expect(await svc.testNetworkAddress('192.168.1.50', 9100), isNull);
      expect(net.dialled.single, '192.168.1.50:9100');
      // Not empty: the slip is real ESC/POS, so a printer that takes it prints
      // something a human can look at. That is the only confirmation port 9100
      // can give — it sends no reply of its own.
      expect(net.byteCounts.single, greaterThan(0));

      net.error = 'The device at 192.168.1.50 answered but refused port 9100.';
      expect(await svc.testNetworkAddress('192.168.1.50', 9100),
          'The device at 192.168.1.50 answered but refused port 9100.');
    });
  });
}
