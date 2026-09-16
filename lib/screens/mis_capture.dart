// CAPTURE — the screens that WRITE what the last six reports read.
//
// Migrations 034-039 gave this system six new facts to record: a comped dish, a
// void's reason, a denied service charge, the tenders (and tips) a bill was paid
// with, the till that rang it, and a menu's groups and price points. Every one
// of them had a route and no way for a restaurant to reach it. This file is that
// way, on Windows and on the phone alike.
//
// WHY A `part` OF modules.dart. Same reason as reports.dart: a comp is taken on
// the TABLE SHEET, a void on the ORDER card, a tender on the SETTLE dialog and a
// price point on the MENU tile — four screens that already exist in this library
// and share its private helpers (`_money`, `_s`, `_int`, `_fmtTime`,
// `_holdsAction`, `_confirm`). Reaching them from a separate library would mean
// copying those, and a bill total formatted two different ways on two screens of
// one till is exactly the class of bug this pack exists to catch.
//
// ============================================================================
// THE THREE RULES THIS FILE IS BUILT ON
// ============================================================================
//
// 1. THE ACTOR IS THE SESSION, NEVER A FIELD. Every capture route takes
//    `marked_by` / `voided_by` / `waived_by` / `settled_by` from the verified
//    token. There is no form in this file with an "acting user" input, and there
//    must never be one: a till that could name its own cashier could sign
//    someone else's comp. `authorised_by` IS a field — it is the SECOND name,
//    the one the control exists for — and it is pre-filled with the signed-in
//    user's own username because a manager acting alone is a real and named
//    case, not a loophole. The server resolves it against the staff list and
//    checks that person holds the same permission, so a typed name that means
//    nothing is a 400 rather than a signature.
//
// 2. NOTHING HERE QUEUES. Every route this file posts to is refused by
//    OutboxPolicy while the line is down — the `/bills/*` family with the
//    BILLING sentence, the rest with the generic one — and none of them is on
//    the 27-route allowlist, because none of them carries `idempotent()` on the
//    server. That is deliberate on both sides and the allowlist is untouched: a
//    queued comp means the printed bill says one total and the server later says
//    another, and a queued tender is a payment that lands into tomorrow's shift.
//    The offline answer for money is "refuse now", and `_captureError` renders
//    exactly the refusal the policy produced.
//
// 3. A CONTROL THAT WOULD 403 IS NOT SHOWN. The three manager acts default to
//    manager-only, so every entry point checks `_holdsAction` first and a waiter
//    sees either nothing at all or a disabled control that SAYS why. A live
//    floor learning about a permission from a red toast at the till is how staff
//    stop trusting a screen.
part of 'modules.dart';

// ---------------------------------------------------------- the gates --------
//
// The Action ids the server actually validates, copied from routes/_shared.ts.
// A wrong id here costs an affordance, never a boundary: the server re-checks
// every one of these and refuses regardless of what this app decided to draw.

/// "Mark Items Non-Chargeable (Bills)" — PERM_NON_CHARGEABLE.
const String _permNonChargeable = 'b4e7a1c9-2d58-4f36-9a07-5c81e3b0d472';

/// "Void Orders With Reason (Orders)" — PERM_VOID_ORDER.
const String _permVoidOrder = 'c1f83b26-5a97-4e40-b8d3-7e02a9c4f156';

/// "Waive Service Charge (Bills)" — PERM_SERVICE_CHARGE_WAIVER.
const String _permServiceChargeWaiver = 'd5a06e73-9c41-4b28-8f6a-1b74d3e08c95';

/// The RECORD-PAYMENT action every tender / counter route is gated on. It is the
/// same one the settle already rides, which is why the payment screen is not a
/// new privilege: whoever can take money can record how it arrived.
const String _permRecordPayment = '2393edd7-cdd9-439c-9ff3-d563d5216967';

/// "Manage Restaurant Settings" — PERM_SETTINGS, which gates CREATING a till.
/// Deliberately asymmetric with reading them: a cashier picks their counter at
/// the start of a shift, an admin configures which counters exist.
const String _permSettings = '6d0f3a94-8b21-4c67-9e53-1a4d7b2f8c60';

/// PERM_EDIT_MENU — menu groups and variations are menu configuration.
const String _permEditMenu = 'ed800655-b937-44ba-a7ca-7458295886c9';

/// The sentence a control shows instead of failing on tap. Named per act
/// because "you don't have permission" tells a waiter nothing they can act on.
String _noPermission(String act) =>
    'Only a manager can $act. Ask one to sign in, or have them granted the permission.';

// ------------------------------------------------------- the vocabularies ----
//
// Mirrored from mis_capture.ts, which mirrors the migrations' own CHECK
// constraints. Sent as the machine value on the left; the label on the right is
// only ever displayed. A vocabulary that drifted would be a 400 naming values
// the user cannot see, so these lists are short, closed, and never free text.

const List<(String, String)> _ncKinds = [
  ('complimentary', 'Complimentary'),
  ('guest_complaint', 'Guest complaint'),
  ('staff_meal', 'Staff meal'),
  ('spoilage', 'Spoilage'),
  ('tasting', 'Tasting'),
  ('promo', 'Promotion'),
];

const List<(String, String)> _voidKinds = [
  ('wrong_entry', 'Wrong entry'),
  ('guest_changed_mind', 'Guest changed their mind'),
  ('kitchen_error', 'Kitchen error'),
  ('item_unavailable', 'Item unavailable'),
  ('duplicate', 'Duplicate ticket'),
  ('test_order', 'Test order'),
  ('other', 'Other'),
];

const List<(String, String)> _scWaiverKinds = [
  ('guest_request', 'Guest asked'),
  ('guest_complaint', 'Guest complaint'),
  ('goodwill', 'Goodwill'),
  ('staff_meal', 'Staff meal'),
  ('policy', 'House policy'),
  ('other', 'Other'),
];

/// How a tip physically arrived (037's `tip_mode` CHECK). Separate from the
/// tender's own method on purpose: cash left on the table against a card
/// payment is the ordinary case, not an anomaly.
const List<(String, String)> _tipModes = [
  ('cash', 'Cash'),
  ('card', 'On the card'),
  ('upi', 'UPI'),
  ('wallet', 'Wallet'),
  ('other', 'Other'),
];

/// 038's `kind` CHECK: a billing point, or a device that rings for one.
const List<(String, String)> _counterKinds = [
  ('counter', 'Counter'),
  ('terminal', 'Terminal'),
];

/// The literal "pool" is a first-class destination in 037 — tips are routinely
/// owed to a shared pot rather than to one named person.
const String _tipPool = 'pool';

// ------------------------------------------------------------- plumbing ------

/// The message to show for a failed capture write.
///
/// An [OfflineUnavailable] already carries the sentence OutboxPolicy chose (the
/// BILLING one for anything under /bills, the generic one otherwise), and that
/// sentence is better than anything this layer could invent — it says WHY the
/// line is needed. Everything else is the server's own refusal, which these
/// routes deliberately write to be read at a till.
String _captureError(Object e) {
  if (e is OfflineUnavailable) return e.message;
  if (e is OfflineQueued) {
    // Cannot happen — no capture route is on the outbox allowlist — but if the
    // policy ever changed underneath this file, say so rather than reporting a
    // write that has not landed as done.
    return 'That was saved to send later, which money writes must never be. '
        'Reconnect and check the bill before doing anything else.';
  }
  if (e is ApiException) return e.message;
  return '$e';
}

/// Whether a table's open bill has a service charge that could be taken off.
///
/// THE SERVER SAYS SO when it can: `service_charge_basis` is the resolver's own
/// answer to "which shape carries this outlet's charge", and "none" is the one
/// value that means there is nothing to remove. Guessing is what this used to
/// do, and guessing by NAME is a rule the two clients spelled differently from
/// the server.
///
/// THE FALLBACK IS FOR A BACKEND THAT PREDATES THE FIELD, and it reads both
/// shapes, because the fleet runs both: `Restaurant.service_charge` puts a
/// number in `service_charge`, while a "Service Charge" line inside
/// `Outlets.default_tax` puts it among the tax lines instead. Offering the
/// control on an outlet that charges neither would be a control that 400s.
bool _billHasServiceCharge(Map bill) {
  final basis = bill['service_charge_basis'];
  if (basis is String && basis.isNotEmpty) return basis != 'none';
  final direct = (num.tryParse('${bill['service_charge'] ?? 0}') ?? 0).toDouble();
  if (direct > 0) return true;
  for (final t in (bill['taxes'] as List?) ?? const []) {
    if (t is Map && _serviceChargeLineName.hasMatch('${t['name'] ?? ''}')) {
      final amt = (num.tryParse('${t['amount'] ?? 0}') ?? 0).toDouble();
      if (amt > 0) return true;
    }
  }
  return false;
}

/// Human label for a stored vocabulary value, falling back to the raw value
/// rather than to a blank: a row whose kind this build does not know about must
/// still say something an auditor can read.
String _vocabLabel(List<(String, String)> vocab, String value) {
  for (final (k, label) in vocab) {
    if (k == value) return label;
  }
  final t = value.trim();
  if (t.isEmpty) return '—';
  return t[0].toUpperCase() + t.substring(1).replaceAll('_', ' ');
}

// --------------------------------------------------- the second-name form ----

/// What one control act needs recorded: WHY (a closed vocabulary), IN WHOSE
/// WORDS (free text) and ON WHOSE SAY-SO (a resolved staff username).
typedef _CaptureReason = ({String kind, String reason, String authorisedBy});

/// The one form behind all three manager acts.
///
/// It is one widget rather than three because the three are one shape — kind,
/// reason, authoriser — and three copies would drift into three different ideas
/// of what a reason is. [kinds] is empty for a reversal, which needs no kind and
/// no second name (putting money BACK on a guest's bill is not the act the
/// control exists to catch, and requiring a second person to undo a mistake is
/// how mistakes get left standing).
class _CaptureReasonDialog extends StatefulWidget {
  const _CaptureReasonDialog({
    required this.title,
    required this.subtitle,
    required this.confirmLabel,
    required this.kinds,
    required this.needsAuthoriser,
    required this.suggestedAuthoriser,
    this.headline,
    this.danger = false,
    this.extra,
    this.reasonOptional = false,
  });

  final String title;
  final String subtitle;
  final String confirmLabel;

  /// The closed vocabulary. Empty = this act has no kind (a reversal).
  final List<(String, String)> kinds;

  /// False for a reversal — see the class header.
  final bool needsAuthoriser;

  /// The signed-in user's own username. Pre-filled, not forced: a manager acting
  /// alone signs their own name and the ledger then says so.
  final String suggestedAuthoriser;

  /// The money this act is about, shown large so it cannot be misread at a till.
  final String? headline;

  final bool danger;

  /// An extra control the caller needs inside the same form (the partial-comp
  /// quantity stepper). Rendered above the reason field.
  final Widget? extra;

  /// True ONLY for the service-charge waiver (client item, 2.0.1: "the reason
  /// should not be mandatory"). Its kind and its second name stay required; the
  /// comp, the void, the cancel, the tender void and every reversal keep a
  /// mandatory reason, which is why this is opt-in and defaults to false.
  final bool reasonOptional;

  @override
  State<_CaptureReasonDialog> createState() => _CaptureReasonDialogState();
}

class _CaptureReasonDialogState extends State<_CaptureReasonDialog> {
  late String _kind = widget.kinds.isEmpty ? '' : widget.kinds.first.$1;
  final TextEditingController _reason = TextEditingController();
  late final TextEditingController _authorisedBy =
      TextEditingController(text: widget.suggestedAuthoriser);

  @override
  void dispose() {
    _reason.dispose();
    _authorisedBy.dispose();
    super.dispose();
  }

  bool get _ready {
    if (widget.kinds.isNotEmpty && _kind.isEmpty) return false;
    if (!widget.reasonOptional && _reason.text.trim().isEmpty) return false;
    if (widget.needsAuthoriser && _authorisedBy.text.trim().isEmpty) return false;
    return true;
  }

  void _submit() {
    if (!_ready) return;
    Navigator.pop(context, (
      kind: _kind,
      reason: _reason.text.trim(),
      authorisedBy: _authorisedBy.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        // A fixed 420 overflows a 390px phone by 30px. Whatever the window
        // allows, capped at the desktop width.
        width: math.min(440, width - 32),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        // The fields scroll; Cancel and Confirm do not. On a 360dp phone this form
        // is taller than the screen, and with the buttons at the foot of the scroll
        // a waiver that needs no typing still needed a scroll before its one tap.
        // Pinned under the fields they stay on screen, above the keyboard too:
        // Dialog pads itself by the keyboard's height.
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(widget.title.toUpperCase(), style: text.labelSmall),
                if (widget.headline != null) ...[
                  const SizedBox(height: 6),
                  Text(widget.headline!,
                      style: text.displaySmall!.copyWith(
                          color: widget.danger ? AppColors.danger : AppColors.copperHi)),
                ],
                const SizedBox(height: 8),
                Text(widget.subtitle, style: text.bodySmall),
                if (widget.extra != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  widget.extra!,
                ],
                if (widget.kinds.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text('WHY', style: text.labelSmall),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final (value, label) in widget.kinds)
                      _CapturePill(
                        key: ValueKey('capture-kind-$value'),
                        label: label,
                        selected: _kind == value,
                        onTap: () => setState(() => _kind = value),
                      ),
                  ]),
                ],
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  key: const ValueKey('capture-reason'),
                  controller: _reason,
                  // The keyboard comes up for a reason the act cannot go without. The
                  // waiver's is optional and its commonest use is the kind as chosen, the
                  // name as filled, Confirm: on a phone a keyboard would only cover that.
                  autofocus: !widget.reasonOptional,
                  minLines: 2,
                  maxLines: 3,
                  maxLength: 400,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: widget.reasonOptional ? misOptionalReasonLabel : 'Reason',
                    alignLabelWithHint: true,
                    helperText: widget.reasonOptional
                        ? 'Optional. If you add one, it goes on the control report, verbatim.'
                        : 'In your own words. It goes on the control report, verbatim.',
                  ),
                ),
                if (widget.needsAuthoriser) ...[
                  const SizedBox(height: 4),
                  TextField(
                    key: const ValueKey('capture-authoriser'),
                    controller: _authorisedBy,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Authorised by (username)',
                      helperText: 'The staff member who approved it. Yours is filled in — '
                          'change it if someone else said yes.',
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // What this control IS and IS NOT, said plainly on the screen where
                  // the name is typed. It is not proof anyone was standing there;
                  // this system has no step-up credential and pretending otherwise
                  // would be a worse control than an honest one.
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, size: 13, color: AppColors.textTertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'The name is checked against your staff list and against this same '
                        'permission. Who is acting is taken from your own sign-in and cannot be typed.',
                        style: text.bodySmall!.copyWith(fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ),
                  ]),
                ],
              ]),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              ForkButton.ghost(label: 'Cancel', dense: true, onPressed: () => Navigator.pop(context)),
              ForkButton(
                key: const ValueKey('capture-confirm'),
                label: widget.confirmLabel,
                icon: Icons.check,
                dense: true,
                // Disabled until it could succeed, rather than posting a body
                // the server would refuse with a field name nobody typed.
                onPressed: _ready ? _submit : null,
              ),
            ],
          ),
        ]),
      ),
    );
  }
}

