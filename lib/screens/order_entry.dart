import 'dart:async';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/role_scope.dart';
import '../services/outbox.dart';
import '../services/phone_validation.dart';
import '../services/rest_client.dart';
import '../ui/theme/app_colors.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/skeleton.dart';
import '../ui/widgets/status_chip.dart';
import '../widgets/async_view.dart';
import '../widgets/table_bill.dart';

/// 6.8 — the most of the order pad's body its header (running-bill strip,
/// search, the order's fields and "Send order") may take.
///
/// The header sits at the TOP now, above the menu, so on a short screen (a phone
/// with the keyboard up, or a takeaway with its three customer fields) it must
/// leave the menu room to scroll. Past this share the header's fields scroll
/// inside it, and the Send button itself never does — it is always on screen.
const double _kHeaderMaxShare = 0.55;

/// Staff POS order entry for a table: pick menu items into a cart and send the
/// order. The order is attributed to the signed-in employee (for APC) and
/// appends to the table's single consolidated bill on the backend.
class OrderEntryScreen extends StatefulWidget {
  final RestClient rest;
  // null for takeaway/delivery (a virtual table is provisioned server-side).
  final String? tableName;
  // 'dine_in' (default), 'takeaway', or 'delivery'.
  final String orderType;

  /// ITEM 16 / CONSTRAINT C: THE TABLE IS NOT OCCUPIED YET, AND SENDING THIS
  /// ORDER IS WHAT WILL OCCUPY IT.
  ///
  /// Set only by the table sheet, only for a reader who has no seating control
  /// (a waiter), and only on a table that is currently free. Everybody else
  /// still seats first and this stays false, so their flow is byte-for-byte the
  /// one that shipped.
  ///
  /// WHY IT LIVES AT SEND RATHER THAN AT OPEN. "Occupancy follows the order"
  /// means the table lights up because an order exists, not because a screen was
  /// opened: a waiter who opens the pad and walks away leaves the table FREE,
  /// where the old seat-first flow left it occupied and empty until somebody
  /// noticed. It also keeps the covers question — which APC divides by, and
  /// which nothing else can supply — at the one moment there is a real party to
  /// count.
  final bool occupyOnSend;

  const OrderEntryScreen({
    super.key,
    required this.rest,
    this.tableName,
    this.orderType = 'dine_in',
    this.occupyOnSend = false,
  });

  bool get isDineIn => orderType == 'dine_in';
  bool get isDelivery => orderType == 'delivery';

  @override
  State<OrderEntryScreen> createState() => _OrderEntryScreenState();
}

class _OrderEntryScreenState extends State<OrderEntryScreen> with CachePrimedScreen {
  // The menu, held as plain state (not a FutureBuilder) so the boot-time cache
  // prime can paint a saved copy instantly and the network refresh can land in
  // place without ever swapping the list for the skeleton.
  List<dynamic>? _menuItems;
  String? _menuError;
  final Map<String, int> _cart = {};
  final Map<String, String> _itemNotes = {}; // per-item kitchen note (by menu id)
  final Set<String> _itemHold = {}; // held courses (fired later from the KDS)
  final Map<String, Map> _itemsById = {};
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _custCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _addrCtrl = TextEditingController();
  // Owned by the State, not by _askCovers, and that is a bug fix rather than a
  // style: `showDialog` completes the moment the route is popped, but the
  // dialog's TextField is still rebuilt while the barrier fades out — so a
  // controller disposed on the line after the await is used after disposal, and
  // the send that follows (which rebuilds this screen) is what makes it certain.
  final TextEditingController _coversCtrl = TextEditingController(text: '2');
  // 6.8 — the menu list's scroll position and the header above it, so the list
  // can be held still when the note and Send button appear or go (see [_setQty]).
  final ScrollController _menuScroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  String _query = '';
  bool _sending = false;
  String? _error;
  // What this table is ALREADY running at (its active orders merged, covers,
  // APC vs target). Dine-in only — a takeaway has no table to be per-head about.
  // Null until it loads, and stays null when the table has no open bill yet.
  Map<String, dynamic>? _tableBill;

