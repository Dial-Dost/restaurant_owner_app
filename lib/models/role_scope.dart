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

  /// The module that moves to the END of a waiter's nav (see [movesOverviewLast]).
  static const String overviewLabel = 'Overview';

  /// The nav group a waiter's Overview is moved into, so it renders as the LAST
  /// section rather than as an orphan row under OPERATIONS.
  static const String trailingSectionTitle = 'YOUR SHIFT';

  /// Modules a waiter-only identity never sees in the nav, whatever their
  /// tenant's grants say.
  ///
  /// Two groups, here for two different reasons.
  ///
  /// THE FLOOR MODULES THAT ARE NOT A WAITER'S JOB:
  ///   * MENU is the menu EDITOR — prices, sections, recipes, the destructive
  ///     surface. Its keyword is ['menu'], which any read-the-menu action name
  ///     matches, so the keyword gate never separated reading a menu from
  ///     rewriting one.
  ///   * KITCHEN is the KDS — the pass's own screen. Its keywords are
  ///     ['order', 'kitchen', 'kot', 'kds'] and every waiter holds an order
  ///     action, so that gate excluded nobody.
  ///   * WAITLIST's keywords are ['table', 'order', 'waitlist'] — same hole,
  ///     same reason. It was too LOOSE, not absent.
  ///   * BOOKINGS is the reservation book — a host/manager surface, and the one
  ///     whose own keyword (['booking']) may well already exclude a given
  ///     waiter. It is named here so the answer does not depend on how one
  ///     tenant spelled its action names.
  ///
  /// THE MONEY MODULES, which are here because of the hiding rule rather than
  /// because of a list of screens. "No money on a waiter's screen" is not a
  /// promise the table sheet can keep on its own: Analytics, Simulation,
  /// History, Reports, Concerns, Accounting and Cash register all price the
  /// restaurant, and every one of them is gated on the SAME keyword list —
  /// ['analytics', 'apc', 'report'] — that a tenant satisfies the moment it
  /// ticks "View Order APC" for its waiters. That tenant exists; it is the exact
  /// case this file was written for. Taking the rupees off the floor plan while
  /// leaving a month-to-date revenue chart two taps away in the same nav is not
  /// scoping, it is decoration.
  ///
  /// Note what is NOT here. Orders and Tables are the job. Attendance is their
  /// own shift. Printer carries no keywords and no money and is left alone —
  /// over-hiding is the failure mode this file's header warns about.
  static const Set<String> hiddenModules = {
    // the floor modules
    'Menu',
    'Kitchen',
    'Waitlist',
    'Bookings',
    // the money modules
    'Concerns',
    'Analytics',
    'Simulation',
    'History',
    'Reports',
    'Accounting',
    'Cash register',
  };

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

  /// Whether the Overview leaves the OPERATIONS group and becomes the LAST
  /// section of this user's nav.
  ///
  /// It is a MOVE, not a hide: a waiter still has an Overview and it is still
  /// one tap away — it is a scorecard about them (see [OverviewScope]) and a
  /// scorecard is what you check at the end of a shift, not the screen you
  /// stand in front of during one. The shell reorders both the flat module list
  /// and the sidebar from this, so the nav and the tab indices cannot disagree.
  static bool movesOverviewLast(Profile p) => isWaiterOnly(p);

  /// Whether this reader may be shown the restaurant's MONEY: what a table is
  /// running at, what a dish on an open bill costs, what a ticket is worth, the
  /// per-table APC and every total built out of them.
  ///
  /// One predicate for the whole app rather than a flag per screen, because the
  /// question is the same question everywhere and the answer has to be. A
  /// waiter's floor plan, their table sheet, their order list, the bill sheet
  /// reached from a ticket and the order-entry strip all ask this one function.
  ///
  /// TWO THINGS IT DELIBERATELY DOES NOT COVER, and both are the job rather than
  /// the restaurant's money:
  ///   * the MENU price list in order entry — that is the card in the guest's
  ///     hands, and a waiter who cannot answer "how much is the paneer tikka"
  ///     cannot take an order;
  ///   * the waiter's OWN average per cover on their own scorecard, which item
  ///     13 asks for by name. That is a figure ABOUT THEM over a month, not the
  ///     live value of the table they are standing at.
  static bool showsMoney(Profile p) => !isWaiterOnly(p);
}

