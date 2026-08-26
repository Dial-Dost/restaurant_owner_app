import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppearanceController.instance.debugReset();
  });

  tearDown(() {
    // Never leak a non-default accent into other test files.
    AppearanceController.instance.debugReset();
  });

  group('AppAccents catalogue', () {
    test('copper is the default and is byte-identical to the shipped ramp', () {
      expect(AppAccents.defaultId, 'copper');
      expect(AppAccents.copper.hi, const Color(0xFFE3B89B));
      expect(AppAccents.copper.base, const Color(0xFFC9997A));
      expect(AppAccents.copper.mid, const Color(0xFFA9795C));
      expect(AppAccents.copper.deep, const Color(0xFF7D5B47));
      expect(AppAccents.copper.shadow, const Color(0xFF4E3928));
      expect(AppAccents.copper.on, const Color(0xFF221510));
      expect(AppAccents.copper.glowBright, const Color(0xFFC2410C));
    });

    test('every accent hi/base stop clears WCAG AA 4.5:1 on the dark ground', () {
      double lum(Color c) {
        double chan(double v) =>
            v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b);
      }

      double contrast(Color a, Color b) {
        final la = lum(a), lb = lum(b);
        final hi = la > lb ? la : lb;
        final lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      expect(AppAccents.all.length, inInclusiveRange(6, 8));
      for (final a in AppAccents.all) {
        expect(contrast(a.hi, AppColors.bg), greaterThanOrEqualTo(4.5),
            reason: '${a.id}.hi must stay readable on the dark ground');
        expect(contrast(a.base, AppColors.bg), greaterThanOrEqualTo(4.5),
            reason: '${a.id}.base must stay readable on the dark ground');
      }
    });

    test('byId falls back to copper for junk ids', () {
      expect(AppAccents.byId('teal').id, 'teal');
      expect(AppAccents.byId('neon-zebra').id, 'copper');
      expect(AppAccents.byId(null).id, 'copper');
      expect(AppAccents.byId('').id, 'copper');
    });
  });

  group('AppearanceController persistence', () {
    test('setAccent persists and load restores it (device round-trip)', () async {
      await AppearanceController.instance.setAccent('teal');
      expect(AppearanceController.instance.accentId, 'teal');
      expect(AppColors.copper, AppAccents.teal.base);

      // Simulate a cold start: reset in-memory state, then load from prefs.
      AppearanceController.instance.debugReset();
      expect(AppColors.copper, AppAccents.copper.base);
      await AppearanceController.instance.load();
      expect(AppearanceController.instance.accentId, 'teal');
      expect(AppColors.copper, AppAccents.teal.base);
      expect(AppColors.copperHi, AppAccents.teal.hi);
      expect(AppColors.onCopper, AppAccents.teal.on);
    });

    test('a corrupt stored id loads as the copper default', () async {
      SharedPreferences.setMockInitialValues({'appearance.accent': 'not-a-real-accent'});
      await AppearanceController.instance.load();
      expect(AppearanceController.instance.accentId, 'copper');
      expect(AppColors.copper, AppAccents.copper.base);
    });

    test('load with no stored value keeps the copper default', () async {
      await AppearanceController.instance.load();
      expect(AppearanceController.instance.accentId, 'copper');
    });
  });

  group('accent recolours the widgets', () {
    testWidgets('changing the accent recolours a primary ForkButton', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Center(child: ForkButton(label: 'Save')),
        ),
      ));

      LinearGradient buttonGradient() {
        final containers = tester.widgetList<AnimatedContainer>(
          find.descendant(of: find.byType(ForkButton), matching: find.byType(AnimatedContainer)),
        );
        final deco = containers.first.decoration as BoxDecoration?;
        return deco!.gradient as LinearGradient;
      }

      // Shipped default: the copper gradient.
      expect(buttonGradient().colors.first, AppAccents.copper.hi);

      await AppearanceController.instance.setAccent('steel');
      // The app root listens to the controller; this bare test harness doesn't,
      // so rebuild the same tree the way the root would.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Center(child: ForkButton(label: 'Save')),
        ),
      ));

      expect(buttonGradient().colors.first, AppAccents.steel.hi);
      expect(buttonGradient().colors.first, isNot(AppAccents.copper.hi));
    });
  });
}
