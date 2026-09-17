// REPORTS — the MIS / control pack, under Insights.
//
// Fifteen fraud-control documents an owner or an auditor reads: Item Wise,
// Discount, Void KOT, Bill Edit, Sales Summary, Order Summary, Executive
// Summary, Cover Size Summary, Settlement Summary — and the six that migrations
// 034-039 finally gave data to: NC Summary, Service Charge Deny, Group Summary,
// Variation Summary, Tip Summary and Counter Summary. Backed by /reports/mis/*,
// all GETs, all read-only — the reports themselves write nothing, so nothing
// they do can reach the offline outbox. Two exceptions, both online-only by
// construction because neither is on the outbox allowlist:
//   * the "Manage sessions" sheet, which replaces the restaurant's saved time
//     slots (PUT /reports/mis/time-slots), offered only to a caller the server
//     marks `can_edit`;
//   * EMAIL (client item 9): the Email button beside Export (Send now, for the
//     report and days on screen) and the "Email reports" view — the address
//     book, the schedules and the delivery history. See report_email.dart.
//
// WHY THIS IS A `part` OF modules.dart AND NOT ITS OWN LIBRARY. The drill-down
// from a Discount or an Order Summary row has to open THE SAME BILL BODY the
// History screen and the settled-bill browser already render (`_closedBillBody`),
// and it has to render money, timestamps and empty values through the same
// helpers every other module uses (`_money`, `_fmtTime`, `_s`, `_int`). Those
// are library-private. Copying them here would mean a Reports drill-down could
// drift into showing a different bill from the rest of the product, which is
// precisely the failure this pack exists to catch. A `part` shares the private
// scope without adding 1,400 lines to a 30,000-line file.
//
// THE SHARED SHELL, once, for all fifteen: date range, outlet scope, search,
// configurable columns, the time-wise toggle, a TOTALS row, CSV/Excel/PDF
// export and row drill-down. Every report gets it by construction because the
// shell is the screen and the reports are its tabs.
part of 'modules.dart';

// The app-wide phone/narrow edge. 760 = kNarrowWidth in home_shell.dart, which
// is not importable here without an import cycle; every module in this library
// spells it inline for the same reason.
const double _misNarrow = 760;

// --------------------------------------------------------- the fifteen ------

/// One report in the pack.
///
/// Mirrored from the server's own catalogue (`GET /reports/mis`), which stays
/// the authority on what exists: `path`, `rowsKey` and `paged` here are the
/// same three facts that endpoint publishes. It is mirrored rather than fetched
/// because the tab strip must be able to paint before any network call, and
/// because each report also carries client-side furniture (its icon, its
/// summary tiles) that no catalogue can supply.
///
/// The list is exactly fifteen — the industry-standard set, complete. The last
/// six were dark until migrations 034-039 started recording what they describe;
/// they are here because the capture screens in this app now write that data,
/// not because the endpoints exist.
class _MisReport {
  const _MisReport(
    this.key,
    this.title,
    this.path,
    this.rowsKey,
    this.icon, {
    this.paged = false,
    this.searchable = false,
    required this.basis,
  });
  final String key;
  final String title;
  final String path;

  /// Which array of the payload is the TABLE. Not always `rows`: the Sales
  /// Summary's table is its time-wise `series`, the Executive Summary's is its
  /// `by_outlet` breakdown.
  final String rowsKey;
  final IconData icon;

  /// True for the row-level reports the server pages. The summaries are whole
  /// answers and have no `page` block at all.
  final bool paged;

  /// True where the SERVER actually applies `?search=`. Seven of the fifteen
  /// answer a whole window rather than a row set and ignore it entirely, so on
  /// those the field is not offered — a search box that refetches the same
  /// answer is the same dead control as a bucket switch that changes nothing.
  final bool searchable;

  /// WHICH CLOCK the report buckets on, in the reader's words. Mirrored from
  /// the catalogue's `shell.basis` map, which exists precisely so a client can
  /// label the toolbar honestly instead of implying that every tab answers the
  /// same question about the same days.
  final String basis;
}

const String _misBasisSettled = 'settlement';
const String _misBasisOrdered = 'order placement';

const List<_MisReport> _misReports = [
  _MisReport('item_wise', 'Item Wise', '/reports/mis/item-wise', 'rows', Icons.restaurant_menu,
      paged: true, searchable: true, basis: _misBasisOrdered),
  _MisReport('discount', 'Discount', '/reports/mis/discount', 'rows', Icons.percent,
      paged: true, searchable: true, basis: _misBasisSettled),
  _MisReport('void_kot', 'Void KOT', '/reports/mis/void-kot', 'rows', Icons.cancel_outlined,
      paged: true, searchable: true, basis: _misBasisOrdered),
  _MisReport('bill_edit', 'Bill Edit', '/reports/mis/bill-edit', 'rows', Icons.edit_note,
      paged: true, searchable: true, basis: 'the edit'),
  _MisReport('sales_summary', 'Sales Summary', '/reports/mis/sales-summary', 'series', Icons.stacked_line_chart,
      basis: _misBasisSettled),
  _MisReport('order_summary', 'Order Summary', '/reports/mis/order-summary', 'rows', Icons.receipt_long,
      paged: true, searchable: true, basis: _misBasisSettled),
  _MisReport('executive_summary', 'Executive Summary', '/reports/mis/executive-summary', 'by_outlet', Icons.workspace_premium,
      basis: _misBasisSettled),
  _MisReport('cover_size_summary', 'Cover Size Summary', '/reports/mis/cover-size-summary', 'rows', Icons.groups_2,
      basis: _misBasisSettled),
  _MisReport('settlement_summary', 'Settlement Summary', '/reports/mis/settlement-summary', 'rows', Icons.account_balance_wallet,
      basis: _misBasisSettled),
  // The six that read migrations 034-039.
  _MisReport('nc_summary', 'NC Summary', '/reports/mis/nc-summary', 'rows', Icons.card_giftcard,
      paged: true, searchable: true, basis: 'the comp'),
  _MisReport('service_charge_deny', 'Service Charge Deny', '/reports/mis/service-charge-deny', 'rows', Icons.money_off_csred_outlined,
      paged: true, searchable: true, basis: 'the waiver'),
  _MisReport('group_summary', 'Group Summary', '/reports/mis/group-summary', 'rows', Icons.category_outlined,
      basis: _misBasisOrdered),
  _MisReport('variation_summary', 'Variation Summary', '/reports/mis/variation-summary', 'rows', Icons.straighten,
      basis: _misBasisOrdered),
  _MisReport('tip_summary', 'Tip Summary', '/reports/mis/tip-summary', 'rows', Icons.volunteer_activism_outlined,
      paged: true, searchable: true, basis: 'the tender'),
  _MisReport('counter_summary', 'Counter Summary', '/reports/mis/counter-summary', 'rows', Icons.point_of_sale,
      basis: _misBasisSettled),
];

// --------------------------------------------------------- session memory ----

/// Which report was open, for the life of the app session.
///
/// Session memory rather than a persisted preference, exactly like
/// [DateRangeMemory]: switching outlet remounts every module (the shell bumps
/// its refresh tick), and an owner who was reading the Settlement Summary for
/// branch A must land on the Settlement Summary for branch B — not back on tab
/// one with no idea why.
int _misOpenTab = 0;

/// Columns the reader has switched OFF, per report. Also session-scoped: a
/// column picker that resets on every visit is a control nobody uses twice.
final Map<String, Set<String>> _misHiddenColumns = <String, Set<String>>{};

/// The time-wise toggle. Only the Sales Summary answers it (the server says so
/// in its own shell descriptor: `time_wise.applies_to: ["sales_summary"]`), so
/// it is only OFFERED there — a bucket switch that silently does nothing on
/// fourteen of fifteen tabs is a dead control.
String _misBucket = 'day';

/// Which view was open — the reports, or Email reports — for the session, like
/// the tab: switching outlet remounts the module and must not throw the owner
/// out of the address book they were editing.
String _misView = 'report';

/// Test seam: a suite must not inherit the previous test's tab or columns.
void misResetReportMemory() {
  _misOpenTab = 0;
  _misView = 'report';
  _misHiddenColumns.clear();
  _misBucket = 'day';
  TimeSlotMemory.reset();
}

// ------------------------------------------------------------- the module ----

Widget reportsModule(RestClient rest, Profile p) => _ReportsView(rest: rest, profile: p);

