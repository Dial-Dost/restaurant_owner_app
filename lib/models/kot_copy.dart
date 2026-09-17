// THE APP'S LOCAL KOT COPY — what the "Print KOT (local PDF copy)" button on a
// kitchen ticket prints, laid out the way the reference docket is.
//
// NOT THE KITCHEN DOCKET. The docket a kitchen cooks from is drawn by the
// backend (escpos.ts layoutKot, a raster in Liberation Sans) and pushed to a
// thermal printer. This is a PDF, printed wherever the system print dialog
// sends it, in the pdf package's default font. What it shares with the docket
// is everything a chef actually reads: THE ORDER OF THE LINES, WHICH OF THEM
// ARE BOLD, AND THE WORDS ON THEM. The reference docket, transcribed:
//
//   Running Table                     centred
//   KOT                               centred, BOLD
//   08/09/26 14:13                    centred
//   KOT - 21                          centred
//   Dine In: DOME SECTION             centred, BOLD
//   Table No: 33                      centred, BOLD
//   Persons - 4                       centred
//   ------------------------------
//   Assign to / Captain               left
//   ------------------------------
//   No.Item                      Qty
//   1 Subz Tehri                   1  dish name BOLD, qty a bare number
//     [Note] Hold Dessert             under the dish, upright
//   ------------------------------
//   Total Qty                      3
//
// and this copy of ONE ORDER off the kitchen board:
//
//   Local copy - no ticket number     centred        (the context line's slot)
//   KOT                               centred, BOLD
//   16 Sep 2026, 14:13:05 IST         centred
//   Dine In                           centred, BOLD
//   Table No: 33                      centred, BOLD
//   ------------------------------
//   ** NOTE **                        centred, BOLD  (only with an order note)
//   No onions for the whole table     left
//   ------------------------------
//   No.Item                      Qty
//   1 Subz Tehri                   1
//     [Hold]                          only what the docket says: the marker
//     [Note] Hold Dessert
//   ------------------------------
//   Total Qty                      1
//   Hold Qty                       1  (only when something is held)
//   ------------------------------
//
// WHAT IT LEAVES OUT, AND WHY:
//   * "Running Table" — the docket covers the table's whole running order set;
//     this covers one order, so the context slot says what the paper really is.
//   * "KOT - n" — the number is allocated server-side, inside the transaction
//     that makes it unique per outlet-day (migration 029). A number invented
//     here would collide with the real series, so the context line says there
//     is none, and the slot stays empty — as the docket's own does when
//     numbering is unavailable.
//   * the section, "Persons", "Assign to" and "Captain" — GET /orders does not
//     carry them, and a line guessed at is worse than a line left out.
//   * the restaurant name — the reference docket has none either.
//
// WHAT IT KEEPS THAT THE REFERENCE HAS NO EQUIVALENT FOR: the "[Hold]" line
// and Hold Qty (hold-and-fire), and the "** NOTE **" block, which is where an
// allergy reaches the pass — the same three the docket keeps.
//
// THE HOLD LINE IS JUST THE MARKER. The client, 2026-09-16: "When an item is on
// hold, on the KOT it must only say 'hold' and NOT 'hold do not cook until
// fired'." [kotHoldLine] is the one string for it in this app — the kitchen
// board's hold line reads it too — and it is escpos.ts KOT_HOLD_LINE word for
// word.
//
// PURE: no Flutter, no pdf, no network. modules.dart draws these rows.

/// The line under a HELD dish, on the docket, on this copy and on the kitchen
/// board — word for word escpos.ts `KOT_HOLD_LINE`. It said "[Hold] Do not
/// cook until fired" until the client asked for the marker alone.
const String kotHoldLine = '[Hold]';

/// The note line under a dish, tagged the way the client's reference docket
/// tags it and the thermal docket prints it: `[Note] <note>`.
String kotNoteLine(String note) => '[Note] $note';

/// What the context slot of a local copy says: what the paper is.
const String kotCopyContextLine = 'Local copy - no ticket number';

/// Whether one order line is a HELD course that has not been fired yet — the
/// predicate the kitchen board dims by, so the board, this copy and its totals
/// cannot disagree about which lines wait.
bool kotLineHeld(Map line) =>
    line['course_hold'] == true && (line['fired_at'] == null || '${line['fired_at']}'.isEmpty);

/// One dish on a KOT: its number, name and quantity, and the indented lines
/// that hang under it — [kotHoldLine] first when it is held, then its note.
typedef KotDocketRow = ({String no, String name, int qty, bool held, List<String> under});

/// The whole item block of a KOT, laid out once so the PDF copy and its tests
/// read the same thing.
typedef KotDocket = ({List<KotDocketRow> rows, int totalQty, int holdQty, bool showTotal, bool showHold});

