import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads a new build and installs it in-app.
///
/// * Android — downloads the `.apk` and hands it to the OS package installer
///   (the user taps "Install"; the app stays open).
/// * Windows — downloads the flat `.zip`, extracts it, then launches a detached
///   helper batch that waits for this exe to exit, robocopies the new bundle
///   over the install dir, relaunches, and cleans up. This process `exit(0)`s
///   itself so the exe/DLLs unlock.
///
/// Anything unsupported or any failure defers to [fallback] (which the caller
/// wires to a browser download) so the flow never regresses below today's.
class AppUpdater {
  /// Basename of a path, tolerant of both `/` and `\` separators.
  static String _basename(String path) {
    final n = path.replaceAll('\\', '/');
    final i = n.lastIndexOf('/');
    return i < 0 ? n : n.substring(i + 1);
  }

  /// Normalise a path to Windows-native backslashes (for the .bat).
  static String _win(String path) => path.replaceAll('/', '\\');

  Future<void> downloadAndInstall(
    String url, {
    required void Function(double) onProgress,
    required Future<void> Function() fallback,
  }) async {
    try {
      if (!Platform.isAndroid && !Platform.isWindows) {
        await fallback();
        return;
      }

      // Fresh work dir under the temp directory.
      final tmp = await getTemporaryDirectory();
      final workDir = Directory('${tmp.path}/restaurantdash_update');
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      workDir.createSync(recursive: true);

      // Download name from the URL (falls back to a generic name).
      var name = _basename(Uri.parse(url).path);
      if (name.trim().isEmpty) name = Platform.isAndroid ? 'update.apk' : 'update.zip';
      final file = File('${workDir.path}/$name');

      // --- (a) streaming download with progress ---
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        final resp = await client.send(req);
        if (resp.statusCode != 200) {
          throw HttpException('Download failed (${resp.statusCode})', uri: Uri.parse(url));
        }
        final total = resp.contentLength ?? 0;
        var received = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in resp.stream) {
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) onProgress(received / total);
          }
        } finally {
          await sink.close();
        }
      } finally {
        client.close();
      }

      // --- (b) Android: launch the OS package installer ---
      if (Platform.isAndroid) {
        final r = await OpenFilex.open(
          file.path,
          type: 'application/vnd.android.package-archive',
        );
        if (r.type != ResultType.done) {
          throw StateError('Installer did not start: ${r.type} ${r.message}');
        }
        return; // app stays open; user taps Install in the OS UI
      }

      // --- (c) Windows: extract, then a detached self-applying batch ---
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final extractDir = Directory('${workDir.path}/extracted');
      extractDir.createSync(recursive: true);
      // Sanity target for the payload check below: the zip must be FLAT, with the
      // running exe's own basename at its root.
      final exeNameExpected = _basename(Platform.resolvedExecutable);
      // The release zip is produced by PowerShell's Compress-Archive, which stores
      // nested entries with BACKSLASH separators ("data\flutter_assets\..."). Used
      // verbatim, those never create the intermediate directories, so the extracted
      // tree came out wrong and the update silently fell back to a browser download
      // every single time. Normalise to '/' and drop any leading/parent segments
      // (also closes zip-slip).
      var filesWritten = 0;
      for (final entry in archive) {
        final rel = entry.name
            .replaceAll('\\', '/')
            .split('/')
            .where((seg) => seg.isNotEmpty && seg != '.' && seg != '..')
            .join('/');
        if (rel.isEmpty) {continue;}
        final outPath = '${extractDir.path}/$rel';
        if (entry.isFile) {
          final data = entry.content as List<int>;
          File(outPath)
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
          filesWritten++;
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      }
      // Fail LOUDLY rather than handing the batch an empty directory: copying
      // nothing over the install dir is far worse than telling the user to update
      // manually. Also assert the payload actually looks like the app.
      if (filesWritten == 0) {
        throw StateError('Update archive contained no files (${archive.length} entries) — nothing to install.');
      }
      if (!File('${extractDir.path}/$exeNameExpected').existsSync()) {
        throw StateError('Update archive does not contain $exeNameExpected at its root — refusing to copy it over the install directory.');
      }

      final exePath = Platform.resolvedExecutable;
      final installDir = File(exePath).parent.path;
      final exeName = _basename(exePath);
      final batPath = '${workDir.path}/apply_update.bat';
      await File(batPath).writeAsString(_windowsBatch(
        extractRoot: _win(extractDir.path),
        installDir: _win(installDir),
        exeName: exeName,
        waitPid: pid,
      ));

      // Detach so it outlives our exit, then quit so the exe/DLLs unlock.
      // Launched via `start /min` so the helper runs as a minimized, properly
      // titled window instead of a bare console in the user's face.
      await Process.start(
        'cmd',
        ['/c', 'start', 'Restaurant Dash update', '/min', batPath],
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (_) {
      await fallback();
    }
  }

  /// Waits for the launching PROCESS (by PID — never by image name, so a second
  /// instance or a debug build with the same exe name can't deadlock the wait)
  /// to exit, robocopies the freshly-extracted flat bundle over the install dir
  /// (never delete-mirrors), relaunches the app, then removes the extract dir
  /// and self-deletes. Gives up after ~2 minutes without touching the install.
  static String _windowsBatch({
    required String extractRoot,
    required String installDir,
    required String exeName,
    required int waitPid,
  }) {
    final lines = <String>[
      '@echo off',
      'setlocal',
      'title Restaurant Dash update',
      'set tries=0',
      ':waitloop',
      // The PID is space-delimited in tasklist output; match " <pid> " exactly
      // so e.g. waiting on 5249 can never match a running 52496. findstr (not
      // find) on purpose: GNU find from Git's Unix tools can shadow Windows
      // find on PATH and break the check; findstr exists only in System32.
      'tasklist /FI "PID eq $waitPid" 2>nul | findstr /C:" $waitPid " >nul',
      'if errorlevel 1 goto swap',
      'set /a tries+=1',
      'if %tries% GEQ 120 exit /b 1',
      'timeout /t 1 /nobreak >nul 2>&1',
      'goto waitloop',
      ':swap',
      'robocopy "$extractRoot" "$installDir" /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS',
      'start "" "$installDir\\$exeName"',
      'rmdir /s /q "$extractRoot"',
      '(goto) 2>nul & del "%~f0"',
    ];
    return '${lines.join('\r\n')}\r\n';
  }
}
