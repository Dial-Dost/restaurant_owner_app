import 'dart:async';
import 'dart:io';

/// Sends raw ESC/POS bytes to a thermal printer over a TCP socket — the port
/// 9100 "RAW"/JetDirect protocol every network-capable receipt printer speaks.
///
/// WHY THIS EXISTS: PRINTING FROM A PHONE
/// --------------------------------------
/// [WinRawPrinter] hands the bytes to the Windows spooler, which is why printing
/// used to be a Windows-only feature and this app logged "Printing is only
/// supported on Windows." on everything else. That is a statement about the
/// TRANSPORT, not about the app: the backend already renders the finished
/// docket (escpos.ts `buildKotBase64` -> "PrintJobs".esc_base64) and pushes the
/// exact bytes down the `bill:print` socket to whoever is listening. A Windows
/// till writes them to a spooler queue; there is nothing stopping an Android
/// tablet writing the SAME bytes to a socket instead.
///
/// Port 9100 is what makes that a small change rather than a plugin: it is a
/// bare TCP stream that the printer treats as its input buffer, so `dart:io`'s
/// Socket is the whole driver. No native code, no platform channel, no pairing,
/// no runtime permission beyond INTERNET (already declared — the app talks to
/// its backend over HTTP).
///
/// WHAT A SUCCESSFUL SEND DOES AND DOES NOT MEAN
/// ---------------------------------------------
/// It means the bytes were accepted by the printer's TCP stack. It does NOT mean
/// paper came out: 9100 is a one-way pipe with no application-level
/// acknowledgement, so a printer that is out of paper, jammed or with its cover
/// open accepts the job in silence. This is exactly the guarantee the Windows
/// spooler gives (a queued job is not a printed one), so the durable-printing
/// contract above it is unchanged — and it is precisely why the printer screen
/// has a TEST PRINT button. The only honest confirmation is a human seeing paper.
///
/// WHAT IT CANNOT DO: BLUETOOTH. Handheld belt printers are usually Bluetooth
/// (SPP/BLE) rather than networked, and Bluetooth needs a plugin, a pairing UI
/// and the Android 12+ `BLUETOOTH_CONNECT` runtime permission — a materially
/// bigger piece of work than this file. A restaurant whose only kitchen printer
/// is Bluetooth-only gets nothing from this transport, and the printer screen
/// says so rather than offering a control that cannot reach their hardware.
abstract final class NetworkPrinter {
  /// The IANA-registered "pdl-datastream" port, and the factory default on
  /// essentially every Epson/Star/Bixolon/Xprinter Ethernet or Wi-Fi model.
  static const int defaultPort = 9100;

  /// Whether this build can open a raw socket at all.
  ///
  /// True wherever `dart:io` exists, which is every platform this app is built
  /// for (Windows, Android, iOS). It is a constant rather than a platform check
  /// on purpose: unlike winspool, nothing here is Windows-specific, and gating
  /// it per platform would be inventing a restriction the transport does not
  /// have. A web build would fail to compile this import long before it could
  /// ask, so there is no case where this is wrongly true.
  static bool get supported => true;

  /// How long to wait for the printer to answer the connection.
  ///
  /// Short, because the common failure is a printer that is switched off or on
  /// a different subnet, and the waiter is standing at the pass: an answer of
  /// "that address is not responding" in five seconds is worth far more than a
  /// perfect one in sixty. The job is retried after this, so a slow printer that
  /// misses the first window is not lost.
  static const Duration connectTimeout = Duration(seconds: 5);

  /// How long to wait for the bytes to reach the socket once connected.
  static const Duration writeTimeout = Duration(seconds: 10);

  /// A raw host:port target string, as the routing map stores it.
  static String target(String host, int port) => 'tcp://${host.trim()}:$port';

