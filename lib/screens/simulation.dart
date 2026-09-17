// -------------------------------------------------------------- simulation ----
//
// The what-if simulator. The owner picks which of the 34 model PARAMETERS to
// work with, adjusts them, and the backend's pure model projects the numbers:
// covers, APC, revenue, labour, food, fixed costs, net profit, turnaround.
// GET /simulation/baseline feeds the live "Current Performance" card and seeds
// every lever's neutral position; "Run Simulation" POSTs the ACTIVE levers to
// /simulation/run and renders CURRENT | SIMULATED | DELTA.
//
// ITS OWN LIBRARY, not another 500 lines of modules.dart. `simulationModule` is
// re-exported from there so home_shell.dart's permission gating keeps working
// untouched — and that gate is load-bearing: the tile matches permitted ACTION
// NAMES, and the action authorising /simulation/* server-side is called "View
// Order APC", which is why its keyword list is ['analytics', 'apc', 'report'].
//
// THE PICKER, AND WHY IT IS SAFE. An INACTIVE lever is omitted from the POST
// body entirely, and the server resolves a missing field to THIS TENANT's
// neutral value — their headcount, the wage that reproduces their labour bill,
// their measured TAT and table count. So a removed lever contributes its own
// default, never zero, and a lever sitting at its default is the same
// simulation as a lever that is absent. See lib/models/simulation_params.dart,
// which is the entry-for-entry mirror of the web dashboard's catalogue.
//
// The reference implementation of this screen rendered ₹NaN in every delta
// cell. The backend contract promises finite numbers, but the UI holds the line
// independently: every figure that reaches a Text goes through [simFinite]
// first, so even a malformed payload renders finite zeros, never NaN.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/simulation_params.dart';
import '../services/outbox.dart';
import '../services/rest_client.dart';
import '../ui/gaia/gaia.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/app_search_field.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/section_header.dart';
import '../ui/widgets/status_chip.dart';
import '../widgets/async_view.dart';

/// One column on a phone, the two cards side by side once the window can hold
/// them — the same breakpoint Analytics and Accounting use. It also decides how
/// the lever picker is presented (see [_SimulationViewState._openPicker]).
const double _kNarrow = 760;

Widget simulationModule(RestClient rest, Profile p) => AsyncView<Map<String, dynamic>>(
      // The baseline is REQUIRED — no catchError: a tenant that cannot load it
      // gets AsyncView's retry screen rather than a simulator over fake zeros.
      load: () => rest.getMap('/simulation/baseline'),
      builder: (context, baseline, reload) => _SimulationView(
        rest: rest,
        baseline: baseline,
        reloadBaseline: reload,
      ),
    );

/// Whole-rupee money with the sign OUTSIDE the ₹ — "₹1234" / "-₹1234" — the
/// convention the accounting screens already use.
String _simMoney(num v) {
  final r = v.round();
  return r < 0 ? '-₹${-r}' : '₹$r';
}

/// Covers/TAT figure to 0.1, with a pointless ".0" dropped ("89.9", "42").
String _simNum(num v) {
  final d = double.parse(v.toStringAsFixed(1));
  return d == d.roundToDouble() ? '${d.round()}' : d.toStringAsFixed(1);
}

/// What the screen says when the line is down.
///
/// POST /simulation/run is a WRITE to the transport and a read-only projection
/// to the user: it stores nothing, so there is nothing to queue and nothing to
/// lose. The outbox refuses it (correctly — it is not one of the 27
/// server-deduplicated routes) with its generic "This isn't saved offline"
/// sentence, which is honest for a write and misleading here: it implies work
/// was dropped. So this screen translates the refusal into what actually
/// happened.
const String _offlineMessage =
    'The simulator needs a connection. This projection is calculated on the '
    'server and saves nothing, so no work was lost — reconnect and run it again. '
    'Your levers are still exactly where you left them.';

class _SimulationView extends StatefulWidget {
  final RestClient rest;
  final Map<String, dynamic> baseline;
  final VoidCallback reloadBaseline;
  const _SimulationView(
      {required this.rest, required this.baseline, required this.reloadBaseline});
  @override
  State<_SimulationView> createState() => _SimulationViewState();
}

/// One row of the results table: which response key it reads, how it formats,
/// and whether a RISE in it is bad ([cost] inverts the delta colour — labour,
/// food, fixed costs and TAT going up are red, not green).
///
/// [neutral] switches the colouring off entirely for the display-only tax line;
/// [optional] rows appear only when they actually carry a number, so a tenant
/// who never touches discounts or service charge still sees the eight rows they
/// always saw.
typedef _SimRow = ({
  String key,
  String label,
  bool money,
  bool minutes,
  bool cost,
  bool neutral,
  bool optional,
});

class _SimulationViewState extends State<_SimulationView> {
  /// THE PER-TENANT NEUTRAL VALUES — what the change-dot and both reset controls
  /// compare against. Derived from the live baseline exactly the way the
  /// backend's resolveParams derives them, NOT from hardcoded constants: six
  /// levers have no catalogue default at all.
  late Map<String, Object> _defaults;

