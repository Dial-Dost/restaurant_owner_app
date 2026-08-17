import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/empty_state.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/skeleton.dart';

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

  /// Identifies the newest request in flight. A slow poll that only lands after a
  /// hard reload has already answered must not overwrite the newer data.
  int _gen = 0;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    final every = widget.pollEvery;
    if (every != null) _poll = Timer.periodic(every, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
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
      setState(() { _data = data; _hasData = true; _error = null; _loading = false; });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      // A failed poll must never replace good data with an error screen: the
      // kitchen keeps the tickets it has and the next tick tries again.
      if (silent && _hasData) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  /// The reload every caller already had: user-initiated, so it is allowed to
  /// show the skeleton while it refetches.
  void _reload() => unawaited(_load());

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
    return widget.builder(context, _data as T, _reload);
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
