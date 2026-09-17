// EMAIL REPORTS — Insights → Reports → Email reports, and the Email button
// beside Export (client item 9).
//
// "All reports or any reports can be emailed to chosen email IDs, automated so
// emails are sent at the end of each day at a specific time to the chosen email
// IDs, with an option to choose/add both the email IDs and the send time."
//
// Three blocks, in the order an owner sets this up — the same three as the web
// dashboard's email-reports.tsx, in the same words (models/report_email.dart):
//   1. THE ADDRESS BOOK. Reports only ever go to addresses in it. Adding and
//      removing is the Settings permission — the server says whether this
//      session holds it (`can_edit_recipients`) and this screen obeys.
//      "Send test email" proves DNS, the provider and the spam folder before the
//      first real report depends on them.
//   2. THE SCHEDULES. Any of the eighteen reports, any minute of the day, one
//      email per schedule with an Excel workbook (CSV optional). A daily
//      schedule covers "the day that just ended": the 24 hours up to its send
//      time. The in-app inbox schedules the Accounting card used to hold are
//      managed here too.
//   3. THE HISTORY, with what happened to each address and the files.
//
// WRITES HERE ARE ONLINE ONLY. None of these routes is on the outbox allowlist
// (services/outbox.dart), so offline they are refused with
// OutboxPolicy.unsupported — an email must never go out twice because a queued
// copy replayed. Send now carries one client request id per opening, so a retry
// after a dropped answer is the SAME send.
//
// A `part` of modules.dart for the reason reports.dart is: the history's rows
// format time and money through the library's private helpers, and the Send
// sheet is opened from the report pane's action bar.
part of 'modules.dart';

Color _emailTone(String tone) => switch (tone) {
      'ok' => AppColors.success,
      'bad' => AppColors.danger,
      'pending' => AppColors.warning,
      _ => AppColors.neutral,
    };

/// The server's machine word for a refusal, when it sent one.
String? _emailCode(Object e) {
  if (e is ApiException) {
    final code = e.body?['code'];
    return code is String ? code : null;
  }
  return null;
}

/// The sentence to show for a failed write: the server's own, or the outbox's
/// "reconnect" when the line is down.
String _emailError(Object e) => e is ApiException ? e.message : '$e';

Widget _emailSheetFrame(BuildContext context, Widget child, {required bool narrow}) {
  if (narrow) return child;
  return Container(
    width: 620,
    decoration: BoxDecoration(
      gradient: AppColors.cardGradient,
      borderRadius: AppRadius.cardAll,
      border: Border.all(color: AppColors.borderStrong),
    ),
    child: child,
  );
}

/// Shows [child] as a bottom sheet on a phone and a dialog above [_misNarrow].
Future<T?> _showEmailSheet<T>(BuildContext context, Widget Function(BuildContext) builder) {
  final narrow = MediaQuery.sizeOf(context).width < _misNarrow;
  if (narrow) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.9),
            child: builder(ctx),
          ),
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.9),
        child: _emailSheetFrame(ctx, builder(ctx), narrow: false),
      ),
    ),
  );
}

/// The Email button's action: Send now for the report and days on screen.
Future<void> _openEmailSend(
  BuildContext context, {
  required RestClient rest,
  required String reportKey,
  required DateRange range,
  required String? slotPhrase,
}) {
  return _showEmailSheet<void>(
    context,
    (ctx) => _EmailSendSheet(rest: rest, reportKey: reportKey, from: range.from, to: range.to, slotPhrase: slotPhrase),
  );
}

// ------------------------------------------------------------- send now ------

class _EmailSendSheet extends StatefulWidget {
  const _EmailSendSheet({
    required this.rest,
    required this.reportKey,
    required this.from,
    required this.to,
    required this.slotPhrase,
  });

  final RestClient rest;
  final String reportKey;
  final String from;
  final String to;

  /// The session filter on screen ("Lunch"), which an email does not apply.
  final String? slotPhrase;

  @override
  State<_EmailSendSheet> createState() => _EmailSendSheetState();
}

class _EmailSendSheetState extends State<_EmailSendSheet> {
  /// The last send's id: reused only by a retry of the SAME choices before a
  /// final answer (requestIdFor). One id per opening once replayed an old
  /// failed send in place of the corrected one.
  LastSend? _last;
  ReportEmailConfig? _config;
  List<BookEntry> _book = const [];
  bool _loaded = false;
  late List<String> _keys = [widget.reportKey];
  List<String> _formats = ['xlsx'];
  bool _closeOn = false;
  int _closeHour = 2;
  int _closeMinute = 0;
  final List<String> _chosen = <String>[];
  String? _error;
  bool _sending = false;
  Map? _delivery;

