import 'package:flutter/material.dart';

import '../services/phone_validation.dart';
import '../services/rest_client.dart';
import '../ui/theme/app_colors.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/skeleton.dart';
import '../ui/widgets/status_chip.dart';
import '../widgets/table_bill.dart';

/// Staff POS order entry for a table: pick menu items into a cart and send the
/// order. The order is attributed to the signed-in employee (for APC) and
/// appends to the table's single consolidated bill on the backend.
class OrderEntryScreen extends StatefulWidget {
  final RestClient rest;
  // null for takeaway/delivery (a virtual table is provisioned server-side).
  final String? tableName;
  // 'dine_in' (default), 'takeaway', or 'delivery'.
  final String orderType;
  const OrderEntryScreen({
    super.key,
    required this.rest,
    this.tableName,
    this.orderType = 'dine_in',
  });

  bool get isDineIn => orderType == 'dine_in';
  bool get isDelivery => orderType == 'delivery';

  @override
  State<OrderEntryScreen> createState() => _OrderEntryScreenState();
}

class _OrderEntryScreenState extends State<OrderEntryScreen> {
  late Future<List<dynamic>> _menu;
  final Map<String, int> _cart = {};
  final Map<String, String> _itemNotes = {}; // per-item kitchen note (by menu id)
  final Set<String> _itemHold = {}; // held courses (fired later from the KDS)
  final Map<String, Map> _itemsById = {};
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _custCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _addrCtrl = TextEditingController();
  String _query = '';
  bool _sending = false;
  String? _error;
  // What this table is ALREADY running at (its active orders merged, covers,
  // APC vs target). Dine-in only — a takeaway has no table to be per-head about.
  // Null until it loads, and stays null when the table has no open bill yet.
  Map<String, dynamic>? _tableBill;

  @override
  void initState() {
    super.initState();
    _menu = _load();
    _loadTableBill();
  }

  // Best-effort: a table with nothing on it yet simply has no bill, which is a
  // legitimate state here (the waiter is about to create the first order).
  Future<void> _loadTableBill() async {
    if (!widget.isDineIn) return;
    final name = widget.tableName ?? '';
    if (name.isEmpty) return;
    final bill = await loadTableBill(widget.rest, name);
    if (!mounted) return;
    setState(() => _tableBill = bill);
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _custCtrl.dispose();
    _phoneCtrl.dispose();
    _addrCtrl.dispose();
    super.dispose();
  }

  Future<List<dynamic>> _load() async {
    final items = await widget.rest.getList('/menu');
    _itemsById.clear();
    for (final it in items) {
      final m = it as Map;
      _itemsById['${m['id']}'] = m;
    }
    return items;
  }

  // Takeaway/delivery contact number. Optional, but anything typed must be a
  // real 10-digit mobile — the same rule the backend enforces on
  // POST /orders/takeaway, so Send never fails on a format the form allowed.
  String? get _phoneError => widget.isDineIn ? null : validateOptionalMobile10(_phoneCtrl.text);

  double _price(String id) => (_itemsById[id]?['price'] as num?)?.toDouble() ?? 0;
  double get _total => _cart.entries.fold(0.0, (s, e) => s + _price(e.key) * e.value);
  int get _count => _cart.values.fold(0, (s, q) => s + q);

  void _setQty(String id, int delta) {
    setState(() {
      final q = (_cart[id] ?? 0) + delta;
      if (q <= 0) {
        _cart.remove(id);
        _itemHold.remove(id);
      } else {
        _cart[id] = q;
      }
    });
  }

