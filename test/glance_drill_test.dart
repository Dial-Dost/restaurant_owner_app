import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/glance_drill.dart';
import 'package:restaurant_owner_app/services/date_range.dart';

/// Where each element of "Today at a glance" leads (client item 10) — the pure
/// half. The widget half is test/overview_glance_test.dart.
///
/// THE ANTI-DRIFT PIN. The server ships every destination; this app mirrors the
/// server's table for a backend that does not. A mirror that drifted would send
/// an owner on an older backend somewhere a newer one would not, so the table
/// here is parsed against `Restaurant_Backend/glance_drill.ts` entry for entry
/// when that checkout sits beside this one — the simulation_catalogue_pin_test
/// posture, skipping with a stated reason when it does not.

File _backend(String rel) => File('../Restaurant_Backend/$rel');
File _shell() => File('lib/screens/home_shell.dart');

/// One route out of the TypeScript, as plain values.
typedef _TsRoute = ({
  String module,
  String? report,
  String window,
  String? method,
  bool bills,
  List<String> fallbacks,
  String? secondaryModule,
  String? secondaryWindow,
  String? secondaryMethod,
  bool secondaryBills,
});

String? _field(String body, String name) => RegExp('\\b$name: "([^"]*)"').firstMatch(body)?.group(1);

/// A deliberately dumb reader for `GLANCE_ROUTES`: each top-level key, its
/// braces matched by depth, comments stripped first.
Map<String, _TsRoute> _parseRoutes(String source) {
  final start = source.indexOf('export const GLANCE_ROUTES');
  expect(start, greaterThan(-1), reason: 'GLANCE_ROUTES not found in the backend');
  final open = source.indexOf('{', source.indexOf('=', start));
  var depth = 0;
  var end = open;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  final body = source
      .substring(open + 1, end)
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
      .join('\n');
  final out = <String, _TsRoute>{};
  var i = 0;
  final keyRe = RegExp(r'([a-z_]+):\s*\{');
  while (true) {
    final at = _skipWs(body, i);
    final m = at >= body.length ? null : keyRe.matchAsPrefix(body, at);
    if (m == null) break;
    final key = m.group(1)!;
    var d = 0;
    var j = m.end - 1;
    for (; j < body.length; j++) {
      if (body[j] == '{') d++;
      if (body[j] == '}') {
        d--;
        if (d == 0) break;
      }
    }
    final entry = body.substring(m.end, j);
    final secAt = entry.indexOf('secondary:');
    final own = secAt < 0 ? entry : entry.substring(0, secAt);
    final sec = secAt < 0 ? '' : entry.substring(secAt);
    final fb = RegExp(r'fallbacks:\s*\[([^\]]*)\]').firstMatch(own)?.group(1) ?? '';
    out[key] = (
      module: _field(own, 'module')!,
      report: _field(own, 'report'),
      window: _field(own, 'window')!,
      method: _field(own, 'method'),
      bills: RegExp(r'\bbills:\s*true').hasMatch(own),
      fallbacks: [for (final f in RegExp(r'"([^"]+)"').allMatches(fb)) f.group(1)!],
      secondaryModule: secAt < 0 ? null : _field(sec, 'module'),
      secondaryWindow: secAt < 0 ? null : _field(sec, 'window'),
      secondaryMethod: secAt < 0 ? null : _field(sec, 'method'),
      secondaryBills: secAt >= 0 && RegExp(r'\bbills:\s*true').hasMatch(sec),
    );
    i = j + 1;
    // Past the comma that ends the entry.
    while (i < body.length && (body[i] == ',' || body[i].trim().isEmpty)) {
      i++;
    }
  }
  return out;
}

int _skipWs(String s, int i) {
  while (i < s.length && s[i].trim().isEmpty) {
    i++;
  }
  return i;
}

Map<String, dynamic> _serverTarget(String module, Map<String, String> params, String href, {bool bills = false}) => {
      'module': module,
      'params': params,
      'href': href,
      if (bills) 'bills': true,
    };

