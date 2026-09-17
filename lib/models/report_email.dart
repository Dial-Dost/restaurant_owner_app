// EMAIL REPORTS — the app's half of client item 9.
//
// "In the reports section, all reports or any reports can be emailed to chosen
// email IDs, automated so emails are sent at the end of each day at a specific
// time to the chosen email IDs, with an option to choose/add both the email IDs
// and the send time."
//
// Everything the Email reports area and the Send-now sheet DECIDE, by value:
// which reports may be read on which kind of day, the exact body Send now
// posts (never a session filter, one request id per SEND — a retry of the
// same choices reuses it, anything else gets a new one), what each delivery
// state and each address outcome is called, what a schedule's next run covers.
// The screens (screens/report_email.dart) only lay these out.
//
// THE SERVER DECIDES, THIS FILE OBEYS. Whether this deployment can send mail,
// whether the scheduler runs, who may edit the address book and who may pick
// "all outlets" come from GET /reports/email/config. A missing answer is "we
// could not ask", never "no".
//
// THE SAME WORDS AS THE WEB DASHBOARD (src/lib/report-email.ts); its test reads
// this file when the two checkouts sit side by side, and ours reads it back.
//
// ONLINE ONLY. None of these writes is on the outbox allowlist
// (services/outbox.dart): an email that went out while the app thought it was
// queued, and then went out again on replay, is exactly the double-apply the
// allowlist exists to prevent. Offline, the write is refused with
// OutboxPolicy.unsupported, and the sheet says so.
//
// PURE: no Flutter, no network. Same discipline as nc_settle.dart.

import 'dart:convert';
import 'dart:math' as math;

// --- The catalogue ------------------------------------------------------------

/// One report that can be emailed.
class EmailableReport {
  const EmailableReport(this.key, this.title, this.family, {this.tradingDay = true});
  final String key;
  final String title;

  /// 'mis' (an Insights → Reports tab) or 'accounting'.
  final String family;

  /// Whether it may be read on a trading day. GST and P&L may not.
  final bool tradingDay;

  List<String> get windowModes => tradingDay ? const ['calendar', 'trading_day'] : const ['calendar'];
}

/// The eighteen, in the backend's order (report_catalogue.ts): the fifteen tabs,
/// then Sales, GST and P&L. The config's own list replaces it when it answers.
const List<EmailableReport> kEmailableReports = [
  EmailableReport('item_wise', 'Item Wise', 'mis'),
  EmailableReport('discount', 'Discount', 'mis'),
  EmailableReport('void_kot', 'Void KOT', 'mis'),
  EmailableReport('bill_edit', 'Bill Edit', 'mis'),
  EmailableReport('sales_summary', 'Sales Summary', 'mis'),
  EmailableReport('order_summary', 'Order Summary', 'mis'),
  EmailableReport('executive_summary', 'Executive Summary', 'mis'),
  EmailableReport('cover_size_summary', 'Cover Size Summary', 'mis'),
  EmailableReport('settlement_summary', 'Settlement Summary', 'mis'),
  EmailableReport('nc_summary', 'NC Summary', 'mis'),
  EmailableReport('service_charge_deny', 'Service Charge Deny', 'mis'),
  EmailableReport('group_summary', 'Group Summary', 'mis'),
  EmailableReport('variation_summary', 'Variation Summary', 'mis'),
  EmailableReport('tip_summary', 'Tip Summary', 'mis'),
  EmailableReport('counter_summary', 'Counter Summary', 'mis'),
  EmailableReport('sales', 'Sales (accounting)', 'accounting'),
  EmailableReport('gst', 'GST', 'accounting', tradingDay: false),
  EmailableReport('pnl', 'Profit & Loss', 'accounting', tradingDay: false),
];

final List<String> kMisEmailKeys = [for (final r in kEmailableReports) if (r.family == 'mis') r.key];
final List<String> kCalendarOnlyKeys = [for (final r in kEmailableReports) if (!r.tradingDay) r.key];

const int kMaxRecipientsPerSend = 10;
const int kMaxAddressBook = 25;

// --- The words (the web's, word for word) ---------------------------------------

