import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/order_draft.dart';
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
  // ITEM 5 — the name each carted dish had when it was added, so a dish a menu
  // refresh drops can still be named in the refusal and in the review.
  final Map<String, String> _cartNames = {};
  // ITEM 5 — bumped on every change to the draft (quantity, note, hold, and a
  // menu refresh that can take a carted dish off the menu). The review sheet is
  // its own route and does not rebuild with this screen, so it listens to this
  // and redraws from the pad's ONE draft — never from a copy of it.
  final ValueNotifier<int> _draftRev = ValueNotifier<int>(0);
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
    _draftRev.dispose();
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
      _draftRev.value++;
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
  double get _total => orderDraftTotal(_draft);
  int get _count => _cart.values.fold(0, (s, q) => s + q);

  /// ITEM 5 — the unsent order as lines: what the review reads back to the guest
  /// and, through [orderDraftPayload], exactly what [_send] posts.
  List<OrderDraftLine> get _draft => orderDraftLines(
        cart: _cart,
        notes: _itemNotes,
        held: _itemHold,
        itemsById: _itemsById,
        knownNames: _cartNames,
      );

  void _toggleHold(String id) {
    setState(() {
      if (!_itemHold.remove(id)) _itemHold.add(id);
    });
    _draftRev.value++;
  }

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
        _cartNames.remove(id);
        // The refusal below named a dish the menu dropped; it is out of the cart.
        if (!_itemsById.containsKey(id)) _error = null;
      } else {
        _cart[id] = q;
        final name = _itemsById[id]?['name'];
        if (name != null) _cartNames[id] = '$name';
      }
    });
    _draftRev.value++;
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
    // ITEM 5 — THE LINES ARE BUILT HERE, FIRST, before a dialog is asked or the
    // sending flag is raised. They used to be built after `_sending = true` with
    // `_itemsById[id]!`, outside the try: a menu refresh that dropped a carted
    // dish threw there and left the button on "Sending…" for good.
    final lines = _draft;
    // Block the send rather than letting the server reject it.
    final blocked = orderDraftBlock(lines, phoneError: _phoneError);
    if (blocked != null) {
      setState(() => _error = blocked);
      // A dish the menu dropped has no row left on the menu to remove it from;
      // the review is the one place it still shows.
      if (_phoneError == null) unawaited(_openReview());
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
    final total = orderDraftTotal(lines);
    final base = <String, dynamic>{
      'items': orderDraftPayload(lines),
      'subtotal': total,
      'total': total,
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
            if (_count > 0) _sendBar(),
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
  ///
  /// ITEM 5 — off while a send is out, for the menu rows' reason (see [_row]):
  /// [_send] reads them once, before it posts, so a word typed into the kitchen
  /// note during "Sending…" would be shown on the pad and never reach the ticket.
  Widget _orderFields() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!widget.isDineIn) ...[
              TextField(
                controller: _custCtrl,
                enabled: !_sending,
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
                enabled: !_sending,
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
                  enabled: !_sending,
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
              enabled: !_sending,
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
  ///
  /// ITEM 5 — and "View order" beside it, IN THE SAME ROW, so the header is no
  /// taller than 6.8 measured it and the menu under the waiter's thumb does not
  /// move. The review is optional: "Send order" is still the one-tap send it
  /// shipped as. The View label never says "Send order" — that phrase is how the
  /// pad's send is found, and it must stay unique on the screen.
  ///
  /// The Send label is scaled down, never cut, on a phone: "₹1,278.00" losing
  /// its last digits to an ellipsis is a different figure, not a shorter one.
  Widget _sendBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          OutlinedButton.icon(
            key: const ValueKey('order-review'),
            onPressed: _sending ? null : _openReview,
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('View order'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              key: const ValueKey('order-send'),
              onPressed: _sending || _phoneError != null ? null : _send,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(_sending
                      ? 'Sending…'
                      : _showsMoney
                          ? 'Send order · $_count item${_count > 1 ? 's' : ''} · ₹${_total.toStringAsFixed(2)}'
                          : 'Send order · $_count item${_count > 1 ? 's' : ''}'),
                ),
              ),
            ),
          ),
        ]),
      );

  /// ITEM 5 — "View order": the unsent draft, to be read back to the guest.
  ///
  /// THE SHEET NEVER SENDS. It answers true ("Send to kitchen") or false, and the
  /// send happens HERE, after it has closed. [_send] ends by popping the pad off
  /// its own context; run with the sheet still on top, that pop takes the SHEET
  /// instead, the pad stays open with the cart live, and the obvious next tap
  /// posts the same order again under a new idempotency key — a second order the
  /// server cannot collapse, on a bill that is the sum of its orders. Sending
  /// after the close also leaves the covers question, and its "cancel leaves the
  /// pad as found", exactly as they were.
  Future<void> _openReview() async {
    if (_count == 0) return;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _OrderReviewSheet(
        revision: _draftRev,
        title: widget.isDineIn
            ? '${widget.tableName}'
            : widget.isDelivery
                ? 'Delivery'
                : 'Takeaway',
        draft: () => _draft,
        showsMoney: _showsMoney,
        kitchenNote: _noteCtrl.text.trim(),
        customer: widget.isDineIn ? '' : _custCtrl.text.trim(),
        phone: widget.isDineIn ? '' : _phoneCtrl.text.trim(),
        address: widget.isDelivery ? _addrCtrl.text.trim() : '',
        phoneError: _phoneError,
        onQty: _setQty,
        onNote: _editItemNote,
        onHold: _toggleHold,
      ),
    );
    if (go == true && mounted) await _send();
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
    _draftRev.value++;
  }

  Widget _row(Map m) {
    final id = '${m['id']}';
    final qty = _cart[id] ?? 0;
    final note = (_itemNotes[id] ?? '').trim();
    final held = _itemHold.contains(id);
    // ITEM 5 — NOTHING ON THE MENU CHANGES THE ORDER WHILE IT IS ON ITS WAY.
    // [_send] takes its lines before it posts and closes the pad when the post
    // lands, so a dish added (or a quantity, hold or note changed) while the
    // button reads "Sending…" was drawn on the pad, counted, and never sent —
    // and the pad closed on it without a word. The waiter believed it had gone
    // to the kitchen. Every control on the row is off until the send settles; a
    // send that fails turns them back on with the cart as it was.
    final locked = _sending;
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
                      onPressed: locked ? null : () => _toggleHold(id),
                    ),
                    IconButton(
                      icon: Icon(Icons.sticky_note_2_outlined,
                          size: 20, color: note.isNotEmpty ? AppColors.copperHi : AppColors.textTertiary),
                      tooltip: note.isNotEmpty ? 'Edit note' : 'Add note',
                      onPressed: locked ? null : () => _editItemNote(id, '${m['name']}'),
                    ),
                    IconButton(
                        icon: Icon(Icons.remove_circle_outline, color: AppColors.textSecondary),
                        onPressed: locked ? null : () => _setQty(id, -1)),
                    Text('$qty',
                        style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    IconButton(
                        icon: Icon(Icons.add_circle_outline, color: AppColors.copperHi),
                        onPressed: locked ? null : () => _setQty(id, 1)),
                  ])
                : FilledButton.tonal(onPressed: locked ? null : () => _setQty(id, 1), child: const Text('Add')),
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

