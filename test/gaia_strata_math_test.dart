// STRATA is the one place in this design system where a picture makes an
// arithmetic claim: "thickness is share". Analytics and History draw settled
// revenue, so a band that is too thick is not a style bug, it is a wrong
// number rendered large and confident.
//
// Everything below tests the pure geometry — no widgets, no pixels, no fonts.
// If these pass, the only way the picture can lie is a painter that ignores
// the layout it was handed, and that is a much smaller surface to keep honest.

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia_strata_math.dart';

/// Ratio of two heights, for asserting that survivors stay in proportion.
double _ratio(double a, double b) => a / b;

void main() {
  group('share mode — thickness is share', () {
    test('three clean parts divide the extent in exact proportion', () {
      // minHeight is pinned in every test that asserts an exact pixel, so the
      // arithmetic under test never moves because the WIDGET's chrome grew.
      final l = GaiaStrataMath.resolve(
        values: [50, 30, 20],
        extent: 300,
        minHeight: 34,
        mode: GaiaStrataMode.share,
      );
      expect(l.positiveTotal, 100);
      expect(l.bands.map((b) => b.height), [150, 90, 60]);
      expect(l.bands.map((b) => b.share), [0.5, 0.3, 0.2]);
      expect(l.anyFloored, isFalse);
      expect(l.proportional, isTrue);
      expect(l.totalHeight, closeTo(300, 1e-9));
    });

    test('shares are taken against the true whole, not the drawn extent', () {
      final l = GaiaStrataMath.resolve(values: [7, 3], extent: 1000);
      expect(l.bands[0].share, closeTo(0.7, 1e-12));
      expect(l.bands[1].share, closeTo(0.3, 1e-12));
    });

    test('doubling a value doubles its thickness and nothing else changes '
        'about the ordering', () {
      final a = GaiaStrataMath.resolve(values: [10, 10, 10], extent: 300);
      final b = GaiaStrataMath.resolve(values: [20, 10, 10], extent: 400);
      expect(_ratio(a.bands[0].height, a.bands[1].height), closeTo(1, 1e-9));
      expect(_ratio(b.bands[0].height, b.bands[1].height), closeTo(2, 1e-9));
    });
  });

  group('a band too small to read is floored, and says so', () {
    test('the hairline band gets the minimum and the survivors keep their '
        'ratio to each other', () {
      // Raw would be 180 / 117 / 3. The 3px band is unreadable.
      final l = GaiaStrataMath.resolve(
        values: [60, 39, 1],
        extent: 300,
        minHeight: 34,
      );
      expect(l.bands[2].floored, isTrue);
      expect(l.bands[2].height, 34);
      expect(l.bands[0].floored, isFalse);
      expect(l.bands[1].floored, isFalse);
      // 60 : 39 preserved exactly among the bands that were not floored —
      // this is the property that keeps the picture readable as a quantity.
      expect(_ratio(l.bands[0].height, l.bands[1].height),
          closeTo(60 / 39, 1e-9));
      expect(l.totalHeight, closeTo(300, 1e-9));
      expect(l.anyFloored, isTrue);
      // Still proportional: two of three bands genuinely are.
      expect(l.proportional, isTrue);
    });

    test('flooring one band can push the next under the minimum, and the '
        'solver keeps going until it stops', () {
      // Single-pass allocation would floor only the 1, then hand 2 a share of
      // the shrunken pool that is BELOW the minimum and leave it there.
      final l = GaiaStrataMath.resolve(
        values: [200, 8, 1],
        extent: 300,
        minHeight: 34,
      );
      expect(l.bands[1].floored, isTrue, reason: 'second round must catch this');
      expect(l.bands[2].floored, isTrue);
      expect(l.bands[1].height, 34);
      expect(l.bands[2].height, 34);
      expect(l.bands[0].height, closeTo(300 - 68, 1e-9));
      for (final b in l.bands) {
        expect(b.height, greaterThanOrEqualTo(34));
      }
    });

    test('when everything floors the layout stops claiming to be '
        'proportional', () {
      final l = GaiaStrataMath.resolve(
        values: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        extent: 120, // 10 bands cannot fit at 34 each
        minHeight: 34,
      );
      expect(l.bands.every((b) => b.height == 34), isTrue);
      expect(l.proportional, isFalse,
          reason: 'ten identical slabs must not imply ten measured equals');
      // Taller than the budget on purpose: text is never crushed to fit.
      expect(l.totalHeight, 340);
    });
  });

  group('zero renders honestly', () {
    test('a zero band keeps a readable height and is flagged, not dropped', () {
      final l = GaiaStrataMath.resolve(
          values: [100, 0, 50], extent: 300, minHeight: 34);
      expect(l.bands.length, 3);
      expect(l.bands[1].isZero, isTrue);
      expect(l.bands[1].share, 0);
      expect(l.bands[1].height, 34);
      expect(l.bands[1].floored, isTrue);
      expect(l.zeroCount, 1);
    });

    test('a zero band takes no share away from the others', () {
      final withZero = GaiaStrataMath.resolve(values: [100, 0, 50], extent: 300);
      final without = GaiaStrataMath.resolve(values: [100, 50], extent: 300);
      expect(withZero.bands[0].share, closeTo(without.bands[0].share, 1e-12));
      expect(withZero.positiveTotal, without.positiveTotal);
    });

    test('an all-zero window has no whole and does not divide by it', () {
      final l = GaiaStrataMath.resolve(values: [0, 0, 0], extent: 300);
      expect(l.hasWhole, isFalse);
      expect(l.proportional, isFalse);
      for (final b in l.bands) {
        expect(b.share, 0);
        expect(b.height.isFinite, isTrue);
        expect(b.height, 100);
      }
    });

    test('an empty series is empty, not a crash', () {
      final l = GaiaStrataMath.resolve(values: [], extent: 300);
      expect(l.bands, isEmpty);
      expect(l.hasWhole, isFalse);
    });
  });

  group('negative renders honestly', () {
    test('a refund is drawn at its magnitude and is never clamped away', () {
      final l = GaiaStrataMath.resolve(
          values: [100, -20, 100], extent: 440, minHeight: 34);
      expect(l.bands[1].isNegative, isTrue);
      expect(l.negativeCount, 1);
      // 20 is a fifth of 100, so its band is a fifth as thick.
      expect(_ratio(l.bands[0].height, l.bands[1].height), closeTo(5, 1e-9));
      expect(l.bands[1].height, greaterThan(0));
    });

    test('a refund is excluded from the denominator, so it cannot shrink the '
        'months around it', () {
      final withRefund = GaiaStrataMath.resolve(values: [100, -50], extent: 300);
      final without = GaiaStrataMath.resolve(values: [100], extent: 300);
      expect(withRefund.positiveTotal, 100);
      expect(withRefund.bands[0].share, closeTo(without.bands[0].share, 1e-12));
      expect(withRefund.bands[0].share, 1.0);
      // The refund's own share is signed, and it is allowed past -100%.
      expect(withRefund.bands[1].share, closeTo(-0.5, 1e-12));
    });

    test('a window that is only refunds has no whole rather than a negative '
        'one', () {
      final l = GaiaStrataMath.resolve(values: [-10, -20], extent: 300);
      expect(l.positiveTotal, 0);
      expect(l.hasWhole, isFalse);
      expect(l.negativeCount, 2);
      for (final b in l.bands) {
        expect(b.height.isFinite, isTrue);
      }
    });
  });

  group('rank mode makes no thickness claim', () {
    test('every band is content-height and the layout says it is not '
        'proportional', () {
      final l = GaiaStrataMath.resolve(
        values: [107.9, 1.71, 5, 4.55, 54.55, 0],
        extent: 300,
        mode: GaiaStrataMode.rank,
      );
      expect(l.bands.every((b) => b.height == 0), isTrue);
      expect(l.proportional, isFalse);
      expect(l.anyFloored, isFalse);
      // The shares are still computed, for anything that wants to report them —
      // but nothing draws with them.
      expect(l.bands[0].share, greaterThan(0));
    });
  });

  group('garbage in does not become a picture', () {
    test('NaN and infinity are read as zero rather than poisoning the scale',
        () {
      final l = GaiaStrataMath.resolve(
        values: [double.nan, 100, double.infinity, -double.infinity],
        extent: 300,
      );
      expect(l.positiveTotal, 100);
      for (final b in l.bands) {
        expect(b.height.isFinite, isTrue);
        expect(b.share.isFinite, isTrue);
      }
      expect(l.bands[0].isZero, isTrue);
      expect(l.bands[2].isZero, isTrue);
      expect(l.bands[3].isZero, isTrue);
    });
  });

  group('stacked chart geometry', () {
    test('bands stack in series order and each is exactly its own value '
        'thick', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [10, 20]),
        GaiaStrataSeries(label: 'Card', values: [30, 10]),
        GaiaStrataSeries(label: 'UPI', values: [60, 70]),
      ]);
      expect(l.length, 2);
      expect(l.spans[0][0], (from: 0.0, to: 10.0));
      expect(l.spans[1][0], (from: 10.0, to: 40.0));
      expect(l.spans[2][0], (from: 40.0, to: 100.0));
      expect(l.maxTop, 100);
      expect(l.minBottom, 0);
      expect(l.hasNegative, isFalse);
      // Thickness == |value|, at every point, for every series.
      for (var s = 0; s < 3; s++) {
        for (var x = 0; x < 2; x++) {
          final span = l.spans[s][x];
          expect(span.to - span.from,
              closeTo(const [
                [10.0, 20.0],
                [30.0, 10.0],
                [60.0, 70.0]
              ][s][x], 1e-12));
        }
      }
    });

    test('a series that is zero all window has no thickness, so its share is '
        'what has to state it', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [0, 0]),
        GaiaStrataSeries(label: 'UPI', values: [50, 50]),
      ]);
      expect(l.spans[0].every((s) => s.to - s.from == 0), isTrue);
      expect(l.shareOf(0), 0);
      expect(l.shareOf(1), 1);
      expect(l.isEmpty, isFalse);
    });

    test('negatives stack below a real zero instead of being clamped to it',
        () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Sales', values: [100, 100]),
        GaiaStrataSeries(label: 'Refunds', values: [0, -40]),
      ]);
      expect(l.hasNegative, isTrue);
      expect(l.minBottom, -40);
      expect(l.maxTop, 100);
      expect(l.span, 140);
      expect(l.spans[1][1], (from: -40.0, to: 0.0));
      // The refund keeps its full magnitude in pixels.
      final h = 140.0; // one pixel per unit
      expect(l.y(0, h) - l.y(-40, h), closeTo(-40, 1e-9));
      expect(l.y(l.maxTop, h), 0);
      expect(l.y(l.minBottom, h), closeTo(h, 1e-9));
    });

    test('a zero day in a series that dips sits ON the baseline, not on top of '
        'the positive stack', () {
      // The bug this pins: a band is one polygon across the window, so a zero
      // parked at the top of the positive stack on Monday and at the baseline
      // on Tuesday sweeps a filled wedge across the chart standing for a day
      // with no refunds. Every zero here must be a degenerate span AT zero.
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Sales', values: [80, 95, 60, 110, 90]),
        GaiaStrataSeries(label: 'Refunds', values: [0, -12, 0, -38, -5]),
      ]);
      expect(l.spans[1][0], (from: 0.0, to: 0.0));
      expect(l.spans[1][2], (from: 0.0, to: 0.0));
      expect(l.spans[1][1], (from: -12.0, to: 0.0));
      expect(l.spans[1][3], (from: -38.0, to: 0.0));
      // The sales band is untouched by the rule.
      expect(l.spans[0][0], (from: 0.0, to: 80.0));
      expect(l.spans[0][2], (from: 0.0, to: 60.0));
    });

    test('a zero day in an all-positive series still rides the stack, so the '
        'layers above it do not slip down to the axis', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [10, 10]),
        GaiaStrataSeries(label: 'Card', values: [5, 0]),
        GaiaStrataSeries(label: 'UPI', values: [20, 20]),
      ]);
      // Card is zero on day two but still sits at the top of Cash…
      expect(l.spans[1][1], (from: 10.0, to: 10.0));
      // …so UPI keeps stacking above it rather than jumping to the baseline.
      expect(l.spans[2][1], (from: 10.0, to: 30.0));
    });

    test('a refund does not inflate any series share', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Sales', values: [100]),
        GaiaStrataSeries(label: 'Refunds', values: [-100]),
      ]);
      expect(l.grandPositive, 100);
      expect(l.shareOf(0), 1);
      expect(l.shareOf(1), 0);
    });

    test('an all-zero stack is empty rather than a flat line pretending to be '
        'a measurement', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [0, 0, 0]),
      ]);
      expect(l.isEmpty, isTrue);
      expect(l.span, 0);
      // y() must still be finite so a painter that ignores isEmpty cannot
      // produce NaN offsets.
      expect(l.y(0, 150).isFinite, isTrue);
    });

    test('a short series is padded with zero rather than throwing', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [10, 10, 10]),
        GaiaStrataSeries(label: 'UPI', values: [5]),
      ]);
      expect(l.length, 3);
      expect(l.spans[1][2], (from: 10.0, to: 10.0));
      expect(l.seriesPositiveTotals[1], 5);
    });

    test('no series and no points is empty, not a crash', () {
      expect(GaiaStrataStack.resolve(const []).isEmpty, isTrue);
      expect(
        GaiaStrataStack.resolve(
            const [GaiaStrataSeries(label: 'x', values: [])]).isEmpty,
        isTrue,
      );
    });

    test('non-finite readings are read as zero', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'Cash', values: [double.nan, 10]),
      ]);
      expect(l.maxTop, 10);
      expect(l.spans[0][0], (from: 0.0, to: 0.0));
      expect(l.y(5, 100).isFinite, isTrue);
    });

    test('y() maps the value range onto the box, top-down', () {
      final l = GaiaStrataStack.resolve(const [
        GaiaStrataSeries(label: 'a', values: [0, 200]),
      ]);
      expect(l.y(200, 100), 0);
      expect(l.y(100, 100), 50);
      expect(l.y(0, 100), 100);
    });
  });
}