  bool get _combined => widget.rest.auth.selectedOutletId == 'all';
  String get _mode => _closeOn ? 'trading_day' : 'calendar';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.rest.getMap('/reports/email/config').catchError((_) => <String, dynamic>{}),
      widget.rest.getMap('/reports/email/recipients').catchError((_) => <String, dynamic>{}),
    ]);
    if (!mounted) return;
    setState(() {
      _config = ReportEmailConfig.fromJson(results[0]);
      _book = [for (final b in BookEntry.listFromJson(results[1]) ?? const <BookEntry>[]) if (b.active) b];
      _loaded = true;
    });
  }

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    // A fresh id is only USED when this is not a retry of the last send.
    final fresh = newClientRequestId();
    final built = buildSendBody(
      clientRequestId: fresh,
      reportKeys: _keys,
      formats: _formats,
      from: widget.from,
      to: widget.to,
      dayClose: _closeOn ? hhmm(_closeHour, _closeMinute) : '',
      allOutlets: _combined,
      recipientIds: _chosen,
      maxRecipients: _config?.recipientsPerSend ?? kMaxRecipientsPerSend,
    );
    if (built.body == null) {
      setState(() => _error = built.error);
      return;
    }
    final key = sendBodyKey(built.body!);
    final current = LastSend(requestIdFor(_last, key, () => fresh), key);
    _last = current;
    setState(() {
      _error = null;
      _sending = true;
      _delivery = null;
    });
    try {
      // The combined scope is in the BODY; the request itself runs as the
      // session's own outlet, because the server refuses writes made "as all".
      final home = widget.rest.auth.profile?.outletId;
      final res = await widget.rest.post(
        '/reports/email/send',
        {...built.body!, 'client_request_id': current.id},
        _combined && home != null && home.isNotEmpty ? home : null,
      );
      final id = res is Map ? '${res['delivery_id'] ?? ''}' : '';
      Map? last;
      var timedOut = true;
      for (var i = 0; i < kPollMaxTries && mounted && id.isNotEmpty; i++) {
        await Future<void>.delayed(kPollInterval);
        if (!mounted) return;
        try {
          final d = (await widget.rest.getMap('/reports/deliveries/$id'))['delivery'];
          if (d is Map) {
            last = d;
            setState(() => _delivery = d);
            if (isResting(d)) {
              timedOut = false;
              break;
            }
          }
        } catch (_) {
          // A poll that fails is not a failed send; the history has the answer.
        }
      }
      // A FINAL answer ends this id: the next press is a new send.
      if (last != null && isFinalDelivery(last)) current.settled = true;
      final outcome = sendOutcome(last, timedOut: timedOut, wallOf: RestaurantTime.wallOf);
      messenger.showSnackBar(SnackBar(content: Text('${outcome.title}. ${outcome.description}')));
      if (mounted && last != null && '${last['status']}' == 'delivered') Navigator.of(context).pop();
    } catch (e) {
      final message = _emailError(e);
      if (mounted) setState(() => _error = message);
      messenger.showSnackBar(SnackBar(content: Text('${refusalTitle(_emailCode(e))}. $message')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final config = _config;
    final blocked = _loaded ? sendNowBlocked(config) : null;
    final allRefused = _combined && config != null && !config.canUseAllOutlets;
    final max = config?.recipientsPerSend ?? kMaxRecipientsPerSend;
    final catalogue = config?.reports ?? kEmailableReports;
    final allMis = kMisEmailKeys.every(_keys.contains);
    final rows = _delivery == null ? const <({String email, String outcome})>[] : recipientOutcomes(_delivery!);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('SEND NOW', style: text.labelSmall),
        const SizedBox(height: 4),
        Text(kEmailAreaTitle, style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          '${_combined ? 'All outlets (combined)' : 'This outlet'} · the server builds the files and emails each address separately.',
          style: text.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        if (!_loaded)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Checking the email settings…', style: text.bodySmall)),
            ]),
          )
        else ...[
          if (blocked != null || allRefused)
            _EmailBannerView(
              key: const ValueKey('email-send-blocked'),
              banner: (
                tone: 'error',
                title: blocked ?? 'All outlets needs an admin or a manager',
                detail: blocked != null
                    ? 'Nothing can be emailed until this is fixed. Reports can still be exported from this screen.'
                    : 'Pick a single outlet to email its reports.',
              ),
            ),
          // A Wrap, not a Row: on a 360dp phone at 1.3x the heading and the
          // shortcut do not fit side by side.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.sm,
            children: [
              Text('Reports · ${reportListPhrase(orderedReportKeys(_keys))}', style: text.titleSmall),
              ForkButton.subtle(
                label: allMis ? 'Only this report' : kAllMisReports,
                onPressed: () => setState(() => _keys = allMis
                    ? [widget.reportKey]
                    : orderedReportKeys([..._keys, ...kMisEmailKeys])),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _ReportPicker(
            catalogue: catalogue,
            selected: _keys,
            mode: _mode,
            onToggle: (k) => setState(() => _keys = _keys.contains(k)
                ? [for (final x in _keys) if (x != k) x]
                : orderedReportKeys([..._keys, k])),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Days · ${periodPhrase(widget.from, widget.to)}', style: text.titleSmall),
          Text('Change the dates on the Reports screen before opening this.', style: text.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            key: const ValueKey('email-close-switch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _closeOn,
            onChanged: (v) => setState(() => _closeOn = v),
            title: const Text('Close each day at a set time'),
            subtitle: Text(_closeOn
                ? 'Each day runs for 24 hours up to ${hhmm(_closeHour, _closeMinute)} — bills settled after midnight count on the day they belong to. GST and Profit & Loss are calendar days only.'
                : "Calendar days, midnight to midnight, in the restaurant's time zone."),
          ),
          if (_closeOn)
            _ClockPicker(
              hour: _closeHour,
              minute: _closeMinute,
              label: 'Close each day at',
              onChanged: (h, m) => setState(() {
                _closeHour = h;
                _closeMinute = m;
              }),
            ),
          if (widget.slotPhrase != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('$kWholeDaysNote (${widget.slotPhrase})',
                key: const ValueKey('email-whole-days'), style: text.bodySmall!.copyWith(color: AppColors.warning)),
          ],
          const SizedBox(height: AppSpacing.md),
          Text('Attach as', style: text.titleSmall),
          _FormatPicker(
            formats: config?.formats ?? const ['xlsx', 'csv'],
            selected: _formats,
            onToggle: (f) => setState(() => _formats = _formats.contains(f)
                ? [for (final x in _formats) if (x != f) x]
                : orderedFormats([..._formats, f])),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Send to (up to $max)', style: text.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          if (_book.isEmpty)
            Text(
              'No addresses in the address book yet. Reports can only be emailed to addresses in it — '
              'add one under $kEmailAreaTitle → $kAddressBookTitle.',
              key: const ValueKey('email-send-empty-book'),
              style: text.bodySmall,
            )
          else
            _RecipientPicker(
              book: _book,
              selected: _chosen,
              max: max,
              onToggle: (id) => setState(() {
                if (_chosen.contains(id)) {
                  _chosen.remove(id);
                } else if (_chosen.length < max) {
                  _chosen.add(id);
                }
              }),
            ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _OutcomeList(rows: rows),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, key: const ValueKey('email-send-error'), style: text.bodySmall!.copyWith(color: AppColors.danger)),
          ],
        ],
        const SizedBox(height: AppSpacing.lg),
        Wrap(alignment: WrapAlignment.end, spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
          ForkButton.ghost(
            key: const ValueKey('email-send-close'),
            label: 'Close',
            onPressed: _sending ? null : () => Navigator.of(context).pop(),
          ),
          ForkButton(
            key: const ValueKey('email-send'),
            label: _sending ? 'Sending…' : 'Send',
            icon: Icons.send_outlined,
            onPressed: !_loaded || _sending || blocked != null || allRefused || _book.isEmpty ? null : _send,
          ),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------ shared bits ----

class _EmailBannerView extends StatelessWidget {
  const _EmailBannerView({super.key, required this.banner});
  final EmailBanner banner;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = banner.tone == 'error'
        ? AppColors.danger
        : banner.tone == 'warning'
            ? AppColors.warning
            : AppColors.info;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: AppRadius.controlAll,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(banner.tone == 'info' ? Icons.info_outline : Icons.error_outline, size: 16, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(banner.title, style: text.bodyMedium!.copyWith(fontWeight: FontWeight.w600)),
            if (banner.detail != null) Text(banner.detail!, style: text.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

class _ReportPicker extends StatelessWidget {
  const _ReportPicker({required this.catalogue, required this.selected, required this.mode, required this.onToggle});
  final List<EmailableReport> catalogue;
  final List<String> selected;
  final String mode;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final r in catalogue)
        Builder(builder: (context) {
          final why = reportDisabledReason(r.key, mode);
          return FilterChip(
            key: ValueKey('email-report-${r.key}'),
            label: Text(why == null ? r.title : '${r.title} ($why)'),
            selected: selected.contains(r.key),
            onSelected: why == null ? (_) => onToggle(r.key) : null,
            visualDensity: VisualDensity.compact,
          );
        }),
    ]);
  }
}

class _FormatPicker extends StatelessWidget {
  const _FormatPicker({required this.formats, required this.selected, required this.onToggle});
  final List<String> formats;
  final List<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final f in formats)
        FilterChip(
          key: ValueKey('email-format-$f'),
          label: Text(kFormatLabels[f] ?? f),
          selected: selected.contains(f),
          onSelected: (_) => onToggle(f),
          visualDensity: VisualDensity.compact,
        ),
    ]);
  }
}

class _RecipientPicker extends StatelessWidget {
  const _RecipientPicker({required this.book, required this.selected, required this.max, required this.onToggle});
  final List<BookEntry> book;
  final List<String> selected;
  final int max;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final b in book)
        FilterChip(
          key: ValueKey('email-to-${b.id}'),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(b.display, overflow: TextOverflow.ellipsis),
          ),
          tooltip: b.email,
          selected: selected.contains(b.id),
          onSelected: selected.contains(b.id) || selected.length < max ? (_) => onToggle(b.id) : null,
          visualDensity: VisualDensity.compact,
        ),
    ]);
  }
}

