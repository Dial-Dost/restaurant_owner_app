// CLIENT ITEM 3 (2026-09-17) — "On the waiter dashboard, Cancel KOT option
// should be removed."
//
// THE RULE IS THE SERVER'S (role_scope.ts mayCancelTicketed, enforced by every
// route that can cancel): a waiter-only login never cancels food the kitchen has
// been told about. What a waiter keeps is "Decline" on a PENDING order — one
// that was placed while auto-push is off and never ticketed.
//
// This file holds the two things the app needs to say about it without asking:
// the code the server refuses with, and the server's own sentence, word for
// word (cancel_authority.ts cancelNeedsSeniorSentence). The sentence is shown
// only if a cancel is somehow attempted where the button is not drawn — a
// defensive path in [_cancelOrder] — so a waiter sees the same words whether
// the app or the server said no. PURE.

/// The machine-readable code on the server's 403.
const String cancelNeedsSeniorCode = 'cancel_needs_senior';

/// "KOT-65 has gone to the kitchen. Only a manager, cashier, captain or admin
/// can cancel it — ask one of them." — the server's words.
String cancelNeedsSeniorSentence(List<int> kotNos) {
  final nos = <int>[];
  for (final n in kotNos) {
    if (n > 0 && !nos.contains(n)) nos.add(n);
  }
  final ticket = nos.isEmpty ? 'This order' : nos.map((n) => 'KOT-$n').join(', ');
  final verb = nos.length > 1 ? 'have' : 'has';
  return '$ticket $verb gone to the kitchen. Only a manager, cashier, captain or admin can cancel it — ask one of them.';
}

/// Whether an order row is PENDING — never ticketed, so a waiter may decline it.
bool orderIsPending(Object? status) => '${status ?? ''}'.trim().toLowerCase() == 'pending';
