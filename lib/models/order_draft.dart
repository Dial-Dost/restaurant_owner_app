/// THE ORDER PAD'S UNSENT DRAFT, AS ONE LIST — what "View order" reads back to
/// the guest and what "Send order" posts, built by the same function.
///
/// "There should be a view order button next to the send order button so that
/// the order can be viewed and repeated to the guest and only then can the
/// order be sent to the kitchen." Before this, the draft was three private
/// collections inside the pad (the quantities, the per-dish notes, the held
/// courses) and the only views of it were the highlighted menu rows — which a
/// typed search filters away — and the count on the Send button.
///
/// WHY ONE FUNCTION FOR BOTH. A review that is built separately from the send
/// is a second opinion about the same order, and the day they disagree the
/// waiter reads one order to the guest and the kitchen cooks another. So the
/// review sheet draws [orderDraftLines] and the send posts
/// [orderDraftPayload] of that SAME list; the payload is byte-for-byte the item
/// maps the pad sent before the review existed (test/order_review_sheet_test.dart
/// pins both).
///
/// A DISH THAT LEFT THE MENU IS KEPT, AND FLAGGED. A menu refresh can drop a
/// dish that is already in the cart. The old send read `_itemsById[id]!` for
/// it, threw outside its try, and left the button on "Sending…" for good. The
/// line is now built with `onMenu: false`, [orderDraftBlock] refuses the send
/// with a sentence that names it, and the review shows it so it can be removed.
/// It is never silently dropped: that would send a shorter order than the one
/// just read back to the guest.
///
/// PURE: no widgets, no network.
library;

/// One dish in the unsent order, in the order it was first added.
class OrderDraftLine {
  const OrderDraftLine({
    required this.menuId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.note,
    required this.held,
    required this.onMenu,
    this.menuName,
    this.menuPrice,
  });

  final String menuId;

  /// What the line is called on screen. The menu's own name while the dish is
  /// on the menu; the last name the pad saw for it once it is not.
  final String name;
  final int quantity;

  /// The menu price as the pad prices it (a missing figure is 0, exactly like
  /// the Send button's total), or null once the dish is off the menu.
  final double? unitPrice;

  /// Trimmed. Empty means no note.
  final String note;
  final bool held;
  final bool onMenu;

  /// The menu row's `name` and `price` values, untouched, for the payload.
  final Object? menuName;
  final Object? menuPrice;

  /// Unit price times quantity, or null when there is no price to multiply.
  double? get amount => unitPrice == null ? null : unitPrice! * quantity;
}

/// The draft as lines: one per carted dish, in cart insertion order, skipping
/// any quantity that is not a positive count.
///
/// [knownNames] is the name the pad last saw for each carted id, used only for
/// a dish the menu no longer carries — so the refusal can say WHICH dish.
List<OrderDraftLine> orderDraftLines({
  required Map<String, int> cart,
  required Map<String, String> notes,
  required Set<String> held,
  required Map<String, Map> itemsById,
  Map<String, String> knownNames = const {},
}) {
  final lines = <OrderDraftLine>[];
  for (final e in cart.entries) {
    if (e.value <= 0) continue;
    final m = itemsById[e.key];
    final note = (notes[e.key] ?? '').trim();
    lines.add(OrderDraftLine(
      menuId: e.key,
      name: m != null ? '${m['name']}' : (knownNames[e.key] ?? e.key),
      quantity: e.value,
      unitPrice: m == null ? null : ((m['price'] as num?)?.toDouble() ?? 0),
      note: note,
      held: held.contains(e.key),
      onMenu: m != null,
      menuName: m?['name'],
      menuPrice: m?['price'],
    ));
  }
  return lines;
}

/// The `items` array POST /orders and /orders/takeaway receive — the same maps,
/// keys and order the pad has always sent: id, name, price, quantity, a note
/// only when there is one, and `course_hold: true` only for a held course.
List<Map<String, dynamic>> orderDraftPayload(List<OrderDraftLine> lines) => [
      for (final l in lines)
        {
          'id': l.menuId,
          'name': l.menuName,
          'price': l.menuPrice,
          'quantity': l.quantity,
          if (l.note.isNotEmpty) 'note': l.note,
          // Course hold-and-fire: the kitchen fires held items on demand.
          if (l.held) 'course_hold': true,
        },
    ];

/// How many plates, across how many dishes.
int orderDraftItemCount(List<OrderDraftLine> lines) => lines.fold(0, (s, l) => s + l.quantity);

/// What the draft comes to at menu prices: the figure on the Send button, the
/// review's total, and the `subtotal`/`total` the send posts. Summed in cart
/// order from 0.0 with an off-menu dish counting 0 — the pad's own fold, term
/// for term — so the three can never differ by so much as a rounding.
double orderDraftTotal(List<OrderDraftLine> lines) => lines.fold(0.0, (s, l) => s + (l.amount ?? 0));

/// "4 items · 3 dishes" — the review's one-line read-out, worded exactly as the
/// web dashboard's (src/lib/order-draft.ts `draftSummary`).
String orderDraftSummary(List<OrderDraftLine> lines) {
  final items = orderDraftItemCount(lines);
  final dishes = lines.length;
  return '$items item${items == 1 ? '' : 's'} · $dishes dish${dishes == 1 ? '' : 'es'}';
}

/// Why this draft may not be sent yet, or null when it may.
///
/// The one rule both "Send order" and the review's "Send to kitchen" obey, so
/// neither button can send what the other would refuse. A bad phone number is
/// checked first, as the pad always has.
String? orderDraftBlock(List<OrderDraftLine> lines, {String? phoneError}) {
  if (lines.isEmpty) return 'Add a dish to send an order.';
  if (phoneError != null) return phoneError;
  for (final l in lines) {
    if (!l.onMenu) return '${l.name} is no longer on the menu — remove it to send';
  }
  return null;
}
