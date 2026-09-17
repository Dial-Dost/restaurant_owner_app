/// THE NEXT PARTY AT A PRINTED TABLE — client item 6.
///
/// "Table where bill is printed is disappearing from the waiter app. There
/// should be a duplicate table showing same number for order taking for the
/// next round of guests."
///
/// The disappearing was C3. 2.0.1 kept it and gave back the NUMBER: the server
/// opens a second seat — a real table row called "12 #2" whose `parent_table`
/// is "12" — when a bill is printed, and retires it once it is idle. 2.0.2
/// (client items 1 and 2) keeps the printed table on the floor too, in orange,
/// with that seat green beside it (models/floor_state.dart). On /get-tables the
/// seat arrives as:
///
///   table_name    "12 #2"   the handle every route addresses it by
///   parent_table  "12"      null on every other table
///   party_no      2         null on every other table
///   display_name  "12"      what the tile prints big
///
/// WHY THE TILE SAYS "12" AND THE PAPER SAYS "12 #2". The waiter asked for the
/// same number, so the tile shows the root's number with a [nextPartyChip]. But
/// two open bills for "12" must stay distinguishable at the till, so the KOT, the
/// bill and every cashier list print the internal name, and anything that sends
/// a request sends [tableName] — never the display name. Two parties on one name
/// would put an order on the wrong bill.
///
/// THE WORDS ARE THE SERVER'S (Restaurant_Backend/next_party.ts) and the web
/// dashboard's too: "Next party", "12 (next party)", "Take it on 12 (next
/// party)". test/next_party_test.dart holds this file to the backend's own
/// source, so the two clients cannot drift into different words for one thing.
library;

/// The chip on a sibling's tile.
const String nextPartyChip = 'Next party';

/// The machine-readable code on the server's refusal of an order added to a
/// printed bill. The refusal is read by this code and never by its status.
const String billPrintedCode = 'bill_printed';

/// The status that refusal arrives with: 423, and deliberately not 409.
///
/// The outbox (services/outbox.dart) reads a 409 on a queued write as "this
/// key is still in flight" and retries it — eight times, holding every later
/// write from this device behind it (the ordering rule). A refusal is not in
/// flight; it is final. Any 4xx other than 401/408/409/429 is parked on its
/// first answer with the server's sentence on the chip, and the server answers
/// 423 so that 2.0.0 tills, which cannot be patched, park it too
/// (next_party.ts' BILL_PRINTED_STATUS).
const int billPrintedStatus = 423;

/// The sentence POST /add-table answers a reserved name with, verbatim from
/// the server. Shown before the request is even sent, so the owner learns the
/// rule without a round trip.
const String reservedTableNameError =
    'Table names ending in "#" and a number (like "12 #2") are kept for the next party at a printed table. Pick another name.';

final RegExp _reservedTail = RegExp(r'\s#\d+$');

/// True for a name only the server may create — "12 #2", "Patio 4 #13".
bool isReservedPartyName(String? name) => _reservedTail.hasMatch((name ?? '').trim());

String _str(Map? row, String key) => '${row?[key] ?? ''}'.trim();

/// The root's name when this /get-tables row is a next-party seat, else null.
String? parentTableOf(Map? row) {
  final p = _str(row, 'parent_table');
  return p.isEmpty ? null : p;
}

/// Is this row the next party's seat at another table?
bool isNextPartyRow(Map? row) => parentTableOf(row) != null;

/// What a tile prints big: the root's number for a sibling, the name otherwise.
/// An older backend sends no `display_name`, and the row's own name stands.
String tableDisplayName(Map? row) {
  final parent = parentTableOf(row);
  if (parent != null) return parent;
  final shown = _str(row, 'display_name');
  return shown.isNotEmpty ? shown : _str(row, 'table_name');
}

/// How many of the ROOM's tables are in use, where a table is in use when it,
/// or the next party's seat beside it, is [busy]. The room is every row that is
/// not a next-party seat; the web dashboard's Overview counts the same way
/// (countRoomsInUse in src/lib/next-party.ts).
({int inUse, int rooms}) countRoomsInUse(List rows, bool Function(Map row) busy) {
  final busyNumbers = <String>{
    for (final r in rows)
      if (r is Map && busy(r)) (parentTableOf(r) ?? _str(r, 'table_name')).toLowerCase(),
  };
  final rooms = [for (final r in rows) if (r is Map && !isNextPartyRow(r)) r];
  return (
    inUse: rooms.where((r) => busyNumbers.contains(_str(r, 'table_name').toLowerCase())).length,
    rooms: rooms.length,
  );
}

