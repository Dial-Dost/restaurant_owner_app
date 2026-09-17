// SETTLE AS NC — the app's half of client item 5.
//
// "NC has to come up as an option for payment mode when settling a bill, this
// has to be coded in as analytics for NC is required."
//
// NC IS A WAY TO CLOSE A BILL, NOT A WAY TO PAY ONE. The backend refuses "NC" as
// a payment mode on purpose (payment_methods.ts), and so does this app's own
// copy of that rule ([PaymentModes.notMoneyKind]): a mode is money collected,
// and settling with one books the grand total as sales and tax for a meal
// nobody paid for. So the NC pill on the settle sheet is not another mode. It
// makes ONE call, POST /bills/order/:orderId/settle-nc, which comps every
// remaining dish into the NC ledger (the ledger "Non-chargeable" already
// writes) and closes the bill at 0.00 with payment_method 'NC'. There is no
// approve and no close after it: nothing was taken, so there is nothing to
// approve.
//
// WHOLE BILLS ONLY. Part of a bill is given away by comping dishes one by one
// and taking the rest; the server refuses an amount, and both clients say so in
// the same sentence.
//
// THE SAME WORDS AS THE WEB DASHBOARD (src/lib/nc-settle.ts) and the same two
// gates: the comp permission AND Close Bill. A waiter holds neither and never
// sees any of it (C1).
//
// PURE: no Flutter, no network. Same discipline as bill_round_off.dart.

/// What "Bills".payment_method says on a bill settled as non-chargeable.
const String kNcSettleMethod = 'NC';

/// What every screen calls that marker — the backend's NC_SETTLE_LABEL.
const String kNcSettleLabel = 'Non-chargeable (NC)';

/// The pill on the settle sheet, beside the payment modes.
const String kNcSettlePill = 'NC · Non-chargeable';

/// The one button that does it.
const String kNcSettleButton = 'Settle as NC';

/// The backend's NC_WHOLE_BILL_ONLY, word for word.
const String kNcWholeBillOnly =
    'Settle as NC covers the whole bill. To give part of it away, comp dishes individually, then take the rest.';

