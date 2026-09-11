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
    //
    // FLOOR PLAN is the newest of them and the plainest case. It is the layout
    // EDITOR that requirement D5 split out of Tables — add a table, delete one,
    // re-seat it, drag it between zones, mint and dissolve the zones themselves
    // — and every control on it is already false for this role
    // ([FloorScope.arrangeFloor], .addTable, .deleteTable, .editSeating). Left
    // in the nav it would be a second copy of the floor plan with every button
    // removed: a screen that exists to answer a question this role is not being
    // asked. Its keyword is ['table'], which every waiter matches, so the
    // keyword gate would never have excluded it.
    'Floor plan',
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
  /// Roles that OUTRANK a waiter. Mirrors ROLES_OUTRANKING_WAITER in the
  /// server's role_scope.ts, which is the authority; this copy exists only for
  /// the fallback below.
  static const Set<String> _outranksWaiter = {'admin', 'manager', 'cashier', 'captain'};

  static bool isWaiterOnly(Profile p) {
    if (p.isAdmin || p.actions.contains('*')) return false;

    // THE SERVER DECIDES. It holds the whole picture — the roles, what the
    // custom ones grant, the resolved action set — and there is one of it. When
    // it has said, we obey; deriving a second answer here is what produced the
    // bug described below.
    final fromServer = p.waiterOnly;
    if (fromServer != null) return fromServer;

    // FALLBACK, for an app pointed at a backend older than the `scope` block.
    //
    // THIS USED TO BE `roles.every((r) => r == waiter)` AND IT WAS LIVE AND
    // WRONG. That is a test on SPELLING rather than on authority, and two
    // ordinary configurations defeated it:
    //
    //   * a waiter granted any CUSTOM ROLE carries its UUID in role_all — not
    //     the word "waiter" — so `every` failed and every restriction lifted,
    //     including the money gate, since showsMoney is `!isWaiterOnly`. Using
    //     the granular RBAC feature silently un-scoped the role it was most
    //     likely to be used on;
    //   * "employee" is the SERVER'S FALLBACK for an unset primary and is always
    //     folded into role_all, so a half-configured record un-scoped itself.
    //
    // Both were invisible: correct on a tenant whose waiters happened to carry
    // one clean role, wrong on the tenant next door. The rule is now "a waiter
    // is scoped unless they also hold a role that OUTRANKS a waiter" — a closed
    // list, so a custom role, a placeholder or an unrecognised string cannot
    // lift the scoping by accident.
    final roles = <String>{
      p.role.trim().toLowerCase(),
      for (final r in p.roleAll) r.trim().toLowerCase(),
    }..removeWhere((r) => r.isEmpty);
    if (roles.isEmpty) return false;
    if (!roles.contains(waiter)) return false;
    return !roles.any(_outranksWaiter.contains);
  }

  /// MAY THIS IDENTITY DO [c] — the server's answer, obeyed.
  ///
  /// THE TEST THAT MATTERS: give this a profile whose ROLE STRINGS say one thing
  /// and whose server flag says another, and the FLAG wins. That is the test
  /// that would have caught csrorganics, where a client derived an authority
  /// answer from `role_all` and got it wrong on every tenant using custom roles.
  ///
  /// [fallback] IS WHAT THIS CALL SITE DID BEFORE THE FLAG EXISTED, and it is
  /// required rather than defaulted so nobody can add a gate here without
  /// stating what an older backend should do about it. It is consulted ONLY when
  /// the server said nothing at all. Defaulting these to false instead would
  /// empty the till the first day the app shipped ahead of the backend — see
  /// [Profile.said].
  ///
  /// THE ONE SHORT-CIRCUIT: the `*` wildcard. That is not a role string and not
  /// a guess — it is the server's own admin marker out of `actions_set`, and
  /// `sessionCapabilities` returns true for every flag when it is present, so
  /// this can never disagree with a correctly built server. It is here so a
  /// malformed or half-migrated payload cannot take the floor away from the
  /// person who owns the restaurant, which is the failure this codebase fears
  /// more than any control drawn one release too long.
  static bool may(Profile p, Capability c, {required bool fallback}) {
    if (p.actions.contains('*')) return true;
    return p.said(c) ?? fallback;
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

/// WHICH OF THE TWO FLOOR SCREENS IS ASKING — requirement D5.
///
/// The app used to fuse them. One module called "Tables" drew the floor plan,
/// the section groups, the drag-and-drop that re-labels a table's zone, the
/// "Add table" button, and — through the per-table sheet — "Edit seating" and
/// "Delete table". So the screen a waiter stands in front of all service was
/// also the screen the floor gets rebuilt on, and the only thing between a
/// mis-aimed long-press and a table changing section was the length of the
/// gesture.
///
/// D5 splits the JOB in two and this enum is the seam:
///
///   * [service] — the TABLES screen. Read the floor, open a table, take an
///     order, print, settle. It may not move, re-layout, reformat or delete
///     anything. Not "may not, if you are a waiter" — MAY NOT, full stop: an
///     owner working the floor at eight o'clock is doing service, and the
///     layout controls are not what they reached for.
///   * [plan] — the FLOOR PLAN screen. Rearrange, group, add, re-seat, delete.
///     Everything that writes the shape of the room rather than what is
///     happening in it.
///
/// IT IS A SURFACE, NOT A PERMISSION, and the two are ANDed rather than
/// substituted (see [FloorScope.of]). Moving a control to the layout screen
/// cannot hand it to somebody the role gate already refused, and the role gate
/// cannot put a delete button back on the service screen. Both have to say yes.
///
/// AN ADMIN LOSES NOTHING: every layout control an owner had is still theirs,
/// one tab away, on the screen that is now named after the job.
enum FloorSurface {
  /// The Tables screen — service. Deny-by-default for every layout write.
  service,

  /// The Floor plan screen — the layout editor.
  plan,
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
    required this.arrangeFloor,
    required this.billOps,
    required this.guestQr,
    required this.assignWaiter,
    required this.money,
    required this.floorSummary,
    required this.managerOnlyAsks,
  });

  /// "Seat guests & take order" — POST /occupy-table.
  ///
  /// A waiter takes orders; the table becomes occupied because an order was
  /// placed on it, not because somebody pressed a button (item 16). The seating
  /// itself has NOT gone anywhere — see the notes on the occupancy trigger — it
  /// stopped being a thing a waiter does by hand.
  final bool seat;

  /// "Settle bill", and the approve-a-guest-payment card that also closes the
  /// table. Taking money is a cashier/manager act, and the server says who may:
  /// [Capability.settleBill].
  final bool settle;

  /// "Release without payment" — POST /release-table. Freeing an occupied table
  /// with an open bill on it is a write-off, whatever it is called.
  ///
  /// SO IT TAKES [Capability.settleBill], THE SAME FLAG SETTLING TAKES, and the
  /// reason is worth stating where somebody might otherwise relax it. The route
  /// voids every active order on the table AND closes its open bill at
  /// total_amt = 0. Gated on an ordinary floor permission, that left the bill
  /// impossible to take for its true value and trivial to make vanish for
  /// nothing — a restriction that looks like one from the outside and is not.
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

  /// RE-LAYING OUT THE ROOM: dragging a table from one zone into another, and
  /// creating, renaming, dissolving or re-ordering the zones themselves.
  ///
  /// REQUIREMENT D5, AND IT IS THE SURFACE THAT DECIDES IT, not the role. These
  /// controls answered to a permission alone ("Table Added" for a move, "Manage
  /// Table Sections" for the roster) and lived on the same screen as the service
  /// floor, so an owner reading their tables during a rush was one long-press
  /// away from re-sectioning one. They are now [FloorSurface.plan] only — the
  /// permission gates underneath are untouched and still have to say yes too.
  ///
  /// Deliberately ONE flag for the move and the roster rather than two. They are
  /// the same act seen at two scales, and splitting them is how you get a screen
  /// that lets you drag a table into a section you cannot name.
  final bool arrangeFloor;

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

  /// The "Floor plan" header above the table grid — its title, its table count
  /// and the Occupied / Reserved / Free chips beside it.
  ///
  /// IT IS A HOUSE-WIDE SUMMARY ON A SCREEN THAT IS OTHERWISE ABOUT ONE WAITER'S
  /// TABLES. "23 Free" is a fact about the restaurant, not about the section
  /// this waiter is working, and it is the first thing on their landing screen —
  /// Tables is where a waiter opens (see [RoleScope.landingModule]). It also
  /// reads as a control: it is a header, it carries a count, and it sits exactly
  /// where the floor-plan editing controls live for everyone else, which is the
  /// opposite of what item D5 wants a waiter's Tables view to be.
  ///
  /// Managers and owners keep it, because for them the same strip is the point
  /// of the screen: how full is the floor right now.
  final bool floorSummary;

  /// "Comp an item" and "Waive service charge" — the two controls a waiter may
  /// not operate but which, until now, they could SEE.
  ///
  /// THIS FLAG REVERSES A DELIBERATE DECISION AND THE REVERSAL IS THE CLIENT'S,
  /// so it is recorded here rather than argued in the code it removes. 1.8.6
  /// shipped both visible-but-inert on purpose: a waiter needs to know the
  /// control EXISTS so they fetch a manager, instead of arguing with a guest
  /// about a screen that appears to have no such option. The comp button even
  /// said "manager only" in its own label, because a dimmed control in a wrap of
  /// eight cannot carry a sentence beside it.
  ///
  /// The V3 requirements ask for the opposite in as many words — "completely
  /// hidden", "including its accompanying text" — so both go. What is traded
  /// away is the discoverability: a waiter who does not already know a comp is
  /// possible now has nothing on screen to tell them. If that turns out to cost
  /// more at the pass than the clutter did, this one flag is the thing to flip.
  ///
  /// Gated on the ROLE, not on the permission, and that is the point: a tenant
  /// that has granted its waiters the non-chargeable UUID would otherwise get an
  /// ENABLED comp button, which the requirement forbids regardless of grant.
  final bool managerOnlyAsks;

  /// [surface] says WHICH floor screen is asking — see [FloorSurface].
  ///
  /// IT DEFAULTS TO [FloorSurface.service], THE RESTRICTIVE ONE, and that
  /// direction is the point. Both modules pass it explicitly, so the default is
  /// only ever reached by a call site written later — and the failure mode of a
  /// forgotten argument then is "somebody has to switch tabs to delete a table",
  /// never "a delete button reappeared on the service floor". The role gates are
  /// the other way round for the reason stated at the top of this file: an
  /// unreadable ROLE keeps every screen it has, because a floor that cannot take
  /// an order is a worse outage than a control in the wrong place.
  ///
  /// The three layout flags are the role answer AND the surface answer. Neither
  /// can overrule the other: this cannot grant a waiter a delete button by
  /// putting them on the plan screen, and it cannot take an owner's away
  /// permanently — theirs moved, it did not go.
  factory FloorScope.of(Profile p, {FloorSurface surface = FloorSurface.service}) {
    final waiterOnly = RoleScope.isWaiterOnly(p);
    final layout = surface == FloorSurface.plan;
    // THE SERVER'S ANSWERS, not this class's arithmetic on role strings. Each
    // fallback is what this flag meant before the capability shipped, so an app
    // pointed at an older backend behaves exactly as it did — see [RoleScope.may].
    final mayClose = RoleScope.may(p, Capability.settleBill, fallback: !waiterOnly);
    final mayEditTable = RoleScope.may(p, Capability.editTable, fallback: !waiterOnly);
    final mayDeleteTable = RoleScope.may(p, Capability.deleteTable, fallback: !waiterOnly);
    return FloorScope(
      seat: !waiterOnly,
      settle: !waiterOnly && mayClose,
      // THE SIDE DOOR, AND IT WAS STANDING OPEN. Every settle path went behind
      // "Close Bill", and POST /release-table did not — it voids every active
      // order on the table and closes the open bill at zero, on a permission the
      // core waiter role holds. So the bill could not be taken for what it was
      // worth and could still be made to vanish for nothing, which is worse than
      // never having restricted settling at all, because it LOOKS restricted.
      //
      // Releasing a table that owes money is a WRITE-OFF, so it takes the
      // write-off authority: the same flag settling takes. The server gate is the
      // control (POST /release-table now requires Close Bill when the table has an
      // open bill); this is the courtesy that stops drawing a button that 403s.
      release: !waiterOnly && mayClose,
      editSeating: !waiterOnly && layout && mayEditTable,
      deleteTable: !waiterOnly && layout && mayDeleteTable,
      addTable: !waiterOnly && layout && mayEditTable,
      // NOT gated here, and deliberately: the two writes behind it answer to two
      // different capabilities (moving a table is `edit_table`, minting a zone is
      // `manage_table_sections`) and the call site already ANDs each control with
      // its own — see `_canMoveTables` / `_canManageSections` in modules.dart.
      // Collapsing both into one flag here would either hand a zone editor to
      // somebody who may only drag a table, or take the drag away from somebody
      // who may not rename a zone.
      arrangeFloor: !waiterOnly && layout,
      billOps: !waiterOnly,
      guestQr: !waiterOnly,
      assignWaiter: !waiterOnly,
      money: RoleScope.showsMoney(p),
      floorSummary: !waiterOnly,
      // The ROLE half only. Each of the two controls behind it is ANDed with its
      // own capability at its own call site (`comp_item`, `waive_service_charge`),
      // for the reason stated on this field: a tenant that granted its waiters the
      // non-chargeable uuid must still not get an enabled comp button, so the role
      // gate cannot be replaced by the capability — only added to.
      managerOnlyAsks: !waiterOnly,
    );
  }
}

