// REQUIREMENTS 1.8 AND 1.3 — the table preview's orders, one block per KOT, and
// the "Cancel KOT" on each block.
//
// A PART of modules.dart for the reason reports.dart and mis_capture.dart are:
// the KOT number is read through the same `_kotNos` the order tile and the
// kitchen card read it through, and the cancel is the same `_cancelOrder` every
// other cancel in the app goes through. A second library would have to copy
// both, and a copied cancel is how one path ends up without the reason prompt.
part of 'modules.dart';

/// "Add Orders" — the action PATCH /orders/:id/status is gated on server side
/// (routes/orders.ts), and so the one a plain cancel travels under. Written down
/// here only as the fallback for [_mayCancelKot]; the server re-checks it.
const String _permAddOrders = '4ad474d4-5230-449c-874f-6a238b833bca';

/// One block of the table preview: a KOT and the lines that were on it.
///
/// [order] is the order row the KOT numbers belong to, and it is null ONLY for
/// the trailing group — the lines whose order carries no KOT number (not sent to
/// the kitchen yet, printed before migration 043, or a backend that does not
/// send `kot_nos`). That group is not a ticket, so it has no cancel.
class TableKotGroup {
  const TableKotGroup({
    required this.kotNos,
    required this.placedAt,
    required this.orderIds,
    required this.items,
    this.order,
  });

  /// The KOT numbers on this block, in allocation order. Empty for the trailing
  /// group.
  final List<int> kotNos;

  /// The server's `created_at` of the (earliest) order in this block, or ''.
  final String placedAt;

  /// The orders whose lines are in this block — exactly one for a KOT block.
  final List<String> orderIds;

  /// The lines, normalised to the `name` / `quantity` / `price` / `note` keys
  /// the bill's own item rows use, so one row widget draws both.
  final List<Map<String, dynamic>> items;

  final Map? order;

  bool get numbered => kotNos.isNotEmpty;

  /// "KOT 5" / "KOTs 5, 7" / "No KOT number".
  String get label => !numbered
      ? 'No KOT number'
      : kotNos.length == 1
          ? 'KOT ${kotNos.first}'
          : 'KOTs ${kotNos.join(', ')}';

  /// "KOT 5 · 14:57" — the header staff match against the docket on the pass.
  /// The time is the restaurant's wall clock (see [RestaurantTime]); a block
  /// whose order carries no readable timestamp shows the number alone.
  ///
  /// CLIENT ITEM 4: a ticket moved here from another table says so — "KOT 65 ·
  /// 16:27 · from 12" — which is what the pass's correction docket says too.
  String get header {
    final at = placedAt.isEmpty || RestaurantTime.wallOf(placedAt) == null
        ? ''
        : RestaurantTime.clock(placedAt);
    final from = order == null ? null : movedFromLabel(order!);
    return [label, if (at.isNotEmpty) at, ?from].join(' · ');
  }
}

/// 1.8 — SPLIT A TABLE'S RUNNING BILL INTO ITS KOTs.
///
/// [bill] is GET /bill-for-table, [orders] is GET /orders. Pure, so the whole
/// rule is testable without a screen.
///
/// WHICH ORDERS: exactly the bill's own `order_ids`, in the order the server
/// lists them — `created_at` ascending, the same order the bill merges its lines
/// in — so the blocks can never describe a different set of orders than the
/// Bill card under them adds up. Numbered blocks come first in that order; every
/// line whose order carries no KOT number goes into ONE trailing group.
///
/// ONE BLOCK PER ORDER, because that is the unit the backend attributes a KOT
/// number to (migration 043: an order's numbers are the distinct `kot_no` of its
/// own dockets) and the unit a cancel acts on. An order the kitchen was sent
/// twice ("KOTs 5, 7") is still one block, labelled with both numbers, because
/// nothing on the wire says which line was on which of the two.
///
/// RETURNS NULL — "draw the flat list as before" — when the grouping cannot be
/// complete: no `order_ids` (an older backend), or an order on the bill that the
/// orders feed does not carry (offline, or a feed that failed). A preview that
/// silently dropped the lines of a missing order would under-state the table,
/// which is worse than a preview that is not split.
List<TableKotGroup>? tableKotGroups(Map? bill, List? orders) {
  if (bill == null || orders == null) return null;
  final ids = _strList(bill['order_ids']);
  if (ids.isEmpty) return null;
  final byId = <String, Map>{};
  for (final o in orders) {
    if (o is Map && o['id'] != null) byId['${o['id']}'] = o;
  }
  if (ids.any((id) => !byId.containsKey(id))) return null;

  final numbered = <TableKotGroup>[];
  final looseIds = <String>[];
  final looseItems = <Map<String, dynamic>>[];
  var looseAt = '';
  for (final id in ids) {
    final o = byId[id]!;
    final nos = _kotNos(o);
    final at = _s(o, 'created_at', '');
    final lines = _kotOrderLines(o);
    if (nos.isEmpty) {
      looseIds.add(id);
      looseItems.addAll(lines);
      if (looseAt.isEmpty) looseAt = at;
    } else {
      numbered.add(TableKotGroup(kotNos: nos, placedAt: at, orderIds: [id], items: lines, order: o));
    }
  }
  return [
    ...numbered,
    if (looseIds.isNotEmpty)
      TableKotGroup(kotNos: const [], placedAt: looseAt, orderIds: looseIds, items: looseItems),
  ];
}

