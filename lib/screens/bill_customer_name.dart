// REQUIREMENT 6.5 — the name on a running table's bill, changed from the table
// sheet: "Allow users to update or change the customer's name on the bill
// directly within the dashboard."
//
// ROUND 2, ITEM 1 — "This also includes customer GST number for corporate
// parties. This option has to come in the past bills section in accounting and
// in live tables where on top of a clicked table these details can be updated."
// So the ONE dialog here now carries a second, optional box — the customer's
// GSTIN — and is reached from two places: the top of a live table's sheet
// (POST /bills/customer-name) and a settled bill in Accounting (POST
// /bills/:billId/customer-details). One dialog, not two, so the two entry points
// cannot disagree about what a valid GSTIN is.
//
// The web has had the name since H6 ("Change name on bill…" in
// bill-actions.tsx); the app did not, because nothing here called POST
// /bills/customer-name. This mirrors the web's dialog rule for rule — seeded
// with the current name, an empty box CLEARS it, 120 characters at most — so the
// two tills cannot disagree about what a name is.
//
// A PART of modules.dart for the reason table_kots.dart is one: the gate is the
// same `_holdsAction` / `_permAddOrders` pair the sheet's other bill writes go
// through, and a copied permission check is how one control drifts from the
// server's.
part of 'modules.dart';

/// The longest name the server keeps. SetBillCustomerName slices at 120 — "the
/// printed header's practical width at 32 columns with wrapping" — and the web
/// field carries the same `maxLength`, so the box refuses the 121st character
/// rather than letting somebody type a name the paper will cut short.
const int billCustomerNameMaxLength = 120;

/// What the name box opens with, given the bill's `customer`.
///
/// SEEDED WITH THE CURRENT NAME rather than opening blank, because the common
/// case is fixing a typo and an empty box invites retyping the whole thing. The
/// two placeholders the server writes when nobody typed a name ("Guest" from
/// AddOrder, "QR Guest" from the guest QR flow) are NOT seeded back — that is
/// what the bill says when it has no name, not a name. Same rule as the web.
String billCustomerNameSeed(Object? customer) {
  final current = (customer ?? '').toString().trim();
  return RegExp(r'^(guest|qr guest)$', caseSensitive: false).hasMatch(current) ? '' : current;
}

/// The name as the server will store it: trimmed, inner runs of whitespace
/// collapsed to one space, capped at [billCustomerNameMaxLength]. The server
/// does exactly this again; doing it here too means the snackbar names what the
/// paper will actually print. Empty means "clear the name".
String normaliseBillCustomerName(String raw) {
  final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return name.length > billCustomerNameMaxLength ? name.substring(0, billCustomerNameMaxLength) : name;
}

/// ROUND 2 ITEM 1 — the shape of an Indian GSTIN, exactly as the server checks
/// it: two-digit state code, the ten-character PAN, entity number, `Z`, check
/// character. The server is the authority; this copy exists so the box can say
/// "that is not a GSTIN" before a round trip, never to accept something the
/// server would refuse.
final RegExp billCustomerGstinPattern = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

/// The server's own sentence for a malformed GSTIN, word for word, so the box
/// and a server refusal read the same.
const String billCustomerGstinInvalidMessage = 'GSTIN must be 15 characters, e.g. 29ABCDE1234F1Z5';

/// The GSTIN as the server will store it: trimmed, upper-cased, every space
/// removed (people paste it off an invoice as "29 ABCDE 1234F 1Z5"). Empty means
/// "clear the GSTIN".
String normaliseBillCustomerGstin(String raw) => raw.replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// Null when [raw] is acceptable — empty (which clears it) or a well-formed
/// GSTIN once normalised — otherwise [billCustomerGstinInvalidMessage].
String? billCustomerGstinError(String raw) {
  final gstin = normaliseBillCustomerGstin(raw);
  if (gstin.isEmpty || billCustomerGstinPattern.hasMatch(gstin)) return null;
  return billCustomerGstinInvalidMessage;
}

/// THE CUSTOMER SLOT — the lines the client's printed bill carries in their own
/// ruled-off block, directly under the restaurant header (logo, name, legal
/// entity, address, phone, GSTN) and ABOVE the date / cashier / bill-no block:
/// `Name: <name>` always, worded as the client's bill words it, and
/// `Customer GSTIN: <gstin>` directly under it, only when one is set.
///
/// A WALK-IN LEAVES THE SLOT BLANK — a bare `Name:` — because that is what the
/// client's bill does and what escpos.ts now prints. "Guest" and "QR Guest" are
/// the placeholders the ordering flows store for "nobody gave a name"
/// ([billCustomerNameSeed] reads both as empty); printed, either reads as a
/// name somebody wrote down. The thermal renderer, the app bill preview and the
/// settled-bill sheet all draw exactly these, in this order.
///
/// A stored "null" / "undefined" is no value either — escpos.ts `present()`
/// drops both before printing, so the slip never says "Name: null".
List<String> billCustomerLines(Map bill) {
  String present(String s) => RegExp(r'^(null|undefined)$', caseSensitive: false).hasMatch(s) ? '' : s;
  final name = present(billCustomerNameSeed(bill['customer']));
  final gstin = present('${bill['customer_gstin'] ?? ''}'.trim());
  return [
    name.isEmpty ? 'Name:' : 'Name: $name',
    if (gstin.isNotEmpty) 'Customer GSTIN: $gstin',
  ];
}