/// A selectable pill in the template's voice. Same shape as the settle dialog's
/// payment-method pill, which is the control staff already know.
class _CapturePill extends StatelessWidget {
  const _CapturePill({super.key, required this.label, required this.selected, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.tint(AppColors.copper) : AppColors.inset,
            borderRadius: AppRadius.controlAll,
            border: Border.all(
              color: selected ? AppColors.copper.withValues(alpha: 0.55) : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0.2,
              color: selected ? AppColors.copperHi : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A large −/+ stepper for "how many of this line". Deliberately not a text
/// field: this is a till control used under time pressure, and a keyboard for a
/// number between 1 and 4 is slower and easier to get wrong.
class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    super.key,
    required this.value,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final int value;
  final int max;
  final String label;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(), style: text.labelSmall),
      const SizedBox(height: 8),
      Row(children: [
        ForkIconButton(
          icon: Icons.remove,
          tooltip: 'One fewer',
          onPressed: value <= 1 ? null : () => onChanged(value - 1),
        ),
        SizedBox(
          width: 64,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: text.displaySmall!.copyWith(fontSize: 24, color: AppColors.copperHi)),
        ),
        ForkIconButton(
          icon: Icons.add,
          tooltip: 'One more',
          onPressed: value >= max ? null : () => onChanged(value + 1),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            value >= max ? 'The whole line' : 'The other ${max - value} stay on the bill',
            style: text.bodySmall,
          ),
        ),
      ]),
    ]);
  }
}

// ============================================================================
// 034 — NON-CHARGEABLE: comp a dish off what the guest pays
// ============================================================================

/// Open the comp sheet for a table (or for one order).
///
/// WHY IT WORKS OFF `/orders` AND NOT OFF THE BILL. The comp route addresses a
/// LINE — `POST /orders/:id/items/:itemId/non-chargeable` — and `/bill-for-table`
/// deliberately MERGES lines by name+price+nc+variation for printing, so its
/// items carry no ids at all. Comping "the merged Gulab Jamun x3" is not a thing
/// this schema can express; comping one line of one order is. So this sheet
/// shows the ORDERS behind the bill, which is also the level a manager thinks at
/// ("the dessert on the second round was on the house").
Future<void> misOpenComps(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  String tableName = '',
  List<String> orderIds = const [],
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: _NonChargeableSheet(
          rest: rest,
          profile: profile,
          tableName: tableName,
          orderIds: orderIds,
          onChanged: onChanged,
        ),
      ),
    ),
  );
}

class _NonChargeableSheet extends StatefulWidget {
  const _NonChargeableSheet({
    required this.rest,
    required this.profile,
    required this.tableName,
    required this.orderIds,
    this.onChanged,
  });

  final RestClient rest;
  final Profile profile;
  final String tableName;
  final List<String> orderIds;
  final VoidCallback? onChanged;

  @override
  State<_NonChargeableSheet> createState() => _NonChargeableSheetState();
}

class _NonChargeableSheetState extends State<_NonChargeableSheet> {
  /// The live orders this sheet can comp from.
  List<Map> _orders = const [];

