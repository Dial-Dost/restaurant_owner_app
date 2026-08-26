import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../ui/theme/app_colors.dart';
import 'app_updater.dart';

/// Result of an update check against the backend's /app/version manifest.
class UpdateInfo {
  final String latest;
  final String current;
  final bool mandatory; // current is below the server's min_supported
  final String notes;
  final String? downloadUrl; // for this platform (null if none configured)
  UpdateInfo({required this.latest, required this.current, required this.mandatory, required this.notes, required this.downloadUrl});
}

// Compare dotted versions (ignores any +build suffix). >0 if a>b.
int _cmpVersion(String a, String b) {
  List<int> parse(String v) => v.split('+').first.split('.').map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

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

/// Check on launch and, if an update exists, prompt the user. Mandatory updates
/// (below min_supported) can't be dismissed.
Future<void> showUpdateDialogIfNeeded(BuildContext context) async {
  final info = await checkForUpdate();
  if (info == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: !info.mandatory,
    builder: (ctx) => _UpdateDialog(info: info),
  );
}

enum _UpdatePhase { idle, downloading, launched, fellBack }

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

  Future<void> _startInAppInstall() async {
    setState(() => _phase = _UpdatePhase.downloading);
    _progress.value = 0;
    var fellBack = false;
    await AppUpdater().downloadAndInstall(
      info.downloadUrl!,
      onProgress: (p) => _progress.value = p.clamp(0.0, 1.0),
      fallback: () async {
        fellBack = true;
        await _openInBrowser();
      },
    );
    // On Windows the updater exits the process, so we only get here on Android
    // (installer launched) or after the browser fallback ran.
    if (!mounted) return;
    if (fellBack) {
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
        title: Text(_mandatory ? 'Update required' : 'Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _content(canInApp),
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