/// "12" -> "12 (next party)".
String nextPartyLabel(String root) => '${root.trim()} (next party)';

/// What a table is called in a sentence: "12 (next party)" for a sibling, its
/// own name otherwise. Takes the internal name and, when known, the root's.
String tableSentenceName(String tableName, {String? parentTable}) {
  final parent = (parentTable ?? '').trim();
  if (parent.isNotEmpty) return nextPartyLabel(parent);
  final parsed = parseNextPartyName(tableName);
  return parsed != null ? nextPartyLabel(parsed.root) : tableName.trim();
}

/// The same, read off a /get-tables row.
String tableSentenceNameOf(Map row) =>
    tableSentenceName(_str(row, 'table_name'), parentTable: parentTableOf(row));

/// "12 #2" -> (root: "12", seq: 2); anything else -> null. The inverse of the
/// server's naming, for a refusal that names a seat without its root.
({String root, int seq})? parseNextPartyName(String? name) {
  final m = RegExp(r'^(.*\S)\s#(\d+)$').firstMatch((name ?? '').trim());
  if (m == null) return null;
  final seq = int.tryParse(m.group(2)!);
  if (seq == null || seq < 2) return null;
  return (root: m.group(1)!, seq: seq);
}

/// The button beside that refusal: "Take it on 12 (next party)".
String takeItOnLabel(String nextPartyTable) => 'Take it on ${tableSentenceName(nextPartyTable)}';

/// The line after a print, when the server named a seat for the next party.
String? nextPartyAfterPrintMessage(String? nextPartyTable) {
  final next = (nextPartyTable ?? '').trim();
  if (next.isEmpty) return null;
  return 'Seat the next party at ${tableSentenceName(next)}.';
}

/// A print's response, read for the next party's seat. `next_party_message`
/// is the server's sentence and wins; an older build of the server that named
/// the seat without the sentence gets the same words built here.
({String? table, String? message}) nextPartyAfterPrint(Object? response) {
  if (response is! Map) return (table: null, message: null);
  final table = _str(response, 'next_party_table');
  final message = _str(response, 'next_party_message');
  if (table.isEmpty) return (table: null, message: null);
  return (table: table, message: message.isNotEmpty ? message : nextPartyAfterPrintMessage(table));
}

/// The server's refusal of an order added to a printed bill, read.
class BillPrintedRefusal {
  const BillPrintedRefusal({
    required this.message,
    required this.table,
    required this.nextPartyTable,
    required this.actionLabel,
    this.addToPrintedLabel,
  });

  /// The server's sentence, shown as it stands — its 2.0.2 one
  /// (`add_to_printed_message`) when it also offers [addToPrintedLabel],
  /// because the 2.0.1 sentence sends the waiter to a manager for the very
  /// thing that button does.
  final String message;

  /// The printed table.
  final String table;

  /// Where a NEW party's order goes, or null when there is nowhere else.
  final String? nextPartyTable;

  /// The button's label, or null when there is no button to draw.
  final String? actionLabel;

  /// 2.0.2 (client items 1 and 2): the server's label for "add these to the
  /// printed bill anyway" — "Add to 12's printed bill" — or null when it did
  /// not offer one (a guest, a merge, a move, or a server older than 2.0.2).
  /// Pressing it sends the same order again with [addToPrintedBillKey].
  final String? addToPrintedLabel;

