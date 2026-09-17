/// CLIENT ITEMS 1 AND 2 — WHAT COLOUR IS A TABLE, AND IS ITS PAPER STILL RIGHT?
///
/// "In the waiter dashboard, if a bill is not settled, the table completely
/// vanishes; bills are settled only at night, so there should be a duplicate
/// table with the same number. … Different colour codings: e.g. the fresh
/// table 12 in green, and the table 12 whose bill has been printed but not
/// settled in orange."
///
/// C3 took a printed table off a waiter's floor. At Gaia Global Vegetarian the
/// bills are settled at night, so a printed table is a pending bill for hours,
/// and its guests order dessert. The printed table now STAYS, in orange, and
/// the next party's seat beside it ("12 #2", drawn "12") is green like every
/// other free table.
///
/// FIVE STATES, ONE MEANING EACH:
///
///   free      nobody seated, nothing owed            green
///   seated    a party sat down, nothing ordered yet  amber
///   running   food ordered, bill not printed         red
///   printed   bill printed, not settled              orange
///   reserved  a booking holds it                     blue
///
/// PRINTED WINS over running and seated: the paper is out, and a waiter adding
/// a dessert must see that before anything else. A table is never green while
/// anybody is at it.
///
/// THE WORDS AND THE RULES ARE THE WEB DASHBOARD'S (src/lib/floor-state.ts and
/// src/lib/bill-print-state.ts), and test/waiter_floor_printed_test.dart holds
/// the two to each other. The inks live on the shell scheme
/// (AppShellScheme.floorFree and its four siblings); this file is pure.
library;

/// The five states a table tile can be in, in the legend's order: the busiest
/// first, then the free floor.
enum FloorState {
  running('Running'),
  printed('Bill printed'),
  seated('Seated'),
  reserved('Reserved'),
  free('Free');

  const FloorState(this.word);

  /// What the chip and the legend say.
  final String word;
}

/// The chip on a printed tile whose paper no longer matches the bill.
const String paperStaleChip = 'Updated — print again';

/// What decides a tile's state.
///
/// [hasOrder] null is a backend older than the field: a seated table then reads
/// as running, exactly as the floor always painted it. [printed] is the server's
/// print state (or, on a backend with none, this device's memory of printing).
FloorState floorStateOf({
  required bool seated,
  bool? hasOrder,
  required bool printed,
  required bool reserved,
}) {
  final inUse = seated || hasOrder == true;
  if (printed && inUse) return FloorState.printed;
  if (inUse) return hasOrder == false ? FloorState.seated : FloorState.running;
  if (reserved) return FloorState.reserved;
  return FloorState.free;
}

/// THE LEGEND. A senior reads counts — "3 Running · 8 Bill printed · …", the
/// printed count being the night-settle backlog; a waiter reads the key alone.
/// States with no table are left out of the counted legend.
List<({FloorState state, String label, int count})> floorLegend(
  Iterable<FloorState> states, {
  required bool withCounts,
}) {
  final counts = <FloorState, int>{};
  for (final s in states) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  return [
    for (final state in FloorState.values)
      if (!withCounts || (counts[state] ?? 0) > 0)
        (
          state: state,
          label: withCounts ? '${counts[state] ?? 0} ${state.word}' : state.word,
          count: counts[state] ?? 0,
        ),
  ];
}

/// IS THE OWNER'S "ONLY THE PRINTED BILLS" FILTER NARROWING THE FLOOR? Only
/// when it was asked for AND a printed table is there to show. The counted
/// legend drops a state with no table, so once the last printed bill is settled
/// the chip that turns the filter off is gone — and a filter still in force
/// would leave a blank floor with no control to clear it. The web's
/// printedBacklogFilterOn, the same rule.
bool printedBacklogFilterOn(bool requested, Iterable<FloorState> states) =>
    requested && states.contains(FloorState.printed);