class _OutcomeList extends StatelessWidget {
  const _OutcomeList({required this.rows});
  final List<({String email, String outcome})> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(
              r.outcome == 'sent'
                  ? Icons.check_circle_outline
                  : r.outcome == 'waiting'
                      ? Icons.schedule
                      : Icons.highlight_off,
              size: 14,
              color: r.outcome == 'sent'
                  ? AppColors.success
                  : r.outcome == 'waiting'
                      ? AppColors.textTertiary
                      : AppColors.danger,
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(r.email, style: text.bodySmall, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            Text(kRecipientOutcomeLabels[r.outcome] ?? r.outcome, style: text.bodySmall),
          ]),
        ),
    ]);
  }
}

/// Hour and minute, every minute of the day — the restaurant's clock.
class _ClockPicker extends StatelessWidget {
  const _ClockPicker({required this.hour, required this.minute, required this.label, required this.onChanged});
  final int hour;
  final int minute;
  final String label;
  final void Function(int hour, int minute) onChanged;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    return Row(children: [
      Expanded(
        child: DropdownButtonFormField<int>(
          key: ValueKey('${label.toLowerCase().replaceAll(' ', '-')}-hour'),
          initialValue: hour,
          isExpanded: true,
          dropdownColor: AppColors.cardRaised,
          borderRadius: AppRadius.controlAll,
          decoration: InputDecoration(labelText: '$label · hour', isDense: true),
          items: [for (var i = 0; i < 24; i++) DropdownMenuItem(value: i, child: Text(two(i)))],
          onChanged: (v) => onChanged(v ?? hour, minute),
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: DropdownButtonFormField<int>(
          key: ValueKey('${label.toLowerCase().replaceAll(' ', '-')}-minute'),
          initialValue: minute,
          isExpanded: true,
          dropdownColor: AppColors.cardRaised,
          borderRadius: AppRadius.controlAll,
          menuMaxHeight: 320,
          decoration: const InputDecoration(labelText: 'minute', isDense: true),
          items: [for (var i = 0; i < 60; i++) DropdownMenuItem(value: i, child: Text(two(i)))],
          onChanged: (v) => onChanged(hour, v ?? minute),
        ),
      ),
    ]);
  }
}

// --------------------------------------------------------- the area -----------

class _EmailReportsPanel extends StatefulWidget {
  const _EmailReportsPanel({required this.rest});
  final RestClient rest;

  @override
  State<_EmailReportsPanel> createState() => _EmailReportsPanelState();
}

class _EmailReportsPanelState extends State<_EmailReportsPanel> {
  ReportEmailConfig? _config;
  bool _asked = false;
  List<BookEntry> _book = const [];
  bool _bookFailed = false;
  List<Map> _schedules = const [];
  bool _schedulesFailed = false;
  List<Map> _deliveries = const [];
  bool _historyFailed = false;
  bool _busy = false;
  String? _open;
  Timer? _poll;
  final TextEditingController _email = TextEditingController();
  final TextEditingController _label = TextEditingController();
  String? _addProblem;