  /// The value of EVERY lever in the catalogue, active or not. Removing a lever
  /// keeps its value here, so re-adding it restores where it was left.
  late Map<String, Object> _values;

  /// Which levers the owner has chosen to work with. Widget state only — there
  /// is deliberately no backend call and no DB column for the active set.
  late Set<String> _active;

  Map<String, dynamic>? _result;

  /// The body that produced [_result], so the payback line describes the run on
  /// screen rather than whatever the sliders say now.
  Map<String, dynamic>? _ranWith;

  bool _running = false;
  String? _runError;

  /// Anchor for the desktop popover.
  final GlobalKey _addButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _seed();
    _active = {...kInitialActiveKeys};
  }

  @override
  void didUpdateWidget(covariant _SimulationView old) {
    super.didUpdateWidget(old);
    // A baseline refresh re-seeds every lever from the fresh numbers — fresher
    // baseline, fresher defaults. The ACTIVE SELECTION deliberately survives:
    // asking for newer numbers is not a request to throw away the levers the
    // owner picked.
    if (!identical(old.baseline, widget.baseline)) {
      setState(() {
        _seed();
        _result = null;
        _ranWith = null;
        _runError = null;
      });
    }
  }

  void _seed() {
    _defaults = resolveDefaults(widget.baseline);
    _values = Map<String, Object>.from(_defaults);
  }

  // -------------------------------------------------------------- state ----

  void _toggleLever(String key) => setState(() {
        if (!_active.remove(key)) _active.add(key);
      });

  /// Pulls a lever out of the run WITHOUT touching its stored value.
  void _removeLever(String key) => setState(() => _active.remove(key));

  void _setValue(String key, Object value) => setState(() => _values[key] = value);

  void _resetLever(String key) => setState(() => _values[key] = _defaults[key]!);

  /// Resets EVERY parameter, active or not. The active selection is untouched.
  void _resetAllValues() => setState(() {
        _values = Map<String, Object>.from(_defaults);
        _result = null;
        _ranWith = null;
      });

  int get _changedCount =>
      kParamCatalog.where((s) => isChanged(_values, _defaults, s.key)).length;

  Future<void> _run() async {
    // ONLY the active levers travel. An omitted field resolves server-side to
    // this tenant's neutral value, so a removed lever contributes its default
    // rather than zero (verified against resolveParams in simulation_math.ts).
    final body = buildRunBody(_active, _values);
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final res = await widget.rest.post('/simulation/run', body);
      if (!mounted) return;
      setState(() {
        _result = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
        _ranWith = body;
        _running = false;
      });
    } on OfflineUnavailable catch (_) {
      // The outbox's generic refusal describes a lost write. This one loses
      // nothing — say so (see [_offlineMessage]).
      if (!mounted) return;
      setState(() {
        _runError = _offlineMessage;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runError = '$e';
        _running = false;
      });
    }
  }

  // ------------------------------------------------------------- picker ----

  /// "+ Add a lever".
  ///
  /// PHONE vs DESKTOP, decided deliberately. 34 parameters with a search box do
  /// not fit under a button on a 640dp-tall phone — a popover there would show
  /// four rows and hide the search field behind the keyboard. So a phone gets a
  /// MODAL BOTTOM SHEET at 85% height (thumb-reachable, the idiom every other
  /// picker in this app already uses), and a desktop window gets a real popover
  /// anchored under the button, which is where the eye already is. Both are the
  /// same panel widget, so the behaviour cannot drift: search filters the whole
  /// catalogue, checking adds, unchecking removes, and tapping outside closes.
  Future<void> _openPicker() async {
    final narrow = MediaQuery.sizeOf(context).width < _kNarrow;
    if (narrow) {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        builder: (_) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
            child: _LeverPickerPanel(
              active: _active,
              onToggle: _toggleLever,
              autofocusSearch: false,
            ),
          ),
        ),
      );
      return;
    }

    // Anchored popover. Position is measured off the trigger against the root
    // overlay, then clamped so a button near the right or bottom edge still
    // opens a panel that is entirely on screen.
    final box = _addButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
    const width = 360.0;
    var left = 16.0;
    var top = 120.0;
    var maxHeight = 420.0;
    if (box != null && overlay != null && box.hasSize) {
      final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
      final size = overlay.size;
      left = origin.dx.clamp(8.0, math.max(8.0, size.width - width - 8));
      // Below the button by default. A short desktop window (this path starts at
      // 760 logical px WIDE, which says nothing about its height) can leave less
      // room under the button than over it — then the panel flips up rather than
      // hanging off the bottom edge where its footer and half its list are
      // simply not there.
      final below = size.height - (origin.dy + box.size.height + 6) - 16;
      final above = origin.dy - 6 - 16;
      if (below >= 220 || below >= above) {
        top = origin.dy + box.size.height + 6;
        maxHeight = math.max(160.0, math.min(440.0, below));
      } else {
        maxHeight = math.max(160.0, math.min(440.0, above));
        top = math.max(8.0, origin.dy - 6 - maxHeight);
      }
    }

    await showDialog<void>(
      context: context,
      // Transparent barrier, but still a barrier: a tap anywhere outside closes
      // the panel, and Escape does too.
      barrierColor: Colors.transparent,
      builder: (_) => Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ForkCard(
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: AppRadius.cardAll,
                  child: _LeverPickerPanel(
                    active: _active,
                    onToggle: _toggleLever,
                    autofocusSearch: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // -------------------------------------------------------------- build ----

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < _kNarrow;
    final levers = _leversCard(context);
    final current = _currentCard(context);
    return ListView(padding: AppSpacing.pageNarrow, children: [
      // BICOLOUR's opening move: the screen is cut in two, your restaurant on
      // the dark side and the hypothesis on the champagne side. It restates
      // one number that is already on this page twice over (in Current
      // Performance and in the results table) — nothing is computed here, and
      // nothing about the run changes.
      if (Gaia.of(context)) ...[
        _bicolourSplit(context, narrow),
        const SizedBox(height: AppSpacing.lg),
      ],
      if (narrow) ...[
        levers,
        const SizedBox(height: AppSpacing.lg),
        current,
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: levers),
          const SizedBox(width: AppSpacing.lg),
          Expanded(flex: 2, child: current),
        ]),
      const SizedBox(height: AppSpacing.xxl),
      ..._resultsSection(context),
      const SizedBox(height: AppSpacing.xxl),
    ]);
  }

  /// `.bico`'s two-up header. The scenario half sits at rest — an em dash and
  /// a sentence — until a run has actually happened: filling it with the
  /// baseline before then would show a projection nobody asked for, and
  /// filling it with zero would show a projection of ruin.
  Widget _bicolourSplit(BuildContext context, bool narrow) {
    final b = widget.baseline;
    final res = _result;
    final curNet = simFinite(b['net_profit_per_day']);
    final curRev = simFinite(b['revenue_per_day']);
    final curLab = simFinite(b['labour_cost_per_day']);

    final sim = (res?['simulated'] as Map?) ?? const {};
    final simNet = simFinite(sim['net_profit']);
    final ran = res != null;

    return GaiaBicolourSplit(
      stacked: narrow,
      current: GaiaBicolourFace(
        eyebrow: 'Current · net per day',
        value: _simMoney(curNet),
        valueColor: curNet < 0 ? GaiaColors.coral : GaiaColors.text,
        detail: 'Revenue ${_simMoney(curRev)} · labour ${_simMoney(curLab)}',
      ),
      scenario: GaiaBicolourFace(
        eyebrow: 'Scenario · net per day',
        value: _simMoney(simNet),
        // Re-inked for the champagne ground by GaiaBicolourSplit — coral
        // measures 1.71:1 there and would be invisible.
        valueColor: simNet < 0 ? GaiaColors.coral : null,
        pending: !ran,
        detail: ran
            ? 'Revenue ${_simMoney(simFinite(sim['revenue']))}'
                ' · labour ${_simMoney(simFinite(sim['labour_cost']))}'
            : 'Nothing run yet — set the levers and press Run Simulation.',
      ),
    );
  }

  // ------------------------------------------------------------- levers ----

  /// The levers panel. Under Gaia this is `.bico` — the champagne slab.
  ///
  /// The BICOLOUR restyle changes the GROUND and the ink and nothing else.
  /// Every behaviour on this panel is untouched: the same picker, the same
  /// per-tenant defaults, the same change dots, the same
  /// remove-keeps-the-value contract, the same omit-inactive-levers POST. The
  /// only structural difference is that a card becomes a slab, because a slab
  /// is what an inverted ground is.
  Widget _leversCard(BuildContext context) {
    // Read OUTSIDE the panel: `Gaia.of` here decides whether to build the
    // panel at all, and inside it every Theme lookup is already re-inked.
    final bico = Gaia.of(context);
    // Active levers, grouped under the same category headers the picker uses
    // and in the same (alphabetical) order. A header appears ONLY when at least
    // one of its parameters is active.
    final groups = groupedParams(filter: (spec) => _active.contains(spec.key));
    final changed = _changedCount;

    Widget body(BuildContext context) {
      final text = Theme.of(context).textTheme;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (bico)
          const GaiaBicolourHeading(title: 'Levers')
        else
          const SectionHeader(title: 'What-If Simulator', padding: EdgeInsets.only(bottom: 4)),
        Text(
            'Pick the levers you want to test, adjust them, then run. Anything you'
            ' remove keeps its value and goes back to contributing your own default.'
            ' Nothing here writes to the live data.',
            style: text.bodySmall),
        const SizedBox(height: AppSpacing.md),

        // Wrap, not Row: at 320dp these two buttons do not share a line.
        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
          if (bico) ...[
            GaiaBicolourButton(
              key: _addButtonKey,
              label: 'Add a lever',
              icon: Icons.add,
              onPressed: _openPicker,
            ),
            GaiaBicolourButton(
              label: changed > 0 ? 'Reset values ($changed)' : 'Reset values',
              icon: Icons.restart_alt,
              onPressed: changed == 0 ? null : _resetAllValues,
            ),
          ] else ...[
            ForkButton.ghost(
              key: _addButtonKey,
              label: 'Add a lever',
              icon: Icons.add,
              dense: true,
              onPressed: _openPicker,
            ),
            ForkButton.subtle(
              label: changed > 0 ? 'Reset values ($changed)' : 'Reset values',
              icon: Icons.restart_alt,
              // Disabled with nothing to reset — and ForkButton makes a null
              // onPressed LOOK disabled, which is the point.
              onPressed: changed == 0 ? null : _resetAllValues,
            ),
          ],
        ]),
        const SizedBox(height: AppSpacing.md),

        if (groups.isEmpty)
          if (bico)
            // No inset panel on a slab — a recess inside an inverted ground
            // reads as a hole. A hairline box is the design's own answer.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(color: GaiaBicolourColors.line2),
              ),
              child: Text(
                  "Nothing active. Use '+ Add a lever' to pick what you want to test.",
                  style: text.bodySmall),
            )
          else
            ForkCard(
              inset: true,
              child: Text(
                  "Nothing active. Use '+ Add a lever' to pick what you want to test.",
                  style: text.bodySmall),
            )
        else
          SliderTheme(
            // The theme's copper primary already colours the active track; the
            // rest keeps the hairline voice of the design system. On the
            // champagne slab every one of these inverts — a copper thumb on
            // champagne is the invisible-control failure this file already got
            // bitten by once.
            data: SliderTheme.of(context).copyWith(
              inactiveTrackColor:
                  bico ? GaiaBicolourColors.line2 : AppColors.borderStrong,
              activeTrackColor: bico ? GaiaBicolourColors.ink : null,
              thumbColor: bico ? GaiaBicolourColors.ink : AppColors.copperHi,
              overlayColor: bico
                  ? GaiaColors.ink.withValues(alpha: 0.10)
                  : AppColors.copper.withValues(alpha: 0.12),
              trackHeight: 3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final g in groups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
                    child: Text(g.group.toUpperCase(), style: text.labelSmall),
                  ),
                  for (final spec in g.specs) _leverRow(context, spec),
                ],
              ],
            ),
          ),

        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (bico)
              GaiaBicolourButton(
                  label: 'Run Simulation',
                  icon: Icons.play_arrow,
                  primary: true,
                  dense: false,
                  onPressed: _running ? null : _run)
            else
              ForkButton(
                  label: 'Run Simulation',
                  icon: Icons.play_arrow,
                  onPressed: _running ? null : _run),
            if (_running)
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: bico ? GaiaBicolourColors.ink : null)),
            Text(
                _active.isEmpty
                    ? 'No levers active — this runs your baseline unchanged.'
                    : '${_active.length} lever${_active.length == 1 ? '' : 's'} in this run.',
                style: text.bodySmall),
          ],
        ),
      ]);
    }

    if (bico) {
      return GaiaBicolourPanel(child: Builder(builder: body));
    }
    return ForkCard(child: Builder(builder: body));
  }

  /// One active lever. Slider, segmented control and toggle all share this row:
  /// label + change-dot + per-lever reset on the left, the formatted value and
  /// the remove control on the right, the control under them, the explainer
  /// below that.
  Widget _leverRow(BuildContext context, ParamSpec spec) {
    final text = Theme.of(context).textTheme;
    final changed = isChanged(_values, _defaults, spec.key);
    final gate = spec.key == 'second_outlet' ? _secondOutletGate() : null;
    // On the champagne slab every accent ink flips. Copper on champagne is a
    // dead-looking control and amber on champagne measures 1.9:1 — the change
    // dot and the "speculative" chip would both simply stop existing, which on
    // this screen means an owner cannot see that a lever has been moved.
    final bico = GaiaBicolour.of(context);
    final accent = bico ? GaiaBicolourColors.ink : AppColors.copperHi;
    final warn = bico ? GaiaBicolourColors.statusWarn : AppColors.warning;
    final quiet = bico ? GaiaBicolourColors.body : AppColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(spec.label.toUpperCase(),
                    style: text.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (spec.speculative) ...[
                const SizedBox(width: 6),
                StatusChip(label: 'speculative', color: warn, dense: true),
              ],
              if (changed) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Changed from your default',
                  child: Container(
                    key: ValueKey('sim-dot-${spec.key}'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 2),
                // Visible ONLY when changed — the affordance is the signal.
                _LeverIconButton(
                  key: ValueKey('sim-reset-${spec.key}'),
                  icon: Icons.restart_alt,
                  tooltip: 'Reset ${spec.label} to your default',
                  onPressed: () => _resetLever(spec.key),
                ),
              ],
            ]),
          ),
          if (spec is NumberParam)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: Text(spec.format(numberValue(_values, spec.key), _simMoney),
                  // `.lever .h .v` is the SERIF figure on the slab — the one
                  // place the design puts a number in the display face inside
                  // a control row.
                  style: bico
                      ? GaiaType.serif(size: 26, weight: 500, color: GaiaBicolourColors.ink)
                      : text.titleSmall!.copyWith(color: AppColors.copperHi),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false),
            ),
          const SizedBox(width: 2),
          _LeverIconButton(
            key: ValueKey('sim-remove-${spec.key}'),
            icon: Icons.close,
            tooltip: 'Remove ${spec.label} (its value is kept)',
            onPressed: () => _removeLever(spec.key),
          ),
        ]),
        switch (spec) {
          NumberParam s => _numberControl(s),
          EnumParam s => _enumControl(s),
          ToggleParam s => _toggleControl(s, gate != null),
        },
        Text(spec.explainer, style: text.bodySmall),
        if (gate != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lock_outline, size: 13, color: warn),
              const SizedBox(width: 6),
              Expanded(child: Text(gate, style: text.bodySmall!.copyWith(color: quiet))),
            ]),
          ),
      ]),
    );
  }

  Widget _numberControl(NumberParam spec) {
    final domain = sliderDomain(spec, numberValue(_defaults, spec.key, spec.min));
    // The stored value is NEVER clamped into the catalogue range — an 18-table
    // room's neutral table_count is 18 even though the slider starts at 20, and
    // clamping it would silently simulate a different restaurant. The DOMAIN
    // widens instead, exactly as the backend's clampMeasured does.
    final value = numberValue(_values, spec.key, domain.min).clamp(domain.min, domain.max);
    final divisions = math.max(1, ((domain.max - domain.min) / spec.step).round());
    return Slider(
      key: ValueKey('sim-${spec.key}'),
      value: value.toDouble(),
      min: domain.min,
      max: domain.max,
      // Divisions so a drag lands on the lever's own step (₹500 of marketing,
      // 0.5% of food cost) rather than 13 decimal places of a pixel.
      divisions: divisions,
      onChanged: (v) => _setValue(spec.key, snapToStep(spec, domain, v)),
    );
  }

  /// The segmented control, built out of ForkButton rather than ForkTabs.
  ///
  /// ForkTabs is the design system's pill row, but it scrolls horizontally when
  /// it does not fit — and at 320dp inside this card the third option lands
  /// past the clip, so "Enterprise" is a segment you cannot see or press. A
  /// segmented control that hides a choice is the dead-looking control this app
  /// keeps being bitten by. A Wrap of the design system's own buttons keeps all
  /// three visible at every width, filled = selected (with a tick, because
  /// selection is never carried by colour alone).
  Widget _enumControl(EnumParam spec) {
    final selected = planTierValue(_values);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final o in spec.options)
            if (o.value == selected)
              ForkButton(
                key: ValueKey('sim-${spec.key}-${o.value}'),
                label: o.label,
                icon: Icons.check,
                dense: true,
                onPressed: () => _setValue(spec.key, o.value),
              )
            else
              ForkButton.ghost(
                key: ValueKey('sim-${spec.key}-${o.value}'),
                label: o.label,
                dense: true,
                onPressed: () => _setValue(spec.key, o.value),
              ),
        ],
      ),
    );
  }

  Widget _toggleControl(ToggleParam spec, bool gated) {
    final on = toggleValue(_values, spec.key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        // Gated means "cannot be switched ON" — never "cannot be switched off",
        // or an owner who enabled it and then dropped the plan would be stuck
        // with a lever they cannot undo.
        Switch(
          key: ValueKey('sim-${spec.key}'),
          value: on,
          onChanged: gated && !on ? null : (v) => _setValue(spec.key, v),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(on ? 'On' : 'Off', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  /// The second-outlet toggle is a PLAN capability: platform.plans grants
  /// multi-outlet to the Enterprise tier only. A plan_tier lever the user
  /// removed is resolved to "starter" by the server, so it stops granting it
  /// here too — otherwise the toggle would look enabled while the run silently
  /// refused it. Returns null when the plan allows it.
  String? _secondOutletGate() {
    if (allowsSecondOutlet(_active, _values)) return null;
    final tier = kPlanTiers[effectivePlanTier(_active, _values)]!.label;
    // A plan_tier lever that is not on screen cannot be "switched", so telling
    // the owner to switch it would be a dead end.
    final how = _active.contains('plan_tier')
        ? 'Switch the "Subscription plan" lever to Enterprise to model it.'
        : 'Add the "Subscription plan" lever and choose Enterprise to model it.';
    return toggleValue(_values, 'second_outlet')
        ? 'Switched on, but the $tier plan does not include multi-outlet — the run'
            ' will simulate a single outlet and say so. $how'
        : 'Multi-outlet is an Enterprise-plan capability. $how';
  }

  // ----------------------------------------------------------- baseline ----

  Widget _currentCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = widget.baseline;
    final sources = (b['sources'] as Map?) ?? {};
    // Honesty marker: a field the backend could not measure for this tenant
    // arrives flagged "default" and wears a small chip here, so an owner never
    // mistakes an industry placeholder for their own number.
    bool est(String k) => '${sources[k] ?? ''}' == 'default';
    final winDays = simFinite(b['window_days']);
    final days = winDays > 0 ? winDays.round() : 30;

    Widget row(String label, String value, String key) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label.toUpperCase(), style: text.labelSmall)),
            if (est(key)) ...[
              StatusChip(label: 'estimated', color: AppColors.warning, dense: true),
              const SizedBox(width: AppSpacing.sm),
            ],
            Text(value,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          ]),
        );

    return ForkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(
          title: 'Current Performance',
          padding: const EdgeInsets.only(bottom: 4),
          trailing: ForkIconButton(
              icon: Icons.refresh,
              tooltip: 'Reload the live baseline',
              onPressed: widget.reloadBaseline),
        ),
        // NO DateRangeChip on this screen, deliberately. Every other reporting
        // surface carries one, but GET /simulation/baseline takes no window at
        // all -- it is fixed at the backend's SIM_WINDOW_DAYS. A picker here
        // would let an owner select "1-15 Aug" and be shown a projection built
        // from the last 30 days regardless, which is a worse failure than having
        // no control: it looks answered. So the window is STATED, from the
        // server's own echo, and the screen says plainly that it is fixed.
        Text(
            'Live, from the last $days days -- a fixed window, unlike the other'
            ' reporting screens. All ₹ figures are pre-tax (bill subtotal), per day.',
            style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        row('Covers / day', _simNum(simFinite(b['covers_per_day'])), 'covers_per_day'),
        row('APC', _simMoney(simFinite(b['apc'])), 'apc'),
        row('Revenue / day', _simMoney(simFinite(b['revenue_per_day'])), 'revenue_per_day'),
        row('Food cost', '${_simNum(simFinite(b['food_cost_pct']))}%', 'food_cost_pct'),
        row('Labour / day', _simMoney(simFinite(b['labour_cost_per_day'])), 'labour_cost_per_day'),
        row('Staff on shift', _simNum(simFinite(b['staff_count'])), 'staff_count'),
        row('Avg turnaround', '${_simNum(simFinite(b['avg_tat_min']))} min', 'avg_tat_min'),
        row('Tables', _simNum(simFinite(b['table_count'])), 'table_count'),
        row('Fixed costs / day', _simMoney(simFinite(b['fixed_costs_per_day'])), 'fixed_costs_per_day'),
        row('Net profit / day', _simMoney(simFinite(b['net_profit_per_day'])), 'net_profit_per_day'),
      ]),
    );
  }

  // ------------------------------------------------------------ results ----

  static const List<_SimRow> _rows = [
    (key: 'covers', label: 'Covers / day', money: false, minutes: false, cost: false, neutral: false, optional: false),
    (key: 'apc', label: 'APC', money: true, minutes: false, cost: false, neutral: false, optional: false),
    (key: 'revenue', label: 'Revenue / day', money: true, minutes: false, cost: false, neutral: false, optional: false),
    (key: 'service_charge', label: 'Service charge / day', money: true, minutes: false, cost: false, neutral: false, optional: true),
    (key: 'revenue_deductions', label: 'Discounts & commission', money: true, minutes: false, cost: true, neutral: false, optional: true),
    (key: 'labour_cost', label: 'Labour / day', money: true, minutes: false, cost: true, neutral: false, optional: false),
    (key: 'food_cost', label: 'Food cost / day', money: true, minutes: false, cost: true, neutral: false, optional: false),
    (key: 'fixed_cost', label: 'Fixed costs / day', money: true, minutes: false, cost: true, neutral: false, optional: true),
    (key: 'marketing_per_day', label: 'Marketing / day', money: true, minutes: false, cost: true, neutral: false, optional: false),
    (key: 'net_profit', label: 'Net profit / day', money: true, minutes: false, cost: false, neutral: false, optional: false),
    (key: 'tat_min', label: 'Turnaround', money: false, minutes: true, cost: true, neutral: false, optional: false),
    // Display only — the model is pre-tax, so this never moves revenue or net
    // profit. Never coloured, because there is no good or bad direction.
    (key: 'tax_collected', label: 'Tax collected / day', money: true, minutes: false, cost: false, neutral: true, optional: true),
  ];

  List<Widget> _resultsSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_runError != null) {
      return [
        ForkCard(
          inset: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('The simulation could not run.', style: text.titleSmall),
            const SizedBox(height: 4),
            Text(_runError!, style: text.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            ForkButton.ghost(
                label: 'Try again',
                icon: Icons.refresh,
                dense: true,
                onPressed: _running ? null : _run),
          ]),
        ),
      ];
    }
    final res = _result;
    if (res == null) {
      return [
        ForkCard(
          inset: true,
          child: Text(
              'Projected impact appears here after a run — every major number as CURRENT | SIMULATED | DELTA.',
              style: text.bodySmall),
        ),
      ];
    }

    final cur = (res['current'] as Map?) ?? {};
    final sim = (res['simulated'] as Map?) ?? {};
    final del = (res['delta'] as Map?) ?? {};
    final notes = (res['notes'] as List?) ?? [];
    final warnings = (res['warnings'] as List?) ?? [];
    final be = res['breakeven_days'];
    final beDays = (be is num && be.isFinite && be > 0) ? be.round() : null;
    final ranSpend = simFinite(_ranWith?['marketing_spend']);

    // An optional row appears only when it carries a number in either column,
    // so a tenant who never touched discounts still sees the rows they know.
    final visible = _rows
        .where((r) =>
            !r.optional || simFinite(cur[r.key]) != 0 || simFinite(sim[r.key]) != 0)
        .toList();

    // A numeric cell never wraps and never throws: it fades if a value is
    // genuinely wider than a 320dp column can afford.
    Widget cell(String t, {TextStyle? style, TextAlign align = TextAlign.right}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(t,
              textAlign: align,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: style ??
                  TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
        );

    TableRow header() => TableRow(children: [
          cell('METRIC', style: text.labelSmall, align: TextAlign.left),
          cell('CURRENT', style: text.labelSmall),
          cell('SIMULATED', style: text.labelSmall),
          cell('DELTA', style: text.labelSmall),
        ]);

    /// One row's four figures and how the delta should be read. Shared by both
    /// design systems so the arithmetic and the good/bad judgement can never
    /// differ between them — only the drawing does.
    ({String cur, String sim, String delta, Color color, int rise}) cells(
        _SimRow r) {
      final c = simFinite(cur[r.key]);
      final s = simFinite(sim[r.key]);
      final d = simFinite(del[r.key]);
      String plain(num v) => r.money ? _simMoney(v) : (r.minutes ? '${_simNum(v)} min' : _simNum(v));
      // Judge the delta AFTER display rounding, so a hairline like 0.04 that
      // renders as 0 never wears a sign or a colour it did not earn.
      final num dr = r.money ? d.round() : double.parse(d.toStringAsFixed(1));
      final zero = dr == 0;
      // Green = good for the owner, red = bad; a rising cost or TAT inverts.
      final good = r.cost ? dr < 0 : dr > 0;
      final neutral = zero || r.neutral;
      return (
        cur: plain(c),
        sim: plain(s),
        delta: zero
            ? (r.money ? '₹0' : (r.minutes ? '0 min' : '0'))
            : '${dr > 0 ? '+' : ''}${plain(dr)}',
        color: neutral
            ? AppColors.textSecondary
            : (good ? AppColors.success : AppColors.danger),
        // The non-colour channel on the delta is the SIGN, not the verdict —
        // an arrow that pointed at good/bad would render a rising labour cost
        // as "down 6,150" beside a "+6,150". The verdict is the colour, and
        // the metric's own name (a cost, a turnaround) says which way is
        // welcome.
        rise: dr == 0 ? 0 : (dr > 0 ? 1 : -1),
      );
    }

    TableRow row(_SimRow r) {
      final v = cells(r);
      return TableRow(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(r.label, style: text.bodySmall!.copyWith(color: AppColors.textSecondary)),
        ),
        cell(v.cur),
        cell(v.sim),
        cell(v.delta,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: v.color)),
      ]);
    }

    return [
      const SectionHeader(title: 'Projected impact'),
      ForkCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Loud caveats first — the speculative second-outlet model announces
          // itself here, above the numbers it produced.
          if (warnings.isNotEmpty) ...[
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warning),
                  const SizedBox(width: 7),
                  Expanded(child: Text('$w', style: text.bodySmall)),
                ]),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
          // `.delta-row` — the same four columns, the same rows, the same
          // visibility rule and the same good/bad judgement; only the drawing
          // changes. The SIMULATED column goes serif, which is what makes four
          // numeric columns scannable without a rule between them.
          if (Gaia.of(context))
            Column(children: [
              const GaiaDeltaRow(
                first: true,
                header: true,
                metric: 'Metric',
                current: 'Current',
                scenario: 'Scenario',
                delta: 'Delta',
              ),
              for (final r in visible)
                Builder(builder: (context) {
                  final v = cells(r);
                  return GaiaDeltaRow(
                    metric: r.label,
                    current: v.cur,
                    scenario: v.sim,
                    delta: v.delta,
                    deltaColor: v.color,
                    rise: v.rise,
                  );
                }),
            ])
          else
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.5),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1.1),
                3: FlexColumnWidth(1.1),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [header(), ...visible.map(row)],
            ),
          if (ranSpend > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            if (beDays != null)
              StatusChip(
                  label: 'Marketing pays back in ~$beDays day${beDays == 1 ? '' : 's'}',
                  color: AppColors.info)
            else
              Text(
                  'The one-time ${_simMoney(ranSpend)} spend never breaks even under these'
                  ' settings — there is no daily profit uplift to pay it back.',
                  style: text.bodySmall),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(height: 1, color: AppColors.divider),
            const SizedBox(height: AppSpacing.md),
            // The model explains itself: one line per effect it applied.
            ...notes.map((n) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                        width: 2.5,
                        height: 11,
                        margin: const EdgeInsets.only(top: 3),
                        decoration: BoxDecoration(
                            color: AppColors.copperHi, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 8),
                    Expanded(child: Text('$n', style: text.bodySmall)),
                  ]),
                )),
          ],
        ]),
      ),
    ];
  }
}

