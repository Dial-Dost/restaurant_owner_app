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

  /// How many of those hits came from a SUPERSEDED entry — one a later write
  /// invalidated, kept only as a last-known-good copy. Non-zero means the
  /// payload predates a change this app itself made, which is a different
  /// sentence on the staleness pill than "saved a while ago".
  int supersededHits = 0;

  /// The save time of the OLDEST entry that fed the replayed payload — the
  /// honest number for an "updated Xm ago" label over a composed screen.
  DateTime? oldestSavedAt;

  void recordHit(DateTime savedAt, {bool superseded = false}) {
    hits++;
    if (superseded) supersededHits++;
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
  static const _staleKey = #rdGetCacheAllowStale;

  static bool get isCacheOnly => Zone.current[_policyKey] == true;
  static CacheReplayStamp? get stamp =>
      Zone.current[_stampKey] as CacheReplayStamp?;

  /// Whether the replay in force may answer from a SUPERSEDED entry.
  ///
  /// Off by default, and that default is the whole safety property: the
  /// ordinary fast-open replay behaves exactly as it did before superseded
  /// entries existed, so a screen opened with the line up can never paint a
  /// copy that a write has already invalidated. Only the last-resort replay —
  /// the one that runs after the network has actually been tried and failed —
  /// turns this on, and what it paints is labelled offline and dated.
  static bool get allowStale => Zone.current[_staleKey] == true;

  /// Runs [body] with the cache-only policy active, recording what it touched
  /// into [stamp]. [allowStale] opts into the last-known-good copies; see
  /// [GetCachePolicy.allowStale] for why it must stay off everywhere else.
  static Future<T> runCacheOnly<T>(
          Future<T> Function() body, CacheReplayStamp stamp,
          {bool allowStale = false}) =>
      runZoned(body,
          zoneValues: {_policyKey: true, _stampKey: stamp, _staleKey: allowStale});
}

/// One stored GET response plus the moment it was confirmed by the network.
class CachedResponse {
  final DateTime savedAt;
  final dynamic data;

  /// True when a write has happened since this was saved, so the server has
  /// almost certainly moved on from it. The entry is kept anyway — see
  /// [GetCache.bustRestaurant] — but only the offline last-resort read is
  /// allowed to see it.
  final bool superseded;

  CachedResponse(this.savedAt, this.data, {this.superseded = false});
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
  ///
  /// v2 added the superseded marker (`"s":1`). The bump costs one cold start
  /// per screen on the release that lands it, and buys the guarantee that a
  /// build which does not understand the marker can never read a v2 entry as
  /// though it were live.
  static const String keyPrefix = 'rd_get_cache_v2|';
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

  /// [allowStale] admits SUPERSEDED entries — copies a later write invalidated.
  /// Default off, so every ordinary read behaves as if they had been deleted.
  Future<CachedResponse?> read(String res, String outlet, String path,
      {bool allowStale = false}) async {
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
      final superseded = decoded['s'] == 1;
      if (superseded && !allowStale) return null;
      return CachedResponse(
        DateTime.fromMillisecondsSinceEpoch(decoded['t'] as int),
        decoded['d'],
        superseded: superseded,
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
      if (old != null && !_supersededMark(old)) {
        // A SUPERSEDED entry never takes this shortcut even when the bytes
        // match: the whole point of the write is to clear the marker and put
        // a confirmed time back on the copy, and skipping would leave the app
        // labelling live data as a last-known-good one.
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
  ///
  /// INVALIDATES WITHOUT DELETING, and that distinction is this cache's whole
  /// offline story. The coarse rule above was written for a device that is
  /// online: a busted entry costs one skeleton because the network refills it
  /// in the same second. On a device that is NOT online it cost the screen —
  /// an evening of ordinary use ends with every entry deleted, so the moment
  /// the Wi-Fi drops, every module has nothing saved and shows an error page.
  /// That is the reported bug, and it was measured: browse three modules, take
  /// one order, and the store goes from three entries to zero.
  ///
  /// So the entry is MARKED superseded and its payload kept. The freshness
  /// rule does not move an inch — [read] hides a superseded entry from every
  /// ordinary caller, so the online fast-open path still cannot paint a copy a
  /// write has invalidated, and the "worst case is one skeleton, not a stale
  /// bill" reasoning holds exactly as before. What the kept payload buys is
  /// the case that reasoning never covered: the network has been tried, it is
  /// unreachable, and the choice is no longer skeleton-versus-stale but
  /// last-known-good-with-a-date versus a blank screen.
  ///
  /// The alternative — invalidating by path scope instead of by tenant, so a
  /// settle only drops /orders and /analytics — is worse here, for the reason
  /// the coarse rule already gives: the map is a second, silent copy of the
  /// server's routing table, and the day a route moves it starts serving a
  /// superseded payload as LIVE, with no banner and no date on it. That is the
  /// failure this cache must never have. Marking is strictly additive: it
  /// changes nothing about what counts as fresh, and adds a labelled fallback
  /// where there used to be nothing at all.
  Future<void> bustRestaurant(String res) async {
    try {
      final p = await _prefs;
      final prefix = '$keyPrefix$res|';
      for (final k in p.getKeys().where((k) => k.startsWith(prefix)).toList()) {
        final raw = p.getString(k);
        final marked = raw == null ? null : _withSupersededMark(raw);
        // Anything that cannot be marked (junk, an unexpected shape) is
        // removed, which is what it would have got before this existed.
        if (marked == null) {
          await p.remove(k);
        } else if (!identical(marked, raw)) {
          await p.setString(k, marked);
        }
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

  /// The superseded marker, read the same cheap way the stamp is.
  ///
  /// A marked entry is `{"t":<ms>,"s":1,"d":...}` — the marker goes BETWEEN the
  /// stamp and the payload on purpose, so both substring helpers above keep
  /// working unchanged: `_savedAtOf` still finds the stamp before the first
  /// comma, and `_payloadOf` still finds the first `,"d":`.
  static const String _mark = ',"s":1';

  static bool _supersededMark(String raw) => raw.startsWith('{"t":')
      ? raw.startsWith(_mark, raw.indexOf(','))
      : _supersededSlow(raw);

  static bool _supersededSlow(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is Map && d['s'] == 1;
    } catch (_) {
      return false;
    }
  }

  /// [raw] with the marker added. Returns [raw] itself when it is already
  /// marked, and null when the entry is not a shape this can mark — the caller
  /// drops those.
  static String? _withSupersededMark(String raw) {
    if (!raw.startsWith('{"t":')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 5 || int.tryParse(raw.substring(5, comma)) == null) return null;
    if (raw.startsWith(_mark, comma)) return raw;
    if (!raw.startsWith(',"d":', comma)) return null;
    return '${raw.substring(0, comma)}$_mark${raw.substring(comma)}';
  }
}

class _SweepEntry {
  final String key;
  final int savedAt;
  final int chars;
  _SweepEntry(this.key, this.savedAt, this.chars);
}