  bool get _combined => widget.rest.auth.selectedOutletId == 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _email.dispose();
    _label.dispose();
    super.dispose();
  }

  List<Map> _maps(Object? v) => v is List ? [for (final x in v) if (x is Map) x] : const [];

  Future<void> _load() async {
    final results = await Future.wait<Object?>([
      widget.rest.getMap('/reports/email/config').then<Object?>((m) => m).catchError((_) => null),
      widget.rest.getMap('/reports/email/recipients').then<Object?>((m) => m).catchError((_) => null),
      widget.rest.getMap('/reports/schedules').then<Object?>((m) => m).catchError((_) => null),
      widget.rest.getMap('/reports/deliveries?limit=30').then<Object?>((m) => m).catchError((_) => null),
    ]);
    if (!mounted) return;
    final book = BookEntry.listFromJson(results[1]);
    final schedules = results[2] is Map ? (results[2] as Map)['schedules'] : null;
    final deliveries = results[3] is Map ? (results[3] as Map)['deliveries'] : null;
    setState(() {
      _asked = true;
      _config = ReportEmailConfig.fromJson(results[0]);
      _book = book ?? const [];
      _bookFailed = book == null;
      _schedules = _maps(schedules);
      _schedulesFailed = schedules is! List;
      _deliveries = _maps(deliveries);
      _historyFailed = deliveries is! List;
    });
    _schedulePoll();
  }

  /// A delivery still in flight — or waiting for the server's retry — refreshes
  /// the history by itself, for [kWatchMaxAge] after it was asked for (the
  /// web's cap). Uncapped, a row that never settled re-read the history every
  /// six seconds for as long as the panel stayed open.
  void _schedulePoll() {
    _poll?.cancel();
    final now = DateTime.now();
    final inFlight = _deliveries.any((d) => isWatched(d, now));
    if (!inFlight) return;
    _poll = Timer(kPollInterval * 3, () async {
      try {
        final m = await widget.rest.getMap('/reports/deliveries?limit=30');
        if (!mounted) return;
        setState(() => _deliveries = _maps(m['deliveries']));
        _schedulePoll();
      } catch (_) {}
    });
  }

  Future<void> _write(Future<void> Function() work, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await work();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
      await _load();
    } catch (e) {
      final code = _emailCode(e);
      messenger.showSnackBar(SnackBar(
          content: Text(code == null ? _emailError(e) : '${refusalTitle(code)}. ${_emailError(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ the book --

  Future<void> _add() async {
    final max = _config?.addressBookMax ?? kMaxAddressBook;
    final why = addressProblem(_email.text, _book, max);
    if (why != null) {
      setState(() => _addProblem = why);
      return;
    }
    final email = _email.text.trim();
    final label = _label.text.trim();
    setState(() => _addProblem = null);
    await _write(() async {
      await widget.rest.post('/reports/email/recipients', {'email': email, 'label': label.isEmpty ? null : label});
      _email.clear();
      _label.clear();
    }, done: '$email can now be chosen for reports.');
  }

  Future<void> _remove(BookEntry b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this address?'),
        content: Text('${b.email} stops receiving reports — every schedule skips it from the next run.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _write(() => widget.rest.delete('/reports/email/recipients/${b.id}'),
        done: '${b.email} will not receive any more reports.');
  }

  Future<void> _test(BookEntry b) => _write(
        () => widget.rest.post('/reports/email/test', {'recipient_id': b.id, 'client_request_id': newClientRequestId()}),
        done: 'Test email queued — check ${b.email} in a minute, and its spam folder.',
      );

  // ------------------------------------------------------- the schedules --

  Future<void> _edit({Map? existing}) async {
    final found = existing == null
        ? (form: EmailScheduleForm(channel: _config?.emailAvailable == true ? 'email' : 'inbox'), missing: const <String>[])
        : EmailScheduleForm.fromSchedule(existing, _book);
    final patch = await _showEmailSheet<Map<String, dynamic>>(
      context,
      (ctx) => _EmailScheduleEditor(
        form: found.form,
        missing: found.missing,
        isNew: existing == null,
        config: _config,
        book: [for (final b in _book) if (b.active) b],
      ),
    );
    if (patch == null) return;
    await _write(() async {
      if (existing == null) {
        await widget.rest.post('/reports/schedules', patch);
      } else {
        await widget.rest.patch('/reports/schedules/${existing['id']}', patch);
      }
    }, done: existing == null ? 'Schedule created' : 'Schedule updated');
  }

  Future<void> _setEnabled(Map s, bool enabled) =>
      _write(() => widget.rest.patch('/reports/schedules/${s['id']}', {'enabled': enabled}),
          done: enabled ? 'Schedule resumed' : 'Schedule paused');

  // Queues one extra run; the server builds it in the background. 409 is the
  // per-minute dedup working — the first click's run is still on its way.
  Future<void> _runNow(Map s) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.rest.post('/reports/schedules/${s['id']}/run-now');
      messenger.showSnackBar(const SnackBar(content: Text('Queued — its result appears in the history below.')));
    } catch (e) {
      if (e is ApiException && e.status == 409) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Already queued a moment ago — that run is still on its way, so nothing extra was queued. '
                'Watch the history.')));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(_emailError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _delete(Map s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this schedule?'),
        content: Text('"${_s(s, 'name')}" stops running. Reports it already produced stay in the history and can still be downloaded.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _write(() => widget.rest.delete('/reports/schedules/${s['id']}'), done: 'Schedule removed');
  }

  // --------------------------------------------------------- the history --

  Future<void> _download(Map d, Map f) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = _s(f, 'filename', 'report');
    try {
      final bytes = await widget.rest.getBytes('/reports/deliveries/${d['id']}/files/${f['id']}');
      final result = await ReportExporter.deliver(
          bytes, name, '${f['format']}' == 'xlsx' ? ReportFormat.excel : ReportFormat.csv);
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_emailError(e))));
    }
  }

  Future<void> _downloadLegacy(Map d) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = _s(d, 'artifact_name', 'report.csv');
    try {
      final csv = await widget.rest.getText('/reports/deliveries/${d['id']}/download');
      final result = await ReportExporter.deliver(Uint8List.fromList(utf8.encode(csv)), name, ReportFormat.csv);
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_emailError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final banners = _asked ? configBanners(_config) : const <EmailBanner>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('email-reports-panel'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          for (final b in banners) _EmailBannerView(banner: b),
          if (!_asked)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            _bookSection(context, text),
            const SizedBox(height: AppSpacing.xl),
            _schedulesSection(context, text),
            const SizedBox(height: AppSpacing.xl),
            _historySection(context, text),
          ],
        ],
      ),
    );
  }

  Widget _bookSection(BuildContext context, TextTheme text) {
    final canEdit = _config?.canEditRecipients == true;
    final mailReady = _config?.emailAvailable == true && _config?.schemaReady == true;
    final max = _config?.addressBookMax ?? kMaxAddressBook;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(title: kAddressBookTitle, count: _book.length, padding: const EdgeInsets.only(bottom: 6)),
      Text(
        'Reports are only ever emailed to these addresses — up to $max. They do not need a login. '
        'Removing an address stops every schedule from emailing it.',
        style: text.bodySmall,
      ),
      const SizedBox(height: AppSpacing.sm),
      if (_bookFailed)
        Text("Couldn't load the address book.", style: text.bodySmall)
      else if (_book.isEmpty)
        Text(kAddressBookEmpty, style: text.bodySmall)
      else
        ForkCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(children: [
            for (var i = 0; i < _book.length; i++) ...[
              if (i > 0) Container(height: 1, color: AppColors.divider),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(_book[i].label ?? _book[i].email,
                            style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (_book[i].label != null)
                          Text(_book[i].email, style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    if (!_book[i].active) StatusChip(label: 'Paused', color: AppColors.neutral, dense: true),
                    if (canEdit) ...[
                      ForkButton.ghost(
                        key: ValueKey('email-test-${_book[i].id}'),
                        label: kTestEmailLabel,
                        icon: Icons.outgoing_mail,
                        dense: true,
                        onPressed: !_busy && mailReady && _book[i].active ? () => _test(_book[i]) : null,
                      ),
                      ForkIconButton(
                        key: ValueKey('email-remove-${_book[i].id}'),
                        icon: Icons.delete_outline,
                        tooltip: 'Remove ${_book[i].email}',
                        onPressed: _busy ? null : () => _remove(_book[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ]),
        ),
      const SizedBox(height: AppSpacing.sm),
      if (canEdit) ...[
        LayoutBuilder(builder: (context, box) {
          final email = TextField(
            key: const ValueKey('email-add-address'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) {
              if (_addProblem != null) setState(() => _addProblem = null);
            },
            decoration: const InputDecoration(labelText: 'Email address', hintText: 'name@example.com', isDense: true),
          );
          final label = TextField(
            key: const ValueKey('email-add-label'),
            controller: _label,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Label (optional)', isDense: true, counterText: ''),
          );
          final add = ForkButton(
            key: const ValueKey('email-add'),
            label: 'Add address',
            icon: Icons.add,
            dense: true,
            onPressed: _busy || _book.length >= max ? null : _add,
          );
          if (box.maxWidth < 560) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              email,
              const SizedBox(height: AppSpacing.xs),
              label,
              const SizedBox(height: AppSpacing.sm),
              Align(alignment: Alignment.centerRight, child: add),
            ]);
          }
          return Row(children: [
            Expanded(flex: 2, child: email),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: label),
            const SizedBox(width: AppSpacing.sm),
            add,
          ]);
        }),
        if (_addProblem != null)
          Text(_addProblem!, key: const ValueKey('email-add-problem'), style: text.bodySmall!.copyWith(color: AppColors.danger)),
      ] else
        Text(kAddressBookReadOnly, key: const ValueKey('email-book-read-only'), style: text.bodySmall),
    ]);
  }

  Widget _schedulesSection(BuildContext context, TextTheme text) {
    final emailOk = _config?.emailAvailable == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        title: 'Schedules',
        count: _schedules.length,
        trailing: _combined
            ? null
            : ForkButton.ghost(
                key: const ValueKey('email-new-schedule'),
                label: 'New schedule',
                icon: Icons.add,
                dense: true,
                onPressed: _busy ? null : () => _edit(),
              ),
        padding: const EdgeInsets.only(bottom: 6),
      ),
      Text(
        'Any reports, any time of day, one email per schedule. A daily schedule covers the day that just ended — '
        'the 24 hours up to its send time. Times are the restaurant\'s clock (${RestaurantTime.zone}).',
        style: text.bodySmall,
      ),
      if (_combined) ...[
        const SizedBox(height: AppSpacing.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline, size: 14, color: AppColors.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'All outlets (combined) is a read-only view: every outlet\'s schedules are listed here and none of them can be '
              'changed from it. Switch to a single outlet to create, edit, pause, delete or run one.',
              style: text.bodySmall,
            ),
          ),
        ]),
      ],
      const SizedBox(height: AppSpacing.md),
      if (_schedulesFailed)
        Text("Couldn't load the schedules.", style: text.bodySmall)
      else if (_schedules.isEmpty)
        Text('No schedules yet — create one and the reports arrive without anyone opening the app.', style: text.bodySmall)
      else
        for (final s in _schedules)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _scheduleRow(context, s, emailOk)),
    ]);
  }

  Widget _scheduleRow(BuildContext context, Map s, bool emailOk) {
    final text = Theme.of(context).textTheme;
    final on = s['enabled'] != false;
    final keys = [for (final k in (s['report_keys'] is List ? s['report_keys'] as List : const [])) '$k'];
    final formats = [for (final f in (s['formats'] is List ? s['formats'] as List : [s['format'] ?? 'csv'])) '$f'.toUpperCase()];
    final email = s['channel'] == 'email';
    final recipients = [for (final r in (s['recipients'] is List ? s['recipients'] as List : const [])) '$r'];
    final lastStatus = _s(s, 'last_status', '');
    final lastError = _s(s, 'last_error', '');
    final failures = _int(s['consecutive_failures']) ?? 0;
    final next = nextRunCaption(s, RestaurantTime.wallOf);
    return ForkCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        _recordHeadRow(
          context,
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.inset,
              borderRadius: AppRadius.controlAll,
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(email ? Icons.forward_to_inbox : Icons.event_repeat_outlined,
                size: 16, color: on ? AppColors.textSecondary : AppColors.textTertiary),
          ),
          identity: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(_s(s, 'name', 'Scheduled report'), style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(
              '${reportListPhrase(keys.isNotEmpty ? keys : [_s(s, 'report_key', 'sales')])} · ${formats.join(' + ')}'
              '${s['outlet_scope'] == 'all' ? ' · all outlets' : ''}',
              style: text.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${cadenceCaption(s)} · ${email ? 'Email to ${recipients.isEmpty ? 'nobody yet' : recipients.join(', ')}' : 'In-app inbox'}',
              style: text.bodySmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (next.isNotEmpty) Text(next, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
          trailing: [
            StatusChip(label: on ? 'On' : 'Paused', color: on ? AppColors.success : AppColors.neutral, dense: true),
            if (lastStatus.isNotEmpty)
              StatusChip(
                label: lastStatus == 'delivered' ? 'Last run OK' : 'Last run failed',
                color: lastStatus == 'delivered' ? AppColors.success : AppColors.danger,
                dense: true,
              ),
            if (!_combined) ...[
              ForkButton.ghost(
                label: 'Run now',
                icon: Icons.play_arrow_outlined,
                dense: true,
                onPressed: _busy || (email && !emailOk) ? null : () => _runNow(s),
              ),
              PopupMenuButton<String>(
                iconColor: AppColors.textSecondary,
                enabled: !_busy,
                onSelected: (v) {
                  if (v == 'edit') _edit(existing: s);
                  if (v == 'toggle') _setEnabled(s, !on);
                  if (v == 'delete') _delete(s);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'toggle', child: Text(on ? 'Pause' : 'Resume')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ],
        ),
        if (lastStatus.isNotEmpty && lastStatus != 'delivered' && lastError.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${_capped(lastError, 200)}${failures > 0 ? ' · $failures failure${failures == 1 ? '' : 's'} in a row' : ''}',
            style: text.bodySmall!.copyWith(color: AppColors.danger),
          ),
        ],
        if (!on && failures > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Paused automatically after repeated failures — fix the cause, then resume it.', style: text.bodySmall),
        ],
      ]),
    );
  }

  Widget _historySection(BuildContext context, TextTheme text) {
    final names = <String, Map>{for (final s in _schedules) _s(s, 'id', ''): s}..remove('');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        title: 'History',
        count: _deliveries.length,
        trailing: ForkButton.ghost(label: 'Refresh', icon: Icons.refresh, dense: true, onPressed: _load),
        padding: const EdgeInsets.only(bottom: 6),
      ),
      Text('Every run and every send, with what happened to each address. Files are kept for 90 days.', style: text.bodySmall),
      const SizedBox(height: AppSpacing.sm),
      if (_historyFailed)
        Text("Couldn't load the history.", style: text.bodySmall)
      else if (_deliveries.isEmpty)
        Text('Nothing has run yet.', style: text.bodySmall)
      else
        ForkCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            for (var i = 0; i < _deliveries.length; i++) ...[
              if (i > 0) Container(height: 1, color: AppColors.divider),
              _deliveryRow(context, _deliveries[i], names),
            ],
          ]),
        ),
    ]);
  }

  Widget _deliveryRow(BuildContext context, Map d, Map<String, Map> schedules) {
    final text = Theme.of(context).textTheme;
    final id = _s(d, 'id', '');
    final status = deliveryStatus(d);
    final kind = deliveryKind(d);
    final schedule = schedules['${d['schedule_id']}'];
    final title = d['kind'] == 'adhoc'
        ? kind
        : schedule == null
            ? 'Removed schedule'
            : _s(schedule, 'name', 'Scheduled report');
    final keys = [for (final k in (d['report_keys'] is List ? d['report_keys'] as List : const [])) '$k'];
    final scheduled = schedule != null && schedule['recipients'] is List
        ? [for (final r in schedule['recipients'] as List) '$r']
        : const <String>[];
    final rows = recipientOutcomes(d, scheduled);
    final files = [for (final f in (d['files'] is List ? d['files'] as List : const [])) if (f is Map) f];
    final window = d['day_close'] != null && _s(d, 'window_start_at', '').isNotEmpty
        ? '${wallClock(_s(d, 'window_start_at', ''), RestaurantTime.wallOf)} → ${wallClock(_s(d, 'window_end_at', ''), RestaurantTime.wallOf)}'
        : periodPhrase(_s(d, 'period_from', ''), _s(d, 'period_to', ''));
    final attempts = _int(d['attempts']) ?? 0;
    final sent = rows.where((r) => r.outcome == 'sent').length;
    final expanded = _open == id;
    final error = _s(d, 'error', '');
    final retry = retryCaption(d, RestaurantTime.wallOf);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          key: ValueKey('email-delivery-$id'),
          onTap: () => setState(() => _open = expanded ? null : id),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.textTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [if (keys.isNotEmpty) reportListPhrase(keys), window].join(' · '),
                  style: text.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    if (d['kind'] != 'adhoc') kind,
                    _fmtTime(_s(d, 'fire_at', '')),
                    if (d['channel'] == 'email' && rows.isNotEmpty) '$sent/${rows.length} sent',
                    if (attempts > 1) '$attempts attempts',
                    if (d['maybe_duplicate'] == true) 'may have been sent twice',
                  ].where((p) => p.isNotEmpty).join(' · '),
                  style: text.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
            const SizedBox(width: AppSpacing.sm),
            StatusChip(label: status.label, color: _emailTone(status.tone), dense: true),
          ]),
        ),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(_capped(error, 160),
              style: text.bodySmall!.copyWith(color: isFinalDelivery(d) ? AppColors.danger : AppColors.textTertiary)),
        ],
        if (retry.isNotEmpty)
          Text(retry, key: ValueKey('email-delivery-retry-$id'), style: text.bodySmall),
        if (expanded) ...[
          const SizedBox(height: AppSpacing.sm),
          if (rows.isNotEmpty) _OutcomeList(rows: rows),
          const SizedBox(height: AppSpacing.xs),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            for (final f in files)
              ForkButton.ghost(
                key: ValueKey('email-file-${f['id']}'),
                label: fileLabel(f),
                icon: Icons.download_outlined,
                dense: true,
                onPressed: f['purged'] == true ? null : () => _download(d, f),
              ),
            if (files.isEmpty && _s(d, 'artifact_name', '').isNotEmpty)
              ForkButton.ghost(
                label: 'CSV',
                icon: Icons.download_outlined,
                dense: true,
                onPressed: () => _downloadLegacy(d),
              ),
            if (files.isEmpty && _s(d, 'artifact_name', '').isEmpty)
              Text(d['kind'] == 'adhoc' && keys.isEmpty ? 'A test email carries no files.' : 'No files yet.',
                  style: text.bodySmall),
          ]),
          if (d['day_close'] != null)
            Text('Trading day closing ${d['day_close']} · times in ${_s(d, 'timezone', RestaurantTime.zone)}',
                style: text.bodySmall),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------ the editor ------------