  /// order id -> the comps recorded against it, from the manager-gated read.
  final Map<String, List<Map>> _comps = {};

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _may => _mayDo(widget.profile, Capability.compItem, _permNonChargeable);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// A cancelled or settled order cannot be comped — MarkOrderItemNonChargeable
  /// refuses both, because a comp after the money has moved is a refund and
  /// refunds have their own path and their own columns.
  static bool _compable(Map o) {
    final s = _s(o, 'status', '').toLowerCase();
    return s != 'cancelled' && s != 'paid' && s != 'closed';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = await widget.rest.getList('/orders');
      final wanted = widget.orderIds.toSet();
      final mine = <Map>[
        for (final o in all)
          if (o is Map &&
              _compable(o) &&
              (wanted.isEmpty
                  ? _s(o, 'table', '') == widget.tableName
                  : wanted.contains('${o['id']}')))
            o,
      ];
      // The control data — reason, authoriser, and the ledger id a reversal
      // needs — is a SEPARATE, manager-gated read per order. Best-effort per
      // order so one failure does not blank the whole sheet.
      final comps = <String, List<Map>>{};
      if (_may) {
        for (final o in mine) {
          final id = '${o['id']}';
          try {
            final m = await widget.rest.getMap('/orders/$id/non-chargeables');
            comps[id] = [
              for (final n in (m['non_chargeables'] as List?) ?? const [])
                if (n is Map) n,
            ];
          } catch (_) {/* the lines still render; only the ledger is missing */}
        }
      }
      if (!mounted) return;
      setState(() {
        _orders = mine;
        _comps
          ..clear()
          ..addAll(comps);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _captureError(e);
        _loading = false;
      });
    }
  }

  /// The LIVE comp on one line, or null. A reversed one is not live: the row
  /// stays in the ledger (supersession, never deletion) and the line is
  /// chargeable again, so the control must offer "Comp" and not "Reverse".
  Map? _liveComp(String orderId, String itemId) {
    for (final c in _comps[orderId] ?? const <Map>[]) {
      if ('${c['item_id']}' == itemId &&
          (c['reversed_at'] == null || '${c['reversed_at']}'.isEmpty)) {
        return c;
      }
    }
    return null;
  }

  Future<void> _comp(Map order, Map item) async {
    final messenger = ScaffoldMessenger.of(context);
    final qty = math.max(1, _int(item['quantity']) ?? 1);
    final price = _numOf(item['price']);
    final name = _s(item, 'name');
    // How MUCH of the line. Absent means the whole line; the data layer splits
    // it for a partial and leaves the ORIGINAL id on the chargeable remainder,
    // because prep timers and served state key on that id and belong to the food
    // being paid for.
    var take = qty;
    final answer = await showDialog<_CaptureReason>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => _CaptureReasonDialog(
          title: 'Non-chargeable',
          headline: _money(price * take),
          danger: true,
          subtitle: '$name · ${_money(price)} each. This comes OFF what the guest pays and '
              'stays ON the books as revenue given away — the NC Summary shows both.',
          confirmLabel: 'Comp it',
          kinds: _ncKinds,
          needsAuthoriser: true,
          suggestedAuthoriser: widget.profile.employeeUsername,
          extra: qty <= 1
              ? null
              : _QuantityStepper(
                  key: const ValueKey('capture-nc-qty'),
                  value: take,
                  max: qty,
                  label: 'How many of the $qty?',
                  onChanged: (v) => setLocal(() => take = v),
                ),
        ),
      ),
    );
    if (answer == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.rest.post(
        '/orders/${order['id']}/items/${item['id']}/non-chargeable',
        {
          'nc_kind': answer.kind,
          'reason': answer.reason,
          'authorised_by': answer.authorisedBy,
          // Omitted for a whole-line comp, so the server takes the whole line
          // rather than splitting it and leaving a remainder of zero.
          if (take < qty) 'quantity': take,
        },
      );
      messenger.showSnackBar(SnackBar(
          content: Text('$take × $name is non-chargeable — ${_money(price * take)} given away.')));
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse(Map comp) async {
    final messenger = ScaffoldMessenger.of(context);
    final answer = await showDialog<_CaptureReason>(
      context: context,
      builder: (_) => _CaptureReasonDialog(
        title: 'Put it back on the bill',
        headline: _money(comp['value']),
        subtitle: '${_s(comp, 'item_name')} becomes chargeable again. The original comp stays '
            'on the report, marked reversed — it is never deleted.',
        confirmLabel: 'Charge it again',
        // No kind and no second name: putting a charge BACK on a guest is not
        // the act the second-name control exists to catch, and requiring another
        // person to undo a mistake is how mistakes get left standing.
        kinds: const [],
        needsAuthoriser: false,
        suggestedAuthoriser: '',
      ),
    );
    if (answer == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.rest.post('/non-chargeables/${comp['id']}/reverse', {'reason': answer.reason});
      messenger.showSnackBar(
          SnackBar(content: Text('${_s(comp, 'item_name')} is chargeable again.')));
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final where = widget.tableName.isEmpty ? 'this order' : 'Table ${widget.tableName}';

    // The running total of what has been given away here — the number a manager
    // is accountable for, and the reason this sheet is not merely a list.
    var givenAway = 0.0;
    var comped = 0;
    for (final list in _comps.values) {
      for (final c in list) {
        if (c['reversed_at'] == null || '${c['reversed_at']}'.isEmpty) {
          givenAway += _numOf(c['value']);
          comped++;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('NON-CHARGEABLE', style: text.labelSmall),
              const SizedBox(height: 4),
              Text(where, style: text.headlineMedium),
            ]),
          ),
          if (comped > 0)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money(givenAway),
                  style: text.displaySmall!.copyWith(fontSize: 22, color: AppColors.danger)),
              Text('given away · $comped line${comped == 1 ? '' : 's'}', style: text.bodySmall),
            ]),
        ]),
        const SizedBox(height: AppSpacing.md),
        if (!_may)
          ForkCard(
            inset: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lock_outline, size: 16, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(_noPermission('comp a dish'), style: text.bodySmall)),
            ]),
          )
        else
          Text(
            'Comping takes the line off what the guest pays. It is still counted as revenue '
            'given away, with your name, the reason and the authoriser against it.',
            style: text.bodySmall,
          ),
        const SizedBox(height: AppSpacing.lg),
        Flexible(
          child: _loading
              ? const Center(
                  child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
              : _error != null
                  ? EmptyState(
                      icon: Icons.error_outline,
                      title: 'Could not load the lines',
                      caption: _error!,
                      action: ForkButton.ghost(
                          label: 'Retry', icon: Icons.refresh, dense: true, onPressed: _load),
                    )
                  : _orders.isEmpty
                      ? EmptyState(
                          icon: Icons.no_food_outlined,
                          title: 'Nothing to comp',
                          caption: '$where has no open order lines. A settled or cancelled order '
                              'cannot be comped — that is a refund, which has its own path.',
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [for (final o in _orders) _orderBlock(o)],
                        ),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: ForkButton.ghost(
            label: 'Done',
            dense: true,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ),
      ]),
    );
  }

  Widget _orderBlock(Map order) {
    final text = Theme.of(context).textTheme;
    final items = ((order['items'] as List?) ?? const []).whereType<Map>().toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(
          title: 'Order · ${_fmtTime(_s(order, 'created_at', ''))}',
          count: items.length,
          padding: const EdgeInsets.only(bottom: 8),
        ),
        for (final it in items) _lineRow(order, it),
        if (items.isEmpty) Text('This ticket carries no lines.', style: text.bodySmall),
      ]),
    );
  }

  Widget _lineRow(Map order, Map item) {
    final text = Theme.of(context).textTheme;
    final orderId = '${order['id']}';
    final itemId = '${item['id']}';
    final qty = math.max(1, _int(item['quantity']) ?? 1);
    final price = _numOf(item['price']);
    final live = _liveComp(orderId, itemId);
    final isComped = live != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ForkCard(
        inset: true,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$qty × ${_s(item, 'name')}',
                    style: text.titleSmall!.copyWith(
                      // Struck through only when it is genuinely off the bill,
                      // never as decoration: the strike IS the statement.
                      decoration: isComped ? TextDecoration.lineThrough : null,
                      color: isComped ? AppColors.textSecondary : null,
                    )),
                if (_s(item, 'variation', '').isNotEmpty)
                  Text(_s(item, 'variation'), style: text.bodySmall),
              ]),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(_money(price * qty),
                style: text.titleSmall!.copyWith(
                  color: isComped ? AppColors.textTertiary : null,
                  decoration: isComped ? TextDecoration.lineThrough : null,
                )),
          ]),
          if (isComped) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              StatusChip(
                label: 'NC · ${_vocabLabel(_ncKinds, _s(live, 'nc_kind', ''))}',
                color: AppColors.danger,
                dense: true,
              ),
              InfoChip(icon: Icons.currency_rupee, label: '${_money(live['value'])} given away'),
              InfoChip(
                  icon: Icons.verified_user_outlined,
                  label: 'By ${_s(live, 'authorised_by_username')}'),
            ]),
            const SizedBox(height: 6),
            Text('“${_s(live, 'reason')}” — marked by ${_s(live, 'marked_by_username')}',
                style: text.bodySmall!.copyWith(fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: isComped
                ? ForkButton.ghost(
                    key: ValueKey('nc-reverse-$itemId'),
                    label: 'Put it back on the bill',
                    icon: Icons.undo,
                    dense: true,
                    onPressed: (!_may || _busy) ? null : () => _reverse(live),
                  )
                : ForkButton(
                    key: ValueKey('nc-comp-$itemId'),
                    label: 'Make non-chargeable',
                    icon: Icons.card_giftcard,
                    dense: true,
                    onPressed: (!_may || _busy) ? null : () => _comp(order, item),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ============================================================================
// 035 — VOID WITH A REASON: why a rung-up order was killed
// ============================================================================

/// Void an order AND record why, in one transaction.
///
/// WHY THIS EXISTS BESIDE `PATCH /orders/:id/status → Cancelled` RATHER THAN
/// REPLACING IT. That route is what every shipped client calls, it is on the
/// offline allowlist, and requiring a reason and an authoriser on it would stop
/// a live floor from cancelling anything. So the rule is by PERMISSION, not by
/// screen: a user who holds "Void Orders With Reason" gets this form, because
/// they are exactly the person a control report needs a reason from; everyone
/// else keeps the fast path, and the Void KOT report goes on counting their
/// cancels with an "unknown" reason — visible, not silent.
///
/// `stage` (before_print / after_print / after_bill) is deliberately NOT a field
/// here and never will be: the server derives it from whether a bill exists,
/// whether the order was barked and whether a KOT printed, because the person
/// whose void it is has an obvious interest in it reading "before_print".
///
/// Returns true when the order was voided, false when the user backed out.
Future<bool> misVoidOrder(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  required String orderId,
  String what = 'this order',
  String value = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final answer = await showDialog<_CaptureReason>(
    context: context,
    builder: (_) => _CaptureReasonDialog(
      title: 'Void order',
      headline: value.isEmpty ? null : value,
      danger: true,
      subtitle: 'Voiding $what is final — it cannot be un-cancelled from this screen. '
          'The reason and both names go on the Void KOT report.',
      confirmLabel: 'Void it',
      kinds: _voidKinds,
      needsAuthoriser: true,
      suggestedAuthoriser: profile.employeeUsername,
    ),
  );
  if (answer == null) return false;
  try {
    await rest.post('/orders/$orderId/void', {
      'void_kind': answer.kind,
      'reason': answer.reason,
      'authorised_by': answer.authorisedBy,
    });
    messenger.showSnackBar(const SnackBar(content: Text('Order voided, with the reason recorded.')));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    return false;
  }
}

/// REQUIREMENT A2 — THE CANCELLATION PROMPT, FOR EVERYBODY ELSE.
///
/// WHAT WAS WRONG. A2 asks for "a mandatory confirmation prompt before
/// cancelling a KOT, requiring a cancellation reason before the action can be
/// processed". [misVoidOrder] above does exactly that — and only for the people
/// holding "Void Orders With Reason". Everybody else's cancel went out as a bare
/// `PATCH /orders/:id/status {status: 'Cancelled'}` with no prompt, no reason
/// and, until the slip existed, no paper. So the requirement was met for the one
/// role least likely to be the person standing at the table when a guest changes
/// their mind, and unmet for the role that does most of the cancelling.
///
/// WHY NOT SIMPLY SEND EVERY CANCEL THROUGH THE VOID ROUTE. Because POST
/// /orders/:id/void is deliberately outside the offline queue — it carries no
/// `idempotent()` guard on the server and is not on the outbox's 27-route
/// allowlist, for the reasons this file's rule 2 sets out. Routing every cancel
/// through it would mean that on a floor whose wifi has dropped, a cancellation
/// becomes impossible: the food keeps cooking, the line keeps growing, and the
/// only way out is to settle a bill for a dish nobody wants. A prompt that makes
/// the app unusable in the one situation it is most needed is not a control.
///
/// SO THE PROMPT IS UNCONDITIONAL AND THE ROUTE IS NOT. Everyone is asked, in
/// the same words, with the same closed vocabulary, before anything is sent. The
/// reason then travels on whichever route this user is entitled to use — the
/// strict void for those who hold it, the queueable status patch for everyone
/// else, which stays exactly as reliable as it is today.
///
/// WHAT THE WEAKER ROUTE CAN AND CANNOT PROMISE. `reason` and `cancel_kind` ride
/// on the PATCH body as additive fields. A server that has not been taught about
/// them ignores them and behaves precisely as it does now — the cancel still
/// works, the prompt is still mandatory in front of the waiter, and the Void KOT
/// report goes on recording "unknown" for it. A server that HAS been taught has
/// the reason for the cancellation slip's banner (dispatchCancellationKot
/// already takes one) and for the report. Neither state can make the cancel
/// fail, which is the property that lets this ship in front of the change.
///
/// Returns null when the user backed out — and backing out must cancel nothing.
Future<({String kind, String reason})?> misCancelReason(
  BuildContext context, {
  required String what,
  String value = '',
}) async {
  final answer = await showDialog<_CaptureReason>(
    context: context,
    builder: (_) => _CaptureReasonDialog(
      title: 'Cancel order',
      headline: value.isEmpty ? null : value,
      danger: true,
      subtitle: 'Cancelling $what stops the kitchen and takes it off the bill. '
          'A reason is required before it can be processed, and it is printed on '
          'the cancellation slip that goes to the pass.',
      confirmLabel: 'Cancel it',
      kinds: _voidKinds,
      // NO SECOND NAME HERE, and that is the difference between this and
      // [misVoidOrder]. An authoriser is a CONTROL on a privileged act; this is
      // the ordinary act a waiter performs at the table, and demanding a manager
      // for every changed mind would either stop service or train staff to type
      // their own name into a box that then means nothing. The reason is what A2
      // asked for; the second name is what the void permission is for.
      needsAuthoriser: false,
      suggestedAuthoriser: '',
    ),
  );
  if (answer == null) return null;
  return (kind: answer.kind, reason: answer.reason);
}

// ============================================================================
// 036 — SERVICE CHARGE WAIVER: take the charge off an open bill, and print it
// ============================================================================
//
// ONE CONTROL, NOT TWO (client item 6: "reprint without service charge and
// waive service charge should be merged as one option instead of being 2
// separate steps").
//
// Since the paper was made to equal the drawer, the RECORDED WAIVER is the only
// thing that takes the charge off a bill, so the old "Reprint (no service
// charge)" in the bill-ops row could not do its job on its own: its dialog sent
// the user to "Waive service charge" here, the waiver then ended without a
// print, and pressing the two in the wrong order spent a full-charge copy. On a
// live floor that was a refused print, a waiver and a reprint, 3 to 30 seconds
// apart, table after table.
//
// Both halves are now ONE server call, POST /bills/service-charge-waiver/print,
// which answers every refusal before it writes anything, records the waiver
// exactly as the waiver route does, and prints from the bill as it stands after
// that commit. This app decides nothing about money here: which of the two
// happened, and the totals either side, are the server's answer, read back.

/// The service charge on an open bill, in rupees, whichever shape carries it.
///
/// The HEADLINE of the removal form, and nothing else — never a figure the
/// guest is charged. `service_charge` is only the restaurant_percent leg and is
/// 0 on every tenant carrying the charge as a tax line (most of the fleet), so a
/// headline read from it alone showed nothing on exactly the bills people
/// remove the charge from. The tax-line leg is matched the way the server
/// matches it (`/service\s*charge/i`), so "ServiceCharge" counts too.
double misServiceChargeOnBill(Map bill) {
  var total = _numOf(bill['service_charge']);
  for (final t in (bill['taxes'] as List?) ?? const []) {
    if (t is Map && _serviceChargeLineName.hasMatch('${t['name'] ?? ''}')) {
      total += _numOf(t['amount']);
    }
  }
  return (total * 100).roundToDouble() / 100;
}

final RegExp _serviceChargeLineName = RegExp(r'service\s*charge', caseSensitive: false);

/// WHAT TO TELL SOMEBODY AFTER "Remove service charge & print", given what the
/// server did.
///
/// A pure function of the response, because the defect this family of messages
/// has already had once was a SENTENCE that disagreed with the paper — the
/// numbers were right and the snackbar promised a total the printer did not
/// produce. So every branch says only what the server reported:
///
///   * the waiver landed and the bill printed — the two payable totals;
///   * an existing waiver was reprinted — the total on the paper;
///   * the waiver landed and the PRINT FAILED — that the charge is off, that
///     no paper came out, and what to press, shown long enough to be read while
///     somebody is already walking to a printer that is not printing;
///   * the paper somehow carries the charge (the waiver was put back between
///     the commit and the print) — that, and never "removed".
///
/// The web dashboard's `serviceChargeRemovalSentence` says the same words.
({String message, Duration shown}) serviceChargeRemovalOutcome(Object? response) {
  final r = response is Map ? response : const {};
  final created = r['waiver_created'] == true;
  final printed = r['printed'] == true;
  final before = r['grand_total_before'];
  final after = r['grand_total_after'];
  final hasTotals = before != null && after != null;
  if (printed && r['service_charge_removed'] == false) {
    return (
      message: 'Printed WITH the service charge — the waiver was put back before the bill printed.',
      shown: const Duration(seconds: 8),
    );
  }
  if (!printed) {
    final why = '${r['print_error'] ?? ''}'.trim();
    final notPrinted = 'did not print${why.isEmpty ? '' : ': $why'}. Press Print bill.';
    // Only what the reply proves: a waiver it names is off the bill; a reply
    // that names none proves nothing about the charge, only about the paper.
    if (created && hasTotals) {
      return (
        message: 'Service charge removed (${_money(before)} → ${_money(after)}), but the bill $notPrinted',
        shown: const Duration(seconds: 8),
      );
    }
    return (
      message: created || r['waiver'] is Map
          ? 'The service charge is off this bill, but the bill $notPrinted'
          : 'The bill $notPrinted',
      shown: const Duration(seconds: 8),
    );
  }
  if (created && hasTotals) {
    return (
      message: 'Service charge removed — total ${_money(before)} → ${_money(after)}. Printing bill…',
      shown: const Duration(seconds: 4),
    );
  }
  return (
    message: after != null
        ? 'Reprinting without the service charge — total ${_money(after)}.'
        : 'Reprinting without the service charge…',
    shown: const Duration(seconds: 3),
  );
}

/// THE WAIVED CARD'S PRINT CONTROL AND ITS CONFIRMATION, in words that match the
/// paper that will come out.
///
/// The server stamps REPRINT on a bill only when its ledger already counts a
/// print of this seating's bill (`reprint: bill.print_count > 0` in
/// printOpenTableBill). A waiver can sit on a bill nobody has printed: an
/// installed 1.9.9 till's "Waive service charge" still records without
/// printing, and a removal whose print failed leaves the same state. The dialog
/// used to say "It is marked as a reprint" on exactly those bills, and the paper
/// came out without the banner — the sentence-disagrees-with-the-paper defect
/// [serviceChargeRemovalOutcome] exists to prevent.
///
/// So the words follow [serverBillPrintState]: only the server's `true` says
/// reprint and promises the banner. `false` and "no answer" say print, which is
/// true either way, and promise nothing about a banner. The web dashboard's
/// `serviceChargeWaivedPrintLabel` uses the same labels.
({String label, String title, String body, String confirm}) serviceChargeWaivedPrintCopy(Map bill) {
  if (serverBillPrintState(bill) == true) {
    return (
      label: 'Reprint without the charge',
      title: 'Reprint without the service charge?',
      body: 'The bill prints again with the recorded waiver applied — the total the guest pays. '
          'It is marked as a reprint.',
      confirm: 'Reprint',
    );
  }
  return (
    label: 'Print without the charge',
    title: 'Print without the service charge?',
    body: 'The bill prints with the recorded waiver applied — the total the guest pays.',
    confirm: 'Print',
  );
}

// ------------------------------------ the waiver's reason is optional (2.0.1) --
//
// "When waiving a service charge, the reason should not be mandatory and should
// be left as optional." The waiver's reason only: the kind (chosen already) and
// the authoriser stay required, and every other act on this file keeps its
// mandatory reason. The server stores a missing reason as NULL where migration
// 051 allows it, and refuses exactly as before where it does not.

/// The reason box's label on the waiver form. The web dashboard says the same.
const String misOptionalReasonLabel = 'Reason (optional)';

/// The body of POST /bills/service-charge-waiver/print for a new waiver.
///
/// A blank reason is left OUT, not sent as "": a server from before the change
/// refused "" in its schema with a sentence nobody could act on, while an
/// absent reason gets its own clean refusal.
Map<String, dynamic> serviceChargeRemovalBody({
  required String tableName,
  required String kind,
  required String reason,
  required String authorisedBy,
}) {
  final why = reason.trim();
  return <String, dynamic>{
    // The TABLE, not the bill id: WaiveServiceCharge resolves the table's open
    // bill and mints one when the table has none, which is the case a guest
    // asks about before the bill has been raised.
    'table_name': tableName,
    'waiver_kind': kind,
    if (why.isNotEmpty) 'reason': why,
    'authorised_by': authorisedBy,
  };
}

/// Who took the charge off, and why when they said: `“Long wait” — asha,
/// authorised by manager01`, or `asha, authorised by manager01` for a waiver
/// recorded without a reason — never a quoted dash standing in for one.
String serviceChargeWaiverAttribution(Map waiver) {
  final why = '${waiver['reason'] ?? ''}'.trim();
  final who = '${_s(waiver, 'waived_by_username')}, authorised by ${_s(waiver, 'authorised_by_username')}';
  return why.isEmpty ? who : '“$why” — $who';
}

/// The waiver block on the table sheet: either the one control that takes the
/// charge off and prints, or the live waiver with its reprint and the control
/// to put the charge back.
///
/// Nothing at all when this outlet charges no service charge — offering to
/// remove something that does not exist is a control that would 400 on tap.
Widget misServiceChargeBlock(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  required Map bill,
  required String tableName,
  required VoidCallback onChanged,
  /// Whether this reader may be shown the two rupee figures on the ALREADY-WAIVED
  /// card — what came off the charge, and the charge plus the tax on it.
  ///
  /// Defaults to true, so every existing caller behaves exactly as it did. The
  /// table sheet passes a waiter's `false`: item 19 takes the restaurant's money
  /// off their screen, and this card is the one place a waived amount survived
  /// the bill block being removed. Everything else here — the waiver kind, the
  /// reason, who waived it and who authorised it, and the inert "Put the charge
  /// back" control — is unaffected, because none of it is a figure.
  bool showsMoney = true,
}) {
  final text = Theme.of(context).textTheme;
  final may = _mayDo(profile, Capability.waiveServiceCharge, _permServiceChargeWaiver);
  final waiver = bill['service_charge_waiver'];
  final waived = bill['service_charge_waived'] == true && waiver is Map;

  if (!waived && !_billHasServiceCharge(bill)) return const SizedBox.shrink();

  if (waived) {
    final w = waiver;
    final printCopy = serviceChargeWaivedPrintCopy(bill);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: ForkCard(
        inset: true,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.money_off_csred_outlined, size: 16, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('Service charge waived — ${_vocabLabel(_scWaiverKinds, _s(w, 'waiver_kind', ''))}',
                  style: text.titleSmall),
            ),
          ]),
          if (showsMoney) ...[
            const SizedBox(height: 6),
            // BOTH numbers, because with GST on the charge they differ: the
            // charge itself came off, and so did the tax that rode on it.
            //
            // The second is NOT "off the total" (migration 048). It is measured
            // before round-off, while the total the guest pays is rounded to the
            // rupee, so the payable total can fall by a little more or less —
            // 577.40 of charge and tax took 6351 to 5774. The card has no rounded
            // totals to show (the record keeps the exact figure), so it says
            // what the figure is instead of what it is not.
            Text(
              '${_money(w['amount_waived'])} charge off · '
              '${_money(w['grand_total_reduction'])} with its tax, before round-off',
              style: text.bodyMedium,
            ),
          ],
          const SizedBox(height: 4),
          Text(serviceChargeWaiverAttribution(w),
              style: text.bodySmall!.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: 10),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            // THE REPRINT THAT USED TO LIVE IN THE BILL-OPS ROW, where it could
            // not take anything off. Here it can only ever reprint what the
            // waiver above already took off, so it needs no permission beyond
            // printing — the server reprints a waived bill for anyone who may
            // print it, and records no second waiver. "Reprint" or "Print" by
            // the server's print ledger: see serviceChargeWaivedPrintCopy.
            _ScBusyButton(
              key: const ValueKey('sc-reprint-without-charge'),
              label: printCopy.label,
              icon: Icons.print_outlined,
              run: () => _reprintWithoutServiceCharge(context,
                  rest: rest, tableName: tableName, copy: printCopy, onChanged: onChanged),
            ),
            ForkButton.ghost(
              key: const ValueKey('sc-waiver-reverse'),
              label: 'Put the charge back',
              icon: Icons.undo,
              dense: true,
              onPressed: !may
                  ? null
                  : () => _reverseServiceChargeWaiver(context,
                      rest: rest, waiverId: '${w['id']}', onChanged: onChanged),
            ),
          ]),
          if (!may)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_noPermission('put a waived service charge back'),
                  style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
            ),
        ]),
      ),
    );
  }

  return Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md),
    // A Wrap, not a Row: the label is longer than the one it replaced, and on a
    // 390dp phone a Row hands its button unbounded width to overflow into. The
    // sentence beside an inert control drops under it when there is no room.
    child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: AppSpacing.sm, runSpacing: 6, children: [
      _ScBusyButton(
        key: const ValueKey('sc-remove-and-print'),
        label: 'Remove service charge & print',
        icon: Icons.money_off_csred_outlined,
        // Disabled rather than hidden: a cashier or captain needs to know the
        // control EXISTS so they fetch a manager, instead of arguing with a
        // guest about a screen that appears to have no such option.
        run: !may
            ? null
            : () => _removeServiceChargeAndPrint(context,
                rest: rest,
                profile: profile,
                bill: bill,
                tableName: tableName,
                onChanged: onChanged),
      ),
      if (!may)
        Text(_noPermission('remove a service charge'),
            style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
    ]),
  );
}

