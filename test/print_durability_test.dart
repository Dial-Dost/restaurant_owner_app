import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printer_service.dart';

/// The till half of durable printing.
///
/// The defect these pin down: printing was fire-and-forget in both directions.
/// The backend emitted into a Socket.IO room and answered {success:true}
/// whatever happened (an emit into an empty room is a successful no-op), and
/// this app held its print queue in memory. A bill emitted while the till's
/// socket was down was gone — no retry, no error, a green tick for the waiter.
/// The backend now persists every job first and re-sends whatever it has no
/// acknowledgement for; everything below is what the agent has to get right for
/// that to be safe rather than merely noisy.
///
///   * A RE-SENT JOB THAT ALREADY PRINTED MUST NOT PRINT AGAIN. The server
///     re-sends precisely what it holds no ack for, so a lost ack — an HTTP
///     failure after the paper came out, or a crash — puts a job back on this
///     till that has already been handed to a customer. Only this device knows
///     that, and only if it wrote it down somewhere that survives a restart.
///   * THE ACK FOLLOWS THE SPOOLER, NOT THE SOCKET. Acking on receipt would
///     settle a job this till then failed to print: the server would believe the
///     receipt was delivered and never re-send it, which is the original bug
///     wearing a tick.
///   * A FAILURE IS REPORTED, NOT SWALLOWED. Three refusals from the spooler
///     end in an explicit 'failed' ack, so the job is a settled record of a
///     receipt that never printed rather than something replayed forever at a
///     printer that is out of paper.
///   * IDENTITY IS THE SERVER'S jobId, NEVER billId. billId is stable across
///     reprints and shared by every station ticket of one KOT, so deduplicating
///     on it would swallow a waiter's second copy and drop every kitchen but the
///     first.
///   * AN AGENT THAT CANNOT PRINT MUST NOT CLAIM. Claiming takes jobs off the
///     queue the outlet's real till is waiting on, so a device that then fails
///     to print loses every one of those receipts. The rule is CAPABILITY, not
///     platform: a phone can now print over a socket (see
///     printer_routing_test.dart), so what disqualifies it is having no printer
///     configured at all rather than having no winspool.

class _FakeApi extends ApiClient {
  _FakeApi({this.failAcks = false});

  /// Every write, as 'METHOD path' plus the decoded body — the acks are the
  /// point of most of these tests, so they are recorded rather than mocked away.
  final List<String> calls = <String>[];
  final List<Map<String, dynamic>> acks = <Map<String, dynamic>>[];

  /// Drives the "the ack itself failed" path (a till whose network is down while
  /// its printer is fine).
  final bool failAcks;

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
    calls.add('$method $path');
    if (path == '/print/ack') {
      if (failAcks) throw ApiException('Network is unreachable.', 503);
      acks.add(<String, dynamic>{
        ...Map<String, dynamic>.from(body as Map),
        'outletHeader': outletId,
      });
      return <String, dynamic>{'success': true, 'duplicate': false};
    }
    throw ApiException('No fake route for $path', 404);
  }
}

/// A spooler that records what it was asked to print. [accept] decides whether
/// the write succeeds, so a test can drive an offline printer.
class _FakeSpooler {
  _FakeSpooler({this.accept = true, this.failFirst = 0});
  bool accept;

  /// Refuse this many writes before behaving as [accept] — a printer that was
  /// briefly busy or out of paper and then came good.
  int failFirst;

  final List<int> byteCounts = <int>[];
  final List<String> printers = <String>[];

  /// Interleaved with the acks so a test can assert the ORDER, not just that
  /// both happened.
  final List<String> events = <String>[];

  int get writes => byteCounts.length;

  bool call(String printer, List<int> bytes) {
    printers.add(printer);
    byteCounts.add(bytes.length);
    var ok = accept;
    if (failFirst > 0) {
      failFirst--;
      ok = false;
    }
    events.add('write:${ok ? 'ok' : 'fail'}');
    return ok;
  }
}

Future<AuthController> _signIn(_FakeApi api) async {
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  return auth;
}