class _ReportsView extends StatefulWidget {
  const _ReportsView({required this.rest, required this.profile});
  final RestClient rest;
  final Profile profile;
  @override
  State<_ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends State<_ReportsView> {
  DateRange _range = DateRangeMemory.of('reports');
  late int _tab = _misOpenTab.clamp(0, _misReports.length - 1);

  // WHICH PART OF THE DAY. Remembered like the range. It is only SENT once the
  // presets route has answered (or answered earlier this session): a remembered
  // "Lunch" against a server that cannot slice would be a filter the chip claims
  // and the numbers ignore, so until then there is no chip and the day is whole.
  TimeSlotSelection _slot = TimeSlotMemory.of('reports');
  late TimeSlotCatalogue? _slots = TimeSlotMemory.catalogueFor(widget.rest.outboxRes ?? '');

  TimeSlotSelection get _effectiveSlot => _slots == null ? TimeSlotSelection.allDay : _slot;

  /// The bucket actually sent: the two newer segments exist only where the
  /// presets route does, and one the server cannot answer goes as day-wise.
  String get _effectiveBucket =>
      timeWiseOptions(_slots != null).any((b) => b.$1 == _misBucket) ? _misBucket : 'day';

  @override
  void initState() {
    super.initState();
    // Off the read cache after the first visit, like every other GET here.
    widget.rest.getMap('/reports/mis/time-slots').then((m) {
      final cat = TimeSlotCatalogue.fromJson(m);
      if (!mounted || cat == null) return;
      TimeSlotMemory.rememberCatalogue(widget.rest.outboxRes ?? '', cat);
      setState(() {
        _slots = cat;
        _setSlotInState(_slot.reconcile(cat.slots));
      });
    }).catchError((_) {});
  }

  void _setSlotInState(TimeSlotSelection next) {
    _slot = next;
    TimeSlotMemory.remember('reports', next);
  }

  void _setSlot(TimeSlotSelection next) => setState(() => _setSlotInState(next));

  /// A tapped hour-of-day or session row: that slot, read day by day — the
  /// question an owner asks the instant 1pm or Dinner looks wrong. It REPLACES
  /// the slot, which is only the same as narrowing because the pane offers the
  /// tap solely where the two agree ([slotRowOpensExactly]).
  void _narrowToSlot(TimeSlotSelection next) => setState(() {
        _setSlotInState(next);
        _misBucket = 'day';
      });

  Future<TimeSlotSaveOutcome> _saveSlots(List<TimeSlotDraft> drafts) async {
    try {
      final res = await widget.rest.put('/reports/mis/time-slots', slotDraftsBody(drafts));
      final cat = TimeSlotCatalogue.fromJson(res);
      if (cat == null) {
        return (saved: null, error: 'The server saved the sessions but sent back a list this screen cannot read — reload to see them.');
      }
      if (!mounted) return (saved: cat, error: null);
      TimeSlotMemory.rememberCatalogue(widget.rest.outboxRes ?? '', cat);
      setState(() {
        _slots = cat;
        _setSlotInState(_slot.reconcile(cat.slots));
      });
      return (saved: cat, error: null);
    } on ApiException catch (e) {
      // The server's own sentence ("Lunch and Brunch overlap…") is the point.
      return (saved: null, error: e.message);
    } catch (e) {
      return (
        saved: null,
        error: isUnreachableError(e)
            ? "Couldn't save — this device can't reach the restaurant server. Reconnect and try again."
            : 'Could not save the sessions: $e',
      );
    }
  }

  final TextEditingController _searchCtl = TextEditingController(text: '');
  Timer? _searchDebounce;
  String _search = '';

  // The outlet list behind the scope selector. Loaded lazily and best-effort:
  // a user who cannot switch outlets simply sees the scope the server reports.
  List<Map<String, dynamic>> _outlets = const [];

  bool _askedOutlets = false;

  // The outlet list is fetched HERE and not in initState: reading an inherited
  // widget (ModuleNavigator) is only legal once dependencies are resolved, and
  // whether this user can switch outlets at all is what decides if the call is
  // worth making. Guarded so a rebuild does not refetch.
  /// The view on screen: 'report' or 'email'.
  String _view = _misView;
  int _focusSerial = -1;

  void _setView(String next) => setState(() {
        _view = next;
        _misView = next;
      });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A bell about an emailed report (its meta says module 'Reports'), or the
    // Accounting card's "Open Email reports", lands on the Email reports view.
    // "Scheduled email reports are waiting" names no delivery and no schedule:
    // it carries view 'email' (and its kind), or it landed on the report grid.
    final focus = ModuleNavigator.of(context)?.focusFor('Reports');
    if (focus != null && focus.serial != _focusSerial) {
      _focusSerial = focus.serial;
      final t = focus.target;
      if (t['view'] == 'email' || t['delivery_id'] != null || t['schedule_id'] != null || t['kind'] != null) {
        _view = 'email';
        _misView = 'email';
      }
    }
    if (_askedOutlets) return;
    _askedOutlets = true;
    if (ModuleNavigator.of(context)?.switchOutlet == null) return;
    // Same endpoint the shell's own switcher uses, so both offer the same
    // branches — and it comes off the read cache after the first visit.
    widget.rest.getMap('/outlets').then((m) {
      if (!mounted) return;
      final list = (m['outlets'] as List?) ?? const [];
      setState(() => _outlets = list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  void _setRange(DateRange next) {
    setState(() => _range = next);
    DateRangeMemory.remember('reports', next);
  }

  void _setTab(int i) {
    setState(() {
      _tab = i;
      _misOpenTab = i;
      // A term the new report's endpoint does not read would sit in a visible
      // box filtering nothing, and the empty state would go on to say "no rows
      // match" about a search that was never applied. Dropped, loudly, by the
      // field disappearing with it.
      if (!_misReports[i].searchable && _search.isNotEmpty) {
        _search = '';
        _searchCtl.clear();
        _searchDebounce?.cancel();
      }
    });
  }

  void _onSearch(String v) {
    _searchDebounce?.cancel();
    // A keystroke must not be a request: these queries scan a whole window.
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final t = v.trim();
      if (t != _search) setState(() => _search = t);
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _misReports[_tab];
    final narrow = MediaQuery.sizeOf(context).width < _misNarrow;
    final nav = ModuleNavigator.of(context);
    final outletId = widget.rest.auth.selectedOutletId ?? '';

    // The slot as a QUESTION, not as a URL: `slot=lunch` is the same request
    // before and after Manage sessions moves Lunch's hours, and "By session" is
    // built from every preset even with All day picked. Keyed on the bare
    // selection, a save left the pane mounted on the old answer — see
    // [slotDefinitionKey]. The bucket is the one sent, and only one report takes it.
    final slotQuestion = slotDefinitionKey(
      _effectiveSlot,
      _slots?.slots ?? const [],
      bucket: report.key == 'sales_summary' ? _effectiveBucket : null,
    );
    final pane = _MisReportPane(
      // Remount on every dimension of the question: a pane holding rows for one
      // window must never be reused under the label of another.
      key: ValueKey('mis-${report.key}-${_range.from}-${_range.to}-$_search-$_effectiveBucket-$slotQuestion-$outletId'),
      rest: widget.rest,
      profile: widget.profile,
      report: report,
      range: _range,
      search: _search,
      bucket: _effectiveBucket,
      slot: _effectiveSlot,
      presets: _slots?.slots ?? const [],
      onRange: _setRange,
      onSlot: _narrowToSlot,
    );

    return Padding(
      padding: narrow ? AppSpacing.pageNarrow : AppSpacing.page,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(
          title: 'Reports',
          trailing: narrow || _view == 'email' ? null : InfoChip(icon: Icons.calendar_today_outlined, label: _range.label()),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _MisSegment(
            key: const ValueKey('reports-view'),
            options: const ['report', 'email'],
            labels: const ['Reports', kEmailAreaTitle],
            selected: _view,
            onSelected: _setView,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_view == 'email')
          Expanded(child: _EmailReportsPanel(rest: widget.rest))
        else ...[
        // Every figure below is cut on this window and this outlet, so the
        // controls that set them sit above the figures, never beside them.
        _toolbar(context, report, narrow, nav),
        const SizedBox(height: AppSpacing.md),
        ForkTabs(
          tabs: [for (final r in _misReports) r.title],
          selected: _tab,
          onSelected: _setTab,
        ),
        const SizedBox(height: AppSpacing.md),
        Container(height: 1, color: AppColors.divider),
        const SizedBox(height: AppSpacing.md),
        Expanded(child: pane),
        ],
      ]),
    );
  }

  Widget _toolbar(BuildContext context, _MisReport report, bool narrow, ModuleNavigator? nav) {
    final slotPhrase = _effectiveSlot.phrase(_slots?.slots ?? const []);
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DateRangeChip(value: _range, onChanged: _setRange, dense: true),
        if (_slots != null)
          TimeSlotChip(
            key: const ValueKey('reports-slot'),
            value: _slot,
            presets: _slots!.slots,
            canEdit: _slots!.canEdit,
            onChanged: _setSlot,
            onSave: _saveSlots,
          ),
        _outletControl(context, nav),
        // WHICH CLOCK this tab is cut on. Fifteen reports over one date range do
        // NOT all answer the same question about the same days: a comp is dated
        // when it was given away, a bill when it settled, a dish when it was
        // ordered. Naming it beside the window is what stops two tabs that
        // legitimately disagree from looking like a bug.
        InfoChip(
          key: const ValueKey('reports-basis'),
          icon: Icons.schedule,
          label: (report.basis == _misBasisSettled
                  ? 'Dated on settlement'
                  : report.basis == _misBasisOrdered
                      ? 'Dated on order placement'
                      : 'Dated on ${report.basis}') +
              // …and within which hours of each day, when a slot is on.
              (slotPhrase == null ? '' : ' · $slotPhrase'),
        ),
        if (report.searchable)
        SizedBox(
          width: narrow ? double.infinity : 260,
          // Listens to the controller, not to _search: the clear affordance has
          // to appear on the first keystroke, while the QUERY deliberately waits
          // out the debounce. Scoped here so a keystroke rebuilds one field and
          // not the grid under it.
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchCtl,
            builder: (context, value, _) => TextField(
            key: const ValueKey('reports-search'),
            controller: _searchCtl,
            onChanged: _onSearch,
            onSubmitted: (v) {
              _searchDebounce?.cancel();
              final t = v.trim();
              if (t != _search) setState(() => _search = t);
            },
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: _misSearchHint(report),
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 30),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchCtl.clear();
                        _searchDebounce?.cancel();
                        if (_search.isNotEmpty) setState(() => _search = '');
                      },
                    ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(borderRadius: AppRadius.inputAll),
            ),
            ),
          ),
        ),
        // Time-wise: Sales Summary only — see [_misBucket].
        if (report.key == 'sales_summary')
          _MisSegment(
            key: const ValueKey('reports-bucket'),
            options: [for (final b in timeWiseOptions(_slots != null)) b.$1],
            labels: [for (final b in timeWiseOptions(_slots != null)) b.$2],
            selected: _effectiveBucket,
            onSelected: (v) => setState(() => _misBucket = v),
          ),
      ],
    );
  }

  /// The outlet scope selector.
  ///
  /// It drives the SHELL's outlet switch rather than a private query parameter,
  /// and that is not laziness: the backend reads X-Outlet-Id BEFORE `?outletId`
  /// (rawRequestedOutletId), and this app sends that header on every request
  /// from `auth.selectedOutletId`. A second, screen-local outlet picker would be
  /// silently overruled by the header — the reader would pick "Kalyani Nagar"
  /// and get whichever branch the app bar had selected, with the report title
  /// happily naming the one they asked for. So this is the same control the
  /// app bar offers, surfaced where the reports are read.
  Widget _outletControl(BuildContext context, ModuleNavigator? nav) {
    final switcher = nav?.switchOutlet;
    final active = widget.rest.auth.selectedOutletId ?? '';
    final isAll = active == 'all';
    if (switcher == null || _outlets.length < 2) {
      // Nothing to choose between: state the scope, offer no control.
      return InfoChip(
        icon: isAll ? Icons.layers : Icons.store_mall_directory_outlined,
        label: isAll ? 'All outlets' : 'This outlet',
      );
    }
    String nameOf(String id) {
      for (final o in _outlets) {
        if ('${o['id']}' == id) return '${o['outlet_name'] ?? 'Outlet'}';
      }
      return 'This outlet';
    }

    final label = isAll
        ? 'All outlets (combined)'
        : nameOf(active.isEmpty && _outlets.isNotEmpty ? '${_outlets.first['id']}' : active);
    return PopupMenuButton<String>(
      key: const ValueKey('reports-outlet'),
      tooltip: 'Outlet the report is cut for',
      color: AppColors.cardRaised,
      onSelected: switcher,
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String>(
          value: 'all',
          checked: isAll,
          child: const Text('All outlets (combined)'),
        ),
        for (final o in _outlets)
          CheckedPopupMenuItem<String>(
            value: '${o['id']}',
            checked: '${o['id']}' == active,
            child: Text('${o['outlet_name'] ?? 'Outlet'}'),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.inset,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(isAll ? Icons.layers : Icons.store_mall_directory_outlined,
              size: 14, color: AppColors.copper),
          const SizedBox(width: AppSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 15, color: AppColors.textTertiary),
        ]),
      ),
    );
  }
}

/// What the SERVER's `search` predicate actually matches on this report, so the
/// hint never invites a query the endpoint cannot answer. Each line is read off
/// that report's own `ilike` clause, not guessed.
String _misSearchHint(_MisReport report) => switch (report.key) {
      'item_wise' => 'Dish name',
      'nc_summary' => 'Dish / reason / table / who',
      'service_charge_deny' => 'Bill / table / reason / who',
      'tip_summary' => 'Bill / table / tender / credited to',
      _ => 'Bill No. / KOT / table',
    };

// --------------------------------------------------------- segmented pill ----