/// A ghost button that is inert while its own action runs.
///
/// Both service-charge actions post a request that PRINTS, and a second tap
/// while the first is on the wire is a second copy of the guest's bill marked
/// REPRINT. The server cannot tell a double tap from a real second request (a
/// repeated request for paper is a request for more paper), so the tap is
/// refused here, for as long as the first one is running.
class _ScBusyButton extends StatefulWidget {
  const _ScBusyButton({super.key, required this.label, required this.icon, required this.run});

  final String label;
  final IconData icon;

  /// Null = present but inert (no permission).
  final Future<void> Function()? run;

  @override
  State<_ScBusyButton> createState() => _ScBusyButtonState();
}

class _ScBusyButtonState extends State<_ScBusyButton> {
  bool _busy = false;

  Future<void> _press() async {
    final run = widget.run;
    if (run == null || _busy) return;
    setState(() => _busy = true);
    try {
      await run();
    } finally {
      // The sheet reloads underneath this (a waived bill swaps this button for
      // the waiver card), so the widget may be gone by the time it returns.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ForkButton.ghost(
        label: widget.label,
        icon: widget.icon,
        dense: true,
        onPressed: widget.run == null || _busy ? null : _press,
      );
}

Future<void> _removeServiceChargeAndPrint(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  required Map bill,
  required String tableName,
  required VoidCallback onChanged,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final charge = misServiceChargeOnBill(bill);
  final answer = await showDialog<_CaptureReason>(
    context: context,
    builder: (_) => _CaptureReasonDialog(
      title: 'Remove service charge & print',
      headline: charge > 0 ? _money(charge) : null,
      subtitle: 'The charge comes off this OPEN bill and the bill prints straight away without it. '
          'Where tax rides on the charge the total falls by more than the charge itself, and you '
          'are told both totals. A settled bill cannot be changed — that is a refund.',
      confirmLabel: 'Remove & print',
      // "Guest asked" leads the list: nine of the first eleven waivers recorded
      // in production were exactly that, so the commonest case is one tap.
      kinds: _scWaiverKinds,
      needsAuthoriser: true,
      suggestedAuthoriser: profile.employeeUsername,
      reasonOptional: true,
    ),
  );
  if (answer == null) return;
  try {
    final res = await rest.post(
      '/bills/service-charge-waiver/print',
      serviceChargeRemovalBody(
        tableName: tableName,
        kind: answer.kind,
        reason: answer.reason,
        authorisedBy: answer.authorisedBy,
      ),
    );
    final outcome = serviceChargeRemovalOutcome(res);
    messenger.showSnackBar(SnackBar(content: Text(outcome.message), duration: outcome.shown));
  } catch (e) {
    // Offline is OutboxPolicy's billing sentence and nothing was recorded. A
    // timeout is not so clear — the waiver may have landed — which is why the
    // bill is reloaded below whatever happened: the card that comes back is
    // the answer.
    messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
  } finally {
    onChanged();
  }
}

/// Print a bill whose charge a recorded waiver has already taken off.
///
/// Confirmation only, and no figures in it: the same server route is called
/// with no kind and no reason, and it reprints the existing waiver — no second
/// row, no second audit line. The total goes in the snackbar afterwards, from
/// the server's reply, because that is the total that was printed. The words
/// are [serviceChargeWaivedPrintCopy]'s, so the dialog only promises a REPRINT
/// banner when the server's ledger says the paper will carry one.
Future<void> _reprintWithoutServiceCharge(
  BuildContext context, {
  required RestClient rest,
  required String tableName,
  required ({String label, String title, String body, String confirm}) copy,
  required VoidCallback onChanged,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(copy.title),
      content: Text(copy.body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(copy.confirm)),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final res = await rest.post('/bills/service-charge-waiver/print', {'table_name': tableName});
    final outcome = serviceChargeRemovalOutcome(res);
    messenger.showSnackBar(SnackBar(content: Text(outcome.message), duration: outcome.shown));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
  } finally {
    onChanged();
  }
}

Future<void> _reverseServiceChargeWaiver(
  BuildContext context, {
  required RestClient rest,
  required String waiverId,
  required VoidCallback onChanged,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final answer = await showDialog<_CaptureReason>(
    context: context,
    builder: (_) => _CaptureReasonDialog(
      title: 'Put the service charge back',
      subtitle: 'The charge goes back on this bill. The original waiver stays on the report, '
          'marked reversed — it is never deleted.',
      confirmLabel: 'Charge it again',
      kinds: const [],
      needsAuthoriser: false,
      suggestedAuthoriser: '',
    ),
  );
  if (answer == null) return;
  try {
    await rest.post('/bills/service-charge-waiver/$waiverId/reverse', {'reason': answer.reason});
    messenger.showSnackBar(const SnackBar(content: Text('The service charge is back on the bill.')));
    onChanged();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
  }
}

// ============================================================================
// 037 + 038 — THE PAYMENT SCREEN: tenders, tips and the till
// ============================================================================

/// The till this terminal is ringing on, for the life of the app session.
///
/// SESSION MEMORY, NOT A SAVED SETTING, and not a per-bill choice either. A
/// counter is what a cashier stands at for a shift: asking on every bill is
/// friction that gets answered wrong at 11pm, and persisting it across restarts
/// would silently attribute tomorrow's shift to yesterday's terminal. Empty is
/// the normal state — most tenants have one till per outlet, never configure a
/// counter, and see none of this.
String _misCounterId = '';
String _misCounterLabel = '';

/// Test seam, like [misResetReportMemory]: a suite must not inherit the previous
/// test's till.
void misResetCaptureMemory() {
  _misCounterId = '';
  _misCounterLabel = '';
}

/// One payment being composed at the till, before anything is written.
class _DraftTender {
  _DraftTender({
    required this.method,
    required this.amount,
    this.txnRef = '',
    this.tip = 0,
    this.tipMode = 'cash',
    this.tipTo = '',
  });

  final String method;

  /// The portion of the BILL this settles. Never includes the tip — that is the
  /// whole reason a tipped bill still reconstructs its grand total to the paisa.
  final double amount;
  final String txnRef;
  final double tip;
  final String tipMode;
  final String tipTo;

  Map<String, dynamic> toJson() => {
        'method': method,
        'amount': amount,
        if (txnRef.trim().isNotEmpty) 'txn_ref': txnRef.trim(),
        if (tip > 0) 'tip_amount': tip,
        if (tip > 0) 'tip_mode': tipMode,
        if (tip > 0) 'tip_credited_to_username': tipTo.trim(),
      };
}

/// THE MONEY SCREEN.
///
/// It replaced a single-method dialog, and everything that dialog did still
/// happens in one tap: the method pills are the same pills, the amount arrives
/// pre-filled with the whole outstanding, and "Settle & close" sends exactly the
/// body it always sent. What is new sits underneath and is opt-in — a second
/// payment, a tip, a till — because a busy Saturday must not get slower to buy a
/// report a column.
///
/// TWO BODIES, AND WHICH ONE IS SENT MATTERS. A settle carrying `tenders` is
/// checked with `require_full`: the tenders must reconstruct the grand total to
/// the paisa or NOTHING is written. That is the right rule and it is also a way
/// to fail at a till if the quote moved (an order landing while the guest paid),
/// so the simple case deliberately does NOT send tenders — it sends
/// `payment_method` exactly as before and lets the server compute the total
/// inside its own transaction. Tenders go only when the cashier actually used a
/// tip or a split, and if the reconciliation then fails the refusal is shown
/// verbatim with a control to re-read the amount.
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({
    required this.rest,
    required this.profile,
    required this.orderId,
    required this.tableName,
    required this.fallbackTotal,
  });

  final RestClient rest;
  final Profile profile;
  final String orderId;
  final String tableName;

  /// What the table sheet already knows the bill comes to. Used only until the
  /// ledger answers, and as the whole truth if it never does.
  final String fallbackTotal;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  // ---- the modes -------------------------------------------------------------
  //
  // THE RESTAURANT'S OWN, read from GET /restaurant/settings `payment_methods`
  // in [_load]: the modes the owner switched on (built-ins and the ones they
  // added), minus the online gateway. A pill SHOWS the label and SENDS the id,
  // and whether it needs a screenshot is the config's rule — the same rule the
  // server enforces on the settle. Until the read answers, and whenever it
  // cannot (an older backend, a dead line), the built-in list the server
  // settles with for a restaurant that never opened the editor: a settle is
  // never blocked by a settings read.
  List<PaymentMode> _allModes = PaymentModes.fallback;
  List<PaymentMode> _modes = PaymentModes.till(PaymentModes.fallback);

  static const String _noModes =
      'No payment mode is switched on. An owner can switch one on in Settings > Payments.';

  /// Same ~3MB ceiling POST /billing/upload-payment-proof enforces (its limit is
  /// on the base64 text, which is ~4/3 of the byte count), checked here so an
  /// oversized photo fails instantly instead of after a long upload.
  static const int _maxProofBytes = 3000000;

  /// `payment_splits` accepts 2..6 parts and a seventh tender could be recorded
  /// and then never mirrored — i.e. a fully paid bill stranded open. The server
  /// enforces it; this stops the control being offered a seventh time.
  static const int _maxTenders = 6;

  // ---- the ledger ----------------------------------------------------------
  Map<String, dynamic> _state = const {};
  bool _ledgerOk = false;
  bool _loading = true;

  // ---- the composer --------------------------------------------------------
  String _method = 'Upi';
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _txnRef = TextEditingController();
  bool _tipping = false;
  final TextEditingController _tip = TextEditingController();
  String _tipMode = 'cash';
  final TextEditingController _tipTo = TextEditingController();

  /// Payments composed but not yet sent — the split, built one part at a time.
  final List<_DraftTender> _drafts = [];

  // ---- the till ------------------------------------------------------------
  List<Map> _counters = const [];

  // ---- proof ---------------------------------------------------------------
  String? _proofUrl;
  Uint8List? _proofPreview;
  bool _uploading = false;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _amount.dispose();
    _txnRef.dispose();
    _tip.dispose();
    _tipTo.dispose();
    super.dispose();
  }