const String kEmailAreaTitle = 'Email reports';
const String kEmailButtonLabel = 'Email';
const String kEmailButtonTooltip = 'Email this report';
const String kMailOffSentence = 'Email is not set up on this server';
const String kMailOffHint = 'Ask your administrator to set up the mail settings. Reports can still be downloaded here.';
const String kSchemaPendingSentence = 'Email reports need a database update that has not been applied to this server yet.';
const String kSchedulerOffSentence = 'Scheduled emails are switched off on this server. Send now still works.';
const String kSendNowOffSentence = 'Sending reports on demand is switched off on this server.';
const String kTestEmailLabel = 'Send test email';
const String kAddressBookTitle = 'Address book';
const String kAddressBookEmpty = 'No addresses yet. Reports can only be emailed to addresses in this list.';
const String kAddressBookReadOnly = 'Only someone with the Settings permission can add or remove addresses.';
const String kWholeDaysNote = 'Emailed reports always cover whole days — the session filter on screen is not applied.';
const String kCalendarDaysOnly = 'Calendar days only';
const String kAllMisReports = 'All 15 MIS reports';
const Map<String, String> kFormatLabels = {
  'xlsx': 'Excel workbook (.xlsx)',
  'csv': 'CSV (one file per report)',
};
const Map<String, String> kWindowModeLabels = {
  'trading_day': 'The day that just ended',
  'calendar': 'Previous calendar day',
};
const Map<String, String> kRecipientOutcomeLabels = {
  'sent': 'Sent',
  'refused': 'Refused',
  'skipped': 'Skipped',
  'waiting': 'Waiting',
};

// --- Selection --------------------------------------------------------------------

String reportTitle(String key) {
  for (final r in kEmailableReports) {
    if (r.key == key) return r.title;
  }
  return key;
}

/// The chosen keys in catalogue order, de-duplicated, unknown ones dropped.
List<String> orderedReportKeys(Iterable<String> keys) {
  final wanted = keys.toSet();
  return [for (final r in kEmailableReports) if (wanted.contains(r.key)) r.key];
}

/// "Sales Summary and Void KOT", "All 15 MIS reports", "Item Wise, Discount and 2 more".
/// Up to [max] titles are all named, the last joined with "and": three under
/// max 3 once ran together as "Item WiseDiscountVoid KOT".
String reportListPhrase(List<String> keys, {int max = 2}) {
  final titles = [for (final k in keys) reportTitle(k)];
  if (titles.isEmpty) return 'No reports';
  if (titles.length == kEmailableReports.length) return 'All reports';
  if (titles.length == kMisEmailKeys.length && keys.every(kMisEmailKeys.contains)) return kAllMisReports;
  if (titles.length <= max) {
    return titles.length == 1 ? titles.first : '${titles.sublist(0, titles.length - 1).join(', ')} and ${titles.last}';
  }
  return '${titles.take(max).join(', ')} and ${titles.length - max} more';
}

/// The server's own refusal, before the request.
String? selectionProblem(List<String> keys, String mode) {
  final ordered = orderedReportKeys(keys);
  if (ordered.isEmpty) return 'Pick at least one report to send.';
  if (mode == 'trading_day') {
    final blocked = [for (final k in kCalendarOnlyKeys) if (ordered.contains(k)) k];
    if (blocked.isNotEmpty) {
      final names = blocked.map(reportTitle).join(' and ');
      return '$names can only be sent for calendar days. Choose "previous calendar day", or leave ${blocked.length > 1 ? 'them' : 'it'} out.';
    }
  }
  return null;
}

/// Why a report cannot be ticked for this kind of day, or null.
String? reportDisabledReason(String key, String mode) =>
    mode == 'trading_day' && kCalendarOnlyKeys.contains(key) ? kCalendarDaysOnly : null;

/// Formats in the server's order.
List<String> orderedFormats(Iterable<String> formats) {
  final wanted = formats.toSet();
  return [for (final f in const ['xlsx', 'csv']) if (wanted.contains(f)) f];
}

/// A new daily schedule closes at its send time unless it carries GST or P&L.
String defaultWindowMode(String frequency, List<String> keys) =>
    frequency == 'daily' && !keys.any(kCalendarOnlyKeys.contains) ? 'trading_day' : 'calendar';

// --- Time -------------------------------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');
String hhmm(int hour, int minute) => '${_two(hour)}:${_two(minute)}';

/// "HH:mm" → minutes, or null. 24:00 is not a send time.
int? parseTime(String value) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

const List<String> _weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _monthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const List<String> _weekdayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/// "Wed 16 Sep".
String shortDay(String key) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key);
  if (m == null) return key;
  final d = DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  return '${_weekdaysShort[d.weekday - 1]} ${d.day} ${_monthsShort[d.month - 1]}';
}

