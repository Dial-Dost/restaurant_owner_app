import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/report_export.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/services/time_slot.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

/// REPORTS — SESSION-WISE (client item 3), the app half, on the real screen.
///
/// "Select time for hour-wise or session-wise reports; the superadmin chooses
/// the time slots; Lunch 12pm-5pm and Dinner 6pm-12am as presets." The server
/// does the slicing (branch cfb2/time-slots-api); the fake below stands in for
/// it, answering per the agreed contract. What these pin is the screen's half:
///   * no route, no chip, and not one slot parameter on the wire;
///   * the chip's options, and "Manage sessions" only for `can_edit`;
///   * a pick rides on EVERY report request and remounts the pane — and so
///     does a SAVE that changes what the pick means under the same URL (the
///     picked session's hours or name; any preset, for "By session");
///   * custom times are validated before they are sent;
///   * the editor PUTs the whole list and shows the server's own 400 sentence;
///   * the Sales Summary's four segments, and the rows that narrow into a slot
///     — only where opening one counts exactly what the row did — while a day
///     row narrows the dates and KEEPS the slot;
///   * the export names the slot the server applied, in its filename and
///     preamble;
///   * the clamp chip reads a LIST (`clamped == true` never fired);
///   * a 360dp phone lays all of it out without an overflow.

const _defaultSlots = [
  {'id': 'lunch', 'label': 'Lunch', 'start': '12:00', 'end': '17:00', 'crosses_midnight': false},
  {'id': 'dinner', 'label': 'Dinner', 'start': '18:00', 'end': '24:00', 'crosses_midnight': false},
];

List<Map<String, dynamic>> _cols(List<String> keys) =>
    [for (final k in keys) {'key': k, 'label': k, 'type': 'text'}];

class _SlotApi extends ApiClient {
  _SlotApi({this.slotsRoute = true, this.canEdit = true});

  /// False = an older backend with no presets route.
  final bool slotsRoute;
  final bool canEdit;

  List<Map<String, dynamic>> slots = [for (final s in _defaultSlots) Map<String, dynamic>.from(s)];

  /// When set, the next PUT is refused with this as the server's `details`.
  String? putRefusal;

  /// `meta.window.clamped` on every report.
  List<String> clamped = const [];

  /// The Sales Summary's `hour_of_day` rows.
  List<String> hourRows = const ['13:00-14:00', '20:00-21:00'];

  final List<String> calls = <String>[];
  final List<Object?> puts = <Object?>[];

