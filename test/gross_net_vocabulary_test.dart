import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/gross_net.dart';

/// GROSS, NET AND ITEM TOTAL in the app — the words, the keys behind them, and
/// the screens that must say them.
///
/// Backend jest (test/money/gross_net_vocabulary.test.ts) pins the server's
/// side: every MIS column labelled Gross is keyed grand_total, every Net is
/// keyed net, and the accounting Sales report's total_net is the MIS Net. What
/// can still go wrong HERE is the hard-coded furniture — a summary tile, the
/// money-ladder card, the Accounting NET SALES card — and each case below is one
/// way it could put the client's word on the wrong number:
///   * a tile reading the deprecated `gross` key (the item total) under "Gross",
///     which is exactly the complaint;
///   * NET SALES showing net_sales (Gross less refunds, tax and all) again;
///   * "Net" reappearing on the Settlement Summary's after-refunds figure;
///   * a helper that exists and a screen that never calls it.
/// The widget-level reads live beside their harnesses: reports_module_test.dart
/// (the ladder card) and money_drilldowns_test.dart (the Accounting card).
void main() {
  // Read with CRLF folded to LF, so a Windows checkout pins the same text a Linux
  // one does (the CRLF trap test/kot_hold_as_note_test.dart falls into).
  String source(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group('the three words', () {
    test('are the words the server labels its columns with, and the web says the same', () {
      expect([kGross, kNet, kItemTotal, kAfterRefunds], ['Gross', 'Net', 'Item total', 'After refunds']);
    });
  });

  group('itemTotalOf', () {
    test('reads item_total, and never the grand total', () {
      expect(itemTotalOf({'item_total': 5985.0, 'gross': 5985.0, 'grand_total': 6137.0}), 5985.0);
      expect(itemTotalOf({'item_total': 5985.0, 'gross': 1.0}), 5985.0);
    });

    test('falls back to the deprecated gross alias on a backend that does not send item_total', () {
      expect(itemTotalOf({'gross': 1900.0, 'grand_total': 2000.0}), 1900.0);
    });
  });

  group('discountPctOf', () {
    test('reads the item-total share, falling back to the old key', () {
      expect(discountPctOf({'discount_pct_of_item_total': 2.51, 'discount_pct_of_gross': 9.9}), 2.51);
      expect(discountPctOf({'discount_pct_of_gross': 2.51}), 2.51);
    });
  });

  group('readAccountingSales', () {
    test('headlines Net as total_net — never net_sales, which is Gross less refunds with the tax still in', () {
      final s = readAccountingSales({'total_sales': 6137, 'total_net': 5835, 'total_refund': 60, 'net_sales': 6077});
      expect(s.headlineLabel, 'Net sales');
      expect(s.headlineValue, 5835);
      expect(s.grossSales, 6137);
      expect(s.grossAfterRefunds, 6077);
      expect(s.headlineValue, isNot(6077));
    });

    test('on a backend without total_net, the card names the figure it can show instead of borrowing "Net"', () {
      final s = readAccountingSales({'total_sales': 6137, 'total_refund': 60, 'net_sales': 6077});
      expect(s.netSales, isNull);
      expect(s.headlineLabel, 'Gross after refunds');
      expect(s.headlineValue, 6077);
    });

    test('a missing report is nulls, not zeroes', () {
      final s = readAccountingSales(null);
      expect([s.grossSales, s.netSales, s.refunds, s.grossAfterRefunds, s.roundOff, s.headlineValue],
          everyElement(isNull));
    });
  });

  // The printed Accounting PDF is the copy that gets filed. Its Sales block was
  // inline kv(...) calls, and pointing its "Net sales" line at net_sales — the
  // exact complaint — passed every suite, because the only guard checked that an
  // old caption string was gone.
  group('accountingSalesPdfLines', () {
    Map<String, dynamic> byLabel(List<SalesPdfLine> lines) => {for (final l in lines) l.label: l.value};

    test('Net sales prints total_net, Gross after refunds prints net_sales, Gross sales prints total_sales', () {
      final lines = accountingSalesPdfLines(
          {'total_sales': 6137, 'total_net': 5835, 'total_refund': 60, 'net_sales': 6077, 'bill_count': 3});
      expect(lines.map((l) => l.label), ['Gross sales', 'Bills', 'Gross after refunds', 'Net sales']);
      final v = byLabel(lines);
      expect(v['Gross sales'], 6137);
      expect(v['Gross after refunds'], 6077);
      expect(v['Net sales'], 5835);
      expect(v['Net sales'], isNot(6077), reason: 'net_sales is Gross less refunds, tax still in');
      expect(v['Bills'], 3);
      expect(lines.singleWhere((l) => l.bold).label, 'Net sales');
    });

    test('an older backend without total_net prints no Net sales line at all, rather than borrowing the word', () {
      final lines = accountingSalesPdfLines({'total_sales': 6137, 'total_refund': 60, 'net_sales': 6077});
      expect(lines.map((l) => l.label), ['Gross sales', 'Bills', 'Gross after refunds']);
      expect(byLabel(lines)['Bills'], 0);
    });
  });

  // ---------------------------------------------------------------- wiring --

  group('the report tiles say the words through the model', () {
    final src = source('lib/screens/reports.dart');

    test('no summary tile or ladder rung hard-codes Gross, Net, Grand total or the old names', () {
      expect(src, isNot(contains("_misStat(context, 'Gross'")));
      expect(src, isNot(contains("_misStat(context, 'Net'")));
      expect(src, isNot(contains("_misStat(context, 'Grand total'")));
      expect(src, isNot(contains("'Net taken'")));
      expect(src, isNot(contains("'% of gross'")));
      expect(src, isNot(contains("'Whole menu gross'")));
      expect(src, isNot(contains("line('Gross'")));
      expect(src, isNot(contains("line('Grand total'")));
    });

    test('every Gross tile reads grand_total, and every Net tile reads net', () {
      final gross = RegExp(r"_misStat\(context, kGross, _money\(([^)]*)\)").allMatches(src).map((m) => m.group(1)).toList();
      expect(gross.length, greaterThanOrEqualTo(6));
      expect(gross, everyElement("totals['grand_total']"));
      final net = RegExp(r"_misStat\(context, kNet, _money\(([^)]*)\)").allMatches(src).map((m) => m.group(1)).toList();
      expect(net.length, greaterThanOrEqualTo(5));
      expect(net, everyElement("totals['net']"));
    });

    test('the ladder card: Item total through itemTotalOf at the top, Gross from grand_total at the bottom', () {
      expect(src, contains("line(kItemTotal, itemTotalOf(ladder))"));
      expect(src, contains("line(kGross, ladder['grand_total'], prefix: '=', strong: true, rule: true)"));
      expect(src, isNot(contains("ladder['gross']")));
      expect(src, isNot(contains("totals['gross']")));
      expect(src, contains('discountPctOf(totals)'));
      expect(src, isNot(contains("totals['discount_pct_of_gross']")));
    });

    test('the Settlement Summary names its collected-less-refunds figure After refunds', () {
      expect(src, contains("_misStat(context, kAfterRefunds, _money(totals['net_amount'])"));
    });
  });

  group('Accounting headlines Net through readAccountingSales', () {
    final src = source('lib/screens/modules.dart');

    test('the NET SALES card and its sheet read the model, and never net_sales raw under "Net"', () {
      expect(src, contains('value: money(readAccountingSales(_sales).headlineValue ?? 0)'));
      expect(src, contains('caption: readAccountingSales(_sales).headlineLabel.toUpperCase()'));
      expect(src, isNot(contains("value: money(_n(_sales['net_sales']))")));
      expect(src, isNot(contains("caption: 'NET SALES'")));
      expect(src, isNot(contains("_detailRow(context, 'Net sales', _money(_sales['net_sales']))")));
      expect(src, isNot(contains("'Net sales (after refunds)'")));
    });

    test('the ex-tax revenue line and the by-method figures are not called net', () {
      expect(src, isNot(contains("'Net revenue (ex-tax)'")));
      expect(src, contains("'Revenue ex-tax (after refunds)'"));
      expect(src, isNot(contains("'Net of refunds'")));
      expect(src, isNot(contains("} net' : ''}")));
    });

    test('the PDF Sales block is the tested lines, and prints no Sales line of its own', () {
      expect(src, contains('for (final line in accountingSalesPdfLines(_sales)) kv(line.label, line.value, bold: line.bold)'));
      expect(src, isNot(contains("kv('Net sales'")));
      expect(src, isNot(contains("kv('Gross after refunds'")));
      expect(src, isNot(contains("kv('Gross sales', _sales")));
    });

    test('no discount note calls the bill totals "net of discount" — Net is a defined word, and those totals are Gross', () {
      expect(src.toLowerCase(), isNot(contains('net of discount')));
      expect(src, contains('Bill totals are already stored after discount'));
      expect(src, contains('Bill totals are stored after discount'));
    });
  });

  // The Reports drill-down reuses History's bill body; the flag is what makes it
  // say the report words. reports_module_test.dart reads the rendered sheet.
  group('the Reports drill-down speaks the report words', () {
    final modules = source('lib/screens/modules.dart');
    final reports = source('lib/screens/reports.dart');

    test('_misOpenBill asks for them, and the body maps each receipt word to its report word', () {
      expect(reports, contains('_closedBillBody(ctx, bill, title, reportWords: true)'));
      expect(modules, contains("money(reportWords ? kItemTotal : 'Items subtotal', _money(subtotal))"));
      expect(modules, contains("money(reportWords ? kNet : 'Taxable base', _money(taxable))"));
      expect(modules, contains("money(reportWords ? kGross : 'Grand total', _money(grand)"));
    });
  });
}
