// What-if simulator: the parameter catalogue behind the editable lever list.
//
// MIRROR, NOT A SECOND SOURCE OF TRUTH. Every key, group, label, range, step and
// neutral default below is copied from the web dashboard's
// `src/lib/simulation-params.ts`, which is itself a mirror of the backend's
// `simulation_math.ts` (PARAM_RANGES, PARAM_CATALOG, resolveParams). Two clients
// that disagree about a lever's range is a bug that only shows up in production,
// so `test/simulation_catalogue_pin_test.dart` parses the TypeScript file and
// pins this list against it entry for entry.
//
// (Where the backend's own PARAM_CATALOG lists a COARSER step than the web —
// avg_wage_per_shift 50 vs 10, marketing_spend 1000 vs 500, food_cost_pct 1 vs
// 0.5 — the ranges still agree and the server clamps regardless. The shipped UI
// step is the web's, and that is the one this file mirrors.)
//
// NEUTRALITY — THE REASON THE PICKER IS SAFE AT ALL. The server resolves a
// MISSING field to the neutral value for THIS TENANT
// (`clamp(body.x, min, max, fallback)` -> `finite(undefined, fallback)` -> the
// fallback). That is why an inactive lever is simply OMITTED from the POST body:
// omitting it and sending its default are the same simulation. So a removed
// lever contributes its default, never zero.
//
// Nothing may key off the mere PRESENCE of a field. That was broken once:
// acquisition_per_1000 used to switch the marketing model on presence alone, so
// adding the lever and never touching it moved profit ~Rs 9,740/day with no
// change-dot to explain it. It now scales the curve and is neutral at its
// default. The client must not reintroduce presence-sensitive behaviour either.
//
// PER-TENANT DEFAULTS. Six levers have no catalogue default at all — their
// neutral value is the tenant's own measured figure (headcount, the wage that
// reproduces the labour bill, measured TAT, measured food %, table count, fixed
// costs). They carry `defaultValue: null` + `defaultFrom`, and [resolveDefaults]
// derives them from the live baseline exactly the way resolveParams does.

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Total-arithmetic helpers (the same NaN firewall the screen and backend use)
// ---------------------------------------------------------------------------

/// A finite double out of whatever JSON handed over.
double simFinite(dynamic value, [double fallback = 0]) {
  final n = (value is num) ? value.toDouble() : double.tryParse('${value ?? ''}');
  return (n == null || !n.isFinite) ? fallback : n;
}

double _clamp(double value, double min, double max) => math.min(max, math.max(min, value));

/// JavaScript's `${n}` for a number: "5", "-1.3", "0.5" — never "5.0".
/// The catalogue's format strings are copied from the web, so they have to
/// stringify numbers the way the web does or the two screens read differently.
String simNumStr(double v) {
  if (!v.isFinite) return '0';
  if (v == 0) return '0'; // also normalises -0.0, which prints as "-0"
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(4);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  s = s.replaceFirst(RegExp(r'\.$'), '');
  return s;
}

/// Signed percent, e.g. "+5%" / "-3%".
String _pct(double v) => '${v > 0 ? '+' : ''}${simNumStr(v)}%';

/// How a lever renders money. Supplied by the screen so the simulator keeps the
/// app's own "-₹1234" convention (sign outside the symbol) in one place.
typedef MoneyFormat = String Function(num v);

// ---------------------------------------------------------------------------
// Neutral constants — mirrored from simulation_math.ts, name for name.
// ---------------------------------------------------------------------------

const double kDefaultElasticity = -1.3;
const double kDefaultWagePerShift = 450;
const double kDefaultTatMin = 45;
const double kDefaultFoodCostPct = 32;
const double kDefaultPartySize = 3;
const double kDefaultCaptainSharePct = 20;
const double kDefaultKitchenStations = 3;
const double kBaselineWastePct = 3;
const double kBaselineNoShowPct = 10;
const double kBaselineRetentionPct = 40;
const double kDefaultTaxRatePct = 5;
const double kDefaultAcquisitionPer1000 = 2;
const double kDefaultAggregatorCommissionPct = 20;