  @override
  Future<LoginResult> login(String r, String u, String p, {String? outletId}) async => LoginResult(
        't',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1', 'restaurantName': 'CSR', 'res_id': 'res-1', 'outlet_id': 'out-1',
          'role': 'admin', 'actions_set': ['*'], 'action_names': <String>[],
        }),
      );

  Map<String, dynamic> get _catalogue => {'slots': slots, 'can_edit': canEdit, 'is_default': false};

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    final uri = Uri.parse('http://x$path');
    final base = uri.path;
    if (base == '/reports/mis/time-slots') {
      if (!slotsRoute) throw ApiException('No fake route for $base', 404);
      if (method == 'GET') return _catalogue;
      if (method == 'PUT') {
        puts.add(body);
        if (putRefusal != null) {
          throw ApiException.fromBody({'error': 'Invalid time slots', 'details': putRefusal}, 400);
        }
        final list = ((body as Map)['slots'] as List).cast<Map>();
        slots = list.isEmpty
            ? [for (final s in _defaultSlots) Map<String, dynamic>.from(s)]
            : [
                for (final s in list)
                  {
                    'id': s['id'] ?? '${s['label']}'.toLowerCase(),
                    'label': s['label'],
                    'start': s['start'],
                    'end': s['end'],
                    'crosses_midnight': false,
                  },
              ];
        return _catalogue;
      }
    }
    if (method != 'GET') throw StateError('Unexpected $method $path');
    if (base == '/outlets') {
      return {
        'outlets': [
          {'id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'is_active': true},
        ],
      };
    }
    if (!base.startsWith('/reports/mis/')) throw ApiException('No fake route for $base', 404);
    return _report(base, uri.queryParameters);
  }

  /// The contract's `meta.time_slot`, echoed from the query exactly as the real
  /// server resolves it: custom times win, then a preset id, else all day.
  Map<String, dynamic>? _applied(Map<String, String> q) {
    final from = q['time_from'];
    final to = q['time_to'];
    if (from != null && to != null) {
      return {'id': null, 'label': 'Custom', 'start': from, 'end': to, 'crosses_midnight': to.compareTo(from) < 0, 'source': 'custom'};
    }
    final id = q['slot'];
    for (final s in slots) {
      if (s['id'] == id) {
        return {...s, 'source': 'preset'};
      }
    }
    return null;
  }

  Map<String, dynamic> _report(String base, Map<String, String> q) {
    final key = base.substring('/reports/mis/'.length).replaceAll('-', '_');
    final bucket = q['bucket'] ?? 'day';
    final rows = switch (key) {
      'sales_summary' => switch (bucket) {
          'hour_of_day' => [
              for (final h in hourRows) {'bucket': h, 'bills': 1},
            ],
          // Built from the presets HELD, as the server builds them: a save
          // renames and retimes these rows under an unchanged URL.
          'session' => [
              for (final s in slots) {'bucket': '${s['label']} (${s['start']}-${s['end']})', 'bills': 1},
              {'bucket': 'Outside sessions', 'bills': 1},
            ],
          'hour' => [
              {'bucket': '2026-08-01T13', 'bills': 2},
            ],
          _ => [
              {'bucket': '2026-08-01', 'bills': 2},
              {'bucket': '2026-08-02', 'bills': 2},
            ],
        },
      _ => [
          {'name': 'Row of $key', 'qty': 1},
        ],
    };
    return {
      'meta': {
        'report': key,
        'title': key == 'sales_summary' ? 'Sales Summary' : key,
        'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'clamped': clamped},
        'timezone': 'Asia/Kolkata',
        'outlet_scope': 'outlet',
        'outlet_name': 'Kalyani Nagar',
        'notes': <String>[],
        'time_slot': _applied(q),
      },
      'columns': key == 'sales_summary' ? _cols(['bucket', 'bills']) : _cols(['name', 'qty']),
      key == 'sales_summary' ? 'series' : 'rows': rows,
      'totals': <String, dynamic>{},
      'page': {'limit': 100, 'offset': 0, 'total': rows.length, 'has_more': false},
    };
  }

  List<String> get gets => [for (final c in calls) if (c.startsWith('GET ')) c.substring(4)];

  String lastCallTo(String path) => gets.lastWhere((c) => c.startsWith(path));
}

