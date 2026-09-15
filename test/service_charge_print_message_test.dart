// WHAT THE TILL IS TOLD AFTER "REMOVE SERVICE CHARGE & PRINT".
//
// THE BUG THIS FILE WAS WRITTEN FOR, reported from a live floor: "bills printed
// without a service charge show the same total as bills with one — correct in
// the preview, wrong on the paper." Every figure in that report was right. The
// server had stopped letting `no_service_charge` lower a total without a
// recorded waiver, said so in its response, and the app discarded the answer
// and announced "Reprinting without service charge…" anyway. The money was
// never wrong. The SENTENCE was.
//
// Client item 6 then merged the two steps that bug lived between — "reprint
// without service charge and waive service charge should be merged as one
// option" — into one server call, POST /bills/service-charge-waiver/print. The
// flag-reading message went with the old button. What replaced it has the same
// duty: say only what the server did. So this pins, against that route's
// response:
//
//   * a removal that printed names both payable totals;
//   * a reprint of an existing waiver names the total on the paper and does
//     NOT claim anything was just removed;
//   * a removal whose PRINT FAILED says the charge is off AND that no paper came
//     out — the half that would otherwise send somebody to a silent printer —
//     and stays on screen long enough to be read;
//   * a paper that carries the charge after all is never described as removed.
//
// And the waived card's own print control, whose confirmation said "It is marked
// as a reprint" on bills the server had never printed — so the paper came out
// with no REPRINT banner under a dialog that promised one. Its words now follow
// the server's print ledger (serviceChargeWaivedPrintCopy).
//
// The web dashboard's `serviceChargeRemovalSentence` (src/lib/mis-capture.ts)
// says the same words; its suite pins the same cases.

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;

