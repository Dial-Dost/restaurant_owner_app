import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/theme/backdrop_style.dart';
import 'package:restaurant_owner_app/widgets/appearance_card.dart';

/// The Appearance card's wiring: every control must land on the controller —
/// the card is the ONLY place these knobs exist, so a dead control here is a
/// feature that silently does not exist (the exact bug class the
/// dead-tap-sweep hunts elsewhere).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppearanceController.instance.debugReset();
  });

  tearDown(() {
    AppearanceController.instance.debugReset();
  });

  Future<void> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: const Scaffold(
        body: SingleChildScrollView(child: AppearanceCard()),
      ),
    ));
    await tester.pump();
  }

  testWidgets('scheme swatch applies the scheme', (tester) async {
    await pumpCard(tester);
    expect(AppearanceController.instance.schemeId, 'rustic');

    await tester.tap(find.text('Midnight'));
    await tester.pump();
    expect(AppearanceController.instance.schemeId, 'midnight');
    expect(AppColors.bg, AppSchemes.midnight.bg);
  });

  testWidgets('accent swatch still applies the accent beside the new rows', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.text('Teal'));
    await tester.pump();
    expect(AppearanceController.instance.accentId, 'teal');
    expect(AppColors.copper, AppAccents.teal.base);
  });

  testWidgets('a custom wash hex applies through the hex field', (tester) async {
    await pumpCard(tester);
    // The first hex field on the card is the WASH row's.
    await tester.enterText(find.byType(TextField).first, '#ff69b4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(AppearanceController.instance.backdrop.wash, const Color(0xFFFF69B4));

    // Junk is ignored, not half-applied.
    await tester.enterText(find.byType(TextField).first, 'reddish');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(AppearanceController.instance.backdrop.wash, const Color(0xFFFF69B4));
  });

  testWidgets('sliders move angle/intensity; one tap returns to scheme default', (tester) async {
    await pumpCard(tester);
    final reset = find.text('Back to scheme default');

    // On the default, the reset control is present but disabled.
    // (bySubtype, because TextButton.icon builds a private TextButton
    // subclass that find.byType's exact-runtimeType match walks straight past.)
    expect(tester.widget<ButtonStyleButton>(
      find.ancestor(of: reset, matching: find.bySubtype<ButtonStyleButton>()).first,
    ).enabled, isFalse);

    // Drag the ANGLE slider off its default.
    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    await tester.pump();
    final moved = AppearanceController.instance.backdrop;
    expect(moved.angleDeg, isNot(BackdropStyle.defaultAngle));
    expect(moved.isDefault, isFalse);

    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pump();
    expect(AppearanceController.instance.backdrop, const BackdropStyle());
  });
}
