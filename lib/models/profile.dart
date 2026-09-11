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
        if (waiterOnly != null) 'scope': <String, dynamic>{'waiter_only': waiterOnly},
        'emp_Fname': firstName,
        'employeeUsername': employeeUsername,
        'action_names': actionNames,
        'actions_set': actions,
        'features': features,
        'limits': limits,
      };

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