void main() {
  const today = '2026-09-17';
  const monthFrom = '2026-09-01';

  group('the table mirrors the backend', () {
    test('every route, field for field', () {
      final f = _backend('glance_drill.ts');
      if (!f.existsSync()) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      final ts = _parseRoutes(f.readAsStringSync().replaceAll('\r\n', '\n'));
      // A parser that silently read nothing would make every check below vacuous.
      expect(ts.length, kGlanceRoutes.length);
      expect(ts.keys.toSet(), kGlanceRoutes.keys.toSet());
      for (final e in kGlanceRoutes.entries) {
        final t = ts[e.key]!;
        final d = e.value;
        expect(
          // Lists joined: a record compares a List by identity.
          (t.module, t.report, t.window, t.method, t.bills, t.fallbacks.join(',')),
          (d.module, d.report, d.window.name, d.method, d.bills, d.fallbacks.join(',')),
          reason: e.key,
        );
        expect(
          (t.secondaryModule, t.secondaryWindow, t.secondaryMethod, t.secondaryBills),
          (d.secondary?.module, d.secondary?.window.name, d.secondary?.method, d.secondary?.bills ?? false),
          reason: '${e.key} (secondary)',
        );
      }
    });

    test('the module list, and the figure keys, are the backend\'s', () {
      final f = _backend('glance_drill.ts');
      if (!f.existsSync()) {
        markTestSkipped('no Restaurant_Backend checkout beside this one');
        return;
      }
      final src = f.readAsStringSync();
      final modules = src.substring(src.indexOf('GLANCE_APP_MODULES'), src.indexOf('};', src.indexOf('GLANCE_APP_MODULES')));
      final names = [for (final m in RegExp(r'^\s*"?([A-Za-z ]+?)"?:\s*"/dashboard', multiLine: true).allMatches(modules)) m.group(1)!];
      expect(names.toSet(), kGlanceAppModules.toSet());
      final figures = RegExp(r'GLANCE_FIGURE_KEYS = \[([^\]]*)\]').firstMatch(src)!.group(1)!;
      expect([for (final m in RegExp(r'"([a-z_]+)"').allMatches(figures)) m.group(1)!], kGlanceFigureKeys);
    });

    test('every module the table names is one the shell registers', () {
      final labels = [for (final m in RegExp(r"_Module\('([^']+)'").allMatches(_shell().readAsStringSync())) m.group(1)!];
      for (final m in kGlanceAppModules) {
        expect(labels, contains(m));
      }
      for (final r in kGlanceRoutes.values) {
        expect(kGlanceAppModules, contains(r.module));
        for (final f in r.fallbacks) {
          expect(kGlanceAppModules, contains(f));
        }
      }
    });
  });

  group('the fallback table resolves exactly as the server does', () {
    // Copied from GET /analytics/headline on the backend at this commit, for
    // the same day. If the two ever disagree, a new app on an old backend would
    // land somewhere a new app on a new backend would not.
    final serverCash = <String, dynamic>{
      ..._serverTarget('Reports', {'report': 'settlement_summary', 'from': today, 'to': today, 'slot': 'all'},
          '/dashboard/reports?report=settlement_summary&from=$today&to=$today&slot=all'),
      'fallbacks': [
        _serverTarget('Accounting', {'from': today, 'to': today, 'method': 'Cash'},
            '/dashboard/accounting?from=$today&to=$today&method=Cash#settled-bills', bills: true),
        _serverTarget('Analytics', {}, '/dashboard/analytics'),
      ],
      'secondary': _serverTarget('Cash register', {}, '/dashboard/cash'),
    };
    final serverRow = <String, dynamic>{
      ..._serverTarget('Reports', {'report': 'settlement_summary', 'from': today, 'to': today, 'slot': 'all'}, ''),
      'fallbacks': [
        _serverTarget('Accounting', {'from': today, 'to': today, 'method': 'Split'}, '', bills: true),
        _serverTarget('Analytics', {}, ''),
      ],
      'secondary': _serverTarget('Accounting', {'from': today, 'to': today, 'method': 'Split'}, '', bills: true),
    };
    final serverMonth = <String, dynamic>{
      ..._serverTarget('Reports', {'report': 'sales_summary', 'from': monthFrom, 'to': today, 'slot': 'all'}, ''),
      'fallbacks': [
        _serverTarget('Accounting', {'from': monthFrom, 'to': today}, ''),
        _serverTarget('History', {'from': monthFrom, 'to': today}, ''),
        _serverTarget('Analytics', {}, ''),
      ],
    };

    void same(GlanceDrill a, GlanceDrill b) {
      expect(a.primary, b.primary);
      expect(a.fallbacks, b.fallbacks);
      expect(a.secondary, b.secondary);
    }

    test('cash collection: Settlement Summary, Accounting keeps the Cash filter, the drawer second', () {
      same(glanceFallbackDrill('cash_collection', today: today, monthFrom: monthFrom)!, GlanceDrill.fromJson(serverCash)!);
    });

    test("a mode's row: Unallocated's bills are the Split bills", () {
      same(glanceFallbackDrill('by_method_row', today: today, monthFrom: monthFrom, rowMethod: 'Unallocated')!,
          GlanceDrill.fromJson(serverRow)!);
    });

    test('month to date: the month window on every windowed module', () {
      same(glanceFallbackDrill('month_to_date', today: today, monthFrom: monthFrom)!, GlanceDrill.fromJson(serverMonth)!);
      same(glanceFallbackDrill('month', today: today, monthFrom: monthFrom)!, GlanceDrill.fromJson(serverMonth)!);
    });

    test('every Reports target is the day (or month), all day; nothing else carries a window it cannot read', () {
      for (final key in kGlanceRoutes.keys) {
        final d = glanceFallbackDrill(key, today: today, monthFrom: monthFrom, rowMethod: 'Cash')!;
        for (final t in [d.primary, ...d.fallbacks, ?d.secondary]) {
          switch (t.module) {
            case 'Reports':
              expect((t.slotAll, t.to, t.report != null), (true, today, true), reason: key);
            case 'Accounting':
            case 'History':
              expect(t.to, today, reason: key);
            default:
              expect((t.from, t.to, t.method, t.report, t.slotAll), (null, null, null, null, false), reason: '$key -> ${t.module}');
          }
          if (t.bills) expect(t.module, 'Accounting', reason: key);
        }
      }
    });

    test('an unknown key has no destination', () {
      expect(glanceFallbackDrill('covers', today: today, monthFrom: monthFrom), isNull);
    });
  });

  group('reading the payload', () {
    Map<String, dynamic> headline({Map<String, dynamic> over = const {}}) => {
          'today': today,
          'month_from': monthFrom,
          'today_net': {'value': 1, 'label': 'n', 'hint': 'h'},
          ...over,
        };

    test("the server's drill wins over the table", () {
      final h = headline(over: {
        'today_net': {
          'value': 1,
          'label': 'n',
          'hint': 'h',
          'drill': _serverTarget('History', {'from': today, 'to': today}, '/dashboard/history'),
        },
        'drills': {
          'nc': _serverTarget('Analytics', {}, '/dashboard/analytics'),
          'by_method_rows': {'Upi': _serverTarget('Orders', {}, '/dashboard/orders')},
        },
      });
      expect(glanceDrillOf(h, 'today_net')!.primary, const GlanceTarget(module: 'History', from: today, to: today));
      expect(glanceDrillOf(h, 'nc')!.primary, const GlanceTarget(module: 'Analytics'));
      expect(glanceDrillOf(h, 'by_method_row', rowMethod: 'Upi')!.primary, const GlanceTarget(module: 'Orders'));
      // A mode the server named no drill for falls back to the table.
      expect(glanceDrillOf(h, 'by_method_row', rowMethod: 'Card')!.secondary!.method, 'Card');
    });

    test('an older backend (no drill, no drills) gets the table, on its own day', () {
      final d = glanceDrillOf(headline(), 'today_net')!;
      expect(d.primary,
          const GlanceTarget(module: 'Reports', report: 'sales_summary', from: today, to: today, slotAll: true));
      expect(glanceDrillOf(headline(), 'header')!.primary.report, 'sales_summary');
    });

    test('a malformed drill is not a destination', () {
      final h = headline(over: {
        'today_net': {'value': 1, 'label': 'n', 'drill': {'params': {}}},
        'drills': {'nc': 'Reports', 'by_method_rows': []},
      });
      expect(glanceDrillOf(h, 'today_net')!.primary.module, 'Reports', reason: 'fell back to the table');
      expect(glanceDrillOf(h, 'nc')!.primary.report, 'nc_summary');
      expect(GlanceDrill.fromJson({'module': 'Reports', 'fallbacks': [{'nope': 1}, 7]})!.fallbacks, isEmpty);
    });

    test('no day on the payload means no table fallback at all', () {
      expect(glanceDrillOf({'today_net': {'value': 1}}, 'today_net'), isNull);
    });

    test('glanceRowMethod', () {
      expect(glanceRowMethod(' Unallocated '), 'Split');
      expect(glanceRowMethod('Upi '), 'Upi');
    });
  });

  group('resolving for a user', () {
    final d = glanceFallbackDrill('cash_collection', today: today, monthFrom: monthFrom)!;

    test('the first module this user can open, in order', () {
      expect(d.resolve((m) => true)!.module, 'Reports');
      expect(d.resolve((m) => m != 'Reports')!.module, 'Accounting');
      expect(d.resolve((m) => m == 'Analytics')!.module, 'Analytics');
      expect(d.resolve((m) => false), isNull);
    });

    test('the secondary only when it can be opened and is not the primary again', () {
      expect(d.resolveSecondary((m) => true)!.module, 'Cash register');
      expect(d.resolveSecondary((m) => m != 'Cash register'), isNull);
      final row = glanceFallbackDrill('by_method_row', today: today, monthFrom: monthFrom, rowMethod: 'Upi')!;
      // Without Reports the row's first stop IS its bills — no second button to the same list.
      expect(row.resolve((m) => m != 'Reports'), row.secondary);
      expect(row.resolveSecondary((m) => m != 'Reports'), isNull);
    });
  });

  group('the window a jump lands on', () {
    final now = DateTime(2026, 9, 17, 15);

    test("the device's today is the Today preset, so it moves with the calendar", () {
      expect(glanceWindowOf(const GlanceTarget(module: 'Reports', from: today, to: today), now: now),
          DateRange.fromPreset(RangePreset.today, now: now));
    });

    test('the month to today is the This month preset', () {
      expect(glanceWindowOf(const GlanceTarget(module: 'Reports', from: monthFrom, to: today), now: now),
          DateRange.fromPreset(RangePreset.thisMonth, now: now));
    });

    test("the server's day, pinned, when the device disagrees", () {
      const yesterday = '2026-09-16';
      expect(glanceWindowOf(const GlanceTarget(module: 'Reports', from: yesterday, to: yesterday), now: now),
          const DateRange(from: yesterday, to: yesterday, preset: RangePreset.custom));
      expect(glanceWindowOf(const GlanceTarget(module: 'History', from: '2026-08-01', to: '2026-08-31'), now: now),
          const DateRange(from: '2026-08-01', to: '2026-08-31', preset: RangePreset.custom));
    });

    test('on the 1st, today is Today, not This month', () {
      final first = DateTime(2026, 9, 1, 10);
      expect(glanceWindowOf(const GlanceTarget(module: 'Reports', from: monthFrom, to: monthFrom), now: first)!.preset,
          RangePreset.today);
    });

    test('no window, no range', () {
      expect(glanceWindowOf(const GlanceTarget(module: 'Tables')), isNull);
      expect(glanceWindowOf(const GlanceTarget(module: 'Reports', from: 'soon', to: today)), isNull);
    });
  });

  group('the copy', () {
    test('the empty-day sentence counts the open bills in words', () {
      expect(glanceOpenBillsSentence(0), 'No bill is open on the floor either.');
      expect(glanceOpenBillsSentence(1), '1 bill is still open on the floor.');
      expect(glanceOpenBillsSentence(3), '3 bills are still open on the floor.');
    });

    test('the online sheet names the four modes the client records as payments', () {
      for (final mode in ['Zomato', 'EazyDiner', 'District', 'Dineout']) {
        expect(kGlanceOnlineNone, contains(mode));
      }
      expect(kGlanceOnlineNone, contains('Collected by payment method'));
    });

    test('the ladder is the Sales Summary columns, in order', () {
      expect([for (final (k, _) in kGlanceLadder) k],
          ['item_total', 'discount', 'net', 'service_charge', 'tax', 'round_off', 'grand_total', 'refund']);
      expect([for (final (_, l) in kGlanceLadder) l],
          ['Item total', 'Discount', 'Net', 'Service charge', 'Tax', 'Round off', 'Gross', 'Refunds']);
    });
  });
}
