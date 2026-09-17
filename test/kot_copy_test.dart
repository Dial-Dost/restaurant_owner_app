// THE LOCAL KOT COPY FOLLOWS THE REFERENCE DOCKET.
//
// The kitchen board's "Print KOT (local PDF copy)" prints one order as a PDF.
// It is not the kitchen docket (the backend draws that, escpos.ts layoutKot),
// but a chef should read the same thing off both: the same LINE ORDER, the same
// WEIGHTS, the same WORDS — no restaurant name; "KOT", the service mode, the
// table and each dish name bold; the quantity a plain number; "[Hold]" and
// nothing after it, upright; "[Note]" under the hold, a step SMALLER and
// SLANTED, as the thermal docket has set it since client item 5 — and the
// docket's type sizes.
//
// These pin [kotCopyRows] (what is on the paper, in order) and [kotCopyPdf]
// (that the PDF really carries those words, in the faces and sizes the docket
// uses, in the default font, on A4 and on a roll).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

import 'package:restaurant_owner_app/models/kot_copy.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;

/// The copy as text, one string per line, weight and alignment spelled out:
///   `C* KOT`         a centred bold line      `L  Table 5`  a left regular one
///   `1|Subz Tehri*|1`  a dish row (`*` = bold name)
///   `  [Hold]`       a line under a dish       `----`       a rule
///   ` /[Note] …`     a line under a dish set as a NOTE: smaller, slanted
List<String> paper(List<KotCopyRow> rows) => [
      for (final r in rows)
        switch (r.kind) {
          KotCopyKind.line => '${r.centred ? 'C' : 'L'}${r.bold ? '*' : ' '} ${r.text}',
          KotCopyKind.rule => '----',
          KotCopyKind.columns => '${r.no}|${r.text}${r.bold ? '*' : ''}|${r.qty}',
          KotCopyKind.under => '${r.note ? ' /' : '  '}${r.text}${r.bold ? '*' : ''}',
        },
    ];

/// Every word the PDF draws, with the face and the size it is drawn in — read
/// out of the uncompressed content stream (`BT /F9 8.15764 Tf … [(word)]TJ ET`)
/// and the font objects it names (`9 0 obj <</…/BaseFont/Helvetica-Oblique…`).
List<({String word, String face, double size})> pdfWords(String pdf) {
  final faces = <String, String>{
    for (final m in RegExp(r'(\d+) 0 obj\s*<<[^>]*?/BaseFont\s*/([\w-]+)').allMatches(pdf)) 'F${m.group(1)}': m.group(2)!,
  };
  return [
    for (final m in RegExp(r'BT /(F\d+) ([\d.]+) Tf [^\[]*\[\((.*?)\)\]TJ ET').allMatches(pdf))
      (word: m.group(3)!, face: faces[m.group(1)] ?? '?${m.group(1)}', size: double.parse(m.group(2)!)),
  ];
}

Map<String, dynamic> _item(String name, {int qty = 1, bool held = false, String note = '', String? variation}) => {
      'id': 'i-$name',
      'name': name,
      'quantity': qty,
      if (held) 'course_hold': true,
      'fired_at': null,
      if (note.isNotEmpty) 'note': note,
      'variation': ?variation,
    };

const _stamp = '16 Sep 2026, 14:13:05 IST';

/// The client's reference ticket, as one order on the kitchen board.
final Map<String, dynamic> _reference = {
  'id': 'ord-1',
  'table': '33',
  'order_type': 'dine_in',
  'status': 'Preparing',
  'items': [
    _item('Subz Tehri'),
    _item('Ghewar Berry Mousse'),
    _item('Gaia Rose Cookies', note: 'Hold Dessert'),
  ],
};

