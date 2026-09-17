// TODAY AT A GLANCE — WHERE EVERY ELEMENT OF THE OVERVIEW'S HEADLINE BOX LEADS.
//
// Client item 10: "The entire 'Today at a glance' section needs to be made
// clickable; each option in it must be clickable."
//
// Each element opens an explanation built from the payload the Overview already
// holds, footed by a "View in <Module>" jump pinned to the server's day; a pure
// count jumps straight there. The destination is the SERVER's answer when it
// sent one (`drill` on each figure, the `drills` block for everything else —
// Restaurant_Backend/glance_drill.ts), and this file's mirror of the same table
// when it did not (a backend older than item 10). test/glance_drill_test.dart
// pins the mirror to the backend's source.
//
// WHY REPORTS FIRST. Every figure in the box is computed by the same functions
// as an MIS report, so the report a jump lands on shows the same number (the
// backend's headline_drill_agreement test follows every drill and checks).
// Accounting's by-method card is a different computation — no Unallocated row,
// no refunds taken off — so it is a fallback and a secondary jump for its bill
// list, never the first place a tile leads.
//
// NOTHING HERE FETCHES, WRITES OR FORWARDS A FOCUS TARGET. A jump is local
// navigation plus session memory (the destination's window, report tab and
// slot), so the offline outbox is not involved, and none of these modules reads
// a focus payload — an unread key is what makes a destination claim a record is
// missing.
//
// THE SHEET COPY LIVES HERE TOO, word for word the web dashboard's
// src/lib/glance-destinations.ts, so an owner reading the till and the browser
// reads the same sentences. The web suite pins that.
//
// PURE: no Flutter, no network.

import '../services/date_range.dart';

/// How a destination's window is cut.
enum GlanceWindow { day, month, none }

/// One destination, fully resolved.
class GlanceTarget {
  const GlanceTarget({
    required this.module,
    this.report,
    this.from,
    this.to,
    this.slotAll = false,
    this.method,
    this.bills = false,
  });

  /// The shell's module label, verbatim.
  final String module;

  /// The MIS report the Reports module opens on.
  final String? report;

  /// The window, as the server's day keys. Null for a module that takes none.
  final String? from;
  final String? to;

  /// True when the destination must open on the whole day (every Reports jump).
  final bool slotAll;

  /// Accounting's settled-bill filter.
  final String? method;

  /// True when the destination should scroll to its settled-bill list.
  final bool bills;

