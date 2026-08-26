import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Thrown inside a cache-only replay when a request cannot be answered from
/// the persisted store (a GET with no entry, or anything that is not a
/// cacheable GET at all). It never reaches a screen: AsyncView catches it and
/// falls back to the ordinary network load.
class CacheMiss implements Exception {
  const CacheMiss();
  @override
  String toString() => 'CacheMiss';
}

/// What a cache-only replay actually touched. AsyncView reads this AFTER the
/// replay because the load closures it replays are allowed to swallow errors
/// internally (the Overview wraps every GET in catchError, Employees returns
/// an __error map) — so a thrown [CacheMiss] is not a reliable signal on its
/// own. The counters are.
class CacheReplayStamp {
  int hits = 0;
  int misses = 0;

  /// The save time of the OLDEST entry that fed the replayed payload — the
  /// honest number for an "updated Xm ago" label over a composed screen.
  DateTime? oldestSavedAt;

  void recordHit(DateTime savedAt) {
    hits++;
    final oldest = oldestSavedAt;
    if (oldest == null || savedAt.isBefore(oldest)) oldestSavedAt = savedAt;
  }

  void recordMiss() => misses++;
}

/// The switch AsyncView flips while it replays a load closure against the
/// persisted cache. Zone-scoped rather than a flag on RestClient because the
/// replayed closure is arbitrary async code composing several awaited GETs —
/// a mutable field would leak the policy into unrelated requests running
/// concurrently (polls, the printer service), while a zone value follows
/// exactly the awaits of the one closure it wraps.
abstract final class GetCachePolicy {
  static const _policyKey = #rdGetCacheOnly;
  static const _stampKey = #rdGetCacheStamp;

  static bool get isCacheOnly => Zone.current[_policyKey] == true;
  static CacheReplayStamp? get stamp =>
      Zone.current[_stampKey] as CacheReplayStamp?;

  /// Runs [body] with the cache-only policy active, recording what it touched
  /// into [stamp].
  static Future<T> runCacheOnly<T>(
          Future<T> Function() body, CacheReplayStamp stamp) =>
      runZoned(body, zoneValues: {_policyKey: true, _stampKey: stamp});
}

/// One stored GET response plus the moment it was confirmed by the network.
class CachedResponse {
  final DateTime savedAt;
  final dynamic data;
  CachedResponse(this.savedAt, this.data);
}

/// Persisted GET cache behind [RestClient], keyed restaurant | outlet | path.
///
/// SharedPreferences is the store because it is already in the app (the auth
/// token lives there) and survives a restart, which is the whole point: the
/// first module open after launch should paint from it. Every read is treated
/// as possibly corrupt — a bad entry decodes to a miss (and is removed), never
/// a crash — and the schema version rides in every key, so a format change
/// simply stops matching old entries instead of trying to parse them.
class GetCache {
  GetCache._();
  static final GetCache instance = GetCache._();

  /// Current schema. Bump the v-number on any format change; entries written
  /// under an old prefix are swept, never read.
  static const String keyPrefix = 'rd_get_cache_v1|';
  static const String _familyPrefix = 'rd_get_cache_';

  /// Caps. SharedPreferences persists ALL values as one file, so an oversized
  /// store makes every unrelated write slow — the caps keep the whole cache a
  /// modest fraction of that file. An entry too big to be worth that churn
  /// (a giant analytics payload) is simply not cached.
  static const int maxEntries = 96;
  static const int maxTotalChars = 700000;
  static const int maxEntryChars = 150000;

  /// A payload identical to the stored one within this window skips the
  /// rewrite: the KDS confirms an unchanged board every 10s, and rewriting
  /// the whole prefs file each tick buys nothing but disk wear.
  static const Duration _refreshWriteThrottle = Duration(seconds: 60);

  // Per-operation getInstance() on purpose: it is a cached singleton in
  // production, and tests swap the backing store via setMockInitialValues —
  // holding an instance here would pin a store a test already threw away.
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String _key(String res, String outlet, String path) =>
      '$keyPrefix$res|$outlet|$path';