/// What the Overview may put on screen for one signed-in user.
///
/// COMPOSED, not filtered. Every flag is asked BEFORE the request that feeds its
/// block, so a section this user may not see is never fetched, never rendered,
/// and never leaves a 403-shaped hole behind. That is the whole point: an empty
/// card where the money was is not scoping — it is a broken screen that still
/// tells a waiter there is a revenue figure here.
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
///
/// A WAITER'S OVERVIEW IS NOW A DIFFERENT PAGE, not a subset of this one. It is
/// [scorecard]: their APC, their attendance, their guest ratings and the
/// composite score built from them, and nothing else. The floor read that used
/// to survive here went with the rest — "how many of the restaurant's tables are
/// full" is a restaurant-wide figure, and the floor plan itself is one tap away
/// and is the tab they land on.
class OverviewScope {
  const OverviewScope({
    required this.money,
    required this.insights,
    required this.rating,
    required this.floor,
    required this.billValue,
    required this.scorecard,
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

  /// The floor read (/get-tables): occupancy and covers seated across the
  /// restaurant. Restaurant-wide, so it goes with the rest for a waiter.
  final bool floor;

  /// Whether the open-bills tile may price itself. Gates the RUPEES only, never
  /// the count.
  final bool billValue;

  /// The waiter's personal scorecard — their APC, attendance, guest rating and
  /// the composite performance score, read from `/me/scorecard`.
  ///
  /// True only for the role it is FOR: nobody else's landing screen grows a
  /// section it did not have. It is the whole of a waiter's Overview.
  final bool scorecard;

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
      floor: !waiterOnly && p.can(const ['table']),
      billValue: !waiterOnly,
      scorecard: waiterOnly,
      planLimits: !waiterOnly,
    );
  }
}

/// What a signed-in user may DO on a table, and whether they may see what it is
/// worth.
///
/// The floor plan and its table sheet are one screen carrying fifteen actions,
/// which is why this is a record of flags rather than a call to
/// `isWaiterOnly` at each of fifteen call sites: the sheet asks ONE object what
/// it is allowed to draw, so a control added later has to answer the question
/// too rather than inheriting "visible" by omission.
///
/// EVERY FLAG IS TRUE FOR EVERYONE WHO IS NOT A WAITER-ONLY IDENTITY. This class
/// takes nothing away from an admin, a manager, a cashier or a captain, and the
/// permission gates that already stood in front of these actions (comps,
/// service-charge waiver, refund's admin check) are untouched underneath it.
class FloorScope {
  const FloorScope({
    required this.seat,
    required this.settle,
    required this.release,
    required this.editSeating,
    required this.deleteTable,
    required this.addTable,
    required this.billOps,
    required this.guestQr,
    required this.assignWaiter,
    required this.money,
  });

  /// "Seat guests & take order" — POST /occupy-table.
  ///
  /// A waiter takes orders; the table becomes occupied because an order was
  /// placed on it, not because somebody pressed a button (item 16). The seating
  /// itself has NOT gone anywhere — see the notes on the occupancy trigger — it
  /// stopped being a thing a waiter does by hand.
  final bool seat;

  /// "Settle bill", and the approve-a-guest-payment card that also closes the
  /// table. Taking money is a cashier/manager act.
  final bool settle;

  /// "Release without payment" — POST /release-table. Freeing an occupied table
  /// with an open bill on it is a write-off, whatever it is called.
  final bool release;

  /// "Edit seating" — PATCH /table/:name {capacity, max_capacity}. Floor layout,
  /// not service.
  final bool editSeating;

  /// "Delete table" — DELETE /table/:name.
  final bool deleteTable;

  /// The floor plan's "Add table" button — POST /table.
  ///
  /// AN INFERENCE FROM ITEM 15, NOT A LINE OF IT, and flagged as one so it can
  /// be reverted on its own. Item 15 names "edit seating" and "delete table";
  /// this is the third control in that family, and leaving it while removing the
  /// other two produces the worst of both — a waiter who can create tables on a
  /// live floor plan and then cannot remove the one they mistyped. Adding a
  /// table writes the layout every other screen reads.
  final bool addTable;

  /// Merge, split, discount, coupon, reprint-without-service-charge and refund:
  /// every control that changes or re-presents what the guest owes.
  final bool billOps;

  /// The table's ordering QR block — the code, the URL and "Print QR". It is a
  /// setup artefact (the printed sheet lives on the table), and taking it out is
  /// what makes room for the two controls a waiter actually reaches for.
  final bool guestQr;

  /// The "No waiter assigned / Waiter: X" row with its Assign / Change / Remove
  /// controls.
  final bool assignWaiter;

  /// Every rupee figure about this table: the per-dish amounts down the right of
  /// the open order, the bill card (subtotal, discount, service charge, tax,
  /// TOTAL PAYABLE), covers/APC/target APC, the APC traffic light and its upsell
  /// card, and the bill/apc line on the floor tile.
  final bool money;

  factory FloorScope.of(Profile p) {
    final waiterOnly = RoleScope.isWaiterOnly(p);
    return FloorScope(
      seat: !waiterOnly,
      settle: !waiterOnly,
      release: !waiterOnly,
      editSeating: !waiterOnly,
      deleteTable: !waiterOnly,
      addTable: !waiterOnly,
      billOps: !waiterOnly,
      guestQr: !waiterOnly,
      assignWaiter: !waiterOnly,
      money: RoleScope.showsMoney(p),
    );
  }
}