/// ITEM 5 — "Review order": the unsent draft, read back to the guest before it
/// reaches the kitchen.
///
/// ONLY THE DRAFT. What the table already has is on the running-bill sheet and
/// the KOT blocks; mixing sent and unsent lines here would have the waiter read
/// the guest dishes that are already cooking as if they were new.
///
/// EDITS GO THROUGH THE PAD'S OWN HANDLERS ([onQty], [onNote], [onHold]), and
/// the list is redrawn from the pad's one draft whenever [revision] ticks. A
/// private copy of the cart in here would drift from the pad, and the pad's
/// handlers carry rules a copy would lose (a course's hold goes when its dish
/// does; the menu under the thumb is held still).
///
/// ITEM 19 / C4 — this is the "list of ordered dishes" the waiter rule names, so
/// for a waiter every amount goes, per line and in total. The dish, quantity,
/// hold and note are the ticket and all stay.
class _OrderReviewSheet extends StatelessWidget {
  const _OrderReviewSheet({
    required this.revision,
    required this.title,
    required this.draft,
    required this.showsMoney,
    required this.kitchenNote,
    required this.customer,
    required this.phone,
    required this.address,
    required this.phoneError,
    required this.onQty,
    required this.onNote,
    required this.onHold,
  });

  final ValueListenable<int> revision;
  final String title;
  final List<OrderDraftLine> Function() draft;
  final bool showsMoney;
  final String kitchenNote;
  final String customer;
  final String phone;
  final String address;
  final String? phoneError;
  final void Function(String id, int delta) onQty;
  final Future<void> Function(String id, String name) onNote;
  final void Function(String id) onHold;