/// "#2" — the small chip on a next-party seat, whose tile reads its root's
/// number. Null for anything that is not a whole number of two or more.
String? nextPartyBadge(Object? partyNo) {
  if (partyNo is! num || !partyNo.isFinite || partyNo != partyNo.roundToDouble()) return null;
  final n = partyNo.toInt();
  return n >= 2 ? '#$n' : null;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// The print's clock as the restaurant reads it: "13:32", or "16/09 13:32" when
/// it was another day — the backend's billPrintedClock. Both arguments are
/// restaurant WALL clocks (RestaurantTime.wallOf / nowWall), so this does no
/// zone arithmetic of its own. '' when there is no print time.
String printedClockOf(DateTime? printedWall, DateTime nowWall) {
  if (printedWall == null) return '';
  final clock = '${_two(printedWall.hour)}:${_two(printedWall.minute)}';
  final sameDay = printedWall.year == nowWall.year &&
      printedWall.month == nowWall.month &&
      printedWall.day == nowWall.day;
  return sameDay ? clock : '${_two(printedWall.day)}/${_two(printedWall.month)} $clock';
}

/// The small chips on a printed tile, in order: "Printed 13:32", "Updated —
/// print again" when the paper is out of date, "Printed as 12" after a move.
List<String> printedTileChips({String? printedClock, bool? paperStale, String? printedAs}) {
  final clock = (printedClock ?? '').trim();
  final as = (printedAs ?? '').trim();
  return [
    clock.isEmpty ? 'Printed' : 'Printed $clock',
    if (paperStale == true) paperStaleChip,
    if (as.isNotEmpty) 'Printed as $as',
  ];
}

String _str(Map? row, String key) => '${row?[key] ?? ''}'.trim();

/// THREE ANSWERS, AS FOR THE PRINT ITSELF: true (the paper no longer matches the
/// bill), false (it does), null (nobody knows — an older backend, or a print
/// made before migration 055 recorded what it said). Only a real boolean counts.
bool? paperStaleOf(Map? row) {
  final v = row?['paper_stale'];
  return v is bool ? v : null;
}

/// "12" when the bill in hand was printed under another table's name (the
/// party moved after the print), else null.
String? printedAsOf(Map? row) {
  final v = _str(row, 'printed_as');
  return v.isEmpty ? null : v;
}

/// What the printed paper said the guest owes, or null (a waiter is never sent
/// it, and an older print never recorded it).
double? printedTotalOf(Map? bill) {
  final v = bill?['printed_total'];
  if (v is num) return v.toDouble();
  return v == null ? null : double.tryParse('$v');
}

/// The print control's two words. "Print updated bill" is the one a waiter may
/// press on a printed table — and only when the paper is out of date.
const String printBillLabel = 'Print bill';
const String printUpdatedBillLabel = 'Print updated bill';

/// The banner an updated print carries (Restaurant_Backend bill_paper_digest.ts
/// UPDATED_BILL_MARKER), drawn on the preview as the roll prints it.
const String updatedBillMarker = '** UPDATED BILL **';

/// "Replaces the bill printed 13:32" — the line under that banner.
String replacesBillLine(String clock) {
  final c = clock.trim();
  return c.isEmpty ? 'Replaces an earlier printed bill' : 'Replaces the bill printed $c';
}

/// "Settle anyway" — the override on the stale-paper warning. The web says the
/// same.
const String settleAnywayLabel = 'Settle anyway';

/// THE WARNING BEFORE A SETTLE AGAINST OUT-OF-DATE PAPER.
///
/// "The printed bill (13:32) shows ₹2100.00; the bill is now ₹2220.00. Print the
/// updated bill before taking payment." — or "The printed bill (13:32) no longer
/// matches the bill. …" when the reader was not sent the amounts, or when the
/// two totals are the same. Null unless the paper is KNOWN to be stale: the
/// warning never fires on a guess, and it never blocks. The till books the
/// current total either way, and "Settle anyway" is recorded.
///
/// THE SAME TOTAL IS NEVER NAMED TWICE. The paper also goes stale when only the
/// guest's details change after the print (an address or a GSTIN: the server's
/// paper digest carries them), and then printed_total == grand_total. "Shows
/// ₹2100.00; the bill is now ₹2100.00" reads as if nothing changed, so the
/// amounts are named only when they differ by at least half a paisa AND the
/// reader would see two different figures.
String? stalePaperSettleWarning({
  required bool? paperStale,
  String? printedClock,
  double? printedTotal,
  double? grandTotal,
  required String Function(double amount) money,
}) {
  if (paperStale != true) return null;
  final when = (printedClock ?? '').trim();
  final paper = when.isEmpty ? 'The printed bill' : 'The printed bill ($when)';
  final printed = printedTotal == null ? null : money(printedTotal);
  final now = grandTotal == null ? null : money(grandTotal);
  final differ = printedTotal != null &&
      grandTotal != null &&
      (printedTotal - grandTotal).abs() >= 0.005 &&
      printed != now;
  final amounts = differ
      ? '$paper shows $printed; the bill is now $now.'
      : '$paper no longer matches the bill.';
  return '$amounts Print the updated bill before taking payment.';
}

/// THE WAITER'S LINE AFTER A PRINT, now that the table stays: "12's bill is
/// printed. 12 stays on your floor in orange until a manager settles it. New
/// guests at 12: use the green 12." [tableSentence] is the table as a sentence
/// names it ("12", or "12 (next party)"); [root] is the number on its tile.
String printedStaysMessage({required String tableSentence, required String root, bool hasGreen = true}) {
  final t = tableSentence.trim();
  final r = root.trim();
  final green = hasGreen ? ' New guests at $r: use the green $r.' : '';
  return "$t's bill is printed. $t stays on your floor in orange until a manager settles it.$green";
}

/// What a party move says before it runs, when the party's bill has been
/// printed — the web's printedPartyMoveNote, word for word.
String printedPartyMoveNote(String from, String to) =>
    "The printed bill moves with them. The guest's paper still says ${from.trim()}; "
    'the bill will show as ${to.trim()} (printed as ${from.trim()}).';

/// A move is not queued: POST /tables/move carries a whole party, its bill and
/// its prints, and is not one of the writes the server deduplicates.
const String moveTableNeedsConnection =
    'Moving a table needs a connection — nothing was moved. Reconnect and try again.';
