// Reorderable floor sections (migration 041), on the real Tables module.
//
// The complaint: "sections under tables are grouped in alphabetical order;
// there should be an option to rearrange the order of the sections."
// Alphabetical was never chosen — before 041 the schema had no ordering column,
// so `sort()` was the only order the data could express.
//
// What is pinned here:
//   1. NOTHING CHANGES UNTIL SOMEBODY DRAGS. An outlet with no positions renders
//      in exactly the alphabetical order 1.8.5 rendered in. That is the whole
//      reason the migration backfills nothing.
//   2. A chosen order is obeyed, and "Unassigned" still comes last, so no table
//      can hide behind a section it has not been given.
//   3. The order reaches a user who CANNOT read the section roster. GET
//      /table-sections is gated on "Manage Table Sections"; if the order only
//      rode on that call, an owner who rearranged their floor would have
//      rearranged nothing but their own screen.
//   4. NO SECTION VANISHES. A zone that exists only as a Tables.section label —
//      with no roster row at all — is in the arrange list and in the payload
//      that gets saved. Dropping it is what would read to an owner as
//      "rearranging deleted my Bar section".
//   5. Both design systems. The floor plan is not a Gaia signature screen, so
//      the same widgets must produce the same ORDER under either language.
//   6. Phone and desktop. The reorder affordance cannot be mouse-only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_colors.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_button.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.routes);
  final Map<String, dynamic> routes;

  /// Every write the tests provoke, with its body — the reorder contract is the
  /// body, so recording the path alone would prove nothing.
  final List<({String method, String path, Object? body})> writes = [];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password,
          {String? outletId}) async =>
      LoginResult('test-token', _admin);

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (method != 'GET') {
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    if (routes.containsKey(path)) return routes[path];
    throw ApiException('No fake route for $path', 404);
  }
}

Profile _profile({required List<String> actions, required List<String> names, String role = 'admin'}) =>
    Profile.fromJson(<String, dynamic>{
      'employeeId': 'e1',
      'restaurantName': 'CSR Organics',
      'role': role,
      'actions_set': actions,
      'action_names': names,
    });

final Profile _admin = _profile(actions: ['*'], names: const <String>[]);

/// A manager who can edit tables but holds no "Manage Table Sections" grant —
/// the person GET /table-sections is closed to, and who must still see the
/// floor in the owner's chosen order.
final Profile _floorStaff =
    _profile(actions: const ['aaa'], names: const ['Table Added'], role: 'manager');

Widget _host(Widget child, DesignSystem system) => GaiaScope(
      system: system,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Tables'],
          clearFocus: () {},
          child: Scaffold(backgroundColor: AppColors.bg, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(
  WidgetTester tester,
  Map<String, dynamic> routes, {
  Profile? profile,
  DesignSystem system = DesignSystem.rustic,
  double width = 1200,
  double height = 4000,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final api = _FakeApi(routes);
  final auth = AuthController(api: api);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.tablesModule(rest, profile ?? _admin), system));
  await tester.pumpAndSettle();
  return api;
}

Map<String, dynamic> _table(String name, {String? section, int? position, int capacity = 4}) =>
    <String, dynamic>{
      'table_name': name,
      'capacity': capacity,
      'max_capacity': capacity,
      'section': section,
      'section_position': position,
      'occupied': false,
      'reserved': false,
    };

Map<String, dynamic> _routes(
  List<Map<String, dynamic>> tables, {
  List<Map<String, dynamic>>? roster,
}) =>
    <String, dynamic>{
      '/get-tables': tables,
      '/table-assignments': <dynamic>[],
      '/get-bookings': <dynamic>[],
      '/table-sections': {'sections': roster ?? <Map<String, dynamic>>[], 'unassigned': 0},
    };

/// The section group headers, top to bottom. Headers render the label
/// upper-cased, so this asks for the labels it expects and reports the ones it
/// found, in layout order.
List<String> _headerOrder(WidgetTester tester, List<String> labels) {
  final tops = <String, double>{};
  for (final label in labels) {
    final f = find.text(label.toUpperCase());
    if (f.evaluate().isEmpty) continue;
    tops[label] = tester.getTopLeft(f.first).dy;
  }
  return tops.keys.toList()..sort((a, b) => tops[a]!.compareTo(tops[b]!));
}

/// A ForkButton by its LABEL, not by its rendered text.
///
/// Gaia upper-cases button labels and Rustic does not, so a finder on the
/// rendered text silently finds nothing under Gaia. Matching the widget keeps every
/// assertion below true of the same call site in both design systems, which is
/// the point being made.
Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is ForkButton && w.label == label, description: 'ForkButton "$label"');