/// MAY THIS READER CHANGE THE NAME — the same two gates the sheet's coupon sits
/// behind, and one more.
///
///   * [FloorScope.billOps], the role half, which is exactly how the coupon,
///     discount, split and merge are gated. A scoped waiter does not get it —
///     and neither does the web's waiter, whose orders row draws Print Bill and
///     nothing from BillActions.
///   * "Add Orders" (`_permAddOrders`), the action POST /bills/customer-name is
///     validated on, and deliberately the SAME one the coupon route is: it is
///     what lets this person type the name when the order is placed, so it is
///     what lets them correct it. Hidden without it, rather than drawn as a
///     button that 403s.
bool _mayEditBillCustomerName(Profile p, FloorScope scope) =>
    scope.billOps && _holdsAction(p, _permAddOrders);

/// ROUND 2 ITEM 1 — MAY THIS READER CHANGE THE NAME / GSTIN ON A SETTLED BILL.
///
/// Exactly the gate "Reprint bill" on the same bill sits behind, because POST
/// /bills/:billId/customer-details is validated on exactly the permission POST
/// /print/bill/settled is (the contract says so). Correcting who a settled bill
/// was for and reprinting it are one errand; a person who could do one and not
/// the other would be stuck halfway through it. Null on a read-only surface.
bool _maySetSettledBillCustomer(Profile? p) => _mayReprintSettledBill(p);

/// What the dialog answers: the NORMALISED name ('' clears it) and the
/// NORMALISED GSTIN ('' clears it).
typedef BillCustomerDetails = ({String customer, String gstin});

/// Asks for the name and GSTIN. Null when the dialog was dismissed.
Future<BillCustomerDetails?> _askBillCustomerDetails(
  BuildContext context, {
  required String title,
  required String explanation,
  required Object? currentName,
  required Object? currentGstin,
}) =>
    showDialog<BillCustomerDetails>(
      context: context,
      builder: (_) => _BillCustomerNameDialog(
        title: title,
        explanation: explanation,
        initialName: billCustomerNameSeed(currentName),
        initialGstin: '${currentGstin ?? ''}'.trim(),
      ),
    );

/// The sentence a failed save shows. [settled] picks the route the sentence
/// talks about.
///
///   * Offline: /bills is never queued (see OutboxPolicy.billing), and that
///     family's sentence is about settling. This is not a settle, so say what it
///     is.
///   * 404 on the live route is the ROUTE missing, not the table (that is a 400
///     with its own sentence): the API is a release behind the app. On the
///     settled route a 404 is also how the server says "Bill not found", which
///     is the server's sentence and shown as such.
///   * Everything else — a malformed GSTIN (400), the column not migrated yet
///     (503), a waiter refused (403) — is the server's own sentence, verbatim.
String _billCustomerDetailsFailure(Object e, {required bool settled}) {
  if (e is OfflineUnavailable) {
    return 'Changing the name on a bill needs a connection — reconnect and try again.';
  }
  if (e is ApiException && e.status == 404 && !(settled && e.message.toLowerCase().contains('bill not found'))) {
    return settled
        ? 'This server has not finished updating, so the name and GSTIN on a settled bill cannot be changed '
            'from here yet. Ask your administrator to complete the update.'
        : 'This server has not finished updating, so the name cannot be changed from here yet. '
            'Ask your administrator to complete the update.';
  }
  return '$e';
}

class _BillCustomerNameDialog extends StatefulWidget {
  const _BillCustomerNameDialog({
    required this.title,
    required this.explanation,
    required this.initialName,
    required this.initialGstin,
  });

  final String title;
  final String explanation;
  final String initialName;
  final String initialGstin;

  @override
  State<_BillCustomerNameDialog> createState() => _BillCustomerNameDialogState();
}

