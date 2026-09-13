import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../ui/theme/app_spacing.dart';

/// 6.4 — WHAT IS ON THE FLOOR RIGHT NOW. The app's twin of the website's
/// `LiveGrossBar` (src/components/live-gross.tsx + src/lib/live-gross.ts), with
/// the same three states and the same words, because the client's instruction
/// is that the till and the browser say the same thing.
///
/// V3: "Prominently display the gross sales specifically for currently running
/// tables. This can be a high-priority dashboard widget or a dedicated summary
/// box positioned above the orders in the table section."
///
/// THIS IS MONEY NOT YET TAKEN, AND THE BOX HAS TO SAY SO. Every rupee here is
/// on a table that has not paid, and some of it will be discounted or comped
/// before it reaches the till — so the label is "On the floor now", never
/// "sales", and the caption says outright that it is unpaid.
///
/// THE FIGURE IS THE SERVER'S. `GET /bills/open?limit=1` carries
/// `running_tables` / `running_total` over the WHOLE floor, priced by the same
/// billing maths as the bill screen, and it counts a table with sent KOTs and no
/// bill generated yet. Summing the tiles on screen would under-report exactly
/// the busy night somebody looks at this — and on a waiter's screen, whose
/// printed tables have already left their grid (C3), it would be a different
/// number from the manager's.
///
/// THREE STATES, and zero is never a stand-in for either of the other two:
///   * [LiveGrossUnavailable] — the server could not be asked. Never ₹0.00:
///     "the floor is clear" is the most consequential thing this could wrongly
///     say.
///   * [LiveGrossFloor] with `total == null` — the amount was withheld (a
///     waiter-only session: the server strips `running_total`, and this app
///     does not show a waiter floor-wide money either). The COUNT still shows.
///   * [LiveGrossFloor] with a total — tables and their tax-inclusive total.
sealed class LiveGrossView {
  const LiveGrossView();
}

class LiveGrossUnavailable extends LiveGrossView {
  const LiveGrossUnavailable();
}

class LiveGrossFloor extends LiveGrossView {
  const LiveGrossFloor({required this.tables, required this.total});

  final int tables;

  /// Null = withheld for this role; show the count only.
  final double? total;

  @override
  bool operator ==(Object other) =>
      other is LiveGrossFloor && other.tables == tables && other.total == total;

  @override
  int get hashCode => Object.hash(tables, total);

  @override
  String toString() => 'LiveGrossFloor(tables: $tables, total: $total)';
}

/// What the Tables loader stores for the box when the read fails, so the
/// builder can tell "the server refused this user" from "the line is down".
const String liveGrossRefused = 'refused';
const String liveGrossUnreachable = 'unavailable';

/// The loader half: how a failed `/bills/open` read is filed. A refusal (no
/// "View Bill" for this role, or a backend without the route) hides the box —
/// a permanent "unavailable" for somebody who can never have the figure is
/// noise. Anything else is the line or the server having a bad moment, and the
/// box says so rather than disappearing.
String liveGrossFailure(Object error) {
  final status = error is ApiException ? error.status : null;
  return status == 401 || status == 403 || status == 404 ? liveGrossRefused : liveGrossUnreachable;
}

num? _num(dynamic v) => v is num ? v : num.tryParse('${v ?? ''}');

/// The one place that decides what the box may say — `readLiveGross` on the
/// web, line for line. [showMoney] is the app's own role gate
/// ([FloorScope.money]); the server's redaction is the other, and either one
/// withholding the amount is enough.
LiveGrossView readLiveGross(Map? page, {bool showMoney = true}) {
  if (page == null) return const LiveGrossUnavailable();
  final running = _num(page['running_tables']);
  if (running != null) {
    final total = showMoney ? _num(page['running_total'])?.toDouble() : null;
    return LiveGrossFloor(tables: running.round(), total: total);
  }
  // A backend older than 6.4's fields: the open bills are the best answer it
  // can give, so a staggered deploy degrades to the old figure, not to a blank.
  final bills = _num(page['total']);
  if (bills == null) return const LiveGrossUnavailable();
  final outstanding = showMoney ? _num(page['outstanding_total'])?.toDouble() : null;
  return LiveGrossFloor(tables: bills.round(), total: outstanding);
}

/// ₹ with two decimals and Indian digit grouping (₹1,25,890.25), the web's
/// `toLocaleString("en-IN")`. A headline figure is read from across a counter,
/// so it is grouped even though the app's per-line amounts are not.
String liveGrossMoney(double n) {
  final negative = n < 0;
  final fixed = n.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  var whole = fixed.substring(0, dot);
  final cents = fixed.substring(dot);
  if (whole.length > 3) {
    final last3 = whole.substring(whole.length - 3);
    var rest = whole.substring(0, whole.length - 3);
    final pairs = <String>[];
    while (rest.length > 2) {
      pairs.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) pairs.insert(0, rest);
    whole = '${pairs.join(',')},$last3';
  }
  return '${negative ? '-' : ''}₹$whole$cents';
}

/// The summary box itself. Stateless: the Tables loader fetches the page, so
/// the box refreshes exactly when the table grid does — a reload, a pull from
/// the shell's refresh, an outlet switch — and can never show a floor from a
/// different moment than the tiles beneath it.
class LiveGrossBox extends StatelessWidget {
  const LiveGrossBox({super.key, required this.view});

  final LiveGrossView view;

  @override
  Widget build(BuildContext context) {
    // Theme-derived only: the primary accent for the edge, the page's own
    // surface and inks for the rest, so a light palette (6.6) and Gaia each
    // draw this in their own colours.
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final view = this.view;

    final String headline;
    String? caption;
    var muted = false;
    switch (view) {
      case LiveGrossUnavailable():
        headline = 'Unavailable just now';
        muted = true;
      case LiveGrossFloor(:final tables, :final total):
        final plural = tables == 1 ? '' : 's';
        if (total == null) {
          // Withheld — not zero, not a number.
          headline = '$tables running';
          caption = tables == 0
              ? 'No tables are running.'
              : '${tables == 1 ? 'table' : 'tables'} with orders on them · amounts are not shown for your role.';
        } else {
          headline = liveGrossMoney(total);
          caption = tables == 0
              ? 'No tables are running.'
              : 'Across $tables running table$plural · not yet paid, and before any discount at settlement.';
        }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        key: const ValueKey('live-gross'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: AppRadius.controlAll,
          border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 16,
          runSpacing: 4,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('On the floor now',
                  style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                headline,
                key: const ValueKey('live-gross-figure'),
                style: muted
                    ? text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500)
                    : text.headlineMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
              ),
            ]),
            if (caption != null)
              Text(caption, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