/// PRINTING A TABLE'S BILL — requirement C3, which is the one item in this block
/// that had to be interpreted rather than merely implemented.
///
/// WHAT WAS ASKED, VERBATIM: "Waiters can only execute Print Bill ONCE. After
/// clicking, the button must disappear and the table should clear/reset from
/// their view. Any subsequent actions (reprinting, overrides) must be restricted
/// to Super Admins."
///
/// WHY IT CANNOT BE TAKEN LITERALLY, AND WHAT IT WAS READ AS INSTEAD.
///
/// Read literally, "the table should clear/reset" collides head-on with C2, the
/// requirement immediately above it: a waiter may not settle. If printing
/// RELEASED the table, then printing would be the settle — a table with an open
/// bill on it would go free, unpaid, on the one action C2 says a waiter still
/// has. That is a write-off dressed as a print, and it is the money bug this
/// whole block exists to stop, not a feature.
///
/// So "clear from their view" is read as exactly what it says — THEIR VIEW. The
/// table stays OPEN, the bill stays owing, and a manager settles it. What
/// changes is the waiter's own screen: the Print bill button goes, and the table
/// drops off their floor, because for them the job at that table is finished.
/// The bill remains fully reprintable — by somebody senior, on the unchanged
/// control they already have.
///
/// WHO KEEPS THE REPRINT. Waiter-only identities lose it; NOBODY ELSE DOES. The
/// requirement names "Super Admins", but a manager, cashier or captain who can
/// reprint today would lose it on a literal reading, and this codebase's
/// standing rule is that a fix must not take the till away from the people who
/// run the floor. "Super Admin" is read as naming who a WAITER escalates to, not
/// as a new ceiling on everyone else.
///
/// WHERE THE "ONCE" IS REMEMBERED, AND WHAT EACH ANSWER IS WORTH.
/// The server now records it: `/bill-for-table` carries `print_count`,
/// `bill_printed_at` and `printed_at`, and POST /print/bill itself REFUSES a
/// waiter-only identity's second print with a 403 that says who to ask. So the
/// hidden control has a gate behind it and this class is the courtesy in front
/// of it, which is the right way round.
///
/// [printed] is therefore the SERVER'S answer wherever the payload carries one —
/// including when that answer is "not printed" and this tablet remembers
/// otherwise (see `serverBillPrintState`). The per-device memory in
/// `PrintedBills` is reached ONLY when the payload carries no print state at
/// all, i.e. a backend older than those fields. It is a courtesy, not a control:
/// it survives a back-navigation and an app restart, and it does not survive a
/// reinstall or a second tablet.
class BillPrintScope {
  const BillPrintScope({
    required this.print,
    required this.reprintNeedsSenior,
    required this.retiresTable,
  });