  // ---- wire ----------------------------------------------------------------

  /// READ-ONLY EVEN WHEN THERE IS NO BILL ROW YET. GET /bills/tenders answers
  /// with the live quote and nothing tendered rather than allocating an invoice
  /// number, which is exactly what a payment screen needs before the first
  /// tender — see the route's own header.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      // EVERYTHING HALF-KEYED IS DROPPED, not just the composed parts. A re-read
      // means the server has just said what this bill now carries, and anything
      // left on screen from before it is a payment that could be sent a second
      // time — which is how a guest is charged twice. The tip is the sharpest
      // case: it survives no round trip, because a tip re-sent is money owed to
      // a waiter twice over.
      _drafts.clear();
      _txnRef.clear();
      _tip.clear();
      _tipTo.clear();
      _tipping = false;
    });
    Map<String, dynamic> state = const {};
    var ok = false;
    // Both reads are gated on the RECORD-PAYMENT action. Not asking for them
    // when this profile does not hold it is not an optimisation: it is the
    // difference between opening in the degraded single-method mode on purpose
    // and opening there because two requests quietly 403'd.
    final mayRecord = _holdsAction(widget.profile, _permRecordPayment);
    if (mayRecord) {
      try {
        state = await widget.rest
            .getMap('/bills/tenders?order_id=${Uri.encodeQueryComponent(widget.orderId)}');
        ok = state.isNotEmpty;
      } catch (_) {
        // An older backend, or a permission this session turns out not to have.
        // The screen degrades to exactly the single-method settle it replaced
        // rather than refusing to open with money on the counter.
        ok = false;
      }
    }
    List<Map> counters = const [];
    if (mayRecord) {
      try {
        final m = await widget.rest.getMap('/billing-counters');
        counters = [for (final c in (m['counters'] as List?) ?? const []) if (c is Map) c];
      } catch (_) {/* no tills configured, or an older backend */}
    }
    // Any signed-in staff may read the settings document's payment modes (they
    // are not a privileged field), so this is not gated on record-payment.
    var modes = PaymentModes.fallback;
    try {
      final s = await widget.rest.getMap('/restaurant/settings');
      modes = PaymentModes.parse(s['payment_methods']);
    } catch (_) {/* an older backend or no line: the built-in list, see above */}
    if (!mounted) return;
    setState(() {
      _state = state;
      _ledgerOk = ok;
      _counters = counters;
      _allModes = modes;
      _modes = PaymentModes.till(modes);
      // Keep the cashier's pick if it is still on offer; otherwise UPI, as the
      // sheet always opened on, or the first mode this restaurant takes.
      if (!_modes.any((m) => m.id == _method) && _modes.isNotEmpty) {
        _method = _modes.any((m) => m.id == 'Upi') ? 'Upi' : _modes.first.id;
      }
      _loading = false;
      _amount.text = _remaining <= 0 ? '' : _remaining.toStringAsFixed(2);
    });
  }

  // ---- the numbers ---------------------------------------------------------

  double get _grandTotal => _numOf(_state['grand_total']);

  /// Already recorded against this bill and not voided.
  double get _tendered => _numOf(_state['tendered']);

  /// What the server says is still owed, BEFORE anything composed here.
  double get _outstanding => _numOf(_state['outstanding']);

  double get _draftTotal =>
      _drafts.fold<double>(0, (s, t) => s + t.amount);

  /// What is still unpaid after the parts already composed on this screen. The
  /// number the cashier is actually working towards, and the reason it is the
  /// largest thing on the sheet.
  double get _remaining {
    final r = _outstanding - _draftTotal;
    return r < 0.005 ? 0 : r;
  }

  double get _tipsRecorded => _numOf(_state['tips_total']);
  /// Tips on THIS settlement — the parts already composed AND the one being
  /// keyed. Counting only the parts would leave the headline saying no tip while
  /// a cashier looks at the tip they just typed.
  double get _tipsDraft => _allDrafts.fold<double>(0, (s, t) => s + t.tip);

  List<Map> get _liveTenders => [
        for (final t in (_state['tenders'] as List?) ?? const [])
          if (t is Map && (t['voided_at'] == null || '${t['voided_at']}'.isEmpty)) t,
      ];

  int get _tenderCount => _liveTenders.length + _drafts.length;

  double get _composerAmount => double.tryParse(_amount.text.trim()) ?? 0;
  double get _composerTip => _tipping ? (double.tryParse(_tip.text.trim()) ?? 0) : 0;

  bool get _needsProofNow => PaymentModes.needsScreenshot(_method, _allModes);

  /// What the cashier reads for the chosen mode — the owner's label, not the id.
  String get _methodLabel => PaymentModes.labelFor(_method, _allModes);
  bool get _hasProof => (_proofUrl ?? '').isNotEmpty;

  /// Why the composer cannot be used yet, or null when it can. One sentence, so
  /// the disabled control always says what would fix it.
  String? get _composerRefusal {
    if (!_ledgerOk) return null;
    if (_modes.isEmpty) return _noModes;
    if (_composerAmount <= 0) return 'Enter how much of the bill this payment covers.';
    // OVER-TENDER IS REFUSED, never recorded and never netted off — change
    // handed back in cash is not a negative tender. Caught here so the cashier
    // is told before the guest's card is charged.
    if (_composerAmount > _remaining + 0.005) {
      return 'That is more than the ${_money(_remaining)} still owed. '
          'A payment can never be larger than the bill — hand the change back in cash.';
    }
    if (_composerTip > 0 && _tipTo.text.trim().isEmpty) {
      return 'A tip has to say who it goes to — a name, or "pool".';
    }
    if (_needsProofNow && !_hasProof) {
      return '$_methodLabel needs a payment screenshot before it can settle.';
    }
    return null;
  }

  _DraftTender? get _composed {
    if (_composerRefusal != null || _composerAmount <= 0) return null;
    return _DraftTender(
      method: _method,
      amount: _composerAmount,
      txnRef: _txnRef.text,
      tip: _composerTip,
      tipMode: _tipMode,
      tipTo: _tipTo.text,
    );
  }

  /// Every payment this screen would send: the parts already composed plus the
  /// one in the composer.
  List<_DraftTender> get _allDrafts {
    return [..._drafts, ?_composed];
  }

  /// True when this is the ordinary one-method settle the old dialog did: no
  /// tip, no split, nothing already on the ledger, and the whole bill in one go.
  /// That case sends the body it has always sent — see the class header.
  bool get _isSimpleSettle =>
      _liveTenders.isEmpty &&
      _drafts.isEmpty &&
      _composerTip <= 0 &&
      (!_ledgerOk || (_remaining > 0 && (_composerAmount - _remaining).abs() < 0.005));

  // ---- proof ---------------------------------------------------------------

  /// Content type sniffed from the actual bytes rather than the file extension:
  /// the backend checks the magic bytes, so a mislabelled ".jpg" would 400 there.
  static String? _imageTypeOf(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  Future<void> _pickProof(ImageSource source) async {
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final shot = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      if (shot == null) {
        if (mounted) setState(() => _uploading = false);
        return;
      }
      final bytes = await shot.readAsBytes();
      final ct = _imageTypeOf(bytes);
      if (ct == null) {
        if (mounted) {
          setState(() {
            _uploading = false;
            _error = 'That file is not a JPEG, PNG or WebP image.';
          });
        }
        return;
      }
      if (bytes.length > _maxProofBytes) {
        if (mounted) {
          setState(() {
            _uploading = false;
            _error = 'That image is too large (max 3MB) — retake it at a lower quality.';
          });
        }
        return;
      }
      final res = await widget.rest.post('/billing/upload-payment-proof', {
        'image_base64': base64Encode(bytes),
        'content_type': ct,
      });
      // The route returns payment_proof_screenshot_url (image_url is an alias).
      final url = res is Map ? '${res['payment_proof_screenshot_url'] ?? res['image_url'] ?? ''}' : '';
      if (!mounted) return;
      setState(() {
        _uploading = false;
        if (url.isEmpty) {
          _error = 'The upload came back without an image URL — please try again.';
        } else {
          _proofUrl = url;
          _proofPreview = bytes;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _error = _captureError(e);
        });
      }
    }
  }

  // ---- acts ----------------------------------------------------------------

  void _addPart() {
    final c = _composed;
    if (c == null || _tenderCount >= _maxTenders) return;
    setState(() {
      _drafts.add(c);
      _txnRef.clear();
      _tip.clear();
      _tipTo.clear();
      _tipping = false;
      _amount.text = _remaining <= 0 ? '' : _remaining.toStringAsFixed(2);
    });
  }

  /// Record what has been composed WITHOUT closing the bill.
  ///
  /// This is the under-tender case, and it is a named, legal state rather than a
  /// failure: the guest has paid some of it, `outstanding` says what is left and
  /// the table stays open. It is the whole reason POST /bills/tenders exists
  /// separately from the settle.
  Future<void> _recordPartPayment() async {
    final tenders = _allDrafts;
    if (tenders.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.rest.post('/bills/tenders', {
        'order_id': widget.orderId,
        'tenders': [for (final t in tenders) t.toJson()],
      });
      messenger.showSnackBar(const SnackBar(
          content: Text('Payment recorded. The bill stays open for the rest.')));
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _captureError(e);
      });
    }
  }

  Future<void> _voidTender(Map tender) async {
    final messenger = ScaffoldMessenger.of(context);
    final answer = await showDialog<_CaptureReason>(
      context: context,
      builder: (_) => _CaptureReasonDialog(
        title: 'Void this payment',
        headline: _money(tender['amount']),
        danger: true,
        subtitle: '${_s(tender, 'method')} · the row stays, stamped with your name and this '
            'reason, and drops out of every total. That is what makes a double-keyed card '
            'payment provable when the acquirer’s statement shows two authorisations.',
        confirmLabel: 'Void it',
        kinds: const [],
        needsAuthoriser: false,
        suggestedAuthoriser: '',
      ),
    );
    if (answer == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.rest.post('/bills/tenders/${tender['id']}/void', {'reason': answer.reason});
      messenger.showSnackBar(const SnackBar(content: Text('Payment voided.')));
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _captureError(e);
      });
    }
  }

  /// Settle, approve and close — the same three calls the old dialog made, with
  /// the body chosen by [_isSimpleSettle].
  Future<void> _settleAndClose() async {
    final refusal = _settleRefusal;
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final oid = widget.orderId;
    final tenders = _allDrafts;
    try {
      final body = <String, dynamic>{
        if (_misCounterId.isNotEmpty) 'counter_id': _misCounterId,
        if (_needsProofNow && _hasProof) 'payment_proof_screenshot_url': _proofUrl,
      };
      if (_isSimpleSettle) {
        // UNCHANGED PATH. No `tenders` key, so every value the settle computes is
        // the one it has always computed and the grand total is worked out inside
        // the server's own transaction rather than against a quote from a moment
        // ago.
        body['payment_method'] = _method;
      } else if (tenders.isEmpty) {
        // The bill is already fully paid through part payments. The ledger is the
        // authority on HOW it was paid — the server overrides whatever method is
        // sent here with its own mirror — but the route still requires one field
        // that says "this is a settle", so it gets the ledger's own answer.
        body['payment_method'] = '${_state['payment_method'] ?? _method}';
      } else {
        body['tenders'] = [for (final t in tenders) t.toJson()];
      }
      await widget.rest.post('/bills/order/$oid/waiter-confirm-payment', body);
      await widget.rest.post('/bills/order/$oid/admin-approve-payment');
      await widget.rest.post('/bills/order/$oid/close');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _captureError(e);
      });
      // THE HALF-DONE SETTLE, AND WHY THIS RE-READ IS NOT OPTIONAL.
      //
      // RecordBillTenders commits in its OWN transaction, so a settle carrying
      // tenders that then fails — the approval refused, the bill re-priced
      // underneath — leaves those payments RECORDED on a bill that is still
      // open. The composed parts are then a lie: pressing Settle again would
      // send them a second time and be refused for over-tendering, which reads
      // like a dead end with a guest standing at the till. Re-reading replaces
      // them with what actually landed, and the screen then offers the recovery
      // the server itself names — settle again, from the ledger, with no tenders.
      //
      // Only for a refusal the SERVER answered. An outage recorded nothing, and
      // re-reading through a dead line would drop this screen into its degraded
      // single-payment mode in the middle of taking money.
      final answered = e is ApiException && e.status != null;
      if (answered && tenders.isNotEmpty) {
        final refusal = _error;
        await _load();
        // _load clears the error banner along with the drafts; the refusal is
        // the only thing on screen explaining why the bill is still open.
        if (mounted) setState(() => _error = refusal);
      }
    }
  }

  /// Why the bill cannot be settled yet, or null. Under-tender at settle is
  /// refused by the server (the tenders must reconstruct the grand total to the
  /// paisa); saying so here means the cashier is not told after the card machine.
  String? get _settleRefusal {
    // Every mode switched off in Settings: there is nothing a NEW payment could
    // be taken in. Said, not left as a grey button. (A bill the ledger has
    // already paid in full is not blocked by it — see below.)
    if (!_ledgerOk) {
      if (_modes.isEmpty) return _noModes;
      return (_needsProofNow && !_hasProof)
          ? 'Attach a payment proof photo before settling a $_methodLabel bill.'
          : null;
    }
    // ALREADY PAID IN FULL through part payments, with nothing new keyed. There
    // is no payment to compose and the composer's own "enter an amount" refusal
    // must not stand between a settled bill and its close — the ledger is what
    // settles it.
    if (_remaining <= 0.005 && _composerAmount <= 0) {
      return (_needsProofNow && !_hasProof)
          ? 'Attach a payment proof photo before settling a $_methodLabel bill.'
          : null;
    }
    if (_modes.isEmpty) return _noModes;
    final left = _remaining - (_composed?.amount ?? 0);
    if (left > 0.005) {
      return 'That leaves ${_money(left)} unpaid. A bill settles in full — '
          'take the rest, or use “Record part payment” and leave the table open.';
    }
    return _composerRefusal;
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: math.min(480, width - 32),
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _headline(text),
                const SizedBox(height: AppSpacing.lg),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (_counters.isNotEmpty) ...[
                        _tillRow(text),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      if (_liveTenders.isNotEmpty) ...[
                        _recordedBlock(text),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      if (_drafts.isNotEmpty) ...[
                        _draftBlock(text),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      // Nothing left to take: no method pills, no amount field.
                      // A composer offering to take money on a bill that owes
                      // none is the shortest route to an over-tender.
                      if (!_ledgerOk || _remaining > 0) _composerBlock(text),
                    ]),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger)),
                ],
                // WHY "Settle & close" IS GREY, standing next to it. A disabled
                // primary button on a money screen with no reason beside it is
                // the dead-looking control this app has been bitten by before —
                // and here the reason is always something the cashier can act
                // on: take the rest, or record what has been paid.
                if (_error == null && _settleRefusal != null) ...[
                  const SizedBox(height: 10),
                  Text(_settleRefusal!,
                      key: const ValueKey('pay-refusal'),
                      style: text.bodySmall!.copyWith(color: AppColors.warning)),
                ],
                const SizedBox(height: AppSpacing.md),
                Text('Approval is required before the bill closes and the table frees.',
                    style: text.bodySmall),
                const SizedBox(height: AppSpacing.md),
                _actions(text),
              ]),
      ),
    );
  }

  /// THE ONE NUMBER THIS SCREEN EXISTS FOR. Outstanding is the largest thing on
  /// it, colour-coded AND labelled (never colour alone), with the bill total and
  /// what has already been taken underneath in small type — because at a till the
  /// question is always "how much more", not "how much was it".
  Widget _headline(TextTheme text) {
    final settledUp = _ledgerOk && _remaining <= 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
            widget.tableName.isEmpty ? 'SETTLE BILL' : 'SETTLE BILL · TABLE ${widget.tableName.toUpperCase()}',
            style: text.labelSmall,
          ),
        ),
        if (!_ledgerOk)
          const InfoChip(icon: Icons.info_outline, label: 'Single payment only'),
      ]),
      const SizedBox(height: 8),
      if (!_ledgerOk) ...[
        Text(widget.fallbackTotal, style: text.displayMedium),
        const SizedBox(height: 4),
        Text(
          'This bill’s payment ledger could not be read, so split payments, tips and the '
          'till are not offered here. The bill still settles exactly as it always has.',
          style: text.bodySmall,
        ),
      ] else ...[
        Text(settledUp ? 'PAID IN FULL' : 'STILL TO PAY',
            style: text.labelSmall!.copyWith(
                color: settledUp ? AppColors.success : AppColors.copperHi)),
        const SizedBox(height: 2),
        Text(_money(_remaining),
            key: const ValueKey('pay-outstanding'),
            style: text.displayMedium!.copyWith(
                color: settledUp ? AppColors.success : AppColors.copperHi)),
        const SizedBox(height: 6),
        Wrap(spacing: AppSpacing.md, runSpacing: 6, children: [
          Text('Bill ${_money(_grandTotal)}', style: text.bodySmall),
          if (_tendered > 0) Text('Paid ${_money(_tendered)}', style: text.bodySmall),
          if (_draftTotal > 0) Text('Composed ${_money(_draftTotal)}', style: text.bodySmall),
          // A TIP IS NOT PART OF THE BILL. Reported on its own line, never added
          // into any of the three above, because the moment it is the bill stops
          // reconciling and the day's takings read high by the tips.
          if (_tipsRecorded + _tipsDraft > 0)
            Text('Tips ${_money(_tipsRecorded + _tipsDraft)} (not part of the bill)',
                style: text.bodySmall!.copyWith(color: AppColors.copperHi)),
        ]),
      ],
    ]);
  }

  Widget _tillRow(TextTheme text) {
    return Row(children: [
      Icon(Icons.point_of_sale, size: 16, color: AppColors.textSecondary),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Text(_misCounterId.isEmpty ? 'No till chosen' : 'Till: $_misCounterLabel',
            style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      PopupMenuButton<String>(
        key: const ValueKey('pay-counter'),
        tooltip: 'Which till is ringing this',
        color: AppColors.cardRaised,
        onSelected: (id) => setState(() {
          if (id.isEmpty) {
            _misCounterId = '';
            _misCounterLabel = '';
            return;
          }
          _misCounterId = id;
          final hit = _counters.firstWhere((c) => '${c['id']}' == id, orElse: () => const {});
          _misCounterLabel = hit.isEmpty
              ? id
              : '${_s(hit, 'code')} · ${_s(hit, 'name', _s(hit, 'code'))}';
        }),
        itemBuilder: (_) => [
          CheckedPopupMenuItem<String>(
            value: '',
            checked: _misCounterId.isEmpty,
            child: const Text('This outlet’s single till'),
          ),
          for (final c in _counters)
            CheckedPopupMenuItem<String>(
              value: '${c['id']}',
              checked: '${c['id']}' == _misCounterId,
              child: Text('${_s(c, 'code')} · ${_s(c, 'name', _s(c, 'code'))}'
                  '${c['active'] == false ? ' (retired)' : ''}'),
            ),
        ],
        child: IgnorePointer(
          child: ForkButton.ghost(
              label: _misCounterId.isEmpty ? 'Choose till' : 'Change', dense: true, onPressed: () {}),
        ),
      ),
    ]);
  }

  Widget _recordedBlock(TextTheme text) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
          title: 'Already paid',
          count: _liveTenders.length,
          padding: const EdgeInsets.only(bottom: 8)),
      for (final t in _liveTenders)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ForkCard(
            inset: true,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${PaymentModes.labelFor(_s(t, 'method'), _allModes)} · ${_money(t['amount'])}',
                      style: text.titleSmall),
                  if (_numOf(t['tip_amount']) > 0)
                    Text(
                      '+ ${_money(t['tip_amount'])} tip '
                      '(${_vocabLabel(_tipModes, _s(t, 'tip_mode', ''))}) '
                      'to ${_s(t, 'tip_credited_to_username')}',
                      style: text.bodySmall!.copyWith(color: AppColors.copperHi),
                    ),
                  if (_s(t, 'txn_ref', '').isNotEmpty)
                    Text('Ref ${_s(t, 'txn_ref')}', style: text.bodySmall),
                ]),
              ),
              ForkIconButton(
                icon: Icons.remove_circle_outline,
                tooltip: 'Void this payment',
                onPressed: _busy ? null : () => _voidTender(t),
              ),
            ]),
          ),
        ),
    ]);
  }

  Widget _draftBlock(TextTheme text) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
          title: 'This settlement',
          count: _drafts.length,
          padding: const EdgeInsets.only(bottom: 8)),
      for (var i = 0; i < _drafts.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ForkCard(
            inset: true,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${PaymentModes.labelFor(_drafts[i].method, _allModes)} · ${_money(_drafts[i].amount)}',
                      style: text.titleSmall),
                  if (_drafts[i].tip > 0)
                    Text('+ ${_money(_drafts[i].tip)} tip to ${_drafts[i].tipTo}',
                        style: text.bodySmall!.copyWith(color: AppColors.copperHi)),
                ]),
              ),
              ForkIconButton(
                icon: Icons.close,
                tooltip: 'Take this part off again',
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _drafts.removeAt(i);
                          _amount.text = _remaining <= 0 ? '' : _remaining.toStringAsFixed(2);
                        }),
              ),
            ]),
          ),
        ),
    ]);
  }

  Widget _composerBlock(TextTheme text) {
    final platform = Theme.of(context).platform;
    final canCapture = platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final locked = _busy || _uploading;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_drafts.isEmpty ? 'PAYMENT METHOD' : 'NEXT PART', style: text.labelSmall),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        // Keyed by the id (what is sent), labelled by the owner's name for it.
        for (final m in _modes)
          _CapturePill(
            key: ValueKey('pay-method-${m.id}'),
            label: m.label,
            selected: _method == m.id,
            onTap: locked ? null : () => setState(() => _method = m.id),
          ),
      ]),
      if (_ledgerOk) ...[
        const SizedBox(height: AppSpacing.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('pay-amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ForkButton.ghost(
              key: const ValueKey('pay-all'),
              label: 'All of it',
              dense: true,
              onPressed: (locked || _remaining <= 0)
                  ? null
                  : () => setState(() => _amount.text = _remaining.toStringAsFixed(2)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        TextField(
          key: const ValueKey('pay-ref'),
          controller: _txnRef,
          decoration: const InputDecoration(
            labelText: 'Reference (optional)',
            helperText: 'The acquirer’s reference, so a disputed card payment can be found.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // The tip block is collapsed by default: most bills carry none, and an
        // always-open amount field beside the bill total is a field somebody
        // eventually types the bill into.
        if (!_tipping)
          Align(
            alignment: Alignment.centerLeft,
            child: ForkButton.ghost(
              key: const ValueKey('pay-add-tip'),
              label: 'Add a tip',
              icon: Icons.volunteer_activism_outlined,
              dense: true,
              onPressed: locked ? null : () => setState(() => _tipping = true),
            ),
          )
        else
          _tipBlock(text, locked),
      ],
      if (_needsProofNow) ...[
        const SizedBox(height: AppSpacing.lg),
        Text('PAYMENT PROOF', style: text.labelSmall),
        const SizedBox(height: 8),
        if (_proofPreview != null) ...[
          ClipRRect(
            borderRadius: AppRadius.controlAll,
            child: Image.memory(
              _proofPreview!,
              height: 130,
              width: double.infinity,
              fit: BoxFit.cover,
              // A preview that cannot decode must not take the dialog down.
              errorBuilder: (_, _, _) => Container(
                height: 130,
                alignment: Alignment.center,
                color: AppColors.inset,
                child: Text('Uploaded', style: text.bodySmall),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (canCapture)
            ForkButton.ghost(
              label: _hasProof ? 'Retake' : 'Take photo',
              icon: Icons.photo_camera_outlined,
              dense: true,
              onPressed: locked ? null : () => _pickProof(ImageSource.camera),
            ),
          ForkButton.ghost(
            label: _hasProof ? 'Replace image' : 'Choose image',
            icon: Icons.image_outlined,
            dense: true,
            onPressed: locked ? null : () => _pickProof(ImageSource.gallery),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          _uploading
              ? 'Uploading…'
              : _hasProof
                  ? 'Proof attached — it uploads with the settlement.'
                  : '$_methodLabel needs a payment screenshot. Capture or pick one; it uploads straight away.',
          style: text.bodySmall!.copyWith(
            fontSize: 11.5,
            color: _hasProof && !_uploading ? AppColors.success : AppColors.textTertiary,
          ),
        ),
      ],
      if (_ledgerOk && _remaining > 0) ...[
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: ForkButton.ghost(
            key: const ValueKey('pay-split'),
            label: 'Split — pay part this way',
            icon: Icons.call_split,
            dense: true,
            // Disabled with the reason under it, never a control that 400s.
            onPressed: (locked || _composed == null || _tenderCount >= _maxTenders)
                ? null
                : _addPart,
          ),
        ),
        if (_tenderCount >= _maxTenders)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'A bill can be settled across at most $_maxTenders payments. '
              'Void one before adding another.',
              style: text.bodySmall!.copyWith(color: AppColors.warning),
            ),
          )
        else if (_composerRefusal != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_composerRefusal!, style: text.bodySmall!.copyWith(color: AppColors.warning)),
          ),
      ],
    ]);
  }

  Widget _tipBlock(TextTheme text, bool locked) {
    return ForkCard(
      inset: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('TIP', style: text.labelSmall)),
          ForkIconButton(
            icon: Icons.close,
            tooltip: 'No tip after all',
            onPressed: locked
                ? null
                : () => setState(() {
                      _tipping = false;
                      _tip.clear();
                      _tipTo.clear();
                    }),
          ),
        ]),
        Text('On top of the bill, never part of it. A tip appears in no sales figure, '
            'no APC and no ABV — only on the Tip Summary, as money owed to a person.',
            style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          key: const ValueKey('pay-tip-amount'),
          controller: _tip,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Tip amount', prefixText: '₹ '),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('HOW IT ARRIVED', style: text.labelSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (value, label) in _tipModes)
            _CapturePill(
              key: ValueKey('pay-tip-mode-$value'),
              label: label,
              selected: _tipMode == value,
              onTap: locked ? null : () => setState(() => _tipMode = value),
            ),
        ]),
        const SizedBox(height: AppSpacing.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('pay-tip-to'),
              controller: _tipTo,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Credited to',
                helperText: 'A staff username, or the shared pool.',
                helperMaxLines: 2,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ForkButton.ghost(
              key: const ValueKey('pay-tip-pool'),
              label: 'Pool',
              dense: true,
              onPressed: locked ? null : () => setState(() => _tipTo.text = _tipPool),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _actions(TextTheme text) {
    final locked = _busy || _uploading;
    final canPart = _ledgerOk && _allDrafts.isNotEmpty && _remaining > 0;
    final canSettle = _settleRefusal == null;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        ForkButton.ghost(
          label: 'Cancel',
          dense: true,
          onPressed: locked ? null : () => Navigator.pop(context, false),
        ),
        if (canPart)
          ForkButton.ghost(
            key: const ValueKey('pay-part'),
            label: 'Record part payment',
            icon: Icons.savings_outlined,
            dense: true,
            onPressed: locked ? null : _recordPartPayment,
          ),
        ForkButton(
          key: const ValueKey('pay-settle'),
          label: _busy ? 'Processing…' : 'Settle & close',
          icon: Icons.check,
          onPressed: (locked || !canSettle) ? null : _settleAndClose,
        ),
      ],
    );
  }
}

