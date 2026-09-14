import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/get_cache.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/empty_state.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/skeleton.dart';
import '../ui/widgets/status_chip.dart';

/// What a screen says when the line is down AND it has nothing saved to fall
/// back on — the genuinely empty case, after [GetCache]'s last-known-good copy
/// has been tried and had nothing either.
///
/// "Can't reach the server" was the old wording, and it told the person holding
/// the tablet nothing they could act on: it named the app's problem, not
/// theirs. These name the two things that are actually in their hands, and the
/// one conclusion to draw when neither works. Shared as constants because the
/// [CachePrimedScreen] modules must say the same words for the same state.
const String offlineNothingSavedTitle = 'This device is offline';
const String offlineNothingSavedCaption =
    "It can't reach the restaurant server, and this section has nothing saved "
    'to show. Reconnect to the restaurant Wi-Fi, or share a hotspot from a '
    "phone, then tap Retry. If the other devices can't reach it either, the "
    'server itself is down.';

/// Whether a failure means the LINE is down rather than the server having
/// answered with a refusal. Only the first may reach for a saved copy or wear
/// the offline wording: a 403 or a 500 is a real answer and must be shown as
/// one.
///
/// Same discrimination the offline outbox already makes on writes — an
/// [ApiException] carrying no status never reached anyone.
bool isUnreachableError(Object e) {
  if (e is ApiException) return e.status == null;
  final raw = e.toString();
  return raw.contains('SocketException') ||
      raw.contains('refused') ||
      raw.contains('Failed host lookup') ||
      raw.contains('Connection') ||
      raw.contains('TimeoutException');
}

/// The pane a screen shows when it has nothing to show and the load failed.
///
/// Two different sentences for two different situations, which is the whole
/// reason it exists: an unreachable server is the READER's problem to act on
/// (their Wi-Fi, their hotspot), while a refusal is the server's own words and
/// must be repeated verbatim rather than dressed up as an outage. [whatFailed]
/// names the section for the second case only — offline, the section is
/// irrelevant, because none of them can load.
class LoadErrorState extends StatelessWidget {
  const LoadErrorState({
    super.key,
    required this.whatFailed,
    required this.error,
    required this.onRetry,
  });

  final String whatFailed;
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = isUnreachableError(error);
    return EmptyState(
      icon: offline ? Icons.wifi_off : Icons.error_outline,
      title: offline ? offlineNothingSavedTitle : whatFailed,
      caption: offline ? offlineNothingSavedCaption : error,
      action: ForkButton(label: 'Retry', icon: Icons.refresh, dense: true, onPressed: onRetry),
    );
  }
}

