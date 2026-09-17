import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/floor_state.dart';
import 'package:restaurant_owner_app/models/next_party.dart';
import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/models/role_scope.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/printed_bills.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/theme/contrast.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/floor_chips.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// CLIENT ITEMS 1 AND 2 (2.0.2) — THE WAITER'S FLOOR AFTER A PRINT.
///
/// (1) "In the waiter dashboard, if a bill is not settled, the table completely
/// vanishes; bills are settled only at night, so there should be a duplicate
/// table with the same number. If a bill is printed on a table (not settled),
/// there should still be an option to add more items onto the existing bill;
/// moving table should still be possible as well … different colour codings:
/// e.g. the fresh table 12 in green, and the table 12 whose bill has been
/// printed but not settled in orange."
///
/// (2) "On the waiter dashboard, Move table option needs to be implemented."
///
/// What this file holds, in the order of what it would cost to get wrong:
///
///   * AN ADDITION TO PRINTED PAPER IS A CHOICE. The orange table's first
///     control asks, offers the green seat instead, and only the confirmed pad
///     sends `add_to_printed_bill`. A refusal offers the same choice.
///   * A WAITER PRINTS AGAIN ONLY ONTO OUT-OF-DATE PAPER, and that print is an
///     UPDATED bill. A settle against out-of-date paper is warned, never
///     blocked, and recorded.
///   * MOVE TABLE IS A WAITER'S, never onto the party's own table family, never
///     queued offline; Move an order stays a senior's.
///   * THE COLOURS: five fixed inks per scheme, readable (4.5:1 on every
///     ground) and distinct (CIEDE2000 >= 12), the same values the web paints.
///   * ONE VOCABULARY with the web dashboard and the server, read off their own
///     source when the checkouts are beside this one.
///
/// Every widget case runs on Windows AND Android, under Rustic AND Gaia, and
/// under a light palette (Beige); the floor and the pad are also laid out at
/// 360dp.

// ------------------------------------------------------------------ the fake

typedef _Route = Object? Function(String path);

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.role = 'admin', this.actions = const ['*'], this.scope});

  final Map<String, _Route> routes;
  final String role;
  final List<String> actions;
  final Map<String, dynamic>? scope;

  /// Every write the server APPLIED.
  final List<({String method, String path, Object? body})> writes = [];

  /// Every write that reached the server, refused or not.
  final List<({String method, String path, Object? body})> attempts = [];

  /// Decides a write before it is applied: return an exception to refuse it.
  ApiException? Function(String path, Object? body)? refuse;

  /// Nothing reaches the server at all (a statusless failure), reads included.
  bool offline = false;

  /// Reads answer, writes do not.
  bool offlineWrites = false;

  final Map<String, Object? Function(Object? body)> replies = {};

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Global Vegetarian',
          'restaurantUsername': 'ggv',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'atsu',
          'emp_Fname': 'Atsu',
          'role': role,
          'role_all': [role],
          'scope': ?scope,
          'actions_set': actions,
          'action_names': const [
            'View Orders', 'Create Order', 'View Tables', 'Occupy Table', 'View Menu', 'View Bills',
          ],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (offline) throw ApiException('Connection refused', null);
    if (method != 'GET') {
      if (offlineWrites) throw ApiException('Connection refused', null);
      attempts.add((method: method, path: path, body: body));
      final refusal = refuse?.call(path, body);
      if (refusal != null) throw refusal;
      writes.add((method: method, path: path, body: body));
      final reply = replies[path];
      return reply == null ? <String, dynamic>{'success': true} : reply(body);
    }
    final keys = routes.keys.where(path.startsWith).toList()
      ..sort((a, z) => z.length.compareTo(a.length));
    if (keys.isEmpty) throw ApiException('No fake route for $path', 404);
    return routes[keys.first]!(path);
  }

  Iterable<({String method, String path, Object? body})> to(String path) =>
      writes.where((w) => w.path == path);

  Object? bodyOf(String fragment) => writes.lastWhere((w) => w.path.contains(fragment)).body;
}

// ---------------------------------------------------------------- fixtures --

const String _printedAt = '2026-09-16T08:02:54.000Z';

String get _clock => printedClockOf(RestaurantTime.wallOf(_printedAt), RestaurantTime.nowWall());

Map<String, dynamic> _row(
  String name, {
  String? parent,
  int? partyNo,
  bool seated = false,
  bool? hasOrder,
  bool printed = false,
  bool? stale,
  String? printedAs,
  bool reserved = false,
}) =>
    {
      'table_name': name,
      'parent_table': parent,
      'party_no': partyNo,
      'display_name': parent ?? name,
      'capacity': 4,
      'max_capacity': 4,
      'section': 'Main',
      'occupied': seated,
      'has_order': hasOrder ?? seated,
      'reserved': reserved,
      'num_covers': seated ? 4 : 1,
      'covers': seated ? 4 : 1,
      'table_total': seated ? 1050.0 : 0.0,
      'table_apc': seated ? 262.5 : 0.0,
      'apc_status': 'neutral',
      'print_count': printed ? 1 : 0,
      'bill_printed_at': printed ? _printedAt : null,
      'printed_at': printed ? _printedAt : null,
      'paper_stale': printed ? stale : null,
      'printed_as': printedAs,
    };

Map<String, dynamic> _printed(String name, {bool? stale = false, String? printedAs}) =>
    _row(name, seated: true, printed: true, stale: stale, printedAs: printedAs);

Map<String, dynamic> _seat(String root, {int n = 2, bool seated = false}) =>
    _row('$root #$n', parent: root, partyNo: n, seated: seated);

Map<String, dynamic> _bill({bool printed = true, bool? stale = false, double grand = 1050, double? printedTotal}) => {
      'bill_id': 'bill-1',
      'table_id': 'tbl-1',
      'total_amt': grand,
      'subtotal': grand,
      'discount': 0.0,
      'service_charge': 0.0,
      'service_charge_waived': false,
      'tax_total': 0.0,
      'grand_total': grand,
      'nc_total': 0.0,
      'covers': 4,
      'apc': grand / 4,
      'target_apc': 300.0,
      'apc_status': 'neutral',
      'order_ids': const ['order-1'],
      'items': const [
        {'name': 'Thali', 'price': 525.0, 'quantity': 2},
      ],
      'first_order_at': '2026-09-16T07:58:00Z',
      'last_order_at': '2026-09-16T07:58:00Z',
      'print_count': printed ? 1 : 0,
      'bill_printed_at': printed ? _printedAt : null,
      'printed_at': printed ? _printedAt : null,
      'paper_stale': printed ? stale : null,
      'printed_total': ?printedTotal,
      'printed_as': null,
    };

