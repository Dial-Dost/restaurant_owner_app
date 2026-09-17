import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/status_chip.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// The Sales Summary's order-type split, in the app (client item 10's review).
///
/// The Overview's Online sale jumps to the Sales Summary, and the web draws
/// that report's `by_order_type` as "By order type:" chips. The app fetched the
/// same payload and drew none of it, so the figure behind the tapped tile was
/// nowhere on the screen it led to. This pins the line: the web's words, the
/// server's rows in the server's order, both design systems, both platforms,
/// and a 360px phone at raised text without an overflow. An older backend that
/// sends no split gets no line.

class _FakeApi extends ApiClient {
  _FakeApi(this.summary);
  final Map<String, dynamic> summary;
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(const <String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'Gaia Global Vegetarian',
          'restaurantUsername': 'gaiaglobalvegetarian',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    if (method != 'GET') throw StateError('Reports must never write — saw $method $path');
    if (Uri.parse('http://x$path').path == '/reports/mis/sales-summary') return summary;
    throw ApiException('No fake route for $path', 404);
  }
}

Map<String, dynamic> _summary({Object? split = _split}) => {
      'meta': const {
        'report': 'sales_summary',
        'title': 'Sales Summary',
        'window': {'from': '2026-09-17', 'to': '2026-09-17', 'days': 1, 'source': 'range', 'clamped': false},
        'timezone': 'Asia/Kolkata',
        'outlet_scope': 'outlet',
        'outlet_name': 'GGV',
        'generated_at': '2026-09-17T10:00:00.000Z',
        'notes': <String>[],
      },
      'columns': const [
        {'key': 'bucket', 'label': 'Period', 'type': 'text'},
        {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
        {'key': 'grand_total', 'label': 'Gross', 'type': 'money', 'total': true},
      ],
      'totals': const {
        'item_total': 1250000, 'discount': 0, 'net': 1100000, 'service_charge': 50000, 'tax': 91289001.22,
        'round_off': 0, 'grand_total': 101289001.22, 'refund': 0, 'bills': 1234, 'covers': 4000, 'apc': 275, 'abv': 82000,
      },
      'bucket': 'day',
      'series': const [
        {'bucket': '2026-09-17', 'bills': 1234, 'grand_total': 101289001.22},
      ],
      'by_order_type': ?split,
    };

const Object _split = [
  {'order_type': 'dine_in', 'bills': 1200, 'grand_total': 99000000.0, 'share_pct': 97.74},
  {'order_type': 'delivery', 'bills': 30, 'grand_total': 2000000.22, 'share_pct': 1.97},
  {'order_type': 'other', 'bills': 3, 'grand_total': 280001.0, 'share_pct': 0.28},
  {'order_type': 'takeaway', 'bills': 1, 'grand_total': 9000.0, 'share_pct': null},
];

final _platforms = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android});

