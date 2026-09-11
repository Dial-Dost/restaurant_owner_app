/// THE NINE ANSWERS THE SERVER SHIPS BESIDE `waiter_only` — "may this identity
/// DO x", decided once, on the server, for every client.
///
/// WHY AN ENUM OF WIRE KEYS AND NOT NINE BOOLEAN FIELDS SPRAYED ACROSS THE APP.
/// Each of these is backed by a permission UUID and a route guard, and the whole
/// defect this block exists to end is the same rule written down twice: the uuid
/// in the server's route, the uuid again in Dart, and the two free to drift.
/// `sessionCapabilities` in routes/_shared.ts is the ONE list of which uuid
/// backs which control; this is the ONE list of how to read its answer. No
/// permission uuid for any of these belongs anywhere else in this app.
///
/// A FLAG THE SERVER DID NOT SEND IS `null`, NEVER `false`. See [Profile.said].
enum Capability {
  /// POST /bills/order/:id/waiter-confirm-payment | /admin-approve-payment |
  /// /close, PATCH /orders/:id/status -> Paid — and POST /release-table, which
  /// zeroes and closes an open bill and is therefore the same authority under a
  /// gentler name. See [FloorScope.release].
  settleBill('settle_bill'),

  /// DELETE /table/:name.
  deleteTable('delete_table'),

  /// POST /add-table, PATCH /table/:name — adding a table, editing its seating,
  /// and moving one between existing zones.
  editTable('edit_table'),

  /// POST/PATCH/DELETE /table-sections — minting, renaming and dissolving zones.
  manageTableSections('manage_table_sections'),

  /// POST /orders/:id/items/:itemId/non-chargeable — "Comp an item".
  compItem('comp_item'),

  /// POST /bills/service-charge-waiver — "Waive service charge".
  waiveServiceCharge('waive_service_charge'),

  /// POST /orders/:id/void — cancelling a rung-up order with a recorded reason.
  voidOrder('void_order'),

  /// GET /roles, GET /core-roles — who may OPEN the access-control screen.
  viewRoles('view_roles'),

  /// POST /roles — who may create and edit a custom role.
  manageRoles('manage_roles');

  const Capability(this.wireKey);

  /// The key this flag arrives under inside the session payload's `scope`.
  final String wireKey;
}

/// The signed-in owner's profile, as returned by /auth/employee-login and
/// /auth/me. Tolerant of missing fields so older/newer backends don't crash it.
class Profile {
  final String employeeId;
  final String restaurantName;
  final String restaurantUsername;
  final String resId;
  final String outletId;
  final String role;
  final List<String> roleAll;

  /// THE SERVER'S ANSWER to "is this a scoped floor role", or null when the
  /// backend is older than the field.
  ///
  /// The clients used to DERIVE this from [roleAll] by asking whether every
  /// entry was literally the word "waiter". That is a test on spelling, not on
  /// authority, and it was wrong on any tenant whose waiters carried a custom
  /// role — those are stored as UUIDs, so `every` failed and every restriction
  /// lifted, money included. See role_scope.ts on the server for the whole
  /// story; the rule now lives there, once, for every client.
  ///
  /// NULLABLE ON PURPOSE. An app pointed at a backend that predates the field
  /// must keep working, so null means "the server did not say" and the local
  /// heuristic answers instead. It is not defaulted to false: that would silently
  /// un-scope every waiter the moment the app ran ahead of the backend.
  final bool? waiterOnly;

  /// THE SERVER'S ANSWER to each of [Capability], for the flags it actually
  /// sent. A capability the server did not mention is ABSENT from this map, not
  /// false — see [said].
  ///
  /// These arrive in the SAME `scope` block as [waiterOnly] and are read the
  /// same way and for the same reason: the alternative is every client testing
  /// the backing permission UUID itself, which is the one rule written three
  /// times that this whole block exists to end.
  final Map<Capability, bool> capabilities;

  final String firstName;

  /// The LOGIN identity, as stored. Served by /auth/employee-login and /auth/me.
  ///
  /// It is here for exactly one job: pre-filling the `authorised_by` field on a
  /// comp / void / service-charge waiver, which is the "a manager acting alone
  /// signs their own name" case migration 034's header describes. It is NEVER
  /// the actor of a write — every one of those routes takes the actor from the
  /// verified session and has no body field that could set it. Empty on an
  /// older backend, which the capture forms handle by simply not pre-filling.
  final String employeeUsername;
  final List<String> actionNames;
  final List<String> actions; // action UUIDs or ["*"]; used for permission gating
  final Map<String, dynamic> features;
  final Map<String, dynamic> limits;

  const Profile({
    required this.employeeId,
    required this.restaurantName,
    required this.restaurantUsername,
    required this.resId,
    required this.outletId,
    required this.role,
    required this.roleAll,
    this.waiterOnly,
    this.capabilities = const <Capability, bool>{},
    required this.firstName,
    this.employeeUsername = '',
    required this.actionNames,
    required this.actions,
    required this.features,
    required this.limits,
  });

  /// True if the user may see a module whose permission keywords are [keywords].
  /// Admins (actions == ["*"]) see everything; otherwise match keywords against
  /// the human-readable permitted action names (mirrors the web dashboard).
  bool can(List<String> keywords) {
    if (keywords.isEmpty) return true;
    if (actions.contains('*')) return true;
    final names = actionNames.map((s) => s.toLowerCase());
    return keywords.any((k) => names.any((n) => n.contains(k)));
  }

