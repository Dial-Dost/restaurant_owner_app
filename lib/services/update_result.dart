import 'dart:convert';
import 'dart:io';

/// WHAT THE LAST UPDATE ATTEMPT ACTUALLY DID.
///
/// The Windows updater hands the copy off to a detached batch and then kills
/// itself, so the app is never in the room when the update succeeds or fails.
/// Until now nothing wrote that answer down: the batch ignored robocopy's exit
/// code, relaunched the OLD exe, and deleted its own logs. A user whose install
/// directory was not writable therefore saw the same "Update available" prompt
/// forever, with no error anywhere.
///
/// So the batch now leaves a small JSON receipt behind, and this file is how
/// the app reads it on the next launch. Everything here is pure (no plugins,
/// no `getTemporaryDirectory`) so it can be tested off-Windows.

/// What the helper batch reported.
///
/// * [applied] — robocopy copied files and said so.
/// * [failed]  — robocopy ran and either errored (exit >= 8) or copied nothing.
/// * [denied]  — the copy needed administrator rights and did not get them
///               (the UAC prompt was dismissed, or elevation was unavailable).
enum UpdateOutcome { applied, failed, denied }

/// Why we are showing the user a failure instead of the ordinary prompt.
enum UpdateFailureKind {
  /// Windows refused the write; the install folder needs admin rights.
  denied,

  /// robocopy ran and failed, or copied zero files.
  copyFailed,

  /// The batch claimed success, yet the app came back on the OLD version.
  /// The files were not actually replaced (locked exe, antivirus, a shadowed
  /// install directory...).
  silentNoOp,
}

/// The receipt the helper batch leaves in `<temp>/restaurantdash_update/`.
class UpdateAttempt {
  const UpdateAttempt({
    required this.version,
    required this.outcome,
    required this.installDir,
    required this.logPath,
    this.robocopyExit,
    this.timestamp = '',
    this.message = '',
  });

  /// The version the update was trying to install.
  final String version;
  final UpdateOutcome outcome;

  /// robocopy's exit code (or 99 when elevation itself was refused). Null when
  /// the batch never got as far as running it.
  final int? robocopyExit;
  final String installDir;
  final String logPath;
  final String timestamp;
  final String message;

  /// Parse the receipt. Returns null for absent, empty, malformed, or
  /// uninterpretable content — in which case the caller simply behaves as it
  /// always did. A receipt we cannot read must never suppress the update
  /// prompt; it may only ever add information.
  static UpdateAttempt? parse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final outcome = switch ('${decoded['outcome'] ?? ''}'.trim().toLowerCase()) {
      'applied' => UpdateOutcome.applied,
      'failed' => UpdateOutcome.failed,
      'denied' => UpdateOutcome.denied,
      _ => null,
    };
    if (outcome == null) return null;
    final version = '${decoded['version'] ?? ''}'.trim();
    if (version.isEmpty) return null;
    final rcRaw = decoded['robocopy_exit'];
    final rc = rcRaw is int ? rcRaw : int.tryParse('${rcRaw ?? ''}'.trim());
    return UpdateAttempt(
      version: version,
      outcome: outcome,
      robocopyExit: rc,
      installDir: '${decoded['install_dir'] ?? ''}'.trim(),
      logPath: '${decoded['log'] ?? ''}'.trim(),
      timestamp: '${decoded['timestamp'] ?? ''}'.trim(),
      message: '${decoded['message'] ?? ''}'.trim(),
    );
  }
}

