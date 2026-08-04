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

/// A pinned width, because the barcode's bar count is derived from it: Scaffold
/// hands its body tight constraints, so a bare SizedBox would silently be
/// stretched to the test surface and every expected index would shift.
Widget _hostAt(double width, Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

/// The barcode is a CustomPaint, so the only place its hover selection is
/// observable is the painter. Reached dynamically because the painter type is
/// library-private; `hoveredBar` itself is public precisely for this.
dynamic _barcodePainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.descendant(
        of: find.byType(CopperBarcode), matching: find.byType(CustomPaint)))
    .map((w) => w.painter)
    .firstWhere((p) => p.runtimeType.toString() == '_BarcodePainter');

Iterable<MouseRegion> _clickCursors(WidgetTester tester, Finder within) => tester
    .widgetList<MouseRegion>(
        find.descendant(of: within, matching: find.byType(MouseRegion)))
    .where((r) => r.cursor == SystemMouseCursors.click);

Future<TestGesture> _mouse(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(() => g.removePointer());
  return g;
}

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

    // The barcode divides by its own max too, and now builds a hit box per bar
    // on top of that -- so the interactive path has to survive the empty day as
    // well, not just the painter.
    testWidgets('CopperBarcode renders an all-zero series', (tester) async {
      await tester.pumpWidget(_hostAt(
        300,
        CopperBarcode(
          values: const [0, 0, 0, 0, 0],
          onTap: (_) {},
          tooltipBuilder: (i) => 'point $i',
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_barcodePainter(tester).hoveredBar, isNull);
    });

    testWidgets('CopperBarcode with no values renders nothing rather than throwing',
        (tester) async {
      await tester.pumpWidget(_hostAt(
        300,
        CopperBarcode(values: const [], onTap: (_) {}),
      ));
      expect(tester.takeException(), isNull);
      // Nothing to point at, so nothing claims the pointer.
      expect(_clickCursors(tester, find.byType(CopperBarcode)), isEmpty);
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

  // The Overview page renders its revenue strip as a CopperBarcode and its
  // occupancy meter as a DonutGauge. Both were pure paint until now, so the
  // "charts are clickable" work landed on Analytics and never on the screen the
  // user was actually looking at.
  group('Overview charts answer the pointer', () {
    // At width 300 the painter's slot is barWidth 2.6 + gap 2.4 = 5.0, so it
    // draws 60 bars over 5 readings. The offsets below are chosen from the
    // geometry on screen (left edge, a quarter in, the middle, the right edge);
    // if hit-testing ever stops using the painter's own maths, the reported
    // index drifts away from the bar the pointer is on and these fail.
    const series = [10.0, 20.0, 30.0, 40.0, 50.0];

    testWidgets('tapping a barcode bar reports the reading under the pointer',
        (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(_hostAt(
        300,
        CopperBarcode(values: series, onTap: taps.add),
      ));
      final origin = tester.getTopLeft(find.byType(CopperBarcode));
      for (final dx in const [2.0, 77.0, 152.0, 298.0]) {
        await tester.tapAt(origin + Offset(dx, 23));
        await tester.pump();
      }
      expect(taps, [0, 1, 2, 4]);
    });

    testWidgets('hovering a barcode bar names the reading under the pointer',
        (tester) async {
      await tester.pumpWidget(_hostAt(
        300,
        CopperBarcode(values: series, tooltipBuilder: (i) => 'point $i'),
      ));
      final origin = tester.getTopLeft(find.byType(CopperBarcode));
      final mouse = await _mouse(tester);

      await mouse.moveTo(origin + const Offset(298, 23));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('point 4'), findsOneWidget);
      expect(find.text('point 0'), findsNothing);
    });

    testWidgets('hover highlights the bar the pointer is over', (tester) async {
      await tester.pumpWidget(_hostAt(
        300,
        CopperBarcode(values: series, onTap: (_) {}),
      ));
      expect(_barcodePainter(tester).hoveredBar, isNull);

      final origin = tester.getTopLeft(find.byType(CopperBarcode));
      final mouse = await _mouse(tester);
      await mouse.moveTo(origin + const Offset(152, 23));
      await tester.pump();
      // x 152 falls in slot 30 (152 / 5.0), which resamples to reading 2 --
      // the same bar the tap test drills into from that offset.
      final hovered = _barcodePainter(tester).hoveredBar as int;
      expect(hovered, 30);
      // And the pointer is inside the ink the painter lays down for that bar
      // (x = index * slot, 2.6px wide) -- not merely on a bar with a matching
      // number. Highlighting a bar the pointer is not over is the whole failure
      // mode this chart had to avoid.
      expect(hovered * 5.0, lessThanOrEqualTo(152.0));
      expect(hovered * 5.0 + 2.6, greaterThan(152.0));

      await mouse.moveTo(origin + const Offset(2, 23));
      await tester.pump();
      expect(_barcodePainter(tester).hoveredBar, 0);
    });

    testWidgets('a barcode with no callbacks stays inert', (tester) async {
      await tester.pumpWidget(_hostAt(
        300,
        const CopperBarcode(values: series),
      ));
      final bar = find.byType(CopperBarcode);
      expect(_clickCursors(tester, bar), isEmpty);

      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(bar));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // No highlight, and no hover card promising a drill-down that is not there.
      expect(_barcodePainter(tester).hoveredBar, isNull);
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the occupancy gauge fires its callback', (tester) async {
      var hits = 0;
      await tester.pumpWidget(_host(Center(
        child: DonutGauge(fraction: 0.62, onTap: () => hits++),
      )));
      await tester.tap(find.byType(DonutGauge));
      await tester.pump();
      expect(hits, 1);
    });

    testWidgets('the gauge reads as interactive under the pointer', (tester) async {
      await tester.pumpWidget(_host(Center(
        child: DonutGauge(
          fraction: 0.62,
          tooltip: '13 of 21 tables',
          onTap: () {},
        ),
      )));
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);

      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(find.byType(DonutGauge)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
          greaterThan(1.0));
      expect(find.text('13 of 21 tables'), findsOneWidget);
    });

    testWidgets('a gauge with no callbacks stays inert', (tester) async {
      await tester.pumpWidget(_host(const Center(child: DonutGauge(fraction: 0.62))));
      final gauge = find.byType(DonutGauge);
      expect(_clickCursors(tester, gauge), isEmpty);
      // Not merely unhovered -- the transform is absent, so an inert gauge keeps
      // exactly the tree (and the size) it had before interaction existed.
      expect(find.byType(AnimatedScale), findsNothing);

      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(gauge));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(Tooltip), findsNothing);
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