/// Two-or-three-way pill switch in the template's voice. Used for the time-wise
/// toggle; kept tiny and local because the design system's [ForkTabs] is a page
/// tab strip, not an inline control.
class _MisSegment extends StatelessWidget {
  const _MisSegment({
    super.key,
    required this.options,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> options;
  final List<String> labels;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.inset,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.border),
      ),
      // A Wrap, not a Row: four options are wider than a 360dp phone.
      child: Wrap(children: [
        for (var i = 0; i < options.length; i++)
          GestureDetector(
            onTap: () => onSelected(options[i]),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: options[i] == selected ? AppColors.copper.withValues(alpha: 0.18) : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: options[i] == selected ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------- the report ----

/// What one row of a report can be opened INTO, or [none] when the row is a
/// total and there is nothing single behind it.
///
/// It is deliberately a property of the ROW, not of the report: Bill Edit and
/// NC Summary carry whichever identifier the audit writer happened to record,
/// so two rows of one report legitimately differ. Anything that describes
/// drill-down to the reader is computed from this, so the description and the
/// behaviour cannot disagree.
enum _MisRowOpen { none, bill, kot, day, hour, session, outlet }

class _MisReportPane extends StatefulWidget {
  const _MisReportPane({
    super.key,
    required this.rest,
    required this.profile,
    required this.report,
    required this.range,
    required this.search,
    required this.bucket,
    required this.slot,
    required this.presets,
    required this.onRange,
    required this.onSlot,
  });

  final RestClient rest;
  final Profile profile;
  final _MisReport report;
  final DateRange range;
  final String search;
  final String bucket;

  /// The slot SENT (all day until the presets route has answered).
  final TimeSlotSelection slot;
  final List<TimeSlotPreset> presets;
  final ValueChanged<DateRange> onRange;
  final ValueChanged<TimeSlotSelection> onSlot;

  @override
  State<_MisReportPane> createState() => _MisReportPaneState();
}

class _MisReportPaneState extends State<_MisReportPane> with CachePrimedScreen {
  /// The server's own default page. Deliberately not larger: the TOTALS row is
  /// the window's, not the page's, so a bigger page buys nothing but latency.
  static const int _pageSize = 100;

  /// The server's MIS_MAX_PAGE. Used only when sweeping the window for an
  /// export.
  static const int _exportPage = 500;

  /// Hard ceiling on an export sweep. A window is already bounded by the
  /// server's MAX_REPORT_DAYS; this bounds the pathological tenant on top of it,
  /// and when it bites the file SAYS it was truncated instead of being quietly
  /// short.
  static const int _exportRowCap = 10000;

  Map<String, dynamic> _payload = const {};
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  List<MisColumn> _columns = const [];
  bool _loading = true;
  bool _hasData = false;
  bool _appending = false;
  bool _exporting = false;
  String? _error;
  int _total = 0;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    unawaited(primeFromCache(
      fetch: _fetch,
      apply: (d) {
        _apply(d);
        _loading = false;
        _error = null;
      },
      refresh: () => _load(silent: true),
      fallback: _load,
    ));
  }

  /// The slot this pane asked for, in words (null for all day).
  String? get _slotPhrase => widget.slot.phrase(widget.presets);

  /// The slot the server actually cut these rows under (null = all day).
  AppliedTimeSlot? get _appliedSlot => AppliedTimeSlot.fromMeta(_meta);

  // ---- wire ----------------------------------------------------------------

  String _url({required int limit, required int offset}) {
    final parts = <String>[widget.range.reportQuery];
    // Only where the endpoint reads it. Sending it elsewhere would put a term in
    // the URL that changes nothing, which is how an export comes out labelled
    // with a filter that was never applied.
    if (widget.report.searchable && widget.search.isNotEmpty) {
      parts.add('search=${Uri.encodeQueryComponent(widget.search)}');
    }
    if (widget.report.key == 'sales_summary') parts.add('bucket=${widget.bucket}');
    // Every report takes the slot; all day adds nothing, so the URL (and its
    // read-cache entry) is exactly what it was before slots existed.
    parts.addAll(widget.slot.queryParts);
    if (widget.report.paged) {
      parts..add('limit=$limit')..add('offset=$offset');
    }
    return '${widget.report.path}?${parts.join('&')}';
  }

  /// Side-effect-free, replayable against the persisted GET cache — the
  /// contract [CachePrimedScreen] needs so a report paints its saved copy and
  /// then refreshes, exactly like every other module.
  Future<Map<String, dynamic>> _fetch() => widget.rest.getMap(_url(limit: _pageSize, offset: 0));

  List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> d) => [
        for (final r in (d[widget.report.rowsKey] as List?) ?? const [])
          if (r is Map) Map<String, dynamic>.from(r),
      ];

  void _apply(Map<String, dynamic> d) {
    _payload = d;
    _columns = MisColumn.listOf(d['columns']);
    _rows = _rowsOf(d);
    final page = (d['page'] as Map?) ?? const {};
    _total = _int(page['total']) ?? _rows.length;
    _hasMore = page['has_more'] == true;
    _hasData = true;
    // First visit to this report in the session adopts the server's own
    // default-off columns. Later visits keep whatever the reader chose.
    _misHiddenColumns.putIfAbsent(
      widget.report.key,
      () => {for (final c in _columns) if (!c.defaultOn) c.key},
    );
  }

  Future<void> _load({bool silent = false}) async {
    final gen = bumpCacheGen();
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final d = await _fetch();
      if (!mounted || !cacheGenIs(gen)) return;
      setState(() {
        _apply(d);
        _loading = false;
        _error = null;
        markCacheLive();
      });
    } catch (e) {
      if (!mounted || !cacheGenIs(gen)) return;
      // A SILENT refresh keeps the figures up behind the offline pill. A LOUD
      // one means the reader just changed the question, and old figures under a
      // new window label are exactly the silent mismatch this pack exists to
      // prevent — the error screen is the honest outcome.
      if (silent && _hasData) {
        setState(() { _loading = false; markCacheOffline(); });
        return;
      }
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _loadMore() async {
    if (_appending || !_hasMore) return;
    setState(() => _appending = true);
    final gen = bumpCacheGen();
    try {
      final d = await widget.rest.getMap(_url(limit: _pageSize, offset: _rows.length));
      if (!mounted || !cacheGenIs(gen)) return;
      final page = (d['page'] as Map?) ?? const {};
      setState(() {
        _rows = [..._rows, ..._rowsOf(d)];
        _total = _int(page['total']) ?? _total;
        _hasMore = page['has_more'] == true;
        _appending = false;
        markCacheLive();
      });
    } catch (e) {
      if (!mounted || !cacheGenIs(gen)) return;
      setState(() => _appending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_misWhyFailed('load more rows', e))));
    }
  }

  /// A failure in the reader's words, not the transport's.
  ///
  /// The page on screen stays up when Load more or an export fails, so this is
  /// a snackbar rather than an error pane — but the same rule holds as on the
  /// pane: an unreachable server is the reader's Wi-Fi to act on, while a
  /// server that answered gets its own words repeated. Dumping
  /// "ClientException: Connection closed before full header was received" on a
  /// cashier names neither.
  String _misWhyFailed(String what, Object e) => isUnreachableError(e)
      ? "Couldn't $what — this device can't reach the restaurant server. "
          'Reconnect to the Wi-Fi and try again.'
      : 'Could not $what: $e';

  // ---- columns -------------------------------------------------------------

  Set<String> get _hidden => _misHiddenColumns[widget.report.key] ?? const {};

  /// The columns actually on screen — and therefore the columns in the export.
  ///
  /// Never empty: hiding every column would leave a table with no way back, so
  /// the first one always survives.
  List<MisColumn> get _visibleColumns {
    final on = [for (final c in _columns) if (!_hidden.contains(c.key)) c];
    if (on.isEmpty && _columns.isNotEmpty) return [_columns.first];
    return on;
  }

  Future<void> _pickColumns() async {
    final hidden = {..._hidden};
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Columns'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final c in _columns)
                  CheckboxListTile(
                    key: ValueKey('reports-col-${c.key}'),
                    dense: true,
                    value: !hidden.contains(c.key),
                    title: Text(c.label, style: const TextStyle(fontSize: 13)),
                    subtitle: c.total
                        ? Text('Summed in the totals row', style: Theme.of(ctx).textTheme.bodySmall)
                        : null,
                    onChanged: (v) => setDlg(() {
                      if (v == true) {
                        hidden.remove(c.key);
                      } else {
                        hidden.add(c.key);
                      }
                    }),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDlg(() => hidden.clear()),
              child: const Text('Show all'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                _misHiddenColumns[widget.report.key] = hidden;
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // ---- export --------------------------------------------------------------

  Map<String, dynamic>? get _totals {
    final t = _payload['totals'];
    return t is Map ? Map<String, dynamic>.from(t) : null;
  }

  Map<String, dynamic> get _meta {
    final m = _payload['meta'];
    return m is Map ? Map<String, dynamic>.from(m) : const {};
  }

  List<String> get _notes => [
        for (final n in (_meta['notes'] as List?) ?? const []) '$n',
      ];

  String get _outletLabel {
    if ('${_meta['outlet_scope'] ?? ''}' == 'all') return 'All outlets';
    final n = _s(_meta, 'outlet_name', '');
    return n.isEmpty || n == '—' ? 'This outlet' : n;
  }

  /// Every row in the WINDOW, not just the page on screen.
  ///
  /// An export that quietly carried only the first hundred rows is the kind of
  /// thing that is discovered at an audit, so a paged report is swept from
  /// offset 0 in the server's own maximum page size. `_exportRowCap` bounds it,
  /// and a sweep that hits the cap reports the truncation into the file itself.
  Future<({List<Map<String, dynamic>> rows, int? truncated})> _sweepRows() async {
    if (!widget.report.paged) return (rows: _rows, truncated: null);
    final out = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final d = await widget.rest.getMap(_url(limit: _exportPage, offset: offset));
      out.addAll(_rowsOf(d));
      final page = (d['page'] as Map?) ?? const {};
      if (page['has_more'] != true) return (rows: out, truncated: null);
      offset += _exportPage;
      if (out.length >= _exportRowCap) return (rows: out, truncated: out.length);
    }
  }

  Future<void> _export(ReportFormat format) async {
    if (_exporting) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    messenger.showSnackBar(SnackBar(content: Text('Preparing the ${format.label}…')));
    try {
      final swept = await _sweepRows();
      final window = (_meta['window'] as Map?) ?? const {};
      final doc = MisReportDoc(
        title: _s(_meta, 'title', widget.report.title),
        columns: _visibleColumns,
        rows: swept.rows,
        totals: _totals,
        from: _s(window, 'from', widget.range.from),
        to: _s(window, 'to', widget.range.to),
        timezone: _s(_meta, 'timezone', RestaurantTime.zone),
        outletLabel: _outletLabel,
        notes: _notes,
        truncatedAt: swept.truncated,
        timeSlot: AppliedTimeSlot.fromMeta(_meta),
      );
      final result = await ReportExporter.export(doc, format);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } catch (e) {
      if (!mounted) return;
      // A sweep for an export walks the WHOLE window, so it is the most likely
      // thing on this screen to meet a dying line — and a half-swept file must
      // never be offered as the report.
      messenger.showSnackBar(SnackBar(content: Text(_misWhyFailed('export this report', e))));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- drill-down ----------------------------------------------------------

  /// WHAT A ROW OPENS — the single classifier behind BOTH the tap and the words
  /// that describe it.
  ///
  /// Split out from [_rowAction] on purpose. The reported complaint was that
  /// reports "are not clickable", and the wiring was never broken: nine of the
  /// fifteen reports have rows that open something and six do not, because six
  /// of them are AGGREGATES. "Paneer Tikka, 47 sold" is 47 lines off some
  /// unknown number of bills; there is no single bill behind it to open, and
  /// inventing one would be worse than opening nothing. The bug was that the
  /// screen never said which kind of report the reader was looking at, so a
  /// correct dead row and a broken control looked exactly the same.
  ///
  /// Deriving the description from this classifier — rather than from a second
  /// hand-kept table of report keys — is what makes the sentence on screen
  /// unable to drift from what the tap actually does. A report that starts
  /// carrying `bill_id` tomorrow becomes clickable AND starts saying so in the
  /// same commit, with no client release listing it twice.
  _MisRowOpen _rowOpens(Map<String, dynamic> row) {
    if (_s(row, 'bill_id', '').isNotEmpty) return _MisRowOpen.bill;
    if (_s(row, 'order_id', '').isNotEmpty) return _MisRowOpen.kot;
    // The Sales Summary's day rows narrow the window to that day — the question
    // an owner asks the instant a day looks wrong — and keep the slot, because
    // "Dinner on the 14th" is still a question about Dinner. Date x hour rows
    // cannot: the window is a pair of calendar DAYS, so a dated hour has nothing
    // to narrow to.
    if (widget.report.key == 'sales_summary' &&
        widget.bucket == 'day' &&
        isDayKey(_s(row, 'bucket', ''))) {
      return _MisRowOpen.day;
    }
    // An hour-of-day row becomes that hour as a custom slot, and a session row
    // becomes that saved session — each then read day by day. Opening one
    // REPLACES the slot the rows were cut under, so it is offered only where the
    // replacement counts exactly what the row did: a Lunch row that under
    // 16:00–19:00 held only 16:00–17:00, or a 01:00 row of a night counted on
    // the evening before, would open onto a different total. Judged against the
    // slot the SERVER applied to these rows (`meta.time_slot`), not the picker.
    if (widget.report.key == 'sales_summary' && widget.bucket == 'hour_of_day') {
      final hour = hourOfDaySlot(_s(row, 'bucket', ''));
      if (hour != null && slotRowOpensExactly(hour.from, hour.to, _appliedSlot)) {
        return _MisRowOpen.hour;
      }
    }
    if (widget.report.key == 'sales_summary' && widget.bucket == 'session') {
      final preset = sessionRowPreset(_s(row, 'bucket', ''), widget.presets);
      if (preset != null && slotRowOpensExactly(preset.start, preset.end, _appliedSlot)) {
        return _MisRowOpen.session;
      }
    }
    // An Executive Summary outlet row switches the whole app to that branch,
    // which is what "why is Kalyani Nagar down" actually needs. A reader who
    // cannot switch outlets at all gets no promise of one.
    if (widget.report.key == 'executive_summary' &&
        _s(row, 'outlet_id', '').isNotEmpty &&
        ModuleNavigator.of(context)?.switchOutlet != null) {
      return _MisRowOpen.outlet;
    }
    return _MisRowOpen.none;
  }

  /// What tapping a row DOES — and null when it does nothing, so a row is only
  /// ever offered as a control when it is one.
  VoidCallback? _rowAction(Map<String, dynamic> row) {
    switch (_rowOpens(row)) {
      case _MisRowOpen.bill:
        final id = _s(row, 'bill_id', '');
        return () => _misOpenBill(context, widget.rest, id, _misRowTitle(row));
      case _MisRowOpen.kot:
        final id = _s(row, 'order_id', '');
        return () => _misOpenKot(context, widget.rest, id);
      case _MisRowOpen.day:
        final day = _s(row, 'bucket', '');
        return () => widget.onRange(DateRange.normalized(day, day));
      case _MisRowOpen.hour:
        final hour = hourOfDaySlot(_s(row, 'bucket', ''));
        return hour == null ? null : () => widget.onSlot(hour);
      case _MisRowOpen.session:
        final preset = sessionRowPreset(_s(row, 'bucket', ''), widget.presets);
        return preset == null ? null : () => widget.onSlot(TimeSlotSelection.preset(preset.id));
      case _MisRowOpen.outlet:
        final id = _s(row, 'outlet_id', '');
        // Re-read rather than trusting the classifier's: the closure outlives
        // this build, and an inherited widget can be gone by the time it runs.
        final switcher = ModuleNavigator.of(context)?.switchOutlet;
        return switcher == null ? null : () => switcher(id);
      case _MisRowOpen.none:
        return null;
    }
  }

  /// The one sentence that separates "this report is broken" from "this report
  /// is a total" — read off the rows actually on screen, never off a list of
  /// report names.
  ///
  /// Three shapes, because there are genuinely three situations:
  ///   * every row opens something -> say what it opens;
  ///   * no row opens anything -> say WHY, in the report's own terms, so a
  ///     reader stops tapping and knows nothing is missing;
  ///   * some do and some do not (Bill Edit and NC Summary carry whatever
  ///     identifier the audit writer recorded, which is not always one) -> say
  ///     both halves, with the count, rather than letting the reader discover
  ///     by trial that half the rows are dead.
  ({IconData icon, String label})? _drillNote() {
    if (_rows.isEmpty) return null;
    final kinds = <_MisRowOpen>{};
    var open = 0;
    for (final r in _rows) {
      final k = _rowOpens(r);
      if (k == _MisRowOpen.none) continue;
      open++;
      kinds.add(k);
    }
    if (open == 0) {
      // Hours and sessions that open under All day but not under this slot
      // (see [slotRowOpensExactly]): say which setting brings the taps back,
      // rather than leaving a reader who tapped them yesterday to guess.
      final applied = _appliedSlot;
      final cut = widget.bucket == 'hour_of_day'
          ? 'an hour'
          : widget.bucket == 'session'
              ? 'a session'
              : null;
      if (widget.report.key == 'sales_summary' && cut != null && applied != null) {
        return (
          icon: Icons.filter_alt_outlined,
          label: 'Rows here are cut to ${applied.phrase} — choose All day to open $cut',
        );
      }
      return (
        icon: Icons.functions,
        label: 'Each row totals many bills — no single one to open',
      );
    }
    final what = kinds.length > 1
        ? 'the bill or ticket it names'
        : switch (kinds.first) {
            _MisRowOpen.bill => 'its full bill',
            _MisRowOpen.kot => 'its kitchen ticket',
            _MisRowOpen.day => 'that day on its own',
            _MisRowOpen.hour => 'that hour, day by day',
            _MisRowOpen.session => 'that session, day by day',
            _MisRowOpen.outlet => 'that branch',
            _MisRowOpen.none => 'it',
          };
    final dead = _rows.length - open;
    return (
      icon: Icons.touch_app_outlined,
      label: dead == 0
          // "Some rows" rather than "tap a row" the moment any row is bare:
          // the weaker verb is the true one, and the count is what tells a
          // reader whether a mostly-dead report is a data gap worth chasing.
          ? 'Tap a row to open $what'
          : 'Some rows open $what · $dead of ${_rows.length} rows name none',
    );
  }

  String _misRowTitle(Map<String, dynamic> row) {
    final no = _s(row, 'bill_no', '');
    final table = _s(row, 'table_name', '');
    final left = no.isEmpty ? 'Bill' : 'Bill #$no';
    return table.isEmpty || table == '—' ? left : '$left · $table';
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) return _loadingSkeleton();
    if (_error != null) {
      return LoadErrorState(
        whatFailed: 'Could not load ${widget.report.title}.',
        error: _error!,
        onRetry: _load,
      );
    }

    final cols = _visibleColumns;
    final summary = _misSummary(context, widget.report, _payload);
    final flags = _misFlags(context, widget.report, _payload);
    final empty = _rows.isEmpty;

    return LayoutBuilder(builder: (context, box) {
      // WHEN THE TABLE STOPS BEING A TABLE. Width is the obvious trigger — see
      // [_MisCardList] for why fifteen columns cannot survive a 360dp phone —
      // but HEIGHT is the other one, and it bites on a desktop: a pinned header,
      // a pinned TOTALS row and a few rows under them need roughly 430px of
      // pane. Squeezed below that, the grid is a header and a footer with a
      // sliver of data between them, which is a worse way to read a control
      // report than a card. So the same degradation answers both: cards, one row
      // each, every value beside its own label.
      final narrow = MediaQuery.sizeOf(context).width < _misNarrow;
      final short = box.maxHeight.isFinite && box.maxHeight < _misGridMinHeight;
      final compact = narrow || short;

      final body = empty
          ? EmptyState(
              icon: widget.report.icon,
              title: 'Nothing in this period',
              caption: (widget.report.searchable && widget.search.isNotEmpty)
                  ? 'No rows match "${widget.search}" in this period.'
                  : '${widget.report.title} has no rows between ${widget.range.from} and ${widget.range.to}'
                      '${_slotPhrase == null ? '' : ' in $_slotPhrase'}.',
            )
          : compact
              ? _MisCardList(
                  key: const ValueKey('reports-cards'),
                  columns: cols,
                  rows: _rows,
                  totals: _totals,
                  actionFor: _rowAction,
                )
              : _MisGrid(
                  key: const ValueKey('reports-grid'),
                  columns: cols,
                  rows: _rows,
                  totals: _totals,
                  actionFor: _rowAction,
                );

      // COMPACT — one plain vertical scroll: the tiles, then a card per row.
      if (compact) {
        return cacheStaleOverlay(RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            children: [
              ...summary,
              if (flags.isNotEmpty) ...[
                Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: flags),
                const SizedBox(height: AppSpacing.md),
              ],
              _actionBar(context, narrow: true),
              const SizedBox(height: AppSpacing.md),
              if (empty) SizedBox(height: 280, child: body) else body,
              const SizedBox(height: AppSpacing.md),
              _footer(context),
            ],
          ),
        ));
      }

      // DESKTOP — the tiles and the controls are fixed chrome; the grid takes
      // the rest of the window and owns its own scrolling, so the header row
      // and the TOTALS row stay pinned while the rows move under them.
      //
      // The chrome is CAPPED at 45% of the pane and scrolls inside that cap.
      // Six tiles plus the money ladder plus three caveat chips is a tall
      // header, and an uncapped one would take pixels the grid needs.
      return cacheStaleOverlay(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...summary,
              if (flags.isNotEmpty)
                Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: flags),
            ]),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _actionBar(context, narrow: false),
        const SizedBox(height: AppSpacing.md),
        Expanded(child: body),
        const SizedBox(height: AppSpacing.sm),
        _footer(context),
      ]));
    });
  }

  Widget _actionBar(BuildContext context, {required bool narrow}) {
    final drill = _drillNote();
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ForkButton.ghost(
          key: const ValueKey('reports-columns'),
          label: 'Columns',
          icon: Icons.view_column_outlined,
          dense: true,
          onPressed: _columns.isEmpty ? null : _pickColumns,
        ),
        PopupMenuButton<ReportFormat>(
          key: const ValueKey('reports-export'),
          tooltip: 'Export this report',
          color: AppColors.cardRaised,
          enabled: !_exporting && _rows.isNotEmpty,
          onSelected: _export,
          itemBuilder: (_) => [
            for (final f in ReportFormat.values)
              PopupMenuItem<ReportFormat>(value: f, child: Text('Export ${f.label}')),
          ],
          child: IgnorePointer(
            child: ForkButton.ghost(
              label: _exporting ? 'Exporting…' : 'Export',
              icon: Icons.download_outlined,
              dense: true,
              onPressed: _rows.isEmpty ? null : () {},
            ),
          ),
        ),
        // Email: the server builds and sends the files for whole days, so it
        // waits for nothing on screen — only for somebody to choose addresses.
        Tooltip(
          message: kEmailButtonTooltip,
          child: ForkButton.ghost(
            key: const ValueKey('reports-email'),
            label: kEmailButtonLabel,
            icon: Icons.forward_to_inbox,
            dense: true,
            onPressed: () => _openEmailSend(
              context,
              rest: widget.rest,
              reportKey: widget.report.key,
              range: widget.range,
              slotPhrase: AppliedTimeSlot.fromMeta(_meta)?.phrase,
            ),
          ),
        ),
        ForkButton.ghost(
          key: const ValueKey('reports-notes'),
          label: 'How it is counted',
          icon: Icons.info_outline,
          dense: true,
          onPressed: _notes.isEmpty ? null : () => _misNotesSheet(context, _s(_meta, 'title', widget.report.title), _notes),
        ),
        ForkButton.ghost(
          label: 'Refresh',
          icon: Icons.refresh,
          dense: true,
          onPressed: _load,
        ),
        // WHETHER THESE ROWS OPEN ANYTHING, said in words, beside the controls
        // that act on them. Six of the fifteen reports are aggregates whose
        // rows correctly do nothing when tapped; without this the reader cannot
        // tell those from a broken screen, which is exactly how "the reports
        // are not clickable" was reported. The wording comes off the rows on
        // screen (see [_drillNote]), so it can never promise a tap the grid
        // will not honour.
        if (drill != null)
          InfoChip(
            key: const ValueKey('reports-drill'),
            icon: drill.icon,
            label: drill.label,
          ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final window = (_meta['window'] as Map?) ?? const {};
    // A LIST, not a flag: `clamped == true` never fired, so a window the server
    // really had shortened was never flagged here.
    final clamp = clampNotices(window['clamped']);
    final applied = AppliedTimeSlot.fromMeta(_meta);
    final shown = _rows.length;
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          widget.report.paged
              ? 'Showing $shown of $_total row${_total == 1 ? '' : 's'}'
              : '$shown row${shown == 1 ? '' : 's'}',
          style: text.bodySmall,
        ),
        if (_hasMore)
          ForkButton.ghost(
            key: const ValueKey('reports-more'),
            label: _appending ? 'Loading…' : 'Load more',
            icon: Icons.expand_more,
            dense: true,
            onPressed: _appending ? null : _loadMore,
          ),
        if (clamp.range)
          StatusChip(
            key: const ValueKey('reports-clamp'),
            label: 'Range shortened to ${window['from'] ?? '?'} – ${window['to'] ?? '?'}',
            color: AppColors.warning,
            dense: true,
          ),
        if (clamp.slot != null)
          StatusChip(
            key: const ValueKey('reports-slot-clamp'),
            label: clamp.slot!,
            color: AppColors.warning,
            dense: true,
          ),
        // What the SERVER cut on — never the chip's value.
        if (applied != null)
          InfoChip(key: const ValueKey('reports-slot-applied'), icon: Icons.access_time, label: applied.phrase),
        InfoChip(icon: Icons.public, label: '${_meta['timezone'] ?? RestaurantTime.zone}'),
      ],
    );
  }
}