class _EmailScheduleEditor extends StatefulWidget {
  const _EmailScheduleEditor({
    required this.form,
    required this.missing,
    required this.isNew,
    required this.config,
    required this.book,
  });

  final EmailScheduleForm form;
  final List<String> missing;
  final bool isNew;
  final ReportEmailConfig? config;
  final List<BookEntry> book;

  @override
  State<_EmailScheduleEditor> createState() => _EmailScheduleEditorState();
}

class _EmailScheduleEditorState extends State<_EmailScheduleEditor> {
  late final EmailScheduleForm _f = widget.form;
  late final TextEditingController _name = TextEditingController(text: widget.form.name);
  bool _recipientsTouched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recipientsTouched = widget.isNew;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    _f.name = _name.text;
    final built = buildSchedulePatch(
      _f,
      maxRecipients: widget.config?.recipientsPerSend ?? kMaxRecipientsPerSend,
      recipientsTouched: _recipientsTouched,
    );
    if (built.patch == null) {
      setState(() => _error = built.error);
      return;
    }
    Navigator.of(context).pop(built.patch);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final emailOk = widget.config?.emailAvailable == true;
    final mode = _f.frequency == 'daily' ? _f.windowMode : 'calendar';
    final max = widget.config?.recipientsPerSend ?? kMaxRecipientsPerSend;
    final allMis = kMisEmailKeys.every(_f.reportKeys.contains);
    const weekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('SCHEDULED REPORT', style: text.labelSmall),
        const SizedBox(height: 4),
        Text(widget.isNew ? 'New schedule' : 'Edit schedule', style: text.titleMedium),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const ValueKey('schedule-name'),
          controller: _name,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Name (e.g. Nightly close)', isDense: true, counterText: ''),
        ),
        const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<String>(
          key: const ValueKey('schedule-frequency'),
          initialValue: _f.frequency,
          isExpanded: true,
          dropdownColor: AppColors.cardRaised,
          borderRadius: AppRadius.controlAll,
          decoration: const InputDecoration(labelText: 'How often', isDense: true),
          items: const [
            DropdownMenuItem(value: 'daily', child: Text('Daily')),
            DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
            DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
          ],
          onChanged: (v) => setState(() {
            _f.frequency = v ?? 'daily';
            _f.windowMode = _f.frequency == 'daily' ? defaultWindowMode('daily', _f.reportKeys) : 'calendar';
          }),
        ),
        if (_f.frequency == 'weekly') ...[
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<int>(
            initialValue: _f.weekday.clamp(0, 6),
            isExpanded: true,
            dropdownColor: AppColors.cardRaised,
            borderRadius: AppRadius.controlAll,
            decoration: const InputDecoration(labelText: 'Day of the week', isDense: true),
            items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i, child: Text(weekdays[i]))],
            onChanged: (v) => setState(() => _f.weekday = v ?? 1),
          ),
        ],
        if (_f.frequency == 'monthly') ...[
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<int>(
            initialValue: _f.dayOfMonth.clamp(1, 28),
            isExpanded: true,
            dropdownColor: AppColors.cardRaised,
            borderRadius: AppRadius.controlAll,
            decoration: const InputDecoration(labelText: 'Day of the month (1–28)', isDense: true),
            items: [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i'))],
            onChanged: (v) => setState(() => _f.dayOfMonth = v ?? 1),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        _ClockPicker(
          hour: _f.hour,
          minute: _f.minute,
          label: 'Send at',
          onChanged: (h, m) => setState(() {
            _f.hour = h;
            _f.minute = m;
          }),
        ),
        if (_f.frequency == 'daily') ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Each email covers', style: text.titleSmall),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in const ['trading_day', 'calendar'])
              ChoiceChip(
                key: ValueKey('schedule-window-$m'),
                label: Text(kWindowModeLabels[m]!),
                selected: _f.windowMode == m,
                onSelected: (_) => setState(() => _f.windowMode = m),
                visualDensity: VisualDensity.compact,
              ),
          ]),
        ],
        const SizedBox(height: AppSpacing.xs),
        Text('${coverageCaption(_f.frequency, mode, _f.time)} Restaurant time (${RestaurantTime.zone}).',
            key: const ValueKey('schedule-coverage'), style: text.bodySmall),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          children: [
            Text('Reports · ${reportListPhrase(orderedReportKeys(_f.reportKeys))}', style: text.titleSmall),
            ForkButton.subtle(
              label: allMis ? 'Clear the MIS reports' : kAllMisReports,
              onPressed: () => setState(() => _f.reportKeys = allMis
                  ? [for (final k in _f.reportKeys) if (!kMisEmailKeys.contains(k)) k]
                  : orderedReportKeys([..._f.reportKeys, ...kMisEmailKeys])),
            ),
          ],
        ),
        _ReportPicker(
          catalogue: widget.config?.reports ?? kEmailableReports,
          selected: _f.reportKeys,
          mode: mode,
          onToggle: (k) => setState(() => _f.reportKeys = _f.reportKeys.contains(k)
              ? [for (final x in _f.reportKeys) if (x != k) x]
              : orderedReportKeys([..._f.reportKeys, k])),
        ),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String>(
          key: const ValueKey('schedule-channel'),
          // What the FORM holds, always — the web's select does the same. A
          // stored email schedule on a server without mail shows "Email (not
          // set up on this server)": showing "In-app inbox" while the form
          // kept 'email' saved an email schedule the owner never saw.
          initialValue: _f.channel == 'email' ? 'email' : 'inbox',
          isExpanded: true,
          dropdownColor: AppColors.cardRaised,
          borderRadius: AppRadius.controlAll,
          decoration: const InputDecoration(labelText: 'Deliver to', isDense: true),
          items: [
            DropdownMenuItem(
              value: 'email',
              enabled: emailOk,
              child: Text(emailOk ? 'Email' : 'Email (not set up on this server)'),
            ),
            const DropdownMenuItem(value: 'inbox', child: Text('In-app inbox (notification bell)')),
          ],
          onChanged: (v) => setState(() => _f.channel = v ?? 'inbox'),
        ),
        if (widget.config?.canUseAllOutlets == true) ...[
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<bool>(
            key: const ValueKey('schedule-scope'),
            initialValue: _f.allOutlets,
            isExpanded: true,
            dropdownColor: AppColors.cardRaised,
            borderRadius: AppRadius.controlAll,
            decoration: const InputDecoration(labelText: 'Outlets', isDense: true),
            items: const [
              DropdownMenuItem(value: false, child: Text('This outlet')),
              DropdownMenuItem(value: true, child: Text('All outlets (combined)')),
            ],
            onChanged: (v) => setState(() => _f.allOutlets = v ?? false),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Text('Attach as', style: text.titleSmall),
        _FormatPicker(
          formats: const ['xlsx', 'csv'],
          selected: _f.formats,
          onToggle: (fmt) => setState(() => _f.formats = _f.formats.contains(fmt)
              ? [for (final x in _f.formats) if (x != fmt) x]
              : orderedFormats([..._f.formats, fmt])),
        ),
        if (_f.channel == 'email') ...[
          const SizedBox(height: AppSpacing.md),
          Text('Send to (up to $max, from the address book)', style: text.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          if (widget.book.isEmpty)
            Text(kAddressBookEmpty, style: text.bodySmall)
          else
            _RecipientPicker(
              book: widget.book,
              selected: _f.recipientIds,
              max: max,
              onToggle: (id) => setState(() {
                _recipientsTouched = true;
                _f.recipientIds = _f.recipientIds.contains(id)
                    ? [for (final x in _f.recipientIds) if (x != id) x]
                    : [..._f.recipientIds, id];
              }),
            ),
          if (widget.missing.isNotEmpty && !_recipientsTouched)
            Text(
              'Also stored: ${widget.missing.join(', ')} — not in the address book, so skipped at send time. '
              'Change the selection to drop ${widget.missing.length == 1 ? 'it' : 'them'}.',
              style: text.bodySmall!.copyWith(color: AppColors.warning),
            ),
        ],
        const SizedBox(height: AppSpacing.sm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _f.enabled,
          onChanged: (v) => setState(() => _f.enabled = v),
          title: Text(_f.enabled ? 'On' : 'Paused'),
        ),
        if (_error != null)
          Text(_error!, key: const ValueKey('schedule-error'), style: text.bodySmall!.copyWith(color: AppColors.danger)),
        const SizedBox(height: AppSpacing.md),
        Wrap(alignment: WrapAlignment.end, spacing: AppSpacing.sm, children: [
          ForkButton.ghost(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ForkButton(
            key: const ValueKey('schedule-save'),
            label: widget.isNew ? 'Create' : 'Save',
            icon: Icons.check,
            onPressed: _save,
          ),
        ]),
      ]),
    );
  }
}

// --------------------------------------------------- the Accounting pointer ----

/// Where Accounting's scheduled reports went (client item 9 asked for them
/// "in the reports section"). Kept on Accounting so an owner who set one up
/// there finds it, rather than concluding it was deleted.
const String kSchedulesMovedSentence =
    'Scheduled reports — emailed, or to the in-app inbox — are set up in Insights → Reports → Email reports, '
    'with the address book and the delivery history.';

class _ScheduledReportsMovedCard extends StatelessWidget {
  const _ScheduledReportsMovedCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final nav = ModuleNavigator.of(context);
    final canOpen = nav?.canOpen('Reports') ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader(title: 'Scheduled reports', padding: EdgeInsets.only(bottom: 6)),
      Text(kSchedulesMovedSentence, style: text.bodySmall),
      if (canOpen) ...[
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: ForkButton.ghost(
            key: const ValueKey('accounting-open-email-reports'),
            label: 'Open $kEmailAreaTitle',
            icon: Icons.forward_to_inbox,
            dense: true,
            onPressed: () => nav!.openModule('Reports', target: const {'view': 'email'}),
          ),
        ),
      ],
    ]);
  }
}