Future<_SlotApi> _mount(WidgetTester tester, {_SlotApi? api, double width = 1500, double height = 1100}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fake = api ?? _SlotApi();
  final auth = AuthController(api: fake);
  await auth.login('CSR', 'a', 'b');
  final rest = RestClient(auth);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: ModuleNavigator(
      openModule: (_, {Map<String, dynamic>? target}) {},
      visibleLabels: const ['Reports'],
      clearFocus: () {},
      switchOutlet: (_) {},
      child: Scaffold(body: m.reportsModule(rest, auth.profile!)),
    ),
  ));
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _openTab(WidgetTester tester, String title) async {
  final tab = find.text(title).first;
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _openChip(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reports-slot')));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String option) async {
  await _openChip(tester);
  await tester.tap(find.byKey(ValueKey('slot-option-$option')));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, Finder within) =>
    tester.widgetList<Text>(find.descendant(of: within, matching: find.byType(Text))).map((t) => t.data ?? '').join(' ');

/// Opens Manage sessions, types [fields] (editor key -> text) and saves.
Future<void> _saveSessions(WidgetTester tester, Map<String, String> fields) async {
  await _openChip(tester);
  await tester.tap(find.byKey(const ValueKey('slot-manage')));
  await tester.pumpAndSettle();
  for (final f in fields.entries) {
    await tester.enterText(find.byKey(ValueKey(f.key)), f.value);
  }
  await tester.tap(find.byKey(const ValueKey('slot-edit-save')));
  await tester.pumpAndSettle();
}

Future<void> _pickCustom(WidgetTester tester, String from, String to) async {
  await _openChip(tester);
  await tester.tap(find.byKey(const ValueKey('slot-option-custom')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('slot-custom-from')), from);
  await tester.enterText(find.byKey(const ValueKey('slot-custom-to')), to);
  await tester.tap(find.byKey(const ValueKey('slot-custom-apply')));
  await tester.pumpAndSettle();
}

Future<void> _tapRow(WidgetTester tester, String cell) async {
  await tester.ensureVisible(find.text(cell).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(cell).first);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ReportExporter.overrideDeliver = null;
  });
  tearDown(() => ReportExporter.overrideDeliver = null);

  testWidgets('no presets route: no Session chip, no new segments, and no slot on the wire', (tester) async {
    // Even with "Dinner" remembered from earlier in the session: a filter the
    // server cannot apply must not be sent as though it were one.
    TimeSlotMemory.remember('reports', TimeSlotSelection.preset('dinner'));
    final api = await _mount(tester, api: _SlotApi(slotsRoute: false));
    expect(find.byKey(const ValueKey('reports-slot')), findsNothing);
    await _openTab(tester, 'Sales Summary');
    expect(find.text('Hour-wise'), findsOneWidget);
    expect(find.text('By session'), findsNothing);
    expect(find.text('By hour of day'), findsNothing);
    final reportCalls =
        api.gets.where((c) => c.startsWith('/reports/mis/') && !c.startsWith('/reports/mis/time-slots')).toList();
    expect(reportCalls, isNotEmpty);
    for (final call in reportCalls) {
      expect(call, isNot(contains('slot=')));
      expect(call, isNot(contains('time_from')));
    }
  });

  testWidgets('a session remembered from earlier comes back with the chip, on the first request', (tester) async {
    TimeSlotMemory.remember('reports', TimeSlotSelection.preset('dinner'));
    final api = await _mount(tester);
    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('Dinner · 18:00–24:00'));
    expect(api.lastCallTo('/reports/mis/item-wise'), contains('slot=dinner'));
  });

  testWidgets('the chip offers All day, each preset and Custom… — Manage sessions only with can_edit',
      (tester) async {
    await _mount(tester, api: _SlotApi(canEdit: false));
    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('All day'));
    await _openChip(tester);
    expect(find.text('All day'), findsWidgets);
    expect(find.text('Lunch · 12:00–17:00'), findsOneWidget);
    expect(find.text('Dinner · 18:00–24:00'), findsOneWidget);
    expect(find.text('Custom…'), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-manage')), findsNothing,
        reason: 'a caller without the settings permission is not offered the editor');
    expect(find.text('Manage sessions…'), findsNothing);

    await _mount(tester, api: _SlotApi(canEdit: true));
    await _openChip(tester);
    expect(find.text('Manage sessions…'), findsOneWidget);
  });

  testWidgets('a picked session rides on every report request and names itself', (tester) async {
    final api = await _mount(tester);
    await _pick(tester, 'dinner');

    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('Dinner · 18:00–24:00'));
    expect(api.lastCallTo('/reports/mis/item-wise'), contains('slot=dinner'));
    // The clock AND the hours, together — "Dinner" on an order-time report is
    // a different question from Dinner on the settlement clock.
    expect(_text(tester, find.byKey(const ValueKey('reports-basis'))), 'Dated on order placement · Dinner (18:00–24:00)');
    // What the SERVER applied, beside the timezone.
    expect(_text(tester, find.byKey(const ValueKey('reports-slot-applied'))), 'Dinner (18:00–24:00)');

    await _openTab(tester, 'Order Summary');
    final call = api.lastCallTo('/reports/mis/order-summary');
    expect(call, contains('slot=dinner'));
    expect(call, contains('limit=100'));

    // Back to all day: the parameter goes, the URL is the one it always was.
    await _pick(tester, 'all');
    expect(api.lastCallTo('/reports/mis/order-summary'), isNot(contains('slot=')));
    expect(find.byKey(const ValueKey('reports-slot-applied')), findsNothing);
  });

  testWidgets('custom times are validated, and a crossing pair goes as time_from/time_to', (tester) async {
    final api = await _mount(tester);
    final before = api.gets.length;
    await _openChip(tester);
    await tester.tap(find.byKey(const ValueKey('slot-option-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('slot-custom-from')), '25:00');
    await tester.enterText(find.byKey(const ValueKey('slot-custom-to')), '02:00');
    await tester.tap(find.byKey(const ValueKey('slot-custom-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Start time must be a 24-hour time between 00:00 and 23:59.'), findsOneWidget);
    expect(api.gets.length, before, reason: 'an invalid pair must not reach the server');

    await tester.enterText(find.byKey(const ValueKey('slot-custom-from')), '22:00');
    await tester.pumpAndSettle();
    expect(find.text('Crosses midnight — each night is counted on the day it starts.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('slot-custom-apply')));
    await tester.pumpAndSettle();

    expect(api.lastCallTo('/reports/mis/item-wise'), contains('time_from=22%3A00&time_to=02%3A00'));
    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('Custom · 22:00–02:00'));
  });

  testWidgets('Manage sessions PUTs the whole list and shows the server\'s own sentence', (tester) async {
    final api = await _mount(tester);
    await _openChip(tester);
    await tester.tap(find.byKey(const ValueKey('slot-manage')));
    await tester.pumpAndSettle();
    expect(find.text('Manage sessions'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('slot-edit-name-0')), 'Brunch');
    await tester.enterText(find.byKey(const ValueKey('slot-edit-end-0')), '19:00');
    api.putRefusal = 'Brunch and Dinner overlap between 18:00 and 19:00.';
    await tester.tap(find.byKey(const ValueKey('slot-edit-save')));
    await tester.pumpAndSettle();
    expect(find.text('Brunch and Dinner overlap between 18:00 and 19:00.'), findsOneWidget,
        reason: 'the 400 sentence is shown inline, verbatim');
    expect(find.text('Manage sessions'), findsOneWidget, reason: 'a refused save keeps the editor open');

    api.putRefusal = null;
    await tester.enterText(find.byKey(const ValueKey('slot-edit-end-0')), '17:00');
    await tester.tap(find.byKey(const ValueKey('slot-edit-save')));
    await tester.pumpAndSettle();
    expect(api.puts.last, {
      'slots': [
        {'id': 'lunch', 'label': 'Brunch', 'start': '12:00', 'end': '17:00'},
        {'id': 'dinner', 'label': 'Dinner', 'start': '18:00', 'end': '24:00'},
      ],
    });
    expect(find.text('Manage sessions'), findsNothing);
    await _openChip(tester);
    expect(find.text('Brunch · 12:00–17:00'), findsOneWidget, reason: 'the chip now offers what the server holds');
    // Close the sheet, then reset through the editor.
    await tester.tap(find.byKey(const ValueKey('slot-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('slot-edit-reset')));
    await tester.pumpAndSettle();
    expect(find.text('Replace these with Lunch and Dinner?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('slot-edit-reset-confirm')));
    await tester.pumpAndSettle();
    expect(api.puts.last, {'slots': <Map<String, dynamic>>[]});
  });

  testWidgets('a blank name is caught before any round trip', (tester) async {
    final api = await _mount(tester);
    await _openChip(tester);
    await tester.tap(find.byKey(const ValueKey('slot-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('slot-edit-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('slot-edit-save')));
    await tester.pumpAndSettle();
    expect(find.text('Session 3: a session needs a name of 1 to 24 characters.'), findsOneWidget);
    expect(api.puts, isEmpty);
  });

  testWidgets('Sales Summary: four segments, and each one goes on the wire', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    for (final label in const ['Day-wise', 'Hour-wise', 'By hour of day', 'By session']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('By hour of day'));
    await tester.pumpAndSettle();
    expect(api.lastCallTo('/reports/mis/sales-summary'), contains('bucket=hour_of_day'));
    await tester.tap(find.text('By session'));
    await tester.pumpAndSettle();
    expect(api.lastCallTo('/reports/mis/sales-summary'), contains('bucket=session'));
  });

  testWidgets('a session row selects that session, read day by day', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.text('By session'));
    await tester.pumpAndSettle();
    expect(_text(tester, find.byKey(const ValueKey('reports-drill'))),
        'Some rows open that session, day by day · 1 of 3 rows name none');

    await _tapRow(tester, 'Lunch (12:00-17:00)');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('slot=lunch'));
    expect(call, contains('bucket=day'));
    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('Lunch · 12:00–17:00'));

    // "Outside sessions" is not a session: tapping it asks nothing new.
    await tester.tap(find.text('By session'));
    await tester.pumpAndSettle();
    final n = api.gets.length;
    await _tapRow(tester, 'Outside sessions');
    expect(api.gets.length, n);
  });

  testWidgets('an hour-of-day row narrows to that hour as a custom slot', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.text('By hour of day'));
    await tester.pumpAndSettle();
    expect(_text(tester, find.byKey(const ValueKey('reports-drill'))), 'Tap a row to open that hour, day by day');
    await _tapRow(tester, '13:00-14:00');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('time_from=13%3A00&time_to=14%3A00'));
    expect(call, contains('bucket=day'));
  });

  testWidgets('a day row narrows the dates and KEEPS the slot', (tester) async {
    final api = await _mount(tester);
    await _pick(tester, 'dinner');
    await _openTab(tester, 'Sales Summary');
    await _tapRow(tester, '2026-08-01');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('from=2026-08-01&to=2026-08-01'));
    expect(call, contains('slot=dinner'), reason: '"Dinner on the 1st" is still a question about Dinner');
  });

  testWidgets('saving new hours — or a new name — for the PICKED session re-asks the report under them',
      (tester) async {
    String? name;
    ReportExporter.overrideDeliver = (b, filename, format) async {
      name = filename;
      return const ReportExportResult('Saved');
    };
    final api = await _mount(tester);
    await _pick(tester, 'lunch');
    int itemWiseGets() => api.gets.where((c) => c.startsWith('/reports/mis/item-wise')).length;
    final before = itemWiseGets();

    await _saveSessions(tester, {'slot-edit-end-0': '15:00'});
    // `slot=lunch` is the URL it was — and it is asked again, because the
    // server now reads it as 12:00–15:00. Kept mounted, the pane showed the old
    // Lunch's rows and footer under a toolbar naming the new one.
    expect(itemWiseGets(), before + 1, reason: "the same URL is a new question once Lunch's hours move");
    expect(api.lastCallTo('/reports/mis/item-wise'), contains('slot=lunch'));
    expect(_text(tester, find.byKey(const ValueKey('reports-basis'))), 'Dated on order placement · Lunch (12:00–15:00)');
    expect(_text(tester, find.byKey(const ValueKey('reports-slot-applied'))), 'Lunch (12:00–15:00)',
        reason: 'the footer names what the server applied, and it applied the new hours');

    // The export is built off that same fresh payload: its name agrees with its rows.
    await tester.tap(find.byKey(const ValueKey('reports-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(name, endsWith('_lunch-1200-1500.csv'));

    // A rename alone re-asks too: the footer and the filename are spelled from the name.
    final beforeRename = itemWiseGets(); // the export's sweep was a GET of its own
    await _saveSessions(tester, {'slot-edit-name-0': 'Brunch'});
    expect(itemWiseGets(), beforeRename + 1);
    expect(_text(tester, find.byKey(const ValueKey('reports-slot-applied'))), 'Brunch (12:00–15:00)');
  });

  testWidgets('"By session" re-asks when any session is saved, All day included — its rows are the sessions',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.text('By session'));
    await tester.pumpAndSettle();
    expect(find.text('Lunch (12:00-17:00)'), findsWidgets);
    int salesGets() => api.gets.where((c) => c.startsWith('/reports/mis/sales-summary')).length;
    final before = salesGets();

    await _saveSessions(tester, {'slot-edit-end-0': '15:00'});
    expect(salesGets(), before + 1, reason: 'All day picked, so nothing on the wire changed — but the rows did');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('bucket=session'));
    expect(call, isNot(contains('slot=')));
    expect(find.text('Lunch (12:00-15:00)'), findsWidgets);
    expect(find.text('Lunch (12:00-17:00)'), findsNothing, reason: 'no row from before the save is left standing');

    // Day-wise over All day is not built from the sessions: a save there asks nothing.
    await tester.tap(find.text('Day-wise'));
    await tester.pumpAndSettle();
    final dayBefore = salesGets();
    await _saveSessions(tester, {'slot-edit-end-0': '16:00'});
    expect(salesGets(), dayBefore);
  });

  testWidgets('under a slot, a session row reaching past it does not open — its drill-down would be a bigger total',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await _pickCustom(tester, '16:00', '19:00');
    await tester.tap(find.text('By session'));
    await tester.pumpAndSettle();
    // Lunch here is only 16:00–17:00 and Dinner only 18:00–19:00; opening
    // either as a session would read its whole 12:00–17:00 or 18:00–24:00.
    expect(_text(tester, find.byKey(const ValueKey('reports-drill'))),
        'Rows here are cut to 16:00–19:00 — choose All day to open a session');
    final n = api.gets.length;
    await _tapRow(tester, 'Lunch (12:00-17:00)');
    expect(api.gets.length, n);
    expect(_text(tester, find.byKey(const ValueKey('reports-slot'))), contains('Custom · 16:00–19:00'),
        reason: 'the slot the reader chose is not swapped for a wider one');

    // Inside the pick it still opens: Lunch's own row, under Lunch.
    await _pick(tester, 'lunch');
    expect(_text(tester, find.byKey(const ValueKey('reports-drill'))),
        'Some rows open that session, day by day · 2 of 3 rows name none');
    await _tapRow(tester, 'Lunch (12:00-17:00)');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('slot=lunch'));
    expect(call, contains('bucket=day'));
  });

  testWidgets('under a slot crossing midnight, the small-hours rows do not open — they count on the day before',
      (tester) async {
    final api = await _mount(tester, api: _SlotApi()..hourRows = const ['22:00-23:00', '01:00-02:00']);
    await _openTab(tester, 'Sales Summary');
    await _pickCustom(tester, '22:00', '02:00');
    await tester.tap(find.text('By hour of day'));
    await tester.pumpAndSettle();
    expect(_text(tester, find.byKey(const ValueKey('reports-drill'))),
        'Some rows open that hour, day by day · 1 of 2 rows name none');

    // Over 1–15 Aug this row is 2–16 Aug 01:xx; a plain 01:00–02:00 is 1–15 Aug.
    final n = api.gets.length;
    await _tapRow(tester, '01:00-02:00');
    expect(api.gets.length, n);

    // The evening sits on its own day under both, so it opens.
    await _tapRow(tester, '22:00-23:00');
    final call = api.lastCallTo('/reports/mis/sales-summary');
    expect(call, contains('time_from=22%3A00&time_to=23%3A00'));
    expect(call, contains('bucket=day'));
  });

  testWidgets('the export names the slot the server applied — filename and preamble', (tester) async {
    Uint8List? bytes;
    String? name;
    ReportExporter.overrideDeliver = (b, filename, format) async {
      bytes = b;
      name = filename;
      return const ReportExportResult('Saved');
    };
    await _mount(tester);
    await _pick(tester, 'lunch');
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.byKey(const ValueKey('reports-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(name, 'sales-summary_kalyani-nagar_2026-08-01_to_2026-08-02_lunch-1200-1700.csv');
    expect(utf8.decode(bytes!), contains('Time slot,"Lunch (12:00–17:00) restaurant time, on each day of the range"'));

    // All day: the filename every earlier export had.
    await _pick(tester, 'all');
    await tester.tap(find.byKey(const ValueKey('reports-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(name, 'sales-summary_kalyani-nagar_2026-08-01_to_2026-08-02.csv');
    expect(utf8.decode(bytes!), contains('Time slot,All day'));
  });

  testWidgets('the clamp chip reads a LIST — empty is nothing, a date clamp and a slot clamp each speak',
      (tester) async {
    await _mount(tester);
    expect(find.byKey(const ValueKey('reports-clamp')), findsNothing);
    expect(find.byKey(const ValueKey('reports-slot-clamp')), findsNothing);

    await _mount(tester, api: _SlotApi()..clamped = const ['span_capped']);
    expect(find.byKey(const ValueKey('reports-clamp')), findsOneWidget,
        reason: '`clamped == true` never matched the list the server sends');
    expect(find.text('Range shortened to 2026-08-01 – 2026-08-02'), findsOneWidget);

    await _mount(tester, api: _SlotApi()..clamped = const ['slot_unknown']);
    expect(find.byKey(const ValueKey('reports-clamp')), findsNothing);
    expect(find.text('That session no longer exists — showing all day'), findsOneWidget);
  });

  testWidgets('a 360dp phone lays out the chip, the four-way segment and both sheets without overflow',
      (tester) async {
    await _mount(tester, width: 360, height: 780);
    expect(tester.takeException(), isNull);
    await _openTab(tester, 'Sales Summary');
    expect(find.text('By session'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _openChip(tester);
    await tester.tap(find.byKey(const ValueKey('slot-option-custom')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'custom time fields on a phone');
    await tester.tap(find.byKey(const ValueKey('slot-manage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slot-edit-name-1')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the editor rows on a phone');
  });
}
