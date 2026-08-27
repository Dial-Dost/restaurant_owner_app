// The seat responses now carry `assignment` — WHO the seating put on the table,
// or why nobody. Both seat screens (the tables sheet and the queue) render it,
// and the only logic they share is this parse, so this is where the meaning of
// each case is pinned down.
//
// The distinction that matters and is easy to get backwards: `assigned == false`
// is USUALLY FINE. The auto path only ever fills a VACANT slot, so "someone was
// already assigned to this table and was kept" comes back as assigned:false with
// an employee — a healthy outcome that must not be flagged red. The case worth
// interrupting a host for is a table that came out of seating with NO waiter.

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/models/table_assignment.dart';

void main() {
  group('TableAssignmentOutcome.parse', () {
    test('reads a successful assignment', () {
      final o = TableAssignmentOutcome.parse({
        'assigned': true,
        'reason': 'assigned',
        'employee_id': 'emp-1',
        'employee_name': 'Asha K',
        'message': 'Asha K is now serving this table.',
      });
      expect(o, isNotNull);
      expect(o!.assigned, isTrue);
      expect(o.reason, 'assigned');
      expect(o.employeeName, 'Asha K');
      expect(o.leftTableUnattended, isFalse);
    });

    test('a KEPT assignment is not a problem — someone is still on the table', () {
      final o = TableAssignmentOutcome.parse({
        'assigned': false,
        'reason': 'already_assigned',
        'employee_id': 'emp-2',
        'employee_name': 'Binu M',
        'message': 'This table stays with Binu M - the waiter already assigned to it.',
      });
      expect(o!.assigned, isFalse);
      expect(o.leftTableUnattended, isFalse);
      expect(o.message, contains('Binu M'));
    });

    test('a table left with NOBODY is flagged, whatever the reason', () {
      for (final reason in const ['not_clocked_in', 'unknown_employee', 'no_actor', 'error']) {
        final o = TableAssignmentOutcome.parse({
          'assigned': false,
          'reason': reason,
          'employee_id': null,
          'employee_name': null,
          'message': 'No waiter was assigned.',
        });
        expect(o, isNotNull, reason: reason);
        expect(o!.leftTableUnattended, isTrue, reason: reason);
      }
    });

    test('an empty employee_id counts as nobody, not as an assignee', () {
      final o = TableAssignmentOutcome.parse({
        'assigned': false,
        'reason': 'error',
        'employee_id': '',
        'message': 'No waiter was assigned - the assignment could not be saved.',
      });
      expect(o!.leftTableUnattended, isTrue);
    });

    // Null means SAY NOTHING. An older backend omits the field entirely, and a
    // re-occupy of an already-seated table sends null on purpose — neither is
    // "this table has no waiter", and rendering them as such would put a red
    // warning on every order save.
    test('null / missing / non-map input yields null rather than a false alarm', () {
      expect(TableAssignmentOutcome.parse(null), isNull);
      expect(TableAssignmentOutcome.parse('assigned'), isNull);
      expect(TableAssignmentOutcome.parse(const <String, Object?>{}), isNull);
      expect(TableAssignmentOutcome.parse(const {'assigned': false}), isNull);
      expect(TableAssignmentOutcome.parse(const {'message': '   '}), isNull);
    });

    test('non-string ids and names are coerced, not crashed on', () {
      final o = TableAssignmentOutcome.parse({
        'assigned': true,
        'reason': 'assigned',
        'employee_id': 42,
        'employee_name': 7,
        'message': 'ok',
      });
      expect(o!.employeeId, '42');
      expect(o.employeeName, '7');
    });
  });
}