  /// Whose order this is. Read once from the session rather than passed in, so
  /// every entry point into this screen (the table sheet, a takeaway, a
  /// delivery) is scoped without any of them having to remember to be.
  Profile? get _profile => widget.rest.auth.profile;

  /// ITEM 19 ON THE ORDER PAD. False for a waiter, and it takes out the running
  /// bill / APC strip at the top and the rupee total on the Send button.
  ///
  /// IT DELIBERATELY LEAVES THE MENU PRICES ALONE. That list is the card in the
  /// guest's hands: a waiter who cannot answer "how much is the paneer tikka"
  /// cannot take the order this screen exists to take. Hiding what a dish costs
  /// is not hiding the restaurant's money, it is hiding the menu.
  bool get _showsMoney => _profile == null || RoleScope.showsMoney(_profile!);

  /// Whether THIS send is the one that occupies the table. Dine-in only: a
  /// takeaway has no table to occupy, and its virtual table is provisioned
  /// server-side.
  bool get _occupyOnSend =>
      widget.occupyOnSend && widget.isDineIn && (widget.tableName ?? '').trim().isNotEmpty;

  /// The covers dialog, deliberately worded as a question about the party rather
  /// than as an instruction to seat them: this is the send button's follow-up,
  /// not a seating step wearing a different label.
  Future<int?> _askCovers() async {
    _coversCtrl.text = '2';
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How many guests at this table?'),
        content: TextField(
          controller: _coversCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Number of guests'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(_coversCtrl.text.trim()) ?? 1),
            child: const Text('Send order'),
          ),
        ],
      ),
    );
    return n == null ? null : (n < 1 ? 1 : n);
  }

  @override
  void initState() {
    super.initState();
    // _loadMenu is naturally silent while items are on screen (the skeleton is
    // simply "_menuItems == null"), so refresh and fallback are the same call.
    unawaited(primeFromCache(
      fetch: () => widget.rest.getList('/menu'),
      apply: _applyMenu,
      refresh: _loadMenu,
      fallback: _loadMenu,
    ));
    // The running bill is live money — deliberately never primed from a saved
    // copy: a stale APC strip could steer the waiter's upsell the wrong way.
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
    _coversCtrl.dispose();
    _menuScroll.dispose();
    super.dispose();
  }

  /// Field assignment only — shared by the cache prime and the network load.
  void _applyMenu(List<dynamic> items) {
    _itemsById.clear();
    for (final it in items) {
      final m = it as Map;
      _itemsById['${m['id']}'] = m;
    }
    _menuItems = items;
    _menuError = null;
  }

  Future<void> _loadMenu() async {
    final gen = bumpCacheGen();
    try {
      final items = await widget.rest.getList('/menu');
      if (!mounted || !cacheGenIs(gen)) return;
      setState(() {
        _applyMenu(items);
        markCacheLive();
      });
    } catch (e) {
      if (!mounted || !cacheGenIs(gen)) return;
      // A saved menu already on screen survives a failed refresh — the waiter
      // keeps taking the order behind the offline pill.
      if (_menuItems != null) {
        setState(markCacheOffline);
        return;
      }
      setState(() => _menuError = '$e');
    }
  }

  // Takeaway/delivery contact number. Optional, but anything typed must be a
  // real 10-digit mobile — the same rule the backend enforces on
  // POST /orders/takeaway, so Send never fails on a format the form allowed.
  String? get _phoneError => widget.isDineIn ? null : validateOptionalMobile10(_phoneCtrl.text);

  double _price(String id) => (_itemsById[id]?['price'] as num?)?.toDouble() ?? 0;
  double get _total => _cart.entries.fold(0.0, (s, e) => s + _price(e.key) * e.value);
  int get _count => _cart.values.fold(0, (s, q) => s + q);

  void _setQty(String id, int delta) {
    // 6.8 — HOLD THE MENU STILL UNDER THE WAITER'S THUMB. The note and the Send
    // button sit ABOVE the menu and only exist while the cart does, so the first
    // "Add" pushes the whole list down by their height and emptying the cart
    // pulls it back up — and the next tap lands on the wrong dish. Scrolling the
    // list by exactly how much the header grew (or shrank) keeps every row where
    // it was.
    final wasEmpty = _count == 0;
    final headerBefore = _headerKey.currentContext?.size?.height ?? 0;
    setState(() {
      final q = (_cart[id] ?? 0) + delta;
      if (q <= 0) {
        _cart.remove(id);
        _itemHold.remove(id);
      } else {
        _cart[id] = q;
      }
    });
    if (wasEmpty != (_count == 0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_menuScroll.hasClients) return;
        final shift = (_headerKey.currentContext?.size?.height ?? 0) - headerBefore;
        final pos = _menuScroll.position;
        _menuScroll.jumpTo((pos.pixels + shift).clamp(pos.minScrollExtent, pos.maxScrollExtent));
      });
    }
  }

  Future<void> _send() async {
    if (_cart.isEmpty) return;
    // Block the send rather than letting the server reject it.
    if (_phoneError != null) {
      setState(() => _error = _phoneError);
      return;
    }
    // COVERS BEFORE ANYTHING IS SENT, and before the sending flag is raised —
    // a cancelled dialog must leave the pad exactly as it was found.
    //
    // Covers are asked here for one reason: APC is the bill divided by the
    // covers counted ONCE PER SEATING, and no other write in this flow can
    // supply that number. Defaulting it to 1 would not be "no seating step", it
    // would be a table of four silently recorded as one cover — an APC four
    // times too high, in the analytics, in the MIS reports and in the simulator
    // baseline. So the seating is still RECORDED; it stopped being a button a
    // waiter presses before the guests have ordered.
    int? covers;
    if (_occupyOnSend) {
      covers = await _askCovers();
      if (covers == null || !mounted) return;
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
      if (_occupyOnSend && covers != null) {
        // OCCUPY FIRST, ORDER SECOND, and the order is load-bearing rather than
        // stylistic: the TableSessions row is written by a trigger on the
        // free -> occupied transition, and every reader that ties money to a
        // seating (staff APC, target APC, the cover-size report) matches a bill
        // to the session whose `seated_at <= bill.created_at`. Send the order
        // first and its bill predates the seating it belongs to, so it is
        // attributed to the PREVIOUS party or to none at all.
        try {
          await widget.rest.post('/occupy-table', {'table_name': widget.tableName, 'num_covers': covers});
        } on OfflineQueued catch (_) {
          // Queued, not lost — and queued AHEAD of the order below, which the
          // outbox replays in the order it was written. The kitchen ticket must
          // not be held hostage to the seating write.
        }
      }
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
    } on OfflineQueued catch (queued) {
      // The order is SAVED, not SENT — and the difference has to survive this
      // screen. Two things follow from that, and both matter:
      //
      //  * the screen closes exactly as a sent order closes it. If it stayed
      //    open with the cart live, the obvious next move is to tap Send again,
      //    and that queues a SECOND copy under a second key — a duplicate the
      //    idempotency contract cannot collapse, because they really are two
      //    different requests. Closing is what makes the queued order singular.
      //  * the message says what actually happened. Not "Order sent", which is
      //    the lie; the kitchen has not seen this and will not until the line
      //    is back, and the table's own card on the floor plan now carries a
      //    "Not sent yet" chip that says so at a glance.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.card,
            duration: const Duration(seconds: 6),
            content: Text(
              'Saved on this device — ${queued.what}. '
              'The kitchen has NOT seen it yet; it sends when the connection returns.',
            ),
          ),
        );
        Navigator.pop(context, true);
      }
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
      body: cacheStaleOverlay(LayoutBuilder(builder: (context, box) => Column(children: [
        // 6.8 — "SEND ORDER" DIRECTLY UNDER THE SEARCH, NOT AT THE FOOT OF THE
        // SCREEN. It used to be the Scaffold's bottomNavigationBar, which put the
        // one control that ends the flow at the very bottom edge of a phone —
        // first under the Android nav bar, then (once lifted clear of it) still
        // the furthest thing on the page from where the waiter's eyes are.
        //
        // Now the running-bill strip, the search, the order's fields and the
        // Send button are one header above the menu. It is sticky by
        // construction: a sibling of the menu list, not a row inside it, so the
        // menu scrolls beneath it and it never moves. And the old inset
        // arithmetic is no longer needed rather than merely dropped: the
        // Scaffold already shrinks its body for the keyboard, and the nav bar is
        // at the bottom edge, so nothing can sit on top of a control at the top.
        //
        // On a short body (a phone with the keyboard up, a takeaway's three
        // customer fields) the header stops at [_kHeaderMaxShare]; past that its
        // fields scroll inside it, and the Send button — outside that scroll —
        // stays on screen. Still hidden with an empty cart, exactly as before.
        ConstrainedBox(
          key: _headerKey,
          constraints: BoxConstraints(maxHeight: box.maxHeight * _kHeaderMaxShare),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // What the table is already running at — visible while the order is
                  // being built, so the waiter can see the per-head gap in time to close
                  // it. Tapping opens the full item-by-item bill.
                  if (widget.isDineIn && _tableBill != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: TableApcStrip(
                        bill: _tableBill!,
                        profile: _profile,
                        pendingTotal: _total,
                        onTap: () => showTableBillSheet(
                          context,
                          rest: widget.rest,
                          tableName: widget.tableName ?? '',
                          profile: _profile,
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
                  if (_count > 0) _orderFields(),
                ]),
              ),
            ),
            if (_count > 0) _sendButton(),
          ]),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_menuError != null) {
                return Center(child: Text('Failed to load menu: $_menuError'));
              }
              final items = _menuItems;
              if (items == null) {
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
              // THE ANDROID NAVIGATION BAR IS NOT THE KEYBOARD — kept from the fix
              // that first lifted "Send order" clear of it. Nothing is pinned to
              // the bottom edge any more (6.8), but the menu's last dish still is
              // the bottom edge, so the list ends `padding.bottom` (the nav bar;
              // zero while the keyboard covers it) above the physical bottom.
              final menuPadding = EdgeInsets.fromLTRB(12, 12, 12, 12 + MediaQuery.of(context).padding.bottom);
              final q = _query.trim().toLowerCase();
              if (q.isNotEmpty) {
                // Flat, filtered list across all categories while searching.
                final matches = items
                    .where((it) => '${(it as Map)['name'] ?? ''}'.toLowerCase().contains(q))
                    .toList();
                if (matches.isEmpty) {
                  return const Center(child: Text('No items match your search.'));
                }
                return ListView(controller: _menuScroll, padding: menuPadding, children: [
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
              return ListView(controller: _menuScroll, padding: menuPadding, children: [
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
      ]))),
    );
  }

  /// 6.8 — the order's own fields, which ride in the header above the Send
  /// button: a takeaway's customer name / phone / address, and the kitchen note.
  Widget _orderFields() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
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
        ]),
      );

  /// 6.8 — "Send order", directly under the order's fields and outside the
  /// header's scroll, so it is always on screen while the cart has anything in it.
  Widget _sendButton() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('order-send'),
            onPressed: _sending || _phoneError != null ? null : _send,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_sending
                  ? 'Sending…'
                  : _showsMoney
                      ? 'Send order · $_count item${_count > 1 ? 's' : ''} · ₹${_total.toStringAsFixed(2)}'
                      : 'Send order · $_count item${_count > 1 ? 's' : ''}'),
            ),
          ),
        ),
      );

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
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('₹${_price(id).toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
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
                        icon: Icon(Icons.remove_circle_outline, color: AppColors.textSecondary),
                        onPressed: () => _setQty(id, -1)),
                    Text('$qty',
                        style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
                  StatusChip(label: 'HOLD', color: AppColors.warning, dense: true),
                  const SizedBox(width: 8),
                ],
                if (note.isNotEmpty) ...[
                  Icon(Icons.sticky_note_2_outlined, size: 14, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(note,
                          style: TextStyle(
                              fontSize: 12, fontStyle: FontStyle.italic, color: AppColors.textSecondary))),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}