/// Compare dotted versions, ignoring any `+build` suffix and any stray
/// non-digits. `> 0` when `a` is newer than `b`. This is the one comparison the
/// update flow uses, in both directions; `update_checker` delegates to it.
int compareVersions(String a, String b) {
  List<int> parse(String v) => v
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// True when two version strings name the same release.
bool sameVersion(String a, String b) => compareVersions(a, b) == 0;

/// The verdict on the last attempt, given the version that is running NOW.
class UpdateAttemptReview {
  const UpdateAttemptReview._({this.attempt, this.failure, this.resolved = false});

  final UpdateAttempt? attempt;

  /// Non-null when the user must be told the update did not happen.
  final UpdateFailureKind? failure;

  /// True when the attempted version is the one now running: the update landed
  /// (perhaps after a manual install), so the receipt should be deleted.
  final bool resolved;

  /// Nothing to say — no receipt, or one we could not read.
  static const UpdateAttemptReview none = UpdateAttemptReview._();

  bool get hasFailure => failure != null;
}

/// Decide what the last attempt means.
///
/// The order matters. "Am I now on the version it was installing?" is asked
/// FIRST, because that is the only unambiguous evidence of success — and it is
/// what catches the silent no-op: a batch that reports `applied` while the app
/// relaunches on the old version did not replace anything, whatever robocopy's
/// exit code said.
UpdateAttemptReview reviewUpdateAttempt({
  required UpdateAttempt? attempt,
  required String runningVersion,
}) {
  if (attempt == null) return UpdateAttemptReview.none;
  // ">=", not "==": if the user gave up and installed 2.0.3 by hand, a receipt
  // about 2.0.2 is history, not a complaint to greet them with.
  if (compareVersions(runningVersion, attempt.version) >= 0) {
    return UpdateAttemptReview._(attempt: attempt, resolved: true);
  }
  final kind = switch (attempt.outcome) {
    UpdateOutcome.applied => UpdateFailureKind.silentNoOp,
    UpdateOutcome.denied => UpdateFailureKind.denied,
    UpdateOutcome.failed => UpdateFailureKind.copyFailed,
  };
  return UpdateAttemptReview._(attempt: attempt, failure: kind);
}

/// Plain-language headline for a failed attempt.
String updateFailureHeadline(UpdateFailureKind kind) => switch (kind) {
      UpdateFailureKind.denied => "Windows wouldn't let the app update itself",
      UpdateFailureKind.copyFailed => "The update couldn't be installed",
      UpdateFailureKind.silentNoOp => "The update didn't take effect",
    };

/// Plain-language explanation. No exit codes, no jargon — the number lives in
/// the log, and the log path is offered separately.
String updateFailureDetail(UpdateFailureKind kind, UpdateAttempt attempt) {
  final v = attempt.version;
  switch (kind) {
    case UpdateFailureKind.denied:
      return 'Version $v was downloaded, but Windows blocked it from replacing '
          'the installed files. The app is installed in a folder that needs '
          'administrator permission to change.';
    case UpdateFailureKind.copyFailed:
      return 'Version $v was downloaded, but the new files could not be copied '
          'over the installed app. This usually means the folder is protected, '
          'or a file was still in use by antivirus or another copy of the app.';
    case UpdateFailureKind.silentNoOp:
      return 'The updater reported success, but the app restarted still on the '
          'old version, so the files could not be replaced. Version $v is not '
          'installed.';
  }
}

/// Where the updater keeps its work, its log, and its receipt.
///
/// `base` survives between attempts on purpose: the log and the receipt are the
/// only evidence a failed update leaves behind, so only [workDir] is wiped.
class UpdatePaths {
  const UpdatePaths._(this.base);

  /// Build the layout under a temp directory. Pure — takes the path as a
  /// string so tests never touch `path_provider`.
  factory UpdatePaths.under(String tempDirPath) {
    final t = tempDirPath.replaceAll('\\', '/');
    final trimmed = t.endsWith('/') ? t.substring(0, t.length - 1) : t;
    return UpdatePaths._('$trimmed/restaurantdash_update');
  }

  final String base;

  /// Never deleted on failure — this is the diagnosis.
  String get logPath => '$base/update.log';

  /// The machine-readable receipt the app reads on next launch.
  String get resultPath => '$base/update_result.json';

  /// Download + extraction scratch. Wiped at the start of every attempt.
  String get workDir => '$base/work';

  String get extractDir => '$workDir/extracted';

  String get batPath => '$workDir/apply_update.bat';
}

/// Reads and clears the receipt. The only part of this file that touches disk.
class UpdateResultStore {
  const UpdateResultStore(this.paths);

  final UpdatePaths paths;

  Future<UpdateAttempt?> read() async {
    try {
      final f = File(paths.resultPath);
      if (!f.existsSync()) return null;
      return UpdateAttempt.parse(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final f = File(paths.resultPath);
      if (f.existsSync()) await f.delete();
    } catch (_) {/* best effort; a stale receipt is re-evaluated next launch */}
  }
}
