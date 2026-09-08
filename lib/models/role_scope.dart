import 'profile.dart';

/// Role-shaped scoping: what a signed-in user's JOB says they are here to do,
/// as distinct from what their tenant's role JSON happens to permit.
///
/// The app needs both questions answered and they are not the same question.
/// [Profile.can] / [Profile.featureEnabled] answer "will the server serve this
/// identity this data" — a per-tenant grant, because `Roles.actions_performable`
/// is editable JSON and a restaurant that ticked "View Order APC" for its
/// waiters has genuinely granted it. This file answers the other one: "is this
/// person running the restaurant, or working a section of it", which no tenant
/// edit changes.
///
/// Everything here is deliberately NARROW. It scopes ONE role — waiter — to the
/// case the owner described, and every other role (cashier, captain, manager,
/// custom) falls through untouched. Widening it is a product decision, not a
/// refactor: a shift lead who silently loses a screen they need cannot work the
/// shift, and nobody will report it as a permissions bug.
class RoleScope {
  const RoleScope._();

  /// The one core role this file narrows.
  ///
  /// The backend closes over admin/employee/valet/waiter/cashier/captain/manager
  /// and lowercases every role name on write (`parseEmployeeRoles`), so the
  /// comparison below is against a lowercase literal rather than a fuzzy match.
  static const String waiter = 'waiter';

  /// The tab a waiter opens the app on. The floor plan is where their shift
  /// actually happens; the Overview is the owner's screen.
  static const String landingModule = 'Tables';

  /// Modules a waiter-only identity never sees in the nav, whatever their
  /// tenant's grants say.
  ///
  /// Three NAMED modules rather than a rule, because each is here for a
  /// different reason and each was reachable for a different reason:
  ///   * MENU is the menu EDITOR — prices, sections, recipes, the destructive
  ///     surface. Its keyword is ['menu'], which any read-the-menu action name
  ///     matches, so the keyword gate never separated reading a menu from
  ///     rewriting one.
  ///   * WAITLIST's keywords are ['table', 'order', 'waitlist'] and every waiter
  ///     holds an order action, so that gate excluded nobody. It was too LOOSE,
  ///     not absent.
  ///   * BOOKINGS is the reservation book — a host/manager surface, and the one
  ///     of the three whose own keyword (['booking']) may well already exclude a
  ///     given waiter. It is named here so the answer does not depend on how one
  ///     tenant spelled its action names.
  static const Set<String> hiddenModules = {'Menu', 'Waitlist', 'Bookings'};

  /// True when EVERY role this user holds is 'waiter'.
  ///
  /// Deliberately "only", not "any", and that asymmetry is the safety margin.
  /// `role_all` always carries the primary role plus whatever else was granted,
  /// and it can carry UUIDs for a tenant's own custom roles. Someone who is a
  /// waiter AND a manager is a manager on shift; someone holding a custom role
  /// this build cannot read is not narrowed on a guess. An unrecognised role set
  /// therefore keeps every screen it has today — the failure mode of being wrong
  /// here is "the owner still sees everything", never "a role lost a screen".
  ///
  /// An admin — by role or by the `*` action wildcard — is never narrowed, which
  /// is belt and braces rather than logic: a wildcard identity is by definition
  /// not a scoped floor role.
  static bool isWaiterOnly(Profile p) {
    if (p.isAdmin || p.actions.contains('*')) return false;
    final roles = <String>{
      p.role.trim().toLowerCase(),
      for (final r in p.roleAll) r.trim().toLowerCase(),
    }..removeWhere((r) => r.isEmpty);
    if (roles.isEmpty) return false;
    return roles.every((r) => r == waiter);
  }

  /// True when [label] must be kept out of this user's nav on role grounds
  /// alone — i.e. even though their permissions and plan would allow it.
  static bool hidesModule(Profile p, String label) =>
      isWaiterOnly(p) && hiddenModules.contains(label);

  /// The module this user should open the app on, or null to keep the shell's
  /// default (the first module they can see).
  ///
  /// Returning a LABEL rather than an index is what makes this survive a role
  /// whose [landingModule] is hidden: the caller looks the label up in the list
  /// it is actually about to render, and falls back when it is not there.
  static String? landingModuleFor(Profile p) =>
      isWaiterOnly(p) ? landingModule : null;
}