/// "17 Sep" or "1 Sep – 15 Sep".
String periodPhrase(String from, String to) {
  if (from == to) return shortDay(from);
  String dm(String k) => shortDay(k).split(' ').skip(1).join(' ');
  return '${dm(from)} – ${dm(to)}';
}

/// An instant on the restaurant's wall clock: "18 Sep, 02:00". [wallOf] is
/// RestaurantTime.wallOf in the app; injected so this file stays pure.
String wallClock(String? iso, DateTime? Function(String iso) wallOf) {
  if (iso == null || iso.isEmpty) return '';
  final d = wallOf(iso);
  if (d == null) return iso;
  return '${d.day} ${_monthsShort[d.month - 1]}, ${_two(d.hour)}:${_two(d.minute)}';
}

/// What one run of a schedule covers.
String coverageCaption(String frequency, String mode, String time) {
  if (frequency == 'weekly') return 'Covers the seven restaurant days ending the day before it runs.';
  if (frequency == 'monthly') return 'Covers the whole previous calendar month.';
  if (mode == 'trading_day') {
    final at = parseTime(time) == null ? 'the send time' : time;
    return 'Covers the 24 hours up to $at — the trading day that just closed, so bills settled after midnight count on the day they belong to.';
  }
  return 'Covers the previous calendar day, midnight to midnight.';
}

/// "Every day at 02:00 · the day that just ended", "Every Monday at 08:05".
String cadenceCaption(Map s) {
  final at = hhmm(_int(s['hour_local']) ?? 0, _int(s['minute_local']) ?? 0);
  final frequency = '${s['frequency'] ?? 'daily'}';
  if (frequency == 'weekly') {
    final wd = _int(s['weekday']) ?? 0;
    return 'Every ${wd >= 0 && wd < 7 ? _weekdayNames[wd] : 'week'} at $at';
  }
  if (frequency == 'monthly') return 'On day ${_int(s['day_of_month']) ?? 1} of each month at $at';
  final mode = s['window_mode'] == 'trading_day' ? 'trading_day' : 'calendar';
  return 'Every day at $at · ${kWindowModeLabels[mode]!.toLowerCase()}';
}

/// "Next: 18 Sep, 02:00 — covers 17 Sep, 02:00 → 18 Sep, 02:00". Empty for a
/// paused schedule: its chip already says so, and it has no next run.
String nextRunCaption(Map s, DateTime? Function(String iso) wallOf) {
  if (s['enabled'] == false) return '';
  final at = '${s['next_run_at'] ?? ''}';
  if (at.isEmpty || at == 'null') return '';
  final next = 'Next: ${wallClock(at, wallOf)}';
  final w = s['next_window'];
  if (w is! Map) return next;
  final close = w['day_close'];
  if (close != null && '$close'.isNotEmpty) {
    return '$next — covers ${wallClock('${w['start_at']}', wallOf)} → ${wallClock('${w['end_at']}', wallOf)}';
  }
  return '$next — covers ${periodPhrase('${w['from']}', '${w['to']}')}';
}

int? _int(Object? v) => num.tryParse('${v ?? ''}')?.round();

// --- The config -------------------------------------------------------------------

/// What this server can do, as GET /reports/email/config says.
class ReportEmailConfig {
  const ReportEmailConfig({
    required this.emailAvailable,
    required this.reason,
    required this.schemaReady,
    required this.sendNowEnabled,
    required this.schedulerEnabled,
    required this.recipientsPerSend,
    required this.addressBookMax,
    required this.formats,
    required this.reports,
    required this.canEditRecipients,
    required this.canUseAllOutlets,
  });

  final bool emailAvailable;
  final String? reason;
  final bool schemaReady;
  final bool sendNowEnabled;
  final bool schedulerEnabled;
  final int recipientsPerSend;
  final int addressBookMax;
  final List<String> formats;
  final List<EmailableReport> reports;
  final bool canEditRecipients;
  final bool canUseAllOutlets;

