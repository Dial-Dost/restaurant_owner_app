import 'package:shared_preferences/shared_preferences.dart';

/// App configuration.
///
/// The backend URL is baked in at build time so a restaurant owner never has to
/// configure anything — they are simply handed the built app. Override per
/// environment with:
///   flutter run    -d windows --dart-define=BACKEND_URL=https://api.example.com
///   flutter build windows     --dart-define=BACKEND_URL=https://api.example.com
///
/// A RUNTIME override (set from the login screen's server dialog, persisted on
/// the device) wins over the baked-in value — so a test build can be repointed
/// at a new tunnel/server URL without rebuilding.
class AppConfig {
  static const String _builtBackendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://localhost:3001',
  );

  /// Where the customer ordering web page is hosted (the dashboard). A table's
  /// QR points at {orderBaseUrl}/order/{slug}?table={name}.
  static const String orderBaseUrl = String.fromEnvironment(
    'ORDER_BASE_URL',
    defaultValue: 'http://localhost:9002',
  );

  static const String _overrideKey = 'backend_url_override';
  static String? _backendOverride;

  static String get backendUrl => _backendOverride ?? _builtBackendUrl;
  static String get builtBackendUrl => _builtBackendUrl;
  static bool get hasBackendOverride => _backendOverride != null;

  /// Load the persisted override before the first network call (main()).
  static Future<void> loadBackendOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_overrideKey)?.trim();
      _backendOverride = (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      _backendOverride = null;
    }
  }

  /// Set (or clear, with null/empty) the runtime backend override.
  static Future<void> setBackendOverride(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final t = (url ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    if (t.isEmpty) {
      _backendOverride = null;
      await prefs.remove(_overrideKey);
    } else {
      _backendOverride = t;
      await prefs.setString(_overrideKey, t);
    }
  }
}