ForkButton _buttonWidget(WidgetTester tester, String label) =>
    tester.widget<ForkButton>(_button(label).first);

const _all = ['Bar', 'Garden', 'Terrace', 'Unassigned'];

void main() {
  setUp(() => AppearanceController.instance.debugReset());
  tearDown(() => AppearanceController.instance.debugReset());

  group('the order on screen', () {
    testWidgets('with no positions the floor is alphabetical — 1.8.5 exactly', (tester) async {
      // Migration 041 backfills nothing, so this is every outlet on the day it
      // lands. If this test ever fails, the release stopped being invisible.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace'),
          _table('T2', section: 'Bar'),
          _table('T3', section: 'Garden'),
          _table('T4'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Garden', 'tables': 1, 'seats': 4, 'sort_order': null},
        ]),
      );
      expect(_headerOrder(tester, _all), ['Bar', 'Garden', 'Terrace', 'Unassigned']);
    });

    testWidgets('a chosen order is obeyed, and Unassigned still comes last', (tester) async {
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', position: 1),
          _table('T2', section: 'Bar', position: 2),
          _table('T3', section: 'Garden', position: 3),
          _table('T4'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': 1},
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': 2},
          {'section': 'Garden', 'tables': 1, 'seats': 4, 'sort_order': 3},
        ]),
      );
      // Alphabetical would be Bar, Garden, Terrace. It is not.
      expect(_headerOrder(tester, _all), ['Terrace', 'Bar', 'Garden', 'Unassigned']);
    });

    testWidgets('a section created after a reorder lands at the END, not in the middle',
        (tester) async {
      // Null position = never placed. Appending is the only placement that moves
      // nothing the owner already arranged.
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', position: 1),
          _table('T2', section: 'Bar', position: 2),
          _table('T3', section: 'Annexe'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': 1},
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': 2},
          {'section': 'Annexe', 'tables': 1, 'seats': 4, 'sort_order': null},
        ]),
      );
      expect(_headerOrder(tester, ['Terrace', 'Bar', 'Annexe']), ['Terrace', 'Bar', 'Annexe']);
    });

    testWidgets('the order reaches a user who cannot read the section roster', (tester) async {
      // GET /table-sections is gated on "Manage Table Sections", so this profile
      // never fetches it — the fake would 404 the path if it tried. The order
      // has to arrive on the tables themselves or it does not arrive at all.
      final api = await _mount(
        tester,
        <String, dynamic>{
          '/get-tables': [
            _table('T1', section: 'Terrace', position: 1),
            _table('T2', section: 'Bar', position: 2),
            _table('T3', section: 'Garden', position: 3),
          ],
          '/table-assignments': <dynamic>[],
          '/get-bookings': <dynamic>[],
        },
        profile: _floorStaff,
      );
      expect(_headerOrder(tester, ['Terrace', 'Bar', 'Garden']), ['Terrace', 'Bar', 'Garden']);
      // And they are offered no way to change it.
      expect(_button('Arrange'), findsNothing);
      expect(api.writes, isEmpty);
    });

    testWidgets('the SAME data renders in the SAME order under Gaia', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace', position: 1),
          _table('T2', section: 'Bar', position: 2),
          _table('T3', section: 'Garden', position: 3),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': 1},
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': 2},
          {'section': 'Garden', 'tables': 1, 'seats': 4, 'sort_order': 3},
        ]),
        system: DesignSystem.gaia,
      );
      expect(_headerOrder(tester, ['Terrace', 'Bar', 'Garden']), ['Terrace', 'Bar', 'Garden']);
      expect(_button('Arrange'), findsOneWidget);
    });
  });

  group('the Arrange sheet', () {
    Map<String, dynamic> threeZones() => _routes([
          _table('T1', section: 'Bar'),
          _table('T2', section: 'Garden'),
          _table('T3', section: 'Terrace'),
        ], roster: [
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Garden', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': null},
        ]);

    testWidgets('sends the WHOLE list, in the new order, as one PUT', (tester) async {
      // A whole-list PUT rather than "move Bar to slot 2": a positional edit
      // needs both ends to agree on what the list currently is, and two tablets
      // dragging at once do not.
      final api = await _mount(tester, threeZones());
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(find.text('Arrange sections'), findsOneWidget);

      // Bar (row 0) moves down one: Garden, Bar, Terrace.
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();

      expect(api.writes, hasLength(1));
      final w = api.writes.single;
      expect(w.method, 'PUT');
      expect(w.path, '/table-sections/order');
      expect((w.body as Map)['sections'], ['Garden', 'Bar', 'Terrace']);
    });

    testWidgets('the new order shows immediately, before the reload agrees', (tester) async {
      // Optimistic like every other write on this screen. The fake keeps serving
      // the OLD (position-less) data, so if the optimism were missing the
      // headers would snap straight back to alphabetical after the reload.
      await _mount(tester, threeZones());
      expect(_headerOrder(tester, _all), ['Bar', 'Garden', 'Terrace']);

      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();

      expect(_headerOrder(tester, _all), ['Garden', 'Bar', 'Terrace']);
    });

    testWidgets('a section that exists only as a table label is in the list and is saved',
        (tester) async {
      // THE TRAP. "Bar" has no roster row — it exists because a table carries the
      // label. Leave it out of the arrange list and the reorder that follows
      // drops it: to an owner, rearranging deleted a section.
      final api = await _mount(
        tester,
        _routes([
          _table('T1', section: 'Bar'),
          _table('T2', section: 'Terrace'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': null},
        ]),
      );
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(find.text('Bar'), findsOneWidget);

      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();

      expect((api.writes.single.body as Map)['sections'], ['Terrace', 'Bar']);
    });

    testWidgets('an EMPTY zone — roster only, no tables — is arrangeable too', (tester) async {
      final api = await _mount(
        tester,
        _routes([
          _table('T1', section: 'Terrace'),
        ], roster: [
          {'section': 'Terrace', 'tables': 1, 'seats': 4, 'sort_order': null},
          {'section': 'Annexe', 'tables': 0, 'seats': 0, 'sort_order': null},
        ]),
      );
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      // Scoped to the sheet: the floor plan behind it already badges that zone
      // "Empty" in its group header.
      expect(
        find.descendant(of: find.byType(ReorderableListView), matching: find.text('Empty')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();
      expect((api.writes.single.body as Map)['sections'], ['Terrace', 'Annexe']);
    });

    testWidgets('cancelling writes nothing and leaves the floor alone', (tester) async {
      final api = await _mount(tester, threeZones());
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(_headerOrder(tester, _all), ['Bar', 'Garden', 'Terrace']);
    });

    testWidgets('saving is refused until something actually moves', (tester) async {
      // Sending the list unchanged would stamp explicit positions on an outlet
      // that had none — a real change (new sections would start landing at the
      // end) dressed up as a no-op.
      await _mount(tester, threeZones());
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(_buttonWidget(tester, 'Save order').onPressed, isNull,
          reason: 'nothing has moved yet');
    });

    testWidgets('every row can be moved with a pointer OR with the arrows', (tester) async {
      // The drag handle is a ReorderableDragStartListener — pointer-kind
      // agnostic, so the same grab works with a mouse on the Windows build and
      // with a finger on the phone build. The arrows are the second path, for
      // keyboard and for anyone a precise drag is hard for. A handle wired to
      // hover would leave a phone unable to reorder at all.
      await _mount(tester, threeZones());
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
      expect(find.byTooltip('Move up'), findsNWidgets(3));
      expect(find.byTooltip('Move down'), findsNWidgets(3));

      // The list is NOT draggable outside the handle, so it still scrolls on a
      // phone — a reorder sheet that cannot be scrolled is worse than none.
      final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      expect(list.buildDefaultDragHandles, isFalse);
    });

    testWidgets('the sheet works on a phone-width screen', (tester) async {
      await _mount(tester, threeZones(), width: 390, height: 844);
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(find.text('Arrange sections'), findsOneWidget);
      // A striped overflow bar across the bottom of the sheet is the failure
      // this asserts against: the footer wraps rather than running off a 390px
      // screen, which is exactly the device this feature most needs to work on.
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the sheet renders under Gaia and saves the same body', (tester) async {
      await AppearanceController.instance.setDesignSystem(DesignSystem.gaia);
      final api = await _mount(tester, threeZones(), system: DesignSystem.gaia);
      await tester.tap(_button('Arrange'));
      await tester.pumpAndSettle();
      expect(find.text('Arrange sections'), findsOneWidget);
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('Save order'));
      await tester.pumpAndSettle();
      expect((api.writes.single.body as Map)['sections'], ['Garden', 'Bar', 'Terrace']);
    });

    testWidgets('one section offers nothing to arrange', (tester) async {
      await _mount(
        tester,
        _routes([
          _table('T1', section: 'Bar'),
        ], roster: [
          {'section': 'Bar', 'tables': 1, 'seats': 4, 'sort_order': null},
        ]),
      );
      expect(_button('Arrange'), findsNothing);
      expect(_button('New section'), findsOneWidget);
    });
  });
}
