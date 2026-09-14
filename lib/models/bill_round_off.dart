// THE ROUND-OFF RUNG, AS EVERY SCREEN IN THIS APP READS IT (backend migration 048).
//
// "Round off the final amount always in final bill." The backend now rounds
// every bill's grand total to the rupee, once, in its billing layer
// (computeBillCharges), and returns the adjustment as `round_off` beside
// `grand_total` — on /bill-for-table (the table sheet, the waiter strip, the
// bill preview) and on the settled bill (/bills/closed/:id). The client's own
// receipt is the specification: "Round off -0.26" directly above "Grand Total
// 4982.00".
//
// NOTHING HERE ROUNDS. A client that rounded for itself would be a second rule
// in a second language, and the first time the two disagreed the screen and the
// till would show different totals. These helpers only READ the server's
// adjustment and say whether there is one to show.
//
// SHOWN ONLY WHEN IT IS NOT ZERO, like every other optional rung: a bill that was
// already whole rupees, a bill settled before rounding existed (round_off NULL),
// and a backend older than the field (no key) all show exactly what they did.

/// The server's round-off on a bill payload, or null when there is none to show.
/// Compared in whole paisa, so float noise under a paisa is nothing.
double? billRoundOff(dynamic raw) {
  if (raw == null) return null;
  final value = raw is num ? raw.toDouble() : double.tryParse('$raw'.trim());
  if (value == null || !value.isFinite) return null;
  final paisa = (value * 100).round();
  return paisa == 0 ? null : paisa / 100;
}

/// As the PAPER prints it (escpos.ts): "+0.50", "-0.26" — signed, no currency.
String billRoundOffPaper(double value) => '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}';

/// As a SCREEN shows it: always signed, with the currency on the magnitude, so
/// "−₹0.26" can never be read as a charge and "+₹0.50" never as a discount.
String billRoundOffMoney(double value) => '${value < 0 ? '−' : '+'}₹${value.abs().toStringAsFixed(2)}';