double _num(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : 0;
  final n = double.tryParse('${v ?? ''}'.trim());
  return n != null && n.isFinite ? n : 0;
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// The NC settle's rules, by value.
abstract final class NcSettle {
  /// Is this stored method the NC marker? Case- and space-insensitive.
  static bool isMethod(Object? raw) => '${raw ?? ''}'.trim().toLowerCase() == 'nc';

  /// May this session be offered the NC pill? BOTH gates, because the route has
  /// both: it is a comp and a settle. A cashier (Close Bill only) and a waiter
  /// (neither) are not shown a control that would 403.
  static bool mayOffer({required bool compItem, required bool settleBill}) => compItem && settleBill;

  /// What the settle comps and what `expected_value` carries: the open bill's
  /// `subtotal`, which IS the chargeable pre-tax subtotal the server checks —
  /// nothing summed here.
  static double value(Map? bill) => _r2(_num(bill?['subtotal']));

  /// Dishes already comped one by one on this bill (`nc_total`).
  static double alreadyComped(Map? bill) => _r2(_num(bill?['nc_total']));

  /// Everything the bill will have given away once settled as NC.
  static double givenAway(Map? bill) => _r2(value(bill) + alreadyComped(bill));

  /// What the guest would have paid today — information only, in no report.
  static double wouldHaveCharged(Map? bill) => _r2(_num(bill?['grand_total']));

  /// Should the sheet OPEN in NC mode? A ₹0 bill whose dishes were all comped
  /// is an NC bill already; offering UPI for it is how installed 2.0.0 tills
  /// booked fully comped tables as ₹0 UPI bills.
  static bool opensAsNc(Map? bill) =>
      bill != null && (_num(bill['grand_total']) * 100).round() == 0 && (alreadyComped(bill) * 100).round() > 0;

  /// Why the NC pill is not available right now, or null. The SERVER decides
  /// (these are its refusals, read again inside its transaction); this only
  /// stops a manager filling in a form the server will refuse, and says why.
  /// Same order and the same sentences as ncSettleRefusal.
  static String? blocker({
    required Map? bill,
    required double tendered,
    required int drafts,
    required String Function(double) money,
  }) {
    if (bill == null) return 'The bill could not be read, so it cannot be settled as non-chargeable from here.';
    if ('${bill['payment_status'] ?? ''}' == 'pending_approval') {
      return 'A payment for this bill is already waiting for approval. Approve it, or re-open the bill afterwards — settling it as non-chargeable now would erase money already taken.';
    }
    if (_r2(tendered) > 0) {
      return '${money(_r2(tendered))} is already recorded as paid on this bill. Void that payment first, or comp dishes individually and take the rest.';
    }
    if (drafts > 0) return kNcWholeBillOnly;
    if (_num(bill['discount']) > 0 || _num(bill['discount_value']) > 0 || '${bill['coupon_code'] ?? ''}'.trim().isNotEmpty) {
      return 'This bill carries a discount or a coupon. Remove it first — a comped bill has nothing to discount.';
    }
    // A table whose every dish was already comped still settles here, at 0.00.
    if (value(bill) <= 0 && alreadyComped(bill) <= 0) return 'There is nothing on this table to settle.';
    return null;
  }

  /// Is the form complete? Kind, reason AND authoriser — the reason stays
  /// required for a whole-bill NC.
  static bool formReady({required String kind, required String reason, required String authorisedBy}) =>
      kind.trim().isNotEmpty && reason.trim().isNotEmpty && authorisedBy.trim().isNotEmpty;

  /// What POST /bills/order/:orderId/settle-nc is sent. Never an amount.
  static Map<String, dynamic> body({
    required String kind,
    required String reason,
    required String authorisedBy,
    required double expectedValue,
    String counterId = '',
    bool print = true,
  }) =>
      {
        'nc_kind': kind.trim(),
        'reason': reason.trim(),
        'authorised_by': authorisedBy.trim(),
        'expected_value': _r2(expectedValue),
        'print': print,
        if (counterId.trim().isNotEmpty) 'counter_id': counterId.trim(),
      };

  /// The sheet's headline. The web dialog says the same.
  static String headline(double givenAway, String Function(double) money) =>
      'NOTHING TO PAY · ${money(givenAway)} given away';

  /// What the server answered, as the snackbar says it.
  static String doneSentence(Map r, String Function(double) money) {
    final no = '${r['bill_no'] ?? ''}'.trim();
    final bill = no.isEmpty ? 'The bill' : 'Bill $no';
    if (r['already'] == true) return '$bill was already settled as non-chargeable.';
    final head = '$bill was settled as non-chargeable — ${money(_num(r['nc_value']))} given away, nothing collected.';
    if (r['printed'] == true) return '$head The NC bill is printing.';
    final why = '${r['print_error'] ?? ''}'.trim();
    return why.isEmpty ? head : '$head The NC bill did not print: $why';
  }

  // ---- reading the figures back --------------------------------------------

  /// The Overview's `today_nc`, or null — absent, unlabelled, or nothing today.
  static ({String label, String hint, int bills, double value})? headlineNc(Map? h) {
    final raw = h?['today_nc'];
    if (raw is! Map) return null;
    final label = '${raw['label'] ?? ''}'.trim();
    if (label.isEmpty) return null;
    final bills = _num(raw['bills']).round();
    final value = _r2(_num(raw['value']));
    if (bills == 0 && value == 0) return null;
    return (label: label, hint: '${raw['hint'] ?? ''}'.trim(), bills: bills, value: value);
  }

  /// "2 NC bills · ₹1,200.00 given away" — the line both clients print beside
  /// the figures, never inside them.
  static String besideLine(int bills, double value, String Function(double) money) =>
      '$bills NC bill${bills == 1 ? '' : 's'} · ${money(value)} given away';

  /// Sales Summary totals' `nc_bills` / `nc_value`, or null when there are none.
  static ({int bills, double value})? salesSummary(Map? totals) {
    final bills = _num(totals?['nc_bills']).round();
    final value = _r2(_num(totals?['nc_value']));
    return bills == 0 && value == 0 ? null : (bills: bills, value: value);
  }

  /// Settlement Summary `totals.nc`, or null when there are none.
  static ({int bills, double value})? settlementSummary(Map? totals) {
    final nc = totals?['nc'];
    if (nc is! Map) return null;
    final bills = _num(nc['bills']).round();
    final value = _r2(_num(nc['value']));
    return bills == 0 && value == 0 ? null : (bills: bills, value: value);
  }

  /// NC Summary `by_scope`, with the empty scopes dropped.
  static List<({String scope, String label, int entries, double loss})> byScope(Map? payload) {
    final raw = payload?['by_scope'];
    if (raw is! List) return const [];
    return [
      for (final s in raw)
        if (s is Map &&
            '${s['label'] ?? ''}'.trim().isNotEmpty &&
            (_num(s['entries']).round() > 0 || _r2(_num(s['loss'])) != 0))
          (
            scope: '${s['scope'] ?? ''}',
            label: '${s['label']}'.trim(),
            entries: _num(s['entries']).round(),
            loss: _r2(_num(s['loss'])),
          ),
    ];
  }

  /// A closed bill's `nc_settlement`, or null for every bill not settled as NC.
  static ({String kind, String authorisedBy, String reason, double value, double? wouldHaveCharged})? settlement(
      Map? bill) {
    if (bill == null || !isMethod(bill['payment_method'])) return null;
    final s = bill['nc_settlement'];
    if (s is! Map) return null;
    final w = s['would_have_charged'];
    return (
      kind: '${s['kind_label'] ?? ''}'.trim(),
      authorisedBy: '${s['authorised_by'] ?? ''}'.trim(),
      reason: '${s['reason'] ?? ''}'.trim(),
      value: _r2(_num(s['value'])),
      wouldHaveCharged: w == null || double.tryParse('$w') == null ? null : _r2(_num(w)),
    );
  }

  /// A bill line's name as the paper prints it: `"<name> (NC)"` for a comped one.
  static String lineLabel(String name, Object? nc) => nc == true ? '$name (NC)' : name;

  /// The Amount a line prints: 0 for a comped one, so the column adds up to the
  /// Sub Total under it.
  static double lineAmount(double price, double qty, Object? nc) => nc == true ? 0 : _r2(price * qty);

  /// "NC value (not charged)" under the total: the comped lines at the quantity
  /// and price they print at (escpos.ts). Null when nothing is comped.
  static double? paperNcValue(List items) {
    var v = 0.0;
    for (final it in items) {
      if (it is! Map || it['nc'] != true) continue;
      final q = _num(it['quantity'] ?? 1).round();
      v += _num(it['price']) * (q < 1 ? 1 : q);
    }
    return (v * 100).round() > 0 ? v : null;
  }
}
