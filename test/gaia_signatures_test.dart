// The two DATA-LED signature styles, as rendered.
//
// `gaia_strata_math_test.dart` pins the arithmetic. This file pins the two
// things arithmetic cannot: that the picture actually SAYS what the numbers
// could not draw (a zero band, a refund, a floored thickness, an empty
// window), and that inverting the ground on the Simulation screen does not
// make a control disappear.
//
// The second half matters more than it looks. Coral on champagne measures
// 1.71:1 and sage 1.02:1 — a status chip that carries its dark-ground ink onto
// the BICOLOUR slab does not render "faintly", it renders as nothing at all,
// on the one screen in the app that projects money.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// GaiaScope, not just GaiaTheme: `Gaia.of` is what every shared primitive
/// asks, and without the scope a StatusChip in here would quietly render its
/// RUSTIC self and the bicolour assertions would be testing nothing.
Widget _host(Widget child, {double width = 430}) => GaiaScope(
      system: DesignSystem.gaia,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: GaiaTheme.dark(),
        home: Scaffold(
          backgroundColor: GaiaColors.bg,
          body: SizedBox(
            width: width,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

/// The rendered height of the band whose label is [label]. In share mode a
/// band is wrapped in a `SizedBox(height: …)` the solver decided, so this is
/// the actual thickness on screen — not the number the solver returned.
double _bandHeight(WidgetTester tester, String label) {
  final box = find
      .ancestor(
        of: find.text(label.toUpperCase()),
        matching: find.byType(SizedBox),
      )
      .first;
  return tester.getSize(box).height;
}

GaiaStratum _s(String label, double v, {String? display}) => GaiaStratum(
      label: label,
      value: v,
      display: display ?? '₹${v.toStringAsFixed(0)}',
    );

void main() {
  group('STRATA · the band list says what the geometry cannot', () {
    testWidgets('thickness on screen is the share, not just in the solver',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: 400,
        strata: [_s('Aug', 300), _s('Jul', 100)],
      )));
      final aug = _bandHeight(tester, 'Aug');
      final jul = _bandHeight(tester, 'Jul');
      expect(aug / jul, closeTo(3, 0.01),
          reason: 'three times the revenue must be three times the band');
      expect(aug + jul, closeTo(400, 1));
    });

    testWidgets('a zero month keeps its row, its figure and a word for it',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: 400,
        strata: [_s('Aug', 177214), _s('Jul', 0, display: '₹0')],
      )));
      // The row exists.
      expect(find.text('JUL'), findsOneWidget);
      // The figure is stated rather than implied by an absent band.
      expect(find.text('₹0'), findsOneWidget);
      // And the condition the geometry cannot draw is a word.
      expect(find.text('ZERO'), findsOneWidget);
      expect(_bandHeight(tester, 'Jul'),
          greaterThanOrEqualTo(GaiaStrataMath.defaultMinHeight));
    });

    testWidgets('a refund is drawn, named and kept out of the shares',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: 400,
        strata: [_s('Aug', 200), _s('Jul', -100, display: '−₹100')],
      )));
      expect(find.text('BELOW ZERO'), findsOneWidget);
      expect(find.text('−₹100'), findsOneWidget);
      // 200 positive is the whole; the refund is half of it in magnitude, so
      // half the ink — and the positive band still reads 100%.
      expect(find.text('100.0%'), findsOneWidget);
      expect(find.text('-50.0%'), findsOneWidget);
      expect(_bandHeight(tester, 'Aug') / _bandHeight(tester, 'Jul'),
          closeTo(2, 0.01));
      expect(find.textContaining('below zero, drawn at magnitude'),
          findsOneWidget);
    });

    testWidgets('a floored band does not pretend its thickness is its share',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: 300,
        strata: [_s('Aug', 990), _s('Jul', 10)],
      )));
      // 1% of 300px is 3px. The band is raised to a readable height — and the
      // page says so, so nobody reads that height as 21%.
      expect(_bandHeight(tester, 'Jul'), GaiaStrataMath.defaultMinHeight);
      expect(find.textContaining('drawn at their minimum height'), findsOneWidget);
      // The true figure is still on the band.
      expect(find.text('1.0%'), findsOneWidget);
    });

    testWidgets('when the floors eat the whole budget the strata stops '
        'claiming any thickness means anything', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        // 100px between six bands whose floor alone is 64 each.
        extent: 100,
        strata: [for (var i = 0; i < 6; i++) _s('M$i', (i + 1) * 10)],
      )));
      expect(find.textContaining('Too many rows to give any band a height'),
          findsOneWidget);
      // …and NOT the softer sentence, which would imply the rest are honest.
      expect(find.textContaining('Bands too small to hold a label'), findsNothing);
    });

    testWidgets('extentFor leaves the proportional bands room after the floors',
        (tester) async {
      // Five months, one of them carrying almost everything: with a budget
      // sized by eye the four small ones floor and swallow it, and the big one
      // ends up the same height as a zero.
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: GaiaStrataList.extentFor(5),
        strata: [
          _s('Aug', 177214),
          _s('Jul', 59071),
          _s('Jun', 8940),
          _s('May', 0, display: '₹0'),
          _s('Apr', 0, display: '₹0'),
        ],
      )));
      expect(_bandHeight(tester, 'Aug') / _bandHeight(tester, 'Jul'),
          closeTo(177214 / 59071, 0.01));
      expect(_bandHeight(tester, 'Aug'),
          greaterThan(2 * GaiaStrataMath.defaultMinHeight));
    });

    testWidgets('an all-zero window says there is no whole rather than '
        'drawing equal slabs silently', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        mode: GaiaStrataMode.share,
        extent: 300,
        strata: [_s('Aug', 0, display: '₹0'), _s('Jul', 0, display: '₹0')],
      )));
      expect(find.textContaining('No positive total in this window'),
          findsOneWidget);
      // No percentage is claimed — but the zeros are real readings and are
      // still named. "No whole to be a share of" and "this month earned
      // nothing" are two different facts.
      expect(find.text('ZERO'), findsNWidgets(2));
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('rank mode makes no percentage claim at all', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        strata: [
          GaiaStratum(
              label: 'Table turnaround',
              value: 107.9,
              display: '107.9',
              unit: 'min',
              tagLabel: 'Action',
              tagColor: GaiaStrataColors.tagCoral),
          const GaiaStratum(label: 'NPS', value: 54.55, display: '54.55'),
        ],
      )));
      expect(find.text('ACTION'), findsOneWidget);
      // No band in rank mode carries a share — these metrics share no total.
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('These metrics share no total'), findsNothing,
          reason: 'that caption is passed by the screen, not the widget');
    });

    testWidgets('rank mode does not tag a band ZERO — it never measured one',
        (tester) async {
      // A KPI the backend could not compute arrives with a null value, which
      // the screen hands over as 0. In rank mode nothing is drawn from that
      // number, so calling the band "zero" reports a measurement that was
      // never taken — and it would sit right beside the screen's own NO DATA.
      await tester.pumpWidget(_host(const GaiaStrataList(
        strata: [
          GaiaStratum(
              label: 'Labour cost',
              value: 0,
              display: '—',
              tagLabel: 'No data'),
        ],
      )));
      expect(find.text('NO DATA'), findsOneWidget);
      expect(find.text('ZERO'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('the status word ships alongside the status ink',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataList(
        strata: [
          GaiaStratum(
              label: 'RevPASH',
              value: 1.71,
              display: '₹1.71',
              tagLabel: 'Action',
              tagColor: GaiaStrataColors.tagCoral),
        ],
      )));
      expect(find.text('ACTION'), findsOneWidget);
    });
  });

  group('STRATA · the stacked chart', () {
    testWidgets('an all-zero window refuses to draw a flat line and says so',
        (tester) async {
      await tester.pumpWidget(_host(GaiaStrataChart(
        series: const [GaiaStrataSeries(label: 'Revenue', values: [0, 0, 0])],
        format: (v) => '₹${v.toStringAsFixed(0)}',
        emptyMessage: 'No revenue in this window.',
      )));
      expect(find.text('No revenue in this window.'), findsOneWidget);
    });

    testWidgets('the key numbers every band and states its share, so colour '
        'is never the thing being read', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataChart(
        series: const [
          GaiaStrataSeries(label: 'Cash', values: [16, 16]),
          GaiaStrataSeries(label: 'Card', values: [38, 38]),
          GaiaStrataSeries(label: 'UPI', values: [46, 46]),
        ],
        format: (v) => '₹${v.toStringAsFixed(0)}',
        axisLabels: const ['21 Aug', '3 Sep'],
      )));
      expect(find.text('01 '), findsOneWidget);
      expect(find.text('02 '), findsOneWidget);
      expect(find.text('03 '), findsOneWidget);
      expect(find.text('CASH · 16% · ₹32'), findsOneWidget);
      expect(find.text('CARD · 38% · ₹76'), findsOneWidget);
      expect(find.text('UPI · 46% · ₹92'), findsOneWidget);
      // The axis ends are labelled.
      expect(find.text('21 AUG'), findsOneWidget);
      expect(find.text('3 SEP'), findsOneWidget);
    });

    testWidgets('a series that never moves off zero states its 0% rather than '
        'vanishing without comment', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataChart(
        series: const [
          GaiaStrataSeries(label: 'Cash', values: [0, 0]),
          GaiaStrataSeries(label: 'UPI', values: [50, 50]),
        ],
        format: (v) => '₹${v.toStringAsFixed(0)}',
      )));
      expect(find.text('CASH · 0% · ₹0'), findsOneWidget);
    });

    testWidgets('a window with refunds announces its baseline', (tester) async {
      await tester.pumpWidget(_host(GaiaStrataChart(
        series: const [
          GaiaStrataSeries(label: 'Sales', values: [100, 100]),
          GaiaStrataSeries(label: 'Refunds', values: [0, -40]),
        ],
        format: (v) => '₹${v.toStringAsFixed(0)}',
      )));
      expect(find.textContaining('below zero are drawn under the marked'),
          findsOneWidget);
    });
  });

  group('BICOLOUR · nothing invisible may reach the champagne slab', () {
    test('every ink the slab uses clears AA 4.5 on its own ground', () {
      const g = GaiaBicolourColors.ground;
      final inks = <String, Color>{
        'ink': GaiaBicolourColors.ink,
        'label': GaiaBicolourColors.label,
        'body': GaiaBicolourColors.body,
        'statusBad': GaiaBicolourColors.statusBad,
        'statusGood': GaiaBicolourColors.statusGood,
        'statusWarn': GaiaBicolourColors.statusWarn,
        'statusInfo': GaiaBicolourColors.statusInfo,
      };
      inks.forEach((name, c) {
        expect(_contrast(c, g), greaterThanOrEqualTo(4.5),
            reason: '$name on champagne is ${_contrast(c, g).toStringAsFixed(2)}');
      });
    });

    test("the mockup's own supporting inks would NOT have cleared, which is "
        'why they were lifted', () {
      // Recorded so the divergence from the spec stays a decision rather than
      // drift. #6b5634 is `.bico .eyebrow`, #5a4a32 is `.bico .lever p`.
      expect(_contrast(const Color(0xFF6B5634), GaiaBicolourColors.ground),
          lessThan(4.5));
      expect(_contrast(const Color(0xFF5A4A32), GaiaBicolourColors.ground),
          lessThan(4.5));
      // And the lifted pair is visibly the same colour, not a new one.
      expect(
          (GaiaBicolourColors.label.r - const Color(0xFF6B5634).r).abs(),
          lessThan(0.10));
    });

    test('the dark-ground status inks are invisible here — every one of them',
        () {
      for (final c in [
        GaiaColors.coral,
        GaiaColors.sage,
        GaiaColors.amber,
        AppColors.success,
        AppColors.warning,
        AppColors.danger,
        AppColors.info,
      ]) {
        expect(_contrast(c, GaiaBicolourColors.ground), lessThan(2.0),
            reason: 'this is the failure the remap exists to prevent');
        // …and every one of them survives the remap.
        expect(
            _contrast(GaiaBicolour.status(c), GaiaBicolourColors.ground),
            greaterThanOrEqualTo(4.5));
      }
    });

    test('the remap keeps the MEANING, not just the legibility', () {
      expect(GaiaBicolour.status(GaiaColors.coral), GaiaBicolourColors.statusBad);
      expect(GaiaBicolour.status(AppColors.danger), GaiaBicolourColors.statusBad);
      expect(GaiaBicolour.status(GaiaColors.sage), GaiaBicolourColors.statusGood);
      expect(GaiaBicolour.status(AppColors.success), GaiaBicolourColors.statusGood);
      expect(GaiaBicolour.status(GaiaColors.amber), GaiaBicolourColors.statusWarn);
      expect(GaiaBicolour.status(AppColors.warning), GaiaBicolourColors.statusWarn);
      expect(GaiaBicolour.status(AppColors.info), GaiaBicolourColors.statusInfo);
      // The accent inverts on its own ground.
      expect(GaiaBicolour.status(GaiaColors.champagne), GaiaBicolourColors.ink);
    });

    test('no colour anywhere on the wheel gets through the remap invisible',
        () {
      // The safety net, fuzzed: StatusChip takes a caller-chosen colour at well
      // over a hundred sites and this is what stops any of them rendering blank.
      for (var h = 0; h < 360; h += 5) {
        for (final s in [0.0, 0.25, 0.6, 1.0]) {
          for (final l in [0.15, 0.4, 0.65, 0.9]) {
            final c = HSLColor.fromAHSL(1, h.toDouble(), s, l).toColor();
            final mapped = GaiaBicolour.status(c);
            expect(_contrast(mapped, GaiaBicolourColors.ground),
                greaterThanOrEqualTo(4.5),
                reason: 'hsl($h, $s, $l) mapped to something unreadable');
          }
        }
      }
    });

    test('a colour that already reads on champagne is left exactly as the '
        'caller chose it', () {
      const deliberate = Color(0xFF102030);
      expect(GaiaBicolour.status(deliberate), deliberate);
    });
  });

  group('BICOLOUR · the slab re-inks what is drawn on it', () {
    testWidgets('a status chip inside the panel does not keep its dark ink',
        (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourPanel(
        child: StatusChip(label: 'speculative', color: GaiaColors.amber),
      )));
      final dot = tester.widget<Container>(find
          .descendant(of: find.byType(StatusChip), matching: find.byType(Container))
          .first);
      final border = (dot.decoration as BoxDecoration?)?.border;
      expect(border, isNotNull);
      final side = (border! as Border).top.color;
      expect(side, isNot(GaiaColors.amber));
      expect(_contrast(side, GaiaBicolourColors.ground),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('the same chip OUTSIDE the panel is untouched', (tester) async {
      await tester.pumpWidget(_host(const StatusChip(
        label: 'speculative',
        color: GaiaColors.amber,
      )));
      final dot = tester.widget<Container>(find
          .descendant(of: find.byType(StatusChip), matching: find.byType(Container))
          .first);
      final border = (dot.decoration as BoxDecoration?)!.border! as Border;
      expect(border.top.color, GaiaColors.amber);
    });

    testWidgets('a button on the slab outlines in ink, not in champagne',
        (tester) async {
      await tester.pumpWidget(_host(GaiaBicolourPanel(
        child: GaiaButton(label: 'Run', onPressed: () {}),
      )));
      final box = tester.widget<AnimatedContainer>(find
          .descendant(of: find.byType(GaiaButton), matching: find.byType(AnimatedContainer))
          .first);
      final d = box.decoration! as BoxDecoration;
      expect(d.color, GaiaBicolourColors.ink,
          reason: 'a champagne fill on a champagne ground is not a button');
      expect((d.border! as Border).top.color, GaiaBicolourColors.ink);
    });

    testWidgets('the panel publishes itself, and only inside itself',
        (tester) async {
      late bool inside;
      late bool outside;
      await tester.pumpWidget(_host(Column(children: [
        GaiaBicolourPanel(
          child: Builder(builder: (c) {
            inside = GaiaBicolour.of(c);
            return const SizedBox();
          }),
        ),
        Builder(builder: (c) {
          outside = GaiaBicolour.of(c);
          return const SizedBox();
        }),
      ])));
      expect(inside, isTrue);
      expect(outside, isFalse);
    });
  });

  group('BICOLOUR · the delta row', () {
    testWidgets('a delta never depends on its colour alone', (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourPanel(
        child: Column(children: [
          GaiaDeltaRow(
            first: true,
            metric: 'Net profit / day',
            current: '−₹2,510',
            scenario: '−₹10,309',
            delta: '−7,799',
            deltaColor: GaiaColors.coral,
            rise: -1,
          ),
          GaiaDeltaRow(
            metric: 'Covers / day',
            current: '5.3',
            scenario: '5.5',
            delta: '+0.2',
            deltaColor: GaiaColors.sage,
            rise: 1,
          ),
        ]),
      )));
      // The sign is in the string AND a shape rides in front of it.
      expect(find.text('▼ −7,799'), findsOneWidget);
      expect(find.text('▲ +0.2'), findsOneWidget);
    });

    testWidgets('the column header clears AA on both grounds — nothing else '
        'names the columns', (tester) async {
      await tester.pumpWidget(_host(const Column(children: [
        GaiaDeltaRow(
          first: true,
          header: true,
          metric: 'Metric',
          current: 'Current',
          scenario: 'Scenario',
          delta: 'Delta',
        ),
        GaiaBicolourPanel(
          child: GaiaDeltaRow(
            first: true,
            header: true,
            metric: 'Metric',
            current: 'Current',
            scenario: 'Scenario',
            delta: 'Delta',
          ),
        ),
      ])));
      final heads = tester.widgetList<Text>(find.text('Metric')).toList();
      expect(heads.length, 2);
      expect(_contrast(heads[0].style!.color!, GaiaColors.bg),
          greaterThanOrEqualTo(4.5));
      expect(_contrast(heads[1].style!.color!, GaiaBicolourColors.ground),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('the arrow can never contradict the sign beside it',
        (tester) async {
      // A rising cost is BAD (coral) but it still rose, so the glyph points up.
      // The version that pointed the arrow at the verdict rendered this row as
      // "▼ +₹6,150", which is an arrow arguing with its own number.
      await tester.pumpWidget(_host(const GaiaDeltaRow(
        first: true,
        metric: 'Labour / day',
        current: '₹6,300',
        scenario: '₹12,450',
        delta: '+₹6,150',
        deltaColor: AppColors.danger,
        rise: 1,
      )));
      expect(find.text('▲ +₹6,150'), findsOneWidget);
      final cell = tester.widget<Text>(find.text('▲ +₹6,150'));
      expect(cell.style!.color, AppColors.danger,
          reason: 'the verdict stays with the colour');
    });

    testWidgets('an unchanged row carries no arrow and no status ink',
        (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourPanel(
        child: GaiaDeltaRow(
          first: true,
          metric: 'Food cost / day',
          current: '₹12,800',
          scenario: '₹12,800',
          delta: '₹0',
        ),
      )));
      expect(find.text('₹0'), findsOneWidget);
      expect(find.textContaining('▲'), findsNothing);
      expect(find.textContaining('▼'), findsNothing);
    });
  });

  group('BICOLOUR · the split header', () {
    testWidgets('the scenario half sits at rest until a run has happened',
        (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourSplit(
        current: GaiaBicolourFace(
          eyebrow: 'Current · net per day',
          value: '₹16,200',
        ),
        scenario: GaiaBicolourFace(
          eyebrow: 'Scenario · net per day',
          value: '₹0',
          pending: true,
          detail: 'Nothing run yet.',
        ),
      )));
      expect(find.text('₹16,200'), findsOneWidget);
      // NOT '₹0' — a zero here would read as a projection of ruin.
      expect(find.text('₹0'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Nothing run yet.'), findsOneWidget);
    });

    testWidgets('both eyebrows clear AA — they are the only thing saying which '
        'half is real', (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourSplit(
        current: GaiaBicolourFace(eyebrow: 'Current', value: '₹1'),
        scenario: GaiaBicolourFace(eyebrow: 'Scenario', value: '₹2'),
      )));
      final dark = tester.widget<Text>(find.text('CURRENT'));
      final bright = tester.widget<Text>(find.text('SCENARIO'));
      expect(_contrast(dark.style!.color!, GaiaColors.bg),
          greaterThanOrEqualTo(4.5));
      expect(_contrast(bright.style!.color!, GaiaBicolourColors.ground),
          greaterThanOrEqualTo(4.5));
      // Specifically NOT the spec's --text-3, which measures 4.20 here.
      expect(dark.style!.color, isNot(GaiaColors.text3));
    });

    testWidgets('a loss on the champagne half is re-inked, never carried '
        'across as coral', (tester) async {
      await tester.pumpWidget(_host(const GaiaBicolourSplit(
        current: GaiaBicolourFace(
          eyebrow: 'Current',
          value: '−₹2,510',
          valueColor: GaiaColors.coral,
        ),
        scenario: GaiaBicolourFace(
          eyebrow: 'Scenario',
          value: '−₹10,309',
          valueColor: GaiaColors.coral,
        ),
      )));
      final dark = tester.widget<Text>(find.text('−₹2,510'));
      final bright = tester.widget<Text>(find.text('−₹10,309'));
      expect(dark.style!.color, GaiaColors.coral);
      expect(bright.style!.color, isNot(GaiaColors.coral));
      expect(_contrast(bright.style!.color!, GaiaBicolourColors.ground),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('the strata band grounds are readable', () {
    test('every ink a band actually uses clears AA on every band ground', () {
      for (final ground in GaiaStrataColors.bands) {
        for (final ink in [
          GaiaColors.text,
          GaiaColors.text2,
          GaiaStrataColors.tagCoral,
          GaiaColors.sage,
          GaiaColors.amber,
          GaiaColors.champagne,
        ]) {
          expect(_contrast(ink, ground), greaterThanOrEqualTo(4.5),
              reason: '$ink on $ground');
        }
      }
    });

    test("the spec's --text-3 does NOT clear on a band, which is why no "
        'caption uses it', () {
      // Recorded rather than assumed: 3.12:1 on the lightest band.
      expect(_contrast(GaiaColors.text3, GaiaStrataColors.bands.first),
          lessThan(4.5));
    });

    test('--coral is a near miss on the lightest band, and tagCoral is the '
        'same hue lifted past it', () {
      expect(_contrast(GaiaColors.coral, GaiaStrataColors.bands.first),
          lessThan(4.5));
      expect(_contrast(GaiaStrataColors.tagCoral, GaiaStrataColors.bands.first),
          greaterThanOrEqualTo(4.5));
      // Same hue, one step of lightness — not a different red.
      expect(
          (HSLColor.fromColor(GaiaStrataColors.tagCoral).hue -
                  HSLColor.fromColor(GaiaColors.coral).hue)
              .abs(),
          lessThan(3));
    });

    test('adjacent ramp fills are below the 3:1 that adjacent shapes want, '
        'which is why the painter draws a hairline between them', () {
      for (var i = 0; i + 1 < 3; i++) {
        expect(
            _contrast(GaiaStrataColors.ramp[i], GaiaStrataColors.ramp[i + 1]),
            lessThan(3.0));
      }
    });
  });
}
