import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' show printerLinkStatus;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/printer_service.dart';

/// "Every now and then we need to close and reopen the app for the printer to
/// work."
///
/// Two defects produced the same symptom — a till whose realtime transport was
/// up (green "Connected") but which the server had never put in its outlet's
/// room, so no `bill:print` ever arrived — and a restart was the only thing
/// staff found that cleared it:
///
///   * THE STALE HANDSHAKE TOKEN. socket_io_client 3.1.6 caches one Manager per
///     host for the whole process and hands back the FIRST socket it ever made,
///     auth and all, ignoring the options passed later. So after any sign-out
///     and sign-in — or a 401 auto sign-out, an expired session, a password
///     reset — the agent handshook with a destroyed token, the server ignored
///     it in silence, and only a fresh process got a fresh cache.
///   * NO SUBSCRIPTION LIVENESS. 'joinedOutlet' was only logged, a keepalive
///     401 was swallowed, nothing re-asked, and nothing noticed the app coming
///     back to the foreground. Both defects looked like a working printer.
///
/// The server half (a join sent before the session lookup resolves is no longer
/// dropped, and a dead session is answered with joinRejected) is pinned in the
/// backend's jest-tests/realtime_session_race.test.ts. This file is the till
/// half: a new connection per start, a watchdog that re-asks on a capped ladder,
/// sign-out only on the server's word, and a screen that says which it is.

class _FakeApi extends ApiClient {
  _FakeApi({List<String>? tokens}) : _tokens = tokens ?? <String>['token-1'];

  final List<String> _tokens;
  int _logins = 0;

  /// What /auth/me does next: null answers 200; anything else is thrown.
  Object? meFailure;
  int meCalls = 0;
  final List<String> serverLogouts = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async {
    final token = _tokens[_logins < _tokens.length ? _logins : _tokens.length - 1];
    _logins++;
    return LoginResult(token, _profile());
  }

  @override
  Future<Profile> me(String token) async {
    meCalls++;
    final f = meFailure;
    if (f != null) throw f;
    return _profile();
  }

  @override
  Future<void> logout(String token) async => serverLogouts.add(token);

  static Profile _profile() => Profile.fromJson(<String, dynamic>{
        'employeeId': 'e1',
        'restaurantName': 'Gaia',
        'restaurantUsername': 'gaia',
        'res_id': 'res-1',
        'outlet_id': 'outlet-1',
        'role': 'admin',
        'actions_set': ['*'],
        'action_names': <String>[],
      });
}

/// One connection, with the test playing the server.
///
/// [dispose] deliberately does NOT clear the handlers, unlike the real client:
/// it lets a test deliver a late event from a replaced connection and prove the
/// agent ignores it, rather than relying on the library to have removed it.
class _FakeSocket implements AgentSocket {
  _FakeSocket(this.options);

  final Map<String, dynamic> options;
  final Map<String, List<void Function(dynamic)>> _handlers = <String, List<void Function(dynamic)>>{};
  final List<MapEntry<String, dynamic>> emitted = <MapEntry<String, dynamic>>[];
  final List<Map> handshakes = <Map>[];
  int connectCalls = 0;
  bool disposed = false;

  @override
  void on(String event, void Function(dynamic data) handler) =>
      (_handlers[event] ??= <void Function(dynamic)>[]).add(handler);

  @override
  void emit(String event, [dynamic data]) => emitted.add(MapEntry(event, data));

  /// Opening the transport is when Socket.IO reads the auth — so a function
  /// auth is invoked here, exactly as socket.dart's onopen does.
  @override
  void connect() {
    connectCalls++;
    final auth = options['auth'];
    if (auth is Function) {
      auth((Map data) => handshakes.add(Map.of(data)));
    } else if (auth is Map) {
      handshakes.add(Map.of(auth));
    }
  }

  @override
  void dispose() => disposed = true;

  /// A packet from the server.
  void serverSends(String event, [dynamic data]) {
    for (final h in List.of(_handlers[event] ?? const <void Function(dynamic)>[])) {
      h(data);
    }
  }

  int get joins => emitted.where((e) => e.key == 'joinOutlet').length;
  String? get handshakeToken => handshakes.isEmpty ? null : '${handshakes.last['token']}';
}

class _FakeServer {
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  AgentSocket call(String url, Map<String, dynamic> options) {
    final s = _FakeSocket(options);
    sockets.add(s);
    return s;
  }

