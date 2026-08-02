import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import '../services/auth_controller.dart';
import '../services/printer_service.dart';
import '../services/rest_client.dart';
import '../services/restaurant_time.dart';
import '../services/update_checker.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import 'modules.dart' as m;
import '../widgets/module_navigator.dart';
import '../widgets/notifications_bell.dart';

class _Module {
  final String label;
  final IconData icon;
  final List<String> keywords; // permission keywords (empty = always visible)
  final Widget Function(RestClient rest, Profile p) build;
  final String? feature; // subscription-plan feature flag (null = always allowed)
  final bool adminOnly; // hard admin gate, regardless of keywords
  const _Module(this.label, this.icon, this.keywords, this.build, {this.feature, this.adminOnly = false});
}

// Mirrors the web dashboard's modules and permission keywords. `feature` gates a
// module behind a subscription-plan flag (additive — only hidden when the plan
// explicitly sets it false).
const _allModules = <_Module>[
  _Module('Overview', Icons.dashboard, [], m.overviewModule),
  _Module('Orders', Icons.receipt_long, ['order', 'bill', 'payment'], m.ordersModule),
  _Module('Kitchen', Icons.soup_kitchen, ['order', 'kitchen', 'kot', 'kds'], m.kdsModule),
  _Module('Menu', Icons.menu_book, ['menu'], m.menuModule),
  _Module('Tables', Icons.table_restaurant, ['table'], m.tablesModule),
  _Module('Waitlist', Icons.hourglass_top, ['table', 'order', 'waitlist'], m.waitlistModule),
  _Module('Inventory', Icons.inventory_2, ['inventory', 'stock'], m.inventoryModule, feature: 'inventory'),
  _Module('Purchase Orders', Icons.local_shipping, ['inventory', 'stock', 'purchase', 'vendor'], m.purchaseOrdersModule, feature: 'inventory'),
  _Module('Bookings', Icons.event_seat, ['booking'], m.bookingsModule),
  _Module('Customers', Icons.people, ['customer'], m.customersModule),
  _Module('Feedback', Icons.reviews, ['feedback'], m.feedbackModule),
  _Module('Analytics', Icons.insights, ['analytics', 'apc', 'report'], m.analyticsModule, feature: 'analytics'),
  _Module('History', Icons.calendar_month, ['analytics', 'report'], m.historyModule, feature: 'analytics'),
  _Module('Accounting', Icons.account_balance, ['report', 'accounting', 'finance', 'expense', 'analytics'], m.accountingModule, feature: 'accounting'),
  _Module('Cash register', Icons.point_of_sale, ['report', 'accounting', 'finance', 'cash'], m.cashModule, feature: 'accounting'),
  _Module('Valet', Icons.local_parking, ['valet', 'parking'], m.valetModule, feature: 'valet'),
  _Module('Outlets', Icons.store_mall_directory, ['outlet', 'branch', 'setting', 'profile'], m.outletsModule, feature: 'multi_outlet'),
  _Module('Employees', Icons.badge, ['employee', 'role', 'user'], m.employeesModule),
  _Module('Roles', Icons.shield, ['role', 'permission'], m.rolesModule),
  _Module('Audit Log', Icons.history, ['audit', 'log'], m.auditLogModule),
  _Module('Attendance', Icons.schedule, [], m.attendanceModule),
  _Module('Printer', Icons.print, [], m.printerModule),
  _Module('Billing', Icons.card_membership, [], m.billingModule, adminOnly: true),
  _Module('Settings', Icons.settings, [], m.settingsModule, adminOnly: true),
];

/// The signed-in shell: a permission-gated sidebar plus the selected module.
class HomeShell extends StatefulWidget {
  final AuthController auth;
  const HomeShell({super.key, required this.auth});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _refreshTick = 0;
  bool _checkedUpdate = false;
  bool _sidebarCollapsed = false;
  List<Map<String, dynamic>> _outlets = [];
  // Labels of the modules this user can actually see, refreshed on every build.
  // Cached so `_openModule` can stay a stable instance method (shared by the
  // notifications bell and the ModuleNavigator handed to every module).
  List<String> _visibleLabels = const [];
  // The record a caller (usually a tapped notification) asked the destination
  // module to focus, handed down on the ModuleNavigator.
  ModuleFocusRequest? _focus;
  // Monotonic: identifies each focus request AND remounts the destination so it
  // refetches. Never decremented, so clearing a focus does not remount (and the
  // module keeps its scroll position).
  int _focusTick = 0;

