// THE WINDOWS UPDATE THAT NEVER APPLIED.
//
// Reported from a customer's Windows machine, with video. The app says
// "Update available — Version 2.0.2 is available (you have 1.9.9)". The user
// clicks Update. The app closes, relaunches, and shows the SAME dialog, still
// on 1.9.9. Forever.
//
// Everything up to the copy was already correct and is NOT what this pins:
// `app_updater.dart` is byte-identical between 1.9.9 and main (so it is not a
// regression), and the 2.0.2 `RestaurantDash-Windows.zip` is well-formed —
// `restaurant_owner_app.exe` and the DLLs sit at the archive root with `data/`
// beside them, so the updater's "exe at root" sanity check passes.
//
// WHAT WAS WRONG was that nothing ever asked whether the copy worked. The old
// helper batch ran
//
//     robocopy "<extract>" "<installDir>" /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS
//
// then unconditionally relaunched the exe and deleted itself. robocopy exit
// codes >= 8 are failures and exit code 0 means "copied nothing"; both were
// discarded, the output was suppressed by the /N* flags, and the batch erased
// its own trail. So a customer whose install directory is not writable —
// anything under `C:\Program Files\` — got a perfect, silent no-op and the same
// prompt on every launch.
//
// The leading theory is that permission, but a file held open by antivirus or a
// lingering process produces exactly the same silence, so the fix is layered
// and each layer is pinned below:
//
//   1. a PRE-FLIGHT that proves the install dir is writable BEFORE spending
//      18MB of the customer's bandwidth;
//   2. a batch that LOGS (and keeps the log), reads robocopy's exit code,
//      treats >= 8 and 0 as failures, retries once through UAC, and leaves a
//      JSON receipt;
//   3. a verdict on next launch, including the silent no-op: coming back on
//      the old version is a failure whatever the batch claimed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/services/app_updater.dart';
import 'package:restaurant_owner_app/services/update_checker.dart';
import 'package:restaurant_owner_app/services/update_result.dart';

String _batch({bool elevateFirst = false}) => AppUpdater.windowsBatch(
      extractRoot: r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\work\extracted',
      installDir: r'C:\Program Files\Restaurant Dash',
      exeName: 'restaurant_owner_app.exe',
      waitPid: 5249,
      version: '2.0.2',
      logPath: r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update.log',
      resultPath: r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update_result.json',
      elevateFirst: elevateFirst,
    );

/// A probe that answers whatever the test needs, and records what it was asked.
class _FakeProbe implements InstallDirProbe {
  _FakeProbe(this.answer);
  final bool answer;
  final List<String> asked = [];

  @override
  Future<bool> isWritable(String dir) async {
    asked.add(dir);
    return answer;
  }
}

