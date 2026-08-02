import 'package:flutter/widgets.dart';

/// Signature of the shell's "jump to another module" callback.
///
/// [label] is the module's registry label (e.g. 'Orders', 'Inventory').
/// [target] optionally carries entity ids from the caller (e.g.
/// `{'order_id': 12}`) for the destination module to focus.
typedef OpenModuleCallback = void Function(String label, {Map<String, dynamic>? target});

/// A request to focus ONE record inside a module — what a tapped notification
/// (or any cross-module drill-down) hands to its destination.
///
/// The shell parks it on the [ModuleNavigator] and the destination module reads
/// it with `ModuleNavigator.of(context)?.focusFor('Orders')`, so per-record
/// focus works without widening the `(RestClient, Profile) -> Widget` builder
/// signature every module shares.
@immutable
class ModuleFocusRequest {
  const ModuleFocusRequest({
    required this.moduleLabel,
    required this.target,
    required this.serial,
  });

  /// Module the focus belongs to — a module only ever reads its own request.
  final String moduleLabel;

  /// The caller's payload. For a notification this is its stored `meta` merged
  /// with the backend resolver's answer (`entity_id`, `entity_type`) — see
  /// `GET /notifications/:id/target`.
  final Map<String, dynamic> target;

  /// Bumped on every request, so two taps on the same record are distinguishable
  /// and the shell can remount the destination to refetch.
  final int serial;

  String? _str(String key) {
    final v = target[key];
    if (v == null) return null;
    final s = '$v'.trim();
    return (s.isEmpty || s == 'null') ? null : s;
  }

  /// Id of the record to focus: the resolver's `entity_id` first, then the
  /// per-type meta keys the backend has always written (older notification rows
  /// carry only those).
  String? idOf(List<String> fallbackKeys) {
    final direct = _str('entity_id');
    if (direct != null) return direct;
    for (final k in fallbackKeys) {
      final v = _str(k);
      if (v != null) return v;
    }
    return null;
  }

  /// `order` / `booking` / `waitlist` / … when the resolver ran, else null.
  String? get entityType => _str('entity_type');

  /// Table name carried by table-scoped notifications (QR orders, payments).
  String? get tableName => _str('table');
}

/// Exposes the shell's module navigation to any widget below it, without
/// widening the `(RestClient, Profile) -> Widget` builder signature every
/// module shares.
///
/// Modules obtain it with `ModuleNavigator.of(context)?.openModule('Orders')`.
/// It is deliberately nullable: a module rendered outside the shell (tests,
/// previews) simply gets `null` and should degrade to no navigation.
class ModuleNavigator extends InheritedWidget {
  const ModuleNavigator({
    super.key,
    required this.openModule,
    required this.visibleLabels,
    required this.clearFocus,
    this.focus,
    this.switchOutlet,
    required super.child,
  });

  /// Jumps the shell to the module registered under [label]. Safe no-op when
  /// that module is not visible to the signed-in user (permission- or
  /// feature-gated) or the label is unknown.
  final OpenModuleCallback openModule;

  /// Labels of the modules currently visible to this user — lets a caller hide
  /// an affordance instead of offering a navigation that would no-op.
  final List<String> visibleLabels;

  /// The record the shell was asked to focus, or null. Read it through
  /// [focusFor] so a module never picks up another module's request.
  final ModuleFocusRequest? focus;

  /// Drops the pending focus (the module's "x" on its focus banner).
  final VoidCallback clearFocus;

  /// Switches the active outlet the same way the AppBar switcher does — an
  /// outlet id, or 'all' for the combined read-only view. Null when the
  /// signed-in user cannot switch (single outlet / no permission).
  final void Function(String outletId)? switchOutlet;

  /// True when [label] is reachable for the signed-in user.
  bool canOpen(String label) => visibleLabels.contains(label);

  /// The pending focus request iff it belongs to [label].
  ModuleFocusRequest? focusFor(String label) => focus?.moduleLabel == label ? focus : null;

  static ModuleNavigator? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModuleNavigator>();

  @override
  bool updateShouldNotify(ModuleNavigator oldWidget) =>
      oldWidget.openModule != openModule ||
      oldWidget.switchOutlet != switchOutlet ||
      oldWidget.focus?.serial != focus?.serial ||
      oldWidget.focus?.moduleLabel != focus?.moduleLabel ||
      !identical(oldWidget.visibleLabels, visibleLabels) &&
          oldWidget.visibleLabels.join(' ') != visibleLabels.join(' ');
}