void main() {
  group('serviceChargeRemovalOutcome — the message must match what the server did', () {
    test('removed and printed: both payable totals, as the server rounded them', () {
      final r = m.serviceChargeRemovalOutcome({
        'printed': true,
        'waiver_created': true,
        'service_charge_removed': true,
        'grand_total_before': 6324,
        'grand_total_after': 5774,
      });
      expect(r.message, 'Service charge removed — total ₹6324.00 → ₹5774.00. Printing bill…');
    });

    test('an existing waiver reprinted: the paper\'s total, and no claim of a new removal', () {
      final r = m.serviceChargeRemovalOutcome({
        'printed': true,
        'waiver_created': false,
        'service_charge_removed': true,
        'grand_total_before': null,
        'grand_total_after': 5774,
      });
      expect(r.message, 'Reprinting without the service charge — total ₹5774.00.');
      expect(r.message, isNot(contains('removed')));
    });

    test('THE HALF THAT MATTERS: removed, but the print failed — says both, and what to press', () {
      final r = m.serviceChargeRemovalOutcome({
        'printed': false,
        'print_error': 'printer routing table unreadable',
        'waiver_created': true,
        'service_charge_removed': true,
        'grand_total_before': 6324,
        'grand_total_after': 5774,
      });
      expect(r.message,
          'Service charge removed (₹6324.00 → ₹5774.00), but the bill did not print: printer routing table unreadable. Press Print bill.');
      expect(r.message, isNot(contains('Printing bill')));
    });

    test('a failed REPRINT does not pretend a removal just happened', () {
      final r = m.serviceChargeRemovalOutcome({
        'printed': false,
        'print_error': 'Nothing to print for this table',
        'waiver_created': false,
        'waiver': {'id': 'w-live'},
        'grand_total_before': null,
        'grand_total_after': null,
      });
      expect(r.message,
          'The service charge is off this bill, but the bill did not print: Nothing to print for this table. Press Print bill.');
    });

    test('a failure stays on screen longer than a routine confirmation', () {
      final failed = m.serviceChargeRemovalOutcome({'printed': false, 'waiver_created': true});
      final ok = m.serviceChargeRemovalOutcome({
        'printed': true, 'waiver_created': true, 'grand_total_before': 1, 'grand_total_after': 1,
      });
      // It asks the reader to go and do something, while they are already
      // walking to a printer. A three-second snackbar is gone before they look up.
      expect(failed.shown, greaterThan(ok.shown));
    });

    test('paper that carries the charge after all is NEVER described as removed', () {
      // The waiver was put back between the commit and the print. The server's
      // paper carries the charge and says so; the sentence must too.
      final r = m.serviceChargeRemovalOutcome({
        'printed': true,
        'waiver_created': true,
        'service_charge_removed': false,
        'grand_total_before': 6324,
        'grand_total_after': 6324,
      });
      expect(r.message, contains('WITH the service charge'));
      expect(r.message, isNot(contains('removed —')));
    });

    test('an unreadable reply is not a success story', () {
      final r = m.serviceChargeRemovalOutcome(null);
      expect(r.message, 'The bill did not print. Press Print bill.');
      // It proves nothing about the charge, so it says nothing about it.
      expect(r.message, isNot(contains('service charge')));
    });
  });

  group('serviceChargeWaivedPrintCopy — "reprint" only when the paper will say so', () {
    test('printed before (print_count > 0): Reprint, and the banner is promised', () {
      final c = m.serviceChargeWaivedPrintCopy({'print_count': 2, 'bill_printed_at': '2026-09-15T13:02:00Z'});
      expect(c.label, 'Reprint without the charge');
      expect(c.title, 'Reprint without the service charge?');
      expect(c.body, contains('It is marked as a reprint.'));
      expect(c.confirm, 'Reprint');
    });

    test('THE BUG: a waiver nobody printed (print_count 0) is a first print, with no banner promised', () {
      // A 1.9.9 till's "Waive service charge" records without printing, and a
      // removal whose print failed leaves the same bill. The server prints it
      // with `reprint: print_count > 0` — false — so the paper has no banner.
      final c = m.serviceChargeWaivedPrintCopy({'print_count': 0, 'bill_printed_at': null, 'printed_at': null});
      expect(c.label, 'Print without the charge');
      expect(c.title, 'Print without the service charge?');
      expect(c.body, isNot(contains('reprint')));
      expect(c.body, isNot(contains('again')));
      expect(c.confirm, 'Print');
    });

    test('a first-print instant alone is the server saying printed', () {
      expect(m.serviceChargeWaivedPrintCopy({'bill_printed_at': '2026-09-15T13:02:00Z'}).label,
          'Reprint without the charge');
    });

    test('no print state at all promises nothing about a banner', () {
      final c = m.serviceChargeWaivedPrintCopy(const {});
      expect(c.label, 'Print without the charge');
      expect(c.body, isNot(contains('reprint')));
    });
  });

  group('misServiceChargeOnBill — the headline in both shapes', () {
    test('the restaurant_percent leg', () {
      expect(m.misServiceChargeOnBill({'service_charge': 549.9, 'taxes': const []}), 549.9);
    });

    test('a TAX-LINE tenant, whose `service_charge` is always 0', () {
      // Most of the fleet. A headline read from `service_charge` alone showed
      // nothing on exactly the bills people take the charge off.
      expect(
        m.misServiceChargeOnBill({
          'service_charge': 0,
          'taxes': const [
            {'name': 'SGST', 'percentage': 2.5, 'amount': 137.48},
            {'name': 'Service Charge', 'percentage': 10, 'amount': 549.90},
          ],
        }),
        549.9,
      );
    });

    test('matched the way the server matches it: "ServiceCharge" is a service charge', () {
      expect(
        m.misServiceChargeOnBill({
          'taxes': const [
            {'name': 'ServiceCharge', 'amount': 10},
            {'name': 'service  charge (AC)', 'amount': 5},
            {'name': 'CGST', 'amount': 3},
          ],
        }),
        15,
      );
    });
  });
}
