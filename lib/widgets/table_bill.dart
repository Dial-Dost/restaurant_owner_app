import 'package:flutter/material.dart';

import '../services/rest_client.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/metric_tag.dart';
import '../ui/widgets/section_header.dart';
import '../ui/widgets/skeleton.dart';

/// What the person standing AT the table needs: everything already ordered on
/// it, what it adds up to, how many covers, and the average per cover against
/// the target.
///
/// One read backs all of it — GET /bill-for-table, which merges the table's
/// ACTIVE orders into a single running bill. It is deliberately the only table
/// read in the waiter/captain permission set (Action 98b10bde "View Bill"), so
/// this file works for a captain who cannot see the Tables module at all.
///
/// Read-only by design: editing the bill stays in the Tables module, behind the
/// table permission.
String _money(dynamic v) {
  final n = v is num ? v : num.tryParse('${v ?? ''}');
  return n == null ? '—' : '₹${n.toStringAsFixed(2)}';
}

double _num(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

/// Traffic-light colour for an `apc_status` ('green' / 'yellow' / 'red').
Color _apcColor(String status) => status == 'green'
    ? AppColors.success
    : status == 'yellow'
        ? AppColors.warning
        : AppColors.danger;

/// Short label for an `apc_status`, so the colour never travels alone.
String _apcLabel(String status) => status == 'green'
    ? 'APC on target'
    : status == 'yellow'
        ? 'APC close'
        : 'APC below target';

/// The table's running bill, or null when it has none open yet (the backend
/// answers 404 for an unoccupied / not-yet-ordered table). Never throws for that
/// case — a waiter opening a fresh table should see "nothing ordered yet", not
/// an error.
Future<Map<String, dynamic>?> loadTableBill(RestClient rest, String tableName) async {
  final name = tableName.trim();
  if (name.isEmpty) return null;
  try {
    final r = await rest.get('/bill-for-table?table_name=${Uri.encodeQueryComponent(name)}');
    return r is Map ? Map<String, dynamic>.from(r) : null;
  } catch (_) {
    return null;
  }
}

/// Compact "what this table is running at" strip: bill, covers, APC and the
/// target it is measured against, plus a labelled traffic light.
///
/// [pendingTotal] is an amount not yet sent to the kitchen (the cart being
/// typed in order entry). When non-zero the strip also projects what the APC
/// becomes once that cart is sent — the upsell signal while there is still time
/// to act on it.
class TableApcStrip extends StatelessWidget {
  const TableApcStrip({
    super.key,
    required this.bill,
    this.pendingTotal = 0,
    this.onTap,
  });

  final Map<String, dynamic> bill;
  final double pendingTotal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = '${bill['apc_status'] ?? 'neutral'}';
    final covers = _num(bill['covers']);
    final target = _num(bill['target_apc']);
    final running = _num(bill['subtotal'] ?? bill['total_amt']);
    final orders = (bill['order_ids'] as List?)?.length ?? 0;
    final items = (bill['items'] as List?)?.length ?? 0;
    // Projected APC once the cart in hand is sent. Covers is the divisor the
    // backend uses (counted once per table), so mirror it rather than invent one.
    final projected = covers > 0 ? (running + pendingTotal) / covers : 0.0;
    final showProjection = pendingTotal > 0 && covers > 0;

    return ForkCard(
      inset: true,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.receipt_long_outlined, size: 15, color: AppColors.copper),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              orders == 0
                  ? 'Nothing ordered on this table yet'
                  : '$orders active order${orders == 1 ? '' : 's'} · $items item${items == 1 ? '' : 's'}',
              style: text.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status != 'neutral') TickTag(_apcLabel(status), color: _apcColor(status)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 22, runSpacing: 10, children: [
          MicroStat(value: _money(running), label: 'running bill'),
          MicroStat(value: covers == 0 ? '—' : covers.toStringAsFixed(0), label: 'covers'),
          MicroStat(value: _money(bill['apc']), label: 'apc'),
          if (target != 0) MicroStat(value: _money(target), label: 'target apc'),
        ]),
        if (showProjection) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.tint(target != 0 && projected >= target ? AppColors.success : AppColors.copper),
              borderRadius: AppRadius.controlAll,
              border: Border.all(
                  color: AppColors.edge(target != 0 && projected >= target ? AppColors.success : AppColors.copper)),
            ),
            child: Row(children: [
              Icon(target != 0 && projected >= target ? Icons.trending_up : Icons.add_shopping_cart,
                  size: 14,
                  color: target != 0 && projected >= target ? AppColors.success : AppColors.copperHi),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'With this cart: ${_money(running + pendingTotal)} · APC ${_money(projected)}'
                  '${target == 0 ? '' : ' of ${_money(target)}'}',
                  style: text.bodySmall,
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// Read-only sheet: every item already on the table (its active orders merged),
/// the running bill, covers, and APC vs target with the server's own upsell
/// suggestions. Opened from the order list and from order entry.
Future<void> showTableBillSheet(
  BuildContext context, {
  required RestClient rest,
  required String tableName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _TableBillSheet(rest: rest, tableName: tableName),
  );
}

class _TableBillSheet extends StatefulWidget {
  const _TableBillSheet({required this.rest, required this.tableName});

  final RestClient rest;
  final String tableName;

  @override
  State<_TableBillSheet> createState() => _TableBillSheetState();
}

class _TableBillSheetState extends State<_TableBillSheet> {
  Map<String, dynamic>? _bill;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final b = await loadTableBill(widget.rest, widget.tableName);
    if (!mounted) return;
    setState(() {
      _bill = b;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bill = _bill;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(child: Text('Table ${widget.tableName}', style: text.titleLarge)),
                  ForkButton.subtle(label: 'Refresh', icon: Icons.refresh, onPressed: _load),
                ]),
                const SizedBox(height: AppSpacing.lg),
                if (_loading) ...[
                  for (var i = 0; i < 4; i++)
                    const Padding(padding: EdgeInsets.only(bottom: 10), child: SkeletonBox(height: 16)),
                ] else if (bill == null) ...[
                  ForkCard(
                    inset: true,
                    child: Row(children: [
                      const Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('No open bill on this table yet — nothing has been ordered.',
                            style: text.bodySmall),
                      ),
                    ]),
                  ),
                ] else ...[
                  TableApcStrip(bill: bill),
                  const SizedBox(height: AppSpacing.xl),
                  const SectionHeader(title: 'On this table'),
                  _items(bill),
                  const SizedBox(height: AppSpacing.lg),
                  _totals(bill),
                  _suggestions(bill),
                ],
              ]),
        ),
      ),
    );
  }

  // Every line already sent to the kitchen for this table (its active orders,
  // merged by the backend).
  Widget _items(Map<String, dynamic> bill) {
    final text = Theme.of(context).textTheme;
    final items = (bill['items'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
    if (items.isEmpty) {
      return Text('No items on the bill yet.', style: text.bodySmall);
    }
    return ForkCard(
      inset: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${it['name'] ?? '—'}  ×${it['quantity'] ?? 1}', style: text.bodyLarge),
                  if ('${it['note'] ?? ''}'.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${it['note']}',
                          style: text.bodySmall!.copyWith(fontSize: 11, fontStyle: FontStyle.italic)),
                    ),
                ]),
              ),
              const SizedBox(width: 10),
              Text(_money(_num(it['price']) * _num(it['quantity'] ?? 1)), style: text.titleSmall),
            ]),
          ),
      ]),
    );
  }

  Widget _totals(Map<String, dynamic> bill) {
    final text = Theme.of(context).textTheme;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: text.bodySmall)),
            Text(value, style: text.bodyLarge),
          ]),
        );
    return ForkCard(
      inset: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row('Subtotal', _money(bill['subtotal'] ?? bill['total_amt'])),
        if (_num(bill['discount']) > 0) row('Discount', '− ${_money(bill['discount'])}'),
        if (_num(bill['service_charge']) > 0) row('Service charge', _money(bill['service_charge'])),
        if (_num(bill['tax_total']) > 0) row('Tax', _money(bill['tax_total'])),
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: Text('TOTAL PAYABLE', style: text.labelSmall)),
          Text(_money(bill['grand_total'] ?? bill['total_amt']), style: text.displaySmall),
        ]),
      ]),
    );
  }

  // The server's own upsell lines — never ones we invent.
  Widget _suggestions(Map<String, dynamic> bill) {
    final status = '${bill['apc_status'] ?? 'neutral'}';
    if (status == 'neutral' || status == 'green') return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final c = _apcColor(status);
    final lines = (bill['apc_suggestions'] as List?) ?? const [];
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.tint(c),
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: AppColors.edge(c)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(status == 'red' ? Icons.trending_down : Icons.lightbulb_outline, size: 16, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(status == 'red' ? 'Below target — push to upsell' : 'Close to target — suggest more',
                style: text.titleSmall!.copyWith(color: c)),
          ),
        ]),
        const SizedBox(height: 6),
        if (lines.isEmpty)
          Text('Suggest a dessert or a drink to lift the bill.', style: text.bodySmall)
        else
          ...lines.map((s) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('• $s', style: text.bodySmall),
              )),
      ]),
    );
  }
}
