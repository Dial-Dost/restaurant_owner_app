import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_result.dart';

/// Downloads a new build and installs it in-app.
///
/// * Android — downloads the `.apk` and hands it to the OS package installer
///   (the user taps "Install"; the app stays open). UNCHANGED.
/// * Windows — downloads the flat `.zip`, extracts it, then launches a detached
///   helper batch that waits for this exe to exit, robocopies the new bundle
///   over the install dir, relaunches, and cleans up. This process `exit(0)`s
///   itself so the exe/DLLs unlock.
///
/// THE BUG THIS FIXES, from a customer's Windows machine (video). The app said
/// "Version 2.0.2 is available (you have 1.9.9)", the user clicked Update, the
/// app closed and reopened — on 1.9.9, showing the same dialog. Forever.
///
/// The download, the extraction and the batch handoff were all fine. What was
/// missing was any notion of whether the COPY worked. The old batch ran
/// `robocopy ... /NFL /NDL /NJH /NJS`, discarded its exit code, relaunched the
/// exe it had just failed to replace, and deleted itself along with any trace
/// of what happened. robocopy exit codes >= 8 are failures and exit code 0
/// means "copied nothing"; both looked identical to success.
///
/// The likeliest cause is an install directory the user cannot write (anything
/// under `C:\Program Files\`), but a file held open by antivirus or a lingering
/// process produces the same silence. So this is fixed in three layers rather
/// than betting on one:
///
///  1. PRE-FLIGHT — before spending 18MB of the customer's bandwidth, prove the
///     install directory is writable by creating and deleting a file in it.
///     If it isn't, say so by name and offer administrator / manual routes.
///  2. AN HONEST BATCH — log everything (kept on failure), capture robocopy's
///     exit code, treat >= 8 AND 0 as failures, retry once elevated through
///     UAC, and write a JSON receipt the app reads on next launch.
///  3. A VERDICT ON NEXT LAUNCH — see [reviewUpdateAttempt]: if the app comes
///     back on the version it was supposed to have replaced, that is a failure
///     no matter what the batch claimed.
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

  /// Escape for embedding inside a `set "X=..."` in a batch file: a literal `%`
  /// would otherwise start a variable expansion.
  static String _bat(String value) => value.replaceAll('%', '%%');

  /// Escape for embedding inside a JSON string literal we `echo` out of batch.
  static String _json(String value) =>
      value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

  Future<void> downloadAndInstall(
    String url, {
    required void Function(double) onProgress,
    required Future<void> Function() fallback,
    String? version,

    /// Called INSTEAD of downloading when the install directory cannot be
    /// written. Receives the directory so the UI can name it. When null, the
    /// unwritable case simply falls back to the browser, as before.
    Future<void> Function(String installDir)? onInstallDirNotWritable,

    /// Skip the pre-flight and tell the helper to ask for administrator rights
    /// up front. This is what the failure card's "Retry as administrator" does.
    bool elevated = false,

    /// Injected so the pre-flight check is testable off-Windows.
    InstallDirProbe probe = const RealInstallDirProbe(),
  }) async {
    try {
      if (!Platform.isAndroid && !Platform.isWindows) {
        await fallback();
        return;
      }

      // --- (0) Windows pre-flight: can we even write where we are installed? ---
      // Done BEFORE the download: there is no point pulling 18MB over a café
      // connection to discover the copy was never going to be permitted. Note
      // this probes the DIRECTORY, not the exe — the exe is locked by us right
      // now by definition, so only the batch can meaningfully test that.
      final installDir = File(Platform.resolvedExecutable).parent.path;
      if (Platform.isWindows && !elevated) {
        if (!await canUpdateInPlace(installDir, probe: probe)) {
          if (onInstallDirNotWritable != null) {
            await onInstallDirNotWritable(installDir);
          } else {
            await fallback();
          }
          return;
        }
      }

      // Work dir under the temp directory. Only `work` is wiped — the log and
      // the receipt from a previous failure live one level up and must survive.
      final tmp = await getTemporaryDirectory();
      final paths = UpdatePaths.under(tmp.path);
      Directory(paths.base).createSync(recursive: true);
      final workDir = Directory(paths.workDir);
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      workDir.createSync(recursive: true);

      // Download name from the URL (falls back to a generic name).
      var name = _basename(Uri.parse(url).path);
      if (name.trim().isEmpty) name = Platform.isAndroid ? 'update.apk' : 'update.zip';
      final file = File('${paths.workDir}/$name');

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
      final extractDir = Directory(paths.extractDir);
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
      final exeName = _basename(exePath);
      await File(paths.batPath).writeAsString(windowsBatch(
        extractRoot: _win(paths.extractDir),
        installDir: _win(installDir),
        exeName: exeName,
        waitPid: pid,
        version: (version ?? '').trim(),
        logPath: _win(paths.logPath),
        resultPath: _win(paths.resultPath),
        elevateFirst: elevated,
      ));

      // Detach so it outlives our exit, then quit so the exe/DLLs unlock.
      // Launched via `start /min` so the helper runs as a minimized, properly
      // titled window instead of a bare console in the user's face.
      await Process.start(
        'cmd',
        ['/c', 'start', 'Restaurant Dash update', '/min', _win(paths.batPath)],
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (_) {
      await fallback();
    }
  }

  /// THE PRE-FLIGHT. True when a self-update stands a chance of working.
  ///
  /// Split out from [downloadAndInstall] — which can only run on Windows — so
  /// the decision itself is testable anywhere with a fake [InstallDirProbe].
  /// A blank directory is treated as unwritable: we would not know where to
  /// copy to, and guessing is how you overwrite the wrong folder.
  static Future<bool> canUpdateInPlace(
    String installDir, {
    InstallDirProbe probe = const RealInstallDirProbe(),
  }) async {
    if (installDir.trim().isEmpty) return false;
    return probe.isWritable(installDir);
  }

  /// The helper batch, in full.
  ///
  /// Public because its behaviour IS the fix and is unit-tested: it must log,
  /// must read robocopy's exit code, must retry elevated, and must never delete
  /// the log — the old one did none of those things.
  ///
  /// Shape:
  ///   1. wait for PID [waitPid] to disappear (bounded, ~5 min — longer than
  ///      the old 2, because antivirus can hold a dying process for a while);
  ///   2. wait for the installed exe to become writable (a `>>file (call )`
  ///      probe, the standard batch test for "unlocked AND permitted");
  ///   3. robocopy, capturing the exit code and the output into the log;
  ///   4. on failure (>= 8) or no-op (== 0), retry once through UAC;
  ///   5. write the JSON receipt, THEN relaunch, and keep the log + this file
  ///      unless everything worked.
  static String windowsBatch({
    required String extractRoot,
    required String installDir,
    required String exeName,
    required int waitPid,
    required String version,
    required String logPath,
    required String resultPath,
    bool elevateFirst = false,
  }) {
    // robocopy flags: /E all subdirs incl. empty, /IS include same-size files
    // (a rebuild of the same version must still overwrite), /IT include
    // tweaked. NEVER /MIR — a delete-mirror of a wrong source destroys the
    // install. /NFL /NDL are dropped: we now want the file list in the log.
    const rcFlags = '/E /IS /IT /R:3 /W:1 /NP';
    // The directory the log lives in, taken off the log path itself so the two
    // can never drift apart.
    final logDir = logPath.contains('\\')
        ? logPath.substring(0, logPath.lastIndexOf('\\'))
        : logPath;
    final lines = <String>[
      '@echo off',
      'setlocal',
      'title Restaurant Dash update',
      'set "SRC=${_bat(extractRoot)}"',
      'set "DST=${_bat(installDir)}"',
      'set "EXE=${_bat(exeName)}"',
      'set "LOG=${_bat(logPath)}"',
      'set "LOGDIR=${_bat(logDir)}"',
      'set "RESULT=${_bat(resultPath)}"',
      'set "VER=${_bat(version)}"',
      'set "OK=0"',
      'set "RC=-1"',
      // The log directory already exists (the app made it before writing this
      // file), but create it anyway: a user or support may re-run this batch by
      // hand long after the work dir was cleaned up, and a batch whose very
      // first act is a redirect into a missing directory dies silently.
      'if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1',
      '>>"%LOG%" echo ==================================================',
      '>>"%LOG%" echo Restaurant Dash update  %DATE% %TIME%',
      '>>"%LOG%" echo target version : %VER%',
      '>>"%LOG%" echo install dir    : %DST%',
      '>>"%LOG%" echo payload        : %SRC%',
      '>>"%LOG%" echo waiting for pid: $waitPid',
      // --- 1. wait for the old process to go ---
      'set tries=0',
      ':waitloop',
      // The PID is space-delimited in tasklist output; match " <pid> " exactly
      // so e.g. waiting on 5249 can never match a running 52496. findstr (not
      // find) on purpose: GNU find from Git's Unix tools can shadow Windows
      // find on PATH and break the check; findstr exists only in System32.
      'tasklist /FI "PID eq $waitPid" 2>nul | findstr /C:" $waitPid " >nul',
      'if errorlevel 1 goto unlocked',
      'set /a tries+=1',
      'if %tries% GEQ 300 goto stillrunning',
      'timeout /t 1 /nobreak >nul 2>&1',
      'goto waitloop',
      ':stillrunning',
      '>>"%LOG%" echo FAILED: the old app (pid $waitPid) was still running after %tries% seconds.',
      'call :writeresult failed -1 "The previous copy of the app never closed, so its files could not be replaced."',
      'goto finish',
      ':unlocked',
      '>>"%LOG%" echo old process gone after %tries% seconds',
      // --- 2. wait for the installed exe to actually be writable ---
      // `>>file (call )` opens the file for append and writes nothing: it fails
      // if the file is locked by another process OR if we lack permission. This
      // is the last chance to notice before we start overwriting DLLs.
      'set wtries=0',
      ':exewait',
      'if not exist "%DST%\\%EXE%" goto probedone',
      '2>nul (>>"%DST%\\%EXE%" (call )) && goto probedone',
      'set /a wtries+=1',
      'if %wtries% GEQ 30 goto lockedexe',
      'timeout /t 1 /nobreak >nul 2>&1',
      'goto exewait',
      ':lockedexe',
      '>>"%LOG%" echo WARNING: %DST%\\%EXE% is still not writable after %wtries% seconds - trying anyway',
      ':probedone',
      if (elevateFirst) ...[
        '>>"%LOG%" echo retry requested WITH administrator rights - skipping the plain copy',
        'goto elevate',
      ],
      // --- 3. the copy, with its exit code kept ---
      ':docopy',
      '>>"%LOG%" echo --- robocopy %SRC% -^> %DST% ---',
      'robocopy "%SRC%" "%DST%" $rcFlags >>"%LOG%" 2>&1',
      'set RC=%ERRORLEVEL%',
      '>>"%LOG%" echo robocopy exit code: %RC%',
      // robocopy: 0 = nothing copied, 1..7 = copied/extra/mismatch (success),
      // >= 8 = at least one file or directory could not be copied. Since the
      // payload is a different build copied with /IS, "nothing copied" can only
      // mean the copy never happened — it is a failure, not a no-change.
      'if %RC% GEQ 8 goto elevate',
      'if %RC% EQU 0 goto elevate',
      '>>"%LOG%" echo copy applied.',
      'set "OK=1"',
      'call :writeresult applied %RC% "Update applied."',
      'goto finish',
      // --- 4. one elevated retry, which raises a UAC prompt ---
      ':elevate',
      '>>"%LOG%" echo plain copy did not apply (exit %RC%) - retrying with administrator rights',
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "try { \$p = Start-Process -FilePath \'robocopy.exe\' -ArgumentList (\'\\"\'+\$env:SRC+\'\\"\'),(\'\\"\'+\$env:DST+\'\\"\'),\'/E\',\'/IS\',\'/IT\',\'/R:1\',\'/W:1\',\'/NP\',(\'\\"/LOG+:\'+\$env:LOG+\'\\"\') -Verb RunAs -Wait -PassThru; exit \$p.ExitCode } catch { exit 99 }"',
      'set RC2=%ERRORLEVEL%',
      '>>"%LOG%" echo elevated robocopy exit code: %RC2%',
      'if %RC2% EQU 99 goto denied',
      'if %RC2% GEQ 8 goto copyfailed',
      'if %RC2% EQU 0 goto copyfailed',
      '>>"%LOG%" echo copy applied with administrator rights.',
      'set "OK=1"',
      'call :writeresult applied %RC2% "Update applied after an administrator prompt."',
      'goto finish',
      ':denied',
      '>>"%LOG%" echo elevation refused or unavailable.',
      'call :writeresult denied %RC% "Windows blocked the update: the app is installed in a folder that needs administrator permission."',
      'goto finish',
      ':copyfailed',
      '>>"%LOG%" echo elevated copy also failed (exit %RC2%).',
      'call :writeresult failed %RC2% "The new files could not be copied over the installed app."',
      'goto finish',
      // --- 5. receipt first, relaunch second, cleanup only if it all worked ---
      ':finish',
      '>>"%LOG%" echo relaunching %DST%\\%EXE%',
      'start "" "%DST%\\%EXE%"',
      '>>"%LOG%" echo ==== end (ok=%OK%) ====',
      // On failure the log AND this batch stay put: they are the only evidence
      // the user or we can look at, and the app hands out the log path.
      'if not "%OK%"=="1" exit /b 1',
      'rmdir /s /q "%SRC%" >nul 2>&1',
      '(goto) 2>nul & del "%~f0"',
      // --- the receipt writer: %1 outcome, %2 robocopy exit, %3 message ---
      ':writeresult',
      '>"%RESULT%" echo {',
      '>>"%RESULT%" echo   "version": "%VER%",',
      '>>"%RESULT%" echo   "outcome": "%~1",',
      '>>"%RESULT%" echo   "robocopy_exit": %~2,',
      '>>"%RESULT%" echo   "install_dir": "${_bat(_json(installDir))}",',
      '>>"%RESULT%" echo   "log": "${_bat(_json(logPath))}",',
      '>>"%RESULT%" echo   "message": "%~3",',
      '>>"%RESULT%" echo   "timestamp": "%DATE% %TIME%"',
      '>>"%RESULT%" echo }',
      '>>"%LOG%" echo receipt: outcome=%~1 robocopy_exit=%~2',
      'exit /b 0',
    ];
    return '${lines.join('\r\n')}\r\n';
  }
}

/// "Can we write here?", injectable so the pre-flight is testable on any OS.
abstract class InstallDirProbe {
  Future<bool> isWritable(String dir);
}

/// The real thing: create a file next to the exe, then delete it. Nothing else
/// tells the truth about a Windows ACL — `Directory.existsSync` and friends all
/// say yes for `C:\Program Files\`.
class RealInstallDirProbe implements InstallDirProbe {
  const RealInstallDirProbe();

  @override
  Future<bool> isWritable(String dir) async {
    File? f;
    try {
      f = File('$dir${Platform.pathSeparator}.restaurantdash_write_test_$pid.tmp');
      await f.writeAsString('probe', flush: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (f != null && f.existsSync()) f.deleteSync();
      } catch (_) {/* leaving a 5-byte probe file behind is not worth failing on */}
    }
  }
}