// An order row's lines. GET /orders sends them top-level as `items`; older rows
// (and the fakes that mirror them) nest them under `food`.
List<Map<String, dynamic>> _kotOrderLines(Map o) {
  final food = o['food'];
  final raw = o['items'] is List ? o['items'] as List : (food is Map && food['items'] is List ? food['items'] as List : const []);
  return [
    for (final it in raw.whereType<Map>())
      {
        ...Map<String, dynamic>.from(it),
        'name': _s(it, 'name', _s(it, 'item_name', 'Item')),
        'quantity': it['quantity'] ?? it['qty'] ?? 1,
        'price': it['price'] ?? 0,
        'note': _s(it, 'note', ''),
      },
  ];
}

/// 1.3 — MAY THIS PERSON CANCEL A KOT FROM THE TABLE PREVIEW (or pick
/// "Cancelled" for a ticketed order on the stage sheet).
///
/// CLIENT ITEM 3 (2026-09-17): "On the waiter dashboard, Cancel KOT option
/// should be removed." The server's `cancel_kot` answers it — false for a
/// waiter-only login, whatever it was granted, because every route that can
/// cancel a ticketed order now refuses one (`cancel_needs_senior`). Against a
/// backend older than the flag the answer is worked out the way it always was
/// (either of the two routes [_cancelOrder] chooses between: the strict void or
/// the plain cancel on "Add Orders"), less a waiter-only login.
///
/// A PENDING order's "Decline" does not ask this: it was never ticketed, and a
/// waiter keeps it.
bool _mayCancelKot(Profile p) => RoleScope.may(
      p,
      Capability.cancelKot,
      fallback: !RoleScope.isWaiterOnly(p) &&
          (_mayDo(p, Capability.voidOrder, _permVoidOrder) || _holdsAction(p, _permAddOrders)),
    );

/// One separated KOT block: the header (number, time, Cancel KOT) and its lines.
class _TableKotBlock extends StatelessWidget {
  const _TableKotBlock({required this.group, required this.itemRow, this.onCancel});

  final TableKotGroup group;
  final Widget Function(Map item) itemRow;

  /// Null hides "Cancel KOT" — the trailing group, or a reader who may not.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final key = group.numbered ? group.kotNos.first : 'none';
    return Container(
      key: ValueKey('table-kot-block-$key'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      decoration: BoxDecoration(
        borderRadius: AppRadius.cardAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Row(children: [
            Icon(group.numbered ? Icons.receipt_long_outlined : Icons.hourglass_empty,
                size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(group.header,
                  key: ValueKey('table-kot-header-$key'),
                  style: text.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (onCancel != null)
              ForkButton.ghost(
                key: ValueKey('table-kot-cancel-$key'),
                label: 'Cancel KOT',
                icon: Icons.cancel_outlined,
                dense: true,
                onPressed: onCancel,
              ),
          ]),
        ),
        ...group.items.map(itemRow),
      ]),
    );
  }
}