// ---------------------------------------------------------------- picker ----

/// The searchable, category-grouped checklist of all 34 parameters.
///
/// One widget for both presentations (bottom sheet on a phone, anchored popover
/// on desktop) so the two cannot drift apart. It keeps its own copy of the
/// active set for the checkmarks and reports every change up immediately, so the
/// list behind it grows and shrinks while the panel stays open.
class _LeverPickerPanel extends StatefulWidget {
  const _LeverPickerPanel({
    required this.active,
    required this.onToggle,
    required this.autofocusSearch,
  });

  final Set<String> active;
  final void Function(String key) onToggle;
  final bool autofocusSearch;

  @override
  State<_LeverPickerPanel> createState() => _LeverPickerPanelState();
}

class _LeverPickerPanelState extends State<_LeverPickerPanel> {
  String _query = '';
  late final Set<String> _local = {...widget.active};

  void _toggle(String key) {
    setState(() {
      if (!_local.remove(key)) _local.add(key);
    });
    widget.onToggle(key);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final query = _query;
    // Search filters the FULL catalogue, not one category; a category with
    // nothing left drops out rather than rendering an empty header.
    final groups = groupedParams(query: query);

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
        child: AppSearchField(
          testId: 'sim-pick-search',
          hint: 'Search parameters…',
          autofocus: widget.autofocusSearch,
          onQuery: (q) => setState(() => _query = q),
        ),
      ),
      Flexible(
        child: groups.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('No parameter matches "$query".',
                    style: text.bodySmall, textAlign: TextAlign.center),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                children: [
                  for (final g in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 2),
                      child: Text(g.group.toUpperCase(), style: text.labelSmall),
                    ),
                    for (final spec in g.specs)
                      _PickerRow(
                        key: ValueKey('sim-pick-${spec.key}'),
                        spec: spec,
                        checked: _local.contains(spec.key),
                        onTap: () => _toggle(spec.key),
                      ),
                  ],
                ],
              ),
      ),
      Container(height: 1, color: AppColors.divider),
      Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
            '${_local.length} of ${kParamCatalog.length} levers active · removed levers'
            ' keep their value and contribute your default.',
            style: text.bodySmall),
      ),
    ]);
  }
}