// ------------------------------------------------------------ summary tiles --

/// Compact stat tile. Deliberately a fixed, small height (not [StatCard], whose
/// display-size numeral needs ~110px) because these sit as FIXED chrome above a
/// grid that wants the rest of the window.
Widget _misStat(BuildContext context, String label, String value, {String? sub, Color? tint}) {
  final text = Theme.of(context).textTheme;
  return SizedBox(
    width: 168,
    child: ForkCard(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label.toUpperCase(), style: text.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: tint ?? AppColors.textPrimary),
        ),
        if (sub != null) ...[
          const SizedBox(height: 3),
          Text(sub, style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ]),
    ),
  );
}

Widget _misTiles(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: tiles),
    );

/// The money ladder, spelled out.
///
/// This is the backend's pinned composition rendered verbatim —
/// `item total − discount = net + service charge + tax + round off = gross` —
/// and every one of the fifteen derives from it. The words are the client's
/// (models/gross_net.dart): Gross is the grand total, Net is after discount and
/// before the charges, and the top rung is the Item total. The top rung reads
/// `item_total`, falling back to the deprecated `gross` alias on an older
/// backend — never `grand_total`. Showing it, rather than only its
/// end, is what lets an owner see WHERE two reports would have to differ before
/// they could disagree.
Widget _misLadderCard(BuildContext context, Map ladder) {
  final text = Theme.of(context).textTheme;
  Widget line(String label, dynamic v, {String prefix = '', bool strong = false, bool rule = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          if (rule) Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(height: 1, color: AppColors.divider),
          ),
          Row(children: [
            SizedBox(width: 16, child: Text(prefix, style: text.bodySmall)),
            Expanded(child: Text(label, style: strong ? text.titleSmall : text.bodyMedium)),
            Text(_money(v),
                style: strong
                    ? text.titleSmall!.copyWith(color: AppColors.copperHi)
                    : const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ]),
        ]),
      );

  return ForkCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(title: 'Money ladder', padding: const EdgeInsets.only(bottom: 4)),
      Text('Every report in this pack derives from this one composition.', style: text.bodySmall),
      const SizedBox(height: AppSpacing.sm),
      line(kItemTotal, itemTotalOf(ladder)),
      line('Discount', ladder['discount'], prefix: '−'),
      line(kNet, ladder['net'], prefix: '=', strong: true, rule: true),
      line('Service charge', ladder['service_charge'], prefix: '+'),
      line('Tax', ladder['tax'], prefix: '+'),
      // Signed like every other round-off on a bill screen: the rung is a SUM of
      // per-bill round-offs and is usually negative, so a fixed '+' read as
      // "+ Round off ₹-3.45". Always drawn, like every rung of the ladder.
      line('Round off', _numOf(ladder['round_off']).abs(),
          prefix: _numOf(ladder['round_off']) < 0 ? '−' : '+'),
      line(kGross, ladder['grand_total'], prefix: '=', strong: true, rule: true),
      if (_numOf(ladder['refund']) > 0) line('Refunds', ladder['refund'], prefix: '−'),
    ]),
  );
}