  /// True when this user is an admin (by primary role or any granted role).
  /// Used to gate sensitive sections (Settings, etc.) that must never be
  /// editable by waiters/cashiers — mirrors the backend's enforceAdmin gate.
  bool get isAdmin {
    if (role.toLowerCase() == 'admin') return true;
    return roleAll.any((r) => r.toLowerCase() == 'admin');
  }

  /// True unless the restaurant's subscription plan explicitly disables
  /// [feature]. Additive by design: an empty/unset plan (or unknown flag) always
  /// allows, mirroring the backend's additive feature gate.
  bool featureEnabled(String? feature) {
    if (feature == null || feature.isEmpty) return true;
    return features[feature] != false;
  }

  factory Profile.fromJson(Map<String, dynamic> j) {
    return Profile(
      employeeId: (j['employeeId'] ?? j['uid'] ?? '').toString(),
      restaurantName: (j['restaurantName'] ?? '').toString(),
      restaurantUsername: (j['restaurantUsername'] ?? '').toString(),
      resId: (j['res_id'] ?? '').toString(),
      outletId: (j['outlet_id'] ?? '').toString(),
      role: (j['role'] ?? '').toString(),
      roleAll: _stringList(j['role_all']),
      waiterOnly: _scopeFlag(j['scope'], 'waiter_only'),
      capabilities: _capabilities(j['scope']),
      firstName: (j['emp_Fname'] ?? '').toString(),
      employeeUsername: (j['employeeUsername'] ?? '').toString(),
      actionNames: _stringList(j['action_names']),
      actions: _stringList(j['actions_set']),
      features: _map(j['features']),
      limits: _map(j['limits']),
    );
  }

  /// The inverse of [Profile.fromJson], so a session can be restored from disk
  /// when the server cannot be reached.
  ///
  /// THE KEYS ARE THE WIRE'S KEYS, not Dart field names, and that is deliberate:
  /// what gets written to disk is indistinguishable from what /auth/me returned,
  /// so the restore path and the network path parse the same shape and cannot
  /// drift into disagreeing about what a profile is. `profile_round_trips_test`
  /// pins that — add a field to fromJson without adding it here and it fails.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'employeeId': employeeId,
        'restaurantName': restaurantName,
        'restaurantUsername': restaurantUsername,
        'res_id': resId,
        'outlet_id': outletId,
        'role': role,
        'role_all': roleAll,
        // Written back in the WIRE's shape so the disk copy and /auth/me parse
        // identically. Omitted entirely when the server never said, so a restore
        // cannot invent an answer the server did not give.
        //
        // EVERY CAPABILITY RIDES ALONG, and that is not tidiness. The offline
        // restore reads this file back as the session: a flag that did not
        // survive the round trip would come back absent, the fallback would
        // answer instead, and a gate would silently CHANGE on a cold launch —
        // a waiter's Settle button reappearing, or an owner's disappearing,
        // for no reason anybody on the floor could see.
        if (scopeJson.isNotEmpty) 'scope': scopeJson,
        'emp_Fname': firstName,
        'employeeUsername': employeeUsername,
        'action_names': actionNames,
        'actions_set': actions,
        'features': features,
        'limits': limits,
      };

  /// True/false when the server SAID, null when it did not.
  ///
  /// THE NULL IS THE WHOLE POINT AND IT MUST NOT BE COLLAPSED TO FALSE. An app
  /// that has run ahead of its backend — a Windows till that auto-updated before
  /// the server deploy, a profile restored from disk that was written by an
  /// older build — gets null for every one of these. Read as false, that day
  /// takes the till away from the owner: no Settle, no floor edits, no roles
  /// screen, on a restaurant that is open. Read as "the server did not say", the
  /// caller falls back to what it did before the flag existed and nothing moves.
  /// Exactly the direction [waiterOnly] already fails in.
  bool? said(Capability c) => capabilities[c];

  /// The `scope` block as it goes back to disk — [waiterOnly] and every
  /// capability the server actually sent, under the wire's own keys.
  Map<String, dynamic> get scopeJson => <String, dynamic>{
        if (waiterOnly != null) 'waiter_only': waiterOnly,
        for (final e in capabilities.entries) e.key.wireKey: e.value,
      };

  /// Every capability the server sent, in the order [Capability] declares them.
  /// A key that is absent, null, or not a real boolean is simply not in the map:
  /// "not said" and "said false" are different answers and must stay different.
  static Map<Capability, bool> _capabilities(dynamic scope) {
    if (scope is! Map) return const <Capability, bool>{};
    final out = <Capability, bool>{};
    for (final c in Capability.values) {
      final v = scope[c.wireKey];
      if (v is bool) out[c] = v;
    }
    return out;
  }

  /// One flag out of the server's `scope` block, or null when it is absent or
  /// unreadable. Anything that is not a real boolean reads as "not said" rather
  /// than as false — see [waiterOnly] for why that direction matters.
  static bool? _scopeFlag(dynamic scope, String key) {
    if (scope is! Map) return null;
    final v = scope[key];
    return v is bool ? v : null;
  }

  static List<String> _stringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : const <String>[];

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
}