  /// Whether the Print bill control may be drawn and pressed at all right now.
  final bool print;

  /// True when this reader has used up their one print and a second one is
  /// somebody else's to make. Drives the sentence the sheet shows in the
  /// button's place — a waiter who is simply given a blank space where a control
  /// was will press it again on the next device they find.
  final bool reprintNeedsSenior;

  /// Whether this table now leaves THIS reader's floor grid.
  ///
  /// Never a release, never a settle, never a write of any kind — the row is
  /// filtered out of one list on one device. The table is still occupied, still
  /// owes money, and is still on every manager's screen, which is the whole
  /// difference between "clear from their view" and "clear the table".
  final bool retiresTable;

  /// [printed] is "this table's current bill has already been printed by this
  /// reader", resolved by the caller from the server's answer where there is one
  /// and from the device memory otherwise.
  factory BillPrintScope.of(Profile p, {required bool printed}) {
    final waiterOnly = RoleScope.isWaiterOnly(p);
    // Everyone else is untouched — same control, same number of presses, same
    // receipt preview in front of it.
    if (!waiterOnly) {
      return const BillPrintScope(print: true, reprintNeedsSenior: false, retiresTable: false);
    }
    return BillPrintScope(
      print: !printed,
      reprintNeedsSenior: printed,
      retiresTable: printed,
    );
  }
}