/// Per-report headline tiles. One place, so the fifteen cannot drift into fifteen
/// different ideas of what their own summary is.
List<Widget> _misSummary(BuildContext context, _MisReport report, Map<String, dynamic> d) {
  final totals = (d['totals'] as Map?) ?? const {};
  switch (report.key) {
    case 'item_wise':
      return [
        _misTiles([
          _misStat(context, 'Items', '${_int(totals['items']) ?? 0}'),
          _misStat(context, 'Qty sold', '${_int(totals['qty']) ?? 0}'),
          // Item total only: Gross and Net are bill figures and cannot be put
          // on a dish honestly (the always-equal Net tile is gone).
          _misStat(context, kItemTotal, _money(totals['gross_amount']), sub: 'before any discount'),
          _misStat(context, 'Bill-level discount', _money(d['bill_level_discount']),
              sub: 'not spread across lines'),
        ]),
      ];
    case 'discount':
      return [
        _misTiles([
          _misStat(context, 'Discounted bills', '${_int(totals['discounted_bills']) ?? 0}'),
          _misStat(context, 'Given away', _money(totals['discount_amount']), tint: AppColors.warning),
          _misStat(context, '% of item total', misPercent(discountPctOf(totals)), sub: 'of everything sold'),
          _misStat(context, kItemTotal, _money(itemTotalOf(totals)), sub: 'discounted bills'),
          _misStat(context, kGross, _money(totals['grand_total']), sub: 'discounted bills'),
        ]),
      ];
    case 'void_kot':
      return [
        _misTiles([
          _misStat(context, 'Voided tickets', '${_int(totals['voids']) ?? 0}', tint: AppColors.danger),
          _misStat(context, 'Lines', '${_int(totals['item_count']) ?? 0}'),
          _misStat(context, 'Qty', '${_int(totals['qty']) ?? 0}'),
          _misStat(context, 'Value not earned', _money(totals['value']), tint: AppColors.danger),
        ]),
      ];
    case 'bill_edit':
      final kinds = (totals['by_kind'] as List?) ?? const [];
      return [
        _misTiles([
          _misStat(context, 'Edits', '${_int(totals['edits']) ?? 0}'),
          for (final k in kinds.take(4))
            if (k is Map) _misStat(context, '${k['label'] ?? k['kind']}', '${_int(k['count']) ?? 0}'),
        ]),
      ];
    case 'sales_summary':
      final salesNc = NcSettle.salesSummary(totals);
      return [
        _misTiles([
          _misStat(context, kGross, _money(totals['grand_total']), tint: AppColors.copperHi, sub: 'what guests paid'),
          _misStat(context, kNet, _money(totals['net']), sub: 'before SC, tax, round off'),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
          _misStat(context, 'Covers', '${_int(totals['covers']) ?? 0}'),
          _misStat(context, 'ABV', _money(totals['abv']), sub: 'tax-inclusive'),
          _misStat(context, 'APC', _money(totals['apc']), sub: 'pre-tax'),
        ]),
        _misLadderCard(context, totals),
        if (salesNc != null) ...[
          const SizedBox(height: AppSpacing.md),
          _misNcBeside(
            context,
            salesNc.bills,
            salesNc.value,
            'NC bills close at 0.00 and still count as bills (and their parties as covers), like a released '
            'table; the value given away is pre-tax, dishes comped one by one included.',
          ),
        ],
        const SizedBox(height: AppSpacing.md),
      ];
    case 'order_summary':
      return [
        _misTiles([
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
          _misStat(context, 'Covers', '${_int(totals['covers']) ?? 0}'),
          _misStat(context, kNet, _money(totals['net'])),
          _misStat(context, 'Tax', _money(totals['tax'])),
          _misStat(context, kGross, _money(totals['grand_total']), tint: AppColors.copperHi),
          _misStat(context, 'ABV', _money(totals['abv'])),
        ]),
      ];
    case 'executive_summary':
      final growth = (d['growth'] as Map?) ?? const {};
      final prevWindow = (d['previous_window'] as Map?) ?? const {};
      final prev = (d['previous'] as Map?) ?? const {};
      return [
        _misTiles([
          _misStat(context, kGross, _money(totals['grand_total']), tint: AppColors.copperHi),
          _misStat(context, 'vs previous', misPercent(growth['grand_total']),
              sub: _money(prev['grand_total']),
              tint: _misGrowthColor(growth['grand_total'])),
          _misStat(context, kNet, _money(totals['net']), sub: misPercent(growth['net'])),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}', sub: misPercent(growth['bills'])),
          _misStat(context, 'Covers', '${_int(totals['covers']) ?? 0}', sub: misPercent(growth['covers'])),
          _misStat(context, 'APC', _money(totals['apc']), sub: 'pre-tax · ${misPercent(growth['apc'])}'),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: InfoChip(
            icon: Icons.compare_arrows,
            label: 'Compared against ${prevWindow['from'] ?? '?'} to ${prevWindow['to'] ?? '?'}'
                ' (${prevWindow['basis'] == 'months' ? 'whole preceding month(s)' : 'the equally-long window before'})',
          ),
        ),
      ];
    case 'cover_size_summary':
      return [
        _misTiles([
          _misStat(context, 'Parties', '${_int(totals['parties']) ?? 0}'),
          _misStat(context, 'Covers', '${_int(totals['covers']) ?? 0}'),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
          _misStat(context, kNet, _money(totals['net'])),
          _misStat(context, kGross, _money(totals['grand_total']), tint: AppColors.copperHi),
          _misStat(context, 'APC', _money(totals['apc']), sub: 'pre-tax'),
        ]),
      ];
    case 'settlement_summary':
      final settleNc = NcSettle.settlementSummary(totals);
      return [
        _misTiles([
          _misStat(context, 'Collected', _money(totals['amount']), tint: AppColors.copperHi),
          _misStat(context, 'Refunds', _money(totals['refund'])),
          _misStat(context, kAfterRefunds, _money(totals['net_amount']), sub: 'tax still in'),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
          _misStat(context, 'Split-tender bills', '${_int(totals['split_bills']) ?? 0}'),
        ]),
        if (settleNc != null) ...[
          _misNcBeside(
            context,
            settleNc.bills,
            settleNc.value,
            'The $kNcSettleLabel row reads 0.00 and moves no total; the value beside it is what was given away '
            'in this window, before tax.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ];

    // ---- the six that read migrations 034-039 -------------------------------

    // BOTH FACTS, SIDE BY SIDE. A comp comes OUT of what the guest pays (so it
    // is in no sales figure and never a rung of the ladder) and it is STILL
    // revenue given away. "Given away" is therefore the headline, and "Net sales"
    // sits beside it so the share is a number the reader can check rather than
    // one they have to be told.
    case 'nc_summary':
      final kinds = (d['by_kind'] as List?) ?? const [];
      final reversed = _int(totals['reversed_entries']) ?? 0;
      final scopes = NcSettle.byScope(d);
      return [
        _misTiles([
          _misStat(context, 'Comps', '${_int(totals['entries']) ?? 0}',
              sub: reversed > 0 ? '$reversed reversed' : null),
          _misStat(context, 'Qty comped', '${_int(totals['quantity']) ?? 0}'),
          _misStat(context, 'Given away', _money(totals['loss']), tint: AppColors.danger),
          _misStat(context, '% of net sales', misPercent(totals['loss_pct_of_net'])),
          _misStat(context, 'Net sales', _money(totals['net_sales']), sub: 'settlement clock'),
          if (reversed > 0)
            _misStat(context, 'Reversed', _money(totals['reversed_loss']),
                sub: 'back on the bill'),
        ]),
        if (kinds.isNotEmpty) _misBreakdownCard(context, 'Why it was comped', [
          for (final k in kinds)
            if (k is Map)
              (
                label: '${k['label'] ?? k['kind']}',
                count: '${_int(k['entries']) ?? 0}',
                value: _money(k['loss']),
              ),
        ]),
        if (kinds.isNotEmpty) const SizedBox(height: AppSpacing.md),
        // Item = one dish comped; Bill = a line of a bill settled as NC.
        if (scopes.isNotEmpty) _misBreakdownCard(context, 'Dish comps and NC bills', [
          for (final sc in scopes) (label: sc.label, count: '${sc.entries}', value: _money(sc.loss)),
        ]),
        if (scopes.isNotEmpty) const SizedBox(height: AppSpacing.md),
      ];

    // The money the house chose NOT to charge. It never entered a sales figure,
    // so it is reported beside what WAS collected rather than inside it.
    case 'service_charge_deny':
      final kinds = (d['by_kind'] as List?) ?? const [];
      final reversed = _int(totals['reversed_waivers']) ?? 0;
      return [
        _misTiles([
          _misStat(context, 'Waivers', '${_int(totals['waivers']) ?? 0}',
              sub: reversed > 0 ? '$reversed reversed' : null),
          _misStat(context, 'Charge denied', _money(totals['amount_waived']), tint: AppColors.warning),
          _misStat(context, 'Tax denied', _money(totals['tax_on_waived'])),
          // Charge + tax, measured before each bill's round-off (migration 048):
          // not "off the grand total", which is rounded and can differ by paise.
          _misStat(context, 'Total reduction', _money(totals['grand_total_reduction']),
              sub: 'charge + tax, before round-off'),
          _misStat(context, 'Charge collected', _money(totals['service_charge_collected']),
              sub: 'settlement clock'),
          _misStat(context, '% denied', misPercent(totals['denied_pct_of_chargeable'])),
        ]),
        if (kinds.isNotEmpty) _misBreakdownCard(context, 'Why it came off', [
          for (final k in kinds)
            if (k is Map)
              (
                label: '${k['label'] ?? k['kind']}',
                count: '${_int(k['waivers']) ?? 0}',
                value: _money(k['amount']),
              ),
        ]),
        if (kinds.isNotEmpty) const SizedBox(height: AppSpacing.md),
      ];

    case 'group_summary':
      return [
        _misTiles([
          _misStat(context, 'Groups', '${_int(totals['groups']) ?? 0}'),
          _misStat(context, 'Items', '${_int(totals['items']) ?? 0}'),
          _misStat(context, 'Qty sold', '${_int(totals['qty']) ?? 0}'),
          _misStat(context, kItemTotal, _money(totals['gross_amount'])),
          _misStat(context, 'Bill-level discount', _money(d['bill_level_discount']),
              sub: 'not spread across lines'),
        ]),
      ];

    case 'variation_summary':
      return [
        _misTiles([
          _misStat(context, 'Dishes with sizes', '${_int(totals['items']) ?? 0}'),
          _misStat(context, 'Variations', '${_int(totals['variations']) ?? 0}'),
          _misStat(context, 'Qty sold', '${_int(totals['qty']) ?? 0}'),
          _misStat(context, kItemTotal, _money(totals['gross_amount'])),
          // The size of the subset, so a small number is visibly small rather
          // than mistaken for the whole menu's takings.
          _misStat(context, 'Whole menu item total', _money(d['window_gross']),
              sub: 'Item Wise, same window'),
        ]),
      ];

    // A TIP IS NOT REVENUE. It is on no rung of the ladder, in no APC and no
    // ABV, and the tender's own amount is deliberately not a column here — the
    // only number on this page is money that belongs to a person, not the house.
    case 'tip_summary':
      final people = (d['by_credited_to'] as List?) ?? const [];
      final modes = (d['by_mode'] as List?) ?? const [];
      return [
        _misTiles([
          _misStat(context, 'Tips', _money(totals['tip_amount']), tint: AppColors.copperHi,
              sub: 'not revenue'),
          _misStat(context, 'Tipped tenders', '${_int(totals['tenders']) ?? 0}'),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
        ]),
        if (people.isNotEmpty) _misBreakdownCard(context, 'Who is owed it', [
          for (final r in people)
            if (r is Map)
              (
                label: '${r['credited_to'] ?? '—'}',
                count: '${_int(r['tenders']) ?? 0}',
                value: _money(r['tips']),
              ),
        ]),
        if (people.isNotEmpty) const SizedBox(height: AppSpacing.md),
        if (modes.isNotEmpty) _misBreakdownCard(context, 'How it arrived', [
          for (final r in modes)
            if (r is Map)
              (
                label: '${r['label'] ?? r['mode']}',
                count: '${_int(r['tenders']) ?? 0}',
                value: _money(r['tips']),
              ),
        ]),
        if (modes.isNotEmpty) const SizedBox(height: AppSpacing.md),
      ];

    // The Sales Summary's own bill set, re-cut by till — so the ladder is shown
    // in full: the sum of these rows IS the Gross on the Sales Summary,
    // and the rungs are how a reader checks that rather than takes it on trust.
    case 'counter_summary':
      return [
        _misTiles([
          _misStat(context, 'Tills', '${_int(totals['counters']) ?? 0}'),
          _misStat(context, 'Bills', '${_int(totals['bills']) ?? 0}'),
          _misStat(context, kGross, _money(totals['grand_total']), tint: AppColors.copperHi),
          _misStat(context, kNet, _money(totals['net'])),
          _misStat(context, 'Cash sessions', '${_int(totals['sessions']) ?? 0}'),
          _misStat(context, 'Cash variance', _money(totals['variance']),
              sub: 'counted − expected',
              tint: _numOf(totals['variance']).abs() >= 0.01 ? AppColors.warning : null),
        ]),
        _misLadderCard(context, totals),
        const SizedBox(height: AppSpacing.md),
      ];
    default:
      return const [];
  }
}

/// NC BESIDE THE MONEY (client item 5): the bills settled as non-chargeable and
/// what was given away, in a card of its own under the figures — never a tile
/// among them, because nothing here was collected. The web panel says the same.
Widget _misNcBeside(BuildContext context, int bills, double value, String note) {
  final text = Theme.of(context).textTheme;
  return ForkCard(
    key: const ValueKey('mis-nc-beside'),
    inset: true,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${kNcSettleLabel.toUpperCase()} — NOT COLLECTED', style: text.labelSmall),
      const SizedBox(height: 4),
      Text(NcSettle.besideLine(bills, value, (v) => _money(v)), style: text.titleSmall),
      const SizedBox(height: 4),
      Text(note, style: text.bodySmall),
    ]),
  );
}

/// A named breakdown the server already computed — `by_kind`, `by_mode`,
/// `by_credited_to`. Rendered as a card rather than as more tiles because these
/// lists are open-ended (a tenant may credit tips to fifteen people) and a wrap
/// of fifteen tiles would push the table off the screen.
///
/// It is NOT a second table: nothing here is summed, sorted or derived on the
/// client. Every figure is printed exactly as the payload carries it, in the
/// order the payload carries it, which is the order the server chose.
Widget _misBreakdownCard(
  BuildContext context,
  String title,
  List<({String label, String count, String value})> rows,
) {
  final text = Theme.of(context).textTheme;
  return ForkCard(
    inset: true,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(title: title, count: rows.length, padding: const EdgeInsets.only(bottom: 6)),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(r.label, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: AppSpacing.sm),
            Text('${r.count}×', style: text.bodySmall),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 96,
              child: Text(r.value, textAlign: TextAlign.right, style: text.titleSmall),
            ),
          ]),
        ),
    ]),
  );
}