/// Subscription tiers, mirrored from the backend's PLAN_TIERS (which reads
/// migration 009's `platform.plans` seed). `multi_outlet` is granted to the TOP
/// TIER ONLY — growth's seeded features say `"multi_outlet": false` — so the
/// second-outlet toggle is an Enterprise capability, not a Growth one.
class PlanTierSpec {
  const PlanTierSpec(this.label, this.monthlyFee, this.multiOutlet);
  final String label;
  final int monthlyFee;
  final bool multiOutlet;
}

const Map<String, PlanTierSpec> kPlanTiers = {
  'starter': PlanTierSpec('Starter', 0, false),
  'growth': PlanTierSpec('Growth', 1499, false),
  'enterprise': PlanTierSpec('Enterprise', 3999, true),
};

const List<String> kPlanTierOrder = ['starter', 'growth', 'enterprise'];

/// Unknown/garbage tiers resolve to Starter, never a crash. "pro"/"premium" are
/// accepted by the backend as aliases for the seeded top tier.
String toPlanTier(Object? value) {
  final key = value is String ? value.trim().toLowerCase() : '';
  if (key == 'growth') return 'growth';
  if (key == 'enterprise' || key == 'pro' || key == 'premium') return 'enterprise';
  return 'starter';
}

// ---------------------------------------------------------------------------
// Catalogue shapes
// ---------------------------------------------------------------------------

const List<String> kParamGroups = [
  'Pricing & demand',
  'Staffing',
  'Operations',
  'Marketing & growth',
  'Overhead',
  'Scale',
];

/// One lever in the catalogue. Sealed so the screen's `switch` over the three
/// control shapes is exhaustive — a fourth kind cannot be added without the
/// analyzer pointing at every place that renders one.
sealed class ParamSpec {
  const ParamSpec({
    required this.key,
    required this.group,
    required this.label,
    required this.explainer,
    this.speculative = false,
  });

  /// The POST body field name. Identical on both clients and the server.
  final String key;
  final String group;
  final String label;

  /// One line under the control: what the lever does, and where it is an
  /// approximation.
  final String explainer;

  /// Set when the lever is a rough sketch rather than a measured relationship.
  final bool speculative;
}

/// A slider.
class NumberParam extends ParamSpec {
  const NumberParam({
    required super.key,
    required super.group,
    required super.label,
    required super.explainer,
    required this.min,
    required this.max,
    required this.step,
    required this.defaultValue,
    required this.format,
    this.defaultFrom,
    this.overridesMeasured = false,
    super.speculative,
  });

  final double min;
  final double max;
  final double step;

  /// Neutral value, or `null` when it is the tenant's own measured figure.
  final double? defaultValue;

  /// Baseline field a per-tenant default is derived from (documentation + tests).
  final String? defaultFrom;

  /// True for the two levers that OVERRIDE a measured baseline field. Their
  /// legal domain widens to include that measurement (an 18-table room, ₹30,000
  /// a day of rent), exactly as the backend's `clampMeasured` does — otherwise a
  /// screen nobody touched would silently simulate a different restaurant.
  final bool overridesMeasured;

  final String Function(double value, MoneyFormat money) format;
}

/// A segmented control.
class EnumParam extends ParamSpec {
  const EnumParam({
    required super.key,
    required super.group,
    required super.label,
    required super.explainer,
    required this.options,
    required this.defaultValue,
    super.speculative,
  });

  final List<({String value, String label})> options;
  final String defaultValue;
}

/// A switch.
class ToggleParam extends ParamSpec {
  const ToggleParam({
    required super.key,
    required super.group,
    required super.label,
    required super.explainer,
    required this.defaultValue,
    super.speculative,
  });

  final bool defaultValue;
}

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