Map<String, _Route> _floor(List<Map<String, dynamic>> tables, {Map<String, dynamic>? bill}) => {
      '/get-tables': (_) => tables,
      '/table-assignments': (_) => <dynamic>[],
      '/get-bookings': (_) => <dynamic>[],
      '/table-sections': (_) => {
            'sections': [
              {'section': 'Main'},
            ],
          },
      // A next-party seat has no bill yet; every other table has [bill].
      '/bill-for-table': (path) => path.contains('%23') ? <String, dynamic>{'items': const []} : (bill ?? _bill()),
      '/restaurant/settings': (_) => {'kitchen_sections': <dynamic>[]},
      '/restaurant/profile': (_) => {'outlet_add': ''},
      '/restaurant/logo': (_) => <String, dynamic>{},
      '/menu': (_) => const [
            {'id': 'mi-1', 'name': 'Gulab Jamun', 'price': 120.0, 'category': 'Desserts'},
          ],
      '/bills/tenders': (_) => {
            'bill_id': 'bill-1',
            'grand_total': (bill ?? _bill())['grand_total'],
            'tenders': <dynamic>[],
            'tendered': 0.0,
            'outstanding': (bill ?? _bill())['grand_total'],
            'tips_total': 0.0,
            'payment_method': null,
            'payment_splits': <dynamic>[],
          },
      '/billing-counters': (_) => {'counters': <dynamic>[]},
    };

/// A waiter as a 2.0.2 server describes one: scoped, may move a table, may not
/// move an order or settle.
const Map<String, dynamic> _waiterScope = {
  'waiter_only': true,
  'move_table': true,
  'move_order': true, // the server's answer; the floor still keeps it a senior's
  'settle_bill': false,
};

_FakeApi _waiter(Map<String, _Route> routes, {Map<String, dynamic>? scope = _waiterScope}) =>
    _FakeApi(routes, role: 'waiter', actions: const ['a1'], scope: scope);

_FakeApi _owner(Map<String, _Route> routes) => _FakeApi(routes);

/// The refusal a 2.0.2 server answers a waiter's unconfirmed order with.
ApiException _billPrinted() => ApiException.fromBody({
      'error': "T1's bill has already been printed, so nothing more can be added to it. "
          'Take a new party\'s order on T1 (next party). If it is for the same guests, ask a manager to add it and reprint the bill.',
      'code': 'bill_printed',
      'table': 'T1',
      'next_party_table': 'T1 #2',
      'next_party_action': 'Take it on T1 (next party)',
      'add_to_printed_action': "Add to T1's printed bill",
      'print_count': 1,
    }, billPrintedStatus);

// ------------------------------------------------------------------- looks --

/// One platform x design system x palette the widget cases run under.
class _Look {
  const _Look(this.platform, this.system, {this.light = false});
  final TargetPlatform platform;
  final DesignSystem system;
  final bool light;
  @override
  String toString() => '${platform.name}/${system.name}${light ? '/beige' : ''}';
}

class _Looks extends TestVariant<_Look> {
  _Looks(this.values);

  @override
  final Set<_Look> values;

  _Look? current;

  @override
  String describeValue(_Look value) => value.toString();

  @override
  Future<Object?> setUp(_Look value) async {
    current = value;
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = value.platform;
    await AppearanceController.instance.setDesignSystem(value.system);
    if (value.light) await AppearanceController.instance.applyThemePick('beige');
    return previous;
  }

  @override
  Future<void> tearDown(_Look value, covariant TargetPlatform? memento) async {
    debugDefaultTargetPlatformOverride = memento;
    AppearanceController.instance.debugReset();
    current = null;
  }
}

final _Looks _looks = _Looks({
  const _Look(TargetPlatform.windows, DesignSystem.rustic),
  const _Look(TargetPlatform.android, DesignSystem.rustic),
  const _Look(TargetPlatform.windows, DesignSystem.gaia),
  const _Look(TargetPlatform.android, DesignSystem.gaia),
  const _Look(TargetPlatform.android, DesignSystem.rustic, light: true),
});

DesignSystem get _system => _looks.current?.system ?? DesignSystem.rustic;

// ------------------------------------------------------------------- hosts --

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Global Vegetarian', 'atsu', 'pw');
  return RestClient(auth);
}

Widget _host(Widget child) => GaiaScope(
      system: _system,
      child: MaterialApp(
        theme: _system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.active(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables', 'Orders'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mountFloor(WidgetTester tester, _FakeApi api, {Size size = const Size(1400, 1800)}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rest = await _signIn(api);
  await tester.pumpWidget(_host(m.tablesModule(rest, rest.auth.profile!)));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _open(WidgetTester tester, String table) async {
  await tester.tap(find.byKey(ValueKey('table-title-$table')));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  try {
    await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).last);
  } catch (_) {/* not on this sheet at all */}
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await _reveal(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _addAndSend(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('order-send')));
  await tester.pumpAndSettle();
}

Future<void> _answerCovers(WidgetTester tester, String covers) async {
  expect(find.text('How many guests at this table?'), findsOneWidget);
  await tester.enterText(find.byType(TextField).last, covers);
  await tester.tap(find.widgetWithText(FilledButton, 'Send order'));
  await tester.pumpAndSettle();
}

bool _reachable(WidgetTester tester, Finder finder) {
  final target = tester.renderObject(finder);
  return tester.hitTestOnBinding(tester.getCenter(finder)).path.any((e) => identical(e.target, target));
}

/// The FloorChip under [key] — the keyed widget itself, or the one it draws.
FloorChip _chip(WidgetTester tester, String key) => tester.widget<FloorChip>(
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(FloorChip), matchRoot: true).first);