  bool get hasWindow => isDayKey(from) && isDayKey(to);

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  /// Null for anything that does not name a module — a destination the shell
  /// cannot resolve is not a destination.
  static GlanceTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final module = _str(raw['module']);
    if (module == null) return null;
    final params = raw['params'] is Map ? raw['params'] as Map : const {};
    return GlanceTarget(
      module: module,
      report: _str(params['report']),
      from: _str(params['from']),
      to: _str(params['to']),
      slotAll: _str(params['slot']) == 'all',
      method: _str(params['method']),
      bills: raw['bills'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlanceTarget &&
      other.module == module &&
      other.report == report &&
      other.from == from &&
      other.to == to &&
      other.slotAll == slotAll &&
      other.method == method &&
      other.bills == bills;

  @override
  int get hashCode => Object.hash(module, report, from, to, slotAll, method, bills);

  @override
  String toString() => 'GlanceTarget($module, report: $report, $from..$to, all: $slotAll, method: $method, bills: $bills)';
}

/// What one element leads to.
class GlanceDrill {
  const GlanceDrill({required this.primary, this.fallbacks = const [], this.secondary});

  final GlanceTarget primary;

  /// Tried in order when [primary]'s module is not open to this user.
  final List<GlanceTarget> fallbacks;

  /// A second destination with a different question behind it — the drawer
  /// behind Cash collection, a mode's own bills behind its row.
  final GlanceTarget? secondary;

  static GlanceDrill? fromJson(Object? raw) {
    final primary = GlanceTarget.fromJson(raw);
    if (primary == null) return null;
    final m = raw as Map;
    return GlanceDrill(
      primary: primary,
      fallbacks: [
        if (m['fallbacks'] is List)
          for (final f in m['fallbacks'] as List) ?GlanceTarget.fromJson(f),
      ],
      secondary: GlanceTarget.fromJson(m['secondary']),
    );
  }

  /// The first destination this user can open, or null — in which case the
  /// sheet still opens and simply offers no jump, never a dead one.
  GlanceTarget? resolve(bool Function(String module) canOpen) {
    if (canOpen(primary.module)) return primary;
    for (final f in fallbacks) {
      if (canOpen(f.module)) return f;
    }
    return null;
  }

  /// [secondary] when this user can open it and it is not where [resolve]
  /// already leads — two buttons to one screen is one button too many.
  GlanceTarget? resolveSecondary(bool Function(String module) canOpen) {
    final s = secondary;
    if (s == null || !canOpen(s.module)) return null;
    final first = resolve(canOpen);
    return first == s ? null : s;
  }
}

// ------------------------------------------------------------ the table ----

/// One row of the table, before it is given a day.
class GlanceRoute {
  const GlanceRoute(this.module, {this.report, required this.window, this.method, this.bills = false,
      this.fallbacks = const [], this.secondary});

  final String module;
  final String? report;
  final GlanceWindow window;

  /// 'row' = the tapped mode's own filter.
  final String? method;
  final bool bills;
  final List<String> fallbacks;
  final GlanceRoute? secondary;
}

/// The modules a drill may name, as the shell registers them.
const List<String> kGlanceAppModules = [
  'Reports', 'Accounting', 'Cash register', 'Analytics', 'History', 'Tables', 'Orders', 'Settings',
];

/// Restaurant_Backend/glance_drill.ts `GLANCE_ROUTES`, mirrored for a backend
/// that sends no drills. Pinned to that source by test/glance_drill_test.dart.
const Map<String, GlanceRoute> kGlanceRoutes = {
  'header': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'bills': GlanceRoute('Reports', report: 'order_summary', window: GlanceWindow.day, bills: true, fallbacks: ['Accounting', 'Analytics']),
  'day': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'zone': GlanceRoute('Settings', window: GlanceWindow.none),
  'month': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.month, fallbacks: ['Accounting', 'History', 'Analytics']),
  'today_net': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'today_gross': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'online_net': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'online_gross': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'cash_collection': GlanceRoute('Reports', report: 'settlement_summary', window: GlanceWindow.day, method: 'Cash', bills: true,
      fallbacks: ['Accounting', 'Analytics'], secondary: GlanceRoute('Cash register', window: GlanceWindow.none)),
  'month_to_date': GlanceRoute('Reports', report: 'sales_summary', window: GlanceWindow.month, fallbacks: ['Accounting', 'History', 'Analytics']),
  'by_method': GlanceRoute('Reports', report: 'settlement_summary', window: GlanceWindow.day, fallbacks: ['Accounting', 'Analytics']),
  'by_method_row': GlanceRoute('Reports', report: 'settlement_summary', window: GlanceWindow.day, method: 'row', bills: true,
      fallbacks: ['Accounting', 'Analytics'],
      secondary: GlanceRoute('Accounting', window: GlanceWindow.day, method: 'row', bills: true)),
  'split': GlanceRoute('Accounting', report: 'settlement_summary', window: GlanceWindow.day, method: 'Split', bills: true, fallbacks: ['Reports']),
  'unallocated': GlanceRoute('Accounting', report: 'settlement_summary', window: GlanceWindow.day, method: 'Split', bills: true, fallbacks: ['Reports']),
  'nc': GlanceRoute('Reports', report: 'nc_summary', window: GlanceWindow.day),
  'nothing_settled': GlanceRoute('Tables', window: GlanceWindow.none, fallbacks: ['Orders']),
};

/// The six figures, which carry their drill on themselves.
const List<String> kGlanceFigureKeys = [
  'today_net', 'today_gross', 'online_net', 'online_gross', 'cash_collection', 'month_to_date',
];

/// Unallocated is not a stored payment method; its bills are the Split bills.
String glanceRowMethod(String method) => method.trim() == 'Unallocated' ? 'Split' : method.trim();

/// glance_drill.ts `glanceParamsFor`, as a target: which of the window, report
/// and method each module takes. Anything but Reports, Accounting and History
/// takes nothing.
GlanceTarget glanceTargetFor(String module, GlanceRoute route,
    {required String today, required String monthFrom, String? rowMethod}) {
  final windowed = route.window != GlanceWindow.none;
  final from = route.window == GlanceWindow.month ? monthFrom : today;
  final method = route.method == 'row'
      ? (rowMethod == null || rowMethod.trim().isEmpty ? null : glanceRowMethod(rowMethod))
      : route.method;
  switch (module) {
    case 'Reports':
      return GlanceTarget(
        module: module,
        report: route.report ?? 'sales_summary',
        from: windowed ? from : null,
        to: windowed ? today : null,
        slotAll: windowed,
      );
    case 'Accounting':
      return GlanceTarget(
        module: module,
        from: windowed ? from : null,
        to: windowed ? today : null,
        method: method,
        bills: route.bills,
      );
    case 'History':
      return GlanceTarget(module: module, from: windowed ? from : null, to: windowed ? today : null);
    default:
      return GlanceTarget(module: module);
  }
}

/// The table's drill for [key], cut on the headline's own day.
GlanceDrill? glanceFallbackDrill(String key, {required String today, required String monthFrom, String? rowMethod}) {
  final route = kGlanceRoutes[key];
  if (route == null) return null;
  GlanceTarget t(String module, GlanceRoute r) =>
      glanceTargetFor(module, r, today: today, monthFrom: monthFrom, rowMethod: rowMethod);
  return GlanceDrill(
    primary: t(route.module, route),
    fallbacks: [for (final f in route.fallbacks) t(f, route)],
    secondary: route.secondary == null ? null : t(route.secondary!.module, route.secondary!),
  );
}

/// Where [key] leads on this headline payload: the server's drill when it sent
/// one, the mirrored table otherwise. A mode's row passes its stored [rowMethod].
GlanceDrill? glanceDrillOf(Map headline, String key, {String? rowMethod}) {
  Object? raw;
  if (kGlanceFigureKeys.contains(key)) {
    final f = headline[key];
    raw = f is Map ? f['drill'] : null;
  } else {
    final block = headline['drills'];
    if (block is Map) {
      if (key == 'by_method_row') {
        final rows = block['by_method_rows'];
        raw = rows is Map && rowMethod != null ? rows[rowMethod] : null;
      } else {
        raw = block[key];
      }
    }
  }
  final served = GlanceDrill.fromJson(raw);
  if (served != null) return served;
  final today = '${headline['today'] ?? ''}'.trim();
  final monthFrom = '${headline['month_from'] ?? ''}'.trim();
  // No day to pin a fallback to: a jump would land on whatever window the
  // destination last had, which is the misreading this whole table prevents.
  if (!isDayKey(today)) return null;
  return glanceFallbackDrill(key,
      today: today, monthFrom: isDayKey(monthFrom) ? monthFrom : '${today.substring(0, 7)}-01', rowMethod: rowMethod);
}

/// The window a target lands on, as the destination's date control stores it.
///
/// The SERVER's day, never the device's — a till past midnight, or in another
/// zone, must not land on a different day from the one the sheet named. When
/// the two agree it is stored as the matching PRESET (Today, This month), so a
/// return visit after midnight moves with the calendar like any other preset.
DateRange? glanceWindowOf(GlanceTarget t, {DateTime? now}) {
  if (!t.hasWindow) return null;
  final today = DateRange.fromPreset(RangePreset.today, now: now);
  if (t.from == today.from && t.to == today.to) return today;
  final month = DateRange.fromPreset(RangePreset.thisMonth, now: now);
  if (t.from == month.from && t.to == month.to && t.from != t.to) return month;
  return DateRange(from: t.from!, to: t.to!, preset: RangePreset.custom);
}

// --------------------------------------------------------------- the copy ----
// Word for word the web's src/lib/glance-destinations.ts (GLANCE_COPY).

const String kGlanceReportButton = "Today's report";
const String kGlanceDayTitle = 'How today is cut';
const String kGlanceSettledClock =
    'A bill counts on the day it was settled: when it was closed, or when it was approved if it was never closed.';
const String kGlanceOnlineRule =
    'A bill is online when the order it was raised from came through delivery or an aggregator. A counter takeaway is a walk-in and is not counted.';
const String kGlanceOnlineNone =
    'No delivery or aggregator order was settled today. Zomato, EazyDiner, District and Dineout taken at the table are payment modes: they are counted under Collected by payment method, not here.';
const String kGlanceNoCash = 'No cash was taken today.';
const String kGlanceDrawerNote =
    'The Cash register counts its own session and drawer, so its figure can differ from this one.';
const String kGlanceBillListNote =
    'Accounting lists a bill under the one payment method stored on it, so a bill paid in parts is listed under Split.';
const String kGlanceSplitRule =
    'Each part of a bill paid in parts counts under its own payment method.';
const String kGlanceByMethodTitle = 'Payment methods today';
const String kGlanceGrossAddsUp = 'Collected by payment method, below, adds up to this figure.';
const String kGlanceNoDestination = 'There is no screen here you can open for this.';

/// "Today is 17 Sep in Asia/Kolkata (UTC+05:30), midnight to midnight on the restaurant's clock."
String glanceDaySentence(String day, String zone) => zone.isEmpty
    ? 'Today is $day, midnight to midnight on the restaurant\'s clock.'
    : 'Today is $day in $zone, midnight to midnight on the restaurant\'s clock, not this device\'s.';

/// "Every bill settled from 1 Sep to 17 Sep, today included."
String glanceMonthSentence(String from, String to) => 'Every bill settled from $from to $to, today included.';

/// The empty-day sentence, with the open bills the Overview already counted.
String glanceOpenBillsSentence(int open) => open == 0
    ? 'No bill is open on the floor either.'
    : '$open bill${open == 1 ? ' is' : 's are'} still open on the floor.';

/// The ladder rungs the net/gross sheets print, in order, with their labels.
/// The Sales Summary's column labels.
const List<(String, String)> kGlanceLadder = [
  ('item_total', 'Item total'),
  ('discount', 'Discount'),
  ('net', 'Net'),
  ('service_charge', 'Service charge'),
  ('tax', 'Tax'),
  ('round_off', 'Round off'),
  ('grand_total', 'Gross'),
  ('refund', 'Refunds'),
];