/// Loads a future and renders loading / error+retry / content. Reused by every
/// feature module so each screen is just "load this endpoint, render the data".
class AsyncView<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;

  /// How often this view refetches on its own. Null — the default, and what every
  /// existing caller keeps — loads once and only reloads when asked.
  ///
  /// A poll is always SILENT, and that is the whole point of the parameter: the
  /// data already on screen STAYS on screen until the new payload lands, so the
  /// view updates in place instead of being replaced by the loading skeleton
  /// every tick. The kitchen board has no realtime push behind it, so it
  /// genuinely has to poll — what it must not do is blink. Copied from the
  /// waitlist's hand-rolled `_load(silent: true)`, which is the same shape.
  ///
  /// The timer is owned HERE rather than by the caller, so it lives and dies with
  /// the view it refreshes: a screen that swaps this view out (Tickets -> Expo)
  /// cannot leave a timer ticking against a disposed State.
  final Duration? pollEvery;

  const AsyncView({super.key, required this.load, required this.builder, this.pollEvery});

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  /// The last payload that loaded successfully. Presence is tracked separately
  /// because `T` itself may be a nullable type.
  T? _data;
  bool _hasData = false;
  Object? _error;
  bool _loading = true;

  /// True while what is on screen came out of the persisted GET cache rather
  /// than the network. Cleared by the first successful load.
  bool _fromCache = false;

  /// True after a refresh failed while good data was on screen — the data
  /// stays, a non-blocking "offline" banner appears over it. Cleared by any
  /// successful load.
  bool _offline = false;

  /// True when what is on screen is a LAST-KNOWN-GOOD copy: saved before a
  /// write this app has since made, and painted only because the network was
  /// tried and could not be reached. It is a stronger claim than "a bit old",
  /// so it gets its own sentence on the pill.
  bool _superseded = false;

  /// When the payload on screen was last confirmed by the network: the save
  /// time of its oldest cache entry, or the moment a live load landed. Feeds
  /// the "updated Xm ago" label, which is the honesty affordance for screens
  /// where staleness could mislead (open bills, settle totals).
  DateTime? _dataAsOf;

  /// Identifies the newest request in flight. A slow poll that only lands after a
  /// hard reload has already answered must not overwrite the newer data.
  int _gen = 0;

  Timer? _poll;

  /// Keeps the relative "updated Xm ago" label moving while stale data is on
  /// screen. Only runs in that state, and dies with the view.
  Timer? _ageTick;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
    final every = widget.pollEvery;
    if (every != null) _poll = Timer.periodic(every, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ageTick?.cancel();
    super.dispose();
  }

  /// First paint: stale-while-revalidate. The load closure is replayed against
  /// the persisted GET cache (see [GetCachePolicy]) so a module the user has
  /// opened before paints its saved payload immediately — then the network
  /// refresh reuses the silent in-place path a poll already uses. Replaying
  /// the SAME closure is what keeps every composed loader (Overview stitches
  /// ten endpoints into one map) working with zero call-site changes: the
  /// replay succeeds exactly when every GET it performs is saved, and the
  /// payload shape is identical by construction. Safe to run the closure an
  /// extra time because AsyncView already re-runs it on every poll tick and
  /// reload — a side-effectful load was never allowed here.
  ///
  /// Three outcomes, read off the [CacheReplayStamp] (not the thrown error —
  /// composed loaders swallow errors internally):
  ///   * every GET hit the store  -> paint the saved copy, refresh silently;
  ///   * any GET missed           -> the composed payload has holes, and holes
  ///     render as confident zeros; the skeleton is more honest, so this falls
  ///     back to the plain network load;
  ///   * the closure never touched the cache layer at all -> the replay WAS
  ///     the real load (arbitrary caller-supplied work must not run twice), so
  ///     its result or failure is delivered exactly as _load would have.
  Future<void> _boot() async {
    final gen = ++_gen;
    final stamp = CacheReplayStamp();
    T data;
    try {
      data = await GetCachePolicy.runCacheOnly(widget.load, stamp);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      if (stamp.hits == 0 && stamp.misses == 0 && e is! CacheMiss) {
        // A non-cache-aware load really failed: same as a failed first load.
        setState(() { _error = e; _loading = false; });
        return;
      }
      await _load();
      return;
    }
    if (!mounted || gen != _gen) return;
    if (stamp.misses > 0) {
      await _load();
      return;
    }
    final fromCache = stamp.hits > 0;
    setState(() {
      _data = data;
      _hasData = true;
      _error = null;
      _loading = false;
      _fromCache = fromCache;
      _dataAsOf = fromCache ? (stamp.oldestSavedAt ?? DateTime.now()) : DateTime.now();
    });
    if (fromCache) {
      _syncAgeTick();
      await _load(silent: true);
    }
  }

  /// THE OFFLINE LAST RESORT, and the only caller anywhere that is allowed to
  /// read a superseded entry.
  ///
  /// It runs in exactly one situation: the network has already been tried on
  /// this screen and could not be reached, and there is nothing on screen to
  /// keep. Before this existed that combination produced "Can't reach the
  /// server" on every module, because an evening of ordinary online writes had
  /// invalidated every saved copy on the device — see [GetCache.bustRestaurant].
  ///
  /// Ordering matters and is deliberate: the network is tried FIRST, always.
  /// A saved copy is never a shortcut past a reachable server, only a
  /// replacement for a blank screen — and what it paints carries the offline
  /// pill with the copy's own age on it, never a live-looking screen.
  ///
  /// The same all-or-nothing rule as the fast path: any miss means a composed
  /// payload with holes, and holes render as confident zeros.
  Future<bool> _paintLastKnownGood(int gen) async {
    final stamp = CacheReplayStamp();
    T data;
    try {
      data = await GetCachePolicy.runCacheOnly(widget.load, stamp, allowStale: true);
    } catch (_) {
      return false;
    }
    if (!mounted || gen != _gen) return false;
    if (stamp.hits == 0 || stamp.misses > 0) return false;
    setState(() {
      _data = data;
      _hasData = true;
      _error = null;
      _loading = false;
      _fromCache = true;
      _offline = true;
      _superseded = stamp.supersededHits > 0;
      _dataAsOf = stamp.oldestSavedAt;
    });
    _syncAgeTick();
    return true;
  }

  /// [silent] keeps whatever is on screen on screen while the refetch is in
  /// flight: no skeleton, and no error state if it fails. Because the widget tree
  /// at this slot never changes shape (the staleness pill included, see
  /// [_StaleFrame]), nothing below is remounted either — scroll position, the
  /// selected filter and every child's own state survive.
  Future<void> _load({bool silent = false}) async {
    final gen = ++_gen;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final data = await widget.load();
      if (!mounted || gen != _gen) return;
      setState(() {
        _data = data;
        _hasData = true;
        _error = null;
        _loading = false;
        _fromCache = false;
        _offline = false;
        _superseded = false;
        _dataAsOf = DateTime.now();
      });
      _syncAgeTick();
    } catch (e) {
      if (!mounted || gen != _gen) return;
      // A failed load must never replace good data with an error screen: the
      // kitchen keeps the tickets it has and the next tick tries again. What
      // it must do is SAY so — the non-blocking banner over the data marks it
      // "offline, showing saved data" instead of letting a stale board pass
      // for a live one. This holds for a failed manual reload too: the user
      // asked for fresh, fresh is unreachable, and the saved copy plus the
      // banner beats trading the whole screen for an error page.
      if (_hasData) {
        setState(() { _offline = true; _loading = false; _error = null; });
        _syncAgeTick();
        return;
      }
      // Nothing on screen and nothing live. Before an error page — which tells
      // a waiter nothing they can act on — try the last-known-good copy.
      if (isUnreachableError(e) && await _paintLastKnownGood(gen)) return;
      if (!mounted || gen != _gen) return;
      setState(() { _error = e; _loading = false; });
    }
  }


  /// The reload every caller already had: user-initiated, so it is allowed to
  /// show the skeleton while it refetches — and because it goes through the
  /// normal network path, it always bypasses the cache.
  void _reload() => unawaited(_load());

  void _syncAgeTick() {
    final need = _offline || _fromCache;
    if (need) {
      _ageTick ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ageTick?.cancel();
      _ageTick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _LoadingSkeleton();
    if (_error != null) {
      final err = _error!;
      final isConn = isUnreachableError(err);
      return EmptyState(
        icon: isConn ? Icons.wifi_off : Icons.error_outline,
        title: isConn ? offlineNothingSavedTitle : "Couldn't load this section.",
        caption: isConn ? offlineNothingSavedCaption : err.toString(),
        action: ForkButton(
          label: 'Retry',
          icon: Icons.refresh,
          dense: true,
          onPressed: _reload,
        ),
      );
    }
    final content = widget.builder(context, _data as T, _reload);
    // The staleness affordance. Offline always shows; a saved copy that is
    // still being refreshed only labels itself once it is old enough to
    // mislead (a copy seconds old is fresher than the poll intervals the
    // boards already live with).
    final asOf = _dataAsOf;
    final aged = asOf != null &&
        DateTime.now().difference(asOf) > const Duration(seconds: 60);
    return _StaleFrame(
      content: content,
      banner: _offline || (_fromCache && aged)
          ? _StaleBanner(offline: _offline, asOf: asOf, superseded: _superseded)
          : null,
    );
  }
}