  _FakeSocket get last => sockets.last;
  Iterable<_FakeSocket> get live => sockets.where((s) => !s.disposed);
}

const _answer = Duration(milliseconds: 40);

Future<void> _wait(Duration d) => Future<void>.delayed(d);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // A PHONE WITH A NETWORK PRINTER: a claiming agent without winspool, so
    // start() opens its socket without enumerating real Windows printers.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'printer_net_outlet-1': <String>['tcp://192.168.1.50:9100'],
    });
  });

  Future<({PrinterService svc, AuthController auth, _FakeApi api, _FakeServer server})> agent({
    List<String>? tokens,
    Duration keepAliveEvery = const Duration(minutes: 25),
  }) async {
    final api = _FakeApi(tokens: tokens);
    final auth = AuthController(api: api);
    await auth.login('Gaia', 'till', 'pw');
    final server = _FakeServer();
    final svc = PrinterService.forTest(
      auth: auth,
      write: (_, _) => false,
      netWrite: (_, _, _) async => null,
      spooler: false,
      printer: 'tcp://192.168.1.50:9100',
      socketFactory: server.call,
      joinAnswerTimeout: _answer,
      keepAliveEvery: keepAliveEvery,
    );
    addTearDown(svc.stop);
    return (svc: svc, auth: auth, api: api, server: server);
  }

  group('the socket library quirk, and the option that defeats it', () {
    test('without forceNew, a second io() after dispose hands back the FIRST socket and its token', () {
      // Characterisation of socket_io_client 3.1.6, kept so nobody "tidies"
      // forceNew away. If this ever fails, the library has fixed its cache —
      // forceNew stays correct either way.
      const url = 'http://127.0.0.1:39431';
      io.Socket build(String token) => io.io(
            url,
            io.OptionBuilder().setTransports(['websocket']).disableAutoConnect().setAuth({'token': token}).build(),
          );
      final first = build('TOKEN_A');
      first.dispose();
      final second = build('TOKEN_B');
      expect(identical(first, second), isTrue);
      expect((second.auth as Map)['token'], 'TOKEN_A', reason: 'the new sign-in is silently ignored');
      second.dispose();
    });

    test('PrinterService.socketOptions: a new socket every time, introducing the CURRENT token', () {
      const url = 'http://127.0.0.1:39432';
      var token = 'TOKEN_A';
      final opts = PrinterService.socketOptions(token: () => token, resId: 'res-1');
      expect(opts['forceNew'], isTrue);
      expect(opts['autoConnect'], isFalse);

      final first = io.io(url, PrinterService.socketOptions(token: () => 'TOKEN_A', resId: 'res-1'));
      first.dispose();
      final second = io.io(url, opts);
      expect(identical(first, second), isFalse);

      Map? sent;
      token = 'TOKEN_B';
      (second.auth as Function)((Map m) => sent = m);
      expect(sent?['token'], 'TOKEN_B');
      expect(sent?['restaurantId'], 'res-1');
      second.dispose();
    });
  });

  group('one connection per start, carrying the session of that start', () {
    test('start -> stop -> sign in again -> start handshakes with the NEW token', () async {
      final a = await agent(tokens: <String>['token-1', 'token-2']);
      await a.svc.start(a.auth);
      expect(a.server.sockets, hasLength(1));
      expect(a.server.last.handshakeToken, 'token-1');

      // Sign out and back in on the till — the shift handover.
      await a.svc.stop();
      expect(a.server.sockets.single.disposed, isTrue);
      await a.auth.logout();
      await a.auth.login('Gaia', 'till', 'pw');
      await a.svc.start(a.auth);

      expect(a.server.sockets, hasLength(2));
      expect(a.server.last.handshakeToken, 'token-2',
          reason: 'the old client re-sent token-1 here, which the server had destroyed');
      expect(a.server.live, hasLength(1), reason: 'never two live sockets');
    });

    test('a reconnect reads the token at handshake time, not at start()', () async {
      final a = await agent(tokens: <String>['token-1', 'token-2']);
      await a.svc.start(a.auth);
      final socket = a.server.last;
      await a.auth.login('Gaia', 'till', 'pw'); // same controller, new session
      socket.connect(); // the transport comes back
      expect(socket.handshakes.map((h) => h['token']), <String>['token-1', 'token-2']);
    });

    test('a replaced connection can change nothing, and cannot print', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final old = a.server.last;
      old.serverSends('connect');
      await a.svc.stop();
      await a.svc.start(a.auth);
      final fresh = a.server.last;

      old.serverSends('joinedOutlet', {'restaurantId': 'res-1', 'outletId': 'outlet-1'});
      old.serverSends('bill:print', {'billId': 'B-1', 'escBase64': 'SGVsbG8=', 'jobId': 'job-1'});
      await pumpEventQueue();
      expect(a.svc.subscribed, isFalse);
      expect(a.svc.connected, isFalse);
      expect(a.svc.queue, isEmpty);
      expect(a.svc.logs.where((l) => l.contains('B-1')), isEmpty);
      expect(fresh.disposed, isFalse);
    });

    test('a stop() that lands while start() is still loading opens no socket', () async {
      final a = await agent();
      final starting = a.svc.start(a.auth);
      await a.svc.stop();
      await starting;
      expect(a.server.sockets, isEmpty);
    });
  });

  group('connected is not subscribed', () {
    test('only a joinedOutlet for THIS outlet turns the link to listening', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      expect(a.svc.linkState, PrinterLink.offline);

      s.serverSends('connect');
      expect(s.joins, 1);
      expect(s.emitted.first.value['outletId'], 'outlet-1');
      expect(a.svc.linkState, PrinterLink.joining);

      s.serverSends('joinedOutlet', {'restaurantId': 'res-1', 'outletId': 'outlet-OTHER'});
      expect(a.svc.subscribed, isFalse, reason: 'a stale confirmation for another outlet');

      s.serverSends('joinedOutlet', {'restaurantId': 'res-1', 'outletId': 'outlet-1'});
      expect(a.svc.subscribed, isTrue);
      expect(a.svc.linkState, PrinterLink.listening);

      s.serverSends('disconnect');
      expect(a.svc.linkState, PrinterLink.offline);
      s.serverSends('connect');
      expect(a.svc.linkState, PrinterLink.joining,
          reason: 'a new connection is a new server socket in no rooms');
    });

    test('the screen says three different things', () {
      final listening = printerLinkStatus(PrinterLink.listening, unconfigured: false);
      final joining = printerLinkStatus(PrinterLink.joining, unconfigured: false);
      final offline = printerLinkStatus(PrinterLink.offline, unconfigured: false);
      expect(listening.label, 'Listening');
      expect(joining.label, 'Connecting');
      expect(joining.caption, contains('not receiving jobs yet'));
      expect(offline.label, 'Offline');
      expect({listening.color, joining.color, offline.color}, hasLength(3));
      expect(printerLinkStatus(PrinterLink.offline, unconfigured: true).caption, contains('Add a printer'));
    });
  });

  group('the watchdog re-asks, on a ladder, and only while unanswered', () {
    test('the ladder doubles and caps at a minute', () {
      const first = Duration(seconds: 5);
      expect(
        [for (var i = 0; i < 7; i++) PrinterService.joinRetryDelay(i, first: first).inSeconds],
        <int>[5, 10, 20, 40, 60, 60, 60],
      );
    });

    test('an unanswered join is asked again, and an answer stops it', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      expect(s.joins, 1);

      await _wait(_answer * 1.5); // first rung: 40ms
      expect(s.joins, greaterThanOrEqualTo(2), reason: 'the lost join (the server connect race) is re-sent');

      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      final after = s.joins;
      await _wait(_answer * 8);
      expect(s.joins, after, reason: 'a confirmed room costs no further joins — no extra replay transactions');
      expect(a.api.meCalls, 0);
    });

    test('a subscribed agent is never re-joined by the keepalive', () async {
      final a = await agent(keepAliveEvery: const Duration(milliseconds: 30));
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      await _wait(const Duration(milliseconds: 120));
      expect(s.joins, 1);
    });
  });

  group('sign-out only on the server\'s word', () {
    test('joinRejected {session_invalid} signs out once, as expired', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinRejected', {'reason': 'session_invalid'});
      s.serverSends('joinRejected', {'reason': 'session_invalid'});
      await pumpEventQueue();

      expect(a.auth.token, isNull);
      expect(a.auth.notice, contains('session expired'));
      expect(a.api.serverLogouts, <String>['token-1'], reason: 'once, not per rejection');
      expect(a.svc.logs.first, contains('Session expired'));
      await _wait(_answer * 4);
      await a.svc.onResume(); // the login screen coming to the front
      expect(s.joins, 1, reason: 'nothing keeps asking on behalf of a dead session');
    });

    test('a rejection of a token this device no longer holds reconnects instead', () async {
      final a = await agent(tokens: <String>['token-1', 'token-2']);
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      await a.auth.login('Gaia', 'till', 'pw'); // now holding token-2
      s.serverSends('joinRejected', {'reason': 'session_invalid'});
      await pumpEventQueue();

      expect(a.auth.token, 'token-2', reason: 'a good session must not be ended');
      expect(s.disposed, isTrue);
      expect(a.server.sockets, hasLength(2));
      expect(a.server.last.handshakeToken, 'token-2');
      expect(a.server.live, hasLength(1));
    });

    test('unanswered joins probe /auth/me, and a 401 signs out once', () async {
      final a = await agent();
      a.api.meFailure = ApiException('Unauthorized', 401);
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect'); // an older backend: silence for a dead session

      await _wait(_answer * 5); // 40ms re-ask, then 80ms -> probe
      expect(a.api.meCalls, 1);
      expect(a.auth.token, isNull);
      expect(a.auth.notice, contains('session expired'));
      expect(a.api.serverLogouts, hasLength(1));
    });

    test('a probe that cannot reach the server NEVER signs out — it reconnects', () async {
      final a = await agent();
      a.api.meFailure = const SocketException('Network is unreachable');
      await a.svc.start(a.auth);
      final first = a.server.last;
      first.serverSends('connect');

      await _wait(_answer * 5);
      expect(a.api.meCalls, 1);
      expect(a.auth.token, 'token-1', reason: 'flaky Wi-Fi must not sign staff out mid-service');
      expect(first.disposed, isTrue);
      expect(a.server.sockets, hasLength(2), reason: 'a fresh handshake is what a restart was really doing');
      expect(a.server.live, hasLength(1));
    });

    test('a 5xx from /auth/me is not a verdict on the session either', () async {
      final a = await agent();
      a.api.meFailure = ApiException('Bad gateway', 502);
      await a.svc.start(a.auth);
      a.server.last.serverSends('connect');
      await _wait(_answer * 5);
      expect(a.api.meCalls, 1);
      expect(a.auth.token, 'token-1');
      expect(a.server.sockets, hasLength(2));
    });

    test('the keepalive no longer swallows a 401', () async {
      final a = await agent(keepAliveEvery: const Duration(milliseconds: 30));
      a.api.meFailure = ApiException('Unauthorized', 401);
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      await _wait(const Duration(milliseconds: 100));
      expect(a.auth.token, isNull);
      expect(a.api.serverLogouts, hasLength(1));
    });

    test('a keepalive transport failure changes nothing', () async {
      final a = await agent(keepAliveEvery: const Duration(milliseconds: 30));
      a.api.meFailure = const SocketException('offline');
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      await _wait(const Duration(milliseconds: 100));
      expect(a.auth.token, 'token-1');
      expect(a.server.sockets, hasLength(1));
    });
  });

  group('coming back to the app', () {
    test('a dropped transport is nudged to reconnect', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      final before = s.connectCalls;
      await a.svc.onResume();
      expect(s.connectCalls, before + 1);
    });

    test('connected but unsubscribed asks again', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      await a.svc.onResume();
      expect(s.joins, 2);
    });

    test('a till already listening is left alone — no extra replay transaction', () async {
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      await a.svc.onResume();
      await a.svc.onResume();
      expect(s.joins, 1);
      expect(s.connectCalls, 1);
    });

    // The two below run in testWidgets for its fake clock: the empty-window
    // retry is 150 real seconds, and an hour of service has to pass in a test.
    Future<({PrinterService svc, _FakeSocket s})> listeningTill() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'printer_net_outlet-1': <String>['tcp://192.168.1.50:9100'],
        'selected_printer': 'tcp://192.168.1.50:9100',
      });
      final a = await agent();
      await a.svc.start(a.auth);
      final s = a.server.last;
      s.serverSends('connect');
      s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      return (svc: a.svc, s: s);
    }

    // A LONG-RUNNING TILL IS NOT A PAUSED CATCH-UP. Every live docket that
    // drains arms the empty-window retry, and each quiet gap after it spends one
    // of the 25 rounds — so an ordinary till reaches the cap within an hour or
    // two of service without ever having had a backlog. Reading that cap as
    // "paused" re-joined a listening socket on every window focus (a replay
    // transaction each) and handed back a fresh 25-round budget every time.
    testWidgets('a till that spent its retry rounds on quiet gaps is still left alone', (tester) async {
      final t = await listeningTill();
      Future<void> liveDocketsWithQuietGaps(String prefix) async {
        for (var i = 0; i < 30; i++) {
          t.s.serverSends('bill:print', {'billId': '$prefix-$i', 'escBase64': 'SGVsbG8='});
          await tester.pump();
          await tester.pump(const Duration(seconds: 151));
        }
      }

      await liveDocketsWithQuietGaps('A');
      expect(t.svc.logs.where((l) => l.contains('Printed A-')), hasLength(30));
      expect(t.s.joins, 26, reason: 'precondition: the connect join, then all 25 retry rounds spent');
      expect(t.svc.subscribed, isTrue);

      await t.svc.onResume();
      await t.svc.onResume();
      expect(t.s.joins, 26, reason: 'no replay transaction for a window regaining focus');

      await liveDocketsWithQuietGaps('B');
      expect(t.s.joins, 26, reason: 'and no fresh retry budget handed out by the resume either');
      await t.svc.stop();
    });

    testWidgets('a catch-up that really paused at its cap is continued by coming back, once', (tester) async {
      final t = await listeningTill();
      // 26 re-sent dockets: each of the first 25 drains into a request for the
      // next window; the 26th arrives with the budget spent.
      for (var i = 0; i <= 25; i++) {
        t.s.serverSends('bill:print', {'billId': 'R-$i', 'escBase64': 'SGVsbG8=', 'replay': true});
        await tester.pump();
      }
      expect(t.s.joins, 26);
      expect(t.svc.logs.any((l) => l.contains('Paused catching up')), isTrue);

      await t.svc.onResume();
      expect(t.s.joins, 27, reason: 'coming back to the app is the reconnect the log asked for');
      await t.svc.onResume();
      expect(t.s.joins, 27, reason: 'once — the next resume finds nothing paused');
      await t.svc.stop();
    });

    testWidgets('a reconnect already restarted a paused catch-up, so a resume after it adds nothing', (tester) async {
      final t = await listeningTill();
      for (var i = 0; i <= 25; i++) {
        t.s.serverSends('bill:print', {'billId': 'R-$i', 'escBase64': 'SGVsbG8=', 'replay': true});
        await tester.pump();
      }
      expect(t.svc.logs.any((l) => l.contains('Paused catching up')), isTrue);

      t.s.serverSends('disconnect');
      t.s.serverSends('connect'); // its join is the continue
      t.s.serverSends('joinedOutlet', {'outletId': 'outlet-1'});
      expect(t.s.joins, 27);
      await t.svc.onResume();
      expect(t.s.joins, 27);
      await t.svc.stop();
    });
  });

  group('wiring', () {
    // Built-but-never-called is this project's most repeated defect. These pin
    // the call sites, not just the methods.
    test('HomeShell observes the app lifecycle and forwards a resume to the agent', () {
      final src = File('lib/screens/home_shell.dart').readAsStringSync();
      expect(src, contains('with WidgetsBindingObserver'));
      expect(src, contains('WidgetsBinding.instance.addObserver(this)'));
      expect(src, contains('WidgetsBinding.instance.removeObserver(this)'));
      expect(src, matches(RegExp(r'AppLifecycleState\.resumed[\s\S]{0,120}PrinterService\.instance\.onResume\(\)')));
    });

    test('the printer screen renders the three-state link, not the bare transport flag', () {
      final src = File('lib/screens/modules.dart').readAsStringSync();
      expect(src, contains('printerLinkStatus(svc.linkState'));
      expect(src, isNot(contains("svc.connected ? 'Connected' : 'Offline'")));
    });

    test('production connections go through socketOptions and the io factory', () {
      final src = File('lib/services/printer_service.dart').readAsStringSync();
      expect(src, contains('.enableForceNew()'));
      expect(src, contains('AgentSocketFactory _socketFactory = ioSocketFactory;'));
      expect(src, contains("socket.on('joinRejected'"));
      expect(src, isNot(contains('io.io(AppConfig.backendUrl')),
          reason: 'a direct io.io() call would bypass forceNew and the dispose-first rule');
    });
  });
}
