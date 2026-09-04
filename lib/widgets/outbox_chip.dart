import 'dart:async';

import 'package:flutter/material.dart';

import '../services/outbox.dart';
import '../services/rest_client.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/status_chip.dart';

/// THE HONESTY AFFORDANCE for writes, and the twin of the read cache's
/// "Offline — showing saved data" pill.
///
/// A queued order is NOT an order the kitchen has seen, and nothing on a screen
/// may imply otherwise. So the count of unsent actions lives permanently in the
/// AppBar, in the same chip language as the staleness banner, and opens a sheet
/// that names every single one of them.
///
/// It renders NOTHING when the queue is empty. That is the constraint the whole
/// feature is held to: a restaurant with a good connection can never tell this
/// shipped.
class OutboxChip extends StatefulWidget {
  const OutboxChip({super.key, required this.rest});

  final RestClient rest;

  @override
  State<OutboxChip> createState() => _OutboxChipState();
}

class _OutboxChipState extends State<OutboxChip> {
  /// The replay heartbeat. It lives here — on a widget that exists exactly as
  /// long as a signed-in shell does — so there is no timer running against a
  /// logged-out session, and none at all in a test that never mounts the shell.
  ///
  /// A tick with an empty queue does nothing and touches no network, so this
  /// adds no traffic online. With a queue it is the probe that notices the line
  /// came back when nothing else happens to be polling.
  static const Duration _heartbeat = Duration(seconds: 8);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Unsent work survives a restart; load it before anyone writes again so the
    // count is right from the first frame.
    _syncScope();
    // The queue is scoped restaurant|outlet exactly like the read cache, so
    // switching branches switches queues. Without this the chip would keep
    // showing branch A's count while the user is standing in branch B — a
    // number about the wrong restaurant is worse than no number. The write path
    // re-scopes on its own (RestClient does it before every write), so this is
    // purely about what the chrome SAYS.
    widget.rest.auth.addListener(_syncScope);
    _timer = Timer.periodic(_heartbeat, (_) {
      if (!mounted) return;
      if (!Outbox.instance.hasPending) return;
      unawaited(widget.rest.drainOutbox());
    });
  }

  @override
  void didUpdateWidget(OutboxChip old) {
    super.didUpdateWidget(old);
    if (!identical(old.rest.auth, widget.rest.auth)) {
      old.rest.auth.removeListener(_syncScope);
      widget.rest.auth.addListener(_syncScope);
    }
    _syncScope();
  }

  void _syncScope() => unawaited(widget.rest.ensureOutboxScope());

  @override
  void dispose() {
    widget.rest.auth.removeListener(_syncScope);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Outbox.instance,
      builder: (context, _) {
        final pending = Outbox.instance.pendingCount;
        final failed = Outbox.instance.failedCount;
        if (pending == 0 && failed == 0) return const SizedBox.shrink();
        final blocked = failed > 0;
        final label = blocked
            ? "$failed didn't send"
            : '$pending waiting to send';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Tooltip(
            message: blocked
                ? 'Some actions could not be sent. Open to see what.'
                : 'Saved on this device — not sent to the server yet.',
            child: InkWell(
              onTap: () => showOutboxSheet(context, widget.rest),
              borderRadius: BorderRadius.circular(999),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                StatusChip(
                  label: label,
                  color: blocked ? AppColors.danger : AppColors.warning,
                  dense: true,
                ),
                if (blocked && pending > 0) ...[
                  const SizedBox(width: 4),
                  InfoChip(label: '$pending held'),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// A per-subject pending marker — "this TABLE has work the kitchen has not
/// seen", not just "the app has work somewhere". A global count alone would
/// still let a waiter walk up to table 4 believing its order is in.
///
/// Invisible when that subject has nothing waiting, so an online floor plan is
/// byte-identical to what it is today.
class OutboxTagBadge extends StatelessWidget {
  const OutboxTagBadge({
    super.key,
    required this.tag,
    this.dense = true,
    this.gap = 0,
  });

  /// The grouping key, e.g. `table:T4` (see [OutboxPolicy.tagFor]).
  final String tag;
  final bool dense;

  /// Leading space applied ONLY when the badge is visible. A plain `SizedBox`
  /// separator, or a `Wrap`'s spacing, would reserve a gap for a badge that is
  /// not there and shift every card by a few pixels on a healthy connection —
  /// which is exactly the "you can tell this shipped" the feature is not
  /// allowed to cost.
  final double gap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Outbox.instance,
      builder: (context, _) {
        final failed = Outbox.instance.failedForTag(tag);
        final pending = Outbox.instance.pendingForTag(tag);
        if (failed == 0 && pending == 0) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(left: gap),
          child: failed > 0
              ? StatusChip(
                  label: failed == 1 ? "1 didn't send" : "$failed didn't send",
                  color: AppColors.danger,
                  dense: dense,
                )
              : StatusChip(
                  label: pending == 1 ? 'Not sent yet' : '$pending not sent yet',
                  color: AppColors.warning,
                  dense: dense,
                ),
        );
      },
    );
  }
}

/// The list of everything the server has not been told about, and what happened
/// to the ones that will never go.
Future<void> showOutboxSheet(BuildContext context, RestClient rest) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _OutboxSheet(rest: rest),
  );
}