  Future<void> _send() async {
    if (_cart.isEmpty) return;
    // Block the send rather than letting the server reject it.
    if (_phoneError != null) {
      setState(() => _error = _phoneError);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final p = widget.rest.auth.profile;
    final items = _cart.entries.map((e) {
      final m = _itemsById[e.key]!;
      final note = (_itemNotes[e.key] ?? '').trim();
      return {
        'id': e.key,
        'name': m['name'],
        'price': m['price'],
        'quantity': e.value,
        if (note.isNotEmpty) 'note': note,
        // Course hold-and-fire: the kitchen fires held items on demand.
        if (_itemHold.contains(e.key)) 'course_hold': true,
      };
    }).toList();
    final base = <String, dynamic>{
      'items': items,
      'subtotal': _total,
      'total': _total,
      'taxes': [],
      'applyServiceCharge': false,
      'status': 'Preparing',
      if (_noteCtrl.text.trim().isNotEmpty) 'note': _noteCtrl.text.trim(),
      'taken_by_employee_id': p?.employeeId,
      'taken_by_employee_name': p?.firstName,
      'taken_by_employee_role': p?.role,
    };
    try {
      if (widget.isDineIn) {
        await widget.rest.post('/orders', {...base, 'table': widget.tableName});
      } else {
        await widget.rest.post('/orders/takeaway', {
          ...base,
          'order_type': widget.orderType,
          if (_custCtrl.text.trim().isNotEmpty) 'customer': _custCtrl.text.trim(),
          // Stored in the bare 10-digit form the backend normalizes to.
          if (normalizeMobile10(_phoneCtrl.text) != null)
            'customer_phone': normalizeMobile10(_phoneCtrl.text),
          if (widget.isDelivery && _addrCtrl.text.trim().isNotEmpty) 'delivery_address': _addrCtrl.text.trim(),
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _error = '$e';
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isDineIn
            ? 'New order · ${widget.tableName}'
            : widget.isDelivery
                ? 'New delivery'
                : 'New takeaway'),
      ),
      body: Column(children: [
        // What the table is already running at — visible while the order is
        // being built, so the waiter can see the per-head gap in time to close
        // it. Tapping opens the full item-by-item bill.
        if (widget.isDineIn && _tableBill != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TableApcStrip(
              bill: _tableBill!,
              pendingTotal: _total,
              onTap: () => showTableBillSheet(
                context,
                rest: widget.rest,
                tableName: widget.tableName ?? '',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search menu…',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _query = '')),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<dynamic>>(
            future: _menu,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (var i = 0; i < 8; i++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Row(children: [
                          SkeletonBox(width: 40, height: 40, radius: 10),
                          SizedBox(width: 12),
                          Expanded(child: SkeletonBox(height: 13)),
                        ]),
                      ),
                  ],
                );
              }
              if (snap.hasError) {
                return Center(child: Text('Failed to load menu: ${snap.error}'));
              }
              final items = snap.data ?? [];
              final q = _query.trim().toLowerCase();
              if (q.isNotEmpty) {
                // Flat, filtered list across all categories while searching.
                final matches = items
                    .where((it) => '${(it as Map)['name'] ?? ''}'.toLowerCase().contains(q))
                    .toList();
                if (matches.isEmpty) {
                  return const Center(child: Text('No items match your search.'));
                }
                return ListView(padding: const EdgeInsets.all(12), children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  for (final m in matches) _row(m as Map),
                  const SizedBox(height: 80),
                ]);
              }
              final byCat = <String, List<Map>>{};
              for (final it in items) {
                final m = it as Map;
                (byCat['${m['category'] ?? 'Menu'}'] ??= []).add(m);
              }
              final cats = byCat.keys.toList()..sort();
              return ListView(padding: const EdgeInsets.all(12), children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                for (final cat in cats) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
                    child: Text(cat.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                          color: AppColors.copperHi,
                        )),
                  ),
                  for (final m in byCat[cat]!) _row(m),
                ],
                const SizedBox(height: 80),
              ]);
            },
          ),
        ),
      ]),
      bottomNavigationBar: _count == 0
          ? null
          : Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 8,
                bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (!widget.isDineIn) ...[
                  TextField(
                    controller: _custCtrl,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.person_outline),
                      hintText: 'Customer name (optional)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: mobile10Formatters(),
                    maxLength: 10,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.phone_outlined),
                      hintText: '10-digit mobile (optional)',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      counterText: '',
                      errorText: _phoneError,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (widget.isDelivery) ...[
                    TextField(
                      controller: _addrCtrl,
                      minLines: 1,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.location_on_outlined),
                        hintText: 'Delivery address',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
                TextField(
                  controller: _noteCtrl,
                  minLines: 1,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.sticky_note_2_outlined),
                    hintText: 'Note for the kitchen (e.g. no onions)…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _sending || _phoneError != null ? null : _send,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_sending
                          ? 'Sending…'
                          : 'Send order · $_count item${_count > 1 ? 's' : ''} · ₹${_total.toStringAsFixed(2)}'),
                    ),
                  ),
                ),
              ]),
            ),
    );
  }

  Future<void> _editItemNote(String id, String name) async {
    final ctrl = TextEditingController(text: _itemNotes[id] ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Note for $name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'e.g. no onions, extra spicy…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (note == null) return;
    setState(() {
      if (note.isEmpty) {
        _itemNotes.remove(id);
      } else {
        _itemNotes[id] = note;
      }
    });
  }

  Widget _row(Map m) {
    final id = '${m['id']}';
    final qty = _cart[id] ?? 0;
    final note = (_itemNotes[id] ?? '').trim();
    final held = _itemHold.contains(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ForkCard(
        padding: const EdgeInsets.all(12),
        selected: qty > 0,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m['name']}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('₹${_price(id).toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
            ),
            qty > 0
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: Icon(Icons.front_hand_outlined,
                          size: 20, color: held ? AppColors.warning : AppColors.textTertiary),
                      tooltip: held ? 'Course held — tap to release' : 'Hold course (fire later from the KDS)',
                      onPressed: () => setState(() {
                        if (!_itemHold.remove(id)) _itemHold.add(id);
                      }),
                    ),
                    IconButton(
                      icon: Icon(Icons.sticky_note_2_outlined,
                          size: 20, color: note.isNotEmpty ? AppColors.copperHi : AppColors.textTertiary),
                      tooltip: note.isNotEmpty ? 'Edit note' : 'Add note',
                      onPressed: () => _editItemNote(id, '${m['name']}'),
                    ),
                    IconButton(
                        icon: const Icon(Icons.remove_circle_outline, color: AppColors.textSecondary),
                        onPressed: () => _setQty(id, -1)),
                    Text('$qty',
                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    IconButton(
                        icon: Icon(Icons.add_circle_outline, color: AppColors.copperHi),
                        onPressed: () => _setQty(id, 1)),
                  ])
                : FilledButton.tonal(onPressed: () => _setQty(id, 1), child: const Text('Add')),
          ]),
          if (qty > 0 && (note.isNotEmpty || held))
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
              child: Row(children: [
                if (held) ...[
                  const StatusChip(label: 'HOLD', color: AppColors.warning, dense: true),
                  const SizedBox(width: 8),
                ],
                if (note.isNotEmpty) ...[
                  const Icon(Icons.sticky_note_2_outlined, size: 14, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(note,
                          style: const TextStyle(
                              fontSize: 12, fontStyle: FontStyle.italic, color: AppColors.textSecondary))),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}