Color? _misGrowthColor(dynamic pct) {
  final n = misNum(pct);
  if (n == null || n == 0) return null;
  return n > 0 ? AppColors.success : AppColors.danger;
}

/// The caveats that must not be buried in a notes sheet — the ones that change
/// how a number should be READ, shown next to it.
List<Widget> _misFlags(BuildContext context, _MisReport report, Map<String, dynamic> d) {
  final totals = (d['totals'] as Map?) ?? const {};
  final chips = <Widget>[];

  if (report.key == 'item_wise') {
    if (d['category_exact'] == false) {
      chips.add(StatusChip(
        label: 'Category is matched by dish NAME — a renamed dish shows blank',
        color: AppColors.warning,
        dense: true,
      ));
    }
    chips.add(StatusChip(
      label: 'Counted on order time, not settlement — does not tie to Sales Summary',
      color: AppColors.info,
      dense: true,
    ));
  }
  if (report.key == 'discount') {
    final est = _int(totals['estimated_bills']) ?? 0;
    if (est > 0) {
      chips.add(StatusChip(
        label: '$est percentage discount${est == 1 ? '' : 's'} reconstructed from the settled total',
        color: AppColors.warning,
        dense: true,
      ));
    }
  }
  if (report.key == 'void_kot') {
    chips.add(StatusChip(
      label: 'No KOT number exists for an order — the order id is the ticket identity',
      color: AppColors.info,
      dense: true,
    ));
  }
  if (report.key == 'bill_edit') {
    chips.add(StatusChip(
      label: 'No before/after amounts are recorded anywhere — this shows what changed, never a difference',
      color: AppColors.info,
      dense: true,
    ));
  }
  if (report.key == 'settlement_summary') {
    final un = _numOf(totals['unallocated']);
    if (un.abs() >= 0.01) {
      chips.add(StatusChip(
        label: 'Unallocated ${_money(un)} — split parts do not add back to the bill total',
        color: AppColors.danger,
        dense: true,
      ));
    }
  }

  // ---- the six ------------------------------------------------------------

  if (report.key == 'nc_summary') {
    // The one thing a reader must not get wrong about this page: the money here
    // is NOT missing from the takings — it never entered them.
    chips.add(StatusChip(
      label: 'Comped food is in no sales figure — this is revenue given away, not revenue lost from a total',
      color: AppColors.info,
      dense: true,
    ));
    if (d['category_exact'] == false) {
      chips.add(StatusChip(
        label: 'Category is matched by dish NAME — a renamed dish shows blank',
        color: AppColors.warning,
        dense: true,
      ));
    }
    final rev = _int(totals['reversed_entries']) ?? 0;
    if (rev > 0) {
      chips.add(StatusChip(
        label: '$rev comp${rev == 1 ? ' was' : 's were'} reversed — still listed, worth zero, with the amount under Reversed',
        color: AppColors.info,
        dense: true,
      ));
    }
  }

  if (report.key == 'service_charge_deny') {
    chips.add(StatusChip(
      label: 'A denied charge never entered a sales figure — it is what the house chose not to charge',
      color: AppColors.info,
      dense: true,
    ));
    final rev = _int(totals['reversed_waivers']) ?? 0;
    if (rev > 0) {
      chips.add(StatusChip(
        label: '$rev waiver${rev == 1 ? ' was' : 's were'} reversed — the charge went back on',
        color: AppColors.info,
        dense: true,
      ));
    }
  }

  if (report.key == 'group_summary') {
    chips.add(StatusChip(
      label: 'Item total ties to Item Wise for the same window — the same lines, re-cut',
      color: AppColors.info,
      dense: true,
    ));
    // TWO GAPS, NEVER ONE. Unclassified is a configuration gap an owner can
    // close and watch shrink to zero; Unattributed is a history gap that cannot
    // be closed backwards. Folding them together would tell an owner who has
    // just filed their whole menu that a bucket they cannot empty is their fault.
    final unclassified = _numOf(totals['unclassified_gross']);
    if (unclassified.abs() >= 0.01) {
      chips.add(StatusChip(
        label: '${_money(unclassified)} in Unclassified — dishes that are on the menu and in no group. File them to close it.',
        color: AppColors.warning,
        dense: true,
      ));
    }
    final unattributed = _numOf(totals['unattributed_gross']);
    if (unattributed.abs() >= 0.01) {
      chips.add(StatusChip(
        label: '${_money(unattributed)} in Unattributed — lines that match no menu row at all. History; it cannot be reclassified backwards.',
        color: AppColors.info,
        dense: true,
      ));
    }
  }

  if (report.key == 'variation_summary') {
    if (d['no_variations_configured'] == true) {
      chips.add(StatusChip(
        label: 'No variations are configured — add price points to a dish on the Menu screen and its sizes appear here',
        color: AppColors.warning,
        dense: true,
      ));
    }
    chips.add(StatusChip(
      label: 'Only dishes that HAVE sizes appear — a variation is never inferred from a typed name',
      color: AppColors.info,
      dense: true,
    ));
  }

  if (report.key == 'tip_summary') {
    chips.add(StatusChip(
      label: 'A tip is NOT revenue — it is in no sales figure, no APC and no ABV, and no rung of the money ladder',
      color: AppColors.info,
      dense: true,
    ));
  }

  if (report.key == 'counter_summary') {
    chips.add(StatusChip(
      label: 'These rows sum to the Sales Summary Gross — the same bills, cut by the till that rang them',
      color: AppColors.info,
      dense: true,
    ));
    if (d['no_counters_configured'] == true) {
      chips.add(StatusChip(
        label: 'No tills are configured — every bill sits on this outlet’s single till. Add one under Settings → Billing counters.',
        color: AppColors.warning,
        dense: true,
      ));
    }
    final variance = _numOf(totals['variance']);
    if (variance.abs() >= 0.01) {
      chips.add(StatusChip(
        label: 'Cash variance ${_money(variance)} across the cash sessions in this window',
        color: AppColors.warning,
        dense: true,
      ));
    }
  }
  final withoutCovers = _int(totals['bills_without_covers']) ?? 0;
  if (withoutCovers > 0) {
    chips.add(StatusChip(
      label: '$withoutCovers bill${withoutCovers == 1 ? '' : 's'} carry money but no covers',
      color: AppColors.info,
      dense: true,
    ));
  }

  return chips;
}

