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
  const AsyncView({super.key, required this.load, required this.builder});

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _reload() {
    setState(() {
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _LoadingSkeleton();
        }
        if (snap.hasError) {
          final raw = snap.error.toString();
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
        return widget.builder(context, snap.data as T, _reload);
      },
    );
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