/// THE ORIGINAL EIGHT COME FIRST AND ARE UNCHANGED — same min/max/step and the
/// same neutral defaults as the fixed eight-slider screen this picker replaces.
final List<ParamSpec> kParamCatalog = List<ParamSpec>.unmodifiable(<ParamSpec>[
  // --- The original eight ---------------------------------------------------
  NumberParam(
    key: 'price_adjust_pct', group: 'Pricing & demand',
    label: 'Price adjustment', min: -20, max: 30, step: 1, defaultValue: 0,
    explainer: 'Across-the-board menu price change. APC moves with it; demand responds via elasticity.',
    format: (v, money) => _pct(v),
  ),
  NumberParam(
    key: 'elasticity', group: 'Pricing & demand',
    label: 'Price elasticity', min: -2, max: -0.5, step: 0.1, defaultValue: kDefaultElasticity,
    explainer: 'How strongly demand reacts to price: −1.3 means a 10% price rise loses 13% of covers.',
    format: (v, money) => v.toStringAsFixed(1),
  ),
  NumberParam(
    key: 'staff_count', group: 'Staffing',
    label: 'Staff count', min: 1, max: 60, step: 1, defaultValue: null, defaultFrom: 'staff_count',
    explainer: 'Rostered staff per day — drives the daily wage bill.',
    format: (v, money) => '${simNumStr(v)} staff',
  ),
  NumberParam(
    key: 'avg_wage_per_shift', group: 'Staffing',
    label: 'Average wage per shift', min: 100, max: 2000, step: 10,
    defaultValue: null, defaultFrom: 'labour_cost_per_day',
    explainer: 'What one staff member costs per shift. Its default is the wage that reproduces your measured labour bill.',
    format: (v, money) => '${money(v)}/shift',
  ),
  NumberParam(
    key: 'tat_target_min', group: 'Operations',
    label: 'Turnaround time target', min: 10, max: 60, step: 1,
    defaultValue: null, defaultFrom: 'avg_tat_min',
    explainer: 'Target seat-to-settle time. Faster turns seat more covers — but only as fast as staffing can actually achieve.',
    format: (v, money) => '${simNumStr(v)} min',
  ),
  NumberParam(
    key: 'extra_expediters', group: 'Staffing',
    label: 'Extra expediters', min: 0, max: 5, step: 1, defaultValue: 0,
    explainer: 'Each expediter cuts achievable turnaround by 3 min (floor 10 min) and costs ₹2100/shift.',
    format: (v, money) => simNumStr(v),
  ),
  NumberParam(
    key: 'marketing_spend', group: 'Marketing & growth',
    label: 'Marketing spend (one-time)', min: 0, max: 100000, step: 500, defaultValue: 0,
    explainer: 'One-off campaign with diminishing returns. Not amortised into daily profit — payback shows as breakeven days.',
    format: (v, money) => money(v),
  ),
  NumberParam(
    key: 'food_cost_pct', group: 'Operations',
    label: 'Food cost', min: 20, max: 60, step: 0.5, defaultValue: null, defaultFrom: 'food_cost_pct',
    explainer: 'Ingredient cost as a share of revenue.',
    format: (v, money) => '${simNumStr(v)}%',
  ),

  // --- Pricing & demand -----------------------------------------------------
  NumberParam(
    key: 'discount_depth_pct', group: 'Pricing & demand',
    label: 'Average discount depth', min: 0, max: 30, step: 1, defaultValue: 0,
    explainer: 'Average % off a discounted bill. Works with the frequency lever; ingredient cost does not fall — a discount does not make food cheaper.',
    format: (v, money) => '${simNumStr(v)}%',
  ),
  NumberParam(
    key: 'discount_frequency_pct', group: 'Pricing & demand',
    label: 'Bills discounted', min: 0, max: 100, step: 5, defaultValue: 0,
    explainer: 'Share of bills carrying a discount. Revenue falls by depth × frequency.',
    format: (v, money) => '${simNumStr(v)}% of bills',
  ),
  NumberParam(
    key: 'coupon_redemption_pct', group: 'Pricing & demand',
    label: 'Coupon redemption', min: 0, max: 50, step: 5, defaultValue: 0,
    explainer: 'Share of bills that redeem a coupon.',
    format: (v, money) => '${simNumStr(v)}% of bills',
  ),
  NumberParam(
    key: 'coupon_avg_value', group: 'Pricing & demand',
    label: 'Average coupon value', min: 0, max: 500, step: 25, defaultValue: 0,
    explainer: 'Flat ₹ a redeemed coupon takes off the bill.',
    format: (v, money) => money(v),
  ),
  NumberParam(
    key: 'service_charge_pct', group: 'Pricing & demand',
    label: 'Service charge', min: 0, max: 10, step: 0.5, defaultValue: 0,
    explainer: 'Charged on the discounted subtotal by the same billing pipeline the POS prints. Neutral at 0 — your baseline revenue is measured before service charge.',
    format: (v, money) => '${simNumStr(v)}%',
  ),
  NumberParam(
    key: 'tax_rate_pct', group: 'Pricing & demand',
    label: 'Tax rate (display only)', min: 0, max: 28, step: 0.5, defaultValue: kDefaultTaxRatePct,
    explainer: 'Display only. The whole model is pre-tax, so this moves the tax line and nothing else — revenue and net profit are identical at every rate.',
    format: (v, money) => '${simNumStr(v)}%',
  ),
  NumberParam(
    key: 'avg_party_size', group: 'Pricing & demand',
    label: 'Average party size', min: 1, max: 8, step: 0.5, defaultValue: kDefaultPartySize,
    explainer: 'Covers per table. Bigger parties lift the seating ceiling; they do not create demand on their own.',
    format: (v, money) => '${simNumStr(v)} covers/table',
  ),
  NumberParam(
    key: 'loyalty_redemption_pct', group: 'Pricing & demand',
    label: 'Loyalty redemption', min: 0, max: 30, step: 5, defaultValue: 0,
    explainer: 'Share of bills redeeming loyalty. Approximation: there is no loyalty ledger to measure, so one redemption is priced at ₹100.',
    format: (v, money) => '${simNumStr(v)}% of bills',
  ),

  // --- Staffing -------------------------------------------------------------
  NumberParam(
    key: 'captain_share_pct', group: 'Staffing',
    label: 'Captains on the floor', min: 0, max: 100, step: 5, defaultValue: kDefaultCaptainSharePct,
    explainer: 'Captains can bark an order before approval, so a captain-heavy floor gets tickets to the kitchen sooner. Approximation: a full 0→100% swing is worth 4 min of turnaround.',
    format: (v, money) => '${simNumStr(v)}% of staff',
  ),
  NumberParam(
    key: 'shifts_per_day', group: 'Staffing',
    label: 'Shifts per day', min: 1, max: 2, step: 1, defaultValue: 1,
    explainer: 'A second shift doubles both the covers ceiling and the wage bill.',
    format: (v, money) => '${simNumStr(v)} shift${v == 1 ? '' : 's'}/day',
  ),
  NumberParam(
    key: 'overtime_premium_pct', group: 'Staffing',
    label: 'Overtime premium', min: 0, max: 100, step: 10, defaultValue: 0,
    explainer: 'Premium paid on the hourly rate for overtime hours.',
    format: (v, money) => _pct(v),
  ),
  NumberParam(
    key: 'overtime_hours_per_shift', group: 'Staffing',
    label: 'Overtime per shift', min: 0, max: 4, step: 0.5, defaultValue: 0,
    explainer: 'Overtime hours per staff member per shift, priced off the shift wage over an 8-hour shift.',
    format: (v, money) => '${simNumStr(v)} hrs',
  ),
  NumberParam(
    key: 'staff_attendance_pct', group: 'Staffing',
    label: 'Attendance', min: 70, max: 100, step: 5, defaultValue: 100,
    explainer: 'Absence cuts the covers you can actually serve. Payroll is unchanged — rostered staff are still paid.',
    format: (v, money) => '${simNumStr(v)}%',
  ),

  // --- Operations -----------------------------------------------------------
  NumberParam(
    key: 'table_count', group: 'Operations',
    label: 'Tables', min: 20, max: 150, step: 2,
    defaultValue: null, defaultFrom: 'table_count', overridesMeasured: true,
    explainer: 'Overrides your measured table count and caps the covers the room can achieve.',
    format: (v, money) => '${simNumStr(v)} tables',
  ),
  NumberParam(
    key: 'kitchen_stations', group: 'Operations',
    label: 'Kitchen stations', min: 1, max: 8, step: 1, defaultValue: kDefaultKitchenStations,
    explainer: 'Approximation: each station above or below 3 moves achievable turnaround by 2 min. A separate lever from expediters — stations speed up cooking, expediters speed up the pass.',
    format: (v, money) => '${simNumStr(v)} stations',
  ),
  NumberParam(
    key: 'waste_pct', group: 'Operations',
    label: 'Food wastage', min: 0, max: 15, step: 0.5, defaultValue: kBaselineWastePct,
    explainer: 'Wastage as a share of revenue. Neutral at 3% — the level already priced into a measured food cost.',
    format: (v, money) => '${simNumStr(v)}%',
  ),
  NumberParam(
    key: 'ingredient_inflation_pct', group: 'Operations',
    label: 'Ingredient inflation', min: -10, max: 30, step: 1, defaultValue: 0,
    explainer: 'Multiplies your effective food cost percentage.',
    format: (v, money) => _pct(v),
  ),
  NumberParam(
    key: 'no_show_pct', group: 'Operations',
    label: 'Booking no-shows', min: 0, max: 40, step: 5, defaultValue: kBaselineNoShowPct,
    explainer: 'Neutral at 10%. Approximation: only the ~25% of covers that arrive from a booking can no-show; walk-ins cannot.',
    format: (v, money) => '${simNumStr(v)}%',
  ),

  // --- Marketing & growth ---------------------------------------------------
  NumberParam(
    key: 'acquisition_per_1000', group: 'Marketing & growth',
    label: 'Guests per ₹1,000 spent', min: 0, max: 10, step: 0.5, defaultValue: kDefaultAcquisitionPer1000,
    explainer: 'How efficiently marketing spend converts to walk-ins. It scales the diminishing-returns curve rather than replacing it, so 2 is today\'s assumed conversion and leaves the answer unchanged. Extra covers are still capped by what the room can absorb off-peak.',
    format: (v, money) => '${simNumStr(v)} guests',
  ),
  NumberParam(
    key: 'retention_pct', group: 'Marketing & growth',
    label: 'Repeat guests', min: 0, max: 100, step: 5, defaultValue: kBaselineRetentionPct,
    explainer: 'Directional only: a full 0→100% swing moves demand by ±15% of the gap from today\'s 40%. Not a cohort model.',
    format: (v, money) => '${simNumStr(v)}%',
  ),
  NumberParam(
    key: 'aggregator_mix_pct', group: 'Marketing & growth',
    label: 'Delivery aggregator mix', min: 0, max: 60, step: 5, defaultValue: 0,
    explainer: 'Share of covers taken through delivery aggregators. This re-mixes existing demand rather than adding covers, so only the commission bites.',
    format: (v, money) => '${simNumStr(v)}% of covers',
  ),
  NumberParam(
    key: 'aggregator_commission_pct', group: 'Marketing & growth',
    label: 'Aggregator commission', min: 15, max: 30, step: 1, defaultValue: kDefaultAggregatorCommissionPct,
    explainer: 'Commission the aggregator keeps on its share of the discounted subtotal.',
    format: (v, money) => '${simNumStr(v)}%',
  ),

  // --- Overhead -------------------------------------------------------------
  NumberParam(
    key: 'fixed_costs_per_day', group: 'Overhead',
    label: 'Fixed costs', min: 0, max: 20000, step: 500,
    defaultValue: null, defaultFrom: 'fixed_costs_per_day', overridesMeasured: true,
    explainer: 'Overrides the fixed costs derived from your expense categories (rent, power, upkeep — everything that is neither food nor wages).',
    format: (v, money) => '${money(v)}/day',
  ),
  NumberParam(
    key: 'utilities_per_day', group: 'Overhead',
    label: 'Extra utilities', min: 0, max: 5000, step: 250, defaultValue: 0,
    explainer: 'Added on top of fixed costs.',
    format: (v, money) => '${money(v)}/day',
  ),
  const EnumParam(
    key: 'plan_tier', group: 'Overhead',
    label: 'Subscription plan', defaultValue: 'starter',
    options: [
      (value: 'starter', label: 'Starter'),
      (value: 'growth', label: 'Growth'),
      (value: 'enterprise', label: 'Enterprise'),
    ],
    explainer: 'Adds the subscription fee ÷ 30 to daily fixed costs (Starter ₹0, Growth ₹1,499/mo, Enterprise ₹3,999/mo). Only Enterprise includes multi-outlet.',
  ),

  // --- Scale ----------------------------------------------------------------
  const ToggleParam(
    key: 'second_outlet', group: 'Scale',
    label: 'Open a second outlet', defaultValue: false, speculative: true,
    explainer: 'SPECULATIVE — this model has never been validated end to end. It assumes a second site reaches 60% of this one\'s covers while doubling site costs and labour. Treat it as a sketch, not a forecast.',
  ),
]);

