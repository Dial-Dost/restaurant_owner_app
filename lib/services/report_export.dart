/// MIS / CONTROL REPORT RENDERING AND EXPORT.
///
/// The nine reports under Insights → Reports are fraud-control documents. Two
/// consequences shape this whole file:
///
///   1. ONE FORMATTER, FOUR SURFACES. `misText` is the only place a report cell
///      becomes a string. The grid on screen, the CSV, the Excel sheet and the
///      PDF all go through it, so the figure an owner reads on the laptop is
///      character-for-character the figure in the file they email their
///      accountant. A second formatter written "just for the export" is exactly
///      how two copies of one report end up disagreeing.
///
///   2. THE EXPORT CARRIES ITS OWN BASIS. Every file starts with the report
///      name, the window, the timezone the window was cut in, the outlet scope,
///      the moment it was generated and EVERY caveat the server attached
///      (`meta.notes` — "bills are counted on the day they were settled",
///      "category is matched by name", "no before/after amounts exist"). A
///      spreadsheet that leaves the building without those lines is a number
///      with no provenance, and the first person to reconcile it against
///      something else has no way to find out why they differ.
///
/// NUMBERS GO INTO A SPREADSHEET AS NUMBERS. In CSV and XLSX a money, percent
/// or int cell is written RAW — `1234.56`, not `₹1,234.56` — because the first
/// thing anyone does with a discount column is sum it, and a currency-prefixed
/// string sums to zero. The PDF and the screen get the formatted string,
/// because those are read, not calculated. This is the one deliberate
/// divergence from "identical everywhere", and it is why `misText` takes
/// [forSheet].
///
/// READ-ONLY. Nothing here writes to the server, and nothing here touches the
/// offline outbox: the reports are GETs, they flow through the ordinary read
/// cache, and an export is rendered from a payload that is already in memory.
library;

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'restaurant_time.dart';

// ----------------------------------------------------------------- columns --

/// One column of a MIS report, exactly as the server describes it.
///
/// The descriptor is SERVER-DRIVEN on purpose: `columns` is what drives the
/// column picker, the grid, the TOTALS row and all three exports, so a column
/// the backend adds or renames arrives here without a client change, and a
/// column the backend does NOT sum can never be summed by the client.
class MisColumn {
  const MisColumn({
    required this.key,
    required this.label,
    required this.type,
    this.total = false,
    this.defaultOn = true,
  });

  final String key;
  final String label;

  /// "text" | "int" | "money" | "percent" | "datetime" | "date".
  final String type;

  /// True when the server sums this column into the TOTALS row. The client
  /// never decides this for itself — summing a column the server left out
  /// (an average, a percentage, a party size) invents a number.
  final bool total;

  /// False for columns hidden until the user turns them on.
  final bool defaultOn;

  bool get isNumeric => type == 'int' || type == 'money' || type == 'percent';

  static MisColumn fromJson(Map<dynamic, dynamic> j) => MisColumn(
        key: '${j['key'] ?? ''}',
        label: '${j['label'] ?? j['key'] ?? ''}',
        type: '${j['type'] ?? 'text'}',
        total: j['total'] == true,
        // Absent means on. Only an explicit `false` hides a column by default.
        defaultOn: j['default_on'] != false,
      );

  static List<MisColumn> listOf(dynamic raw) => [
        for (final c in (raw as List?) ?? const [])
          if (c is Map) MisColumn.fromJson(c),
      ];
}

// -------------------------------------------------------------- formatting --