/// `meta.notes`, verbatim. Every caveat the server attached to the numbers, in
/// the server's own words — and the same list every export carries.
void _misNotesSheet(BuildContext context, String title, List<String> notes) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) {
      final text = Theme.of(ctx).textTheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('HOW THESE NUMBERS ARE COUNTED', style: text.labelSmall),
                const SizedBox(height: 4),
                Text(title, style: text.headlineMedium),
                const SizedBox(height: AppSpacing.lg),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 2.5,
                        height: 12,
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: AppColors.copperHi,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(n, style: text.bodySmall!.copyWith(height: 1.45))),
                    ]),
                  ),
                const SizedBox(height: AppSpacing.sm),
                Text('Every export of this report carries these lines on its first page.',
                    style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
              ]),
            ),
          ),
        ),
      );
    },
  );
}

// ------------------------------------------------------------------- grid ----

/// Pane height below which a pinned-header grid stops being worth having: a
/// 34px header, a 38px TOTALS row, the chrome above them and four rows of data
/// in between. Under it the report degrades to cards, the same way it does when
/// the window is too narrow.
const double _misGridMinHeight = 430;

const double _misRowH = 38;
const double _misHeadH = 34;

double _misColWidth(MisColumn c, {bool first = false}) {
  switch (c.type) {
    case 'money':
      return 118;
    case 'percent':
      return 96;
    case 'int':
      return 84;
    case 'datetime':
      return 148;
    case 'date':
      return 110;
    default:
      return first ? 190 : 170;
  }
}

/// The wide-screen table: a frozen first column, a horizontally scrolling body,
/// a pinned header and a pinned TOTALS row.
///
/// The first column is frozen because it is the row's IDENTITY — the bill
/// number, the dish, the payment mode — and a fourteen-column control report
/// scrolled six columns right with no idea which row you are on is how a number
/// gets attributed to the wrong bill.
///
/// WHICH column is frozen is the SERVER's column order, unchanged — the same
/// order the CSV, the sheet and the PDF use, so the four surfaces of one report
/// never disagree about what sits where. The reader still chooses the anchor:
/// switching a column off in the picker promotes the next one, so an Order
/// Summary read by bill number rather than by clock is one checkbox away.
///
/// Alignment between the frozen half and the scrolling half is by construction,
/// not by measurement: both are Columns of fixed-height rows inside ONE vertical
/// scroll, so they cannot drift. The header and the totals row keep their own
/// horizontal scrollers, mirrored from the body's — they are not draggable
/// themselves, so there is exactly one thing driving the offset.
class _MisGrid extends StatefulWidget {
  const _MisGrid({
    super.key,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.actionFor,
  });

  final List<MisColumn> columns;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? totals;
  final VoidCallback? Function(Map<String, dynamic> row) actionFor;

  @override
  State<_MisGrid> createState() => _MisGridState();
}

class _MisGridState extends State<_MisGrid> {
  final ScrollController _body = ScrollController();
  final ScrollController _head = ScrollController();
  final ScrollController _foot = ScrollController();
  int _hover = -1;

  @override
  void initState() {
    super.initState();
    _body.addListener(_mirror);
  }

  @override
  void dispose() {
    _body.removeListener(_mirror);
    _body.dispose();
    _head.dispose();
    _foot.dispose();
    super.dispose();
  }