/// Cache-primed boot for the screens whose orchestration cannot live inside an
/// AsyncView — server-side pagination (Audit log, Guests), action flows that
/// own their refresh (Waitlist's call/seat, the cash drawer), composed loads
/// with local filter state (Accounting). Those screens FEED the persisted GET
/// cache through RestClient but used to never paint from it, so they were the
/// only modules still opening on a skeleton.
///
/// This is AsyncView._boot extracted, not a second mechanism: the screen's
/// replayable fetch runs under the same [GetCachePolicy.runCacheOnly] zone, the
/// same [CacheReplayStamp] decides between "paint the saved copy" and "the
/// skeleton is more honest", and the same [_StaleBanner] is the affordance. The
/// only difference is that painting goes through the screen's own [setState]
/// (via `apply`) because these screens hold their data in fields, not in an
/// AsyncView slot.
///
/// Contract for every mixed-in screen:
///  * every load path (loud, silent, append) starts with `bumpCacheGen()` and
///    drops its result unless `cacheGenIs` still holds — the guard that keeps a
///    slow stale refresh from clobbering a newer answer;
///  * a load that lands from the network calls [markCacheLive] inside its
///    setState; a refresh that fails while data is on screen calls
///    [markCacheOffline] instead of replacing the data with an error;
///  * the build wraps its data-bearing return in [cacheStaleOverlay].
mixin CachePrimedScreen<T extends StatefulWidget> on State<T> {
  /// True while what is on screen came out of the persisted store rather than
  /// the network. Cleared by [markCacheLive].
  bool _primedFromCache = false;

  /// True after a refresh failed while good data was on screen.
  bool _cacheOffline = false;

  /// AsyncView's `_superseded`: the copy on screen predates a write this app
  /// made, and is up only because the network could not be reached.
  bool _cacheSuperseded = false;

  /// When the payload on screen was last confirmed by the network — the save
  /// time of the oldest cache entry that fed it, or the moment a load landed.
  DateTime? _cacheAsOf;

  /// Identifies the newest request in flight, exactly like AsyncView's `_gen`.
  int _cacheGen = 0;

  /// How many times a load has landed FROM THE NETWORK on this screen.
  ///
  /// It is how [primeFromCache] learns whether the fallback it just awaited
  /// actually reached the server, without the mixin having to know the name of
  /// any screen's error field. Every screen already owes [markCacheLive] on a
  /// landed load — that documented contract is what makes this readable.
  int _cacheLiveMarks = 0;

  Timer? _cacheAgeTick;

  int bumpCacheGen() => ++_cacheGen;
  bool cacheGenIs(int gen) => gen == _cacheGen;

  @override
  void dispose() {
    _cacheAgeTick?.cancel();
    super.dispose();
  }

  /// initState entry point. Replays [fetch] — the screen's initial GET
  /// composition, with no side effects — against the persisted store. When
  /// every GET hits, [apply] paints the saved payload (inside setState here,
  /// so `apply` only assigns fields) and [refresh] — the screen's silent
  /// in-place reload — chases it with the real network read. Any miss, or a
  /// fetch that failed outright, falls back to [fallback], the screen's
  /// ordinary loud first load: a composed payload with holes would render as
  /// confident zeros, and the skeleton is more honest than that.
  ///
  /// And when THAT fallback cannot reach the server either — the offline-launch
  /// case — the last-known-good copy is tried before the screen is left showing
  /// an error page. Same rule as AsyncView's: network first, always; a saved
  /// copy is a replacement for a blank screen, never a shortcut past a
  /// reachable server; and what it paints wears the offline pill with its own
  /// age on it.
  Future<void> primeFromCache<D>({
    required Future<D> Function() fetch,
    required void Function(D data) apply,
    required Future<void> Function() refresh,
    required Future<void> Function() fallback,
  }) async {
    final gen = bumpCacheGen();
    final stamp = CacheReplayStamp();
    D data;
    try {
      data = await GetCachePolicy.runCacheOnly(fetch, stamp);
    } catch (_) {
      if (!mounted || !cacheGenIs(gen)) return;
      await _fallbackThenLastKnownGood(fetch, apply, fallback);
      return;
    }
    if (!mounted || !cacheGenIs(gen)) return;
    if (stamp.misses > 0 || stamp.hits == 0) {
      await _fallbackThenLastKnownGood(fetch, apply, fallback);
      return;
    }
    setState(() {
      apply(data);
      _primedFromCache = true;
      _cacheOffline = false;
      _cacheSuperseded = false;
      _cacheAsOf = stamp.oldestSavedAt ?? DateTime.now();
    });
    _syncCacheAgeTick();
    await refresh();
  }

  /// The screen's own loud load, and — only if it never reached the server —
  /// the last-known-good copy.
  ///
  /// "Never reached the server" is read off [markCacheLive], which every screen
  /// already calls when a load lands. That is why this needs no per-screen
  /// predicate and no call-site changes: a fallback that landed bumps the
  /// counter, and one that failed (for any reason: offline, 500, 403) does not.
  /// A superseded copy is only ever painted for the first of those three,
  /// because [GetCache] is asked for one only after a genuine outage — a
  /// refusal that a server actually answered still shows as a refusal, since
  /// nothing here can turn `_cacheGen` back or clear the screen's error unless
  /// the replay fully hits.
  Future<void> _fallbackThenLastKnownGood<D>(
    Future<D> Function() fetch,
    void Function(D data) apply,
    Future<void> Function() fallback,
  ) async {
    final marksBefore = _cacheLiveMarks;
    await fallback();
    if (!mounted) return;
    if (_cacheLiveMarks != marksBefore) return; // the network answered
    // The generation to guard against is whatever the FALLBACK left current —
    // it bumps the counter itself, so the prime's own generation is already
    // spent by the time this line runs. What must still be caught is a load
    // that starts AFTER this point (a filter change, a poll tick): its answer
    // is newer than the copy about to be painted and must win.
    final gen = _cacheGen;
    final stamp = CacheReplayStamp();
    D data;
    try {
      data = await GetCachePolicy.runCacheOnly(fetch, stamp, allowStale: true);
    } catch (_) {
      return;
    }
    if (!mounted || !cacheGenIs(gen)) return;
    if (_cacheLiveMarks != marksBefore) return;
    if (stamp.hits == 0 || stamp.misses > 0) return;
    setState(() {
      apply(data);
      _primedFromCache = true;
      _cacheOffline = true;
      _cacheSuperseded = stamp.supersededHits > 0;
      _cacheAsOf = stamp.oldestSavedAt;
    });
    _syncCacheAgeTick();
  }

  /// A network load landed: the data on screen is live. Call inside setState.
  void markCacheLive() {
    _cacheLiveMarks++;
    _primedFromCache = false;
    _cacheOffline = false;
    _cacheSuperseded = false;
    _cacheAsOf = DateTime.now();
    _syncCacheAgeTick();
  }

  /// A refresh failed while data stayed on screen. Call inside setState.
  void markCacheOffline() {
    _cacheOffline = true;
    _syncCacheAgeTick();
  }

  void _syncCacheAgeTick() {
    final need = _cacheOffline || _primedFromCache;
    if (need) {
      _cacheAgeTick ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _cacheAgeTick?.cancel();
      _cacheAgeTick = null;
    }
  }

  /// The same staleness affordance AsyncView paints: offline always shows, a
  /// saved copy still being refreshed labels itself once old enough to mislead.
  Widget cacheStaleOverlay(Widget content) {
    final asOf = _cacheAsOf;
    final aged = asOf != null &&
        DateTime.now().difference(asOf) > const Duration(seconds: 60);
    // One tree with or without the pill, so its clearing never remounts the
    // screen's list (see [_StaleFrame]).
    return _StaleFrame(
      content: content,
      banner: _cacheOffline || (_primedFromCache && aged)
          ? _StaleBanner(offline: _cacheOffline, asOf: asOf, superseded: _cacheSuperseded)
          : null,
    );
  }
}

