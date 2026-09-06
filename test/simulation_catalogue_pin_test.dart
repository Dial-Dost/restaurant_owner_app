import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/simulation_params.dart';

/// THE ANTI-DRIFT TEST.
///
/// The what-if simulator has two clients — the web dashboard and this app — and
/// one server. All three have to agree about what a lever IS: its key, its
/// category, its legal range, its step, and above all its NEUTRAL DEFAULT, which
/// is what the change-dot and both reset controls compare against. Two clients
/// that disagree about a lever's range is a bug that only shows up in
/// production, on somebody's real restaurant.
///
/// So this parses the BACKEND's own catalogue —
/// `Restaurant_Backend/simulation_math.ts`, `PARAM_CATALOG` — and pins the Dart
/// catalogue against it entry for entry. It reads the TypeScript as text on
/// purpose: a generated file or a copied JSON snapshot would be a third source
/// of truth to keep in step, and the point is to have none.
///
/// THE BACKEND, NOT THE WEB DASHBOARD, is the thing to pin against. It is the
/// only authority that matters at runtime — `PARAM_RANGES` is what actually
/// CLAMPS an incoming body, so a client that disagrees about a range ships a
/// slider whose top end silently snaps. The web dashboard's simulator was
/// scrapped on 2026-09-06; had this pinned to it, the guard would have gone
/// quiet the moment that file was deleted, which is precisely when drift starts.
///
/// WHEN THE BACKEND CHECKOUT IS NOT THERE the pin tests skip with a stated
/// reason rather than failing, because the Flutter package can legitimately be
/// built on its own. The self-consistency group below never skips.
File get _webCatalogFile =>
    File('../Restaurant_Backend/simulation_math.ts');

// ---------------------------------------------------------------------------
// A small, deliberately dumb TypeScript reader
// ---------------------------------------------------------------------------

/// One entry of the web PARAM_CATALOG, as parsed out of the source.
typedef WebSpec = ({
  String kind,
  String key,
  String group,
  String label,
  double? min,
  double? max,
  double? step,
  String rawDefault,
  String? defaultFrom,
  bool overridesMeasured,
  bool speculative,
  List<String> optionValues,
});

String? _capture(String text, String pattern) {
  final m = RegExp(pattern).firstMatch(text);
  return m?.group(1);
}

double? _num(String text, String field) {
  final raw = _capture(text, '\\b$field:\\s*(-?[0-9.]+)');
  return raw == null ? null : double.parse(raw);
}

/// `export const DEFAULT_ELASTICITY = -1.3;` -> {'DEFAULT_ELASTICITY': -1.3}
Map<String, double> _webConstants(String source) {
  final out = <String, double>{};
  for (final m in RegExp(r'export const ([A-Z][A-Z0-9_]*)\s*=\s*(-?[0-9.]+);')
      .allMatches(source)) {
    out[m.group(1)!] = double.parse(m.group(2)!);
  }
  return out;
}