  void _mirror() {
    final x = _body.offset;
    for (final c in [_head, _foot]) {
      if (c.hasClients && c.offset != x) {
        // Clamped to the follower's own extent: the header row and the totals
        // row are the same width as the body, but a frame in which one has not
        // been laid out yet must not throw.
        c.jumpTo(x.clamp(c.position.minScrollExtent, c.position.maxScrollExtent));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = widget.columns;
    if (cols.isEmpty) {
      return const EmptyState(
        icon: Icons.view_column_outlined,
        title: 'No columns selected',
        caption: 'Turn a column back on to see this report.',
      );
    }
    final first = cols.first;
    final rest = cols.skip(1).toList();
    final w0 = _misColWidth(first, first: true);
    final restWidth = rest.fold<double>(0, (s, c) => s + _misColWidth(c));
    final totals = widget.totals;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Pinned header.
      Container(
        decoration: BoxDecoration(
          color: AppColors.inset,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.control)),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          SizedBox(width: w0, height: _misHeadH, child: _head1(context, first, frozen: true)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _head,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: restWidth,
                height: _misHeadH,
                child: Row(children: [for (final c in rest) SizedBox(width: _misColWidth(c), child: _head1(context, c))]),
              ),
            ),
          ),
        ]),
      ),
      // Body: ONE vertical scroll over both halves.
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.border),
              right: BorderSide(color: AppColors.border),
            ),
          ),
          child: SingleChildScrollView(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: w0,
                child: Column(children: [
                  for (var i = 0; i < widget.rows.length; i++)
                    _cellRow(context, i, [first], frozen: true, width: w0),
                ]),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: _body,
                  child: SizedBox(
                    width: restWidth,
                    child: Column(children: [
                      for (var i = 0; i < widget.rows.length; i++)
                        _cellRow(context, i, rest, frozen: false, width: restWidth),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      // Pinned TOTALS row. The window's totals, never the page's — which is why
      // it says so.
      if (totals != null)
        Container(
          decoration: BoxDecoration(
            color: AppColors.cardRaised,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(AppRadius.control)),
            border: Border.all(color: AppColors.borderStrong),
          ),
          child: Row(children: [
            SizedBox(
              width: w0,
              height: _misRowH,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('TOTAL · whole period',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: AppColors.copperHi)),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _foot,
                physics: const NeverScrollableScrollPhysics(),
                child: SizedBox(
                  width: restWidth,
                  height: _misRowH,
                  child: Row(children: [
                    for (final c in rest)
                      SizedBox(
                        width: _misColWidth(c),
                        // Only a column the SERVER marks summable carries a
                        // total. Summing an average or a share would be a
                        // number nobody could reproduce.
                        child: _cell(context, c, c.total ? totals[c.key] : null,
                            strong: true, blankIfNull: !c.total),
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
    ]);
  }

  Widget _head1(BuildContext context, MisColumn c, {bool frozen = false}) => Container(
        alignment: c.isNumeric ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: frozen
            ? BoxDecoration(border: Border(right: BorderSide(color: AppColors.borderStrong)))
            : null,
        child: Text(
          c.label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );

  Widget _cellRow(BuildContext context, int i, List<MisColumn> cols,
      {required bool frozen, required double width}) {
    final row = widget.rows[i];
    final action = widget.actionFor(row);
    final hovered = _hover == i;
    final child = Container(
      width: width,
      height: _misRowH,
      decoration: BoxDecoration(
        color: hovered
            ? Colors.white.withValues(alpha: 0.04)
            : (i.isOdd ? Colors.white.withValues(alpha: 0.012) : Colors.transparent),
        border: Border(
          bottom: BorderSide(color: AppColors.divider),
          right: frozen ? BorderSide(color: AppColors.borderStrong) : BorderSide.none,
        ),
      ),
      child: Row(children: [
        // The frozen half holds exactly one column and takes what the border
        // leaves it — a fixed SizedBox there overflows the 1px hairline.
        for (final c in cols)
          if (frozen)
            Expanded(child: _cell(context, c, row[c.key]))
          else
            SizedBox(width: _misColWidth(c), child: _cell(context, c, row[c.key])),
        // THE AFFORDANCE, ON THE ROW ITSELF. A pointer cursor that only appears
        // once the pointer is already over the row tells a reader nothing
        // before they try it, and tells a touch screen nothing at all — which
        // is how a correctly-inert aggregate row and a broken control came to
        // look identical. The chevron rides in the FROZEN half so it stays put
        // while the table scrolls sideways, and it is decided per ROW: on Bill
        // Edit, where only the rows the audit recorded an id on can open, its
        // absence is the honest signal that this particular row has nothing
        // behind it.
        if (frozen && action != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.chevron_right, size: 15, color: AppColors.textTertiary),
          ),
      ]),
    );
    if (action == null) {
      // The hover tint stays on a row that opens nothing: across fifteen
      // columns of horizontal scroll it is how a reader keeps their place, not
      // a promise of a tap. The promise is the chevron and the cursor, and
      // neither is drawn here.
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = i),
        onExit: (_) => setState(() => _hover = -1),
        child: child,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() => _hover = -1),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: action, child: child),
    );
  }

  Widget _cell(BuildContext context, MisColumn c, Object? v,
          {bool strong = false, bool blankIfNull = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Align(
          alignment: c.isNumeric ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            blankIfNull && v == null ? '' : misText(c, v),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              color: strong ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      );
}

// ------------------------------------------------------------- phone cards ---

/// The narrow-screen form of the same table: ONE CARD PER ROW, every visible
/// column as a labelled line.
///
/// THE CHOICE, and why. A fifteen-column grid does not survive a 360dp phone in
/// any form. A frozen first column leaves ~190dp of viewport for fourteen
/// columns — eight screens of sideways travel per row — and the moment a reader
/// scrolls right, the only thing telling them WHICH column a number sits in is a
/// header they must scroll back to read. In a fraud-control document that is not
/// an inconvenience, it is a misattribution waiting to happen.
///
/// A card keeps every value glued to its own label, so a number can never be
/// read under the wrong heading. It costs vertical space — which is exactly what
/// the column picker is for, and what makes that control worth having on a
/// phone. Nothing is dropped or folded away: every column the reader has switched
/// on appears, because silently hiding a column of a control report is the same
/// failure by another route.
class _MisCardList extends StatelessWidget {
  const _MisCardList({
    super.key,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.actionFor,
  });

  final List<MisColumn> columns;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? totals;
  final VoidCallback? Function(Map<String, dynamic> row) actionFor;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (columns.isEmpty) {
      return const EmptyState(
        icon: Icons.view_column_outlined,
        title: 'No columns selected',
        caption: 'Turn a column back on to see this report.',
      );
    }
    final title = columns.first;
    // The card's headline figure: the last money column the reader kept on,
    // which for almost every one of the fifteen is the row bottom line.
    MisColumn? headline;
    for (final c in columns.skip(1)) {
      if (c.type == 'money') headline = c;
    }
    final body = [for (final c in columns.skip(1)) if (c.key != headline?.key) c];

    // The tap and the chevron read the SAME value, resolved once per row. Two
    // separate calls to `actionFor` would let a card grow a chevron it does not
    // honour (or eat a tap it never advertised) the moment that classifier
    // stopped being pure — which is precisely the failure this pack is about.
    final cards = [for (final row in rows) (row: row, action: actionFor(row))];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final card in cards)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ForkCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            onTap: card.action,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(misText(title, card.row[title.key]),
                      style: text.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                if (headline != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(misText(headline, card.row[headline.key]),
                      style: text.titleSmall!.copyWith(color: AppColors.copperHi)),
                ],
                if (card.action != null)
                  Icon(Icons.chevron_right, size: 17, color: AppColors.textTertiary),
              ]),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(height: 1, color: AppColors.divider),
                const SizedBox(height: 4),
                for (final c in body) _misPair(context, c.label, misText(c, card.row[c.key])),
              ],
            ]),
          ),
        ),
      if (totals != null) ...[
        const SizedBox(height: AppSpacing.xs),
        ForkCard(
          inset: true,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('TOTAL · WHOLE PERIOD',
                style: text.labelSmall!.copyWith(color: AppColors.copperHi)),
            const SizedBox(height: 6),
            for (final c in columns)
              if (c.total) _misPair(context, c.label, misText(c, totals![c.key])),
          ]),
        ),
      ],
    ]);
  }
}

Widget _misPair(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 5,
          child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          flex: 6,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );

// -------------------------------------------------------------- drill-down ---

/// The full bill behind a row.
///
/// Deliberately rendered by `_closedBillBody` — the SAME body the History
/// screen and the settled-bill browser use — so a drill-down out of a control
/// report can never show a different bill from the one the rest of the product
/// shows. The endpoint is the reports' own (`/reports/mis/bill/:id`), which the
/// backend built on the same reader for the same reason.
void _misOpenBill(BuildContext context, RestClient rest, String billId, String title) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: AsyncView<Map<String, dynamic>>(
            load: () => rest.getMap('/reports/mis/bill/$billId'),
            builder: (ctx, bill, reload) =>
                // reportWords: the row this opened from says Item total / Net /
                // Gross, and so does the web's drill-down for the same bill.
                SingleChildScrollView(child: _closedBillBody(ctx, bill, title, reportWords: true)),
          ),
        ),
      ),
    ),
  );
}

/// The full KOT (order) behind a Void KOT row, or behind a Bill Edit row that
/// names an order rather than a bill: what was on the ticket, and the audit
/// trail that is the actual subject of a void or an edit.
void _misOpenKot(BuildContext context, RestClient rest, String orderId) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: AsyncView<Map<String, dynamic>>(
            load: () => rest.getMap('/reports/mis/kot/$orderId'),
            builder: (ctx, order, reload) => SingleChildScrollView(child: _misKotBody(ctx, order)),
          ),
        ),
      ),
    ),
  );
}

Widget _misKotBody(BuildContext context, Map order) {
  final text = Theme.of(context).textTheme;
  final items = ((order['items'] as List?) ?? const []).whereType<Map>().toList();
  final trail = ((order['trail'] as List?) ?? const []).whereType<Map>().toList();
  final billNo = _s(order, 'bill_no', '');
  final id = _s(order, 'id', '');
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('KITCHEN TICKET', style: text.labelSmall),
          const SizedBox(height: 4),
          Text(_s(order, 'table_name', 'Order'), style: text.headlineMedium),
        ]),
      ),
      Text(_money(order['value']), style: text.displaySmall!.copyWith(fontSize: 22)),
    ]),
    const SizedBox(height: AppSpacing.sm),
    Wrap(spacing: 6, runSpacing: 6, children: [
      StatusChip(
        label: _s(order, 'status', 'Unknown'),
        color: _s(order, 'status', '').toLowerCase() == 'cancelled' ? AppColors.danger : AppColors.info,
        dense: true,
      ),
      InfoChip(icon: Icons.dining, label: _s(order, 'order_type', 'Dine-in')),
      if (_s(order, 'taken_by', '').isNotEmpty)
        InfoChip(icon: Icons.person_outline, label: 'Taken by ${_s(order, 'taken_by')}'),
      InfoChip(icon: Icons.schedule, label: _fmtTime(_s(order, 'created_at', ''))),
      if (billNo.isNotEmpty && billNo != '—') InfoChip(icon: Icons.receipt_long, label: 'Bill #$billNo'),
      // The order id IS the ticket identity here: "KotTickets" keys its number
      // by a content fingerprint, not by order id, so no KOT number can be
      // joined back — and a guessed identifier in a control document is worse
      // than a blank one.
      if (id.isNotEmpty) InfoChip(icon: Icons.tag, label: _capped(id, 12)),
    ]),
    const SizedBox(height: AppSpacing.lg),
    ForkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(title: 'Items', count: items.length, padding: const EdgeInsets.only(bottom: 6)),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(
                width: 34,
                child: Text('${_int(it['quantity']) ?? 1}×',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // A comped line is marked as the bill marks it (the web drill-down
                  // says the same); its figure stays the ticket's — what was cooked.
                  Text(NcSettle.lineLabel(_s(it, 'name'), it['nc']), style: text.bodyMedium),
                  if (_s(it, 'note', '').isNotEmpty)
                    Text(_s(it, 'note'), style: text.bodySmall),
                ]),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(_money(it['line_total']), style: text.titleSmall),
            ]),
          ),
        if (items.isEmpty) Text('This ticket carries no item lines.', style: text.bodySmall),
      ]),
    ),
    const SizedBox(height: AppSpacing.lg),
    ForkCard(
      inset: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(title: 'Audit trail', count: trail.length, padding: const EdgeInsets.only(bottom: 6)),
        Text('Every entry the immutable trail holds for this order, newest first.',
            style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        for (final t in trail)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_s(t, 'action'), style: text.titleSmall)),
                Text(_fmtTime(_s(t, 'at', '')), style: text.bodySmall),
              ]),
              if (_s(t, 'description', '').isNotEmpty)
                Text(_s(t, 'description'), style: text.bodySmall),
              if (_s(t, 'by', '').isNotEmpty)
                Text('by ${_s(t, 'by')}',
                    style: text.bodySmall!.copyWith(color: AppColors.textTertiary)),
            ]),
          ),
        if (trail.isEmpty)
          Text('No audit entry names this order.', style: text.bodySmall),
      ]),
    ),
  ]);
}