// ============================================================================
// 038 — BILLING COUNTERS: which tills this outlet has
// ============================================================================

/// The tills, under Settings → Billing & taxes.
///
/// EMPTY IS THE NORMAL ANSWER and the card says so: most tenants run one till
/// per outlet, configure no counter, and every bill and every cash session
/// resolves as "this outlet's till" in every report. The card exists for the
/// food court with four stalls and the restaurant with a bar terminal, where a
/// cash-up that cannot name the drawer it is reconciling is not a cash-up.
///
/// THERE IS NO DELETE, deliberately and on both sides. A counter id sits on
/// every bill that till ever rang; removing it would orphan that history, which
/// is precisely what the column exists to keep. Retiring stops it being offered
/// and leaves every past attribution resolvable.
class _BillingCountersCard extends StatefulWidget {
  const _BillingCountersCard({required this.rest, required this.profile});
  final RestClient rest;
  final Profile profile;

  @override
  State<_BillingCountersCard> createState() => _BillingCountersCardState();
}

class _BillingCountersCardState extends State<_BillingCountersCard> {
  List<Map> _counters = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _mayEdit =>
      widget.profile.isAdmin || _holdsAction(widget.profile, _permSettings);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // include_inactive: an editor has to see the retired ones it may reinstate.
      final m = await widget.rest.getMap('/billing-counters?include_inactive=1');
      if (!mounted) return;
      setState(() {
        _counters = [for (final c in (m['counters'] as List?) ?? const []) if (c is Map) c];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _captureError(e);
      });
    }
  }

  Future<void> _edit({Map? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BillingCounterDialog(rest: widget.rest, existing: existing),
    );
    if (saved == true) await _load();
  }

  /// Retire or reinstate. `active: false` is the ONLY way out — see the class
  /// header for why there is no delete.
  Future<void> _setActive(Map counter, bool active) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      // UPSERTS ON THE CODE, so the whole row travels: sending only `active`
      // would let the server's own defaults land on a name somebody typed.
      await widget.rest.post('/billing-counters', {
        'id': counter['id'],
        'code': counter['code'],
        'name': counter['name'],
        'kind': counter['kind'],
        'device_hint': counter['device_hint'],
        'sort_order': counter['sort_order'],
        'active': active,
      });
      // A retired till must not stay selected on this terminal.
      if (!active && '${counter['id']}' == _misCounterId) {
        _misCounterId = '';
        _misCounterLabel = '';
      }
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ForkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Billing counters', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'The tills that ring sales here. Leave this empty and every bill sits on this '
          'outlet’s single till, which is what most restaurants want. Configure them and the '
          'Counter Summary report cuts the day’s takings by the drawer that took them.',
          style: text.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        if (_loading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger))
        else if (_counters.isEmpty)
          Text('No tills configured.', style: text.bodySmall)
        else
          for (final c in _counters)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: ForkCard(
                inset: true,
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_s(c, 'code')} · ${_s(c, 'name', _s(c, 'code'))}', style: text.titleSmall),
                      Text(
                        [
                          _vocabLabel(_counterKinds, _s(c, 'kind', 'counter')),
                          if (_s(c, 'device_hint', '').isNotEmpty) _s(c, 'device_hint'),
                        ].join(' · '),
                        style: text.bodySmall,
                      ),
                    ]),
                  ),
                  if (c['active'] == false)
                    StatusChip(label: 'Retired', color: AppColors.neutral, dense: true),
                  if (_mayEdit) ...[
                    const SizedBox(width: AppSpacing.sm),
                    ForkIconButton(
                      icon: Icons.edit_outlined,
                      tooltip: 'Rename this till',
                      onPressed: _busy ? null : () => _edit(existing: c),
                    ),
                    ForkIconButton(
                      icon: c['active'] == false ? Icons.restart_alt : Icons.block,
                      tooltip: c['active'] == false ? 'Put it back in service' : 'Retire it',
                      onPressed: _busy ? null : () => _setActive(c, c['active'] == false),
                    ),
                  ],
                ]),
              ),
            ),
        if (_mayEdit) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: ForkButton.ghost(
              key: const ValueKey('counters-add'),
              label: 'Add a till',
              icon: Icons.add,
              dense: true,
              onPressed: _busy ? null : () => _edit(),
            ),
          ),
        ] else
          Text('Only an admin can add or rename a till.',
              style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
      ]),
    );
  }
}

