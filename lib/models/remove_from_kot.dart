// ROUND 4 ITEM 2 — "Instead of removing it from the bill, it should be removed
// from the KOT … 'Remove from bill' makes it sound like the item is going to be
// served but only removed from bill."
//
// ============================================================================
// THE NAME WAS THE BUG
// ============================================================================
// "Remove from bill" is a complete and accurate description of a DIFFERENT act
// this app already has: a comp. Mark a line non-chargeable (mis_capture.dart,
// "Make non-chargeable") and the dish is cooked, plated and carried out — the
// house simply does not charge for it. That is what the floor reads into
// "remove from bill", and they are reading it correctly.
//
// This control does the opposite, irreversibly and without a prompt after the
// fact: the line comes off the ticket, the money comes off the bill, and a
// CANCELLED slip goes to the pass so the dish is never cooked. The guest does
// not get it. So the control says KOT, and so do the words below.
//
// PURE, and in models/ beside order_moves.dart for the same reason: the
// sentences a person on the floor acts on are worth a unit test, and a widget
// is a poor place to keep one. Character-for-character parity with the web's
// `removedItemSentence` (kot-line-actions.tsx) — a restaurant that removes a
// dish on the till and on the laptop is told the same thing both times.

String _text(Object? v) {
  if (v == null) return '';
  if (v is num) return '${v is int ? v : v.toInt()}';
  return '$v'.trim();
}

/// The question the admin is asked before anything happens.
///
/// It names the dish and the ticket, and then says the two things the old
/// "Remove "X" from this table's bill?" left to be guessed: that the kitchen is
/// told, and that nobody is served. The last clause points at the act somebody
/// reaching for a comp actually wants, rather than letting them discover from
/// an empty plate that this was not it.
const String removeFromKotWarning =
    'It comes off the ticket and off the bill, and the kitchen gets a CANCELLED '
    'slip for it, so it will not be cooked or served. To serve it free of charge '
    'instead, mark it non-chargeable.';

/// The title of that question: `Remove "Tandoori Roti" from this KOT?`
String removeFromKotTitle(String dish) => 'Remove "$dish" from this KOT?';

/// What the person who removed a dish is told afterwards:
///
///   Removed Tandoori Roti from KOT-3. The slip is printing as CANCELLED — tell the pass.
///   Removed Tandoori Roti from the KOT. It will not be cooked.
///
/// The second form is the honest answer when NOTHING went to the pass — a line
/// on a pending order, or a tenant that prints on demand (`kot_cancelled` false,
/// see dispatchCancellationKot's reasons). Announcing a docket that does not
/// exist is worse than announcing none, so the number is named only when the
/// server says a slip carrying it is on its way.
String removedFromKotSentence(String dish, Object? response) {
  final answer = response is Map ? response : const {};
  final no = _text(answer['kot_no']);
  return answer['kot_cancelled'] == true && no.isNotEmpty
      ? 'Removed $dish from KOT-$no. The slip is printing as CANCELLED — tell the pass.'
      : 'Removed $dish from the KOT. It will not be cooked.';
}