class _BillCustomerNameDialogState extends State<_BillCustomerNameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialName);
  late final TextEditingController _gstinCtrl = TextEditingController(text: widget.initialGstin);

  /// Shown only once Save has been tried, and cleared as soon as the box is
  /// edited: a GSTIN is typed a character at a time, and every one of the first
  /// fourteen is "wrong".
  String? _gstinError;

  @override
  void dispose() {
    _ctrl.dispose();
    _gstinCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final error = billCustomerGstinError(_gstinCtrl.text);
    if (error != null) {
      setState(() => _gstinError = error);
      return;
    }
    Navigator.pop<BillCustomerDetails>(
      context,
      (customer: normaliseBillCustomerName(_ctrl.text), gstin: normaliseBillCustomerGstin(_gstinCtrl.text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const ValueKey('bill-customer-name-field'),
            controller: _ctrl,
            autofocus: true,
            // Enforced, not advisory: a pasted paragraph is cut at the limit in
            // the box, where the person can see it, not silently on the server.
            maxLength: billCustomerNameMaxLength,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Guest name',
              hintText: 'e.g. Mr Sharma',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          // ROUND 2 ITEM 1 — optional, and said to be: most tables are not a
          // corporate party, and a required-looking box gets filled with junk.
          TextField(
            key: const ValueKey('bill-customer-gstin-field'),
            controller: _gstinCtrl,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            // Upper-cased as it is typed, so what is on screen is what is saved.
            inputFormatters: [
              TextInputFormatter.withFunction((_, next) => next.copyWith(text: next.text.toUpperCase())),
            ],
            onChanged: (_) {
              if (_gstinError != null) setState(() => _gstinError = null);
            },
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: 'Customer GSTIN (optional)',
              hintText: 'e.g. 29ABCDE1234F1Z5',
              helperText: 'For corporate parties. Leave empty for none.',
              errorText: _gstinError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          // Said plainly because the behaviour is not obvious — see the callers.
          Text(widget.explanation, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('bill-customer-name-clear'),
          onPressed: () {
            _ctrl.clear();
            _gstinCtrl.clear();
            setState(() => _gstinError = null);
          },
          child: const Text('Clear'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('bill-customer-name-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// ROUND 2 ITEM 1 — "Edit name / GSTIN" on a SETTLED bill in Accounting.
///
/// POST /bills/:billId/customer-details changes the name and GSTIN and NOTHING
/// ELSE — no money, no status, no timestamps; the server writes the audit line.
/// [onSaved] gets the server's answer so the caller can repaint the row or
/// re-read the sheet; nothing here assumes what the server stored.
///
/// [compact] draws an icon for the list row; otherwise a labelled button for the
/// bill's own sheet, beside "Reprint bill".
class _EditSettledBillCustomerButton extends StatefulWidget {
  final RestClient rest;
  final Map bill;
  final Profile? profile;
  final bool compact;
  final void Function(Map<String, dynamic> saved) onSaved;

  const _EditSettledBillCustomerButton({
    super.key,
    required this.rest,
    required this.bill,
    required this.profile,
    required this.onSaved,
    this.compact = false,
  });

  @override
  State<_EditSettledBillCustomerButton> createState() => _EditSettledBillCustomerButtonState();
}

class _EditSettledBillCustomerButtonState extends State<_EditSettledBillCustomerButton> {
  bool _sending = false;

  Future<void> _edit() async {
    // Captured before any await — see [_ReprintSettledBillButtonState._send].
    final messenger = ScaffoldMessenger.of(context);
    final billId = _s(widget.bill, 'id', '');
    if (billId.isEmpty) return;
    final no = _s(widget.bill, 'bill_no', '');
    final details = await _askBillCustomerDetails(
      context,
      title: no.isEmpty ? 'Name / GSTIN on this bill' : 'Name / GSTIN on Bill #$no',
      explanation: 'This bill is settled. Only the name and GSTIN printed on it change — never its '
          'amounts or payment. Reprint it afterwards for a corrected copy.',
      currentName: widget.bill['customer'],
      currentGstin: widget.bill['customer_gstin'],
    );
    if (details == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final res = await widget.rest.post('/bills/${Uri.encodeComponent(billId)}/customer-details', {
        'customer': details.customer,
        'customer_gstin': details.gstin.isEmpty ? null : details.gstin,
      });
      // The server's answer when it gave one: it normalises again (an empty
      // name comes back as "Guest").
      final saved = <String, dynamic>{
        'customer': res is Map && res.containsKey('customer')
            ? res['customer']
            : (details.customer.isEmpty ? 'Guest' : details.customer),
        'customer_gstin': res is Map && res.containsKey('customer_gstin')
            ? res['customer_gstin']
            : (details.gstin.isEmpty ? null : details.gstin),
      };
      widget.onSaved(saved);
      messenger.showSnackBar(SnackBar(
          content: Text(no.isEmpty ? 'Name and GSTIN updated on the bill.' : 'Name and GSTIN updated on Bill #$no.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_billCustomerDetailsFailure(e, settled: true))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A UI convenience only — the route re-checks the permission itself.
    if (!_maySetSettledBillCustomer(widget.profile)) return const SizedBox.shrink();
    if (widget.compact) {
      return IconButton(
        tooltip: 'Edit name / GSTIN',
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.person_outline, size: 18, color: AppColors.textSecondary),
        onPressed: _sending ? null : _edit,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: OutlinedButton.icon(
        onPressed: _sending ? null : _edit,
        icon: const Icon(Icons.person_outline, size: 18),
        label: Text(_sending ? 'Saving…' : 'Edit name / GSTIN'),
      ),
    );
  }
}
