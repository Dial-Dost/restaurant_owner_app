// CLIENT ITEM 4 (2026-09-17) — "Right now there are no item names visible when
// an order is moved from one table to another. This needs to be visible and
// implemented correctly."
//
// WHAT THE APP USED TO SAY. The "Move an order" picker read "3 items · ₹1427.00
// / The kitchen has this one" — no dish, no KOT number, and with a single order
// no picker at all. The confirm said "Move this order to 15?". The snackbar said
// "Moved to 15. Correction docket KOT-65 is printing". A dish moved with "Move
// to another table" left its ticket reading "Guest · 0 item(s) · Cancelled",
// and nothing on the destination said where its food had come from.
//
// THE WORDS, ONCE. Every string a move puts on a screen is built here, and the
// web dashboard builds the same strings in src/lib/table-move.ts — the two
// suites pin the same sentences, so a restaurant running both is told the same
// thing about the same move. PURE: no Flutter, no network.
//
// NO MONEY. Nothing here reads a price: the picker is shown to whoever may move
// an order, and a waiter-only login is not shown what a ticket is worth.

String _text(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

int _qty(Object? v) {
  final n = num.tryParse('${v ?? 1}') ?? 1;
  final q = n.round();
  return q < 1 ? 1 : q;
}

/// "2 × Dal (Half)" — one dish as the table sheet already prints it. GET /orders
/// names the size `variation`; a raw stored line names it `variation_name`.
String moveDishLine(Map line) {
  final name = _text(line['name']).isEmpty ? _text(line['item_name']) : _text(line['name']);
  final size = _text(line['variation']).isEmpty ? _text(line['variation_name']) : _text(line['variation']);
  final label = size.isEmpty ? (name.isEmpty ? 'Item' : name) : '${name.isEmpty ? 'Item' : name} ($size)';
  return '${_qty(line['quantity'] ?? line['qty'])} × $label';
}

/// Every dish on an order row of GET /orders, in the ticket's order.
List<String> orderDishLines(Map order) {
  final food = order['food'];
  final raw = order['items'] is List
      ? order['items'] as List
      : (food is Map && food['items'] is List ? food['items'] as List : const []);
  return [for (final it in raw.whereType<Map>()) moveDishLine(it)];
}

/// "1 × A, 1 × B, 1 × C +2 more" — the dishes in one line. [max] is how many are
/// named before the rest are counted; null names them all.
String moveDishSummary(List<String> lines, {int? max = 3}) {
  if (lines.isEmpty) return '';
  if (max == null || lines.length <= max) return lines.join(', ');
  return '${lines.take(max).join(', ')} +${lines.length - max} more';
}

/// The KOT numbers on an order row, cleaned: positive, whole, de-duplicated.
List<int> moveKotNos(Map order) {
  final raw = order['kot_nos'];
  if (raw is! List) return const [];
  final out = <int>[];
  for (final v in raw) {
    final n = num.tryParse('$v');
    if (n == null || n <= 0) continue;
    final i = n.round();
    if (!out.contains(i)) out.add(i);
  }
  return out;
}

/// "KOT 65" / "KOTs 65, 66" — the handle the pass quotes — or "No KOT number",
/// the table sheet's own words for a ticket the server numbered nothing for.
/// Whether the kitchen HAS it is said separately (a barked ticket on a tenant
/// without numbering has no number and is still on the pass).
String moveOrderTitle(Map order) {
  final nos = moveKotNos(order);
  if (nos.isEmpty) return 'No KOT number';
  return '${nos.length == 1 ? 'KOT' : 'KOTs'} ${nos.join(', ')}';
}

/// "from 12" — where a moved ticket came from, or null when it never moved.
String? movedFromLabel(Map order) {
  final from = _text(order['moved_from']);
  return from.isEmpty ? null : 'from $from';
}

/// "Moved to 31: 1 × NOT YOUR PUCHKA" — what a dish move took OFF this ticket,
/// grouped by where it went ("…; to 32: 2 × Dal"). Null when nothing left it
/// by a move, which is every order written before 2.0.2.
String? movedAwayLine(Map order) {
  final raw = order['moved_items'];
  if (raw is! List || raw.isEmpty) return null;
  final byTable = <String, List<String>>{};
  for (final it in raw.whereType<Map>()) {
    final to = _text(it['to_table']);
    byTable.putIfAbsent(to, () => []).add(moveDishLine(it));
  }
  if (byTable.isEmpty) return null;
  final parts = <String>[];
  var first = true;
  byTable.forEach((to, dishes) {
    final where = to.isEmpty ? 'another table' : to;
    parts.add('${first ? 'Moved to' : 'to'} $where: ${dishes.join(', ')}');
    first = false;
  });
  return parts.join('; ');
}

/// The picker row for one order: its handle, and its dishes under it.
({String title, String dishes}) moveOrderPickerRow(Map order) =>
    (title: moveOrderTitle(order), dishes: moveDishSummary(orderDishLines(order)));

/// The body of "Move this order to 15?" — WHAT is moving, then what the kitchen
/// will see. [barked] is whether the kitchen already has the ticket.
String moveOrderConfirmBody({
  required Map order,
  required String fromTable,
  required String toTable,
  required bool barked,
}) {
  final dishes = moveDishSummary(orderDishLines(order), max: null);
  final what = dishes.isEmpty
      ? ''
      : moveKotNos(order).isEmpty
          ? '$dishes.\n\n'
          : '${moveOrderTitle(order)}: $dishes.\n\n';
  return '$what${moveOrderKitchenSentence(fromTable: fromTable, toTable: toTable, barked: barked)}';
}

/// What the kitchen will see when an order moves — the sentence both clients
/// put in front of the move.
String moveOrderKitchenSentence({required String fromTable, required String toTable, required bool barked}) => barked
    ? 'The kitchen already has a docket for $fromTable, so a correction docket '
        'prints for $toTable with the same KOT number. $fromTable keeps its guests '
        'and its other orders.'
    : 'The kitchen has not been sent this order yet, so nothing prints now — '
        'it will print for $toTable when it is sent.';

/// What the person who moved an order is told, from the server's answer:
///
///   Moved to 15: 1 × KUNAFA BIRDS NEST, 1 × STIR FRIED WATERCHESTNUT +1 more. Correction docket KOT-65 is printing — tell the pass.
///   Moved to 15: 2 × Dal. Nothing was on the pass for it, so no docket printed.
///
/// [dishes] are the server's `items` when it sent them, else the order's own.
String movedOrderSentence({
  required String toTable,
  required bool printed,
  Object? kotNo,
  List<String> dishes = const [],
}) {
  final summary = moveDishSummary(dishes);
  final head = summary.isEmpty ? 'Moved to $toTable.' : 'Moved to $toTable: $summary.';
  final no = _text(kotNo);
  final handle = no.isEmpty ? 'A correction docket' : 'Correction docket KOT-$no';
  return printed
      ? '$head $handle is printing — tell the pass.'
      : '$head Nothing was on the pass for it, so no docket printed.';
}

/// The dishes the server named in a move's answer (`items`: name, variation,
/// quantity), as lines. Empty for a server older than the field.
List<String> movedDishesOf(Object? response) {
  if (response is! Map || response['items'] is! List) return const [];
  return [for (final it in (response['items'] as List).whereType<Map>()) moveDishLine(it)];
}

/// What the person who moved ONE dish is told:
///
///   Moved 1 × NOT YOUR PUCHKA to Table 31. Docket KOT-35 is printing for 31 — tell the pass.
///   Moved 1 × NOT YOUR PUCHKA to Table 31.
String movedItemSentence({
  required String toTable,
  required List<String> dishes,
  required String fallbackName,
  Object? response,
}) {
  final what = dishes.isEmpty ? fallbackName : moveDishSummary(dishes);
  final prints = response is Map && response['prints'] is List ? (response['prints'] as List).whereType<Map>() : const <Map>[];
  final printedNos = <String>[
    for (final p in prints)
      if (p['printed'] == true && _text(p['kot_no']).isNotEmpty) 'KOT-${_text(p['kot_no'])}',
  ];
  final docket = printedNos.isEmpty
      ? ''
      : ' Docket ${printedNos.join(', ')} ${printedNos.length == 1 ? 'is' : 'are'} printing for $toTable — tell the pass.';
  return 'Moved $what to Table $toTable.$docket';
}
