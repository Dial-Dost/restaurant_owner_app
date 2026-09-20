import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../ui/theme/app_colors.dart';
import 'app_updater.dart';
import 'update_result.dart';

/// Result of an update check against the backend's /app/version manifest.
class UpdateInfo {
  final String latest;
  final String current;
  final bool mandatory; // current is below the server's min_supported
  final String notes;
  final String? downloadUrl; // for this platform (null if none configured)
  UpdateInfo({required this.latest, required this.current, required this.mandatory, required this.notes, required this.downloadUrl});
}

// Compare dotted versions (ignores any +build suffix). >0 if a>b. One
// implementation, in update_result.dart, because the "did the update actually
// land?" verdict and the "is there an update?" check must never disagree.
int _cmpVersion(String a, String b) => compareVersions(a, b);

String? _platformKey() {
  try {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
  } catch (_) {/* web/unknown */}
  return null;
}

/// Ask the backend whether a newer build exists. Returns null when up to date
/// or unreachable (never blocks the app on a network hiccup).
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;
    final res = await http
        .get(Uri.parse('${AppConfig.backendUrl}/app/version'))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = '${data['latest'] ?? current}';
    final minSupported = '${data['min_supported'] ?? '0.0.0'}';
    if (_cmpVersion(latest, current) <= 0) return null; // already current
    final downloads = (data['downloads'] as Map?) ?? const {};
    final key = _platformKey();
    final url = key != null ? '${downloads[key] ?? ''}' : '';
    return UpdateInfo(
      latest: latest,
      current: current,
      mandatory: _cmpVersion(current, minSupported) < 0,
      notes: '${data['notes'] ?? ''}',
      downloadUrl: url.trim().isEmpty ? null : url.trim(),
    );
  } catch (_) {
    return null;
  }
}

/// True when we can download + install in-app (vs. just opening the browser):
/// a real http(s) URL on a platform the updater can drive (Android/Windows).
bool _inAppInstallSupported(String? url) {
  if (url == null || !url.startsWith('http')) return false;
  try {
    return Platform.isAndroid || Platform.isWindows;
  } catch (_) {
    return false;
  }
}

/// Read the receipt the Windows helper batch left behind, and judge it against
/// the version that is running right now.
///
/// If the attempted version IS the running version the update landed, so the
/// receipt is deleted and we go back to the ordinary flow. Anything else — a
/// reported failure, a refused UAC prompt, or a "success" that left us on the
/// old version — is a failure the user has to be told about.
Future<UpdateAttemptReview> readLastUpdateAttempt() async {
  try {
    if (!Platform.isWindows) return UpdateAttemptReview.none;
    final tmp = await getTemporaryDirectory();
    final store = UpdateResultStore(UpdatePaths.under(tmp.path));
    final attempt = await store.read();
    if (attempt == null) return UpdateAttemptReview.none;
    final pkg = await PackageInfo.fromPlatform();
    final review = reviewUpdateAttempt(attempt: attempt, runningVersion: pkg.version);
    if (review.resolved) await store.clear();
    return review;
  } catch (_) {
    return UpdateAttemptReview.none;
  }
}

/// Check on launch and, if there is something to say, say it. Mandatory updates
/// (below min_supported) can't be dismissed.
Future<void> showUpdateDialogIfNeeded(BuildContext context) async {
  final review = await readLastUpdateAttempt();
  final info = await checkForUpdate();
  if (!context.mounted) return;
  await presentUpdatePrompt(context, review: review, info: info);
}

/// The decision, separated from the IO so it can be driven in a widget test.
///
/// THE RULE THIS ENFORCES: when the last attempt failed, the ordinary
/// "Update available" dialog is NOT shown. Showing it again is exactly the loop
/// the customer was stuck in — click Update, watch the app restart unchanged,
/// be asked again, with nothing anywhere saying why.
@visibleForTesting
Future<void> presentUpdatePrompt(
  BuildContext context, {
  required UpdateAttemptReview review,
  required UpdateInfo? info,
}) async {
  final attempt = review.attempt;
  if (review.hasFailure && attempt != null) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => UpdateFailureDialog(
        kind: review.failure!,
        attempt: attempt,
        downloadUrl: info?.downloadUrl,
      ),
    );
    return;
  }
  if (info == null) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: !info.mandatory,
    builder: (ctx) => _UpdateDialog(info: info),
  );
}