final Map<String, ParamSpec> _catalogByKey = {
  for (final spec in kParamCatalog) spec.key: spec,
};

ParamSpec? paramSpec(String key) => _catalogByKey[key];

/// The eight levers this screen has always shown — the starting selection, so
/// nobody's simulator changes shape the day the picker ships.
const List<String> kInitialActiveKeys = [
  'price_adjust_pct', 'elasticity', 'staff_count', 'avg_wage_per_shift',
  'tat_target_min', 'extra_expediters', 'marketing_spend', 'food_cost_pct',
];

// ---------------------------------------------------------------------------
// Defaults — the per-tenant neutral values the dot and the resets compare against
// ---------------------------------------------------------------------------

/// Resolve every lever's NEUTRAL value for this tenant, mirroring the backend's
/// `resolveParams` fallbacks exactly:
///
///   staff_count         clamp(baseline.staff_count, 1, 60), rounded
///   avg_wage_per_shift  clamp(labour / headcount, 100, 2000) — the wage that
///                       reproduces the measured labour bill
///   tat_target_min      clamp(baseline.avg_tat_min, 10, 60)
///   food_cost_pct       clamp(baseline.food_cost_pct, 20, 60)
///   table_count         round(baseline.table_count)    UNCLAMPED (clampMeasured)
///   fixed_costs_per_day baseline.fixed_costs_per_day   UNCLAMPED (clampMeasured)
///
/// The last two OVERRIDE a measurement, so their neutral value is that
/// measurement even when it falls outside the slider's own range.
Map<String, Object> resolveDefaults(Map<String, dynamic>? baseline) {
  final b = baseline;
  final staffCount = math.max(0.0, simFinite(b?['staff_count']));
  final labourPerDay = simFinite(b?['labour_cost_per_day']);
  return <String, Object>{
    // The original eight.
    'price_adjust_pct': 0.0,
    'elasticity': kDefaultElasticity,
    'staff_count': _clamp(staffCount, 1, 60).roundToDouble(),
    'avg_wage_per_shift': _clamp(
      staffCount > 0 ? simFinite(labourPerDay / staffCount, kDefaultWagePerShift) : kDefaultWagePerShift,
      100, 2000,
    ),
    'tat_target_min': _clamp(simFinite(b?['avg_tat_min'], kDefaultTatMin), 10, 60),
    'extra_expediters': 0.0,
    'marketing_spend': 0.0,
    'food_cost_pct': _clamp(simFinite(b?['food_cost_pct'], kDefaultFoodCostPct), 20, 60),

    // Pricing & demand. Every deduction is neutral at 0: the baseline's revenue
    // basis is the taxable base actually billed, so "no extra discount".
    'discount_depth_pct': 0.0,
    'discount_frequency_pct': 0.0,
    'coupon_redemption_pct': 0.0,
    'coupon_avg_value': 0.0,
    // 0, NOT the 1% a menu would suggest — the baseline is measured PRE-service
    // charge, so any other default would invent revenue on an untouched screen.
    'service_charge_pct': 0.0,
    'tax_rate_pct': kDefaultTaxRatePct,
    'avg_party_size': kDefaultPartySize,
    'loyalty_redemption_pct': 0.0,

    // Staffing.
    'captain_share_pct': kDefaultCaptainSharePct,
    'shifts_per_day': 1.0,
    'overtime_premium_pct': 0.0,
    'overtime_hours_per_shift': 0.0,
    'staff_attendance_pct': 100.0,

    // Operations. table_count overrides a measurement -> unclamped.
    'table_count': simFinite(b?['table_count'], 20).roundToDouble(),
    'kitchen_stations': kDefaultKitchenStations,
    'waste_pct': kBaselineWastePct,
    'ingredient_inflation_pct': 0.0,
    'no_show_pct': kBaselineNoShowPct,

    // Marketing & growth.
    'acquisition_per_1000': kDefaultAcquisitionPer1000,
    'retention_pct': kBaselineRetentionPct,
    'aggregator_mix_pct': 0.0,
    'aggregator_commission_pct': kDefaultAggregatorCommissionPct,

    // Overhead & scale. fixed_costs_per_day overrides a measurement -> unclamped.
    'fixed_costs_per_day': simFinite(b?['fixed_costs_per_day']),
    'utilities_per_day': 0.0,
    'plan_tier': 'starter',
    'second_outlet': false,
  };
}

