import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/models/report_email.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/time_slot.dart';

/// EMAIL REPORTS (client item 9) — the app's rules, by value.
///
///   * which reports may be read on which kind of day, and the server's own
///     refusal sentence for the rest;
///   * the exact Send-now body: whole days only (never a session filter), one
///     request id per sheet, the combined scope in the BODY;
///   * one word per delivery state and one outcome per address, the same as
///     the web dashboard's src/lib/report-email.ts — read from its checkout
///     when it sits beside this one, and the backend's catalogue the same way;
///   * a schedule edit that did not touch the addresses leaves them alone;
///   * none of it can ride the offline outbox.

String _sibling(String repo, String relative) {
  for (final base in [Directory.current.parent.path, '${Directory.current.path}/..']) {
    final f = File('$base/$repo/$relative');
    if (f.existsSync()) return f.readAsStringSync().replaceAll('\r\n', '\n');
  }
  return '';
}

DateTime? _ist(String iso) {
  final d = DateTime.tryParse(iso);
  return d?.toUtc().add(const Duration(minutes: 330));
}

const _book = [
  BookEntry(id: 'r1', email: 'owner@gaia.test', label: 'Owner'),
  BookEntry(id: 'r2', email: 'Accounts@Firm.test'),
  BookEntry(id: 'r3', email: 'old@firm.test', active: false, suppressedReason: 'bounced'),
];

const _rid = '1b4e28ba-2fa1-41d2-883f-0016d3cca427';

({Map<String, dynamic>? body, String? error}) _send({
  String id = _rid,
  List<String> keys = const ['sales_summary'],
  List<String> formats = const ['xlsx'],
  String from = '2026-09-16',
  String to = '2026-09-16',
  String close = '',
  bool all = false,
  List<String> to_ = const ['r1'],
}) =>
    buildSendBody(
      clientRequestId: id,
      reportKeys: keys,
      formats: formats,
      from: from,
      to: to,
      dayClose: close,
      allOutlets: all,
      recipientIds: to_,
    );