void main() {
  group('the helper batch is honest about what robocopy did', () {
    test('it logs, and the log is the same file the app hands the user', () {
      final b = _batch();
      expect(b, contains(r'set "LOG=C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update.log"'));
      // ...in a directory the batch creates if it has to, so a re-run by hand
      // months later does not die on its first redirect.
      expect(b, contains(r'set "LOGDIR=C:\Users\Till\AppData\Local\Temp\restaurantdash_update"'));
      expect(b, contains(r'if not exist "%LOGDIR%" mkdir "%LOGDIR%"'));
      // Not a token gesture: the run is narrated into that file.
      expect(b, contains(r'>>"%LOG%" echo Restaurant Dash update'));
      expect(b, contains(r'>>"%LOG%" echo install dir    : %DST%'));
      expect(b, contains(r'>>"%LOG%" echo robocopy exit code: %RC%'));
      // ...and robocopy's own output goes into it, which the suppressed
      // /NFL /NDL /NJH /NJS of the old batch made impossible.
      expect(b, contains(r'robocopy "%SRC%" "%DST%" /E /IS /IT /R:3 /W:1 /NP >>"%LOG%" 2>&1'));
      expect(b, isNot(contains('/NFL')));
    });

    test('robocopy exit code is captured and judged', () {
      final b = _batch();
      expect(b, contains('set RC=%ERRORLEVEL%'));
      // >= 8 is a real robocopy failure.
      expect(b, contains('if %RC% GEQ 8 goto elevate'));
      // 0 means it copied NOTHING. Against a different build copied with /IS
      // that can only mean the copy never happened — the exact silent no-op the
      // customer was living in.
      expect(b, contains('if %RC% EQU 0 goto elevate'));
    });

    test('a failed copy is retried once with administrator rights', () {
      final b = _batch();
      expect(b, contains(':elevate'));
      expect(b, contains('Start-Process'));
      expect(b, contains('-Verb RunAs')); // this is what raises the UAC prompt
      expect(b, contains('set RC2=%ERRORLEVEL%'));
      expect(b, contains(r'>>"%LOG%" echo elevated robocopy exit code: %RC2%'));
      // A dismissed UAC prompt is NOT the same as a copy that failed: the
      // PowerShell catch maps it to 99, which becomes outcome "denied".
      expect(b, contains('catch { exit 99 }'));
      expect(b, contains('if %RC2% EQU 99 goto denied'));
      expect(b, contains('if %RC2% GEQ 8 goto copyfailed'));
      expect(b, contains('if %RC2% EQU 0 goto copyfailed'));
    });

    test('the log survives a failure — only a clean run cleans up', () {
      final b = _batch();
      // Nothing anywhere deletes the log or the directory holding it.
      expect(b, isNot(contains('del "%LOG%"')));
      expect(b, isNot(contains('rmdir /s /q "%RESULT%"')));
      // The self-delete is gated behind OK=1 and only ever removes the payload
      // and the batch itself.
      final gate = b.indexOf('if not "%OK%"=="1" exit /b 1');
      final selfDelete = b.indexOf(r'del "%~f0"');
      expect(gate, greaterThan(-1));
      expect(selfDelete, greaterThan(gate),
          reason: 'the batch must bail out before deleting itself when the copy failed');
      expect(b.indexOf(r'rmdir /s /q "%SRC%"'), greaterThan(gate));
    });

    test('it writes a machine-readable receipt for the next launch', () {
      final b = _batch();
      expect(b, contains(r'>"%RESULT%" echo {'));
      expect(b, contains(r'echo   "version": "%VER%",'));
      expect(b, contains(r'echo   "outcome": "%~1",'));
      expect(b, contains(r'echo   "robocopy_exit": %~2,'));
      expect(b, contains(r'echo   "timestamp": "%DATE% %TIME%"'));
      // Paths land in the JSON with their backslashes escaped, or the app's
      // jsonDecode would choke on the one thing it most needs to read.
      expect(b, contains(r'"install_dir": "C:\\Program Files\\Restaurant Dash"'));
      expect(b, contains(r'"log": "C:\\Users\\Till\\AppData\\Local\\Temp\\restaurantdash_update\\update.log"'));
      // Every terminal path records an outcome before it lets go.
      for (final outcome in ['applied', 'failed', 'denied']) {
        expect(b, contains('call :writeresult $outcome'));
      }
    });

    test('it still waits for the old process, longer, and by PID', () {
      final b = _batch();
      // By PID, space-delimited, so waiting on 5249 cannot match 52496.
      expect(b, contains('tasklist /FI "PID eq 5249"'));
      expect(b, contains(r'findstr /C:" 5249 "'));
      // ~5 minutes, up from the old 2: antivirus can hold a dying process.
      expect(b, contains('if %tries% GEQ 300 goto stillrunning'));
      // And a process that never dies is reported, not silently copied over.
      expect(b, contains('call :writeresult failed -1'));
    });

    test('the installed exe must be writable before anything is overwritten', () {
      final b = _batch();
      // `>>file (call )` opens for append and writes nothing: it fails when the
      // file is locked by another process OR when we lack permission.
      expect(b, contains(r'2>nul (>>"%DST%\%EXE%" (call )) && goto probedone'));
      expect(b.indexOf(':exewait'), lessThan(b.indexOf(':docopy')));
    });

    test('the relaunch happens after the copy, not before it', () {
      final b = _batch();
      expect(b.indexOf('robocopy "%SRC%"'), lessThan(b.indexOf(r'start "" "%DST%\%EXE%"')));
      // and after the receipt is written, so the relaunched app can read it
      expect(b.indexOf(':finish'), greaterThan(b.indexOf('call :writeresult applied %RC%')));
    });

    test('never a delete-mirror', () {
      // /MIR against a wrong source deletes the install. It was never here and
      // must never arrive.
      expect(_batch(), isNot(contains('/MIR')));
    });

    test('an explicit elevated retry skips straight to the UAC prompt', () {
      final b = _batch(elevateFirst: true);
      expect(b, contains('goto elevate'));
      expect(b, contains('retry requested WITH administrator rights'));
      // The plain attempt is not repeated first — the user already told us it
      // failed without rights.
      expect(b.indexOf('retry requested WITH administrator rights'),
          lessThan(b.indexOf(':docopy')));
    });

    test('it is a CRLF batch file', () {
      final b = _batch();
      expect(b.endsWith('\r\n'), isTrue);
      expect(b.split('\n').where((l) => l.isNotEmpty).every((l) => l.endsWith('\r')), isTrue);
    });
  });

  group('reading the receipt', () {
    test('absent', () => expect(UpdateAttempt.parse(null), isNull));
    test('empty', () => expect(UpdateAttempt.parse('   '), isNull));
    test('malformed', () {
      expect(UpdateAttempt.parse('{ this is not json'), isNull);
      expect(UpdateAttempt.parse('[]'), isNull);
      // A receipt we cannot interpret must not suppress the update prompt.
      expect(UpdateAttempt.parse('{"outcome":"banana","version":"2.0.2"}'), isNull);
      expect(UpdateAttempt.parse('{"outcome":"applied"}'), isNull);
    });

    test('applied', () {
      final a = UpdateAttempt.parse('''
{
  "version": "2.0.2",
  "outcome": "applied",
  "robocopy_exit": 1,
  "install_dir": "C:\\\\Program Files\\\\Restaurant Dash",
  "log": "C:\\\\Temp\\\\restaurantdash_update\\\\update.log",
  "message": "Update applied.",
  "timestamp": "20/09/2026 14:31:19.42"
}
''')!;
      expect(a.version, '2.0.2');
      expect(a.outcome, UpdateOutcome.applied);
      expect(a.robocopyExit, 1);
      expect(a.installDir, r'C:\Program Files\Restaurant Dash');
      expect(a.logPath, r'C:\Temp\restaurantdash_update\update.log');
      expect(a.timestamp, '20/09/2026 14:31:19.42');
    });

    test('failed, with the exit code batch echoed as a bare token', () {
      final a = UpdateAttempt.parse('{"version":"2.0.2","outcome":"failed","robocopy_exit":16}')!;
      expect(a.outcome, UpdateOutcome.failed);
      expect(a.robocopyExit, 16);
    });

    test('denied', () {
      final a = UpdateAttempt.parse('{"version":"2.0.2","outcome":"DENIED","robocopy_exit":"-1"}')!;
      expect(a.outcome, UpdateOutcome.denied);
      expect(a.robocopyExit, -1); // tolerated as a string, because batch is batch
    });

    test('a receipt with no exit code is still a receipt', () {
      final a = UpdateAttempt.parse('{"version":"2.0.2","outcome":"failed"}')!;
      expect(a.robocopyExit, isNull);
      expect(a.installDir, isEmpty);
    });
  });

  group('the verdict on next launch', () {
    UpdateAttempt attempt(UpdateOutcome o, {String version = '2.0.2'}) => UpdateAttempt(
          version: version,
          outcome: o,
          installDir: r'C:\Program Files\Restaurant Dash',
          logPath: r'C:\Temp\update.log',
          robocopyExit: 0,
        );

    test('no receipt, nothing to say', () {
      final r = reviewUpdateAttempt(attempt: null, runningVersion: '1.9.9');
      expect(r.hasFailure, isFalse);
      expect(r.resolved, isFalse);
      expect(r.attempt, isNull);
    });

    test('the attempted version is now running: it worked, clear the receipt', () {
      final r = reviewUpdateAttempt(attempt: attempt(UpdateOutcome.applied), runningVersion: '2.0.2');
      expect(r.resolved, isTrue);
      expect(r.hasFailure, isFalse);
    });

    test('a version installed BY HAND afterwards also settles the receipt', () {
      // The user gave up on the in-app updater and installed 2.0.3 themselves.
      // Greeting them with a complaint about 2.0.2 would be nonsense.
      final r = reviewUpdateAttempt(attempt: attempt(UpdateOutcome.failed), runningVersion: '2.0.3');
      expect(r.resolved, isTrue);
      expect(r.hasFailure, isFalse);
    });

    test('a build suffix does not make it a different version', () {
      final r = reviewUpdateAttempt(
          attempt: attempt(UpdateOutcome.applied, version: '2.0.2'), runningVersion: '2.0.2+64');
      expect(r.resolved, isTrue);
    });

    test('THE SILENT NO-OP: "applied", but we came back on the old version', () {
      final r = reviewUpdateAttempt(attempt: attempt(UpdateOutcome.applied), runningVersion: '1.9.9');
      expect(r.resolved, isFalse);
      expect(r.failure, UpdateFailureKind.silentNoOp);
      // And it says so in words the user can act on, rather than repeating the
      // offer that just failed.
      expect(updateFailureDetail(r.failure!, r.attempt!),
          contains('the files could not be replaced'));
      expect(updateFailureDetail(r.failure!, r.attempt!), contains('2.0.2'));
    });

    test('denied is its own failure, and names the permission problem', () {
      final r = reviewUpdateAttempt(attempt: attempt(UpdateOutcome.denied), runningVersion: '1.9.9');
      expect(r.failure, UpdateFailureKind.denied);
      expect(updateFailureDetail(r.failure!, r.attempt!), contains('administrator'));
      expect(updateFailureHeadline(r.failure!), contains("wouldn't let"));
    });

    test('a reported copy failure', () {
      final r = reviewUpdateAttempt(attempt: attempt(UpdateOutcome.failed), runningVersion: '1.9.9');
      expect(r.failure, UpdateFailureKind.copyFailed);
      expect(updateFailureDetail(r.failure!, r.attempt!), contains('could not be copied'));
    });

    test('compareVersions orders the shapes the manifest and pubspec produce', () {
      expect(compareVersions('2.0.2', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.9.9', '2.0.2'), lessThan(0));
      expect(compareVersions('2.0.2+64', '2.0.2'), 0);
      expect(sameVersion('2.0.2', '2.0.2'), isTrue);
      expect(sameVersion('2.0.2+64', '2.0.2'), isTrue);
      expect(sameVersion('2.0.2', '2.0.3'), isFalse);
      expect(sameVersion('1.9.9', '2.0.2'), isFalse);
      expect(sameVersion('2.0', '2.0.0'), isTrue);
    });
  });

  group('where the log and the receipt live', () {
    test('outside the work dir, because the work dir is wiped every attempt', () {
      final p = UpdatePaths.under(r'C:\Users\Till\AppData\Local\Temp');
      expect(p.base, 'C:/Users/Till/AppData/Local/Temp/restaurantdash_update');
      expect(p.logPath, '${p.base}/update.log');
      expect(p.resultPath, '${p.base}/update_result.json');
      expect(p.workDir, '${p.base}/work');
      expect(p.extractDir.startsWith(p.workDir), isTrue);
      expect(p.batPath.startsWith(p.workDir), isTrue);
      // The evidence must NOT sit inside the directory the next attempt deletes.
      expect(p.logPath.startsWith('${p.workDir}/'), isFalse);
      expect(p.resultPath.startsWith('${p.workDir}/'), isFalse);
    });

    test('a trailing separator on the temp dir does not double up', () {
      expect(UpdatePaths.under('/tmp/').base, '/tmp/restaurantdash_update');
    });
  });

  group('the pre-flight, before 18MB is spent', () {
    test('a writable install dir lets the update proceed', () async {
      final probe = _FakeProbe(true);
      expect(await AppUpdater.canUpdateInPlace(r'C:\Apps\Restaurant Dash', probe: probe), isTrue);
      expect(probe.asked, [r'C:\Apps\Restaurant Dash']);
    });

    test('an unwritable install dir stops it — nothing is downloaded', () async {
      final probe = _FakeProbe(false);
      expect(await AppUpdater.canUpdateInPlace(r'C:\Program Files\Restaurant Dash', probe: probe), isFalse);
      expect(probe.asked, [r'C:\Program Files\Restaurant Dash']);
    });

    test('an unknown install dir is treated as unwritable, never guessed at', () async {
      final probe = _FakeProbe(true);
      expect(await AppUpdater.canUpdateInPlace('   ', probe: probe), isFalse);
      expect(probe.asked, isEmpty, reason: 'it should not even probe a blank path');
    });

    test('the real probe writes and cleans up in a directory it can write', () async {
      final dir = Directory.systemTemp.createTempSync('rd_preflight');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await const RealInstallDirProbe().isWritable(dir.path), isTrue);
      // It must leave nothing behind next to the exe.
      expect(dir.listSync(), isEmpty);
    });

    test('the real probe says no for a directory that is not there', () async {
      final missing = '${Directory.systemTemp.path}/rd_absent_${DateTime.now().microsecondsSinceEpoch}/nested';
      expect(await const RealInstallDirProbe().isWritable(missing), isFalse);
    });
  });

  group('what the user sees after a failed update', () {
    final attempt = UpdateAttempt(
      version: '2.0.2',
      outcome: UpdateOutcome.applied,
      robocopyExit: 0,
      installDir: r'C:\Program Files\Restaurant Dash',
      logPath: r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update.log',
    );

    testWidgets('the failure card explains, names the folder, and offers a way out',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UpdateFailureDialog(
            kind: UpdateFailureKind.silentNoOp,
            attempt: attempt,
            downloadUrl: 'https://example.test/RestaurantDash-Windows.zip',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text("The update didn't take effect"), findsOneWidget);
      expect(find.textContaining('the files could not be replaced'), findsOneWidget);
      // The folder, by name — the single most useful fact for the person on the
      // phone to support.
      expect(find.text(r'C:\Program Files\Restaurant Dash'), findsOneWidget);
      // The log, copyable.
      expect(find.text(r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update.log'),
          findsOneWidget);
      expect(find.byTooltip('Copy log path'), findsOneWidget);
      expect(find.byTooltip('Copy folder path'), findsOneWidget);
      // And the two routes forward.
      expect(find.text('Retry as administrator'), findsOneWidget);
      expect(find.text('Open download page'), findsOneWidget);
    });

    testWidgets('the log path really goes to the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add('${(call.arguments as Map)['text']}');
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UpdateFailureDialog(kind: UpdateFailureKind.denied, attempt: attempt),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy log path'));
      await tester.pumpAndSettle();
      expect(copied, [r'C:\Users\Till\AppData\Local\Temp\restaurantdash_update\update.log']);
    });

    testWidgets('with no download URL there is nothing to retry, and it says so',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UpdateFailureDialog(kind: UpdateFailureKind.copyFailed, attempt: attempt),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Retry as administrator'), findsNothing);
      expect(find.text('Please update from where you got the app.'), findsOneWidget);
    });

    testWidgets('THE LOOP IS BROKEN: a failed attempt suppresses the ordinary prompt',
        (tester) async {
      final review = reviewUpdateAttempt(attempt: attempt, runningVersion: '1.9.9');
      final info = UpdateInfo(
        latest: '2.0.2',
        current: '1.9.9',
        mandatory: false,
        notes: 'Bug fixes.',
        downloadUrl: 'https://example.test/RestaurantDash-Windows.zip',
      );

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => presentUpdatePrompt(ctx, review: review, info: info),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // What the customer saw on every single launch:
      expect(find.text('Update available'), findsNothing);
      expect(find.text('Update now'), findsNothing);
      expect(find.text('Version 2.0.2 is available (you have 1.9.9).'), findsNothing);
      // What they get instead:
      expect(find.text("The update didn't take effect"), findsOneWidget);
      expect(find.text('Retry as administrator'), findsOneWidget);
    });

    testWidgets('with nothing wrong, the ordinary prompt is exactly as it was',
        (tester) async {
      final info = UpdateInfo(
        latest: '2.0.2',
        current: '1.9.9',
        mandatory: false,
        notes: 'Bug fixes.',
        downloadUrl: 'https://example.test/RestaurantDash-Windows.zip',
      );
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => presentUpdatePrompt(
                    ctx, review: UpdateAttemptReview.none, info: info),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Version 2.0.2 is available (you have 1.9.9).'), findsOneWidget);
    });

    testWidgets('a resolved attempt does not shout about an update that worked',
        (tester) async {
      final review = reviewUpdateAttempt(attempt: attempt, runningVersion: '2.0.2');
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => presentUpdatePrompt(ctx, review: review, info: null),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
