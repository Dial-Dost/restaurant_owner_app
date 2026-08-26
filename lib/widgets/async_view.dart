import 'dart:async';

import 'package:flutter/material.dart';

import '../services/get_cache.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/empty_state.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/skeleton.dart';
import '../ui/widgets/status_chip.dart';

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

  /// [silent] keeps whatever is on screen on screen while the refetch is in
  /// flight: no skeleton, and no error state if it fails. Because the widget tree
  /// at this slot never changes shape, nothing below is remounted either — scroll
  /// position, the selected filter and every child's own state survive.
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
      final raw = _error.toString();
      final isConn = raw.contains('SocketException') ||
          raw.contains('refused') ||
          raw.contains('Failed host lookup') ||
          raw.contains('Connection');
      final title = isConn ? "Can't reach the server" : "Couldn't load this section.";
      final detail = isConn
          ? "The app can't connect to the backend. Make sure the server is running, then retry."
          : raw;
      return EmptyState(
        icon: isConn ? Icons.wifi_off : Icons.error_outline,
        title: title,
        caption: detail,
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
    if (!_offline && !(_fromCache && aged)) return content;
    // Passthrough keeps the builder's constraints byte-identical to what it
    // received before the banner existed — loosening them here could re-lay-out
    // every module for the sake of a chip.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        content,
        Positioned(
          left: 0,
          right: 0,
          bottom: AppSpacing.xl,
          child: IgnorePointer(
            child: Center(
              child: _StaleBanner(offline: _offline, asOf: asOf),
            ),
          ),
        ),
      ],
    );
  }
}

/// Floating, non-blocking staleness pill. Reuses the design system's chip
/// language (StatusChip for a warning state, InfoChip for quiet metadata) on a
/// raised opaque backing so it stays readable over any module body.
class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.offline, required this.asOf});

  final bool offline;
  final DateTime? asOf;

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
              label: 'Offline — showing saved data · $age',
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
