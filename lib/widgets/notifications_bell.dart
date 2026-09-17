import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/rest_client.dart';
import '../services/restaurant_time.dart';
import '../ui/theme/app_colors.dart';

/// AppBar bell that polls the backend for staff notifications (customer payments,
/// online reservations, …), shows an unread badge, and opens a panel where each
/// notification can be read, cleared individually, or cleared all at once.
class NotificationsBell extends StatefulWidget {
  final RestClient rest;
  // Called when a notification is tapped so the shell can jump to the relevant
  // screen. [moduleLabel] is the destination module; [target] carries the
  // notification's parsed `meta` (entity ids like order_id/booking_id) so the
  // module can optionally focus the specific entity.
  final void Function(String moduleLabel, {Map<String, dynamic>? target})? onOpenModule;
  // Makes another outlet active (an outlet id, or 'all'). Null when this user
  // cannot switch — then a cross-outlet notification just explains itself.
  final void Function(String outletId)? onSwitchOutlet;
  // Modules this user can actually reach, so the sheet never offers a jump that
  // would silently no-op.
  final List<String> visibleLabels;
  const NotificationsBell({
    super.key,
    required this.rest,
    this.onOpenModule,
    this.onSwitchOutlet,
    this.visibleLabels = const [],
  });

  @override
  State<NotificationsBell> createState() => _NotificationsBellState();
}