  /// Null when the answer is unreadable (a 2.0.1 server has no such route).
  static ReportEmailConfig? fromJson(Object? raw) {
    if (raw is! Map || raw['email_available'] is! bool) return null;
    final sched = raw['scheduler'] is Map ? raw['scheduler'] as Map : const {};
    final limits = raw['limits'] is Map ? raw['limits'] as Map : const {};
    final served = <EmailableReport>[];
    if (raw['reports'] is List) {
      for (final r in raw['reports'] as List) {
        if (r is! Map) continue;
        final key = '${r['key'] ?? ''}';
        if (key.isEmpty) continue;
        final modes = r['window_modes'] is List ? (r['window_modes'] as List).map((m) => '$m').toList() : const ['calendar'];
        served.add(EmailableReport(key, '${r['title'] ?? key}', r['family'] == 'accounting' ? 'accounting' : 'mis',
            tradingDay: modes.contains('trading_day')));
      }
    }
    final reason = raw['reason'];
    return ReportEmailConfig(
      emailAvailable: raw['email_available'] == true,
      reason: reason is String && reason.isNotEmpty ? reason : null,
      schemaReady: raw['schema_ready'] != false,
      sendNowEnabled: raw['send_now_enabled'] != false,
      schedulerEnabled: sched['enabled'] == true,
      recipientsPerSend: _int(limits['recipients_per_send']) ?? kMaxRecipientsPerSend,
      addressBookMax: _int(limits['address_book']) ?? kMaxAddressBook,
      formats: raw['formats'] is List ? orderedFormats((raw['formats'] as List).map((f) => '$f')) : const ['xlsx', 'csv'],
      reports: served.isEmpty ? kEmailableReports : served,
      canEditRecipients: raw['can_edit_recipients'] == true,
      canUseAllOutlets: raw['can_use_all_outlets'] == true,
    );
  }
}

/// One banner above the area: 'error', 'warning' or 'info'.
typedef EmailBanner = ({String tone, String title, String? detail});

/// A SERVER OLDER THAN EMAILED REPORTS. 2.0.1 has no GET /reports/email/config
/// and answers it with a 404; 2.0.2's route never answers 404. Any other
/// failure (no connection, a 5xx, a refusal) is "we could not ask".
bool emailRoutesMissing(int? status) => status == 404;

/// What the area and the Send sheet say on such a server, instead of blaming
/// the connection. App-only words: the web reads the same 404 as "could not
/// ask" today.
const String kServerPredatesEmailSentence = 'This server has not been updated for email reports yet';
const String kServerPredatesEmailHint =
    'Ask your administrator to update the server. Until then nothing can be emailed, and schedules cannot be '
    'created or edited here. Reports can still be downloaded.';

/// [serverOutdated] is [emailRoutesMissing] of the failed config read; it only
/// speaks when there is no config.
List<EmailBanner> configBanners(ReportEmailConfig? c, {bool serverOutdated = false}) {
  if (c == null) {
    if (serverOutdated) {
      return const [(tone: 'warning', title: kServerPredatesEmailSentence, detail: kServerPredatesEmailHint)];
    }
    return const [
      (tone: 'warning', title: "Couldn't check the email settings", detail: 'Check the connection and reload. Nothing has been changed.'),
    ];
  }
  final out = <EmailBanner>[];
  if (!c.schemaReady) {
    out.add((tone: 'error', title: kSchemaPendingSentence, detail: 'Ask your administrator to apply migrations 056–058.'));
  }
  if (!c.emailAvailable) {
    out.add((tone: 'error', title: kMailOffSentence, detail: c.reason == null ? kMailOffHint : '$kMailOffHint (${c.reason})'));
  } else if (!c.schedulerEnabled) {
    out.add((tone: 'info', title: kSchedulerOffSentence, detail: null));
  }
  if (c.emailAvailable && !c.sendNowEnabled) {
    out.add((tone: 'info', title: kSendNowOffSentence, detail: null));
  }
  return out;
}

/// Why Send now cannot be used, or null when it can. [serverOutdated] as for
/// [configBanners].
String? sendNowBlocked(ReportEmailConfig? c, {bool serverOutdated = false}) {
  if (c == null) {
    return serverOutdated ? kServerPredatesEmailSentence : "Couldn't check the email settings — reload and try again.";
  }
  if (!c.schemaReady) return kSchemaPendingSentence;
  if (!c.emailAvailable) return kMailOffSentence;
  if (!c.sendNowEnabled) return kSendNowOffSentence;
  return null;
}

