// A PREVIEW RENDERER, not a test of behaviour.
//
// It lives in test/ but is deliberately NOT named *_test.dart, so `flutter
// test` never collects it: it renders pictures, it does not assert anything,
// and it must not count toward the suite or run in CI. Being under test/ is
// what lets it legitimately touch @visibleForTesting hooks. Run it by path
// when you want to look at the design:
//
//     flutter test test/gaia_preview.dart
//
// It writes PNGs to build/gaia_preview/.
//
// Why it exists: `flutter test` renders every glyph in Ahem (solid boxes)
// unless the real font files are explicitly loaded, so the whole point of the
// Gaia work — Cormorant Garamond numerals against Instrument Sans labels, at
// the right VARIABLE WEIGHTS — is invisible to an ordinary widget test. This
// loads the bundled TTFs through FontLoader and paints the real thing.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/section_header.dart';
import 'package:restaurant_owner_app/ui/widgets/stat_card.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      loader.addFont(
        File(p).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
    }
    await loader.load();
  }

  await load('Cormorant Garamond', [
    'assets/fonts/CormorantGaramond-Regular.ttf',
    'assets/fonts/CormorantGaramond-Italic.ttf',
  ]);
  await load('Instrument Sans', [
    'assets/fonts/InstrumentSans-Regular.ttf',
    'assets/fonts/InstrumentSans-Italic.ttf',
  ]);
}

Future<void> _shoot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')));
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('build/gaia_preview')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote build/gaia_preview/$name.png');
}