// ---------------------------------------------------------------------------
// Typed accessors. Values live in one uniform `Map<String, Object>` so the
// screen can write `values[key] = v` without a cast; these read them back safely.
// ---------------------------------------------------------------------------

double numberValue(Map<String, Object> values, String key, [double fallback = 0]) {
  final v = values[key];
  return (v is num && v.isFinite) ? v.toDouble() : fallback;
}

String planTierValue(Map<String, Object> values) => toPlanTier(values['plan_tier']);

bool toggleValue(Map<String, Object> values, String key) => values[key] == true;

/// The slider's legal domain. For the two levers that override a measured
/// baseline field this WIDENS to include the measurement, mirroring the
/// backend's `clampMeasured`: an 18-table room or ₹30,000/day of rent is a
/// perfectly legal neutral value even though the slider's own range excludes it.
({double min, double max}) sliderDomain(NumberParam spec, double defaultValue) {
  if (!spec.overridesMeasured) return (min: spec.min, max: spec.max);
  final d = simFinite(defaultValue, spec.min);
  return (min: math.min(spec.min, d), max: math.max(spec.max, d));
}

/// Snap a raw slider position onto the lever's step grid, anchored at the
/// domain's own minimum — which for a widened domain IS the tenant's measured
/// default, so dragging back to the left edge lands exactly on it and the
/// change-dot goes out again.
double snapToStep(NumberParam spec, ({double min, double max}) domain, double raw) {
  final step = spec.step > 0 ? spec.step : 1;
  final k = ((raw - domain.min) / step).roundToDouble();
  final v = _clamp(domain.min + k * step, domain.min, domain.max);
  // Slider arithmetic produces 32.500000000000004; the label and the POST body
  // both have to read 32.5.
  return double.parse(v.toStringAsFixed(4));
}

