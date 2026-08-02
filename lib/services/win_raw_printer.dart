import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Sends raw ESC/POS bytes straight to a Windows spooler printer (RAW datatype),
/// and enumerates installed printers — a Dart `dart:ffi` port of the standalone
/// agent's C# `RawPrinterHelper` (winspool.drv: OpenPrinter/StartDocPrinter/
/// WritePrinter/…). Windows-only; every method is a no-op/empty elsewhere.
///
/// This is what lets the owner app drive a thermal printer directly, so there is
/// no separate printer .exe — the app IS the printer agent.

// DOC_INFO_1A { LPSTR pDocName; LPSTR pOutputFile; LPSTR pDatatype; }
final class _DocInfo1 extends Struct {
  external Pointer<Utf8> pDocName;
  external Pointer<Utf8> pOutputFile;
  external Pointer<Utf8> pDatatype;
}

// PRINTER_INFO_4A { LPSTR pPrinterName; LPSTR pServerName; DWORD Attributes; }
final class _PrinterInfo4 extends Struct {
  external Pointer<Utf8> pPrinterName;
  external Pointer<Utf8> pServerName;
  @Uint32()
  external int attributes;
}

class WinRawPrinter {
  WinRawPrinter._();

  static DynamicLibrary? _lib;
  static DynamicLibrary get _winspool => _lib ??= DynamicLibrary.open('winspool.drv');

  // BOOL OpenPrinterA(LPSTR, LPHANDLE, LPVOID)
  static final _openPrinter = _winspool.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<IntPtr>, Pointer<Void>),
      int Function(Pointer<Utf8>, Pointer<IntPtr>, Pointer<Void>)>('OpenPrinterA');

  // BOOL ClosePrinter(HANDLE)
  static final _closePrinter = _winspool
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('ClosePrinter');

  // DWORD StartDocPrinterA(HANDLE, DWORD level, LPBYTE pDocInfo)
  static final _startDocPrinter = _winspool.lookupFunction<
      Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>),
      int Function(int, int, Pointer<_DocInfo1>)>('StartDocPrinterA');

  // BOOL StartPagePrinter(HANDLE)
  static final _startPagePrinter = _winspool
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('StartPagePrinter');

  // BOOL WritePrinter(HANDLE, LPVOID, DWORD, LPDWORD)
  static final _writePrinter = _winspool.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)>('WritePrinter');

  // BOOL EndPagePrinter(HANDLE) / BOOL EndDocPrinter(HANDLE)
  static final _endPagePrinter = _winspool
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndPagePrinter');
  static final _endDocPrinter = _winspool
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndDocPrinter');

  // BOOL EnumPrintersA(DWORD Flags, LPSTR Name, DWORD Level, LPBYTE, DWORD, LPDWORD, LPDWORD)
  static final _enumPrinters = _winspool.lookupFunction<
      Int32 Function(Uint32, Pointer<Utf8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>),
      int Function(int, Pointer<Utf8>, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>)>('EnumPrintersA');

  static const int _printerEnumLocal = 0x00000002;
  static const int _printerEnumConnections = 0x00000004;

  static bool get supported => Platform.isWindows;

  /// All installed/connected printers (by name). Empty off Windows or on error.
  static List<String> listPrinters() {
    if (!Platform.isWindows) return [];
    final pcbNeeded = calloc<Uint32>();
    final pcReturned = calloc<Uint32>();
    try {
      const flags = _printerEnumLocal | _printerEnumConnections;
      const level = 4;
      // First call sizes the buffer.
      _enumPrinters(flags, nullptr, level, nullptr, 0, pcbNeeded, pcReturned);
      final size = pcbNeeded.value;
      if (size == 0) return [];
      final buf = calloc<Uint8>(size);
      try {
        final ok = _enumPrinters(flags, nullptr, level, buf, size, pcbNeeded, pcReturned) != 0;
        if (!ok) return [];
        final count = pcReturned.value;
        final structSize = sizeOf<_PrinterInfo4>();
        final names = <String>[];
        for (var i = 0; i < count; i++) {
          final info = Pointer<_PrinterInfo4>.fromAddress(buf.address + i * structSize).ref;
          if (info.pPrinterName != nullptr) {
            try {
              final name = info.pPrinterName.toDartString();
              if (name.isNotEmpty) names.add(name);
            } catch (_) {/* skip a name with a non-UTF8 byte */}
          }
        }
        return names;
      } finally {
        calloc.free(buf);
      }
    } catch (_) {
      return [];
    } finally {
      calloc.free(pcbNeeded);
      calloc.free(pcReturned);
    }
  }

  /// Send [bytes] verbatim to [printerName] as a RAW job. Returns true on success.
  static bool sendBytes(String printerName, List<int> bytes) {
    if (!Platform.isWindows) return false;
    if (printerName.isEmpty || bytes.isEmpty) return false;

    final pName = printerName.toNativeUtf8();
    final phPrinter = calloc<IntPtr>();
    final pWritten = calloc<Uint32>();
    final docName = 'Restaurant Dash Bill'.toNativeUtf8();
    final dataType = 'RAW'.toNativeUtf8();
    final di = calloc<_DocInfo1>();
    final pBuf = calloc<Uint8>(bytes.length);
    try {
      if (_openPrinter(pName, phPrinter, nullptr) == 0) return false;
      final h = phPrinter.value;
      try {
        di.ref.pDocName = docName;
        di.ref.pOutputFile = nullptr;
        di.ref.pDatatype = dataType;
        if (_startDocPrinter(h, 1, di) == 0) return false;
        try {
          if (_startPagePrinter(h) == 0) return false;
          pBuf.asTypedList(bytes.length).setAll(0, bytes);
          final ok = _writePrinter(h, pBuf, bytes.length, pWritten) != 0;
          _endPagePrinter(h);
          return ok && pWritten.value == bytes.length;
        } finally {
          _endDocPrinter(h);
        }
      } finally {
        _closePrinter(h);
      }
    } catch (_) {
      return false;
    } finally {
      calloc.free(pName);
      calloc.free(phPrinter);
      calloc.free(pWritten);
      calloc.free(docName);
      calloc.free(dataType);
      calloc.free(di);
      calloc.free(pBuf);
    }
  }
}
