// "ROUND OFF THE FINAL AMOUNT ALWAYS IN FINAL BILL" — the app's half.
//
// The backend rounds every bill to the rupee once, in its billing layer, and
// sends `round_off` beside `grand_total` (migration 048). The app never rounds:
// it READS that adjustment and shows it as a line when it is not zero. The
// reader is pinned here; the screens that draw it are pinned where they are
// mounted (bill_preview_totals_test.dart for the preview and the table sheet,
// money_drilldowns_test.dart for the settled bill) — and the waiter's running
// bill strip, which has no mountable harness of its own, by its source.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/models/bill_round_off.dart';

void main() {
  group('billRoundOff — the server\'s round-off, or nothing to show', () {
    test('reads the adjustment off a payload', () {
      expect(billRoundOff(-0.26), -0.26);
      expect(billRoundOff(0.5), 0.5);
      // numeric(12,2) can arrive as a string through a JSON layer.
      expect(billRoundOff('-0.26'), -0.26);
    });

    test('a whole bill, a bill settled before rounding and an older backend show nothing', () {
      expect(billRoundOff(0), isNull);
      expect(billRoundOff(0.0), isNull);
      expect(billRoundOff(null), isNull);
    });

    test('junk and float noise under a paisa are nothing, never a guess', () {
      expect(billRoundOff('abc'), isNull);
      expect(billRoundOff(''), isNull);
      expect(billRoundOff(double.nan), isNull);
      expect(billRoundOff(0.004), isNull);
      expect(billRoundOff(0.1 + 0.2 - 0.3), isNull);
    });

    test('the paper\'s form is signed with no currency, as escpos.ts prints it', () {
      expect(billRoundOffPaper(-0.26), '-0.26');
      expect(billRoundOffPaper(0.5), '+0.50');
    });

    test('a screen\'s form is always signed, so it cannot be read as a charge or a discount', () {
      expect(billRoundOffMoney(-0.26), '−₹0.26');
      expect(billRoundOffMoney(0.5), '+₹0.50');
    });
  });

  test('the waiter\'s running-bill strip draws the Round off row above TOTAL PAYABLE', () {
    final src = File('lib/widgets/table_bill.dart').readAsStringSync();
    final row = src.indexOf("row('Round off', billRoundOffMoney(billRoundOff(bill['round_off'])!))");
    expect(row, greaterThan(0));
    expect(src.indexOf("if (billRoundOff(bill['round_off']) != null)"), lessThan(row));
    expect(row, lessThan(src.indexOf("Text('TOTAL PAYABLE'")));
  });
}