  /// A quantity change, and the sheet's own exit when it empties the order —
  /// there is nothing left to read back or send.
  void _change(BuildContext context, String id, int delta) {
    onQty(id, delta);
    if (draft().isEmpty) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        key: const ValueKey('order-review-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, _, _) {
            final lines = draft();
            final blocked = orderDraftBlock(lines, phoneError: phoneError);
            final summary = showsMoney
                ? '${orderDraftSummary(lines)} · ₹${orderDraftTotal(lines).toStringAsFixed(2)}'
                : orderDraftSummary(lines);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Review order · $title', style: text.titleLarge),
                const SizedBox(height: 4),
                Text('Read it back to the guest, then send.', style: text.bodySmall),
                const SizedBox(height: 12),
                Text(summary, key: const ValueKey('order-review-summary'), style: text.titleSmall),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final l in lines) _line(context, l),
                        if (kitchenNote.isNotEmpty) _detail(context, Icons.sticky_note_2_outlined, kitchenNote),
                        if (customer.isNotEmpty) _detail(context, Icons.person_outline, customer),
                        if (phone.isNotEmpty) _detail(context, Icons.phone_outlined, phone),
                        if (address.isNotEmpty) _detail(context, Icons.location_on_outlined, address),
                      ],
                    ),
                  ),
                ),
                if (blocked != null && lines.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(blocked,
                        key: const ValueKey('order-review-blocked'),
                        style: text.bodySmall!.copyWith(color: AppColors.danger)),
                  ),
                const SizedBox(height: 12),
                // Scaled down, never cut, however narrow the phone or large its
                // text: both of these are the only two ways out of the sheet.
                Row(children: [
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('order-review-back'),
                      onPressed: () => Navigator.pop(context, false),
                      child: const FittedBox(fit: BoxFit.scaleDown, child: Text('Back to menu')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: const ValueKey('order-review-send'),
                      onPressed: blocked == null ? () => Navigator.pop(context, true) : null,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text('Send to kitchen')),
                      ),
                    ),
                  ),
                ]),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _line(BuildContext context, OrderDraftLine l) {
    final text = Theme.of(context).textTheme;
    final amount = l.amount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ForkCard(
        inset: true,
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 4),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text('${l.quantity} × ${l.name}',
                  style: text.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (showsMoney && amount != null)
              Padding(
                padding: const EdgeInsets.only(left: 10, right: 8),
                child: Text('₹${amount.toStringAsFixed(2)}', style: text.titleSmall),
              ),
          ]),
          if (!l.onMenu || l.held || l.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (!l.onMenu) StatusChip(label: 'No longer on the menu', color: AppColors.danger, dense: true),
                if (l.held) StatusChip(label: 'HOLD', color: AppColors.warning, dense: true),
                if (l.note.isNotEmpty)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.sticky_note_2_outlined, size: 14, color: AppColors.textTertiary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(l.note,
                          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: AppColors.textSecondary)),
                    ),
                  ]),
              ]),
            ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            // A dish the menu no longer carries can only leave the order: it has
            // no price to add another at, and nothing to hold or annotate for.
            if (l.onMenu) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.front_hand_outlined,
                    size: 20, color: l.held ? AppColors.warning : AppColors.textTertiary),
                tooltip: l.held ? 'Course held — tap to release' : 'Hold course (fire later from the KDS)',
                onPressed: () => onHold(l.menuId),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.sticky_note_2_outlined,
                    size: 20, color: l.note.isNotEmpty ? AppColors.copperHi : AppColors.textTertiary),
                tooltip: l.note.isNotEmpty ? 'Edit note' : 'Add note',
                onPressed: () => onNote(l.menuId, l.name),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.remove_circle_outline, color: AppColors.textSecondary),
                tooltip: 'One fewer',
                onPressed: () => _change(context, l.menuId, -1),
              ),
              Text('${l.quantity}', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add_circle_outline, color: AppColors.copperHi),
                tooltip: 'One more',
                onPressed: () => onQty(l.menuId, 1),
              ),
            ],
            IconButton(
              key: ValueKey('order-review-remove-${l.menuId}'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline, color: AppColors.textSecondary),
              tooltip: 'Remove from order',
              onPressed: () => _change(context, l.menuId, -l.quantity),
            ),
          ]),
        ]),
      ),
    );
  }

  /// One of the order's own fields, read-only: the kitchen note, and a
  /// takeaway's customer, phone and address.
  Widget _detail(BuildContext context, IconData icon, String value) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: AppColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}