/// THE ITEM BLOCK OF A KITCHEN TICKET, as the thermal docket lays it out.
///
/// ROUND 2 ITEM 2: "Hold order should come after the name of the dish which is
/// to be put on hold and not before. It should be in the same position like the
/// way a note appears on the food order." So:
///
///   * every dish keeps its number and its place in the list, held or not;
///   * a held dish's first under-line is [kotHoldLine], and a note follows it;
///   * Total Qty counts only what may be cooked now, and Hold Qty — the held
///     quantity — sits directly under it. A wholly held docket prints no Total
///     Qty (a "0" reads as an empty ticket); a docket with nothing held prints no
///     Hold Qty, exactly as before the feature.
///
/// The dish carries its size the way the docket's does: "Paneer Tikka (Half)".
KotDocket kotDocket(List items) {
  final rows = <KotDocketRow>[];
  var totalQty = 0;
  var holdQty = 0;
  var heldLines = 0;
  for (final it in items) {
    final m = it as Map;
    final held = kotLineHeld(m);
    final parsed = num.tryParse('${m['quantity'] ?? 1}') ?? 1;
    final qty = parsed.round() < 1 ? 1 : parsed.round();
    if (held) {
      holdQty += qty;
      heldLines += 1;
    } else {
      totalQty += qty;
    }
    final name = '${m['name'] ?? ''}'.trim();
    final variation = '${m['variation'] ?? ''}'.trim();
    final note = '${m['note'] ?? ''}'.trim();
    rows.add((
      no: '${rows.length + 1}',
      name: variation.isEmpty || variation == 'null' ? name : '$name ($variation)',
      qty: qty,
      held: held,
      under: [if (held) kotHoldLine, if (note.isNotEmpty) kotNoteLine(note)],
    ));
  }
  return (
    rows: rows,
    totalQty: totalQty,
    holdQty: holdQty,
    showTotal: heldLines < rows.length || heldLines == 0,
    showHold: heldLines > 0,
  );
}

/// The docket's words for how an order is served — kot_numbers.ts
/// `serviceModeLabel`, so the copy and the docket name a takeaway alike.
String kotServiceModeLabel(Object? orderType) {
  final t = '${orderType ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  if (t.isEmpty || t == 'null' || t == 'dine_in' || t == 'dinein') return 'Dine In';
  if (t == 'takeaway' || t == 'take_away' || t == 'pickup' || t == 'parcel') return 'Takeaway';
  if (t == 'delivery') return 'Delivery';
  if (t == 'swiggy') return 'Delivery (Swiggy)';
  if (t == 'zomato') return 'Delivery (Zomato)';
  return t
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// The shapes a line of the copy comes in — the docket's own four, with the
/// under-dish line split out because it is set at the name column.
enum KotCopyKind {
  /// One run of text across the paper, centred or left.
  line,

  /// A dashed rule across the paper.
  rule,

  /// The three-column row: [KotCopyRow.no] | [KotCopyRow.text] | [KotCopyRow.qty].
  /// On the heading and the totals the name cell is empty and the left cell
  /// runs into it ("No.Item", "Total Qty"), as it does on the docket.
  columns,

  /// A line hung under a dish, starting at the name column ("[Hold]", "[Note] …").
  under,
}

/// One line of the copy. Only the fields its [kind] uses are meaningful.
typedef KotCopyRow = ({KotCopyKind kind, String text, bool bold, bool centred, String no, String qty});

KotCopyRow _line(String text, {bool bold = false, bool centred = true}) =>
    (kind: KotCopyKind.line, text: text, bold: bold, centred: centred, no: '', qty: '');

const KotCopyRow _rule = (kind: KotCopyKind.rule, text: '', bold: false, centred: false, no: '', qty: '');

KotCopyRow _cols(String no, String name, String qty, {bool bold = false}) =>
    (kind: KotCopyKind.columns, text: name, bold: bold, centred: false, no: no, qty: qty);

KotCopyRow _under(String text) =>
    (kind: KotCopyKind.under, text: text, bold: false, centred: false, no: '', qty: '');

/// THE LOCAL COPY OF ONE ORDER, line by line, in the reference docket's order.
///
/// `order` is one entry of GET /orders (table, order_type, note, items);
/// `stamp` is the printed time, passed in so the copy is a pure function of its
/// input. Emphasis is WEIGHT, never size — "KOT", the service mode, the table
/// and each dish name are bold, everything else is regular and upright — which
/// is how the reference docket does it.
List<KotCopyRow> kotCopyRows(Map order, {required String stamp}) {
  String field(String key) {
    final v = '${order[key] ?? ''}'.trim();
    return v == 'null' ? '' : v;
  }

  final docket = kotDocket((order['items'] as List?) ?? const []);
  final rows = <KotCopyRow>[
    _line(kotCopyContextLine),
    _line('KOT', bold: true),
    if (stamp.trim().isNotEmpty) _line(stamp.trim()),
    _line(kotServiceModeLabel(order['order_type']), bold: true),
    _line('Table No: ${field('table').isEmpty ? 'N/A' : field('table')}', bold: true),
    _rule,
  ];
  // The order-level instruction, above the items it qualifies — the docket's
  // "** NOTE **" block, word for word.
  final note = field('note');
  if (note.isNotEmpty) {
    rows
      ..add(_line('** NOTE **', bold: true))
      ..add(_line(note, centred: false))
      ..add(_rule);
  }
  rows.add(_cols('No.Item', '', 'Qty'));
  for (final r in docket.rows) {
    rows.add(_cols(r.no, r.name, '${r.qty}', bold: true));
    for (final l in r.under) {
      rows.add(_under(l));
    }
  }
  rows.add(_rule);
  if (docket.showTotal) rows.add(_cols('Total Qty', '', '${docket.totalQty}'));
  if (docket.showHold) rows.add(_cols('Hold Qty', '', '${docket.holdQty}'));
  rows.add(_rule);
  return rows;
}