class _NotificationsBellState extends State<NotificationsBell> {
  List _items = const [];
  int _unread = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 25), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final res = await widget.rest.get('/notifications');
      if (!mounted || res is! Map) return;
      setState(() {
        _items = (res['notifications'] as List?) ?? const [];
        _unread = (res['unread'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {/* offline / not signed in — ignore */}
  }

  Future<void> _do(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {/* ignore */}
  }

  // "2h ago" is an elapsed time, so it needs no timezone — but past a day it
  // stops being useful, and from there the bell states the actual instant in the
  // restaurant's zone like every other screen. The exact stamp (with the UTC
  // offset) is always one hover away, see the tooltip on the row.
  static String _fmt(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return RestaurantTime.short(iso);
  }

  static IconData _icon(String type) {
    switch (type) {
      case 'payment':
        return Icons.payments;
      case 'reservation':
        return Icons.event_seat;
      case 'order':
        return Icons.receipt_long;
      case 'waitlist':
        return Icons.hourglass_top;
      case 'valet':
        return Icons.local_parking;
      case 'warning':
        return Icons.warning_amber;
      default:
        return Icons.notifications;
    }
  }

  // Parse a notification's `meta` (jsonb). The API usually decodes it to a Map,
  // but tolerate a raw JSON string too.
  static Map<String, dynamic> _metaOf(dynamic meta) {
    if (meta is Map) return Map<String, dynamic>.from(meta);
    if (meta is String && meta.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {/* not JSON — ignore */}
    }
    return const {};
  }

  // The module a notification should open when tapped (null = no navigation).
  // Types + meta target ids are authoritative from the backend. `warning` is
  // overloaded, so it's disambiguated by which id its `meta` carries.
  static String? _moduleForType(String type, Map<String, dynamic> meta) {
    switch (type) {
      case 'order':
        return 'Orders';
      case 'payment':
        return 'Orders';
      case 'reservation':
        return 'Bookings';
      case 'waitlist':
        return 'Waitlist';
      case 'valet':
        return 'Valet';
      case 'warning':
        if (meta.containsKey('request_id')) return 'Orders'; // discount approval
        if (meta.containsKey('feedback_id')) return 'Feedback'; // low rating
        if (meta.containsKey('alert_key')) return 'Analytics'; // KPI alert
        return 'Analytics';
      case 'report':
        // Client item 9: Reports → Email reports; a 2.0.1 inbox bell says Accounting.
        return meta['module'] == 'Accounting' ? 'Accounting' : 'Reports';
      default:
        return null;
    }
  }

  // Ask the backend where a notification actually points: does the record still
  // exist, is it on the outlet we are viewing, and is it inside the destination
  // module's default filter (GET /notifications/:id/target). Returns null when
  // the resolver cannot be reached — the caller then falls back to the local
  // type -> module mapping.
  Future<Map<String, dynamic>?> _resolveTarget(String id) async {
    try {
      final res = await widget.rest.get('/notifications/$id/target');
      return res is Map ? Map<String, dynamic>.from(res) : null;
    } catch (_) {
      return null;
    }
  }

  // What the destination module needs to focus the record: the notification's
  // own meta, plus the resolver's entity so even an old row (meta with just
  // `order_id`) resolves to a concrete id.
  static Map<String, dynamic> _focusTarget(Map<String, dynamic> meta, Map<String, dynamic>? resolved) {
    final entity = resolved?['entity'];
    final merged = <String, dynamic>{...meta};
    if (entity is Map) {
      if (entity['id'] != null) merged['entity_id'] = '${entity['id']}';
      if (entity['type'] != null) merged['entity_type'] = '${entity['type']}';
    }
    return merged;
  }

  // A notification that cannot be opened where the user is standing: say why,
  // and offer the one action that would actually help.
  Future<void> _explain(Map<String, dynamic> resolved, String notificationId) async {
    if (!mounted) return;
    final reason = '${resolved['reason_gone'] ?? ''}';
    final message = '${resolved['message'] ?? 'This notification has nothing left to open.'}';
    final module = resolved['module'] == null ? null : '${resolved['module']}';
    final switchTo = resolved['switch_outlet_id'] == null ? null : '${resolved['switch_outlet_id']}';
    final meta = _metaOf(resolved['meta']);

    await showDialog<void>(
      context: context,
      // Actions are built with the dialog's own context so each one pops the
      // dialog route and nothing else.
      builder: (ctx) {
        final actions = <Widget>[
          // Another branch's record — switch outlet, then land on it.
          if (switchTo != null && widget.onSwitchOutlet != null)
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.onSwitchOutlet!(switchTo);
                if (module != null && widget.visibleLabels.contains(module)) {
                  widget.onOpenModule?.call(module, target: _focusTarget(meta, resolved));
                }
              },
              child: const Text('Switch outlet'),
            ),
          // Settled and older than the live window — History is where it lives now.
          if (reason == 'outside_live_window' && widget.visibleLabels.contains('History'))
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.onOpenModule?.call('History');
              },
              child: const Text('Open History'),
            ),
          // The record is gone for good — let the user retire the notification.
          if (reason == 'deleted' || reason == 'unknown_entity')
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _do(() async {
                  await widget.rest.delete('/notifications/$notificationId');
                });
                await _fetch();
              },
              child: const Text('Clear notification'),
            ),
          // Still worth showing the module (the queue, the discount log, …) even
          // though this particular record has moved on.
          if (switchTo == null && module != null && widget.visibleLabels.contains(module))
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.onOpenModule?.call(module);
              },
              child: Text('Open $module'),
            ),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ];
        return AlertDialog(
          backgroundColor: AppColors.cardRaised,
          icon: Icon(Icons.info_outline, color: AppColors.copperHi),
          title: const Text("Can't open that yet"),
          content: Text(message, style: TextStyle(color: AppColors.textSecondary)),
          actions: actions,
        );
      },
    );
  }

  // Tap-through: mark read, then either land on the record or explain honestly
  // why it is not where the user is looking. Never opens a screen the record
  // cannot be on.
  Future<void> _follow(Map n, bool unread) async {
    final id = '${n['id']}';
    final meta = _metaOf(n['meta']);
    if (unread) {
      await _do(() async {
        await widget.rest.post('/notifications/$id/read');
      });
    }
    await _fetch();
    final resolved = await _resolveTarget(id);
    if (!mounted) return;

    // Resolver unreachable (offline / older backend): keep the previous
    // behaviour — land on the module the type maps to.
    if (resolved == null) {
      final module = _moduleForType('${n['type']}', meta);
      if (module != null) {
        widget.onOpenModule?.call(module, target: meta.isEmpty ? null : meta);
      }
      return;
    }

    final module = resolved['module'] == null ? null : '${resolved['module']}';
    final reason = '${resolved['reason_gone'] ?? ''}';
    // Informational alert (a KPI warning): nothing to focus, but its module is
    // still the right place to look.
    if (resolved['visible_here'] == true || (reason == 'no_target' && module != null)) {
      // Nothing to open at all — say that rather than swallowing the tap.
      if (module == null) {
        await _explain(resolved, id);
        return;
      }
      if (widget.visibleLabels.isNotEmpty && !widget.visibleLabels.contains(module)) {
        await _explain({
          ...resolved,
          'message': 'This is in $module, which your role cannot open.',
          'reason_gone': 'no_permission',
          'module': null,
        }, id);
        return;
      }
      widget.onOpenModule?.call(
        module,
        target: reason == 'no_target' ? null : _focusTarget(meta, resolved),
      );
      return;
    }
    await _explain(resolved, id);
  }

  Future<void> _open() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> refreshBoth() async {
            await _fetch();
            if (ctx.mounted) setSheet(() {});
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                  child: Row(children: [
                    Text('Notifications', style: Theme.of(ctx).textTheme.titleLarge),
                    const Spacer(),
                    if (_items.isNotEmpty) ...[
                      TextButton(
                        onPressed: () => _do(() async {
                          await widget.rest.post('/notifications/read-all');
                          await refreshBoth();
                        }),
                        child: const Text('Mark all read'),
                      ),
                      TextButton(
                        onPressed: () => _do(() async {
                          await widget.rest.delete('/notifications');
                          await refreshBoth();
                        }),
                        child: Text('Clear all', style: TextStyle(color: AppColors.danger)),
                      ),
                    ],
                  ]),
                ),
                Divider(height: 1, color: AppColors.divider),
                Flexible(
                  child: _items.isEmpty
                      ? Padding(
                          padding: EdgeInsets.all(40),
                          child: Text('No notifications yet',
                              style: TextStyle(color: AppColors.textTertiary)))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.divider),
                          itemBuilder: (_, i) {
                            final n = _items[i] as Map;
                            final unread = n['read_at'] == null;
                            return ListTile(
                              leading: Icon(_icon('${n['type']}'),
                                  color: unread ? AppColors.copperHi : AppColors.textTertiary),
                              title: Text('${n['title'] ?? ''}',
                                  style: TextStyle(
                                    fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                                    color: unread ? AppColors.textPrimary : AppColors.textSecondary,
                                  )),
                              subtitle: Tooltip(
                                message: RestaurantTime.stamp('${n['created_at'] ?? ''}'),
                                child: Text('${n['body'] ?? ''}\n${_fmt('${n['created_at'] ?? ''}')}',
                                    style: TextStyle(color: AppColors.textSecondary)),
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                icon: Icon(Icons.close, size: 18, color: AppColors.textTertiary),
                                tooltip: 'Clear',
                                onPressed: () => _do(() async {
                                  await widget.rest.delete('/notifications/${n['id']}');
                                  await refreshBoth();
                                }),
                              ),
                              onTap: () async {
                                if (ctx.mounted) Navigator.of(ctx).pop();
                                await _follow(n, unread);
                              },
                            );
                          },
                        ),
                ),
              ]),
            ),
          );
        },
      ),
    );
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Notifications',
      onPressed: _open,
      icon: Badge.count(
        count: _unread,
        isLabelVisible: _unread > 0,
        backgroundColor: AppColors.copper,
        textColor: AppColors.onCopper,
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}
