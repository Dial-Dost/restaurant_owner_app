import 'package:flutter/material.dart';

import '../models/floor_state.dart';
import '../ui/gaia/gaia.dart';
import '../ui/theme/app_colors.dart';
import '../ui/widgets/status_chip.dart';

/// CLIENT ITEMS 1 AND 2 — THE FLOOR'S COLOURS, DRAWN.
///
/// The five states of [FloorState] in the scheme's fixed floor inks
/// (AppShellScheme.floorFree …), never the accent. See models/floor_state.dart
/// for what each state means.

/// The ink a state is painted in, on the scheme in force.
Color floorInk(FloorState state) => switch (state) {
      FloorState.free => AppColors.floorFree,
      FloorState.seated => AppColors.floorSeated,
      FloorState.running => AppColors.floorRunning,
      FloorState.printed => AppColors.floorPrinted,
      FloorState.reserved => AppColors.floorReserved,
    };

/// How strongly a table tile is washed with its state's ink, composited over
/// AppColors.card. Printed and running are the states the floor is scanned for;
/// free is the faintest, so twenty green tables do not shout over one orange.
/// test/light_theme_test.dart holds the body inks to 4.5:1 on these washes.
double floorWash(FloorState state) => switch (state) {
      FloorState.running || FloorState.printed => 0.18,
      FloorState.seated => 0.16,
      FloorState.reserved => 0.13,
      FloorState.free => 0.10,
    };

/// A floor chip: the ink on an OPAQUE card-coloured pill.
///
/// NOT A [StatusChip]. A status chip is a 12% tint of its ink, and on a tile
/// that is already washed in the same ink the label drops to about 3.8:1
/// (Gaia's coral, measured). Ink on the card itself is at least 4.99:1 on every
/// scheme, which is the pairing test/waiter_floor_printed_test.dart pins. Under
/// Gaia it keeps that system's engraved, upper-case, square-edged pill.
class FloorChip extends StatelessWidget {
  const FloorChip({
    super.key,
    required this.label,
    required this.color,
    this.dense = true,
    this.tooltip,
    this.maxLines = 1,
  });

  final String label;
  final Color color;
  final bool dense;

  /// 1 for a state (it ellipsises, like every chip — see [ChipLabel]); 2 for a
  /// sentence that must not lose its end, "Updated — print again" in Gaia's
  /// tracked upper case on a phone-width tile.
  final int maxLines;

  /// Spoken and shown on hover — the "#2" chip says "Next party" here.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final gaia = Gaia.of(context);
    final shown = gaia ? label.toUpperCase() : label;
    final style = gaia
        ? GaiaType.pill(color: color)
        : TextStyle(
            fontSize: dense ? 10.5 : 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: color,
          );
    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: gaia ? GaiaRadius.all : BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: dense ? 5 : 6,
          height: dense ? 5 : 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: dense ? 5 : 6),
        if (maxLines <= 1)
          ChipLabel(shown, style: style)
        else
          Flexible(child: Text(shown, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis)),
      ]),
    );
    final tip = tooltip;
    if (tip == null) return chip;
    return Tooltip(message: tip, child: Semantics(label: tip, child: chip));
  }
}

/// A state's chip, in its own words and ink.
class FloorStateChip extends StatelessWidget {
  const FloorStateChip({super.key, required this.state, this.dense = true});

  final FloorState state;
  final bool dense;

  @override
  Widget build(BuildContext context) => FloorChip(label: state.word, color: floorInk(state), dense: dense);
}

/// THE WAITER'S COLOUR KEY — the five states, no counts. A waiter has no
/// floor-summary strip ([FloorScope.floorSummary]): "23 Free" is a fact about
/// the restaurant. What colour means what is a fact about the tiles in front of
/// them.
class FloorColourKey extends StatelessWidget {
  const FloorColourKey({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Wrap(
      key: const ValueKey('floor-colour-key'),
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final row in floorLegend(const [], withCounts: false))
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: floorInk(row.state), shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(row.label, style: text.bodySmall!.copyWith(fontSize: 11.5, color: AppColors.textSecondary)),
          ]),
      ],
    );
  }
}

/// "ONLY THE PRINTED TABLES" — the owner's night-settle backlog, one tap on the
/// "N Bill printed" legend chip away. Held above the Tables screen's tiles and
/// read by the floor sections, so the chip and the grid cannot disagree.
class PrintedBacklogFilter extends StatefulWidget {
  const PrintedBacklogFilter({super.key, required this.child});

  final Widget child;

  /// The filter in force above [context], or null when there is none (the
  /// Floor plan, a test that mounts the sections alone).
  static ValueNotifier<bool>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PrintedBacklogScope>()?.notifier;

  @override
  State<PrintedBacklogFilter> createState() => _PrintedBacklogFilterState();
}

class _PrintedBacklogFilterState extends State<PrintedBacklogFilter> {
  final ValueNotifier<bool> _only = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _only.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PrintedBacklogScope(notifier: _only, child: widget.child);
}

class _PrintedBacklogScope extends InheritedNotifier<ValueNotifier<bool>> {
  const _PrintedBacklogScope({required super.notifier, required super.child});
}

/// One counted legend chip. The printed one is a toggle for [PrintedBacklogFilter].
class FloorLegendChip extends StatelessWidget {
  const FloorLegendChip({super.key, required this.state, required this.label});

  final FloorState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    final chip = FloorChip(label: label, color: floorInk(state));
    final filter = state == FloorState.printed ? PrintedBacklogFilter.maybeOf(context) : null;
    if (filter == null) return chip;
    final on = filter.value;
    return Semantics(
      button: true,
      toggled: on,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => filter.value = !filter.value,
        child: Tooltip(
          message: on ? 'Showing only printed tables — tap to show all' : 'Show only printed tables',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            chip,
            if (on) ...[
              const SizedBox(width: 4),
              Icon(Icons.filter_alt, size: 14, color: floorInk(state)),
            ],
          ]),
        ),
      ),
    );
  }
}
