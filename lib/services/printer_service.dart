import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import 'auth_controller.dart';
import 'restaurant_time.dart';
import 'win_raw_printer.dart';

class PrintJob {
  final String billId;
  final List<int> bytes;
  int attempts = 0;
  PrintJob(this.billId, this.bytes);
}

/// Built-in thermal printer agent: subscribes to the backend's `bill:print`
/// realtime events and sends the raw ESC/POS bytes to the selected Windows
/// printer — so the owner app prints bills itself, with no separate .exe.
///
/// Singleton because the socket + print queue are device-wide and must keep
/// running in the background regardless of which module screen is open.
class PrinterService extends ChangeNotifier {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  static const _printerKey = 'selected_printer';

  io.Socket? _socket;
  AuthController? _auth;
  Timer? _keepAlive;
  bool _processing = false;
  bool _started = false;

  bool _connected = false;
  bool _paused = false;
  String? _selectedPrinter;
  List<String> _printers = const [];
  final List<PrintJob> _queue = [];
  final List<String> _logs = [];

  bool get supported => WinRawPrinter.supported;
  bool get connected => _connected;
  bool get paused => _paused;
  String? get selectedPrinter => _selectedPrinter;
  List<String> get printers => _printers;
  List<PrintJob> get queue => List.unmodifiable(_queue);
  List<String> get logs => List.unmodifiable(_logs);

  void _log(String msg) {
    // Restaurant time, like every other timestamp the app shows — a print log
    // read against an order list has to line up with it.
    _logs.insert(0, '[${RestaurantTime.clockNow()}] $msg');
    if (_logs.length > 200) _logs.removeRange(200, _logs.length);
    notifyListeners();
  }

  /// Connect + subscribe for the signed-in session. Idempotent.
  Future<void> start(AuthController auth) async {
    _auth = auth;
    if (!supported) {
      _log('Printing is only supported on Windows.');
      return;
    }
    if (_started) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    _selectedPrinter = prefs.getString(_printerKey);
    discoverPrinters();

    final token = auth.token;
    final profile = auth.profile;
    if (token == null || profile == null) {
      _log('Not signed in — cannot start printer.');
      return;
    }
    final resId = profile.resId;
    final outletId = (auth.selectedOutletId != null && auth.selectedOutletId!.isNotEmpty)
        ? auth.selectedOutletId!
        : profile.outletId;

    _log('Connecting to realtime…');
    try {
      final opts = io.OptionBuilder()
          // websocket first, polling fallback (matches the backend's accepted
          // transports) so it still connects behind proxies that block WS upgrade.
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .enableReconnection()
          .setAuth({'token': token, 'restaurantId': resId})
          .build();
      final socket = io.io(AppConfig.backendUrl, opts);
      _socket = socket;

      socket.onConnect((_) {
        _connected = true;
        _log('Connected to realtime');
        socket.emit('joinOutlet', {'restaurantId': resId, 'outletId': outletId});
        notifyListeners();
      });
      socket.onDisconnect((_) {
        _connected = false;
        _log('Disconnected from realtime');
        notifyListeners();
      });
      socket.onConnectError((e) => _log('Connect error: $e'));
      socket.onError((e) => _log('Socket error: $e'));
      socket.on('joinedOutlet', (_) => _log('Subscribed to outlet $outletId'));
      socket.on('bill:print', _onBillPrint);

      socket.connect();
    } catch (e) {
      _log('Failed to connect: $e');
    }

    // Keep the session warm so a long-idle till still prints after a reconnect.
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(minutes: 25), (_) async {
      final t = _auth?.token;
      if (t == null) return;
      try {
        await _auth!.api.me(t);
      } catch (_) {/* surfaced elsewhere if the session is truly gone */}
    });
  }

  Future<void> stop() async {
    _started = false;
    _connected = false;
    _keepAlive?.cancel();
    _keepAlive = null;
    try {
      _socket?.dispose();
    } catch (_) {/* ignore */}
    _socket = null;
    _queue.clear();
    notifyListeners();
  }

  void _onBillPrint(dynamic data) {
    Map? payload;
    if (data is Map) {
      payload = data;
    } else if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) payload = d;
      } catch (_) {/* not JSON */}
    }
    final b64 = payload?['escBase64'];
    if (b64 is! String || b64.isEmpty) {
      _log('Received bill:print without escBase64');
      return;
    }
    final billId = '${payload?['billId'] ?? 'bill_${DateTime.now().millisecondsSinceEpoch}'}';
    List<int> bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      _log('Bad escBase64 for $billId');
      return;
    }
    _queue.add(PrintJob(billId, bytes));
    _log('Queued $billId (${bytes.length} bytes)');
    notifyListeners();
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_processing || _paused) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty && !_paused) {
        final printer = _selectedPrinter;
        if (printer == null || printer.isEmpty) {
          _log('No printer selected — ${_queue.length} job(s) waiting.');
          break; // leave jobs queued until a printer is chosen
        }
        final job = _queue.first;
        final ok = WinRawPrinter.sendBytes(printer, job.bytes);
        if (ok) {
          _queue.removeAt(0);
          _log('Printed ${job.billId}');
        } else {
          job.attempts++;
          if (job.attempts >= 3) {
            _queue.removeAt(0);
            _log('Gave up on ${job.billId} after ${job.attempts} attempts');
          } else {
            _log('Print failed for ${job.billId} (attempt ${job.attempts}) — retrying');
            notifyListeners();
            await Future.delayed(const Duration(seconds: 2));
          }
        }
        notifyListeners();
      }
    } finally {
      _processing = false;
    }
  }

  void discoverPrinters() {
    _printers = WinRawPrinter.listPrinters();
    // Auto-pick when there's exactly one, or keep a still-valid saved choice.
    if (_selectedPrinter != null && !_printers.contains(_selectedPrinter)) {
      // saved printer no longer present; keep the name but warn
      _log('Saved printer "$_selectedPrinter" not found among installed printers.');
    }
    if ((_selectedPrinter == null || _selectedPrinter!.isEmpty) && _printers.length == 1) {
      setSelectedPrinter(_printers.first);
    }
    _log('Discovered ${_printers.length} printer(s)');
    notifyListeners();
  }

  Future<void> setSelectedPrinter(String name) async {
    _selectedPrinter = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_printerKey, name);
    _log('Default printer set to "$name"');
    notifyListeners();
    _processQueue(); // flush anything that was waiting on a printer
  }

  void setPaused(bool value) {
    _paused = value;
    _log(value ? 'Printing paused' : 'Printing resumed');
    notifyListeners();
    if (!value) _processQueue();
  }

  void clearQueue() {
    _queue.clear();
    _log('Queue cleared');
    notifyListeners();
  }

  /// Print a tiny ESC/POS test slip to verify the selected printer works.
  bool testPrint() {
    final printer = _selectedPrinter;
    if (printer == null || printer.isEmpty) {
      _log('Select a printer first.');
      return false;
    }
    // ESC @ (init), centered text, feed, full cut.
    final bytes = <int>[
      0x1b, 0x40,
      0x1b, 0x61, 0x01,
      ...utf8.encode('Restaurant Dash\n'),
      ...utf8.encode('Printer test OK\n'),
      ...utf8.encode('${RestaurantTime.stampNow()}\n'),
      0x0a, 0x0a, 0x0a,
      0x1d, 0x56, 0x00,
    ];
    final ok = WinRawPrinter.sendBytes(printer, bytes);
    _log(ok ? 'Test slip sent to "$printer"' : 'Test print failed on "$printer"');
    notifyListeners();
    return ok;
  }
}