/// [content], with the staleness pill floating over it or not — in the SAME
/// tree either way.
///
/// Both staleness affordances used to return the bare `content` when there was
/// no pill and a Stack when there was. That changes the widget type at the
/// slot, so whenever the pill came or went (the silent refresh landing over a
/// saved copy more than a minute old, the line dropping or coming back, the age
/// tick crossing the minute) everything under it was thrown away and mounted
/// afresh: every list back at offset 0, every child's own state gone. On a page
/// scrolled down to a section that reads as the page jumping to the top by
/// itself, and it undid the Analytics section chips' scroll-back whenever the
/// window they returned to had an old saved copy. Always the Stack, with the
/// pill as an optional second child, keeps [content] at index 0 of one Stack,
/// so a refresh updates it in place.
class _StaleFrame extends StatelessWidget {
  const _StaleFrame({required this.content, required this.banner});

  final Widget content;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final pill = banner;
    // Passthrough keeps the builder's constraints byte-identical to what it
    // received before the banner existed — loosening them here could re-lay-out
    // every module for the sake of a chip. With [content] the only non-positioned
    // child, the Stack is exactly its size.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        content,
        if (pill != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.xl,
            child: IgnorePointer(child: Center(child: pill)),
          ),
      ],
    );
  }
}

/// Floating, non-blocking staleness pill. Reuses the design system's chip
/// language (StatusChip for a warning state, InfoChip for quiet metadata) on a
/// raised opaque backing so it stays readable over any module body.
class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.offline, required this.asOf, this.superseded = false});

  final bool offline;
  final DateTime? asOf;

  /// The copy predates a change this app itself made — so it is not merely old,
  /// it is known to be behind. Saying only "saved data" there would let a
  /// waiter read a table board from before the order they just took as simply
  /// a slightly late one.
  final bool superseded;

  @override
  Widget build(BuildContext context) {
    final age = _ago(asOf);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.borderStrong),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: offline
          ? StatusChip(
              label: superseded
                  ? 'Offline — last copy from before your recent changes · $age'
                  : 'Offline — showing saved data · $age',
              color: AppColors.warning,
            )
          : InfoChip(icon: Icons.history, label: 'Updated $age'),
    );
  }

  static String _ago(DateTime? t) {
    if (t == null) return 'a moment ago';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 45) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// Quiet shimmer placeholder shown while a section loads — a few skeleton
/// rows on the dark surface instead of a bare spinner.
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      children: [
        const SkeletonBox(width: 180, height: 22, radius: 7),
        const SizedBox(height: AppSpacing.xl),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Container(
              padding: AppSpacing.cardPad,
              decoration: BoxDecoration(
                color: AppColors.inset,
                borderRadius: AppRadius.cardAll,
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 10),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SkeletonBox(width: 160, height: 13),
                        SizedBox(height: 8),
                        SkeletonBox(width: 90, height: 11),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  const SkeletonBox(width: 56, height: 24, radius: 8),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