void main() {
  group('the catalogue', () {
    test('eighteen reports: the fifteen tabs, then Sales, GST and P&L; GST and P&L calendar only', () {
      expect(kEmailableReports, hasLength(18));
      expect(kMisEmailKeys, hasLength(15));
      expect(kEmailableReports.skip(15).map((r) => r.title), ['Sales (accounting)', 'GST', 'Profit & Loss']);
      expect(kCalendarOnlyKeys, ['gst', 'pnl']);
    });

    test('the fifteen are the Reports tabs, key and title, in order', () {
      final src = File('lib/screens/reports.dart').readAsStringSync();
      final tabs = RegExp(r"_MisReport\('([a-z_]+)', '([^']+)'").allMatches(src).map((m) => '${m[1]}|${m[2]}').toList();
      expect(tabs, [for (final r in kEmailableReports.take(15)) '${r.key}|${r.title}']);
    });

    test('matches the backend catalogue (when its checkout is beside this one)', () {
      final src = _sibling('Restaurant_Backend', 'report_catalogue.ts');
      if (src.isEmpty) return;
      final rows = RegExp(r'\{ key: "([a-z_]+)", title: "([^"]+)", family: "(mis|accounting)",[^}]*windowModes: (BOTH|CALENDAR_ONLY) \}')
          .allMatches(src)
          .map((m) => '${m[1]}|${m[2]}|${m[3]}|${m[4] == 'BOTH'}')
          .toList();
      expect(rows, [for (final r in kEmailableReports) '${r.key}|${r.title}|${r.family}|${r.tradingDay}']);
    });

    test('lists read like the email subject', () {
      expect(reportListPhrase(['sales_summary']), 'Sales Summary');
      expect(reportListPhrase(['void_kot', 'sales_summary']), 'Void KOT and Sales Summary');
      expect(reportListPhrase(['item_wise', 'discount', 'void_kot', 'bill_edit']), 'Item Wise, Discount and 2 more');
      expect(reportListPhrase(kMisEmailKeys), 'All 15 MIS reports');
      expect(reportListPhrase([for (final r in kEmailableReports) r.key]), 'All reports');
      expect(orderedReportKeys(['pnl', 'item_wise', 'nope', 'item_wise']), ['item_wise', 'pnl']);
    });

    test('GST and P&L on a trading day: the server\'s own sentence', () {
      expect(selectionProblem(['gst', 'pnl', 'sales'], 'trading_day'),
          'GST and Profit & Loss can only be sent for calendar days. Choose "previous calendar day", or leave them out.');
      expect(selectionProblem(['gst'], 'trading_day'),
          'GST can only be sent for calendar days. Choose "previous calendar day", or leave it out.');
      expect(selectionProblem(['gst', 'pnl'], 'calendar'), isNull);
      expect(selectionProblem([], 'calendar'), 'Pick at least one report to send.');
      expect(reportDisabledReason('pnl', 'trading_day'), kCalendarDaysOnly);
      expect(reportDisabledReason('sales', 'trading_day'), isNull);
      expect(defaultWindowMode('daily', ['sales_summary']), 'trading_day');
      expect(defaultWindowMode('daily', ['sales_summary', 'gst']), 'calendar');
      expect(defaultWindowMode('monthly', ['sales_summary']), 'calendar');
    });
  });

  group('Send now', () {
    test('a plain send: whole calendar days, the workbook, addresses by book id', () {
      final b = _send();
      expect(b.error, isNull);
      expect(b.body, {
        'client_request_id': _rid,
        'report_keys': ['sales_summary'],
        'formats': ['xlsx'],
        'window': {'from': '2026-09-16', 'to': '2026-09-16'},
        'outlet_scope': 'outlet',
        'recipient_ids': ['r1'],
      });
    });

    test('NEVER a session filter; a close only when chosen; the combined scope in the body', () {
      final b = _send(close: '02:00', keys: ['void_kot', 'item_wise'], formats: ['csv', 'xlsx'], all: true).body!;
      expect(b['window'], {'from': '2026-09-16', 'to': '2026-09-16', 'day_close': '02:00'});
      expect((b['window'] as Map).keys, isNot(contains('slot')));
      expect(b.keys, isNot(contains('slot')));
      expect(b['report_keys'], ['item_wise', 'void_kot']);
      expect(b['formats'], ['xlsx', 'csv']);
      expect(b['outlet_scope'], 'all');
    });

    test('refuses in words', () {
      expect(_send(close: '25:00').error, 'Write the closing time as HH:mm, or leave it empty for calendar days.');
      expect(_send(close: '02:00', keys: ['gst']).error, contains('calendar days'));
      expect(_send(formats: []).error, 'Choose Excel, CSV or both.');
      expect(_send(formats: ['pdf']).error, 'Choose Excel, CSV or both.');
      expect(_send(to_: []).error, 'Choose at least one address from the address book.');
      expect(_send(to_: [for (var i = 0; i < 11; i++) 'r$i']).error, 'Choose at most 10 addresses.');
      expect(_send(from: '2026-09-17').error, 'Pick the days to send.');
      expect(_send(id: 'nope').error, contains('request id'));
    });

    test('a v4 UUID per sheet, never repeated', () {
      final a = newClientRequestId(math.Random(7));
      expect(isRequestId(a), isTrue);
      expect(a[14], '4');
      expect(['8', '9', 'a', 'b'], contains(a[19]));
      final ids = {for (var i = 0; i < 200; i++) newClientRequestId()};
      expect(ids, hasLength(200));
      expect(ids.every(isRequestId), isTrue);
    });

    test('refusal codes read as a person would act on them', () {
      expect(refusalTitle('mail_not_configured'), kMailOffSentence);
      expect(refusalTitle('rate_limited'), 'Too many emails in a short time');
      expect(refusalTitle(null), "Couldn't send");
    });
  });

  group('the config', () {
    final raw = <String, dynamic>{
      'email_available': true, 'transport': 'smtp', 'reason': null, 'schema_ready': true, 'send_now_enabled': true,
      'scheduler': {'enabled': true},
      'limits': {'recipients_per_send': 10, 'address_book': 25},
      'formats': ['xlsx', 'csv'],
      'reports': [
        {'key': 'gst', 'title': 'GST', 'family': 'accounting', 'window_modes': ['calendar']},
      ],
      'can_edit_recipients': true,
      'can_use_all_outlets': false,
    };

    test('reads it, and a server without the route reads as "could not ask"', () {
      final c = ReportEmailConfig.fromJson(raw)!;
      expect(c.reports.single.tradingDay, isFalse);
      expect(c.canUseAllOutlets, isFalse);
      expect(ReportEmailConfig.fromJson(<String, dynamic>{}), isNull);
      expect(configBanners(null).single.title, "Couldn't check the email settings");
      expect(sendNowBlocked(null), contains("Couldn't check"));
      expect(ReportEmailConfig.fromJson({...raw, 'reports': []})!.reports, hasLength(18));
    });

    test('mail off is the server\'s sentence; the scheduler off is information', () {
      final off = ReportEmailConfig.fromJson({...raw, 'email_available': false, 'reason': 'SMTP_HOST is not set'});
      expect(configBanners(off).single.title, 'Email is not set up on this server');
      expect(configBanners(off).single.detail, endsWith('(SMTP_HOST is not set)'));
      expect(sendNowBlocked(off), kMailOffSentence);
      final quiet = ReportEmailConfig.fromJson({...raw, 'scheduler': {'enabled': false}});
      expect(configBanners(quiet).single, (tone: 'info', title: kSchedulerOffSentence, detail: null));
      expect(sendNowBlocked(ReportEmailConfig.fromJson({...raw, 'schema_ready': false})), kSchemaPendingSentence);
      expect(sendNowBlocked(ReportEmailConfig.fromJson({...raw, 'send_now_enabled': false})), kSendNowOffSentence);
      expect(sendNowBlocked(ReportEmailConfig.fromJson(raw)), isNull);
    });

    test('the backend says "Email is not set up on this server" (when its checkout is beside this one)', () {
      final src = _sibling('Restaurant_Backend', 'routes/report_email.ts');
      if (src.isEmpty) return;
      expect(src, contains('export const MAIL_OFF_SENTENCE = "$kMailOffSentence";'));
    });
  });

  group('the address book', () {
    test('reads, matches stored addresses case-insensitively, reports the missing', () {
      final b = BookEntry.listFromJson({
        'recipients': [
          {'id': 'r1', 'email': 'owner@gaia.test', 'label': 'Owner', 'status': 'active'},
          {'id': 'r3', 'email': 'old@firm.test', 'status': 'suppressed', 'suppressed_reason': 'bounced'},
        ],
      })!;
      expect(b.map((e) => e.active), [true, false]);
      expect(b.first.display, 'Owner — owner@gaia.test');
      expect(BookEntry.listFromJson({'nope': 1}), isNull);
      final found = idsForAddresses(['OWNER@gaia.test', 'old@firm.test', 'gone@x.test'], _book);
      expect(found.ids, ['r1']);
      expect(found.missing, ['old@firm.test', 'gone@x.test']);
    });

    test('checks a typed address first', () {
      expect(addressProblem('', _book, 25), 'Type an email address.');
      expect(addressProblem('no-at', _book, 25), 'That does not look like an email address.');
      expect(addressProblem('accounts@firm.TEST', _book, 25), 'That address is already in the address book.');
      expect(addressProblem('new@firm.test', _book, 3), 'The address book holds at most 3 addresses. Remove one first.');
      expect(addressProblem('new+gst@firm.test', _book, 25), isNull);
    });
  });

  group('deliveries', () {
    test('one word per state', () {
      expect(deliveryStatus({'status': 'delivered', 'channel': 'email'}), (label: 'Sent', tone: 'ok'));
      expect(deliveryStatus({'status': 'delivered', 'channel': 'inbox'}).label, 'Delivered');
      expect(deliveryStatus({'status': 'failed'}).label, 'Failed');
      expect(deliveryStatus({'status': 'abandoned'}).label, 'Missed');
      expect(deliveryStatus({'status': 'sending'}).label, 'Sending');
      expect(deliveryStatus({'status': 'rendered'}).label, 'Building');
      expect(deliveryStatus({'status': 'claimed'}).label, 'Queued');
      expect(['delivered', 'failed', 'abandoned'].every(isSettledStatus), isTrue);
      expect(['claimed', 'rendered', 'sending'].any(isSettledStatus), isFalse);
    });

    test('where it came from — a 2.0.1 server sends no kind, and the key still tells', () {
      expect(deliveryKind({'kind': 'adhoc', 'report_keys': []}), 'Test email');
      expect(deliveryKind({'kind': 'adhoc', 'report_keys': ['sales']}), 'Sent from Reports');
      expect(deliveryKind({'kind': 'manual'}), 'Run now');
      expect(deliveryKind({'kind': 'scheduled', 'occurrence_key': '2026-09-16'}), 'Scheduled');
      expect(deliveryKind({'occurrence_key': 'manual:2026-09-16T08:00'}), 'Run now');
      expect(deliveryKind({'occurrence_key': '2026-09-16'}), 'Scheduled');
    });

    test('ONE OUTCOME PER ADDRESS', () {
      final rows = recipientOutcomes({
        'status': 'sending',
        'channel': 'email',
        'recipients': ['owner@gaia.test', 'Accounts@Firm.test', 'third@x.test', 'fourth@x.test'],
        'delivered_to': ['owner@gaia.test'],
        'rejected_to': ['accounts@firm.test'],
        'skipped_to': ['third@x.test'],
      });
      expect([for (final r in rows) '${r.email}:${r.outcome}'], [
        'owner@gaia.test:sent',
        'Accounts@Firm.test:refused',
        'third@x.test:skipped',
        'fourth@x.test:waiting',
      ]);
      expect(recipientOutcomes({'status': 'claimed', 'channel': 'email'}, ['a@b.co']).single.outcome, 'waiting');
      expect(recipientOutcomes({'status': 'delivered', 'channel': 'inbox'}, ['a@b.co']), isEmpty);
    });

    test('the closing message never claims more than it saw', () {
      expect(sendOutcome({'status': 'delivered', 'channel': 'email', 'recipients': ['a@b.co', 'c@d.co'], 'delivered_to': ['a@b.co', 'c@d.co']}, timedOut: false).title,
          'Sent to 2 addresses');
      final partial = sendOutcome({
        'status': 'delivered', 'channel': 'email', 'recipients': ['a@b.co', 'c@d.co'],
        'delivered_to': ['a@b.co'], 'rejected_to': ['c@d.co'], 'maybe_duplicate': true,
      }, timedOut: false);
      expect(partial.title, 'Sent to 1 address');
      expect(partial.description, contains('1 refused by the mail service'));
      expect(partial.description, contains('may have received it twice'));
      final failed = sendOutcome({'status': 'failed', 'error': 'Every address was refused'}, timedOut: false);
      expect(failed, (title: "Couldn't send", description: 'Every address was refused', bad: true));
      expect(sendOutcome({'status': 'sending'}, timedOut: true).title, 'Still sending');
      expect(sendOutcome(null, timedOut: true).title, 'Queued');
    });

    test('files say what they are; days and instants in the restaurant\'s words', () {
      expect(fileLabel({'report_key': 'bundle', 'format': 'xlsx', 'bytes': 48000}), 'Excel workbook · 47 KB');
      expect(fileLabel({'report_key': 'void_kot', 'format': 'csv', 'bytes': 3 * 1024 * 1024, 'truncated': true}),
          'Void KOT (CSV) · 3.0 MB · cut short');
      expect(fileLabel({'report_key': 'sales', 'format': 'csv', 'bytes': 10, 'purged': true}),
          'Sales (accounting) (CSV) · cleared after 90 days');
      expect(shortDay('2026-09-16'), 'Wed 16 Sep');
      expect(periodPhrase('2026-09-01', '2026-09-15'), '1 Sep – 15 Sep');
      expect(wallClock('2026-09-17T20:30:00.000Z', _ist), '18 Sep, 02:00');
      expect(wallClock(null, _ist), '');
    });
  });

  group('schedules', () {
    test('any minute; a new daily schedule closes at its send time', () {
      final f = EmailScheduleForm(name: 'Nightly', hour: 23, minute: 47, recipientIds: ['r1']);
      final p = buildSchedulePatch(f).patch!;
      expect(p, {
        'name': 'Nightly', 'report_keys': ['sales_summary', 'settlement_summary'], 'formats': ['xlsx'],
        'frequency': 'daily', 'hour_local': 23, 'minute_local': 47, 'weekday': null, 'day_of_month': null,
        'window_mode': 'trading_day', 'outlet_scope': 'outlet', 'channel': 'email', 'enabled': true,
        'recipient_ids': ['r1'],
      });
      expect(parseTime('02:05'), 125);
      expect(parseTime('24:00'), isNull);
    });

    test('weekly and monthly are calendar periods whatever the form says', () {
      final p = buildSchedulePatch(EmailScheduleForm(name: 'W', frequency: 'weekly', weekday: 1, recipientIds: ['r1'])).patch!;
      expect(p['window_mode'], 'calendar');
      expect(p['weekday'], 1);
    });

    test('an edit that did not touch the addresses leaves the stored list alone', () {
      final p = buildSchedulePatch(EmailScheduleForm(name: 'E'), recipientsTouched: false).patch!;
      expect(p.containsKey('recipient_ids'), isFalse);
      final inbox = buildSchedulePatch(EmailScheduleForm(name: 'I', channel: 'inbox', recipientIds: ['r1'])).patch!;
      expect(inbox['recipient_ids'], isEmpty);
    });

    test('refuses in words', () {
      String? e(EmailScheduleForm f, {int max = 10}) => buildSchedulePatch(f, maxRecipients: max).error;
      expect(e(EmailScheduleForm(name: ' ', recipientIds: ['r1'])), 'Give the schedule a name');
      expect(e(EmailScheduleForm(name: 'X', reportKeys: ['gst'], recipientIds: ['r1'])), contains('calendar days'));
      expect(e(EmailScheduleForm(name: 'X', reportKeys: ['gst'], windowMode: 'calendar', recipientIds: ['r1'])), isNull);
      expect(e(EmailScheduleForm(name: 'X', formats: [], recipientIds: ['r1'])), 'Choose Excel, CSV or both.');
      expect(e(EmailScheduleForm(name: 'X')), contains('at least one address'));
      expect(e(EmailScheduleForm(name: 'X', recipientIds: ['a', 'b', 'c']), max: 2), 'Choose at most 2 addresses.');
    });

    test('a 2.0.1 schedule opens as the single calendar-day CSV it always was', () {
      final legacy = EmailScheduleForm.fromSchedule({
        'name': 'Morning sales', 'report_key': 'sales', 'format': 'csv', 'frequency': 'daily',
        'hour_local': 8, 'minute_local': 15, 'channel': 'email', 'recipients': ['owner@gaia.test', 'gone@x.test'],
      }, _book);
      expect(legacy.form.reportKeys, ['sales']);
      expect(legacy.form.formats, ['csv']);
      expect(legacy.form.windowMode, 'calendar');
      expect(legacy.form.time, '08:15');
      expect(legacy.form.recipientIds, ['r1']);
      expect(legacy.missing, ['gone@x.test']);
    });

    test('the row says when it next runs and what that covers — the server\'s arithmetic', () {
      final trading = {
        'enabled': true,
        'next_run_at': '2026-09-17T20:30:00.000Z',
        'next_window': {'from': '2026-09-17', 'to': '2026-09-17', 'day_close': '02:00', 'start_at': '2026-09-16T20:30:00.000Z', 'end_at': '2026-09-17T20:30:00.000Z'},
      };
      expect(nextRunCaption(trading, _ist), 'Next: 18 Sep, 02:00 — covers 17 Sep, 02:00 → 18 Sep, 02:00');
      expect(nextRunCaption({...trading, 'enabled': false}, _ist), '', reason: 'a paused schedule has no next run');
      expect(nextRunCaption({
        'enabled': true,
        'next_run_at': '2026-09-18T02:30:00.000Z',
        'next_window': {'from': '2026-09-17', 'to': '2026-09-17', 'day_close': null},
      }, _ist), 'Next: 18 Sep, 08:00 — covers Thu 17 Sep');
      expect(cadenceCaption({'frequency': 'daily', 'hour_local': 2, 'minute_local': 0, 'window_mode': 'trading_day'}),
          'Every day at 02:00 · the day that just ended');
      expect(cadenceCaption({'frequency': 'weekly', 'hour_local': 8, 'minute_local': 5, 'weekday': 1}), 'Every Monday at 08:05');
      expect(coverageCaption('daily', 'trading_day', '02:00'),
          'Covers the 24 hours up to 02:00 — the trading day that just closed, so bills settled after midnight count on the day they belong to.');
    });
  });

  group('the same words as the web dashboard (when its checkout is beside this one)', () {
    test('every label and sentence', () {
      final web = _sibling('Restaurant_Dashboard_UI', 'src/lib/report-email.ts');
      if (web.isEmpty) return;
      for (final w in [
        kEmailAreaTitle, kEmailButtonLabel, kEmailButtonTooltip, kMailOffSentence, kMailOffHint, kSchemaPendingSentence,
        kSchedulerOffSentence, kSendNowOffSentence, kTestEmailLabel, kAddressBookTitle, kAddressBookEmpty,
        kAddressBookReadOnly, kWholeDaysNote, kCalendarDaysOnly, kAllMisReports,
        ...kFormatLabels.values, ...kWindowModeLabels.values, ...kRecipientOutcomeLabels.values,
      ]) {
        expect(web, contains("'${w.replaceAll("'", "\\'")}'"), reason: w);
      }
      for (final r in kEmailableReports) {
        expect(web, contains("{ key: '${r.key}', title: '${r.title}'"), reason: r.key);
      }
    });
  });

  group('online only', () {
    test('no email route and no schedule route can be queued offline', () {
      for (final (method, path) in const [
        ('POST', '/reports/email/send'),
        ('POST', '/reports/email/test'),
        ('POST', '/reports/email/recipients'),
        ('DELETE', '/reports/email/recipients/r1'),
        ('POST', '/reports/schedules'),
        ('PATCH', '/reports/schedules/s1'),
        ('POST', '/reports/schedules/s1/run-now'),
      ]) {
        final d = OutboxPolicy.decide(method, path);
        expect(d.queueable, isFalse, reason: '$method $path');
        expect(d.refusal, "This isn't saved offline — reconnect and try again.");
      }
    });

    test('the Reports footer reads a dropped closing time as a notice, not a shortened range', () {
      expect(clampNotices(['day_close_with_slot']), (range: false, slot: 'A session is on calendar days — closing time not applied'));
      expect(clampNotices(['day_close_unparseable']).slot, 'That closing time could not be read — showing calendar days');
      expect(clampNotices(['slot_unknown', 'day_close_with_slot']).slot, 'That session no longer exists — showing all day');
      expect(clampNotices(['span_capped', 'day_close_with_slot']).range, isTrue);
    });
  });
}