  @override
  void initState() {
    super.initState();
    // Restore the persisted sidebar collapsed/expanded preference.
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final collapsed = prefs.getBool('sidebar_collapsed') ?? false;
      if (collapsed != _sidebarCollapsed) setState(() => _sidebarCollapsed = collapsed);
    });
    // Check for an app update once, after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_checkedUpdate && mounted) {
        _checkedUpdate = true;
        showUpdateDialogIfNeeded(context);
      }
    });
    // Adopt the restaurant's reporting timezone for the session: every
    // timestamp in the app is rendered in it (RestaurantTime). Deliberately
    // /restaurant/timezones and not /restaurant/settings — the zone is how the
    // app labels times for EVERY role, and only the latter is admin-gated.
    // A failure leaves the persisted/default zone in place.
    RestClient(widget.auth).getMap('/restaurant/timezones').then((tz) {
      RestaurantTime.adopt('${tz['current'] ?? ''}');
    }).catchError((_) {});
    // Load outlets for the switcher (admins/managers can act across branches).
    final p = widget.auth.profile;
    final canSwitch = p != null &&
        (p.role == 'admin' || p.roleAll.contains('admin') || p.role == 'manager' || p.roleAll.contains('manager'));
    if (canSwitch) {
      RestClient(widget.auth).getMap('/outlets').then((m) {
        if (!mounted) return;
        final list = (m['outlets'] as List?) ?? const [];
        setState(() => _outlets = list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
      }).catchError((_) {});
    }
    // Start the built-in printer agent: connect to realtime + listen for bills.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PrinterService.instance.start(widget.auth);
    });
  }

  @override
  void dispose() {
    // Tear down the realtime printer connection when leaving the signed-in shell
    // (e.g. on logout).
    PrinterService.instance.stop();
    super.dispose();
  }

  // The one "make this outlet active" path: the AppBar switcher, a module's
  // "switch outlet" affordance (ModuleNavigator.switchOutlet) and the
  // notifications bell all go through here so every surface refreshes together.
  //
  // The chosen outlet is sent as X-Outlet-Id on every request. The special value
  // 'all' asks the backend to aggregate reads across every outlet (admin/manager
  // only); writes are rejected server-side while active, so it is a read-only
  // combined view.
  void _selectOutlet(String outletId) {
    if (outletId.isEmpty) return;
    final current = widget.auth.selectedOutletId ?? (_outlets.isNotEmpty ? '${_outlets.first['id']}' : '');
    if (outletId == current) return;
    widget.auth.selectOutlet(outletId);
    if (!mounted) return;
    setState(() => _refreshTick++);
    // Rejoin the realtime printer subscription for the newly selected outlet.
    PrinterService.instance.stop().then((_) => PrinterService.instance.start(widget.auth));
  }

  Widget _outletSwitcher() {
    final activeId = widget.auth.selectedOutletId ?? (_outlets.isNotEmpty ? '${_outlets.first['id']}' : '');
    final isAll = activeId == 'all';
    return PopupMenuButton<String>(
      tooltip: isAll ? 'Viewing all outlets (combined)' : 'Switch outlet',
      color: AppColors.cardRaised,
      icon: Icon(isAll ? Icons.layers : Icons.store_mall_directory,
          color: isAll ? AppColors.copperHi : AppColors.textSecondary),
      onSelected: _selectOutlet,
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String>(
          value: 'all',
          checked: isAll,
          child: const Text('All outlets (combined)'),
        ),
        for (final o in _outlets)
          CheckedPopupMenuItem<String>(
            value: '${o['id']}',
            checked: '${o['id']}' == activeId,
            child: Text('${o['outlet_name'] ?? 'Outlet'}${o['is_active'] == false ? ' (inactive)' : ''}'),
          ),
      ],
    );
  }

  // The one label -> sidebar-index jump, shared by the notifications bell and
  // the ModuleNavigator exposed to every module. Silently does nothing when the
  // label is unknown or hidden from this user by permissions / plan features,
  // so callers never land on the wrong module.
  //
  // `target` (entity ids from the caller — e.g. order_id / booking_id /
  // waitlist_id / table) is parked on the ModuleNavigator as a
  // [ModuleFocusRequest] and read by the destination module, which scrolls to /
  // highlights that record — or says honestly that it is not in its list. The
  // module builder signature stays `(rest, p) -> Widget`.
  void _openModule(String label, {Map<String, dynamic>? target}) {
    final idx = _visibleLabels.indexOf(label);
    if (idx < 0) return;
    final focused = target != null && target.isNotEmpty;
    if (idx == _index && !focused) return;
    setState(() {
      _index = idx;
      if (focused) {
        // Remount the destination (bumped tick -> new KeyedSubtree key) so it
        // refetches: the record may have arrived since the last load.
        _focusTick++;
        _focus = ModuleFocusRequest(moduleLabel: label, target: target, serial: _focusTick);
      } else {
        // A plain jump — never leave a previous request's banner behind.
        _focus = null;
      }
    });
  }

  // Drops the pending focus without remounting the module (the "x" on a
  // module's focus banner).
  void _clearFocus() {
    if (_focus == null) return;
    setState(() => _focus = null);
  }

  void _toggleSidebar() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('sidebar_collapsed', _sidebarCollapsed));
  }

  // Copper monogram + restaurant wordmark — the brand lockup at the top of the
  // sidebar (mirrors the reference "⊙ RUSTIC FORK" pattern).
  Widget _brandMark(Profile p, {required bool inDrawer}) {
    return Row(children: [
      Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.copperHi, AppColors.copperDeep],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.copperShadow.withValues(alpha: 0.6),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Icons.restaurant_menu, size: 16, color: AppColors.onCopper),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.restaurantName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: AppColors.textPrimary,
                )),
            const SizedBox(height: 2),
            Text('OWNER WORKSPACE',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppColors.textSecondary.withValues(alpha: 0.8),
                )),
          ],
        ),
      ),
      // Collapse control lives on the fixed sidebar only — the drawer is
      // dismissed by tapping away, so it needs no collapse button.
      if (!inDrawer)
        IconButton(
          tooltip: 'Collapse sidebar',
          icon: const Icon(Icons.chevron_left, color: AppColors.textTertiary),
          visualDensity: VisualDensity.compact,
          onPressed: _toggleSidebar,
        ),
    ]);
  }

  // The nav list, reused by the wide sidebar (optionally collapsed to an
  // icon-only rail) and the narrow drawer.
  Widget _navList(List<_Module> visible, Profile p,
      {required bool inDrawer, bool collapsed = false}) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(collapsed ? 8 : 18, 18, collapsed ? 8 : 8, 14),
          child: collapsed
              ? Center(
                  child: IconButton(
                    tooltip: 'Expand sidebar',
                    icon: const Icon(Icons.chevron_right, color: AppColors.textTertiary),
                    onPressed: _toggleSidebar,
                  ),
                )
              : _brandMark(p, inDrawer: inDrawer),
        ),
        if (!collapsed)
          const Padding(
            padding: EdgeInsets.only(left: 20, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('WORKSPACE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: AppColors.textTertiary,
                  )),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 8 : 12),
            itemCount: visible.length,
            itemBuilder: (context, i) => _NavItem(
              label: visible[i].label,
              icon: visible[i].icon,
              active: i == _index,
              collapsed: collapsed,
              onTap: () {
                // A deliberate sidebar jump is not a notification follow-up —
                // drop any pending focus so a stale banner cannot reappear.
                setState(() {
                  _index = i;
                  _focus = null;
                });
                if (inDrawer) Navigator.of(context).pop(); // close the drawer
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.auth.profile!;
    final rest = RestClient(widget.auth);

    final visible = _allModules
        .where((mod) => (!mod.adminOnly || p.isAdmin) && p.can(mod.keywords) && p.featureEnabled(mod.feature))
        .toList();
    if (visible.isEmpty) {
      return const Scaffold(body: Center(child: Text('No modules available for your role.')));
    }
    if (_index >= visible.length) _index = 0;
    final current = visible[_index];
    _visibleLabels = [for (final mod in visible) mod.label];

    // Phones / narrow windows: nav lives in a drawer instead of a fixed sidebar.
    final narrow = MediaQuery.of(context).size.width < 700;

    // Every module builds under a ModuleNavigator, so any of them can jump the
    // shell to another module, focus a record a notification pointed at, or
    // switch outlet — without widening the shared build signature.
    final body = ModuleNavigator(
      openModule: _openModule,
      visibleLabels: _visibleLabels,
      focus: _focus,
      clearFocus: _clearFocus,
      switchOutlet: _outlets.length > 1 ? _selectOutlet : null,
      child: KeyedSubtree(
        key: ValueKey('${current.label}_${_refreshTick}_$_focusTick'),
        child: current.build(rest, p),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgDeep,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleSpacing: narrow ? 0 : 16,
        title: Row(children: [
          const Icon(Icons.auto_awesome, size: 14, color: AppColors.copperHi),
          const SizedBox(width: 8),
          Text(current.label,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: AppColors.textPrimary,
              )),
        ]),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AppColors.divider),
        ),
        actions: [
          if (_outlets.length > 1) _outletSwitcher(),
          NotificationsBell(
            rest: rest,
            onOpenModule: _openModule,
            // Lets a notification whose record lives on another outlet offer
            // "Switch outlet" instead of opening an empty screen.
            onSwitchOutlet: _outlets.length > 1 ? _selectOutlet : null,
            visibleLabels: _visibleLabels,
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => setState(() => _refreshTick++),
            icon: const Icon(Icons.refresh),
          ),
          if (!narrow)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: widget.auth.logout,
                icon: const Icon(Icons.logout, size: 16),
                label: const Text('Sign out'),
              ),
            )
          else
            IconButton(tooltip: 'Sign out', onPressed: widget.auth.logout, icon: const Icon(Icons.logout)),
        ],
      ),
      drawer: narrow
          ? Drawer(
              backgroundColor: AppColors.bgDeep,
              child: SafeArea(child: _navList(visible, p, inDrawer: true)),
            )
          : null,
      body: narrow
          ? body
          : Row(
              children: [
                AnimatedContainer(
                  duration: AppDurations.base,
                  curve: Curves.easeInOut,
                  width: _sidebarCollapsed ? 68 : 224,
                  decoration: const BoxDecoration(
                    color: AppColors.bgDeep,
                    border: Border(right: BorderSide(color: AppColors.divider)),
                  ),
                  child: _navList(visible, p, inDrawer: false, collapsed: _sidebarCollapsed),
                ),
                Expanded(child: body),
              ],
            ),
    );
  }
}

/// A single sidebar entry with the reference's copper tick indicator, quiet
/// inactive ink, and a subtle hover wash.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.active,
    required this.collapsed,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final fg = active
        ? AppColors.textPrimary
        : _hovered
            ? AppColors.textPrimary.withValues(alpha: 0.85)
            : AppColors.textSecondary;

    final item = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.symmetric(
            horizontal: widget.collapsed ? 0 : 12,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: active
                ? Colors.white.withValues(alpha: 0.06)
                : _hovered
                    ? Colors.white.withValues(alpha: 0.03)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment:
                widget.collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              // Copper tick marks the active module.
              if (!widget.collapsed)
                AnimatedContainer(
                  duration: AppDurations.fast,
                  width: 2.5,
                  height: active ? 14 : 0,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    color: AppColors.copperHi,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              Icon(widget.icon, size: 17, color: active ? AppColors.copperHi : fg),
              if (!widget.collapsed) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: 0.1,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Tooltip(message: widget.label, child: item),
      );
    }
    return item;
  }
}