List<WebSpec> _parseWebCatalog(String source) {
  final start = source.indexOf('export const PARAM_CATALOG');
  expect(start, greaterThan(-1), reason: 'PARAM_CATALOG not found in the backend catalogue');
  // trimRight matters: this repo arrives CRLF on Windows, and a trailing
  // carriage return would stop `] as const;` ever matching — every comparison
  // below would then pass vacuously against an empty list.
  final lines = source
      .substring(start)
      .split('\n')
      .map((l) => l.trimRight())
      .toList();

  final specs = <WebSpec>[];
  final buffer = StringBuffer();
  var depth = 0;
  var open = false;

  for (final line in lines) {
    if (!open && line == '] as const;') break;
    final body = line.trimLeft();
    if (!open && !body.startsWith('{ key:')) continue;

    // MOST entries are one line, but `plan_tier` carries a nested `options:`
    // array across four. Counting brackets rather than assuming one-line
    // entries is what keeps its three option values from parsing as none —
    // which is exactly how this test would have silently stopped checking the
    // enum while still reporting green.
    open = true;
    buffer.writeln(body);
    for (final c in body.split('')) {
      if (c == '{' || c == '[') depth++;
      if (c == '}' || c == ']') depth--;
    }
    if (depth > 0) continue;

    final entry = buffer.toString();
    buffer.clear();
    open = false;

    specs.add((
      kind: _capture(entry, r'\bkind:\s*"(\w+)"') ?? '',
      key: _capture(entry, r'\bkey:\s*"(\w+)"') ?? '',
      group: _capture(entry, r'\bgroup:\s*"([^"]+)"') ?? '',
      label: _capture(entry, r'\blabel:\s*"([^"]+)"') ?? '',
      min: _num(entry, 'min'),
      max: _num(entry, 'max'),
      step: _num(entry, 'step'),
      rawDefault: (_capture(entry, r'\bdefault:\s*([^,}\n]+)') ?? '').trim(),
      // snake_case on the server; the Dart side spells it defaultFrom.
      defaultFrom: _capture(entry, r'\bdefault_from:\s*"(\w+)"'),
      // NOT a backend concept — it is how a CLIENT renders a lever whose default
      // is the tenant's own measurement (the slider domain widens to hold it).
      // The server expresses the same idea as clampMeasured rather than a flag,
      // so this stays false and the self-consistency group owns it instead of
      // this pin pretending to check it.
      overridesMeasured: false,
      speculative: RegExp(r'\bspeculative:\s*true').hasMatch(entry),
      optionValues: RegExp(r'value:\s*"(\w+)"')
          .allMatches(entry)
          .map((m) => m.group(1)!)
          .toList(),
    ));
  }
  return specs;
}

/// A `default:` cell as a Dart value: a literal, a named constant, `null`, a
/// quoted tier or a boolean.
Object? _resolveWebDefault(String raw, Map<String, double> constants) {
  if (raw == 'null') return null;
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  if (raw.startsWith('"')) return raw.substring(1, raw.length - 1);
  final n = double.tryParse(raw);
  if (n != null) return n;
  final c = constants[raw];
  expect(c, isNotNull, reason: 'unresolved web default constant "$raw"');
  return c;
}