/// One checkable parameter. The WHOLE row is the target — a 34-row list where
/// only the 18px box works is a list people tap twice.
class _PickerRow extends StatefulWidget {
  const _PickerRow({super.key, required this.spec, required this.checked, required this.onTap});

  final ParamSpec spec;
  final bool checked;
  final VoidCallback onTap;

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          color: _hovered ? Colors.white.withValues(alpha: 0.04) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
          child: Row(children: [
            // The checkbox shares the row's tap target rather than owning one of
            // its own, so a tap on the label and a tap on the box do the same
            // thing and neither can get out of step with the other.
            IgnorePointer(
              child: Checkbox(
                value: widget.checked,
                onChanged: (_) {},
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(widget.spec.label,
                  style: text.bodyMedium!.copyWith(
                      color: widget.checked ? AppColors.textPrimary : AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (widget.spec.speculative) ...[
              const SizedBox(width: 6),
              StatusChip(label: 'speculative', color: AppColors.warning, dense: true),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A 26px icon button in [ForkIconButton]'s voice.
///
/// The real one is 34px with a permanent hairline border, and two of those on
/// every one of 34 lever rows is a wall of boxes that also eats the label's
/// width on a 320dp phone. Same colours, same hover, same durations — no new
/// palette — just smaller and border-on-hover.
class _LeverIconButton extends StatefulWidget {
  const _LeverIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_LeverIconButton> createState() => _LeverIconButtonState();
}

class _LeverIconButtonState extends State<_LeverIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Two of these ride every changed lever row, and on the champagne slab
    // their copper-on-dark inks read as blank space.
    final bico = GaiaBicolour.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppDurations.fast,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hovered
                  ? (bico
                      ? GaiaColors.ink.withValues(alpha: 0.07)
                      : Colors.white.withValues(alpha: 0.06))
                  : Colors.transparent,
              borderRadius: AppRadius.controlAll,
              border: Border.all(
                  color: _hovered
                      ? (bico ? GaiaBicolourColors.line2 : AppColors.borderStrong)
                      : Colors.transparent),
            ),
            child: Icon(widget.icon,
                size: 14,
                color: bico
                    ? (_hovered ? GaiaBicolourColors.ink : GaiaBicolourColors.body)
                    : (_hovered ? AppColors.textPrimary : AppColors.textSecondary)),
          ),
        ),
      ),
    );
  }
}
