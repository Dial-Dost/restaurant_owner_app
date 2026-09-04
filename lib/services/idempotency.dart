import 'dart:async';

/// The client-generated key that lets the backend apply a retried write exactly
/// once. Carried as the `Idempotency-Key` request header.
///
/// Zone-scoped, for the same reason [GetCachePolicy] is: it must follow exactly
/// the awaits of the one request it belongs to, and a mutable field on the
/// client would leak one write's key into a poll or a printer call running
/// concurrently. It also means [ApiClient.request] keeps its exact signature —
/// nothing that overrides or calls it has to change, which is what keeps the
/// online path identical.
abstract final class IdempotencyScope {
  static const _key = #rdIdempotencyKey;

  /// The key in force for the current request, or null outside a [run].
  static String? get key {
    final v = Zone.current[_key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Runs [body] with [key] attached to every request it makes.
  static Future<T> run<T>(String key, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: key});
}