/// Copy a path to the clipboard and say so. Used for the log path, which is the
/// one thing support needs from a user whose update will not apply.
Future<void> _copyPath(BuildContext context, String path, String label) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text('$label copied to the clipboard')),
  );
}

/// A path the user may need to read aloud or paste: selectable, monospaced,
/// with a copy button beside it.
class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.path, required this.copyLabel});

  final String label;
  final String path;
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  path,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: 'Copy $copyLabel',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () => _copyPath(context, path, copyLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// WHAT THE USER SEES WHEN THE UPDATE DID NOT TAKE.
///
/// Not "Update available" again. It names the failure in plain language, names
/// the folder the app is installed in, offers a retry that asks Windows for
/// administrator rights, offers the download page, and hands over the log path
/// so support can be given something concrete.
class UpdateFailureDialog extends StatefulWidget {
  const UpdateFailureDialog({
    super.key,
    required this.kind,
    required this.attempt,
    this.downloadUrl,
  });

  final UpdateFailureKind kind;
  final UpdateAttempt attempt;
  final String? downloadUrl;

  @override
  State<UpdateFailureDialog> createState() => _UpdateFailureDialogState();
}

class _UpdateFailureDialogState extends State<UpdateFailureDialog> {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  bool _retrying = false;
  String? _retryError;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _openDownloadPage() async {
    final url = widget.downloadUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _retryElevated() async {
    final url = widget.downloadUrl;
    if (url == null) return;
    setState(() {
      _retrying = true;
      _retryError = null;
    });
    _progress.value = 0;
    var fellBack = false;
    await AppUpdater().downloadAndInstall(
      url,
      version: widget.attempt.version,
      elevated: true,
      onProgress: (p) => _progress.value = p.clamp(0.0, 1.0),
      fallback: () async {
        fellBack = true;
        await _openDownloadPage();
      },
    );
    // On Windows the updater exits this process, so reaching here at all means
    // it gave up and used the browser instead.
    if (!mounted) return;
    setState(() {
      _retrying = false;
      if (fellBack) {
        _retryError = "We still couldn't install it here, so the download page "
            'is open in your browser. Install it from there.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attempt;
    final installDir = a.installDir.trim();
    final logPath = a.logPath.trim();
    return AlertDialog(
      title: Text(updateFailureHeadline(widget.kind)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(updateFailureDetail(widget.kind, a)),
            if (installDir.isNotEmpty)
              _PathRow(
                label: 'The app is installed in',
                path: installDir,
                copyLabel: 'folder path',
              ),
            if (logPath.isNotEmpty)
              _PathRow(
                label: 'Details were written to',
                path: logPath,
                copyLabel: 'log path',
              ),
            if (widget.downloadUrl == null) ...[
              const SizedBox(height: 10),
              Text('Please update from where you got the app.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
            if (_retryError != null) ...[
              const SizedBox(height: 10),
              Text(_retryError!, style: const TextStyle(color: Colors.redAccent)),
            ],
            if (_retrying) ...[
              const SizedBox(height: 12),
              const Text('Downloading update…'),
              const SizedBox(height: 8),
              ValueListenableBuilder<double>(
                valueListenable: _progress,
                builder: (_, v, _) => LinearProgressIndicator(value: v),
              ),
            ],
          ],
        ),
      ),
      actions: _retrying
          ? const []
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Later'),
              ),
              if (widget.downloadUrl != null)
                TextButton(
                  onPressed: _openDownloadPage,
                  child: const Text('Open download page'),
                ),
              if (widget.downloadUrl != null)
                FilledButton(
                  onPressed: _retryElevated,
                  child: const Text('Retry as administrator'),
                ),
            ],
    );
  }
}

enum _UpdatePhase { idle, downloading, launched, fellBack, notWritable }

/// The update prompt. Idle shows notes + "Update now"; on an in-app-capable
/// platform "Update now" streams the download (determinate progress bar) and
/// installs, otherwise it opens the browser as before. Any failure inside the
/// updater falls back to the browser and surfaces a retry button here.
class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  _UpdatePhase _phase = _UpdatePhase.idle;
  String _installDir = '';

  UpdateInfo get info => widget.info;
  bool get _mandatory => info.mandatory;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _openInBrowser() async {
    final url = info.downloadUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _startInAppInstall({bool elevated = false}) async {
    setState(() => _phase = _UpdatePhase.downloading);
    _progress.value = 0;
    var fellBack = false;
    var notWritable = '';
    await AppUpdater().downloadAndInstall(
      info.downloadUrl!,
      version: info.latest,
      elevated: elevated,
      onProgress: (p) => _progress.value = p.clamp(0.0, 1.0),
      fallback: () async {
        fellBack = true;
        await _openInBrowser();
      },
      // The pre-flight refused BEFORE spending the user's bandwidth. Say so
      // rather than downloading 18MB into a copy that cannot happen.
      onInstallDirNotWritable: (dir) async {
        notWritable = dir;
      },
    );
    // On Windows the updater exits the process, so we only get here on Android
    // (installer launched) or after the browser fallback ran.
    if (!mounted) return;
    if (notWritable.isNotEmpty) {
      setState(() {
        _installDir = notWritable;
        _phase = _UpdatePhase.notWritable;
      });
    } else if (fellBack) {
      setState(() => _phase = _UpdatePhase.fellBack);
    } else if (_mandatory) {
      setState(() => _phase = _UpdatePhase.launched);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canInApp = _inAppInstallSupported(info.downloadUrl);
    // Can't back out while a download is in flight, nor for mandatory updates.
    final canPop = !_mandatory && _phase != _UpdatePhase.downloading;
    return PopScope(
      canPop: canPop,
      child: AlertDialog(
        title: Text(_phase == _UpdatePhase.notWritable
            ? "The app can't update itself where it's installed"
            : _mandatory
                ? 'Update required'
                : 'Update available'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _content(canInApp),
          ),
        ),
        actions: _actions(canInApp),
      ),
    );
  }

  List<Widget> _content(bool canInApp) {
    switch (_phase) {
      case _UpdatePhase.downloading:
        return [
          Text('Version ${info.latest} is available (you have ${info.current}).'),
          const SizedBox(height: 12),
          const Text('Downloading update…'),
          const SizedBox(height: 8),
          ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: v),
                const SizedBox(height: 6),
                Text('${(v * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ];
      case _UpdatePhase.launched:
        return const [
          Text('The installer has opened. Complete the installation to finish updating.'),
        ];
      case _UpdatePhase.fellBack:
        return const [
          Text("We couldn't install the update automatically, so we opened your "
              'browser to download it. Please install it manually.'),
        ];
      case _UpdatePhase.notWritable:
        return [
          Text('Version ${info.latest} was not downloaded, because Windows '
              "won't let the app replace its own files in the folder it is "
              'installed in. Nothing has been changed.'),
          _PathRow(
            label: 'The app is installed in',
            path: _installDir,
            copyLabel: 'folder path',
          ),
          const SizedBox(height: 6),
          Text('Retry as administrator to let Windows ask for permission, or '
              'download the new version and install it yourself.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ];
      case _UpdatePhase.idle:
        return [
          Text('Version ${info.latest} is available (you have ${info.current}).'),
          if (info.notes.isNotEmpty) ...[const SizedBox(height: 8), Text(info.notes)],
          if (info.downloadUrl == null) ...[
            const SizedBox(height: 8),
            Text('Please update from where you got the app.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ];
    }
  }

  List<Widget> _actions(bool canInApp) {
    switch (_phase) {
      case _UpdatePhase.downloading:
        return const []; // locked until the download resolves
      case _UpdatePhase.launched:
        return [
          if (!_mandatory) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(onPressed: _startInAppInstall, child: const Text('Reopen installer')),
        ];
      case _UpdatePhase.fellBack:
        return [
          if (!_mandatory) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(onPressed: _openInBrowser, child: const Text('Open in browser')),
        ];
      case _UpdatePhase.notWritable:
        return [
          if (!_mandatory) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          TextButton(onPressed: _openInBrowser, child: const Text('Open download page')),
          FilledButton(
            onPressed: () => _startInAppInstall(elevated: true),
            child: const Text('Retry as administrator'),
          ),
        ];
      case _UpdatePhase.idle:
        return [
          if (!_mandatory) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(
            onPressed: info.downloadUrl == null
                ? null
                : () async {
                    if (canInApp) {
                      await _startInAppInstall();
                    } else {
                      // Unsupported platform / non-http URL: original behaviour.
                      await _openInBrowser();
                      if (!_mandatory && mounted) Navigator.pop(context);
                    }
                  },
            child: const Text('Update now'),
          ),
        ];
    }
  }
}
