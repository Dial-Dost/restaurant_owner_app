// REQUIREMENT 6.5 — the name on a running table's bill, changed from the table
// sheet: "Allow users to update or change the customer's name on the bill
// directly within the dashboard."
//
// The web has had this since H6 ("Change name on bill…" in bill-actions.tsx);
// the app did not, because nothing here called POST /bills/customer-name. This
// mirrors the web's dialog rule for rule — seeded with the current name, an
// empty box CLEARS it, 120 characters at most — so the two tills cannot
// disagree about what a name is.
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

/// The button's label: the verb, and the name already on the bill when there
/// is one — the way "Coupon: SAVE10" says what the coupon button would change.
/// A long name is shortened for the button only; the dialog shows all of it.
String _billCustomerNameLabel(Map bill) {
  final name = billCustomerNameSeed(bill['customer']);
  if (name.isEmpty) return 'Edit guest name';
  final short = name.length > 24 ? '${name.substring(0, 23)}…' : name;
  return 'Edit guest name · $short';
}

/// Asks for the name. Answers the NORMALISED name to save ('' clears it), or
/// null when the dialog was dismissed.
Future<String?> _askBillCustomerName(BuildContext context, {required String tableName, required Object? current}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _BillCustomerNameDialog(tableName: tableName, initial: billCustomerNameSeed(current)),
    );

class _BillCustomerNameDialog extends StatefulWidget {
  const _BillCustomerNameDialog({required this.tableName, required this.initial});

  final String tableName;
  final String initial;

  @override
  State<_BillCustomerNameDialog> createState() => _BillCustomerNameDialogState();
}

class _BillCustomerNameDialogState extends State<_BillCustomerNameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, normaliseBillCustomerName(_ctrl.text));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Name on bill · Table ${widget.tableName}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const ValueKey('bill-customer-name-field'),
          controller: _ctrl,
          autofocus: true,
          // Enforced, not advisory: a pasted paragraph is cut at the limit in
          // the box, where the person can see it, not silently on the server.
          maxLength: billCustomerNameMaxLength,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'Guest name',
            hintText: 'e.g. Mr Sharma',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 4),
        // Said plainly because the behaviour is not obvious: the name is stored
        // on every running order, so it changes the whole table's bill, and a
        // settled bill is refused by the server.
        Text(
          'This is the name printed at the top of the bill. It applies to the whole '
          'table, and can be changed until the bill is settled. Leave it empty to '
          'print no name.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]),
      actions: [
        TextButton(
          key: const ValueKey('bill-customer-name-clear'),
          onPressed: () => _ctrl.clear(),
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