Future<_FakeApi> _mount(WidgetTester tester, DesignSystem system, Map<String, dynamic> summary) async {
  await tester.pumpWidget(const SizedBox());
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await AppearanceController.instance.setDesignSystem(system);
  m.misRememberReport('sales_summary');
  final api = _FakeApi(summary);
  final auth = AuthController(api: api);
  await auth.login('GGV', 'u', 'p');
  final rest = RestClient(auth);
  await tester.pumpWidget(GaiaScope(
    system: system,
    child: MaterialApp(
      theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
      home: ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Reports'],
        clearFocus: () {},
        child: Scaffold(backgroundColor: AppColors.bg, body: m.reportsModule(rest, rest.auth.profile!)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

Finder get _split$ => find.byKey(const ValueKey('mis-order-types'));

List<String> _chips(WidgetTester tester) => [
      for (final c in tester.widgetList<InfoChip>(find.descendant(of: _split$, matching: find.byType(InfoChip)))) c.label,
    ];

String _money(Object? v) => '₹${(v as num).toStringAsFixed(2)}';

void main() {
  setUp(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
  });
  tearDown(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    AppearanceController.instance.debugReset();
  });

  group('the chip text', () {
    test("is the web badge's: channel · gross (share)", () {
      expect(m.misOrderTypeChips(_split, _money), [
        'dine_in · ₹99000000.00 (97.7%)',
        'delivery · ₹2000000.22 (2.0%)',
        'other · ₹280001.00 (0.3%)',
        // No honest share is a dash, never 0%.
        'takeaway · ₹9000.00 (—)',
      ]);
    });

    test("keeps the server's order and skips what is not a row", () {
      expect(
        m.misOrderTypeChips([
          {'order_type': 'delivery', 'grand_total': 5, 'share_pct': 50},
          'junk',
          {'order_type': '  ', 'grand_total': 1, 'share_pct': 1},
          {'grand_total': 1},
          {'order_type': ' dine_in ', 'grand_total': 5, 'share_pct': 50},
        ], _money),
        ['delivery · ₹5.00 (50.0%)', 'dine_in · ₹5.00 (50.0%)'],
      );
      expect(m.misOrderTypeChips(null, _money), isEmpty);
      expect(m.misOrderTypeChips(const <dynamic>[], _money), isEmpty);
      expect(m.misOrderTypeChips({'order_type': 'delivery'}, _money), isEmpty);
    });

    test('the words are the web panel\'s, word for word', () {
      final web = File('../Restaurant_Dashboard_UI/src/app/dashboard/reports/context-panels.tsx');
      if (!web.existsSync()) {
        markTestSkipped('no Restaurant_Dashboard_UI checkout beside this one');
        return;
      }
      final src = web.readAsStringSync();
      expect(src, contains('>${m.kMisOrderTypeLabel}</span>'));
      // `{t.order_type} · {money(t.grand_total)} ({formatPercent(t.share_pct)})`
      expect(src, contains('{t.order_type} · <span className="ml-1 font-mono tabular-nums">{money(t.grand_total)}</span>'));
      expect(src, contains('({formatPercent(t.share_pct)})'));
      // And formatPercent is misPercent: one decimal, a dash for none.
      final lib = File('../Restaurant_Dashboard_UI/src/lib/mis-reports.ts').readAsStringSync();
      expect(lib, contains("if (value === null || value === undefined || value === '' || Number.isNaN(n)) {return '—';}"));
      expect(lib, contains(r'return `${sign}${n.toFixed(1)}%`;'));
    });
  });

  for (final system in DesignSystem.values) {
    group('[${system.id}]', () {
      testWidgets('the Sales Summary draws its order-type split, 360px to desktop, 1.0x and 1.3x', (tester) async {
        for (final width in const [360.0, 390.0, 800.0, 1400.0]) {
          for (final scale in const [1.0, 1.3]) {
            tester.view.physicalSize = Size(width, 1600);
            tester.view.devicePixelRatio = 1.0;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            final api = await _mount(tester, system, _summary());
            final where = '${width}px / ${scale}x';
            expect(tester.takeException(), isNull, reason: where);
            expect(api.calls.where((c) => c.startsWith('GET /reports/mis/sales-summary?')), isNotEmpty);
            expect(_split$, findsOneWidget, reason: where);
            await tester.ensureVisible(_split$);
            await tester.pumpAndSettle();
            expect(find.descendant(of: _split$, matching: find.text(m.kMisOrderTypeLabel)), findsOneWidget, reason: where);
            expect(_chips(tester), [
              'dine_in · ₹99000000.00 (97.7%)',
              'delivery · ₹2000000.22 (2.0%)',
              'other · ₹280001.00 (0.3%)',
              'takeaway · ₹9000.00 (—)',
            ], reason: where);
            // Every chip is whole on screen: nothing ellipsised, nothing past the edge.
            for (final c in tester.widgetList<InfoChip>(find.descendant(of: _split$, matching: find.byType(InfoChip)))) {
              expect(c.wrap, isTrue, reason: 'a figure is never cut');
            }
            for (final chip in tester.widgetList<Text>(
                find.descendant(of: _split$, matching: find.textContaining(' · ')))) {
              final box = tester.renderObject<RenderParagraph>(find.byWidget(chip));
              expect(box.didExceedMaxLines, isFalse, reason: '${chip.data} at $where');
            }
            final rect = tester.getRect(_split$);
            expect(rect.left, greaterThanOrEqualTo(0), reason: where);
            expect(rect.right, lessThanOrEqualTo(width), reason: where);
          }
        }
      }, variant: _platforms);

      testWidgets('on a desktop the split is on screen the moment the report opens', (tester) async {
        // The chrome above the grid is capped at 45% of the pane and scrolls
        // inside it; the split must be in view without that scroll.
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await _mount(tester, system, _summary());
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('reports-grid')), findsOneWidget, reason: 'the desktop layout');
        // Probed on its texts: a Wrap's own centre can be the gap between two chips.
        expect(find.descendant(of: _split$, matching: find.text(m.kMisOrderTypeLabel)).hitTestable(), findsOneWidget);
        expect(_chips(tester), hasLength(4));
        for (final c in _chips(tester)) {
          expect(find.descendant(of: _split$, matching: find.text(c)).hitTestable(), findsOneWidget, reason: c);
        }
      }, variant: _platforms);

      testWidgets('an older backend that sends no split gets no line', (tester) async {
        tester.view.physicalSize = const Size(1400, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        for (final split in const <Object?>[null, <dynamic>[]]) {
          await _mount(tester, system, _summary(split: split));
          expect(tester.takeException(), isNull);
          // Gaia sets tab labels in capitals.
          expect(find.textContaining(RegExp('sales summary', caseSensitive: false)), findsWidgets,
              reason: 'the report itself still draws');
          expect(find.text('₹101289001.22'), findsWidgets, reason: 'and its Gross');
          expect(_split$, findsNothing, reason: '$split');
          expect(find.text(m.kMisOrderTypeLabel), findsNothing);
        }
      }, variant: _platforms);
    });
  }
}
