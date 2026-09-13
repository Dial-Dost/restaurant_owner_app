// WHAT THE TILL IS TOLD AFTER A THERMAL PRINT.
//
// THE BUG THIS PINS, reported from a live floor: "bills printed without a
// service charge show the same total as bills with one — correct in the
// preview, wrong on the paper."
//
// Every figure in that report was right. `POST /print/bill` with
// `no_service_charge: true` prints the FULL total on a bill carrying no
// recorded waiver, deliberately — a printed total lower than the settled one is
// a receipt a guest can hold up against a till that disagrees with it — and it
// says so in its response:
//
//     service_charge_removed: false
//     service_charge_waiver_required: true
//
// The app discarded that answer and announced "Reprinting without service
// charge…" regardless. So the screen promised one total and the paper carried
// another, and the person reading the snackbar is the person handing over the
// receipt.
//
// Verified against a live stack before this test was written, on a tenant
// carrying its service charge as a TAX LINE (the shipped default shape):
//
//   no waiver  -> removed=false, waiver_required=true, paper Grand Total 1060.00
//   waiver     -> removed=true,  waiver_required=false, paper reads
//                 "Service Charge (1%)  Opted-out", Grand Total 1050.00
//
// So the money was never wrong. The sentence was. This pins the sentence.

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;

void main() {
  group('thermalPrintOutcome — the message must match what the server did', () {
    test('an ordinary print says the ordinary thing', () {
      final r = m.thermalPrintOutcome(
        askedWithoutServiceCharge: false,
        removed: false,
        waiverRequired: false,
      );
      expect(r.message, 'Printing bill…');
    });

    test('asked without the charge AND the server removed it — says so', () {
      final r = m.thermalPrintOutcome(
        askedWithoutServiceCharge: true,
        removed: true,
        waiverRequired: false,
      );
      expect(r.message, contains('without the service charge'));
    });

    test('THE REGRESSION: asked without it, server kept it — must NOT claim it came off', () {
      final r = m.thermalPrintOutcome(
        askedWithoutServiceCharge: true,
        removed: false,
        waiverRequired: true,
      );
      // The old behaviour was to say "Reprinting without service charge…" here.
      // That sentence, on this branch, is the whole defect.
      expect(r.message, isNot(contains('without the service charge')));
      expect(r.message, contains('WITH the service charge'));
      // It must name the mechanism, or the waiter presses the same button again.
      expect(r.message, contains('Waive service charge'));
    });

    test('the refusal stays on screen longer than a routine confirmation', () {
      final refused = m.thermalPrintOutcome(
        askedWithoutServiceCharge: true,
        removed: false,
        waiverRequired: true,
      );
      final ordinary = m.thermalPrintOutcome(
        askedWithoutServiceCharge: false,
        removed: false,
        waiverRequired: false,
      );
      // It asks the reader to go and do something, while a printer is already
      // running. A three-second snackbar is gone before they look up.
      expect(refused.shown, greaterThan(ordinary.shown));
    });

    test('nothing to remove is not the same as something removed', () {
      // Neither flag set: this bill carried no service charge at all. Claiming
      // one came off would be a different lie from the one above.
      final r = m.thermalPrintOutcome(
        askedWithoutServiceCharge: true,
        removed: false,
        waiverRequired: false,
      );
      expect(r.message, isNot(contains('without the service charge')));
      expect(r.message, isNot(contains('WITH the service charge')));
    });
  });
}