class _OutboxSheet extends StatefulWidget {
  const _OutboxSheet({required this.rest});
  final RestClient rest;

  @override
  State<_OutboxSheet> createState() => _OutboxSheetState();
}

class _OutboxSheetState extends State<_OutboxSheet> {
  String? _notice;

  Future<void> _sendNow() async {
    setState(() => _notice = null);
    final result = await widget.rest.drainOutbox();
    if (!mounted) return;
    setState(() {
      switch (result.outcome) {
        case OutboxDrainOutcome.drained:
          _notice = result.sent == 0
              ? 'Nothing was waiting.'
              : 'Sent ${result.sent}. Everything is through.';
        case OutboxDrainOutcome.offline:
          _notice = 'Still no connection. Nothing was lost — it stays saved.';
        case OutboxDrainOutcome.blocked:
          _notice = 'One action was rejected by the server. It is listed below '
              'with the reason, and the rest are held behind it.';
        case OutboxDrainOutcome.retryLater:
          _notice = 'The server could not take it just now. It will try again.';
        case OutboxDrainOutcome.signedOut:
          _notice = 'Sign in again to send these.';
        case OutboxDrainOutcome.idle:
          _notice = 'Nothing was waiting.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AnimatedBuilder(
      animation: Outbox.instance,
      builder: (context, _) {
        final entries = Outbox.instance.entries;
        final pending = Outbox.instance.pendingCount;
        final failed = Outbox.instance.failedCount;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xxl, 0, AppSpacing.xxl, AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Waiting to send', style: text.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  failed > 0
                      ? "$pending saved on this device, $failed couldn't be sent. "
                          'Nothing here has reached the kitchen or the books.'
                      : 'Saved on this device. Nothing here has reached the '
                          'kitchen or the books yet.',
                  style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_notice != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.inset,
                      borderRadius: AppRadius.controlAll,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(_notice!,
                        style: text.bodySmall
                            ?.copyWith(color: AppColors.textSecondary)),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                Flexible(
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                          child: Text('Everything has been sent.',
                              style: text.bodyMedium
                                  ?.copyWith(color: AppColors.textSecondary)),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (context, i) => _OutboxRow(
                            entry: entries[i],
                            onRetry: () => Outbox.instance.retry(entries[i].id),
                            onDiscard: () => _confirmDiscard(entries[i]),
                          ),
                        ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(children: [
                  ForkButton(
                    label: Outbox.instance.isDraining ? 'Sending…' : 'Send now',
                    icon: Icons.cloud_upload_outlined,
                    dense: true,
                    onPressed: Outbox.instance.isDraining ? null : _sendNow,
                  ),
                  const Spacer(),
                  ForkButton.ghost(
                    label: 'Close',
                    dense: true,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Discarding is the one way work leaves this queue unsent, so it is always a
  /// deliberate human act with the thing named back to them — never a timeout,
  /// an eviction, or a silent drop.
  Future<void> _confirmDiscard(OutboxEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Discard this action?'),
        content: Text(
            '"${entry.what}" will be thrown away and never sent. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok == true) await Outbox.instance.discard(entry.id);
  }
}

class _OutboxRow extends StatelessWidget {
  const _OutboxRow({
    required this.entry,
    required this.onRetry,
    required this.onDiscard,
  });

  final OutboxEntry entry;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final failed = entry.failed;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.inset,
        borderRadius: AppRadius.controlAll,
        border: Border.all(
            color: failed ? AppColors.edge(AppColors.danger) : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(failed ? Icons.error_outline : Icons.schedule,
                size: 15,
                color: failed ? AppColors.danger : AppColors.textTertiary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(entry.what,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium),
            ),
            const SizedBox(width: AppSpacing.sm),
            StatusChip(
              label: failed ? 'Failed' : 'Waiting',
              color: failed ? AppColors.danger : AppColors.warning,
              dense: true,
            ),
          ]),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${entry.method} ${entry.path} · saved ${_ago(entry.queuedAt)}',
            style: text.bodySmall?.copyWith(color: AppColors.textTertiary),
          ),
          if (failed) ...[
            const SizedBox(height: AppSpacing.sm),
            // The server's own words, verbatim. A parked action that cannot say
            // why it is parked is barely better than one that vanished.
            Text(
              entry.failureStatus == null
                  ? (entry.failureMessage ?? 'The server rejected this.')
                  : 'Server said (${entry.failureStatus}): ${entry.failureMessage ?? 'rejected'}',
              style: text.bodySmall?.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(children: [
              ForkButton.ghost(
                  label: 'Try again',
                  icon: Icons.refresh,
                  dense: true,
                  onPressed: onRetry),
              const SizedBox(width: AppSpacing.sm),
              ForkButton.subtle(
                  label: 'Discard', icon: Icons.delete_outline, onPressed: onDiscard),
            ]),
          ],
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 45) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