  /// Null unless [body] is a `bill_printed` refusal.
  static BillPrintedRefusal? parse(Object? body, {String? fallbackMessage}) {
    if (body is! Map || _str(body, 'code') != billPrintedCode) return null;
    final table = _str(body, 'table');
    final next = _str(body, 'next_party_table');
    final elsewhere = next.isNotEmpty && next.toLowerCase() != table.toLowerCase();
    final label = _str(body, 'next_party_action');
    final addLabel = _str(body, 'add_to_printed_action');
    final addMessage = addLabel.isNotEmpty ? _str(body, 'add_to_printed_message') : '';
    final message = addMessage.isNotEmpty ? addMessage : _str(body, 'error');
    return BillPrintedRefusal(
      message: message.isNotEmpty
          ? message
          : (fallbackMessage ?? "This table's bill has already been printed."),
      table: table,
      nextPartyTable: elsewhere ? next : null,
      actionLabel: elsewhere ? (label.isNotEmpty ? label : takeItOnLabel(next)) : null,
      addToPrintedLabel: addLabel.isNotEmpty ? addLabel : null,
    );
  }
}

// ---------------------------------------------------------------------------
// CLIENT ITEMS 1 AND 2 — ADDING TO A PRINTED BILL, ON PURPOSE
// ---------------------------------------------------------------------------
//
// "If a bill is printed on a table (not settled), there should still be an
// option to add more items onto the existing bill." The server lets a waiter do
// it only when the write says `add_to_printed_bill: true`, and this app sends
// that only after the waiter has seen what it means and chosen it over the
// green seat beside the table. The words are the web dashboard's too
// (src/lib/next-party.ts).

/// The body key the server reads (Restaurant_Backend next_party.ts
/// ADD_TO_PRINTED_BILL_KEY). Only a literal `true` counts there.
const String addToPrintedBillKey = 'add_to_printed_bill';

/// "Add to 12's printed bill" — the server's addToPrintedBillLabel.
String addToPrintedBillLabel(String table, {String? parentTable}) =>
    "Add to ${tableSentenceName(table, parentTable: parentTable)}'s printed bill";

/// The orange tile's first control, and the confirm's primary action.
const String addToPrintedBillAction = 'Add to printed bill';

/// "Use green 12" — the confirm's other action: the next party's seat.
String useGreenTableLabel(String root) => 'Use green ${root.trim()}';

/// THE CONFIRM, in one sentence: "12's bill was printed at 13:32. These items
/// go on that bill and it must be printed again. New guests? Use the green 12."
/// [printedClock] is '' when the print time is unknown; [hasGreen] is whether
/// there is a green seat to send new guests to.
String addToPrintedBillConfirm({
  required String table,
  String? parentTable,
  String? printedClock,
  required bool hasGreen,
}) {
  final named = tableSentenceName(table, parentTable: parentTable);
  final parent = (parentTable ?? '').trim();
  final root = parent.isNotEmpty ? parent : (parseNextPartyName(table)?.root ?? table.trim());
  final when = (printedClock ?? '').trim();
  final printed = when.isNotEmpty ? "$named's bill was printed at $when." : "$named's bill has been printed.";
  final green = hasGreen ? ' New guests? Use the green $root.' : '';
  return '$printed These items go on that bill and it must be printed again.$green';
}

/// The strip across the order pad while it is adding to printed paper.
String addingToPrintedBillStrip(String table, {String? parentTable}) =>
    "Adding to ${tableSentenceName(table, parentTable: parentTable)}'s printed bill";

/// The FAMILY a /get-tables row belongs to: the root's name for a next-party
/// seat, its own otherwise, folded for comparison. "12" and "12 #2" are one
/// table.
String tableFamilyKey(Map row) => (parentTableOf(row) ?? _str(row, 'table_name')).toLowerCase();

/// Are these two rows the SAME PHYSICAL TABLE? The server refuses a party move
/// between them (Restaurant_Backend next_party.ts sameTableFamily), so the move
/// picker never offers one.
bool sameTableFamily(Map a, Map b) {
  final key = tableFamilyKey(a);
  return key.isNotEmpty && key == tableFamilyKey(b);
}

