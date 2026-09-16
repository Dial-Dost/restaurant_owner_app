// "WHEN WAIVING A SERVICE CHARGE, THE REASON SHOULD NOT BE MANDATORY."
//
// Client item for app 2.0.1. The server stores a missing reason as NULL where
// migration 051 allows it, and refuses as it always did where it does not. The
// till's half is small, and each piece of it can go quietly wrong:
//
//   * "NO REASON" SENT AS "". A backend from before the change refused "" in its
//     schema with a sentence nobody could act on; an absent reason gets its own
//     clean refusal. So a blank reason is left OUT of the body.
//   * A NULL RENDERED AS A QUOTED DASH. The live-waiver card read
//     `“${_s(w, 'reason')}” — …`, and `_s` turns null into "—", so a reasonless
//     waiver showed `“—” — asha, …` — a dash in quotes, as if someone typed it.
//   * EVERY OTHER REASON GOING OPTIONAL. The comp, its reversal, the void, the
//     cancel, the tender void and "Put the charge back" share one dialog with the
//     waiver. The flag is opt-in, defaults to false, and only the waiver sets it.
//   * THE TWO CLIENTS DISAGREEING. The web dashboard's label is the same words
//     (OPTIONAL_REASON_LABEL in src/lib/mis-capture.ts).
//
// The widget behaviour — Confirm live with no reason, the second name still
// required, the reversal unchanged — is pinned in mis_capture_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;

void main() {
  group('serviceChargeRemovalBody — what POST /bills/service-charge-waiver/print is sent', () {
    test('no reason is no key — not "", not null', () {
      final body = m.serviceChargeRemovalBody(
          tableName: 'T1', kind: 'guest_request', reason: '', authorisedBy: 'manager01');
      expect(body, {'table_name': 'T1', 'waiver_kind': 'guest_request', 'authorised_by': 'manager01'});
      expect(body.containsKey('reason'), isFalse);
    });

    test('a reason of only whitespace is no reason', () {
      final body = m.serviceChargeRemovalBody(
          tableName: 'T1', kind: 'guest_request', reason: ' \t \n ', authorisedBy: 'manager01');
      expect(body.containsKey('reason'), isFalse);
    });

    test('a typed reason is sent, trimmed, beside the kind and the second name', () {
      final body = m.serviceChargeRemovalBody(
          tableName: 'T4', kind: 'goodwill', reason: '  Regular, long wait ', authorisedBy: 'manager01');
      expect(body, {
        'table_name': 'T4',
        'waiver_kind': 'goodwill',
        'reason': 'Regular, long wait',
        'authorised_by': 'manager01',
      });
    });

    test('the kind and the second name are always sent — the server refuses without them', () {
      final body = m.serviceChargeRemovalBody(tableName: 'T1', kind: 'policy', reason: '', authorisedBy: 'asha');
      expect(body['waiver_kind'], 'policy');
      expect(body['authorised_by'], 'asha');
    });
  });

  group('serviceChargeWaiverAttribution — the live-waiver card\'s line', () {
    final withReason = <String, dynamic>{
      'reason': 'Long wait for the mains',
      'waived_by_username': 'asha',
      'authorised_by_username': 'manager01',
    };

    test('a waiver with a reason reads exactly as the card always read it', () {
      expect(m.serviceChargeWaiverAttribution(withReason),
          '“Long wait for the mains” — asha, authorised by manager01');
    });

    for (final (label, reason) in [('null', null), ('empty', ''), ('whitespace', '   ')]) {
      test('a reason that is $label: who and who authorised, and no quotes or dash in front', () {
        final line = m.serviceChargeWaiverAttribution({...withReason, 'reason': reason});
        expect(line, 'asha, authorised by manager01');
        expect(line, isNot(contains('“')));
        expect(line, isNot(startsWith('—')));
      });
    }

    test('a record with no reason key at all (a 2.0.0 server never sends one) reads the same', () {
      final w = Map<String, dynamic>.of(withReason)..remove('reason');
      expect(m.serviceChargeWaiverAttribution(w), 'asha, authorised by manager01');
    });
  });

  test('the label says optional, in the words the web dashboard uses', () {
    expect(m.misOptionalReasonLabel, 'Reason (optional)');
  });

  group('wiring — only the waiver\'s reason is optional, and the card and the form use the helpers', () {
    final src = File('lib/screens/mis_capture.dart').readAsStringSync().replaceAll('\r\n', '\n');

    test('the flag defaults to false, and exactly one of the seven dialogs sets it: the removal', () {
      expect(src, contains('this.reasonOptional = false,'));
      expect(RegExp(r'_CaptureReasonDialog\(\n').allMatches(src).length, 7);
      expect(RegExp(r'reasonOptional: true').allMatches(src).length, 1);
      final removal = src.substring(
        src.indexOf('Future<void> _removeServiceChargeAndPrint('),
        src.indexOf('Future<void> _reprintWithoutServiceCharge('),
      );
      expect(removal, contains('reasonOptional: true,'));
      expect(removal, contains('serviceChargeRemovalBody('));
      expect(removal, isNot(contains("'reason': answer.reason")));
    });

    test('the dialog skips the reason check only under the flag', () {
      expect(src, contains('if (!widget.reasonOptional && _reason.text.trim().isEmpty) return false;'));
      expect(src, contains('if (widget.needsAuthoriser && _authorisedBy.text.trim().isEmpty) return false;'));
      expect(src, contains("labelText: widget.reasonOptional ? misOptionalReasonLabel : 'Reason',"));
    });

    test('putting the charge back still sends its reason and never sets the flag', () {
      final reverse = src.substring(
        src.indexOf('Future<void> _reverseServiceChargeWaiver('),
        src.indexOf('// 037 + 038 — THE PAYMENT SCREEN'),
      );
      expect(reverse, isNot(contains('reasonOptional')));
      expect(reverse, contains("{'reason': answer.reason}"));
    });

    test('the live-waiver card renders the attribution helper, not the raw reason', () {
      expect(src, contains('Text(serviceChargeWaiverAttribution(w),'));
      expect(src, isNot(contains("“\${_s(w, 'reason')}”")));
    });
  });
}
