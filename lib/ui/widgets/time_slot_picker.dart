import 'package:flutter/material.dart';

import '../../services/time_slot.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'fork_button.dart';

/// What saving the session list came to: the list the server now holds, or the
/// sentence to show inline (the server's own 400 wording when it wrote one).
typedef TimeSlotSaveOutcome = ({TimeSlotCatalogue? saved, String? error});

/// WHICH PART OF THE DAY — the session chip beside [DateRangeChip] on Reports.
///
/// Two jobs, kept visibly apart:
///   * PICKING is for anyone who can read the report: All day, one of the saved
///     sessions, or custom times. A slot filters data the reader could already
///     see across the whole day, so it needs no permission of its own.
///   * MANAGING the saved list is behind [canEdit] — the server's answer to
///     "does this caller hold the settings permission" — and for everyone else
///     the entry is simply absent rather than present and refused.
///
/// THE CHIP ALWAYS SAYS WHAT IS PICKED ("Dinner · 18:00–24:00"), for the same
/// reason the date chip does: a filtered figure beside a control that does not
/// say what it filtered to is how an evening's takings get read as a day's.
///
/// Every rule and every sentence lives in services/time_slot.dart, shared word
/// for word with the web dashboard; this file is layout and state.
class TimeSlotChip extends StatelessWidget {
  const TimeSlotChip({
    super.key,
    required this.value,
    required this.presets,
    required this.canEdit,
    required this.onChanged,
    required this.onSave,
  });

  final TimeSlotSelection value;
  final List<TimeSlotPreset> presets;
  final bool canEdit;
  final ValueChanged<TimeSlotSelection> onChanged;

  /// PUT the whole list (an empty list restores the defaults).
  final Future<TimeSlotSaveOutcome> Function(List<TimeSlotDraft> drafts) onSave;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final filtered = !value.isAllDay;
    return Tooltip(
      message: 'The part of each day this report counts, in restaurant time',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          onTap: () => _open(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
            decoration: BoxDecoration(
              color: filtered ? AppColors.copper.withValues(alpha: 0.14) : AppColors.inset,
              borderRadius: BorderRadius.circular(AppRadius.chip),
              border: Border.all(color: filtered ? AppColors.copper : AppColors.borderStrong),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.access_time, size: 14, color: AppColors.copper),
              const SizedBox(width: AppSpacing.sm),
              // Flexible + ellipsis: a long session name on a 320dp phone gives
              // up its tail, never the layout.
              Flexible(
                child: Text(
                  value.label(presets),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.expand_more, size: 14, color: AppColors.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SlotSheet(value: value, presets: presets, canEdit: canEdit),
    );
    if (picked is TimeSlotSelection) {
      onChanged(picked);
    } else if (picked == _manage && context.mounted) {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => _ManageSessionsSheet(presets: presets, onSave: onSave),
      );
    }
  }
}

/// The sheet's "open the editor" answer — distinct from any selection.
const Object _manage = Object();

Widget _sheetFrame(BuildContext context, List<Widget> children) {
  final media = MediaQuery.of(context);
  return Padding(
    // Lifts the sheet over the keyboard, so the time being typed stays visible.
    padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
    child: SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                decoration: BoxDecoration(color: AppColors.borderStrong, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            ...children,
          ]),
        ),
      ),
    ),
  );
}

InputDecoration _timeField(String hint) => InputDecoration(
      isDense: true,
      hintText: hint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(borderRadius: AppRadius.inputAll),
    );

class _SlotSheet extends StatefulWidget {
  const _SlotSheet({required this.value, required this.presets, required this.canEdit});

  final TimeSlotSelection value;
  final List<TimeSlotPreset> presets;
  final bool canEdit;

  @override
  State<_SlotSheet> createState() => _SlotSheetState();
}