/// What the Overview may put on screen for one signed-in user.
///
/// COMPOSED, not filtered. Every flag is asked BEFORE the request that feeds its
/// block, so a section this user may not see is never fetched, never rendered,
/// and never leaves a 403-shaped hole behind. That is the whole point: an empty
/// card where the money was is not scoping — it is a broken screen that still
/// tells a waiter there is a revenue figure here, and it is what the Overview
/// does today for anyone whose tenant did not grant the analytics action.
///
/// Each flag is two gates ANDed, answering two different questions:
///
///   * PERMISSION mirrors what the server actually enforces on the endpoints
///     behind the block, quoting the module registry's own keyword lists rather
///     than inventing new ones. /orders/apc and /orders/daily-revenue are both
///     `validateAction("df75119b-…")` — the action NAMED "View Order APC" —
///     which is precisely what Analytics' ['analytics', 'apc', 'report']
///     matches. /feedback/summary carries the feedback action, /get-tables the
///     tables action.
///
///   * ROLE is [RoleScope]. A waiter's landing screen carries no restaurant
///     money EVEN WHEN their tenant granted them "View Order APC". That case is
///     not hypothetical — a restaurant that ticked that box is showing its
///     waiters real revenue today — and the permission gate cannot fix it,
///     because it is doing exactly what the tenant asked it to do.
class OverviewScope {
  const OverviewScope({
    required this.money,
    required this.insights,
    required this.rating,
    required this.floor,
    required this.billValue,
    required this.ownSection,
    required this.planLimits,
  });

  /// The rupee figures read straight from /orders/apc and
  /// /orders/daily-revenue: month-to-date revenue, APC, the 14-day strip and
  /// the week-on-week delta.
  ///
  /// NO plan-feature term, deliberately. `FEATURE_BY_PREFIX` gates the
  /// `/analytics` PREFIX; these two routes live under `/orders` and keep serving
  /// a tenant whose plan drops analytics. Carrying the flag here would take an
  /// owner's own revenue off their own dashboard on a lean plan while Accounting
  /// still showed it.
  final bool money;

  /// The composed 30-day insight read (/analytics/overview): headline deltas,
  /// top dishes, top staff, kitchen timing, peak trade, needs-attention.
  ///
  /// This one DOES carry the plan flag as well as the action, because
  /// `/analytics/*` is exactly the prefix `FEATURE_BY_PREFIX` maps to the
  /// `analytics` feature — a plan without it 403s the read.
  final bool insights;

  /// The restaurant-wide guest-rating summary (/feedback/summary).
  final bool rating;

  /// The floor read (/get-tables): occupancy and covers seated. The one block a
  /// waiter keeps in full, because it is the floor they are working.
  final bool floor;

  /// Whether the open-bills tile may price itself.
  ///
  /// Gates the RUPEES only, never the count. How many tables have not settled is
  /// a waiter's own business and stays on their screen; what those tables are
  /// worth is the restaurant's money and does not.
  final bool billValue;

  /// The waiter-shaped blocks — which tables are theirs, and what is still open
  /// on them. True only for the role those blocks are FOR: nobody else's landing
  /// screen grows a section it did not have.
  final bool ownSection;

  /// The tenant's subscription limits on the Account card. A plan is the
  /// restaurant's billing arrangement, not a floor role's business.
  final bool planLimits;

  /// Analytics' keyword list, VERBATIM. Not a copy to keep in sync by hand —
  /// the Overview's money blocks are fed by the same action the Analytics module
  /// is gated on, so they must ask the same question. 'apc' is the keyword that
  /// does the work: the action is named "View Order APC".
  static const List<String> analyticsKeywords = ['analytics', 'apc', 'report'];

  factory OverviewScope.of(Profile p) {
    final waiterOnly = RoleScope.isWaiterOnly(p);
    final analytics = p.can(analyticsKeywords);
    return OverviewScope(
      money: !waiterOnly && analytics,
      insights: !waiterOnly && analytics && p.featureEnabled('analytics'),
      rating: !waiterOnly && p.can(const ['feedback']),
      floor: p.can(const ['table']),
      billValue: !waiterOnly,
      ownSection: waiterOnly,
      planLimits: !waiterOnly,
    );
  }
}
