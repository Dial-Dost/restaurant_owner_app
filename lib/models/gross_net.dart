// GROSS, NET AND ITEM TOTAL — three words, one meaning each, on every screen.
//
// Client: "Gross means the total value of all the bills including service
// charge, taxes and so on. Net means just the menu price value of all the bills
// where you reduce the discounts, service charge, taxes and so on."
//
//   GROSS       the grand total — net + service charge + tax + round off, before
//               refunds. `grand_total` on the MIS reports, `total_sales` on the
//               accounting Sales report.
//   NET         the item total less discounts, before service charge, tax and
//               round off. `net` on the MIS reports, `total_net` on Sales.
//   ITEM TOTAL  the menu-price value of the lines before any discount.
//               `item_total` (`gross_amount` on the three item-level reports).
//
// WHAT WENT WRONG, so nobody walks back into it: the pre-discount rung used to be
// called "Gross", so a restaurant that never discounts saw Gross === Net on every
// report while the Overview's "gross sale" was a different, tax-inclusive number.
// The Accounting NET SALES card, meanwhile, showed a THIRD figure — the grand
// total less refunds, tax and all. Nothing about the money changed; the words did.
//
// THE KEYS DID NOT MOVE. The backend keeps `gross` (= item total) and `net_sales`
// (= gross − refunds) under their old names and values for tills that have not
// updated, so this file is the ONE place that decides which key a word reads —
// and falls back to the old key where an older backend has not sent the new one.
// The web dashboard's src/lib/gross-net.ts makes the same decisions in the same
// words; the two must not drift.
//
// PURE: no Flutter, no network. Every figure is the server's.

const String kGross = 'Gross';
const String kNet = 'Net';
const String kItemTotal = 'Item total';

/// Collected (or Gross) less refunds, tax still in — never called Net.
const String kAfterRefunds = 'After refunds';

bool _present(dynamic v) => v != null && '$v'.trim().isNotEmpty;

double? _numOrNull(dynamic v) {
  if (!_present(v)) return null;
  final n = v is num ? v.toDouble() : double.tryParse('$v'.trim());
  return (n == null || !n.isFinite) ? null : n;
}

/// The pre-discount rung off a ladder totals map: `item_total` from a backend
/// that sends it, the deprecated `gross` alias (same value) from one that does
/// not. NEVER `grand_total` — that is Gross.
dynamic itemTotalOf(Map totals) => _present(totals['item_total']) ? totals['item_total'] : totals['gross'];

/// The Discount report's share, on the item total. Same fallback rule.
dynamic discountPctOf(Map totals) => _present(totals['discount_pct_of_item_total'])
    ? totals['discount_pct_of_item_total']
    : totals['discount_pct_of_gross'];

/// The accounting Sales report, as far as these words need it.
class AccountingSalesFigures {
  const AccountingSalesFigures({
    required this.grossSales,
    required this.netSales,
    required this.refunds,
    required this.grossAfterRefunds,
    required this.roundOff,
  });

  /// total_sales — the grand total of the window's bills.
  final double? grossSales;

  /// total_net — null from a backend older than this change, never guessed.
  final double? netSales;
  final double? refunds;

  /// net_sales, the legacy key: Gross less refunds, tax still in.
  final double? grossAfterRefunds;

  /// total_round_off — null from an older backend.
  final double? roundOff;

  /// The headline card's caption. "Net sales" when the server sent Net;
  /// otherwise the card says what it is actually showing.
  String get headlineLabel => netSales != null ? 'Net sales' : 'Gross after refunds';
  double? get headlineValue => netSales ?? grossAfterRefunds;
}

/// One line of the printed Accounting PDF's Sales block.
class SalesPdfLine {
  const SalesPdfLine(this.label, this.value, {this.bold = false});
  final String label;

  /// The server's raw value, formatted by the PDF's own `kv`.
  final dynamic value;
  final bool bold;
}

/// The Sales block of the Accounting PDF, as (label, value) lines off the
/// accounting Sales report.
///
/// PURE and here, not inline in the PDF builder, because the PDF is the copy
/// that gets filed and nothing else pinned which key its lines read: pointing
/// "Net sales" back at `net_sales` — Gross less refunds, tax and all, which is
/// exactly the client's complaint — passed every suite. "Net sales" is printed
/// only when the server sent `total_net`; an older backend's PDF says what it
/// has rather than borrowing the word.
List<SalesPdfLine> accountingSalesPdfLines(Map sales) => [
      SalesPdfLine('Gross sales', sales['total_sales']),
      SalesPdfLine('Bills', sales['bill_count'] ?? 0),
      SalesPdfLine('Gross after refunds', sales['net_sales']),
      if (readAccountingSales(sales).netSales != null) SalesPdfLine('Net sales', sales['total_net'], bold: true),
    ];

AccountingSalesFigures readAccountingSales(Map? sales) => AccountingSalesFigures(
      grossSales: _numOrNull(sales?['total_sales']),
      netSales: _numOrNull(sales?['total_net']),
      refunds: _numOrNull(sales?['total_refund']),
      grossAfterRefunds: _numOrNull(sales?['net_sales']),
      roundOff: _numOrNull(sales?['total_round_off']),
    );