/// True when a lever sits somewhere other than its (per-tenant) default.
///
/// The web compares with `!==`. Doubles get a hair of tolerance instead, so a
/// slider that landed on 31.999999999999996 does not wear a change-dot it did
/// not earn — the smallest step in the catalogue is 0.1, so no real move hides
/// under it.
bool isChanged(Map<String, Object> values, Map<String, Object> defaults, String key) {
  final v = values[key];
  final d = defaults[key];
  if (v is num && d is num) return (v - d).abs() > 1e-9;
  return v != d;
}

// ---------------------------------------------------------------------------
// Grouping / search for the picker and the active list
// ---------------------------------------------------------------------------

/// Catalogue split by category, each category's levers sorted alphabetically by
/// label. [query] filters the FULL list (across every category); a category with
/// no surviving lever is dropped, so no empty header is ever rendered.
List<({String group, List<ParamSpec> specs})> groupedParams({
  String query = '',
  bool Function(ParamSpec spec)? filter,
}) {
  final needle = query.trim().toLowerCase();
  bool matches(ParamSpec spec) {
    if (filter != null && !filter(spec)) return false;
    if (needle.isEmpty) return true;
    return '${spec.label} ${spec.group} ${spec.explainer}'.toLowerCase().contains(needle);
  }

  final out = <({String group, List<ParamSpec> specs})>[];
  for (final group in kParamGroups) {
    final specs = kParamCatalog.where((s) => s.group == group && matches(s)).toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    if (specs.isNotEmpty) out.add((group: group, specs: specs));
  }
  return out;
}