/// A refusal's title, by the server's `code`.
String refusalTitle(String? code) => switch (code) {
      'mail_not_configured' => kMailOffSentence,
      'schema_pending' => kSchemaPendingSentence,
      'send_now_disabled' => kSendNowOffSentence,
      'rate_limited' => 'Too many emails in a short time',
      'daily_limit' => 'Daily email limit reached',
      'recipient_not_allowed' => 'An address is no longer allowed',
      'all_outlets_not_allowed' => 'All outlets needs an admin or a manager',
      'duplicate' => 'Already in the address book',
      _ => "Couldn't send",
    };

// --- The address book -------------------------------------------------------------

class BookEntry {
  const BookEntry({required this.id, required this.email, this.label, this.active = true, this.suppressedReason});
  final String id;
  final String email;
  final String? label;
  final bool active;
  final String? suppressedReason;

  String get display => label == null ? email : '$label — $email';

  static List<BookEntry>? listFromJson(Object? raw) {
    if (raw is! Map || raw['recipients'] is! List) return null;
    return [
      for (final r in raw['recipients'] as List)
        if (r is Map && '${r['id'] ?? ''}'.isNotEmpty && '${r['email'] ?? ''}'.isNotEmpty)
          BookEntry(
            id: '${r['id']}',
            email: '${r['email']}',
            label: r['label'] is String && (r['label'] as String).isNotEmpty ? r['label'] as String : null,
            active: r['status'] != 'suppressed',
            suppressedReason: r['suppressed_reason'] is String ? r['suppressed_reason'] as String : null,
          ),
    ];
  }
}

String _emailKey(String s) => s.trim().toLowerCase();

/// The book ids behind stored addresses; the ones no longer in the book are reported.
({List<String> ids, List<String> missing}) idsForAddresses(List<String> addresses, List<BookEntry> book) {
  final ids = <String>[];
  final missing = <String>[];
  for (final a in addresses) {
    BookEntry? hit;
    for (final b in book) {
      if (b.active && _emailKey(b.email) == _emailKey(a)) {
        hit = b;
        break;
      }
    }
    if (hit == null) {
      missing.add(a);
    } else if (!ids.contains(hit.id)) {
      ids.add(hit.id);
    }
  }
  return (ids: ids, missing: missing);
}

/// A typed address, checked before the server checks it again.
String? addressProblem(String email, List<BookEntry> book, int max) {
  final s = email.trim();
  if (s.isEmpty) return 'Type an email address.';
  if (s.length > 254 || RegExp(r'\s').hasMatch(s) || !RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s)) {
    return 'That does not look like an email address.';
  }
  if (book.any((b) => _emailKey(b.email) == _emailKey(s))) return 'That address is already in the address book.';
  if (book.length >= max) return 'The address book holds at most $max addresses. Remove one first.';
  return null;
}

// --- Send now ---------------------------------------------------------------------

final RegExp _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false);
bool isRequestId(String v) => _uuidRe.hasMatch(v);