class _BillingCounterDialog extends StatefulWidget {
  const _BillingCounterDialog({required this.rest, this.existing});
  final RestClient rest;
  final Map? existing;

  @override
  State<_BillingCounterDialog> createState() => _BillingCounterDialogState();
}

class _BillingCounterDialogState extends State<_BillingCounterDialog> {
  late final TextEditingController _code =
      TextEditingController(text: _s(widget.existing ?? const {}, 'code', ''));
  late final TextEditingController _name =
      TextEditingController(text: _s(widget.existing ?? const {}, 'name', ''));
  late final TextEditingController _hint =
      TextEditingController(text: _s(widget.existing ?? const {}, 'device_hint', ''));
  late String _kind = _s(widget.existing ?? const {}, 'kind', 'counter');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _hint.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'A till needs a short code — "C1", "BAR", "STALL2".');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.rest.post('/billing-counters', {
        if (widget.existing != null) 'id': widget.existing!['id'],
        'code': code,
        'name': _name.text.trim().isEmpty ? code : _name.text.trim(),
        'kind': _kind,
        'device_hint': _hint.text.trim().isEmpty ? null : _hint.text.trim(),
        if (widget.existing != null) 'active': widget.existing!['active'] != false,
        if (widget.existing != null) 'sort_order': widget.existing!['sort_order'],
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _captureError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: math.min(420, width - 32),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.existing == null ? 'ADD A TILL' : 'EDIT TILL', style: text.labelSmall),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('counter-code'),
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Code',
                helperText: 'Short and unique — it is what a cash-up sheet says at 1am. '
                    '"C1" and "c1" are the same till.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('counter-name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'What staff call it — "Front counter", "Bar".',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('KIND', style: text.labelSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (value, label) in _counterKinds)
                _CapturePill(
                  key: ValueKey('counter-kind-$value'),
                  label: label,
                  selected: _kind == value,
                  onTap: _busy ? null : () => setState(() => _kind = value),
                ),
            ]),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('counter-hint'),
              controller: _hint,
              decoration: const InputDecoration(
                labelText: 'Device hint (optional)',
                helperText: 'Which machine this is, for whoever sets the terminals up.',
                helperMaxLines: 2,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: AppSpacing.lg),
            Wrap(alignment: WrapAlignment.end, spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
              ForkButton.ghost(
                  label: 'Cancel', dense: true, onPressed: _busy ? null : () => Navigator.pop(context)),
              ForkButton(
                key: const ValueKey('counter-save'),
                label: _busy ? 'Saving…' : 'Save',
                icon: Icons.check,
                dense: true,
                onPressed: _busy ? null : _save,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// MOVE A SETTLED BILL TO ANOTHER TILL.
///
/// The one thing the settle's own attribution cannot do. A terminal found to be
/// misconfigured mid-shift has already rung real sales onto the wrong drawer,
/// and a cash-up will not balance until they are moved — which is exactly why
/// POST /bills/counter refuses nothing for being closed.
///
/// Renders nothing when the outlet has configured no tills, because then there
/// is only one place a bill can be and nowhere to move it to.
Widget misBillCounterAction(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  required String billId,
  required VoidCallback onChanged,
}) {
  if (!_holdsAction(profile, _permRecordPayment)) return const SizedBox.shrink();
  return _BillCounterAction(rest: rest, billId: billId, onChanged: onChanged);
}

class _BillCounterAction extends StatefulWidget {
  const _BillCounterAction({required this.rest, required this.billId, required this.onChanged});
  final RestClient rest;
  final String billId;
  final VoidCallback onChanged;

  @override
  State<_BillCounterAction> createState() => _BillCounterActionState();
}

class _BillCounterActionState extends State<_BillCounterAction> {
  List<Map> _counters = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final m = await widget.rest.getMap('/billing-counters?include_inactive=1');
      if (!mounted) return;
      setState(() => _counters = [
            for (final c in (m['counters'] as List?) ?? const []) if (c is Map) c,
          ]);
    } catch (_) {/* no tills, or an older backend — the control stays away */}
  }

  Future<void> _move(String? counterId, String label) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.rest.post('/bills/counter', {
        'bill_id': widget.billId,
        // An omitted counter_id CLEARS the attribution back to "this outlet's
        // single till", which is the state of every bill written before 038.
        'counter_id': ?counterId,
      });
      messenger.showSnackBar(SnackBar(content: Text('Bill moved to $label.')));
      widget.onChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_counters.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('TILL', style: text.labelSmall),
        const SizedBox(height: 6),
        Text('If this sale was rung on the wrong terminal, move it — the cash-up will '
            'not balance until it sits on the drawer that took the money.',
            style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: PopupMenuButton<String>(
            key: const ValueKey('bill-counter-move'),
            tooltip: 'Move this bill to another till',
            color: AppColors.cardRaised,
            enabled: !_busy,
            onSelected: (id) => _move(
              id.isEmpty ? null : id,
              id.isEmpty
                  ? 'this outlet’s single till'
                  : _s(_counters.firstWhere((c) => '${c['id']}' == id, orElse: () => const {}), 'code', id),
            ),
            itemBuilder: (_) => [
              const PopupMenuItem<String>(value: '', child: Text('This outlet’s single till')),
              for (final c in _counters)
                PopupMenuItem<String>(
                  value: '${c['id']}',
                  child: Text('${_s(c, 'code')} · ${_s(c, 'name', _s(c, 'code'))}'
                      '${c['active'] == false ? ' (retired)' : ''}'),
                ),
            ],
            child: IgnorePointer(
              child: ForkButton.ghost(
                  label: 'Move to another till', icon: Icons.point_of_sale, dense: true, onPressed: () {}),
            ),
          ),
        ),
      ]),
    );
  }
}

// ============================================================================
// 039 — MENU GROUPS: what a dish is filed under, for the Group Summary
// ============================================================================

/// Open the group editor. Returns true when anything was written, so the menu
/// module can reload — a reclassification changes what the reports say about the
/// last six months, not just about tomorrow.
Future<bool> misOpenMenuGroups(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _MenuGroupsDialog(rest: rest, profile: profile),
  );
  return changed == true;
}

/// THE CLASSIFICATION EDITOR.
///
/// Two halves, in the order the work is actually done: the GROUPS a tenant has,
/// then the CATEGORIES filed under them. Filing ~12 categories is the workflow —
/// the per-item override exists for the genuine exception (the mocktail listed
/// under Desserts) and this screen offers it from the same list rather than
/// making an owner edit three hundred dishes.
///
/// `unclassified_items` is shown at the top and not buried: the Group Summary's
/// totals only equal the Sales Summary's because an Unclassified bucket is
/// counted, and an owner should meet that number here rather than in front of
/// their accountant.
class _MenuGroupsDialog extends StatefulWidget {
  const _MenuGroupsDialog({required this.rest, required this.profile});
  final RestClient rest;
  final Profile profile;

  @override
  State<_MenuGroupsDialog> createState() => _MenuGroupsDialogState();
}

class _MenuGroupsDialogState extends State<_MenuGroupsDialog> {
  String _kind = 'revenue';
  List<Map> _groups = const [];
  List<Map> _categories = const [];
  List<Map> _items = const [];
  int _unclassified = 0;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  bool _showItems = false;
  String? _error;

