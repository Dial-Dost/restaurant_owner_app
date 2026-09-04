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
      firstName: (j['emp_Fname'] ?? '').toString(),
      employeeUsername: (j['employeeUsername'] ?? '').toString(),
      actionNames: _stringList(j['action_names']),
      actions: _stringList(j['actions_set']),
      features: _map(j['features']),
      limits: _map(j['limits']),
    );
  }

  static List<String> _stringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : const <String>[];

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
}