double? misNum(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// `12.3%`, or `—` when the server sent null. Null here always means "there is
/// no honest percentage" (growth from a base of zero, a per-cover figure for a
/// bill with no resolvable seating), never zero.
String misPercent(Object? v) {
  final n = misNum(v);
  return n == null ? '—' : '${n.toStringAsFixed(1)}%';
}

/// THE cell formatter. See the library header: the grid, the CSV, the sheet and
/// the PDF all come through here.
///
/// [forSheet] switches money/percent/int to their raw numeric text so a
/// spreadsheet can add the column up. [forPdf] swaps `₹` for `Rs ` because the
/// PDF package's built-in Helvetica has no rupee glyph and would silently emit
/// a blank where the currency should be — the same substitution the accounting
/// PDF export already makes.
String misText(MisColumn c, Object? v, {bool forSheet = false, bool forPdf = false}) {
  switch (c.type) {
    case 'money':
      final n = misNum(v);
      if (n == null) return forSheet ? '' : '—';
      if (forSheet) return n.toStringAsFixed(2);
      return forPdf ? 'Rs ${n.toStringAsFixed(2)}' : '₹${n.toStringAsFixed(2)}';
    case 'percent':
      final n = misNum(v);
      if (n == null) return forSheet ? '' : '—';
      return forSheet ? n.toStringAsFixed(2) : '${n.toStringAsFixed(1)}%';
    case 'int':
      final n = misNum(v);
      if (n == null) return forSheet ? '' : '—';
      // Round for display; the server already rounds, this only stops a float
      // artefact rendering "12.000000000000002" in a Qty column.
      return n.round().toString();
    case 'datetime':
      final s = '${v ?? ''}'.trim();
      if (s.isEmpty) return forSheet ? '' : '—';
      // Sheets get the raw ISO instant: it sorts correctly and can be parsed
      // back. Screens get the restaurant's own wall clock.
      return forSheet ? s : RestaurantTime.short(s);
    case 'date':
      final s = '${v ?? ''}'.trim();
      if (s.isEmpty) return forSheet ? '' : '—';
      return forSheet ? s : RestaurantTime.day(s);
    default:
      final s = '${v ?? ''}'.trim();
      if (s.isEmpty || s == 'null') return forSheet ? '' : '—';
      return s;
  }
}

// -------------------------------------------------------------- the payload --

/// Everything one rendered report is: its identity, the rows on the page, the
/// WINDOW's totals (never the page's) and the caveats the server attached.
class MisReportDoc {
  const MisReportDoc({
    required this.title,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.from,
    required this.to,
    required this.timezone,
    required this.outletLabel,
    required this.notes,
    this.truncatedAt,
  });

  final String title;

  /// Only the columns the reader has switched ON. The export is the document
  /// they are looking at, not a different one.
  final List<MisColumn> columns;
  final List<Map<String, dynamic>> rows;

  /// The window's totals, keyed by column. Null for reports the server gives no
  /// totals row (there are none today, but the shape must not assume).
  final Map<String, dynamic>? totals;

  final String from;
  final String to;
  final String timezone;
  final String outletLabel;
  final List<String> notes;

  /// Set when the export could not fetch every row the window holds, so the
  /// file says so on its own face instead of quietly being short.
  final int? truncatedAt;

  /// Filename stem — report, scope and window, so two exports of the same
  /// report cannot be confused once they are sitting in a Downloads folder.
  String get fileStem =>
      '${_slug(title)}_${_slug(outletLabel)}_${from}_to_$to';

  static String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+'), '')
      .replaceAll(RegExp(r'-+$'), '');

  /// The provenance block every export opens with.
  List<List<String>> get preamble => [
        ['Report', title],
        ['Outlet', outletLabel],
        ['Period', '$from to $to (both days included)'],
        ['Timezone', timezone],
        ['Generated', RestaurantTime.stampNow()],
        ['Rows', truncatedAt == null ? '${rows.length}' : '${rows.length} (truncated at $truncatedAt)'],
      ];
}

// -------------------------------------------------------------------- CSV ----

String _csvCell(Object? v) {
  final s = '${v ?? ''}';
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _csvRow(List<Object?> cells) => '${cells.map(_csvCell).join(',')}\r\n';

/// CSV: preamble, notes, a blank line, the header, the rows, the TOTALS row.
///
/// CRLF and no BOM, matching the app's existing exports (`_downloadCsv`, the
/// Tally XML, the scheduled-report download) so every file this product emits
/// opens the same way.
String misCsv(MisReportDoc doc) {
  final b = StringBuffer();
  for (final line in doc.preamble) {
    b.write(_csvRow(line));
  }
  if (doc.notes.isNotEmpty) {
    b.write(_csvRow(const ['']));
    b.write(_csvRow(const ['How these numbers are counted']));
    for (final n in doc.notes) {
      b.write(_csvRow(['', n]));
    }
  }
  b.write(_csvRow(const ['']));
  b.write(_csvRow([for (final c in doc.columns) c.label]));
  for (final r in doc.rows) {
    b.write(_csvRow([for (final c in doc.columns) misText(c, r[c.key], forSheet: true)]));
  }
  final t = doc.totals;
  if (t != null) {
    b.write(_csvRow([
      for (var i = 0; i < doc.columns.length; i++)
        i == 0
            ? 'TOTAL (whole period)'
            // Only the columns the SERVER marks summable carry a total. An
            // average or a share has no meaningful column sum, and printing one
            // would be a number nobody could reproduce.
            : (doc.columns[i].total ? misText(doc.columns[i], t[doc.columns[i].key], forSheet: true) : ''),
    ]));
  }
  return b.toString();
}

// ------------------------------------------------------------------ Excel ----

/// XLSX with the same content as the CSV, but typed: money/percent/int land as
/// real numbers so the column sums, filters and charts in the sheet.
Uint8List misXlsx(MisReportDoc doc) {
  final book = xl.Excel.createExcel();
  // `rename` is a silent no-op when its preconditions do not hold, so the sheet
  // is resolved AFTER the attempt rather than assumed — otherwise `book['Report']`
  // would quietly create a second, empty tab and the data would sit in the one
  // nobody opens.
  final original = book.sheets.keys.first;
  book.rename(original, 'Report');
  final sheetName = book.sheets.containsKey('Report') ? 'Report' : original;
  final sheet = book[sheetName];

  for (final line in doc.preamble) {
    sheet.appendRow([for (final c in line) xl.TextCellValue(c)]);
  }
  if (doc.notes.isNotEmpty) {
    sheet.appendRow([xl.TextCellValue('')]);
    sheet.appendRow([xl.TextCellValue('How these numbers are counted')]);
    for (final n in doc.notes) {
      sheet.appendRow([xl.TextCellValue(''), xl.TextCellValue(n)]);
    }
  }
  sheet.appendRow([xl.TextCellValue('')]);
  sheet.appendRow([for (final c in doc.columns) xl.TextCellValue(c.label)]);

  xl.CellValue cell(MisColumn c, Object? v) {
    if (c.isNumeric) {
      final n = misNum(v);
      if (n == null) return xl.TextCellValue('');
      if (c.type == 'int') return xl.IntCellValue(n.round());
      return xl.DoubleCellValue(double.parse(n.toStringAsFixed(2)));
    }
    return xl.TextCellValue(misText(c, v, forSheet: true));
  }

  for (final r in doc.rows) {
    sheet.appendRow([for (final c in doc.columns) cell(c, r[c.key])]);
  }
  final t = doc.totals;
  if (t != null) {
    sheet.appendRow([
      for (var i = 0; i < doc.columns.length; i++)
        i == 0
            ? xl.TextCellValue('TOTAL (whole period)')
            : (doc.columns[i].total
                ? cell(doc.columns[i], t[doc.columns[i].key])
                : xl.TextCellValue('')),
    ]);
  }

  final bytes = book.encode();
  return Uint8List.fromList(bytes ?? const <int>[]);
}

// -------------------------------------------------------------------- PDF ----

/// Everything in the PDF goes through here first.
///
/// The pdf package's built-in Helvetica is a Latin-1 face with no Unicode
/// coverage: a rupee sign, an em dash or a curly quote does not render as the
/// wrong glyph, it renders as NOTHING, so a money column would silently lose
/// its currency and a blank cell would lose its dash. There is no Unicode font
/// bundled with this app to fall back on, so the substitution is made here,
/// once, and every string on the page is folded — cells, headers, notes and the
/// title alike. (`misText(forPdf: true)` already writes `Rs ` for money; this
/// catches everything else, including whatever wording the server puts in
/// `meta.notes`.)
String pdfSafe(String s) => s
    .replaceAll('₹', 'Rs ')
    .replaceAll('—', '-')
    .replaceAll('–', '-')
    .replaceAll('→', '->')
    .replaceAll('·', '-')
    .replaceAll('‘', "'")
    .replaceAll('’', "'")
    .replaceAll('“', '"')
    .replaceAll('”', '"')
    .replaceAll('…', '...')
    // Anything still outside Latin-1 would print as a hole; a visible marker is
    // better than a number that quietly lost a character.
    .replaceAll(RegExp(r'[^\u0000-\u00FF]'), '?');

/// PDF: the filed copy. Landscape, because these tables are wide, and every
/// page repeats the header row so a number on page four still has a column
/// name over it.
Future<Uint8List> misPdf(MisReportDoc doc) async {
  final pdf = pw.Document();
  final headers = [for (final c in doc.columns) pdfSafe(c.label)];
  final data = [
    for (final r in doc.rows)
      [for (final c in doc.columns) pdfSafe(misText(c, r[c.key], forPdf: true))],
  ];
  final t = doc.totals;
  if (t != null) {
    data.add([
      for (var i = 0; i < doc.columns.length; i++)
        i == 0
            ? 'TOTAL (whole period)'
            : (doc.columns[i].total
                ? pdfSafe(misText(doc.columns[i], t[doc.columns[i].key], forPdf: true))
                : ''),
    ]);
  }

  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(22),
    build: (ctx) => [
      pw.Text(pdfSafe(doc.title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      for (final line in doc.preamble)
        pw.Text(pdfSafe('${line[0]}: ${line[1]}'), style: const pw.TextStyle(fontSize: 8)),
      pw.SizedBox(height: 10),
      if (data.isEmpty)
        pw.Text('No rows in this period.', style: const pw.TextStyle(fontSize: 10))
      else
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: data,
          headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 7.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          cellAlignments: {
            for (var i = 0; i < doc.columns.length; i++)
              i: doc.columns[i].isNumeric ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
          },
        ),
      if (doc.notes.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        pw.Text('How these numbers are counted',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 3),
        for (final n in doc.notes)
          pw.Bullet(text: pdfSafe(n), style: const pw.TextStyle(fontSize: 7.5)),
      ],
    ],
  ));
  return pdf.save();
}

// --------------------------------------------------------------- delivery ----

enum ReportFormat { csv, excel, pdf }

extension ReportFormatX on ReportFormat {
  String get ext => switch (this) {
        ReportFormat.csv => 'csv',
        ReportFormat.excel => 'xlsx',
        ReportFormat.pdf => 'pdf',
      };

  String get label => switch (this) {
        ReportFormat.csv => 'CSV',
        ReportFormat.excel => 'Excel',
        ReportFormat.pdf => 'PDF',
      };
}

/// What happened to an export, in words the UI can show verbatim.
class ReportExportResult {
  const ReportExportResult(this.message, {this.ok = true});
  final String message;
  final bool ok;
}

/// Renders and hands over one report.
///
/// DESKTOP AND PHONE ARE DELIBERATELY DIFFERENT, because "export" means
/// different things on the two:
///
///   * DESKTOP (Windows/macOS/Linux) — a native Save dialog, so the file lands
///     at a path the owner chose and the confirmation NAMES that path. An
///     accountant asked for "the discount report" wants a file in a folder, not
///     a share sheet.
///
///   * PHONE — the file is handed to the platform. A PDF goes through the real
///     share sheet (`Printing.sharePdf`, which is the only share the app's
///     dependency set actually provides). CSV and XLSX are written first
///     (`FilePicker.saveFile` on mobile writes the bytes and returns the path)
///     and then opened with `OpenFilex`, which is Android's hand-off to whatever
///     can read a spreadsheet — and when nothing can, the message names the file
///     instead of pretending it went somewhere.
///
/// [overrideDeliver] is the test seam: a widget test must not open a native file
/// dialog, and the export path is worth asserting without one.
class ReportExporter {
  /// Set by tests. Receives the rendered bytes and the filename and returns the
  /// message the caller would have shown.
  static Future<ReportExportResult> Function(Uint8List bytes, String filename, ReportFormat format)?
      overrideDeliver;

  /// True on a phone-shaped platform. Overridable so a test can exercise the
  /// share branch on a desktop test host.
  static bool? overrideIsMobile;

  static bool get isMobile =>
      overrideIsMobile ?? (Platform.isAndroid || Platform.isIOS);

  static Future<Uint8List> render(MisReportDoc doc, ReportFormat format) async {
    switch (format) {
      case ReportFormat.csv:
        return Uint8List.fromList(utf8.encode(misCsv(doc)));
      case ReportFormat.excel:
        return misXlsx(doc);
      case ReportFormat.pdf:
        return misPdf(doc);
    }
  }

  static Future<ReportExportResult> export(MisReportDoc doc, ReportFormat format) async {
    final filename = '${doc.fileStem}.${format.ext}';
    final Uint8List bytes;
    try {
      bytes = await render(doc, format);
    } catch (e) {
      return ReportExportResult('Could not build the ${format.label}: $e', ok: false);
    }
    return deliver(bytes, filename, format);
  }

  static Future<ReportExportResult> deliver(
      Uint8List bytes, String filename, ReportFormat format) async {
    final hook = overrideDeliver;
    if (hook != null) return hook(bytes, filename, format);
    try {
      if (isMobile) {
        if (format == ReportFormat.pdf) {
          await Printing.sharePdf(bytes: bytes, filename: filename);
          return ReportExportResult('Shared $filename.');
        }
        final path = await FilePicker.saveFile(
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: [format.ext],
          bytes: bytes,
        );
        if (path == null) return const ReportExportResult('Export cancelled.', ok: false);
        final opened = await OpenFilex.open(path);
        if (opened.type == ResultType.done) {
          return ReportExportResult('Shared $filename.');
        }
        // Honest fallback: the file exists, nothing on this phone opens it.
        return ReportExportResult('Saved $filename to $path — no app on this phone opens ${format.label} files.');
      }
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save $filename',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [format.ext],
        bytes: bytes,
      );
      if (path == null) return const ReportExportResult('Export cancelled.', ok: false);
      return ReportExportResult('Saved to $path');
    } catch (e) {
      return ReportExportResult('Could not save the ${format.label}: $e', ok: false);
    }
  }
}