  /// Reject an address before it is saved, so a typo fails at the settings
  /// screen with a sentence rather than at 8pm as a docket nobody printed.
  ///
  /// Returns null when the address is usable, or the reason it is not. The host
  /// is deliberately NOT resolved here — a printer that is merely switched off
  /// must still be configurable — that is what the Test print button is for.
  static String? validate(String host, int port) {
    final h = host.trim();
    if (h.isEmpty) return 'Enter the printer\'s IP address.';
    if (h.contains(' ')) return 'An address cannot contain spaces.';
    if (h.contains('/') || h.contains(':')) {
      return 'Enter just the address (like 192.168.1.50) — the port goes in its own box.';
    }
    if (port < 1 || port > 65535) return 'The port must be between 1 and 65535.';
    return null;
  }

  /// Send [bytes] to [host]:[port] and return null, or the reason it failed.
  ///
  /// A STRING RATHER THAN A BOOL, because the caller has to be able to SAY what
  /// went wrong. "Print failed" on a kitchen docket is the same silent drop that
  /// durable printing exists to remove: "Connection refused" means the address
  /// is right and the printer is off, "No route to host" means the tablet is on
  /// the guest Wi-Fi, and those need different people to do different things.
  static Future<String?> send(
    String host,
    int port,
    List<int> bytes, {
    Duration? connect,
    Duration? write,
  }) async {
    final h = host.trim();
    final invalid = validate(h, port);
    if (invalid != null) return invalid;
    if (bytes.isEmpty) return 'There was nothing to print.';

    Socket? socket;
    try {
      socket = await Socket.connect(h, port, timeout: connect ?? connectTimeout);
      // A docket is one short burst and the pass is waiting for it; there is
      // nothing following it to coalesce with.
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {
        /* an option the platform does not support is not a reason to fail */
      }
      // Drain whatever the printer says back (most say nothing). Without a
      // listener the socket's own close future can never complete.
      socket.listen((_) {}, onError: (_) {}, cancelOnError: false);

      socket.add(bytes);
      // THE ONE STEP THAT DECIDES SUCCESS. flush() completing means the bytes
      // are out of this process and into the connection; anything after it is
      // tidying up.
      await socket.flush().timeout(write ?? writeTimeout);
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // A printer that holds the connection open after taking the job is
        // common and harmless — the bytes have already been flushed. Reporting
        // this as a failure would make the till reprint a docket that is on
        // paper, which is the one outcome worse than a slow close.
      }
      return null;
    } on SocketException catch (e) {
      return _readable(h, port, e);
    } on TimeoutException {
      return 'The printer at $h:$port accepted the connection but did not take the job in time.';
    } catch (e) {
      return 'Could not print to $h:$port — $e';
    } finally {
      try {
        socket?.destroy();
      } catch (_) {
        /* already gone */
      }
    }
  }

  /// A [SocketException] as a sentence someone standing at the till can act on.
  ///
  /// The OS message is kept on the end rather than thrown away — it is what
  /// makes a support call short — but it is never the whole message, because
  /// "OS Error: errno = 111" tells an owner nothing about which of the two
  /// boxes in front of them is wrong.
  static String _readable(String host, int port, SocketException e) {
    final detail = (e.osError?.message ?? e.message).trim();
    final lower = detail.toLowerCase();
    if (lower.contains('refused')) {
      return 'The device at $host answered but refused port $port. '
          'Check the printer\'s port setting (usually 9100). [$detail]';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'No answer from $host:$port. The printer may be switched off, '
          'asleep, or on a different network from this device. [$detail]';
    }
    if (lower.contains('no route') || lower.contains('unreachable') || lower.contains('network is down')) {
      return 'This device cannot reach $host. Both it and the printer have to be '
          'on the same Wi-Fi/LAN. [$detail]';
    }
    if (lower.contains('failed host lookup') || lower.contains('nodename') || lower.contains('not known')) {
      return 'The name "$host" could not be looked up. Use the printer\'s IP '
          'address (like 192.168.1.50). [$detail]';
    }
    return 'Could not print to $host:$port — $detail';
  }
}