  bool get _mayEdit => widget.profile.isAdmin || _holdsAction(widget.profile, _permEditMenu);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final m = await widget.rest.getMap('/menu-group-assignments?kind=$_kind');
      if (!mounted) return;
      setState(() {
        _groups = [for (final g in (m['groups'] as List?) ?? const []) if (g is Map) g];
        _categories = [for (final c in (m['categories'] as List?) ?? const []) if (c is Map) c];
        _items = [for (final i in (m['items'] as List?) ?? const []) if (i is Map) i];
        _unclassified = _int(m['unclassified_items']) ?? 0;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _captureError(e);
      });
    }
  }

  Future<void> _addGroup() async {
    final name = await _askText(context, 'New ${_kind == 'revenue' ? 'revenue' : 'production'} group',
        'Group name');
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _write(() => widget.rest.post('/menu-groups', {'name': name.trim(), 'kind': _kind}));
  }

  Future<void> _renameGroup(Map group) async {
    final name = await _askText(context, 'Rename group', 'Group name', initial: _s(group, 'name'));
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _write(() => widget.rest.patch('/menu-groups/${group['id']}', {'name': name.trim()}));
  }

  /// RETIRING IS THE ONLY WAY OUT, on both sides. A group id sits on menu rows
  /// and categories and reports resolve it at read time, so deleting one would
  /// strand those references and rewrite history as Unclassified.
  Future<void> _setGroupActive(Map group, bool active) =>
      _write(() => widget.rest.patch('/menu-groups/${group['id']}', {'active': active}));

  Future<void> _assign({String? categoryId, String? menuId, required String? groupId}) => _write(
        () => widget.rest.post('/menu-group-assignments', {
          'main_cat_id': ?categoryId,
          'menu_id': ?menuId,
          // An explicit null CLEARS: on an item that means "fall back to my
          // category", on a category "everything under me is Unclassified".
          // Neither is an error, and both are ordinary states.
          'group_id': groupId,
        }),
      );

  Future<void> _write(Future<dynamic> Function() call) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await call();
      _dirty = true;
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: math.min(560, size.width - 32),
        constraints: BoxConstraints(maxHeight: size.height * 0.9),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('MENU GROUPS', style: text.labelSmall),
          const SizedBox(height: 6),
          Text(
            'How the Group Summary rolls your sales up. A dish takes its category’s group '
            'unless it carries its own — file the categories and the whole menu is done.',
            style: text.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // TWO AXES, because 039 has two and a client that offered one would
            // make the other unreachable. Revenue is what the report cuts by;
            // production is the kitchen's own grouping.
            _CapturePill(
              key: const ValueKey('groups-kind-revenue'),
              label: 'Revenue',
              selected: _kind == 'revenue',
              onTap: _busy ? null : () => setState(() { _kind = 'revenue'; unawaited(_load()); }),
            ),
            _CapturePill(
              key: const ValueKey('groups-kind-production'),
              label: 'Production',
              selected: _kind == 'production',
              onTap: _busy ? null : () => setState(() { _kind = 'production'; unawaited(_load()); }),
            ),
            if (_unclassified > 0)
              StatusChip(
                label: '$_unclassified dish${_unclassified == 1 ? '' : 'es'} in no group',
                color: AppColors.warning,
                dense: true,
              ),
          ]),
          const SizedBox(height: AppSpacing.md),
          Flexible(
            child: _loading
                ? const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
                : _error != null
                    ? EmptyState(
                        icon: Icons.error_outline,
                        title: 'Could not load the groups',
                        caption: _error!,
                        action: ForkButton.ghost(
                            label: 'Retry', icon: Icons.refresh, dense: true, onPressed: _load),
                      )
                    : ListView(shrinkWrap: true, children: [
                        _groupsBlock(text),
                        const SizedBox(height: AppSpacing.lg),
                        _assignBlock(text),
                      ]),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: ForkButton.ghost(
              label: 'Done',
              dense: true,
              onPressed: _busy ? null : () => Navigator.pop(context, _dirty),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _groupsBlock(TextTheme text) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(title: 'Groups', count: _groups.length, padding: const EdgeInsets.only(bottom: 8)),
      if (_groups.isEmpty)
        Text('No $_kind groups yet. Everything reports as Unclassified until there is one.',
            style: text.bodySmall),
      for (final g in _groups)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ForkCard(
            inset: true,
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(children: [
              Expanded(child: Text(_s(g, 'name'), style: text.titleSmall)),
              if (g['active'] == false)
                StatusChip(label: 'Retired', color: AppColors.neutral, dense: true),
              if (_mayEdit) ...[
                const SizedBox(width: AppSpacing.sm),
                ForkIconButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Rename',
                  onPressed: _busy ? null : () => _renameGroup(g),
                ),
                ForkIconButton(
                  icon: g['active'] == false ? Icons.restart_alt : Icons.block,
                  tooltip: g['active'] == false ? 'Put it back' : 'Retire it',
                  onPressed: _busy ? null : () => _setGroupActive(g, g['active'] == false),
                ),
              ],
            ]),
          ),
        ),
      if (_mayEdit)
        Align(
          alignment: Alignment.centerLeft,
          child: ForkButton.ghost(
            key: const ValueKey('groups-add'),
            label: 'Add a group',
            icon: Icons.add,
            dense: true,
            onPressed: _busy ? null : _addGroup,
          ),
        )
      else
        Text('Only a menu editor can add or rename a group.',
            style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
    ]);
  }

  Widget _assignBlock(TextTheme text) {
    final rows = _showItems ? _items : _categories;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        title: _showItems ? 'Dishes (the exceptions)' : 'Categories (the defaults)',
        count: rows.length,
        padding: const EdgeInsets.only(bottom: 8),
        trailing: ForkButton.subtle(
          key: const ValueKey('groups-toggle-target'),
          label: _showItems ? 'Show categories' : 'Show dishes',
          icon: Icons.swap_horiz,
          onPressed: _busy ? null : () => setState(() => _showItems = !_showItems),
        ),
      ),
      Text(
        _showItems
            ? 'A dish only needs its own group when it should NOT follow its category. '
              'Clearing one puts it back on the category’s answer.'
            : 'Filing a category files every dish under it. This is the ~12 edits that '
              'classify a whole menu.',
        style: text.bodySmall,
      ),
      const SizedBox(height: AppSpacing.sm),
      if (rows.isEmpty)
        Text(_showItems ? 'No dishes on this menu.' : 'No categories on this menu.',
            style: text.bodySmall),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ForkCard(
            inset: true,
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_s(r, 'name'), style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  // The RESOLUTION, not just the field: for a dish the two differ
                  // whenever it is following its category, and showing only the
                  // override would read as "unclassified" for most of the menu.
                  Text(
                    _s(r, 'resolved_group_name', '').isEmpty || _s(r, 'resolved_group_name') == '—'
                        ? 'Unclassified'
                        : '${_s(r, 'resolved_group_name')}'
                            '${_showItems && r['group_id'] == null ? ' (from its category)' : ''}',
                    style: text.bodySmall!.copyWith(
                      color: _s(r, 'resolved_group_name', '').isEmpty
                          ? AppColors.warning
                          : AppColors.textSecondary,
                    ),
                  ),
                ]),
              ),
              if (_mayEdit)
                PopupMenuButton<String>(
                  key: ValueKey('groups-assign-${r['id']}'),
                  tooltip: 'File this under a group',
                  color: AppColors.cardRaised,
                  enabled: !_busy,
                  onSelected: (v) => _assign(
                    categoryId: _showItems ? null : '${r['id']}',
                    menuId: _showItems ? '${r['id']}' : null,
                    groupId: v.isEmpty ? null : v,
                  ),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem<String>(
                      value: '',
                      checked: r['group_id'] == null,
                      child: Text(_showItems ? 'Follow my category' : 'No group'),
                    ),
                    for (final g in _groups)
                      if (g['active'] != false)
                        CheckedPopupMenuItem<String>(
                          value: '${g['id']}',
                          checked: '${g['id']}' == '${r['group_id']}',
                          child: Text(_s(g, 'name')),
                        ),
                  ],
                  child: IgnorePointer(
                    child: ForkButton.ghost(label: 'File', icon: Icons.folder_outlined, dense: true, onPressed: () {}),
                  ),
                ),
            ]),
          ),
        ),
    ]);
  }
}

// ============================================================================
// 039 — MENU VARIATIONS: a dish's price points, for the Variation Summary
// ============================================================================

/// Open the price-point editor for one dish. Returns true when anything was
/// written.
///
/// NEVER A BULK SAVE. Every write here is a targeted POST or PATCH against one
/// variation id; nothing on this screen touches `PUT /menu`, whose bulk save
/// once wiped 56 items' images, sections and recipes.
Future<bool> misOpenMenuVariations(
  BuildContext context, {
  required RestClient rest,
  required Profile profile,
  required String menuId,
  required String itemName,
  required double basePrice,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _MenuVariationsDialog(
      rest: rest,
      profile: profile,
      menuId: menuId,
      itemName: itemName,
      basePrice: basePrice,
    ),
  );
  return changed == true;
}

class _MenuVariationsDialog extends StatefulWidget {
  const _MenuVariationsDialog({
    required this.rest,
    required this.profile,
    required this.menuId,
    required this.itemName,
    required this.basePrice,
  });

  final RestClient rest;
  final Profile profile;
  final String menuId;
  final String itemName;
  final double basePrice;

  @override
  State<_MenuVariationsDialog> createState() => _MenuVariationsDialogState();
}

class _MenuVariationsDialogState extends State<_MenuVariationsDialog> {
  List<Map> _variations = const [];
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  String? _error;

  bool get _mayEdit => widget.profile.isAdmin || _holdsAction(widget.profile, _permEditMenu);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final m = await widget.rest.getMap(
          '/menu-variations?menu_id=${Uri.encodeQueryComponent(widget.menuId)}&include_inactive=1');
      if (!mounted) return;
      setState(() {
        _variations = [for (final v in (m['variations'] as List?) ?? const []) if (v is Map) v];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _captureError(e);
      });
    }
  }

  Future<void> _write(Future<dynamic> Function() call) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await call();
      _dirty = true;
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_captureError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({Map? existing}) async {
    final result = await showDialog<({String name, double price, bool isDefault})>(
      context: context,
      builder: (_) => _VariationEditor(existing: existing, basePrice: widget.basePrice),
    );
    if (result == null || !mounted) return;
    await _write(() => existing == null
        ? widget.rest.post('/menu-variations', {
            'menu_id': widget.menuId,
            'name': result.name,
            'price': result.price,
            'is_default': result.isDefault,
          })
        // A MERGE OVER A SNAPSHOT: only the keys that changed travel, so a
        // client retiring a Half plate can never default its price to ₹0 — which
        // would be a ₹0 FLOOR and an invitation to ring the dish in free.
        : widget.rest.patch('/menu-variations/${existing['id']}', {
            'name': result.name,
            'price': result.price,
            'is_default': result.isDefault,
          }));
  }

  Future<void> _setActive(Map v, bool active) =>
      _write(() => widget.rest.patch('/menu-variations/${v['id']}', {'active': active}));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: math.min(460, size.width - 32),
        constraints: BoxConstraints(maxHeight: size.height * 0.9),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('PRICE POINTS', style: text.labelSmall),
          const SizedBox(height: 4),
          Text(widget.itemName, style: text.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'Sizes of this dish — Half and Full, Regular and Large. Each one’s price is a '
            'FLOOR: a line naming it can never be rung in for less, on the guest QR page or '
            'at the till. Free food is a comp, not a ₹0 size.',
            style: text.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          Flexible(
            child: _loading
                ? const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
                : _error != null
                    ? EmptyState(
                        icon: Icons.error_outline,
                        title: 'Could not load the price points',
                        caption: _error!,
                        action: ForkButton.ghost(
                            label: 'Retry', icon: Icons.refresh, dense: true, onPressed: _load),
                      )
                    : _variations.isEmpty
                        ? EmptyState(
                            icon: Icons.straighten,
                            title: 'One price, no sizes',
                            caption: 'This dish sells at ${_money(widget.basePrice)}. Add a size and '
                                'the Variation Summary starts reporting how the two compare.',
                          )
                        : ListView(shrinkWrap: true, children: [
                            for (final v in _variations) _variationRow(text, v),
                          ]),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(alignment: WrapAlignment.spaceBetween, spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            if (_mayEdit)
              ForkButton.ghost(
                key: const ValueKey('variations-add'),
                label: 'Add a size',
                icon: Icons.add,
                dense: true,
                onPressed: _busy ? null : () => _edit(),
              )
            else
              Text('Only a menu editor can change price points.',
                  style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
            ForkButton.ghost(
              label: 'Done',
              dense: true,
              onPressed: _busy ? null : () => Navigator.pop(context, _dirty),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _variationRow(TextTheme text, Map v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ForkCard(
        inset: true,
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(_s(v, 'name'),
                      style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (v['is_default'] == true) ...[
                  const SizedBox(width: 6),
                  StatusChip(label: 'Default', color: AppColors.info, dense: true),
                ],
              ]),
              Text(_money(v['price']), style: text.bodySmall),
            ]),
          ),
          if (v['active'] == false)
            StatusChip(label: 'Retired', color: AppColors.neutral, dense: true),
          if (_mayEdit) ...[
            const SizedBox(width: AppSpacing.sm),
            ForkIconButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit this size',
              onPressed: _busy ? null : () => _edit(existing: v),
            ),
            ForkIconButton(
              icon: v['active'] == false ? Icons.restart_alt : Icons.block,
              tooltip: v['active'] == false ? 'Offer it again' : 'Retire it',
              onPressed: _busy ? null : () => _setActive(v, v['active'] == false),
            ),
          ],
        ]),
      ),
    );
  }
}

class _VariationEditor extends StatefulWidget {
  const _VariationEditor({this.existing, required this.basePrice});
  final Map? existing;
  final double basePrice;

  @override
  State<_VariationEditor> createState() => _VariationEditorState();
}

class _VariationEditorState extends State<_VariationEditor> {
  late final TextEditingController _name =
      TextEditingController(text: _s(widget.existing ?? const {}, 'name', ''));
  late final TextEditingController _price = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!['price'] ?? ''}');
  late bool _isDefault = widget.existing?['is_default'] == true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim()) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'A size needs a name — "Half", "Large", "500ml".');
      return;
    }
    // A ZERO PRICE IS REFUSED HERE TOO, and not merely because the server does:
    // the price becomes a FLOOR, so a ₹0 size is a standing invitation to ring
    // any quantity of the dish in at nothing with the bill still printing its
    // name. Free food is a non-chargeable, which has a reason and an authoriser.
    if (price <= 0) {
      setState(() => _error = 'A size must cost something. Free food is a comp, not a ₹0 price.');
      return;
    }
    Navigator.pop(context, (name: name, price: price, isDefault: _isDefault));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: math.min(400, width - 32),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.existing == null ? 'ADD A SIZE' : 'EDIT SIZE', style: text.labelSmall),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('variation-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Half / Full / 500ml'),
            ),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('variation-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Price',
                prefixText: '₹ ',
                helperText: 'The dish itself is ${_money(widget.basePrice)}. This price is a floor '
                    'for any line naming this size.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const ValueKey('variation-default'),
              contentPadding: EdgeInsets.zero,
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
              title: const Text('Pre-selected for guests'),
              subtitle: Text(_isDefault
                  ? 'Guests see this size chosen already'
                  : 'Guests must choose a size'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: AppSpacing.lg),
            Wrap(alignment: WrapAlignment.end, spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
              ForkButton.ghost(label: 'Cancel', dense: true, onPressed: () => Navigator.pop(context)),
              ForkButton(
                key: const ValueKey('variation-save'),
                label: 'Save',
                icon: Icons.check,
                dense: true,
                onPressed: _save,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
