import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/charts.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';

/// Covers the two things `dart analyze` cannot: that a chart survives real data
/// shapes, and that the Orders/Bookings tiles actually lay out in the grid.
Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SizedBox(width: 900, child: child)),
    );

void main() {
  group('chart series that used to crash', () {
    // A restaurant with no trade yet sends an all-zero series. The old code did
    // `value / values.reduce(max)` -> 0/0 -> NaN, and a NaN height is a hard
    // layout error, not a cosmetic one. This is a regression test, not a
    // hypothetical: the division is still there, only the divisor is guarded.
    testWidgets('WeekdayBars renders an all-zero series', (tester) async {
      await tester.pumpWidget(_host(
        const WeekdayBars(values: [0, 0, 0, 0, 0, 0, 0]),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('CopperColumns renders an all-zero series', (tester) async {
      await tester.pumpWidget(_host(
        const CopperColumns(
          values: [0, 0, 0, 0, 0],
          labels: ['a', 'b', 'c', 'd', 'e'],
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty series renders nothing rather than throwing', (tester) async {
      await tester.pumpWidget(_host(
        const CopperColumns(values: [], labels: []),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('charts answer the pointer', () {
    testWidgets('tapping a column reports its index', (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(_host(
        CopperColumns(
          values: const [4, 9, 2],
          labels: const ['Mon', 'Tue', 'Wed'],
          onTap: taps.add,
        ),
      ));
      await tester.tap(find.text('Tue'));
      await tester.pump();
      expect(taps, [1]);
    });

    testWidgets('tapping a bar row fires its callback', (tester) async {
      var hits = 0;
      await tester.pumpWidget(_host(
        HBarRow(label: 'Paneer Tikka', fraction: 0.6, value: '120', onTap: () => hits++),
      ));
      await tester.tap(find.text('Paneer Tikka'));
      await tester.pump();
      expect(hits, 1);
    });

    testWidgets('a chart with no onTap stays inert', (tester) async {
      await tester.pumpWidget(_host(
        const CopperColumns(values: [1, 2], labels: ['a', 'b']),
      ));
      // Nothing to assert beyond "does not blow up when tapped" -- the point is
      // that an inert chart must not pretend to be a control.
      await tester.tap(find.text('a'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    // BUG 19: _ChartHitBox wired MouseRegion.onEnter/onExit regardless of
    // interactivity, so the Overview revenue drill-down -- which passes neither
    // onTap nor tooltipBuilder -- lifted its bars under the pointer and promised
    // a drill-down that does not exist.
    testWidgets('an inert chart does not move under the pointer', (tester) async {
      await tester.pumpWidget(_host(const WeekdayBars(
        values: [4200, 5100, 3900, 6200, 7350, 9800, 8600],
        highlight: 6,
      )));
      await tester.pumpAndSettle();

      // Index 5 is the tallest bar, so it is the one with no headroom left.
      final tallest = find.byType(AnimatedContainer).at(5);
      final atRest = tester.getSize(tallest).height;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());
      await mouse.moveTo(tester.getCenter(tallest));
      await tester.pumpAndSettle();

      expect(tester.getSize(tallest).height, atRest);
      expect(tester.takeException(), isNull);
    });

    // BUG 19: the hover lift used to be ADDED to a bar already sized to fill the
    // whole 56px box, so hovering overflowed the Column and clipped the label.
    testWidgets('a hovered bar stays inside its fixed height box', (tester) async {
      await tester.pumpWidget(_host(WeekdayBars(
        values: const [4200, 5100, 3900, 6200, 7350, 9800, 8600],
        highlight: 6,
        onTap: (_) {},
      )));
      await tester.pumpAndSettle();

      final tallest = find.byType(AnimatedContainer).at(5);
      final atRest = tester.getSize(tallest).height;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() => mouse.removePointer());
      await mouse.moveTo(tester.getCenter(tallest));
      await tester.pumpAndSettle();

      // The lift must have happened -- otherwise this proves nothing.
      expect(tester.getSize(tallest).height, greaterThan(atRest));
      // bar + the 6px gap + the weekday letter, against the box it lives in.
      final content = tester.getSize(tallest).height + 6 + tester.getSize(find.text('F')).height;
      expect(content, lessThanOrEqualTo(56.0));
      expect(tester.takeException(), isNull);
    });
  });

  group('Orders/Bookings tile grid', () {
    // The tiles sit in an IntrinsicHeight row so every card in a row matches
    // height. IntrinsicHeight interrogates its children for intrinsic sizes, and
    // cards of UNEQUAL height containing a Wrap are exactly the combination that
    // throws if a child does not support it. Cheap test, whole class of crash.
    testWidgets('unequal cards containing Wrap lay out inside IntrinsicHeight',
        (tester) async {
      Widget card(int chips, bool withButtons) => ForkCard(
            onTap: () {},
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Table 4'),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var i = 0; i < chips; i++)
                  InfoChip(icon: Icons.access_time, label: 'chip $i'),
              ]),
              if (withButtons) ...[
                const SizedBox(height: 10),
                Row(children: const [
                  Expanded(child: Text('Decline')),
                  SizedBox(width: 8),
                  Expanded(child: Text('Approve')),
                ]),
              ],
            ]),
          );

      await tester.pumpWidget(_host(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: card(1, false)),
              const SizedBox(width: 14),
              Expanded(child: card(5, true)),
            ],
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('Table 4'), findsNWidgets(2));
    });
  });
}