// ---------------------------------------------------------------------------
// POST body
// ---------------------------------------------------------------------------

/// Body for POST /simulation/run: ONLY the active levers.
///
/// An omitted field is resolved server-side to this tenant's neutral value
/// (`clamp(body.x, min, max, fallback)` with `finite(undefined, fallback)`), so a
/// removed lever contributes its DEFAULT rather than zero — which is exactly the
/// behaviour an untouched lever has. Keeping the value in widget state means
/// re-adding a lever restores where it was left.
///
/// There are NO exceptions to that rule, and one lever had to be reworked
/// server-side to keep it true: `acquisition_per_1000` originally switched the
/// marketing model on the mere PRESENCE of the key, so adding the lever and
/// never touching it moved profit by ~Rs 9,740/day with no change-dot to explain
/// why. It now SCALES the same diminishing-returns curve and is neutral at its
/// default, so present-at-default and absent are the same simulation.
Map<String, dynamic> buildRunBody(Set<String> active, Map<String, Object> values) {
  final body = <String, dynamic>{};
  for (final spec in kParamCatalog) {
    if (!active.contains(spec.key)) continue;
    switch (spec) {
      case NumberParam():
        final v = numberValue(values, spec.key, spec.defaultValue ?? 0);
        // Whole numbers travel as ints, exactly as the web sends them; the rest
        // are cleaned of slider float noise. Neither changes the simulation —
        // the server clamps every field regardless — it keeps the payload
        // readable and identical to the labels the screen showed.
        final cleaned = double.parse(v.toStringAsFixed(4));
        body[spec.key] = cleaned == cleaned.roundToDouble() ? cleaned.toInt() : cleaned;
      case EnumParam():
        body[spec.key] = planTierValue(values);
      case ToggleParam():
        body[spec.key] = toggleValue(values, spec.key);
    }
  }
  return body;
}

/// The plan tier the SERVER will see. A tier that is not in the POST body is
/// resolved to "starter" there, so a lever the user removed must stop granting
/// multi-outlet here too — otherwise the toggle would look enabled while the run
/// silently refused it.
String effectivePlanTier(Set<String> active, Map<String, Object> values) =>
    active.contains('plan_tier') ? planTierValue(values) : 'starter';

/// Whether the effective plan tier allows the (speculative) second-outlet model.
bool allowsSecondOutlet(Set<String> active, Map<String, Object> values) =>
    kPlanTiers[effectivePlanTier(active, values)]!.multiOutlet;