void main() {
  final file = _webCatalogFile;
  final present = file.existsSync();
  final skip = present
      ? null
      : 'The backend is not checked out beside this package '
          '(${file.path}), so there is no catalogue to pin against.';

  group('the Flutter catalogue mirrors the BACKEND catalogue entry for entry', () {
    late List<WebSpec> web;
    late Map<String, double> constants;

    setUpAll(() {
      if (!present) return;
      final source = file.readAsStringSync();
      constants = _webConstants(source);
      web = _parseWebCatalog(source);
    });

    test('the same 34 levers, in the same order', () {
      expect(web.length, 34, reason: 'the backend catalogue itself must still hold 34 levers');
      expect(
        kParamCatalog.map((s) => s.key).toList(),
        web.map((s) => s.key).toList(),
        reason: 'keys and their order must match the backend catalogue exactly',
      );
    }, skip: skip);

    test('groups, labels, ranges, steps and defaults all agree', () {
      // A parser that quietly returned nothing would make every comparison
      // below pass without comparing anything.
      expect(web, hasLength(34), reason: 'the backend catalogue did not parse');
      for (final w in web) {
        final dart = paramSpec(w.key);
        expect(dart, isNotNull, reason: '${w.key} is missing from the Flutter catalogue');
        expect(dart!.group, w.group, reason: '${w.key} group');
        // LABEL IS DELIBERATELY NOT PINNED. The server carries a label as a
        // hint, but wording is presentation and the client owns its own: the
        // screen says "Price adjustment" where the server says "Menu price
        // change". Pinning it would force server phrasing into the UI and make
        // a copy edit look like a contract breach. What must agree is what the
        // MODEL acts on — key, group, kind, range, default and its source.
        expect(dart.speculative, w.speculative, reason: '${w.key} speculative flag');

        final expected = _resolveWebDefault(w.rawDefault, constants);
        switch (dart) {
          case NumberParam():
            expect(w.kind, 'number', reason: '${w.key} kind');
            expect(dart.min, w.min, reason: '${w.key} min');
            expect(dart.max, w.max, reason: '${w.key} max');
            // STEP IS THE ONE FIELD THE CLIENT MAY REFINE. The server clamps
            // min/max and never snaps to a grid (grep simulation_math.ts: no
            // step arithmetic outside the catalogue literal), so a finer client
            // step is safe and gives the owner a usable slider. Exactly three
            // are allowed, and they are named — a fourth is drift and fails.
            const finerSteps = <String, double>{
              'avg_wage_per_shift': 10,   // backend 50
              'marketing_spend': 500,     // backend 1000
              'food_cost_pct': 0.5,       // backend 1
            };
            if (finerSteps.containsKey(w.key)) {
              expect(dart.step, finerSteps[w.key], reason: '${w.key} client step');
              expect(dart.step < w.step!, isTrue,
                  reason: '${w.key}: a client step may only be FINER than the server step');
            } else {
              expect(dart.step, w.step, reason: '${w.key} step');
            }
            // `null` here is not "no default" — it is "the tenant's own measured
            // figure", and which baseline field it comes from is part of the
            // contract (resolveDefaults mirrors resolveParams field for field).
            expect(dart.defaultValue, expected, reason: '${w.key} default');
            expect(dart.defaultFrom, w.defaultFrom, reason: '${w.key} defaultFrom');
          case EnumParam():
            expect(w.kind, 'enum', reason: '${w.key} kind');
            expect(dart.defaultValue, expected, reason: '${w.key} default');
            expect(dart.options.map((o) => o.value).toList(), w.optionValues,
                reason: '${w.key} option values');
          case ToggleParam():
            expect(w.kind, 'toggle', reason: '${w.key} kind');
            expect(dart.defaultValue, expected, reason: '${w.key} default');
        }
      }
    }, skip: skip);

    test('the category list and its order match', () {
      // The backend has no PARAM_GROUPS export — grouping is presentation. But
      // the catalogue is written grouped, so its ORDER OF FIRST APPEARANCE is a
      // real contract and pins the client's headers without inventing a second
      // source of truth.
      expect(web, hasLength(34), reason: 'the backend catalogue did not parse');
      final seen = <String>[];
      for (final w in web) {
        if (!seen.contains(w.group)) seen.add(w.group);
      }
      expect(kParamGroups, seen);
    }, skip: skip);

    test('multi-outlet is an Enterprise capability, matching the server', () {
      final source = file.readAsStringSync();
      for (final tier in kPlanTierOrder) {
        final row = RegExp('$tier: \\{[^}]*\\}').firstMatch(source)!.group(0)!;
        final grants = RegExp(r'multi_outlet:\s*true').hasMatch(row);
        expect(kPlanTiers[tier]!.multiOutlet, grants, reason: '$tier multi_outlet');
      }
    }, skip: skip);
  });

  // These never skip: they hold whether or not the web repo is beside this one.
  group('the catalogue is internally consistent', () {
    // The starting selection is a pure CLIENT choice — the backend has no such
    // concept — so it is pinned literally here rather than against a source
    // that cannot know it. These are the original eight: the levers this screen
    // shipped with before it became editable, and the set an owner who has
    // never touched the picker still sees.
    test('the screen still opens on the original eight levers', () {
      expect(kInitialActiveKeys, const [
        'price_adjust_pct',
        'elasticity',
        'staff_count',
        'avg_wage_per_shift',
        'tat_target_min',
        'extra_expediters',
        'marketing_spend',
        'food_cost_pct',
      ]);
      for (final k in kInitialActiveKeys) {
        expect(paramSpec(k), isNotNull, reason: '\$k is active by default but not in the catalogue');
      }
    });

    // overridesMeasured is how a client renders a lever whose default is the
    // tenant's own measurement: the slider DOMAIN widens to hold it, so an
    // 18-table room is not silently clamped up to the catalogue's 20. The
    // backend expresses the same idea as clampMeasured rather than as a flag,
    // which is why this is pinned here and not against the catalogue.
    test('exactly the two measured-override levers widen their domain', () {
      final flagged = kParamCatalog
          .whereType<NumberParam>()
          .where((s) => s.overridesMeasured)
          .map((s) => s.key)
          .toList();
      expect(flagged, const ['table_count', 'fixed_costs_per_day']);
      for (final k in flagged) {
        final spec = paramSpec(k)! as NumberParam;
        expect(spec.defaultFrom, isNotNull,
            reason: '\$k overrides a measurement, so it must take its default from one');
      }
    });

    test('34 unique keys, every group known, every default inside its range', () {
      expect(kParamCatalog.length, 34);
      expect(kParamCatalog.map((s) => s.key).toSet().length, 34, reason: 'duplicate key');
      for (final spec in kParamCatalog) {
        expect(kParamGroups, contains(spec.group), reason: '${spec.key} group');
        if (spec is NumberParam) {
          expect(spec.min, lessThan(spec.max), reason: '${spec.key} range');
          expect(spec.step, greaterThan(0), reason: '${spec.key} step');
          final d = spec.defaultValue;
          if (d != null) {
            expect(d, inInclusiveRange(spec.min, spec.max), reason: '${spec.key} default');
          } else {
            expect(spec.defaultFrom, isNotNull,
                reason: '${spec.key} has no default and no baseline field to take one from');
          }
        }
      }
    });

    test('resolveDefaults answers for every key in the catalogue', () {
      final defaults = resolveDefaults(const {
        'staff_count': 12,
        'labour_cost_per_day': 6000,
        'avg_tat_min': 42,
        'food_cost_pct': 32,
        'table_count': 18,
        'fixed_costs_per_day': 5000,
      });
      for (final spec in kParamCatalog) {
        expect(defaults.containsKey(spec.key), isTrue, reason: '${spec.key} has no default');
      }
      expect(defaults.length, kParamCatalog.length);
    });

    test('the six per-tenant defaults come from the baseline, mirroring resolveParams', () {
      final defaults = resolveDefaults(const {
        'staff_count': 12,
        'labour_cost_per_day': 6000,
        'avg_tat_min': 42,
        'food_cost_pct': 32,
        'table_count': 18,
        'fixed_costs_per_day': 5000,
      });
      expect(defaults['staff_count'], 12);
      // The wage that reproduces the measured labour bill: 6000 / 12.
      expect(defaults['avg_wage_per_shift'], 500);
      expect(defaults['tat_target_min'], 42);
      expect(defaults['food_cost_pct'], 32);
      // Both of these OVERRIDE a measurement, so their neutral value is that
      // measurement even though it sits outside the slider's own range (the
      // table slider starts at 20 — an 18-table room is still 18 tables).
      expect(defaults['table_count'], 18);
      expect(defaults['fixed_costs_per_day'], 5000);
      final tables = paramSpec('table_count')! as NumberParam;
      expect(sliderDomain(tables, 18).min, 18, reason: 'the domain widens to hold the measurement');
      expect(tables.min, 20, reason: 'the catalogue range itself is unchanged');
    });

    test('an empty tenant still gets finite, in-range defaults', () {
      final defaults = resolveDefaults(null);
      for (final spec in kParamCatalog) {
        final v = defaults[spec.key];
        if (spec is NumberParam) {
          expect(v, isA<double>(), reason: spec.key);
          expect((v! as double).isFinite, isTrue, reason: spec.key);
        }
      }
      // With no headcount at all the wage falls back to the model's own
      // DEFAULT_WAGE_PER_SHIFT rather than dividing by zero.
      expect(defaults['avg_wage_per_shift'], kDefaultWagePerShift);
      expect(defaults['staff_count'], 1);
    });

    test('each category is sorted alphabetically and empty ones never render', () {
      final groups = groupedParams();
      expect(groups.map((g) => g.group).toList(), kParamGroups);
      for (final g in groups) {
        final labels = g.specs.map((s) => s.label).toList();
        expect(labels, orderedEquals(labels.toList()..sort()), reason: '${g.group} order');
      }
      // A filter that matches nothing drops every header rather than rendering
      // six empty ones.
      expect(groupedParams(filter: (_) => false), isEmpty);
      expect(groupedParams(query: 'zzzz-no-such-lever'), isEmpty);
    });

    test('search filters the whole catalogue, not one category', () {
      final hits = groupedParams(query: 'aggregator');
      // "Delivery aggregator mix" and "Aggregator commission" both live under
      // Marketing & growth; the word also appears in another group's explainer,
      // which is deliberate — the search reads label, group and explainer.
      final keys = hits.expand((g) => g.specs).map((s) => s.key).toList();
      expect(keys, contains('aggregator_mix_pct'));
      expect(keys, contains('aggregator_commission_pct'));
      expect(keys, isNot(contains('staff_count')));
    });
  });
}
