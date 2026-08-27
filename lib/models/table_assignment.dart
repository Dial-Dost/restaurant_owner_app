/// What a seating did about the table's WAITER, as reported by the backend on
/// `POST /occupy-table` and `POST /waitlist/:id/seat` (the `assignment` field —
/// see TableAssignmentOutcome in database_supabase.ts).
///
/// WHY THIS IS A TYPE AND NOT AN INLINE MAP LOOKUP AT EACH CALL SITE: seating a
/// guest is supposed to make the seater that table's waiter, and for weeks it
/// silently did not — the server skipped the assignment without logging and no
/// client asked, so a floor where no table had a waiter looked entirely normal.
/// The server now always states the outcome. Parsing it in one place is what
/// stops one of the two seat screens quietly dropping the field again.
class TableAssignmentOutcome {
  const TableAssignmentOutcome({
    required this.assigned,
    required this.reason,
    required this.employeeId,
    required this.employeeName,
    required this.message,
  });

  /// True when THIS seating put the actor on the table.
  final bool assigned;

  /// assigned | already_assigned | unknown_employee | not_clocked_in | no_actor | error
  final String reason;

  /// Who holds the table AFTER the seating — the new assignee, or the existing
  /// one that was kept. Null when the table ends up with nobody.
  final String? employeeId;
  final String? employeeName;

  /// One sentence, written by the server, safe to show verbatim.
  final String message;

  /// Parse the `assignment` field of a seat response. Returns null for anything
  /// that is not a seating outcome: an older backend that does not send the
  /// field, or an occupy that was never a seating (the order flow re-occupies an
  /// already-occupied table around every save and has no opinion about the
  /// waiter). Null means SAY NOTHING — never "no waiter".
  static TableAssignmentOutcome? parse(Object? raw) {
    if (raw is! Map) return null;
    final message = '${raw['message'] ?? ''}'.trim();
    if (message.isEmpty) return null;
    final id = raw['employee_id'];
    final name = raw['employee_name'];
    return TableAssignmentOutcome(
      assigned: raw['assigned'] == true,
      reason: '${raw['reason'] ?? ''}',
      employeeId: id == null ? null : '$id',
      employeeName: name == null ? null : '$name',
      message: message,
    );
  }

  /// The table came out of this seating with NOBODY serving it.
  ///
  /// `assigned == false` on its own is NOT a problem: the commonest case is
  /// "someone was already assigned to this table and was kept", which is the
  /// whole point of the auto path only ever filling a vacant slot. The case a
  /// host needs flagged is a table with no waiter at all — still cheap to fix
  /// while the party is standing in front of them.
  bool get leftTableUnattended =>
      !assigned && (employeeId == null || employeeId!.isEmpty);
}