/// A ForkButton by its LABEL: Gaia draws labels in upper case, so the painted
/// text is not what a test should look for.
Finder _fork(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

String _legend(WidgetTester tester, FloorState state) =>
    tester.widget<FloorLegendChip>(find.byKey(ValueKey('floor-legend-${state.name}'))).label;

File _sibling(String rel) => File('../$rel');

String? _read(String rel) {
  final f = _sibling(rel);
  return f.existsSync() ? f.readAsStringSync().replaceAll(String.fromCharCode(13), '') : null;
}

// ------------------------------------------------------ colour science --

List<double> _lab(Color c) {
  double lin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(c.r), g = lin(c.g), b = lin(c.b);
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

/// CIEDE2000 (Sharma, Wu and Dalal) — the web test's formula, line for line.
double _deltaE2000(Color c1, Color c2) {
  double rad(double d) => d * math.pi / 180;
  double deg(double r) => r * 180 / math.pi;
  final l1 = _lab(c1), l2 = _lab(c2);
  final cA = math.sqrt(l1[1] * l1[1] + l1[2] * l1[2]);
  final cB = math.sqrt(l2[1] * l2[1] + l2[2] * l2[2]);
  final cb = (cA + cB) / 2;
  final g = 0.5 * (1 - math.sqrt(math.pow(cb, 7) / (math.pow(cb, 7) + math.pow(25, 7))));
  final a1p = (1 + g) * l1[1], a2p = (1 + g) * l2[1];
  final c1p = math.sqrt(a1p * a1p + l1[2] * l1[2]);
  final c2p = math.sqrt(a2p * a2p + l2[2] * l2[2]);
  final h1p = (deg(math.atan2(l1[2], a1p)) + 360) % 360;
  final h2p = (deg(math.atan2(l2[2], a2p)) + 360) % 360;
  final dLp = l2[0] - l1[0];
  final dCp = c2p - c1p;
  var dh = h2p - h1p;
  if (c1p * c2p == 0) {
    dh = 0;
  } else if (dh > 180) {
    dh -= 360;
  } else if (dh < -180) {
    dh += 360;
  }
  final dHp = 2 * math.sqrt(c1p * c2p) * math.sin(rad(dh / 2));
  final lbp = (l1[0] + l2[0]) / 2;
  final cbp = (c1p + c2p) / 2;
  double hbp;
  if (c1p * c2p == 0) {
    hbp = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hbp = (h1p + h2p) / 2;
  } else if (h1p + h2p < 360) {
    hbp = (h1p + h2p + 360) / 2;
  } else {
    hbp = (h1p + h2p - 360) / 2;
  }
  final t = 1 - 0.17 * math.cos(rad(hbp - 30)) + 0.24 * math.cos(rad(2 * hbp)) +
      0.32 * math.cos(rad(3 * hbp + 6)) - 0.2 * math.cos(rad(4 * hbp - 63));
  final dth = 30 * math.exp(-math.pow((hbp - 275) / 25, 2));
  final rc = 2 * math.sqrt(math.pow(cbp, 7) / (math.pow(cbp, 7) + math.pow(25, 7)));
  final sl = 1 + (0.015 * math.pow(lbp - 50, 2)) / math.sqrt(20 + math.pow(lbp - 50, 2));
  final sc = 1 + 0.045 * cbp;
  final sh = 1 + 0.015 * cbp * t;
  final rt = -math.sin(rad(2 * dth)) * rc;
  return math.sqrt(math.pow(dLp / sl, 2) + math.pow(dCp / sc, 2) + math.pow(dHp / sh, 2) +
      rt * (dCp / sc) * (dHp / sh));
}

double _hue(Color c) => HSVColor.fromColor(c).hue;

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Map<String, Color> _inks(AppShellScheme s) => {
      'free': s.floorFree,
      'seated': s.floorSeated,
      'running': s.floorRunning,
      'printed': s.floorPrinted,
      'reserved': s.floorReserved,
      'nextParty': s.floorNextParty,
    };

final List<AppShellScheme> _everyScheme = [
  ...AppSchemes.all,
  GaiaColors.shellBridge,
  for (final t in LightTone.values) AppLightPalettes.of(t),
];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PrintedBills.instance.resetForTest();
    await Outbox.instance.debugReset();
  });
  tearDown(PrintedBills.instance.resetForTest);

  // ==========================================================================
  // THE RULES
  // ==========================================================================

  group('the rules', () {
    test('a tile\'s state: printed beats running beats seated; free is only free', () {
      FloorState s({bool seated = false, bool? hasOrder, bool printed = false, bool reserved = false}) =>
          floorStateOf(seated: seated, hasOrder: hasOrder, printed: printed, reserved: reserved);
      expect(s(seated: true, hasOrder: true, printed: true), FloorState.printed);
      expect(s(seated: true, hasOrder: false, printed: true), FloorState.printed,
          reason: 'the paper is out: that is the first thing to see');
      expect(s(seated: true, printed: true, reserved: true), FloorState.printed);
      expect(s(seated: true, hasOrder: true), FloorState.running);
      expect(s(seated: true), FloorState.running, reason: 'an older server with no has_order reads as it always did');
      expect(s(seated: true, hasOrder: false), FloorState.seated);
      expect(s(hasOrder: true), FloorState.running, reason: 'an order is somebody at the table');
      expect(s(reserved: true), FloorState.reserved);
      expect(s(printed: true), FloorState.free, reason: 'a print nobody is sitting behind is no bill');
      expect(s(printed: true, reserved: true), FloorState.reserved);
      expect(s(), FloorState.free);
      expect([for (final v in FloorState.values) v.word], ['Running', 'Bill printed', 'Seated', 'Reserved', 'Free']);
    });

    test('the legend: counts in the busy-first order for a senior, the key for a waiter', () {
      final states = [FloorState.free, FloorState.printed, FloorState.printed, FloorState.running, FloorState.free];
      expect([for (final r in floorLegend(states, withCounts: true)) r.label],
          ['1 Running', '2 Bill printed', '2 Free']);
      expect([for (final r in floorLegend(states, withCounts: false)) r.label],
          ['Running', 'Bill printed', 'Seated', 'Reserved', 'Free']);
      expect(floorLegend(const [], withCounts: true), isEmpty);
    });

    test('the "#2" badge, the print clock and the printed chips', () {
      expect(nextPartyBadge(2), '#2');
      expect(nextPartyBadge(13), '#13');
      expect(nextPartyBadge(2.0), '#2');
      for (final v in <Object?>[null, 1, 0, -2, 2.5, '2', double.infinity, double.nan]) {
        expect(nextPartyBadge(v), isNull, reason: '$v');
      }
      final printed = DateTime.utc(2026, 9, 16, 13, 32);
      expect(printedClockOf(printed, DateTime.utc(2026, 9, 16, 23, 59)), '13:32');
      expect(printedClockOf(printed, DateTime.utc(2026, 9, 17, 0, 1)), '16/09 13:32');
      expect(printedClockOf(printed, DateTime.utc(2027, 9, 16, 13, 32)), '16/09 13:32');
      expect(printedClockOf(null, printed), '');
      expect(printedTileChips(printedClock: '13:32', paperStale: true, printedAs: '12'),
          ['Printed 13:32', 'Updated — print again', 'Printed as 12']);
      expect(printedTileChips(printedClock: '', paperStale: null, printedAs: ' '), ['Printed']);
      expect(printedTileChips(printedClock: '13:32', paperStale: false), ['Printed 13:32']);
    });

    test('the paper fields are read as the server sent them, and nothing else', () {
      expect(paperStaleOf({'paper_stale': true}), isTrue);
      expect(paperStaleOf({'paper_stale': false}), isFalse);
      for (final v in <Object?>[null, 'true', 1]) {
        expect(paperStaleOf({'paper_stale': v}), isNull, reason: '$v');
      }
      expect(paperStaleOf(null), isNull);
      expect(printedAsOf({'printed_as': ' 12 '}), '12');
      expect(printedAsOf({'printed_as': null}), isNull);
      expect(printedTotalOf({'printed_total': 2100}), 2100.0);
      expect(printedTotalOf({'printed_total': '2100.50'}), 2100.5);
      expect(printedTotalOf(<String, dynamic>{}), isNull, reason: 'a waiter is never sent it');
    });

    test('the settle warning never fires on a guess, and says the two totals when it has them', () {
      String money(double v) => '₹${v.toStringAsFixed(2)}';
      expect(stalePaperSettleWarning(paperStale: false, money: money), isNull);
      expect(stalePaperSettleWarning(paperStale: null, money: money), isNull);
      expect(
          stalePaperSettleWarning(
              paperStale: true, printedClock: '13:32', printedTotal: 2100, grandTotal: 2220, money: money),
          'The printed bill (13:32) shows ₹2100.00; the bill is now ₹2220.00. '
          'Print the updated bill before taking payment.');
      expect(stalePaperSettleWarning(paperStale: true, money: money),
          'The printed bill no longer matches the bill. Print the updated bill before taking payment.');
    });

    test('the sentences', () {
      expect(printedStaysMessage(tableSentence: '12', root: '12'),
          "12's bill is printed. 12 stays on your floor in orange until a manager settles it. "
          'New guests at 12: use the green 12.');
      expect(printedStaysMessage(tableSentence: '12 (next party)', root: '12', hasGreen: false),
          "12 (next party)'s bill is printed. 12 (next party) stays on your floor in orange until a manager settles it.");
      expect(printedPartyMoveNote('12', '20'),
          "The printed bill moves with them. The guest's paper still says 12; the bill will show as 20 (printed as 12).");
      expect(addToPrintedBillLabel('12'), "Add to 12's printed bill");
      expect(addToPrintedBillLabel('12 #2', parentTable: '12'), "Add to 12 (next party)'s printed bill");
      expect(useGreenTableLabel(' 12 '), 'Use green 12');
      expect(addingToPrintedBillStrip('12 #2'), "Adding to 12 (next party)'s printed bill");
      expect(addToPrintedBillConfirm(table: '12', printedClock: '13:32', hasGreen: true),
          "12's bill was printed at 13:32. These items go on that bill and it must be printed again. "
          'New guests? Use the green 12.');
      expect(addToPrintedBillConfirm(table: '12 #2', hasGreen: true),
          "12 (next party)'s bill has been printed. These items go on that bill and it must be printed again. "
          'New guests? Use the green 12.');
      expect(addToPrintedBillConfirm(table: '12', hasGreen: false),
          "12's bill has been printed. These items go on that bill and it must be printed again.");
      expect(replacesBillLine('13:32'), 'Replaces the bill printed 13:32');
      expect(replacesBillLine(''), 'Replaces an earlier printed bill');
    });

    test('the green seat: the free root first, else the lowest free next-party seat, never the family\'s busy ones', () {
      bool free(Map r) => r['occupied'] != true;
      final t12 = _printed('12');
      expect(greenSeatFor(t12, [t12, _seat('12', n: 3), _seat('12'), _row('13')], free)!['table_name'], '12 #2');
      final seat2 = {..._printed('12 #2'), 'parent_table': '12', 'party_no': 2};
      expect(greenSeatFor(seat2, [_row('12'), seat2, _seat('12', n: 3)], free)!['table_name'], '12',
          reason: 'the free root is the green 12');
      expect(greenSeatFor(t12, [t12, _seat('12', seated: true), _row('13')], free), isNull);
      expect(greenSeatFor(t12, [t12, _seat('120'), _row('13')], free), isNull, reason: '"120 #2" is not 12\'s');
      expect(sameTableFamily(_row('12'), _seat('12')), isTrue);
      expect(sameTableFamily(_seat('12'), _seat('12', n: 3)), isTrue);
      expect(sameTableFamily(_row('Patio 4'), _row('patio 4')), isTrue);
      expect(sameTableFamily(_row('12'), _seat('120')), isFalse);
      expect(sameTableFamily(_row('12'), _row('13')), isFalse);
    });

    test('the refusal carries the "add to printed bill" answer only when the server offered it', () {
      final r = BillPrintedRefusal.parse(_billPrinted().body)!;
      expect(r.addToPrintedLabel, "Add to T1's printed bill");
      expect(r.actionLabel, 'Take it on T1 (next party)');
      final old = BillPrintedRefusal.parse({...?_billPrinted().body, 'add_to_printed_action': null})!;
      expect(old.addToPrintedLabel, isNull, reason: 'a 2.0.1 server offers no such thing');
    });

    test('the two moves: the server answers, the floor keeps Move an order a senior\'s', () {
      Profile who(String role, Map<String, dynamic>? scope, {List<String> actions = const ['a1']}) =>
          Profile.fromJson({
            'role': role,
            'role_all': [role],
            'actions_set': actions,
            'action_names': const ['View Tables'],
            'scope': ?scope,
          });
      final w = FloorScope.of(who('waiter', _waiterScope));
      expect([w.moveTable, w.moveOrder], [true, false]);
      expect(Profile.fromJson({'scope': _waiterScope}).said(Capability.moveTable), isTrue);
      expect(Profile.fromJson({'scope': _waiterScope}).said(Capability.moveOrder), isTrue);
      // A backend older than the flags: the pre-2.0.2 answer, a senior's.
      final old = FloorScope.of(who('waiter', {'waiter_only': true}));
      expect([old.moveTable, old.moveOrder], [false, false]);
      final denied = FloorScope.of(who('waiter', {..._waiterScope, 'move_table': false}));
      expect(denied.moveTable, isFalse, reason: 'the server said no');
      final owner = FloorScope.of(who('admin', null, actions: const ['*']));
      expect([owner.moveTable, owner.moveOrder], [true, true]);
      final manager = FloorScope.of(who('manager', {'waiter_only': false, 'move_table': false, 'move_order': false}));
      expect([manager.moveTable, manager.moveOrder], [false, false], reason: 'the flags win for a senior too');
      final managerOld = FloorScope.of(who('manager', null));
      expect([managerOld.moveTable, managerOld.moveOrder], [true, true]);
      expect(Capability.moveTable.wireKey, 'move_table');
      expect(Capability.moveOrder.wireKey, 'move_order');
    });
  });

  // ==========================================================================
  // THE COLOURS
  // ==========================================================================

  group('the floor inks', () {
    for (final s in _everyScheme) {
      test('${s.id}: every ink reads at 4.5:1 on every ground, and the chip on its card', () {
        final grounds = {
          'bg': s.bg, 'bgDeep': s.bgDeep, 'surface': s.surface, 'card': s.card,
          'cardTop': s.cardTop, 'cardBottom': s.cardBottom, 'cardRaised': s.cardRaised, 'inset': s.inset,
        };
        final failures = <String>[];
        _inks(s).forEach((state, ink) {
          grounds.forEach((g, c) {
            final r = contrastRatio(ink, c);
            if (r < 4.5) failures.add('$state/$g ${r.toStringAsFixed(2)}');
          });
        });
        // The tile's own wash, under the name and figures it carries.
        for (final state in FloorState.values) {
          final ink = _inks(s)[state.name]!;
          final wash = Color.alphaBlend(ink.withValues(alpha: floorWash(state)), s.card);
          final r = contrastRatio(s.textPrimary, wash);
          if (r < 4.5) failures.add('textPrimary on ${state.name} wash ${r.toStringAsFixed(2)}');
        }
        expect(failures, isEmpty);
      });

      test('${s.id}: every pair of inks is at least 12 apart (CIEDE2000)', () {
        final entries = _inks(s).entries.toList();
        final close = <String>[];
        for (var i = 0; i < entries.length; i++) {
          for (var j = i + 1; j < entries.length; j++) {
            final d = _deltaE2000(entries[i].value, entries[j].value);
            if (d < 12) close.add('${entries[i].key}~${entries[j].key} ${d.toStringAsFixed(1)}');
          }
        }
        expect(close, isEmpty);
      });

      test('${s.id}: free is green and printed is orange — the client\'s own two words', () {
        expect(_hue(s.floorFree), inInclusiveRange(90, 150));
        expect(_hue(s.floorPrinted), inInclusiveRange(15, 40));
      });
    }

    test('the colour science is the investigation\'s (sanity)', () {
      expect(contrastRatio(Colors.white, Colors.black), closeTo(21, 1e-6));
      expect(_deltaE2000(const Color(0xFFC9997A), const Color(0xFFD9A962)), closeTo(11.5, 0.5));
      expect(_deltaE2000(const Color(0xFFE2C458), const Color(0xFFB9B4A8)), closeTo(21.1, 0.5));
      expect(_deltaE2000(const Color(0xFF8FA3B8), const Color(0xFF8FA3B8)), 0);
    });

    test('never the accent: every dark scheme carries the same inks, whatever the accent', () {
      for (final s in AppSchemes.all) {
        expect(_inks(s).map((k, v) => MapEntry(k, _hex(v))), _inks(AppSchemes.rustic).map((k, v) => MapEntry(k, _hex(v))));
      }
      for (final a in AppAccents.all) {
        AppColors.applyAccent(a);
        expect(AppColors.floorRunning, AppSchemes.rustic.floorRunning, reason: a.id);
        expect(AppColors.floorFree, AppSchemes.rustic.floorFree, reason: a.id);
      }
      AppColors.applyAccent(AppAccents.copper);
    });

    test('the web paints exactly these inks (Restaurant_Dashboard_UI src/lib/floor-state.ts)', () {
      final src = _read('Restaurant_Dashboard_UI/src/lib/floor-state.ts');
      if (src == null) {
        markTestSkipped('no Restaurant_Dashboard_UI checkout beside this one');
        return;
      }
      Map<String, String> web(String scheme) {
        final m = RegExp('$scheme: \\{([^}]*)\\}').firstMatch(src);
        expect(m, isNotNull, reason: 'FLOOR_INKS.$scheme is gone');
        return {
          for (final e in RegExp(r"(\w+): '(#[0-9A-Fa-f]{6})'").allMatches(m!.group(1)!))
            e.group(1)!: e.group(2)!.toUpperCase(),
        };
      }

      Map<String, String> app(AppShellScheme s) => _inks(s).map((k, v) => MapEntry(k, _hex(v)));
      expect(app(AppSchemes.rustic), web('dark'));
      expect(app(GaiaColors.shellBridge), web('gaia'));
      for (final t in LightTone.values) {
        expect(app(AppLightPalettes.of(t)), web('light'), reason: t.id);
      }
      // …and the words.
      for (final s in FloorState.values) {
        expect(src, contains("'${s.word}'"), reason: s.word);
      }
      expect(src, contains("export const PAPER_STALE_CHIP = '$paperStaleChip';"));
    });
  });

  // ==========================================================================
  // ONE VOCABULARY — the web's and the server's own source
  // ==========================================================================

  group('the same words as the web and the server', () {
    test('web: next-party.ts, bill-print-state.ts, table-move.ts', () {
      final np = _read('Restaurant_Dashboard_UI/src/lib/next-party.ts');
      final bps = _read('Restaurant_Dashboard_UI/src/lib/bill-print-state.ts');
      final tm = _read('Restaurant_Dashboard_UI/src/lib/table-move.ts');
      if (np == null || bps == null || tm == null) {
        markTestSkipped('no Restaurant_Dashboard_UI checkout beside this one');
        return;
      }
      expect(np, contains("export const ADD_TO_PRINTED_BILL_KEY = '$addToPrintedBillKey';"));
      expect(np, contains("export const ADD_TO_PRINTED_BILL_ACTION = '$addToPrintedBillAction';"));
      expect(np, contains("`Add to \${tableSentenceName(table, parentTable)}'s printed bill`"));
      expect(np, contains('`Use green \${root.trim()}`'));
      expect(np, contains("`\${named}'s bill was printed at \${when}.`"));
      expect(np, contains("`\${named}'s bill has been printed.`"));
      expect(np, contains('` New guests? Use the green \${root}.`'));
      expect(np, contains('These items go on that bill and it must be printed again.\${green}'));
      expect(np, contains("`Adding to \${tableSentenceName(table, parentTable)}'s printed bill`"));
      expect(bps, contains("export const PRINT_UPDATED_BILL_LABEL = '$printUpdatedBillLabel';"));
      expect(bps, contains("export const SETTLE_ANYWAY_LABEL = '$settleAnywayLabel';"));
      expect(bps, contains("export const UPDATED_BILL_MARKER = '$updatedBillMarker';"));
      expect(bps, contains('`\${paper} shows \${money(printed)}; the bill is now \${money(now)}.`'));
      expect(bps, contains('`\${paper} no longer matches the bill.`'));
      expect(bps, contains('Print the updated bill before taking payment.'));
      expect(tm, contains("The printed bill moves with them. The guest's paper still says \${from.trim()}; "
          'the bill will show as \${to.trim()} (printed as \${from.trim()}).'));
    });

    test('server: the flag, the label, the banner and the two capabilities', () {
      final np = _read('Restaurant_Backend/next_party.ts');
      final digest = _read('Restaurant_Backend/bill_paper_digest.ts');
      final shared = _read('Restaurant_Backend/routes/_shared.ts');
      if (np == null || digest == null || shared == null) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      expect(np, contains('export const ADD_TO_PRINTED_BILL_KEY = "$addToPrintedBillKey";'));
      expect(np, contains("return `Add to \${tableSentenceName(table, parentTable ?? null)}'s printed bill`;"));
      expect(np, contains('add_to_printed_action: input.guest || write !== "order" ? null'));
      expect(digest, contains('export const UPDATED_BILL_MARKER = "$updatedBillMarker";'));
      expect(digest, contains('`Replaces the bill printed \${c}` : "Replaces an earlier printed bill"'));
      for (final c in [Capability.moveTable, Capability.moveOrder]) {
        expect(shared, contains('${c.wireKey}:'), reason: '${c.wireKey} is not in sessionCapabilities');
      }
    });
  });

  // ==========================================================================
  // THE FLOOR
  // ==========================================================================

  group('the floor after a print', () {
    testWidgets('a waiter: the printed T1 orange with its time and "Updated", the green T1 beside it, the key',
        (tester) async {
      for (final size in const [Size(1400, 1800), Size(360, 800)]) {
        await _mountFloor(
            tester, _waiter(_floor([_printed('T1', stale: true, printedAs: 'T9'), _seat('T1'), _row('T2')])),
            size: size);
        expect(tester.takeException(), isNull, reason: 'overflow at ${size.width}');
        // The look really is the one named: its own scheme's inks are painted.
        final look = _looks.current!;
        final scheme = look.light
            ? AppLightPalettes.beige
            : look.system == DesignSystem.gaia
                ? GaiaColors.shellBridge
                : AppSchemes.rustic;
        expect(AppColors.floorPrinted, scheme.floorPrinted, reason: '$look');
        expect(find.byKey(const ValueKey('table-title-T1')), findsOneWidget);
        expect(find.byKey(const ValueKey('table-title-T1 #2')), findsOneWidget);
        expect(find.text('T1'), findsNWidgets(2));
        expect(_chip(tester, 'table-T1-Bill printed').color, AppColors.floorPrinted);
        expect(_chip(tester, 'table-T1 #2-Free').color, AppColors.floorFree);
        expect(_chip(tester, 'table-T2-Free').color, AppColors.floorFree, reason: 'every free table is green');
        expect(_chip(tester, 'next-party-chip-T1 #2').label, '#2');
        expect(_chip(tester, 'next-party-chip-T1 #2').color, AppColors.floorNextParty);
        expect(find.byKey(ValueKey('table-printed-T1-Printed $_clock')), findsOneWidget);
        expect(find.byKey(const ValueKey('table-paper-stale-T1')), findsOneWidget);
        expect(find.byKey(const ValueKey('table-printed-T1-Printed as T9')), findsOneWidget);
        // The waiter's colour key, and no house-wide counts.
        expect(find.byKey(const ValueKey('floor-colour-key')), findsOneWidget);
        expect(find.byKey(const ValueKey('floor-legend-printed')), findsNothing);
        expect(find.textContaining('every table you printed'), findsNothing);
      }
    }, variant: _looks);

    testWidgets('an owner: the backlog is counted, and a tap shows only the printed tables', (tester) async {
      await _mountFloor(
          tester, _owner(_floor([_printed('T1'), _seat('T1'), _row('T2', seated: true), _printed('T3'), _row('T4')])));
      expect(_legend(tester, FloorState.printed), '2 Bill printed');
      expect(_legend(tester, FloorState.running), '1 Running');
      expect(_legend(tester, FloorState.free), '1 Free', reason: 'the idle next-party seat is not a free table');
      expect(find.byKey(const ValueKey('floor-legend-seated')), findsNothing);
      expect(find.byKey(const ValueKey('floor-colour-key')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('floor-legend-printed')));
      await tester.pumpAndSettle();
      for (final t in ['T1', 'T3']) {
        expect(find.byKey(ValueKey('table-title-$t')), findsOneWidget, reason: t);
      }
      for (final t in ['T2', 'T4', 'T1 #2']) {
        expect(find.byKey(ValueKey('table-title-$t')), findsNothing, reason: '$t is not in the backlog');
      }
      await tester.tap(find.byKey(const ValueKey('floor-legend-printed')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-title-T4')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-title-T1 #2')), findsOneWidget);
    }, variant: _looks);
  });

  // ==========================================================================
  // ADDING TO A PRINTED BILL
  // ==========================================================================

  group('adding to a printed bill is a choice', () {
    testWidgets('the orange sheet leads with it; the confirm offers the green T1; that pad sends the flag',
        (tester) async {
      final api = _waiter(_floor([_printed('T1'), _seat('T1')]));
      api.replies['/orders'] = (_) => {
            'success': true,
            'reprint_needed': true,
            'reprint_message': "T1's bill was already printed, so the paper no longer shows this. "
                'Reprint the bill before the guest pays.',
            'reprint_table': 'T1',
          };
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      expect(find.byKey(const ValueKey('table-add-order')), findsNothing);
      final add = find.byKey(const ValueKey('table-add-to-printed'));
      expect(add, findsOneWidget);
      expect(find.byKey(const ValueKey('table-printed-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-print-bill')), findsNothing, reason: 'the paper is up to date');
      expect(find.byKey(const ValueKey('table-print-spent')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-move-party')), findsOneWidget);
      expect(tester.getTopLeft(add).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('table-print-spent'))).dy));

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-to-printed-confirm')), findsOneWidget);
      expect(find.text("Add to T1's printed bill"), findsOneWidget);
      expect(find.text(addToPrintedBillConfirm(table: 'T1', printedClock: _clock, hasGreen: true)), findsOneWidget);
      expect(find.text('Use green T1'), findsOneWidget);
      expect(api.writes, isEmpty, reason: 'asking wrote something');

      await tester.tap(find.byKey(const ValueKey('add-to-printed-go')));
      await tester.pumpAndSettle();
      expect(find.byType(OrderEntryScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('order-adding-to-printed')), findsOneWidget);
      expect(find.text("Adding to T1's printed bill"), findsOneWidget);

      await _addAndSend(tester);
      expect(api.writes.map((w) => w.path).toList(), ['/orders'], reason: 'no seating: T1 is seated');
      final body = api.to('/orders').single.body as Map;
      expect(body['table'], 'T1');
      expect(body[addToPrintedBillKey], isTrue);
      // The pad closed, and the reprint line offers the UPDATED print.
      expect(find.byType(OrderEntryScreen), findsNothing);
      await tester.pump();
      expect(find.byKey(const ValueKey('reprint-needed')), findsOneWidget);
      expect(find.text('Print updated bill'), findsOneWidget);
      await tester.tap(find.text('Print updated bill'));
      await tester.pumpAndSettle();
      expect((api.to('/print/bill').single.body as Map)['table_name'], 'T1');
    }, variant: _looks);

    testWidgets('"Use green T1" takes the order to the next party\'s seat, seated, with no flag', (tester) async {
      final api = _waiter(_floor([_printed('T1'), _seat('T1')]));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      await _tapKey(tester, 'table-add-to-printed');
      await tester.tap(find.byKey(const ValueKey('add-to-printed-use-green')));
      await tester.pumpAndSettle();
      expect(find.text('New order · T1 (next party)'), findsOneWidget);
      expect(find.byKey(const ValueKey('order-adding-to-printed')), findsNothing);
      await _addAndSend(tester);
      await _answerCovers(tester, '2');
      expect(api.writes.map((w) => w.path).toList(), ['/occupy-table', '/orders']);
      expect((api.to('/occupy-table').single.body as Map)['table_name'], 'T1 #2');
      final body = api.to('/orders').single.body as Map;
      expect(body['table'], 'T1 #2');
      expect(body.containsKey(addToPrintedBillKey), isFalse);
    }, variant: _looks);

    testWidgets('Cancel writes nothing; a busy family offers no green seat; an owner is asked too', (tester) async {
      final api = _waiter(_floor([_printed('T1'), _seat('T1', seated: true)]));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      await _tapKey(tester, 'table-add-to-printed');
      expect(find.byKey(const ValueKey('add-to-printed-use-green')), findsNothing);
      expect(find.text(addToPrintedBillConfirm(table: 'T1', printedClock: _clock, hasGreen: false)), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(OrderEntryScreen), findsNothing);
      expect(api.writes, isEmpty);

      final owner = _owner(_floor([_printed('T1'), _seat('T1')]));
      await _mountFloor(tester, owner);
      await _open(tester, 'T1');
      final add = find.byKey(const ValueKey('table-manager-add-order'));
      await _reveal(tester, add);
      expect(tester.widget<ForkButton>(add).label, addToPrintedBillAction);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-to-printed-confirm')), findsOneWidget);
    }, variant: _looks);

    testWidgets('an unprinted table is ordered on exactly as before: no question, no flag', (tester) async {
      final api = _waiter(_floor([_row('T1', seated: true)], bill: _bill(printed: false)));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      expect(find.byKey(const ValueKey('table-add-to-printed')), findsNothing);
      await _tapKey(tester, 'table-add-order');
      expect(find.byKey(const ValueKey('add-to-printed-confirm')), findsNothing);
      await _addAndSend(tester);
      expect((api.to('/orders').single.body as Map).containsKey(addToPrintedBillKey), isFalse);
    }, variant: _looks);
  });

  group('the pad, when a 2.0.2 server refuses an unconfirmed order', () {
    Future<_FakeApi> pad(WidgetTester tester, {Size size = const Size(420, 900), bool keyboard = false}) async {
      final api = _waiter(_floor([_printed('T1'), _seat('T1')]))
        ..refuse = (path, body) =>
            path == '/orders' && (body as Map?)?[addToPrintedBillKey] != true ? _billPrinted() : null;
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rest = await _signIn(api);
      await tester.pumpWidget(_host(Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => Navigator.push<bool>(
              ctx,
              MaterialPageRoute(builder: (_) => OrderEntryScreen(rest: rest, tableName: 'T1')),
            ),
            child: const Text('open pad'),
          ),
        ),
      )));
      await tester.tap(find.text('open pad'));
      await tester.pumpAndSettle();
      if (keyboard) {
        // The usual flow on a phone: type in the search, Add, Send — with the
        // keyboard still up when the refusal arrives.
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await tester.showKeyboard(find.byKey(const ValueKey('order-search')));
        await tester.enterText(find.byKey(const ValueKey('order-search')), 'gul');
        await tester.pumpAndSettle();
      }
      await _addAndSend(tester);
      return api;
    }

    testWidgets('both answers in ONE row; "Add to T1\'s printed bill" sends the same cart with the flag',
        (tester) async {
      final api = await pad(tester);
      expect(api.writes, isEmpty);
      final take = find.byKey(const ValueKey('order-take-on-next-party'));
      final add = find.byKey(const ValueKey('order-add-to-printed'));
      expect(take, findsOneWidget);
      expect(add, findsOneWidget);
      expect(tester.getCenter(add).dy, closeTo(tester.getCenter(take).dy, 1), reason: 'not one row');
      expect(find.text("Add to T1's printed bill"), findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(api.attempts.map((w) => w.path).toList(), ['/orders', '/orders']);
      final sent = api.to('/orders').single.body as Map;
      expect(sent['table'], 'T1');
      expect(sent[addToPrintedBillKey], isTrue);
      expect((sent['items'] as List).single['id'], 'mi-1', reason: 'the same cart');
      expect(find.byType(OrderEntryScreen), findsNothing);
    }, variant: _looks);

    testWidgets('a 360dp phone with the keyboard up: nothing overflows and both answers are reachable',
        (tester) async {
      final api = await pad(tester, size: const Size(360, 640), keyboard: true);
      expect(tester.takeException(), isNull, reason: 'the header overflowed');
      expect(find.byKey(const ValueKey('order-bill-printed')), findsOneWidget);
      for (final k in ['order-take-on-next-party', 'order-add-to-printed', 'order-send']) {
        expect(_reachable(tester, find.byKey(ValueKey(k))), isTrue, reason: '$k is out of reach');
      }
      // And it works from there.
      await tester.tap(find.byKey(const ValueKey('order-add-to-printed')));
      await tester.pumpAndSettle();
      expect((api.to('/orders').single.body as Map)[addToPrintedBillKey], isTrue);
    }, variant: _looks);
  });

  // ==========================================================================
  // PRINTING AGAIN
  // ==========================================================================

  group('a waiter prints again only onto out-of-date paper', () {
    testWidgets('"Print updated bill" is there only when the server says stale, and it prints', (tester) async {
      for (final stale in <bool?>[false, null]) {
        final api = _waiter(_floor([_printed('T1', stale: stale)], bill: _bill(stale: stale)));
        await _mountFloor(tester, api);
        await _open(tester, 'T1');
        expect(find.byKey(const ValueKey('table-print-bill')), findsNothing, reason: 'paper_stale=$stale');
        expect(find.byKey(const ValueKey('table-print-spent')), findsOneWidget);
      }
      final api = _waiter(_floor([_printed('T1', stale: true), _seat('T1')], bill: _bill(stale: true)))
        ..replies['/print/bill'] = (_) => {'success': true, 'next_party_table': 'T1 #2', 'revised': true};
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      final print = find.byKey(const ValueKey('table-print-bill'));
      expect(print, findsOneWidget);
      expect(tester.widget<ForkButton>(print).label, 'Print updated bill');
      await tester.tap(print);
      await tester.pumpAndSettle();
      expect(find.text('Print the updated bill for T1?'), findsOneWidget);
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect((api.to('/print/bill').single.body as Map)['table_name'], 'T1');
      expect(find.byKey(const ValueKey('table-title-T1')), findsOneWidget, reason: 'the table stays');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text(printedStaysMessage(tableSentence: 'T1', root: 'T1')), findsOneWidget);
    }, variant: _looks);

    testWidgets('an owner\'s preview says UPDATED BILL and which print it replaces', (tester) async {
      final api = _owner(_floor([_printed('T1', stale: true)], bill: _bill(stale: true)));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      final print = find.byKey(const ValueKey('table-manager-print-bill'));
      await _reveal(tester, print);
      expect(tester.widget<ForkButton>(print).label, 'Print updated bill');
      await tester.tap(print);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bill-preview-updated')), findsOneWidget);
      expect(find.text('Replaces the bill printed $_clock'), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-preview-reprint')), findsNothing);

      // An unchanged bill's copy is still a REPRINT.
      await _mountFloor(tester, _owner(_floor([_printed('T1')], bill: _bill())));
      await _open(tester, 'T1');
      await _tapKey(tester, 'table-manager-print-bill');
      expect(find.byKey(const ValueKey('bill-preview-reprint')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-preview-updated')), findsNothing);
    }, variant: _looks);
  });

  // ==========================================================================
  // SETTLING AGAINST OUT-OF-DATE PAPER
  // ==========================================================================

  group('a settle against out-of-date paper warns, never blocks, and is recorded', () {
    Future<_FakeApi> openSettle(WidgetTester tester, {required bool? stale}) async {
      final bill = _bill(stale: stale, grand: 2220, printedTotal: 2100);
      final api = _owner(_floor([_printed('T1', stale: stale)], bill: bill));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      await _reveal(tester, _fork('Settle bill'));
      await tester.tap(_fork('Settle bill'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-method-Cash')));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('the warning names both totals; "Settle anyway" settles the current total and says so',
        (tester) async {
      final api = await openSettle(tester, stale: true);
      expect(find.byKey(const ValueKey('settle-stale-paper')), findsOneWidget);
      final warning = 'The printed bill ($_clock) shows ₹2100.00; the bill is now ₹2220.00. '
          'Print the updated bill before taking payment.';
      expect(find.text(warning), findsOneWidget);
      expect(find.byKey(const ValueKey('settle-print-updated')), findsOneWidget);

      // Cancel on the question writes nothing.
      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settle-stale-paper-confirm')), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('settle-stale-paper-confirm')), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('pay-settle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settle-anyway')));
      await tester.pumpAndSettle();
      final confirm = api.bodyOf('waiter-confirm-payment') as Map;
      expect(confirm['settled_with_stale_paper'], isTrue);
      expect(confirm['payment_method'], 'Cash');
      expect(confirm.containsKey('tenders'), isFalse, reason: 'the amount is the server\'s, as always');
      expect(api.bodyOf('admin-approve-payment'), {'settled_with_stale_paper': true});
      expect(api.writes.any((w) => w.path.endsWith('/close')), isTrue);
    }, variant: _looks);

    testWidgets('"Print updated bill" from the warning prints it', (tester) async {
      final api = await openSettle(tester, stale: true);
      await tester.tap(find.byKey(const ValueKey('settle-print-updated')));
      await tester.pumpAndSettle();
      expect((api.to('/print/bill').single.body as Map)['table_name'], 'T1');
    }, variant: _looks);

    testWidgets('paper that matches, or that nobody can vouch for: no warning, no question, no flag',
        (tester) async {
      for (final stale in <bool?>[false, null]) {
        final api = await openSettle(tester, stale: stale);
        expect(find.byKey(const ValueKey('settle-stale-paper')), findsNothing, reason: '$stale');
        await tester.tap(find.byKey(const ValueKey('pay-settle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settle-stale-paper-confirm')), findsNothing);
        expect((api.bodyOf('waiter-confirm-payment') as Map).containsKey('settled_with_stale_paper'), isFalse);
        expect(api.bodyOf('admin-approve-payment'), isNull);
      }
    }, variant: _looks);
  });

  // ==========================================================================
  // MOVE TABLE
  // ==========================================================================

  group('Move table is a waiter\'s too', () {
    List<Map<String, dynamic>> floor() => [
          _printed('T1'),
          _seat('T1'),
          _row('T5', seated: true),
          _seat('T5'),
          _row('T6'),
        ];

    testWidgets('never onto its own family; another table\'s green seat by name; the printed note; one POST',
        (tester) async {
      final api = _waiter(_floor(floor()))
        ..replies['/tables/move'] = (_) => {
              'success': true,
              'moved_orders': 1,
              'printed': true,
              'printed_as': 'T1',
              'next_party_table': 'T6 #2',
              'next_party_message': 'Seat the next party at T6 (next party).',
            };
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      await _tapKey(tester, 'table-move-party');
      expect(find.byKey(const ValueKey('move-to-T6')), findsOneWidget);
      expect(find.byKey(const ValueKey('move-to-T5 #2')), findsOneWidget);
      expect(find.text('Table T5 (next party)'), findsOneWidget);
      expect(find.byKey(const ValueKey('move-to-T1 #2')), findsNothing, reason: 'its own green seat');
      expect(find.byKey(const ValueKey('move-to-T5')), findsNothing, reason: 'seated');
      final icon = tester.widget<Icon>(
          find.descendant(of: find.byKey(const ValueKey('move-to-T6')), matching: find.byType(Icon)));
      expect(icon.color, AppColors.floorFree);

      await tester.tap(find.byKey(const ValueKey('move-to-T6')));
      await tester.pumpAndSettle();
      expect(find.textContaining(printedPartyMoveNote('T1', 'T6')), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(api.writes.map((w) => w.path).toList(), ['/tables/move']);
      expect(api.writes.single.body, {'from_table': 'T1', 'to_table': 'T6'});
      await tester.pump();
      expect(find.text('Moved T1 to T6 — 1 order came with them. Seat the next party at T6 (next party).'),
          findsOneWidget);
    }, variant: _looks);

    testWidgets('offline: refused in words, and nothing is queued', (tester) async {
      // The line is down before the floor can even be read…
      final api = _waiter(_floor(floor()));
      await _mountFloor(tester, api);
      await _open(tester, 'T1');
      api.offline = true;
      await _tapKey(tester, 'table-move-party');
      await tester.pump();
      expect(find.text(moveTableNeedsConnection), findsOneWidget);
      expect(api.attempts, isEmpty);
      expect(Outbox.instance.hasPending, isFalse);

      // …or it drops between the choice and the move.
      final dropped = _waiter(_floor(floor()));
      await _mountFloor(tester, dropped);
      await _open(tester, 'T1');
      await _tapKey(tester, 'table-move-party');
      dropped.offlineWrites = true;
      await tester.tap(find.byKey(const ValueKey('move-to-T6')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text(moveTableNeedsConnection), findsOneWidget);
      expect(dropped.writes, isEmpty);
      expect(Outbox.instance.hasPending, isFalse, reason: 'a party move was saved to send later');
    }, variant: _looks);

    testWidgets('the server decides Move table; Move an order stays a senior\'s', (tester) async {
      // A seated, unprinted table: the sheet a waiter opens most.
      Map<String, _Route> routes() => _floor([_row('T1', seated: true)], bill: _bill(printed: false));

      await _mountFloor(tester, _waiter(routes()));
      await _open(tester, 'T1');
      expect(find.byKey(const ValueKey('table-move-party')), findsOneWidget);
      expect(_fork('Move an order'), findsNothing, reason: 'the server said yes; the floor still says no');

      for (final scope in [
        {..._waiterScope, 'move_table': false},
        {'waiter_only': true},
      ]) {
        await _mountFloor(tester, _waiter(routes(), scope: scope));
        await _open(tester, 'T1');
        expect(find.byKey(const ValueKey('table-move-party')), findsNothing, reason: '$scope');
        expect(_fork('Move table'), findsNothing, reason: '$scope');
      }

      await _mountFloor(tester, _owner(routes()));
      await _open(tester, 'T1');
      await _reveal(tester, _fork('Move an order'));
      expect(_fork('Move table'), findsOneWidget);
      expect(_fork('Move an order'), findsOneWidget);
    }, variant: _looks);

    testWidgets('the waiter\'s printed sheet fits a 360dp phone', (tester) async {
      await _mountFloor(tester, _waiter(_floor(floor())), size: const Size(360, 800));
      await _open(tester, 'T1');
      expect(tester.takeException(), isNull);
      for (final k in ['table-add-to-printed', 'table-print-spent', 'table-move-party', 'table-printed-banner']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
    }, variant: _looks);
  });

  // ==========================================================================
  // WIRING — nothing here is built and never called
  // ==========================================================================

  group('the wiring', () {
    String read(String rel) => File(rel).readAsStringSync().replaceAll(String.fromCharCode(13), '');

    test('the floor filters nothing on the service surface, and paints from one rule', () {
      final mod = read('lib/screens/modules.dart');
      expect(mod, isNot(contains('.retiresTable)')), reason: 'a C3 filter is back on the floor');
      expect(mod, contains('            : allRows;'));
      expect(mod, isNot(contains('every table you printed')));
      expect(mod, contains('return PrintedBacklogFilter(child: Scaffold('));
      expect(mod, contains('final floor = _floorState(table, profile);'));
      expect(mod, contains('FloorLegendChip(key: ValueKey(\'floor-legend-\${row.state.name}\')'));
      expect(mod, contains('const Padding(padding: EdgeInsets.only(bottom: 10), child: FloorColourKey()),'));
      expect(mod, isNot(contains('AppColors.copper.withValues(alpha: _kOccupiedWash)')));
    });

    test('the flag is sent by the pad alone, and only when chosen', () {
      final pad = read('lib/screens/order_entry.dart');
      expect(pad, contains('if (_addsToPrinted) addToPrintedBillKey: true,'));
      expect(pad, contains('bool get _addsToPrinted => _confirmedPrinted && _retarget == null && widget.isDineIn;'));
      expect(pad, contains('late bool _confirmedPrinted = widget.addToPrintedBill;'));
      expect(RegExp('addToPrintedBillKey').allMatches(pad).length, 1, reason: 'a second send carries the flag');
      final mod = read('lib/screens/modules.dart');
      expect(mod, contains(': OrderEntryScreen(rest: widget.rest, tableName: _name, addToPrintedBill: true),'));
      expect(RegExp('addToPrintedBill: true').allMatches(mod).length, 1);
      expect(mod, isNot(contains('addToPrintedBillKey')), reason: 'the sheet writes the flag itself');
    });

    test('the settle records the override only when it warned', () {
      final cap = read('lib/screens/mis_capture.dart');
      expect(cap, contains("if (stale != null) 'settled_with_stale_paper': true,"));
      expect(cap, contains("stale != null ? const {'settled_with_stale_paper': true} : null);"));
      final mod = read('lib/screens/modules.dart');
      expect(mod, contains('paperBill: _bill,'));
    });

    test('Move table is on its own flag and never queued', () {
      final mod = read('lib/screens/modules.dart');
      expect(mod, contains('if (_scope.moveTable) ...['));
      expect(mod, contains('if (_scope.moveOrder)'));
      expect(mod, contains('if (sameTableFamily(widget.table, m)) return false;'));
      expect(OutboxPolicy.decide('POST', '/tables/move').queueable, isFalse);
      expect(OutboxPolicy.decide('POST', '/tables/move-order').queueable, isFalse);
    });
  });
}