/// One `bill:print` payload, in the exact shape printJobPayload() builds on the
/// backend: billId + escBase64 always, station/kind on a KOT only, jobId and
/// replay additive.
Map<String, dynamic> _event({
  required String billId,
  String? jobId,
  String body = 'RECEIPT',
  bool replay = false,
  String? station,
}) =>
    <String, dynamic>{
      'billId': billId,
      'escBase64': base64Encode(utf8.encode(body)),
      if (station != null) ...<String, dynamic>{'station': station, 'kind': 'kot'},
      'jobId': jobId,
      'publishedAt': '2026-08-18T10:00:00.000Z',
      if (replay) 'replay': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('a re-sent job is not printed twice', () {
    test('the same jobId arriving again is skipped, and re-acknowledged', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-1', jobId: 'job-1'));
      await pumpEventQueue();
      expect(spooler.writes, 1);
      expect(api.acks.single['jobId'], 'job-1');
      expect(api.acks.single['result'], 'printed');

      // The server re-sends it because the ack has not landed yet (or was lost).
      await svc.onPrintEvent(_event(billId: 'B-1', jobId: 'job-1', replay: true));
      await pumpEventQueue();
      expect(spooler.writes, 1, reason: 'the customer must not get a second copy');
      expect(svc.queue, isEmpty);

      // ...and it is re-acknowledged, so the server can settle it and stop
      // re-sending. Silently ignoring it would leave the job outstanding until
      // it expired as an undelivered receipt that had in fact printed.
      expect(api.acks.length, 2);
      expect(api.acks.last['jobId'], 'job-1');
      expect(api.acks.last['result'], 'printed');
    });

    test('a replay window that prints nothing still arms a retry', () async {
      // The stranded-lease gap. A window can come back fully deduplicated — or
      // empty — because the backlog is still leased to a connection that has
      // gone away. From the till those are indistinguishable from "drained".
      //
      // Treating that as drained is what stranded a job: the till stopped asking
      // for the life of the connection, and a KOT held by a dead lease expired
      // unprinted. An empty window must therefore re-ask on a timer, bounded by
      // the round cap, rather than end the conversation.
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-9', jobId: 'job-9'));
      await pumpEventQueue();
      expect(spooler.writes, 1);

      // A replay window carrying only what we already printed: nothing to do.
      await svc.onPrintEvent(_event(billId: 'B-9', jobId: 'job-9', replay: true));
      await pumpEventQueue();
      expect(spooler.writes, 1, reason: 'still exactly one receipt');
      expect(svc.replayRetryPending, isTrue,
          reason: 'an unproductive window must re-ask later, not give up');
    });

    test('the skip survives a restart of the app', () async {
      final api = _FakeApi();
      final first = _FakeSpooler();
      final auth = await _signIn(api);
      final before = PrinterService.forTest(auth: auth, write: first.call);
      await before.onPrintEvent(_event(billId: 'B-2', jobId: 'job-2'));
      await pumpEventQueue();
      expect(first.writes, 1);

      // A fresh service over the SAME persisted preferences — the app restarting
      // is the ordinary case here, because a redeploy that drops every till is
      // exactly when the backlog gets replayed.
      final second = _FakeSpooler();
      final after = PrinterService.forTest(auth: auth, write: second.call);
      await after.onPrintEvent(_event(billId: 'B-2', jobId: 'job-2', replay: true));
      await pumpEventQueue();
      expect(second.writes, 0, reason: 'an in-memory set would have forgotten this');
    });

    test('a job still queued is not queued twice by a crossing replay', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);
      svc.setPaused(true); // hold it in the queue, unprinted

      await svc.onPrintEvent(_event(billId: 'B-3', jobId: 'job-3'));
      await svc.onPrintEvent(_event(billId: 'B-3', jobId: 'job-3', replay: true));
      expect(svc.queue.length, 1);
      expect(spooler.writes, 0);

      // Nothing was printed, so nothing was claimed to the server either.
      await pumpEventQueue();
      expect(api.acks, isEmpty);
    });

    test('a reprint of the same bill is a NEW job and does print again', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      // billId is stable across reprints — a waiter asking for a second copy
      // gets a second job row, and deduplicating on billId would swallow it.
      await svc.onPrintEvent(_event(billId: 'B-4', jobId: 'job-4a'));
      await svc.onPrintEvent(_event(billId: 'B-4', jobId: 'job-4b'));
      await pumpEventQueue();
      expect(spooler.writes, 2);
    });

    test('the station tickets of one KOT all print, though they share a billId', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'T5-1', jobId: 'kot-hot', station: 'Hot', body: 'HOT'));
      await svc.onPrintEvent(_event(billId: 'T5-1', jobId: 'kot-cold', station: 'Cold', body: 'COLD-LONGER'));
      await pumpEventQueue();
      expect(spooler.writes, 2, reason: 'the cold kitchen must not lose its docket');
      expect(spooler.byteCounts.toSet().length, 2, reason: 'and it must be its OWN docket');
    });
  });

  group('the acknowledgement follows the spooler', () {
    test('nothing is acknowledged until the write succeeds', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-6', jobId: 'job-6'));
      await pumpEventQueue();
      // The write comes first and the ack second — not merely both present.
      expect(spooler.events.first, 'write:ok');
      expect(api.acks.single['result'], 'printed');
      expect(api.calls, contains('POST /print/ack'));
    });

    test('a job waiting for a printer to be chosen is never acknowledged', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call, printer: null);

      await svc.onPrintEvent(_event(billId: 'B-7', jobId: 'job-7'));
      await pumpEventQueue();
      expect(spooler.writes, 0);
      expect(api.acks, isEmpty, reason: 'acking here would strand a receipt nobody printed');
      expect(svc.queue.length, 1, reason: 'and it must still be waiting');
    });

    test('a printer that refuses three times is reported as failed, not as printed', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler(accept: false);
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-8', jobId: 'job-8'));
      await pumpEventQueue();
      expect(spooler.writes, 3, reason: 'the existing three-attempt retry is kept');
      expect(api.acks.single['jobId'], 'job-8');
      expect(api.acks.single['result'], 'failed');
      expect(api.acks.map((a) => a['result']), isNot(contains('printed')));
    });

    test('a printer that comes good on the second attempt acknowledges once', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler(failFirst: 1);
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-9', jobId: 'job-9'));
      await pumpEventQueue();
      expect(spooler.events, ['write:fail', 'write:ok'], reason: 'the retry is kept');
      // One confirmation, sent for the attempt that worked — not one per attempt,
      // and nothing at all for the attempt that did not.
      expect(api.acks.length, 1);
      expect(api.acks.single['jobId'], 'job-9');
      expect(api.acks.single['result'], 'printed');
    });

    test('a lost acknowledgement leaves the job printable-once, not printed-twice', () async {
      // The till prints fine but cannot reach the server. The server keeps the
      // job outstanding and re-sends it; the local record is what stops the
      // second copy, and the retry then rides the replay instead.
      final api = _FakeApi(failAcks: true);
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-11', jobId: 'job-11'));
      await pumpEventQueue();
      expect(spooler.writes, 1);
      expect(api.calls.where((c) => c == 'POST /print/ack').length, 3, reason: 'retried, then given up on');

      await svc.onPrintEvent(_event(billId: 'B-11', jobId: 'job-11', replay: true));
      await pumpEventQueue();
      expect(spooler.writes, 1);
    });

    test('the acknowledgement carries the concrete outlet, never the "all" sentinel', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call, outletId: 'outlet-2');

      await svc.onPrintEvent(_event(billId: 'B-12', jobId: 'job-12'));
      await pumpEventQueue();
      expect(api.acks.single['outletHeader'], 'outlet-2');
    });
  });

  group('jobs the server could not make durable', () {
    test('a job with no jobId still prints, and is not acknowledged', () async {
      // A backend running ahead of migration 027 emits jobId: null. Printing is
      // back to fire-and-forget for that receipt, which is strictly better than
      // not printing it — but there is nothing to confirm and nothing to dedupe.
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(_event(billId: 'B-13', jobId: null));
      await svc.onPrintEvent(_event(billId: 'B-13', jobId: null));
      await pumpEventQueue();
      expect(spooler.writes, 2, reason: 'without an identity there is nothing to deduplicate on');
      expect(api.acks, isEmpty);
    });

    test('a payload with no bytes is dropped without touching the printer', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call);

      await svc.onPrintEvent(<String, dynamic>{'billId': 'B-14', 'jobId': 'job-14'});
      await svc.onPrintEvent(<String, dynamic>{'billId': 'B-15', 'jobId': 'job-15', 'escBase64': '!!not base64!!'});
      await pumpEventQueue();
      expect(spooler.writes, 0);
      expect(api.acks, isEmpty);
    });
  });

  group('only a till that can print may claim', () {
    test('an agent that cannot print advertises no version, so it is sent nothing', () async {
      // The server replays only to an agent that names a version — its interlock
      // against replaying a backlog to a build that can neither dedupe nor ack.
      // A device with no printing capability at all must stay silent. (The
      // narrower, live case — a phone that CAN print in principle but has no
      // printer address yet — is in printer_routing_test.dart.)
      final api = _FakeApi();
      final android = PrinterService.forTest(
        auth: await _signIn(api),
        write: (_, _) => false,
        supported: false,
      );
      expect(android.canClaimJobs, isFalse);
      expect(android.joinPayload('res-1', 'outlet-1').containsKey('agentVersion'), isFalse);

      final till = PrinterService.forTest(auth: await _signIn(api), write: (_, _) => true);
      expect(till.canClaimJobs, isTrue);
      expect(till.joinPayload('res-1', 'outlet-1')['agentVersion'], PrinterService.agentVersion);
      expect(till.joinPayload('res-1', 'outlet-1')['outletId'], 'outlet-1');
    });

    test('the combined "all outlets" view subscribes to the session outlet', () async {
      // "all" is a read-only aggregate, not an outlet id: joining that room
      // subscribes to something nothing emits into, and it would 400 every ack.
      expect(PrinterService.resolveOutletId('all', 'outlet-1'), 'outlet-1');
      expect(PrinterService.resolveOutletId('__all__', 'outlet-1'), 'outlet-1');
      expect(PrinterService.resolveOutletId('ALL', 'outlet-1'), 'outlet-1');
      expect(PrinterService.resolveOutletId(null, 'outlet-1'), 'outlet-1');
      expect(PrinterService.resolveOutletId('', 'outlet-1'), 'outlet-1');
      expect(PrinterService.resolveOutletId('outlet-9', 'outlet-1'), 'outlet-9');
    });
  });

  group('the queue outlives a teardown', () {
    test('stop() keeps unprinted jobs instead of discarding them', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call, printer: null);

      await svc.onPrintEvent(_event(billId: 'B-16', jobId: 'job-16'));
      expect(svc.queue.length, 1);
      await svc.stop();
      expect(svc.queue.length, 1, reason: 'a logout or outlet switch is not a decision to lose a receipt');

      // And it goes out once a printer is chosen.
      await svc.setSelectedPrinter('Test Printer');
      await pumpEventQueue();
      expect(spooler.writes, 1);
      expect(api.acks.single['jobId'], 'job-16');
    });

    test('clearQueue() is the deliberate discard, and says so to the server', () async {
      final api = _FakeApi();
      final spooler = _FakeSpooler();
      final svc = PrinterService.forTest(auth: await _signIn(api), write: spooler.call, printer: null);

      await svc.onPrintEvent(_event(billId: 'B-17', jobId: 'job-17'));
      svc.clearQueue();
      await pumpEventQueue();
      expect(svc.queue, isEmpty);
      expect(spooler.writes, 0);
      // Left unacknowledged it would be re-sent on the next reconnect and print
      // anyway — the opposite of what "clear" means.
      expect(api.acks.single['jobId'], 'job-17');
      expect(api.acks.single['result'], 'failed');

      // ...and if it is re-sent before that ack lands, it still does not print.
      await svc.setSelectedPrinter('Test Printer');
      await svc.onPrintEvent(_event(billId: 'B-17', jobId: 'job-17', replay: true));
      await pumpEventQueue();
      expect(spooler.writes, 0);
    });
  });
}