/// THE GREEN SEAT BESIDE A PRINTED TABLE: the family's free member other than
/// [printedRow] — the root when it is free, else the lowest-numbered free
/// next-party seat, the choice the server makes (freeFamilySeat). Null when the
/// whole family is busy. [isFree] is the floor's own answer.
Map? greenSeatFor(Map printedRow, List rows, bool Function(Map row) isFree) {
  final self = _str(printedRow, 'table_name').toLowerCase();
  final free = [
    for (final r in rows)
      if (r is Map &&
          sameTableFamily(printedRow, r) &&
          _str(r, 'table_name').toLowerCase() != self &&
          isFree(r))
        r,
  ];
  for (final r in free) {
    if (!isNextPartyRow(r)) return r;
  }
  int seq(Map r) => (r['party_no'] is num) ? (r['party_no'] as num).toInt() : 1 << 30;
  free.sort((a, z) => seq(a).compareTo(seq(z)));
  return free.isEmpty ? null : free.first;
}

/// "12's bill was already printed, so the paper no longer shows this. Reprint
/// the bill before the guest pays." — the server's reprintNeededMessage, word
/// for word, for a server that flagged the reprint without the sentence.
String reprintNeededMessage(String table, {String? parentTable}) =>
    "${tableSentenceName(table, parentTable: parentTable)}'s bill was already printed, "
    'so the paper no longer shows this. Reprint the bill before the guest pays.';

/// A SENIOR ROLE PUT MORE ON A PRINTED BILL, and the paper in the guest's hand
/// is now short: the guest would pay the printed total while the settle books
/// the larger one. The server allows it (a manager, a cashier, a captain may
/// add after a print) and answers `reprint_needed: true`, the sentence, and
/// the table whose paper to reprint. Every screen that sends such a write
/// reads it with [parse] and offers the Reprint (`showReprintNeeded` in
/// widgets/reprint_needed.dart); the web dashboard does the same with the
/// same words.
class ReprintNeeded {
  const ReprintNeeded({required this.table, required this.message});

  /// The table to reprint — the handle ("12 #2"), never the display name.
  final String table;

  /// The server's sentence, shown as it stands.
  final String message;

  /// Null unless [response] flags a reprint. [fallbackTable] is the table the
  /// write was for, used only when the server did not name one.
  static ReprintNeeded? parse(Object? response, {String? fallbackTable}) =>
      _parse(response, 'reprint_', fallbackTable);

  /// CLIENT ITEM 4 — A MOVE CHANGES TWO BILLS. Every reprint a move's answer
  /// asks for: the first in the ordinary `reprint_*` fields, and — when both the
  /// destination's and the source's papers were printed — the second in
  /// `also_reprint_*`, which only a move sends. Empty when neither was printed.
  static List<ReprintNeeded> parseAll(Object? response, {String? fallbackTable}) => [
        ?_parse(response, 'reprint_', fallbackTable),
        ?_parse(response, 'also_reprint_', null),
      ];

  static ReprintNeeded? _parse(Object? response, String prefix, String? fallbackTable) {
    if (response is! Map || response['${prefix}needed'] != true) return null;
    final named = _str(response, '${prefix}table');
    final table = named.isNotEmpty ? named : (fallbackTable ?? '').trim();
    if (table.isEmpty) return null;
    final said = _str(response, '${prefix}message');
    return ReprintNeeded(table: table, message: said.isNotEmpty ? said : reprintNeededMessage(table));
  }
}

/// What a TABLE-WISE view calls a seating row of /orders/apc: the ROOT's name
/// for a next-party seating ("12" for "12 #2"), else its own table name. The
/// web dashboard's table-wise summary reads the same field the same way
/// (`table_label ?? table_name`). A label only — the row is still its own
/// seating, with its own money and covers.
String tableWiseLabel(Map row) {
  final label = _str(row, 'table_label');
  return label.isNotEmpty ? label : _str(row, 'table_name');
}

/// Revenue by table: each seating's `total` added in under its
/// [tableWiseLabel], largest first — the web's table-wise summary, grouped the
/// same way. Seatings with nothing to show are left out, as they always were.
List<({String label, double value})> revenueByTable(List rows) {
  double amount(Object? v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  final byLabel = <String, double>{};
  for (final r in rows) {
    if (r is! Map) continue;
    final label = tableWiseLabel(r);
    final key = label.isEmpty ? '—' : label;
    byLabel[key] = (byLabel[key] ?? 0) + amount(r['total']);
  }
  return [
    for (final e in byLabel.entries)
      if (e.value > 0) (label: 'Table ${e.key}', value: e.value),
  ]..sort((a, b) => b.value.compareTo(a.value));
}