/// A fresh request id (a v4 UUID). The server answers a repeated id as a replay
/// of the delivery it already made — see [requestIdFor] for when one is reused.
String newClientRequestId([math.Random? rng]) {
  final r = rng ?? math.Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// What a Send-now body asks for, without its id — equal keys, equal sends.
String sendBodyKey(Map body) {
  List<String> sorted(Object? v) => [for (final x in (v is List ? v : const [])) '$x']..sort();
  final w = body['window'] is Map ? body['window'] as Map : const {};
  return jsonEncode([
    sorted(body['report_keys']),
    sorted(body['formats']),
    '${w['from'] ?? ''}',
    '${w['to'] ?? ''}',
    '${w['day_close'] ?? ''}',
    '${body['outlet_scope'] ?? ''}',
    sorted(body['recipient_ids']),
  ]);
}

/// The last id a sheet sent, what it asked for, and whether its delivery is final.
class LastSend {
  LastSend(this.id, this.bodyKey);
  final String id;
  final String bodyKey;
  bool settled = false;
}

/// THE ID FOR THIS PRESS OF "Send". The same id ONLY for a true retry: the same
/// reports, days, formats, scope and addresses, and no final answer yet. The
/// server answers a repeated id with the delivery it already made — so one id
/// for the whole sheet turned "change the addresses after a failure and press
/// Send again" into a replay of the OLD failed send, and the corrected choice
/// was never sent.
String requestIdFor(LastSend? last, String bodyKey, [String Function()? mint]) =>
    last != null && !last.settled && last.bodyKey == bodyKey ? last.id : (mint ?? newClientRequestId)();

/// The POST /reports/email/send body, or the sentence that stops it.
({Map<String, dynamic>? body, String? error}) buildSendBody({
  required String clientRequestId,
  required List<String> reportKeys,
  required List<String> formats,
  required String from,
  required String to,
  required String dayClose,
  required bool allOutlets,
  required List<String> recipientIds,
  int maxRecipients = kMaxRecipientsPerSend,
}) {
  final close = dayClose.trim();
  if (close.isNotEmpty && parseTime(close) == null) {
    return (body: null, error: 'Write the closing time as HH:mm, or leave it empty for calendar days.');
  }
  final problem = selectionProblem(reportKeys, close.isEmpty ? 'calendar' : 'trading_day');
  if (problem != null) return (body: null, error: problem);
  final fmts = orderedFormats(formats);
  if (fmts.isEmpty) return (body: null, error: 'Choose Excel, CSV or both.');
  final day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (!day.hasMatch(from) || !day.hasMatch(to) || from.compareTo(to) > 0) {
    return (body: null, error: 'Pick the days to send.');
  }
  final ids = recipientIds.toSet().toList();
  if (ids.isEmpty) return (body: null, error: 'Choose at least one address from the address book.');
  if (ids.length > maxRecipients) return (body: null, error: 'Choose at most $maxRecipients addresses.');
  if (!isRequestId(clientRequestId)) {
    return (body: null, error: 'This send has no request id — close the sheet and open it again.');
  }
  return (
    body: <String, dynamic>{
      'client_request_id': clientRequestId,
      'report_keys': orderedReportKeys(reportKeys),
      'formats': fmts,
      'window': <String, dynamic>{'from': from, 'to': to, if (close.isNotEmpty) 'day_close': close},
      'outlet_scope': allOutlets ? 'all' : 'outlet',
      'recipient_ids': ids,
    },
    error: null,
  );
}

// --- Deliveries -------------------------------------------------------------------

const String kWillRetryLabel = 'Will retry';

/// One word per state, the same on web and app; tone is 'ok', 'bad' or 'pending'.
({String label, String tone}) deliveryStatus(Map d) {
  switch ('${d['status'] ?? ''}') {
    case 'delivered':
      return (label: d['channel'] == 'email' ? 'Sent' : 'Delivered', tone: 'ok');
    case 'failed':
      return isFinalDelivery(d) ? (label: 'Failed', tone: 'bad') : (label: kWillRetryLabel, tone: 'pending');
    case 'abandoned':
      return (label: 'Missed', tone: 'bad');
    case 'sending':
      return (label: 'Sending', tone: 'pending');
    case 'rendered':
      return (label: 'Building', tone: 'pending');
  }
  return (label: 'Queued', tone: 'pending');
}

List<String> _strings(Object? v) => v is List ? [for (final x in v) if (x != null) '$x'] : const [];

/// Where a delivery came from.
String deliveryKind(Map d) {
  final kind = d['kind'];
  if (kind == 'adhoc') return _strings(d['report_keys']).isEmpty ? 'Test email' : 'Sent from Reports';
  final key = d['occurrence_key'];
  if (kind == 'manual' || (kind == null && (key is! String || key.isEmpty || key.startsWith('manual:')))) {
    return 'Run now';
  }
  return 'Scheduled';
}

/// FINAL = nothing more will happen to this row without a person, as the server
/// says (`final`). A 'failed' row with attempts left is RETRIED at
/// next_attempt_at: calling every 'failed' final told the owner "Couldn't send"
/// for an email that went out minutes later — and invited a second send of it.
/// A server that does not say reads the old way.
bool isFinalDelivery(Map d) {
  final status = '${d['status'] ?? ''}';
  if (status == 'delivered' || status == 'abandoned') return true;
  return status == 'failed' && d['final'] != false;
}

/// Nothing will change for a while: final, or failed and waiting for its retry.
/// The Send-now sheet stops watching here.
bool isResting(Map d) => '${d['status'] ?? ''}' == 'failed' || isFinalDelivery(d);

/// "The server tries again at 18 Sep, 02:05." — or '' when it will not.
String retryCaption(Map d, [DateTime? Function(String iso)? wallOf]) {
  if ('${d['status'] ?? ''}' != 'failed' || isFinalDelivery(d)) return '';
  final next = d['next_attempt_at'];
  final at = next is String && next.isNotEmpty && wallOf != null && wallOf(next) != null ? wallClock(next, wallOf) : '';
  return at.isEmpty ? 'The server tries again shortly.' : 'The server tries again at $at.';
}

/// How long a screen keeps refreshing a row that has not finished — the web's
/// WATCH_MAX_MS. Without it a row that never settles re-read the history every
/// six seconds for as long as the panel stayed open.
const Duration kWatchMaxAge = Duration(minutes: 15);

/// Whether the history should keep refreshing for [d] at [now].
bool isWatched(Map d, DateTime now) {
  if (isFinalDelivery(d)) return false;
  final created = DateTime.tryParse('${d['created_at'] ?? ''}');
  return created != null && now.difference(created) < kWatchMaxAge;
}

/// ONE OUTCOME PER ADDRESS, matched case-insensitively.
List<({String email, String outcome})> recipientOutcomes(Map d, [List<String> scheduled = const []]) {
  final sent = _strings(d['delivered_to']);
  final refused = _strings(d['rejected_to']);
  final skipped = _strings(d['skipped_to']);
  final own = _strings(d['recipients']);
  final addressed = own.isNotEmpty ? own : (d['channel'] == 'email' ? scheduled : const <String>[]);
  final all = <String>[];
  for (final a in [...addressed, ...sent, ...refused, ...skipped]) {
    if (!all.any((x) => _emailKey(x) == _emailKey(a))) all.add(a);
  }
  bool has(List<String> list, String a) => list.any((x) => _emailKey(x) == _emailKey(a));
  return [
    for (final e in all)
      (
        email: e,
        outcome: has(sent, e) ? 'sent' : has(refused, e) ? 'refused' : has(skipped, e) ? 'skipped' : 'waiting',
      ),
  ];
}

/// The message a finished (or still running) send ends with.
({String title, String description, bool bad}) sendOutcome(
  Map? d, {
  required bool timedOut,
  DateTime? Function(String iso)? wallOf,
}) {
  const onItsWay = 'The email is on its way. Its result will appear in Email reports → History.';
  if (d == null) return (title: 'Queued', description: onItsWay, bad: false);
  final rows = recipientOutcomes(d);
  int count(String o) => rows.where((r) => r.outcome == o).length;
  final sent = count('sent');
  final extra = <String>[
    if (count('refused') > 0) '${count('refused')} refused by the mail service',
    if (count('skipped') > 0) '${count('skipped')} skipped',
    if (d['maybe_duplicate'] == true) 'the server restarted while sending, so someone may have received it twice',
  ];
  final status = '${d['status'] ?? ''}';
  if (status == 'delivered') {
    return (
      title: 'Sent to $sent address${sent == 1 ? '' : 'es'}',
      description: extra.isNotEmpty ? '${extra.join('; ')}.' : 'The files are also kept in Email reports → History.',
      bad: false,
    );
  }
  if (status == 'failed' && !isFinalDelivery(d)) {
    final err = d['error'];
    return (
      title: 'Not sent yet',
      description: '${err is String && err.isNotEmpty ? '$err ' : ''}${retryCaption(d, wallOf)} '
          'Its result will appear in Email reports → History; pressing Send again with the same choices does not send it twice.',
      bad: false,
    );
  }
  if (status == 'failed' || status == 'abandoned') {
    final err = d['error'];
    return (
      title: "Couldn't send",
      description: err is String && err.isNotEmpty
          ? err
          : extra.isNotEmpty
              ? '${extra.join('; ')}.'
              : 'The mail service did not accept the email.',
      bad: true,
    );
  }
  return (title: timedOut ? 'Still sending' : 'Queued', description: onItsWay, bad: false);
}

/// "Excel workbook · 47 KB", "Void KOT (CSV) · 3.0 MB · cut short".
String fileLabel(Map f) {
  final format = '${f['format'] ?? ''}';
  final what = format == 'xlsx' ? 'Excel workbook' : '${reportTitle('${f['report_key'] ?? ''}')} (CSV)';
  final bytes = _int(f['bytes']) ?? 0;
  final size = bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${math.max(1, (bytes / 1024).round())} KB';
  final notes = [f['purged'] == true ? 'cleared after 90 days' : size, if (f['truncated'] == true) 'cut short'];
  return '$what · ${notes.join(' · ')}';
}

/// Poll every two seconds for up to a minute; after that the history takes over.
const Duration kPollInterval = Duration(seconds: 2);
const int kPollMaxTries = 30;

// --- Schedules --------------------------------------------------------------------

/// The create/edit form's state.
class EmailScheduleForm {
  EmailScheduleForm({
    this.name = '',
    List<String>? reportKeys,
    List<String>? formats,
    this.frequency = 'daily',
    this.hour = 23,
    this.minute = 30,
    this.weekday = 1,
    this.dayOfMonth = 1,
    this.windowMode = 'trading_day',
    this.allOutlets = false,
    this.channel = 'email',
    List<String>? recipientIds,
    this.enabled = true,
  })  : reportKeys = reportKeys ?? ['sales_summary', 'settlement_summary'],
        formats = formats ?? ['xlsx'],
        recipientIds = recipientIds ?? <String>[];

  String name;
  List<String> reportKeys;
  List<String> formats;
  String frequency;
  int hour;
  int minute;
  int weekday;
  int dayOfMonth;
  String windowMode;
  bool allOutlets;
  String channel;
  List<String> recipientIds;
  bool enabled;

  String get time => hhmm(hour, minute);

  /// The form for a stored schedule, and the addresses no longer in the book.
  static ({EmailScheduleForm form, List<String> missing}) fromSchedule(Map s, List<BookEntry> book) {
    final keys = _strings(s['report_keys']);
    final fmts = _strings(s['formats']);
    final found = idsForAddresses(_strings(s['recipients']), book);
    return (
      form: EmailScheduleForm(
        name: '${s['name'] ?? ''}',
        reportKeys: orderedReportKeys(keys.isNotEmpty ? keys : ['${s['report_key'] ?? 'sales'}']),
        formats: orderedFormats(fmts.isNotEmpty ? fmts : ['${s['format'] ?? 'csv'}']),
        frequency: '${s['frequency'] ?? 'daily'}',
        hour: _int(s['hour_local']) ?? 8,
        minute: _int(s['minute_local']) ?? 0,
        weekday: _int(s['weekday']) ?? 1,
        dayOfMonth: _int(s['day_of_month']) ?? 1,
        windowMode: s['window_mode'] == 'trading_day' ? 'trading_day' : 'calendar',
        allOutlets: s['outlet_scope'] == 'all',
        channel: '${s['channel'] ?? 'inbox'}',
        recipientIds: found.ids,
        enabled: s['enabled'] != false,
      ),
      missing: found.missing,
    );
  }
}

/// The create/edit body, or what is missing. [recipientsTouched] false leaves
/// the stored list alone.
({Map<String, dynamic>? patch, String? error}) buildSchedulePatch(
  EmailScheduleForm f, {
  int maxRecipients = kMaxRecipientsPerSend,
  bool recipientsTouched = true,
}) {
  final name = f.name.trim();
  if (name.isEmpty) return (patch: null, error: 'Give the schedule a name');
  if (f.hour < 0 || f.hour > 23 || f.minute < 0 || f.minute > 59) return (patch: null, error: 'Pick a time of day');
  final mode = f.frequency == 'daily' ? f.windowMode : 'calendar';
  final problem = selectionProblem(f.reportKeys, mode);
  if (problem != null) return (patch: null, error: problem);
  final fmts = orderedFormats(f.formats);
  if (fmts.isEmpty) return (patch: null, error: 'Choose Excel, CSV or both.');
  final ids = f.recipientIds.toSet().toList();
  if (f.channel == 'email' && recipientsTouched && ids.isEmpty) {
    return (patch: null, error: 'Choose at least one address from the address book, or deliver to the in-app inbox instead.');
  }
  if (ids.length > maxRecipients) return (patch: null, error: 'Choose at most $maxRecipients addresses.');
  return (
    patch: <String, dynamic>{
      'name': name,
      'report_keys': orderedReportKeys(f.reportKeys),
      'formats': fmts,
      'frequency': f.frequency,
      'hour_local': f.hour,
      'minute_local': f.minute,
      'weekday': f.frequency == 'weekly' ? f.weekday : null,
      'day_of_month': f.frequency == 'monthly' ? f.dayOfMonth : null,
      'window_mode': mode,
      'outlet_scope': f.allOutlets ? 'all' : 'outlet',
      'channel': f.channel,
      'enabled': f.enabled,
      if (f.channel != 'email') 'recipient_ids': const <String>[],
      if (f.channel == 'email' && recipientsTouched) 'recipient_ids': ids,
    },
    error: null,
  );
}
