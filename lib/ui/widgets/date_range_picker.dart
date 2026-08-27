import 'package:flutter/material.dart';

import '../../services/date_range.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// THE date-range control. One widget, mounted on every reporting surface:
/// Analytics, Accounting, History, Cash. Not one picker per module — the point
/// of the exercise is that the window means the same thing wherever you read it,
/// and four pickers built four times would drift apart the way the ad-hoc period
/// tabs this replaces already had.
///
/// WHAT IT IS
/// ----------
/// A chip that ALWAYS reads the chosen window ("1–15 Aug"), and opens a sheet
/// holding the six presets plus a calendar. The chip is not decoration: a
/// filtered money figure sitting next to a control that does not say what it
/// filtered to is how an owner reads a fortnight's takings as the month's.
///
/// PRESETS FIRST, CALENDAR SECOND
/// ------------------------------
/// "Today" and "Last 7 days" are what an owner opens the app for; those are one
/// tap, at the top of the sheet where the thumb already is. The calendar is for
/// the rest — "1–15 August" is a question nothing but a calendar answers
/// comfortably.
///
/// SELECTING A SPAN: TAP-START / TAP-END, NOT DRAG
/// ----------------------------------------------
/// This is a deliberate choice and it is the same one the web control lands on
/// for touch. A finger drag across a calendar grid is ambiguous — the framework
/// cannot know whether the gesture means "select these days" or "scroll this
/// sheet" — and resolving it in favour of selection would break scrolling the
/// sheet on a 320dp phone, which is the exact device this has to work on.
/// Flutter's own [showDateRangePicker] is used rather than a hand-rolled grid:
/// two taps, full-screen on a phone so the cells are thumb-sized, keyboard entry
/// for the owner who would rather type, and semantics/locale handling that a
/// bespoke grid would have to re-earn. The app's own theme is pushed into it, so
/// it does not arrive looking like a different product.
class DateRangeChip extends StatelessWidget {
  const DateRangeChip({
    super.key,
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  final DateRange value;
  final ValueChanged<DateRange> onChanged;

  /// Tighter padding for a card header, where the chip sits beside a title.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: value.tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          onTap: () => _open(context),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? AppSpacing.md : AppSpacing.lg,
              vertical: dense ? 6 : AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: AppColors.inset,
              borderRadius: BorderRadius.circular(AppRadius.chip),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.date_range, size: dense ? 14 : 16, color: AppColors.copper),
              const SizedBox(width: AppSpacing.sm),
              // ONE Flexible text span, not a row of separate Texts. The preset
              // name is the nicety and the dates are the fact, so they share a
              // single ellipsising line: on a 320dp phone at 1.3x the name
              // truncates and the days survive, where two rigid Texts side by
              // side would overflow the chip by a hair and take the whole
              // screen's layout with them.
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    if (!dense && value.preset != RangePreset.custom)
                      TextSpan(text: '${presetLabel(value.preset)}  ·  ', style: text.bodySmall),
                    TextSpan(
                      text: value.label(),
                      style: (dense ? text.bodySmall : text.bodyMedium)
                          ?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.expand_more, size: dense ? 14 : 16, color: AppColors.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<DateRange>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _RangeSheet(value: value),
    );
    if (picked != null) onChanged(picked);
  }
}

class _RangeSheet extends StatelessWidget {
  const _RangeSheet({required this.value});

  final DateRange value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: Container(
        // Capped so the sheet never swallows the screen it is filtering; the
        // preset list is short enough that it does not need to.
        constraints: BoxConstraints(maxHeight: media.size.height * 0.8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.borderStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Period', style: text.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              // States the zone: "1st to 15th" is meaningless to an accountant
              // without knowing whose midnight closed each day.
              'Showing ${value.label()} · ${value.days} day${value.days == 1 ? '' : 's'} · '
              'counted on the restaurant\'s calendar',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final p in kRangePresets)
                  _PresetPill(
                    label: presetLabel(p),
                    active: value.preset == p,
                    onTap: () => Navigator.of(context).pop(DateRange.fromPreset(p)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(height: 1, color: AppColors.divider),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: _CalendarButton(value: value),
            ),
          ]),
        ),
      ),
    );
  }
}

class _CalendarButton extends StatelessWidget {
  const _CalendarButton({required this.value});

  final DateRange value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppRadius.controlAll,
        onTap: () => _pickDates(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: AppRadius.controlAll,
            border: Border.all(color: AppColors.borderStrong),
          ),
          child: Row(children: [
            Icon(Icons.calendar_month_outlined, size: 18, color: AppColors.copper),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pick dates on a calendar',
                    style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('Tap the first day, then the last.', style: text.bodySmall),
              ]),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }

  Future<void> _pickDates(BuildContext context) async {
    final navigator = Navigator.of(context);
    // The calendar's own DateTimes are plain local field-carriers: it is drawing
    // a picture of a calendar, not naming instants. They are converted straight
    // back to day keys, never through UTC — `toIso8601String()` on a local
    // midnight would name the previous day for any device west of Greenwich.
    final firstKey = value.from;
    final f = _dateOf(firstKey);
    final t = _dateOf(value.to);
    final today = _dateOf(todayKey())!;

    final picked = await showDateRangePicker(
      context: context,
      // Ten years back is past any tenant's data; the future is not selectable
      // at all, because there is no trade tomorrow and a future window comes
      // back as zeros that read like data loss.
      firstDate: DateTime(today.year - 10),
      lastDate: today,
      currentDate: today,
      initialDateRange: (f != null && t != null && !f.isAfter(t))
          ? DateTimeRange(start: f, end: t)
          : null,
      helpText: 'Select a period',
      saveText: 'Apply',
      builder: (ctx, child) => Theme(
        // The picker is Material's, so it is handed the app's own scheme rather
        // than arriving in default Material colours mid-flow.
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
                primary: AppColors.copper,
                onPrimary: AppColors.onCopper,
                surface: AppColors.card,
                onSurface: AppColors.textPrimary,
              ),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null) return;
    navigator.pop(DateRange.normalized(
      _keyOfDate(picked.start),
      _keyOfDate(picked.end),
    ));
  }

  static DateTime? _dateOf(String key) {
    if (!isDayKey(key)) return null;
    final p = key.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  static String _keyOfDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
}

class _PresetPill extends StatelessWidget {
  const _PresetPill({required this.label, required this.active, required this.onTap});

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

/// The always-visible statement of what a figure was cut on, for use INSIDE a
/// card — under a title, beside a total, in a chart caption.
///
/// The chip already says it once at the top of the module, but a reporting
/// screen scrolls, and a number without its window is exactly the misreading
/// this feature exists to prevent. Cheap enough to put on every money section,
/// so it is.
class RangeNote extends StatelessWidget {
  const RangeNote({super.key, required this.range, this.prefix = 'Showing'});

  final DateRange range;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: range.tooltip,
      child: Text(
        '$prefix ${range.label()}',
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