class _SlotSheetState extends State<_SlotSheet> {
  late bool _customOpen = widget.value.kind == TimeSlotKind.custom;
  late final TextEditingController _from = TextEditingController(text: widget.value.from);
  late final TextEditingController _to = TextEditingController(text: widget.value.to);
  String? _error;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    final problem = validateCustomSlot(_from.text, _to.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(TimeSlotSelection.custom(_from.text, _to.text));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final v = widget.value;
    return _sheetFrame(context, [
      Text('Session', style: text.titleMedium),
      const SizedBox(height: AppSpacing.xs),
      Text('Restaurant time, on each day of the range.', style: text.bodySmall),
      const SizedBox(height: AppSpacing.lg),
      Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
        _Pill(
          key: const ValueKey('slot-option-all'),
          label: 'All day',
          active: v.isAllDay,
          onTap: () => Navigator.of(context).pop(TimeSlotSelection.allDay),
        ),
        for (final p in widget.presets)
          _Pill(
            key: ValueKey('slot-option-${p.id}'),
            label: p.optionLabel,
            active: v.kind == TimeSlotKind.preset && v.id == p.id,
            onTap: () => Navigator.of(context).pop(TimeSlotSelection.preset(p.id)),
          ),
        _Pill(
          key: const ValueKey('slot-option-custom'),
          label: 'Custom…',
          active: v.kind == TimeSlotKind.custom,
          onTap: () => setState(() => _customOpen = !_customOpen),
        ),
      ]),
      if (_customOpen) ...[
        const SizedBox(height: AppSpacing.lg),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              key: const ValueKey('slot-custom-from'),
              controller: _from,
              keyboardType: TextInputType.datetime,
              maxLength: 5,
              onChanged: (_) => setState(() => _error = null),
              decoration: _timeField('From HH:mm').copyWith(counterText: ''),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              key: const ValueKey('slot-custom-to'),
              controller: _to,
              keyboardType: TextInputType.datetime,
              maxLength: 5,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _apply(),
              decoration: _timeField('To HH:mm').copyWith(counterText: ''),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          ForkButton(key: const ValueKey('slot-custom-apply'), label: 'Apply', dense: true, onPressed: _apply),
        ]),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _error ??
              (crossesMidnight(_from.text, _to.text)
                  ? 'Crosses midnight — each night is counted on the day it starts.'
                  : '24-hour times. The end may be 24:00.'),
          key: const ValueKey('slot-custom-hint'),
          style: text.bodySmall?.copyWith(color: _error == null ? null : AppColors.danger),
        ),
      ],
      if (widget.canEdit) ...[
        const SizedBox(height: AppSpacing.lg),
        Container(height: 1, color: AppColors.divider),
        const SizedBox(height: AppSpacing.sm),
        ListTile(
          key: const ValueKey('slot-manage'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(Icons.tune, size: 18, color: AppColors.copper),
          title: const Text('Manage sessions…'),
          onTap: () => Navigator.of(context).pop(_manage),
        ),
      ],
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: active ? AppColors.copper : AppColors.inset,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(color: active ? AppColors.copper : AppColors.borderStrong),
          ),
          child: Text(
            label,
            style: text.bodySmall?.copyWith(
              color: active ? AppColors.onCopper : AppColors.textPrimary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// The restaurant's list, edited as a whole and saved as a whole — the route
/// replaces the list, so the sheet never pretends one row was saved on its own.
/// The server judges overlaps; its sentence is shown here, verbatim.
class _ManageSessionsSheet extends StatefulWidget {
  const _ManageSessionsSheet({required this.presets, required this.onSave});

  final List<TimeSlotPreset> presets;
  final Future<TimeSlotSaveOutcome> Function(List<TimeSlotDraft> drafts) onSave;

  @override
  State<_ManageSessionsSheet> createState() => _ManageSessionsSheetState();
}

class _Row {
  _Row({this.id, String label = '', String start = '', String end = ''})
      : name = TextEditingController(text: label),
        start = TextEditingController(text: start),
        end = TextEditingController(text: end);

  final String? id;
  final TextEditingController name;
  final TextEditingController start;
  final TextEditingController end;

  TimeSlotDraft get draft => TimeSlotDraft(id: id, label: name.text, start: start.text, end: end.text);

  void dispose() {
    name.dispose();
    start.dispose();
    end.dispose();
  }
}

class _ManageSessionsSheetState extends State<_ManageSessionsSheet> {
  late final List<_Row> _rows = [
    for (final p in widget.presets) _Row(id: p.id, label: p.label, start: p.start, end: p.end),
  ];
  String? _error;
  bool _saving = false;
  bool _confirmReset = false;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _submit(List<TimeSlotDraft> drafts) async {
    final problem = validateSlotDrafts(drafts);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await widget.onSave(drafts);
    if (!mounted) return;
    if (outcome.saved == null) {
      setState(() {
        _saving = false;
        _error = outcome.error ?? 'Could not save the sessions.';
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _sheetFrame(context, [
      Text('Manage sessions', style: text.titleMedium),
      const SizedBox(height: AppSpacing.xs),
      Text(
        'Saved for the whole restaurant. Everyone who reads reports can pick these; only people who can '
        'change settings can edit them. 24-hour times; an end may be 24:00, and an end before the start '
        'runs past midnight.',
        style: text.bodySmall,
      ),
      const SizedBox(height: AppSpacing.lg),
      for (var i = 0; i < _rows.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(children: [
            Expanded(
              flex: 5,
              child: TextField(
                key: ValueKey('slot-edit-name-$i'),
                controller: _rows[i].name,
                maxLength: kMaxTimeSlotLabel,
                onChanged: (_) => setState(() => _error = null),
                decoration: _timeField('Name').copyWith(counterText: ''),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              flex: 3,
              child: TextField(
                key: ValueKey('slot-edit-start-$i'),
                controller: _rows[i].start,
                keyboardType: TextInputType.datetime,
                maxLength: 5,
                onChanged: (_) => setState(() => _error = null),
                decoration: _timeField('HH:mm').copyWith(counterText: ''),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              flex: 3,
              child: TextField(
                key: ValueKey('slot-edit-end-$i'),
                controller: _rows[i].end,
                keyboardType: TextInputType.datetime,
                maxLength: 5,
                onChanged: (_) => setState(() => _error = null),
                decoration: _timeField('HH:mm').copyWith(counterText: ''),
              ),
            ),
            IconButton(
              key: ValueKey('slot-edit-remove-$i'),
              tooltip: 'Remove',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _rows.removeAt(i).dispose();
                        _error = null;
                      }),
            ),
          ]),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: ForkButton.ghost(
          key: const ValueKey('slot-edit-add'),
          label: _rows.length >= kMaxTimeSlots ? 'At most $kMaxTimeSlots sessions' : 'Add session',
          icon: Icons.add,
          dense: true,
          onPressed: _saving || _rows.length >= kMaxTimeSlots
              ? null
              : () => setState(() {
                    _rows.add(_Row());
                    _error = null;
                  }),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpacing.md),
        Text(_error!, key: const ValueKey('slot-edit-error'), style: text.bodySmall?.copyWith(color: AppColors.danger)),
      ],
      const SizedBox(height: AppSpacing.lg),
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          if (_confirmReset) ...[
            Text('Replace these with Lunch and Dinner?', style: text.bodySmall),
            ForkButton(
              key: const ValueKey('slot-edit-reset-confirm'),
              label: 'Reset',
              dense: true,
              onPressed: _saving ? null : () => _submit(const []),
            ),
            ForkButton.ghost(
              label: 'Keep',
              dense: true,
              onPressed: _saving ? null : () => setState(() => _confirmReset = false),
            ),
          ] else
            ForkButton.ghost(
              key: const ValueKey('slot-edit-reset'),
              label: 'Reset to defaults',
              dense: true,
              onPressed: _saving ? null : () => setState(() => _confirmReset = true),
            ),
          ForkButton(
            key: const ValueKey('slot-edit-save'),
            label: _saving ? 'Saving…' : 'Save sessions',
            dense: true,
            onPressed: _saving ? null : () => _submit([for (final r in _rows) r.draft]),
          ),
        ],
      ),
    ]);
  }
}