void main() {
  group('kotCopyRows — the lines, in the reference docket\'s order', () {
    test('the client\'s reference ticket', () {
      expect(paper(kotCopyRows(_reference, stamp: _stamp)), [
        'C  Local copy - no ticket number',
        'C* KOT',
        'C  $_stamp',
        'C* Dine In',
        'C* Table No: 33',
        '----',
        'No.Item||Qty',
        '1|Subz Tehri*|1',
        '2|Ghewar Berry Mousse*|1',
        '3|Gaia Rose Cookies*|1',
        ' /[Note] Hold Dessert',
        '----',
        'Total Qty||3',
        '----',
      ]);
    });

    test('a long name, a hold, a hold with a note, a size, and an order note', () {
      final order = {
        'table': '33',
        'order_type': 'dine_in',
        'note': 'Birthday table - no nuts anywhere',
        'items': [
          _item('Chargrilled Tandoori Broccoli Malai with Burnt Garlic', qty: 12),
          _item('Ghewar Berry Mousse', qty: 2, held: true),
          _item('Gaia Rose Cookies', held: true, note: 'Serve with the mains, no nuts'),
          _item('Paneer Tikka', qty: 3, variation: 'Half'),
        ],
      };
      expect(paper(kotCopyRows(order, stamp: _stamp)), [
        'C  Local copy - no ticket number',
        'C* KOT',
        'C  $_stamp',
        'C* Dine In',
        'C* Table No: 33',
        '----',
        'C* ** NOTE **',
        'L  Birthday table - no nuts anywhere',
        '----',
        'No.Item||Qty',
        '1|Chargrilled Tandoori Broccoli Malai with Burnt Garlic*|12',
        '2|Ghewar Berry Mousse*|2',
        '  [Hold]',
        '3|Gaia Rose Cookies*|1',
        '  [Hold]',
        ' /[Note] Serve with the mains, no nuts',
        '4|Paneer Tikka (Half)*|3',
        '----',
        'Total Qty||15',
        'Hold Qty||3',
        '----',
      ]);
    });

    test('the hold line is "[Hold]" and nothing else, upright; the note is the one note line; neither is bold', () {
      final rows = kotCopyRows({
        'table': '7',
        'items': [_item('Gulab Jamun', held: true, note: 'Dessert course')],
      }, stamp: _stamp);
      final under = rows.where((r) => r.kind == KotCopyKind.under).toList();
      expect(under.map((r) => r.text), ['[Hold]', '[Note] Dessert course']);
      expect(under.map((r) => r.note), [false, true]);
      expect(under.every((r) => !r.bold), isTrue);
      // Nothing but a dish's note is ever set as one.
      expect(rows.where((r) => r.note).map((r) => r.text), ['[Note] Dessert course']);
      final all = paper(rows).join('\n');
      expect(all, isNot(matches(RegExp('do not cook|until fired', caseSensitive: false))));
      // Everything held: no "Total Qty 0" over the hold total.
      expect(paper(rows).where((l) => l.contains('Qty||')), ['Hold Qty||1']);
    });

    test('a note that reads "[Hold]" is still a note, and an unheld dish\'s note is one too', () {
      final rows = kotCopyRows({
        'table': '7',
        'items': [_item('Naan', note: '[Hold]'), _item('Dal', held: true)],
      }, stamp: _stamp);
      expect(paper(rows).where((l) => l.startsWith(' /') || l.startsWith('  [')), [
        ' /[Note] [Hold]',
        '  [Hold]',
      ]);
    });

    test('no restaurant name, no "x" before a quantity, no dot leaders, no station line', () {
      final lines = paper(kotCopyRows({..._reference, 'restaurant_name': 'Gaia - Global Vegetarian'}, stamp: _stamp));
      expect(lines.join('\n'), isNot(contains('Gaia - Global')));
      for (final l in lines.where((l) => RegExp(r'^\d+\|').hasMatch(l))) {
        expect(l, matches(RegExp(r'\|\d+$')), reason: 'a bare number: $l');
      }
      expect(lines.join('\n'), isNot(contains('..')));
      expect(lines.join('\n'), isNot(contains('[ ')));
    });

    test('only the header block and the dish names are bold', () {
      final rows = kotCopyRows(_reference, stamp: _stamp);
      final bold = [
        for (final r in rows)
          if (r.bold) r.text,
      ];
      expect(bold, ['KOT', 'Dine In', 'Table No: 33', 'Subz Tehri', 'Ghewar Berry Mousse', 'Gaia Rose Cookies']);
    });

    test('a takeaway says so where "Dine In" goes; a missing table reads N/A', () {
      final lines = paper(kotCopyRows({'order_type': 'takeaway', 'items': [_item('Naan')]}, stamp: _stamp));
      expect(lines[3], 'C* Takeaway');
      expect(lines[4], 'C* Table No: N/A');
      final nulls = paper(kotCopyRows({'table': null, 'note': null, 'order_type': null, 'items': null}, stamp: ''));
      expect(nulls.take(4), ['C  Local copy - no ticket number', 'C* KOT', 'C* Dine In', 'C* Table No: N/A'],
          reason: 'no blank stamp line, no "null" anywhere');
      expect(nulls.join('\n'), isNot(contains('null')));
      // An empty ticket still totals — the docket's own rule.
      expect(nulls.where((l) => l.contains('Qty||')), ['Total Qty||0']);
    });

    test('the service mode speaks the docket\'s words (kot_numbers.ts serviceModeLabel)', () {
      const cases = {
        null: 'Dine In',
        '': 'Dine In',
        'dine_in': 'Dine In',
        'Dine In': 'Dine In',
        'dine-in': 'Dine In',
        'dinein': 'Dine In',
        'takeaway': 'Takeaway',
        'take away': 'Takeaway',
        'pickup': 'Takeaway',
        'parcel': 'Takeaway',
        'delivery': 'Delivery',
        'swiggy': 'Delivery (Swiggy)',
        'zomato': 'Delivery (Zomato)',
        'room_service': 'Room Service',
      };
      cases.forEach((input, want) => expect(kotServiceModeLabel(input), want, reason: '$input'));
    });

    test('a fired course is not held, and a quantity below one prints as one', () {
      final rows = kotCopyRows({
        'table': '2',
        'items': [
          {'name': 'Gulab Jamun', 'quantity': 0, 'course_hold': true, 'fired_at': '2026-09-16T12:00:00Z'},
        ],
      }, stamp: _stamp);
      expect(paper(rows).where((l) => l.startsWith('1|') || l.startsWith('  ') || l.contains('Qty||')),
          ['1|Gulab Jamun*|1', 'Total Qty||1']);
    });
  });

  group('kotCopyPdf — the PDF carries those words', () {
    // Uncompressed, the page's content stream holds each word as a PDF string.
    Future<String> pdfText(List<KotCopyRow> rows, [PdfPageFormat format = PdfPageFormat.a4]) async {
      final bytes = await m.kotCopyPdf(rows, pageFormat: format, compress: false).save();
      return latin1.decode(bytes);
    }

    test('the hold is "[Hold]" on paper, and the sentence after it is gone', () async {
      final rows = kotCopyRows({
        'table': '33',
        'items': [_item('Gulab Jamun', held: true, note: 'Dessert course')],
      }, stamp: _stamp);
      final pdf = await pdfText(rows);
      expect(pdf, contains('[Hold]'));
      expect(pdf, contains('[Note]'));
      expect(pdf, contains('Jamun'));
      expect(pdf, contains('KOT'));
      expect(pdf, isNot(contains(RegExp('cook|fired', caseSensitive: false))));
      // The default font, in its regular and bold faces, and the slanted one
      // for the note.
      expect(pdf, contains('/Helvetica'));
      expect(pdf, contains('/Helvetica-Bold'));
      expect(pdf, contains('/Helvetica-Oblique'));
      expect(pdf, isNot(contains('Gaia - Global')));
    });

    test('THE NOTE IS SMALLER AND SLANTED, AS ON THE DOCKET; [Hold] and the dish stay upright at the body size',
        () async {
      final rows = kotCopyRows({
        'table': '33',
        'items': [_item('Gulab Jamun', held: true, note: 'Dessert course')],
      }, stamp: _stamp);
      final words = pdfWords(await pdfText(rows));
      ({String face, double size}) of(String word) {
        final hit = words.where((w) => w.word == word).toList();
        expect(hit, hasLength(1), reason: '"$word" drawn once, in: $words');
        return (face: hit.single.face, size: hit.single.size);
      }

      const body = 27 * 72 / 203;
      const note = 23 * 72 / 203;
      for (final w in ['[Note]', 'Dessert', 'course']) {
        expect(of(w).face, 'Helvetica-Oblique', reason: w);
        expect(of(w).size, closeTo(note, 0.001), reason: w);
      }
      expect(of('[Hold]').face, 'Helvetica');
      expect(of('[Hold]').size, closeTo(body, 0.001));
      for (final w in ['Gulab', 'Jamun', 'KOT']) {
        expect(of(w).face, 'Helvetica-Bold', reason: w);
        expect(of(w).size, closeTo(body, 0.001), reason: w);
      }
      // Every word is one of the docket's two sizes, and only the note's
      // words are slanted.
      expect(words.map((w) => w.size.toStringAsFixed(3)).toSet(), {body.toStringAsFixed(3), note.toStringAsFixed(3)});
      expect(words.where((w) => w.face == 'Helvetica-Oblique').map((w) => w.word), ['[Note]', 'Dessert', 'course']);
    });

    test('an order with no dish note sets nothing slanted', () async {
      final rows = kotCopyRows({
        'table': '33',
        'note': 'No onions for the whole table',
        'items': [_item('Gulab Jamun', held: true)],
      }, stamp: _stamp);
      final pdf = await pdfText(rows);
      expect(pdf, contains('onions'), reason: 'the ORDER note is a plain line');
      expect(pdf, isNot(contains('Oblique')));
      expect(pdfWords(pdf).map((w) => w.face).toSet(), {'Helvetica', 'Helvetica-Bold'});
    });

    test('the sizes are the kitchen docket\'s: 27 dots per em, the note 0.87 of it, at 203 dpi', () {
      // escpos.ts KOT_BODY_PPEM['80mm'].standard and KOT_NOTE_SCALE, rounded to
      // the whole dots the glyph atlas is baked at.
      expect(kotDocketBodyDots, 27);
      expect(kotDocketNoteDots, (27 * 0.87).round());
      expect(kotPrinterDpi, 203);
      expect(kotCopyBodyPt, closeTo(9.576, 0.001));
      expect(kotCopyNotePt, closeTo(8.158, 0.001));
    });

    test('prints on a roll as well as on A4', () async {
      final rows = kotCopyRows(_reference, stamp: _stamp);
      for (final format in [PdfPageFormat.a4, PdfPageFormat.roll80, PdfPageFormat.roll57]) {
        final pdf = await pdfText(rows, format);
        expect(pdf, startsWith('%PDF'));
        expect(pdf, contains('Tehri'));
      }
    });
  });
}