  Future<CachedResponse?> read(String res, String outlet, String path) async {
    try {
      final p = await _prefs;
      final key = _key(res, outlet, path);
      final raw = p.getString(key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['t'] is! int || !decoded.containsKey('d')) {
        // Malformed but parseable: drop it so it only ever misses once.
        unawaited(p.remove(key));
        return null;
      }
      return CachedResponse(
        DateTime.fromMillisecondsSinceEpoch(decoded['t'] as int),
        decoded['d'],
      );
    } catch (_) {
      // Corrupt store, missing plugin, anything — a cache can only miss.
      return null;
    }
  }

  Future<void> write(String res, String outlet, String path, dynamic data) async {
    if (data == null) return;
    try {
      final dataJson = jsonEncode(data);
      if (dataJson.length > maxEntryChars) return;
      final p = await _prefs;
      final key = _key(res, outlet, path);
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = p.getString(key);
      if (old != null) {
        final oldT = _savedAtOf(old);
        if (oldT != null &&
            now - oldT < _refreshWriteThrottle.inMilliseconds &&
            _payloadOf(old) == dataJson) {
          return;
        }
      }
      await p.setString(key, '{"t":$now,"d":$dataJson}');
      await _sweep(p);
    } catch (_) {
      // An uncacheable payload must never break the request that produced it.
    }
  }

  /// Coarse invalidation: any successful write through RestClient calls this
  /// for the whole restaurant (every outlet). A settle changes /orders, the
  /// bill, and half of /analytics/* at once — a clever path-prefix map would
  /// go stale the day a route moves, while "a write happened, trust nothing
  /// saved" can only ever cost one skeleton.
  Future<void> bustRestaurant(String res) async {
    try {
      final p = await _prefs;
      final prefix = '$keyPrefix$res|';
      for (final k
          in p.getKeys().where((k) => k.startsWith(prefix)).toList()) {
        await p.remove(k);
      }
    } catch (_) {
      // Failing to bust is handled by the next successful GET overwriting.
    }
  }

  /// Drops every cache entry of every schema version. Called on a voluntary
  /// sign-out: that is the "handing the till over" gesture, and business data
  /// should not outlive it on disk.
  Future<void> clearAll() async {
    try {
      final p = await _prefs;
      for (final k
          in p.getKeys().where((k) => k.startsWith(_familyPrefix)).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }

  /// Removes entries from older schema versions, then evicts oldest-first
  /// until both caps hold.
  Future<void> _sweep(SharedPreferences p) async {
    for (final k in p
        .getKeys()
        .where((k) => k.startsWith(_familyPrefix) && !k.startsWith(keyPrefix))
        .toList()) {
      await p.remove(k);
    }
    final entries = <_SweepEntry>[];
    var total = 0;
    for (final k in p.getKeys().where((k) => k.startsWith(keyPrefix))) {
      final raw = p.getString(k);
      if (raw == null) continue;
      // An unreadable stamp sorts as oldest, so junk is evicted first.
      entries.add(_SweepEntry(k, _savedAtOf(raw) ?? 0, raw.length));
      total += raw.length;
    }
    if (entries.length <= maxEntries && total <= maxTotalChars) return;
    entries.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    var count = entries.length;
    for (final e in entries) {
      if (count <= maxEntries && total <= maxTotalChars) break;
      await p.remove(e.key);
      count--;
      total -= e.chars;
    }
  }

  /// Every entry is written as `{"t":<ms>,"d":...}`, so the stamp can be read
  /// with a substring instead of decoding a possibly large payload. Falls back
  /// to a full decode, and to null (= treat as oldest) for junk.
  static int? _savedAtOf(String raw) {
    if (raw.startsWith('{"t":')) {
      final comma = raw.indexOf(',');
      if (comma > 5) {
        final t = int.tryParse(raw.substring(5, comma));
        if (t != null) return t;
      }
    }
    try {
      final d = jsonDecode(raw);
      final t = d is Map ? d['t'] : null;
      return t is int ? t : null;
    } catch (_) {
      return null;
    }
  }

  /// The encoded payload part of an entry, for the unchanged-write skip.
  static String? _payloadOf(String raw) {
    final i = raw.indexOf(',"d":');
    if (i < 0 || !raw.endsWith('}')) return null;
    return raw.substring(i + 5, raw.length - 1);
  }
}

class _SweepEntry {
  final String key;
  final int savedAt;
  final int chars;
  _SweepEntry(this.key, this.savedAt, this.chars);
}