/// A stand-in for the real Overview: the same widgets `overviewModule` uses
/// (GaiaPageHeader, StatCard, SectionHeader, ForkCard, ForkButton, StatusChip),
/// fed fixed numbers so the picture is stable.
Widget _overview() => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (Gaia.isActive)
          const GaiaPageHeader(
            wordmark: 'Gaia Test',
            meta: 'Overview',
            title: 'Welcome,',
            titleEmphasis: 'Asha.',
            sub: 'Owner',
          )
        else ...[
          const Text('Welcome, Asha', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Gaia Test · Owner'),
          const SizedBox(height: 24),
        ],
        Row(children: [
          const Expanded(
            child: StatCard(
              value: '₹1,77,213.93',
              tag: 'MTD',
              caption: 'Revenue this month — all channels',
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: StatCard(
              value: '₹1,114.55',
              caption: 'Average per cover (APC), pre-tax',
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Expanded(
            child: StatCard(value: '4/72', unit: 'tables', caption: 'Tables occupied right now'),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: StatCard(value: '4.6', unit: '/ 5', caption: 'Average guest rating'),
          ),
        ]),
        const SizedBox(height: 28),
        const SectionHeader(title: 'Needs attention', count: 3),
        ForkCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (Gaia.isActive) ...[
              const GaiaListRow(
                first: true,
                title: 'Ingredients low on stock',
                detail: 'Carrot out · sprouts 1,000 mg · potato 6,000 mg',
                dotColor: GaiaColors.coral,
              ),
              const GaiaListRow(
                title: 'Table T1 served, cheque open 10 days',
                detail: '27 items · ₹14,187 · placed 25 Aug 16:26',
                value: '₹14,187',
                valueUnit: 'open',
                dotColor: GaiaColors.coral,
              ),
              const GaiaListRow(
                title: 'Printing needs the desktop app',
                detail: 'Thermal tickets pause while the Windows app is closed',
                dotColor: GaiaColors.champagne,
              ),
            ] else ...[
              const Text('Ingredients low on stock'),
              const SizedBox(height: 10),
              const Text('Table T1 served, cheque open 10 days'),
              const SizedBox(height: 10),
              const Text('Printing needs the desktop app'),
            ],
          ]),
        ),
        const SizedBox(height: 24),
        const SectionHeader(title: 'Best performing staff'),
        ForkCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (Gaia.isActive)
              const GaiaKeyValue(
                first: true,
                label: 'Gaia Tester',
                sub: '50 orders · ranked by attributed revenue',
                value: '₹1,68,842',
              )
            else
              const Text('Gaia Tester — ₹1,68,842'),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: const [
              StatusChip(label: 'On shift', color: GaiaColors.sage),
              StatusChip(label: '2 unsettled', color: GaiaColors.coral),
              InfoChip(icon: Icons.event, label: 'Fri 4 Sep'),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              ForkButton(label: 'Open analytics', onPressed: () {}),
              const SizedBox(width: 10),
              ForkButton.ghost(label: 'Export', onPressed: () {}),
              const SizedBox(width: 10),
              const ForkButton.ghost(label: 'Disabled'),
            ]),
          ]),
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AppearanceController persists every change. Without a mocked store,
  // SharedPreferences.getInstance() waits on a platform channel that never
  // answers under the test binding, and setDesignSystem() never returns.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget frame(Widget child) => RepaintBoundary(
        key: const ValueKey('shot'),
        child: GaiaScope(
          system: AppearanceController.instance.designSystem,
          child: MediaQuery(
          data: const MediaQueryData(size: Size(430, 1000)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: Gaia.isActive ? GaiaTheme.dark() : AppTheme.dark(),
            home: Scaffold(
              backgroundColor: AppColors.bg,
              body: SizedBox(width: 430, height: 1000, child: child),
            ),
          ),
          ),
        ),
      );

  // One system per test. Flipping mid-test and then awaiting toImage() again
  // wedges the fake-async zone in flutter_test (the flip ITSELF is fine — see
  // the 'flipping live' group in gaia_design_system_test.dart, which pumps the
  // switch in a live tree and settles). Independent renders sidestep it and
  // give two comparable pictures.

  testWidgets('render the Overview under Rustic Fork', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(860, 2000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    AppearanceController.instance.debugReset();
    await tester.pumpWidget(frame(_overview()));
    await tester.pumpAndSettle();
    await _shoot(tester, '01-overview-rustic');
  });

  testWidgets('render the Overview under Gaia', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(860, 2000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // unawaited: setDesignSystem flips the in-memory state and notifies
    // BEFORE it awaits persistence, so the design is already live here. Its
    // trailing SharedPreferences write is a real-async Future, and awaiting
    // one after tester.runAsync() (which _loadFonts uses) stalls in
    // flutter_test's fake-async zone — a harness wrinkle, not app behaviour.
    // The live flip is covered properly in gaia_design_system_test.dart.
    unawaited(AppearanceController.instance.setDesignSystem(DesignSystem.gaia));
    await tester.pumpWidget(frame(_overview()));
    await tester.pumpAndSettle();
    await _shoot(tester, '02-overview-gaia');
    AppearanceController.instance.debugReset();
  });

  testWidgets('render a type specimen so the variable weights are visible',
      (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(860, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    unawaited(AppearanceController.instance.setDesignSystem(DesignSystem.gaia));

    await tester.pumpWidget(frame(SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const GaiaWordmark(text: 'GAIA', section: 'Specimen'),
        const SizedBox(height: 20),
        // If the wght axis were not being driven, all six of these would look
        // identical (Cormorant's axis default is 300). They must not.
        for (final w in [300.0, 400.0, 500.0, 600.0, 700.0])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('1,77,213 Cormorant $w',
                style: GaiaType.serif(size: 30, weight: w)),
          ),
        const SizedBox(height: 16),
        for (final w in [400.0, 500.0, 600.0, 700.0])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('Instrument Sans $w — covers, cheques, prep time',
                style: GaiaType.sans(size: 15, weight: w)),
          ),
        const SizedBox(height: 20),
        const GaiaBigNumber('₹1,77,213.93'),
        const SizedBox(height: 8),
        Text('Forty-nine cheques settled tonight.', style: GaiaType.italNote()),
        const SizedBox(height: 24),
        GaiaStatRail(stats: const [
          GaiaStat(value: '4', unit: 'of 72', label: 'Seated'),
          GaiaStat(value: '24', unit: 'min', label: 'Avg prep'),
          GaiaStat(value: '2', label: 'Unsettled', color: GaiaColors.coral),
        ]),
        const SizedBox(height: 22),
        GaiaTabs(tabs: const ['Sales', 'Covers', 'Kitchen'], selected: 0, onSelected: (_) {}),
        const SizedBox(height: 22),
        Row(children: [
          GaiaButton(label: 'Settle bill', onPressed: () {}),
          const SizedBox(width: 12),
          GaiaButton(label: 'Export', kind: GaiaButtonKind.ghost, onPressed: () {}),
          const SizedBox(width: 16),
          GaiaToggle(value: true, onChanged: (_) {}),
          const SizedBox(width: 10),
          GaiaToggle(value: false, onChanged: (_) {}),
        ]),
        const SizedBox(height: 18),
        SizedBox(width: 260, child: GaiaSlider(value: 0.62, onChanged: (_) {})),
      ]),
    )));
    await tester.pumpAndSettle();
    await _shoot(tester, '03-type-specimen');

    AppearanceController.instance.debugReset();
  });
}
