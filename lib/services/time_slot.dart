/// SESSION-WISE REPORTS — the part of the day a report is cut on.
///
/// Client ask (item 3): "select time for hour-wise reports or session-wise
/// reports; the superadmin should have an option to select what time slots he
/// wants to see reports of; preset sessions lunch 12pm-5pm and dinner 6pm-12am."
///
/// WHAT A SLOT IS
/// --------------
/// A TIME-OF-DAY filter laid over the date range: "Lunch, 1-15 Aug" is
/// 12:00-17:00 restaurant time on each of those fifteen days. The SERVER applies
/// it, on the clock each report already uses (settlement, order placement, or
/// the act itself), and says what it applied in `meta.time_slot`. Nothing here
/// filters, re-buckets or re-sums a row: this file turns the reader's choice
/// into query parameters and the server's answer back into words. A slot
/// crossing midnight (22:00-02:00) belongs to the business day it STARTS on —
/// the server's rule, repeated in the export so a filed sheet explains its own
/// Friday-night figure.
///
/// "SESSION" ON SCREEN, `time_slot` IN CODE: the word session already means
/// table sessions and cash sessions everywhere else in this app.
///
/// WHO MAY DO WHAT. Anyone who can read a report can PICK a slot — it reveals
/// nothing the whole day did not. Changing the saved list is for callers the
/// server marks `can_edit` (the settings permission; the superadmin always has
/// it), and for nobody else the entry is simply not there.
///
/// PARITY. This mirrors the web dashboard's `src/lib/report-time-slots.ts` rule
/// for rule and sentence for sentence: same parameters, same labels, same
/// filename suffix. A change here is a change there in the same release.
///
/// PURE: no Flutter, no HTTP — which is what lets test/time_slot_test.dart pin
/// every rule without pumping a widget.
library;

/// The server's ceiling on saved sessions.
const int kMaxTimeSlots = 8;

/// The server's label length limit.
const int kMaxTimeSlotLabel = 24;

// ---------------------------------------------------------------- clock text --

final RegExp _clock = RegExp(r'^(\d{1,2}):(\d{2})$');

/// `HH:mm` -> minutes after midnight, or null. `24:00` only with [allow24]: an
/// END may close at midnight, a START opens at 00:00. One-digit hours are
/// accepted ("9:30") because that is how people type; the wire always gets
/// `09:30`.
int? parseClock(Object? text, {bool allow24 = false}) {
  if (text is! String) return null;
  final m = _clock.firstMatch(text.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h == 24 && min == 0) return allow24 ? 1440 : null;
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

/// Minutes -> `HH:mm`. 1440 is `24:00`.
String formatClock(int minutes) {
  final total = minutes.clamp(0, 1440);
  final h = total ~/ 60;
  final m = total % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// `12:00–17:00` — an en dash, the glyph the date range uses.
String clockRange(String start, String end) => '$start–$end';

/// Null when a custom pair is usable; otherwise the one sentence the form
/// shows. 00:00-24:00 is valid: it is simply all day.
String? validateCustomSlot(String from, String to) {
  final start = parseClock(from);
  if (start == null) return 'Start time must be a 24-hour time between 00:00 and 23:59.';
  final end = parseClock(to, allow24: true);
  if (end == null) return 'End time must be a 24-hour time between 00:00 and 24:00.';
  if (start == end) return 'Start and end are the same time — choose two different times.';
  return null;
}

/// A slot whose end is earlier than its start runs past midnight.
bool crossesMidnight(String from, String to) {
  final start = parseClock(from);
  final end = parseClock(to, allow24: true);
  return start != null && end != null && end < start;
}

// -------------------------------------------------------------- the presets --

/// One of the restaurant's saved sessions.
class TimeSlotPreset {
  const TimeSlotPreset({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
    this.crossesMidnight = false,
  });

  final String id;
  final String label;
  final String start;
  final String end;
  final bool crossesMidnight;

  /// `Lunch · 12:00–17:00` — how a preset reads in the picker.
  String get optionLabel => '$label · ${clockRange(start, end)}';
}

/// GET/PUT /reports/mis/time-slots.
class TimeSlotCatalogue {
  const TimeSlotCatalogue({required this.slots, required this.canEdit, required this.isDefault});

  final List<TimeSlotPreset> slots;

  /// The caller may change the list (holds the settings permission).
  final bool canEdit;

  /// True while the restaurant has never saved its own list.
  final bool isDefault;

  /// Read defensively. A slot this client cannot draw is dropped rather than
  /// rendered as `null–null`; a body with no list at all is null, and the
  /// screen then offers no picker.
  static TimeSlotCatalogue? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['slots'];
    if (list is! List) return null;
    final slots = <TimeSlotPreset>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = item['id'] is String ? item['id'] as String : '';
      final label = item['label'] is String ? item['label'] as String : '';
      final start = item['start'] is String ? item['start'] as String : '';
      final end = item['end'] is String ? item['end'] as String : '';
      if (id.isEmpty || parseClock(start) == null || parseClock(end, allow24: true) == null) continue;
      slots.add(TimeSlotPreset(
        id: id,
        label: label.isEmpty ? id : label,
        start: start,
        end: end,
        crossesMidnight: item['crosses_midnight'] == true,
      ));
    }
    return TimeSlotCatalogue(
      slots: slots,
      canEdit: raw['can_edit'] == true,
      isDefault: raw['is_default'] == true,
    );
  }
}

// ------------------------------------------------------- the reader's choice --

enum TimeSlotKind { all, preset, custom }

/// All day, one saved session, or custom times.
class TimeSlotSelection {
  const TimeSlotSelection._(this.kind, {this.id = '', this.from = '', this.to = ''});

  static const TimeSlotSelection allDay = TimeSlotSelection._(TimeSlotKind.all);

  factory TimeSlotSelection.preset(String id) {
    final t = id.trim();
    return t.isEmpty || t == 'all' ? allDay : TimeSlotSelection._(TimeSlotKind.preset, id: t);
  }

  /// Validated and re-formatted; 00:00-24:00 IS all day, and anything unusable
  /// falls back to all day rather than sending the server a question it would
  /// clamp.
  factory TimeSlotSelection.custom(String from, String to) {
    if (validateCustomSlot(from, to) != null) return allDay;
    final start = parseClock(from)!;
    final end = parseClock(to, allow24: true)!;
    if (start == 0 && end == 1440) return allDay;
    return TimeSlotSelection._(TimeSlotKind.custom, from: formatClock(start), to: formatClock(end));
  }

  final TimeSlotKind kind;
  final String id;
  final String from;
  final String to;

  bool get isAllDay => kind == TimeSlotKind.all;

  /// A stable string: a widget key, a cache-able URL fragment.
  String get key => switch (kind) {
        TimeSlotKind.all => 'all',
        TimeSlotKind.preset => 'preset:$id',
        TimeSlotKind.custom => 'custom:$from-$to',
      };

  /// The query-string pairs, per the API contract. All day adds NOTHING, so an
  /// unsliced request is byte-for-byte the URL it always was — and so is its
  /// entry in the persisted read cache. Custom times win over a preset on the
  /// server; a selection is only ever one of the two here.
  List<String> get queryParts => switch (kind) {
        TimeSlotKind.all => const [],
        TimeSlotKind.preset => ['slot=${Uri.encodeQueryComponent(id)}'],
        TimeSlotKind.custom => [
            'time_from=${Uri.encodeQueryComponent(from)}',
            'time_to=${Uri.encodeQueryComponent(to)}',
          ],
      };

  /// What the chip says.
  String label(List<TimeSlotPreset> presets) {
    switch (kind) {
      case TimeSlotKind.custom:
        return 'Custom · ${clockRange(from, to)}';
      case TimeSlotKind.preset:
        for (final p in presets) {
          if (p.id == id) return p.optionLabel;
        }
        return 'All day';
      case TimeSlotKind.all:
        return 'All day';
    }
  }

  /// `Lunch (12:00–17:00)` or `22:00–02:00` — the same phrase the server's
  /// [AppliedTimeSlot.phrase] makes, for a toolbar that has no payload yet.
  /// Null for all day.
  String? phrase(List<TimeSlotPreset> presets) {
    switch (kind) {
      case TimeSlotKind.custom:
        return clockRange(from, to);
      case TimeSlotKind.preset:
        for (final p in presets) {
          if (p.id == id) return '${p.label} (${clockRange(p.start, p.end)})';
        }
        return null;
      case TimeSlotKind.all:
        return null;
    }
  }

  /// A remembered preset the restaurant has since deleted is not a filter any
  /// more; all day, visibly, beats sending an id the server would ignore while
  /// the chip still claimed "Lunch".
  TimeSlotSelection reconcile(List<TimeSlotPreset> presets) =>
      kind == TimeSlotKind.preset && !presets.any((p) => p.id == id) ? allDay : this;

  @override
  bool operator ==(Object other) => other is TimeSlotSelection && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'TimeSlotSelection($key)';
}

// ---------------------------------------------- what the server applied ------

/// `meta.time_slot`, read. Null means all day.
class AppliedTimeSlot {
  const AppliedTimeSlot({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
    required this.crossesMidnight,
    required this.source,
  });

  final String? id;
  final String label;
  final String start;
  final String end;
  final bool crossesMidnight;

  /// 'preset' | 'custom'.
  final String source;

  static AppliedTimeSlot? fromMeta(Object? meta) {
    final raw = meta is Map ? meta['time_slot'] : null;
    if (raw is! Map) return null;
    final start = '${raw['start'] ?? ''}';
    final end = '${raw['end'] ?? ''}';
    if (parseClock(start) == null || parseClock(end, allow24: true) == null) return null;
    return AppliedTimeSlot(
      id: raw['id'] is String ? raw['id'] as String : null,
      label: raw['label'] is String ? raw['label'] as String : '',
      start: start,
      end: end,
      crossesMidnight: raw['crosses_midnight'] == true,
      source: raw['source'] == 'preset' ? 'preset' : 'custom',
    );
  }

  /// `Lunch (12:00–17:00)`, or just `22:00–02:00` for custom times.
  String get phrase => source == 'preset' && label.isNotEmpty
      ? '$label (${clockRange(start, end)})'
      : clockRange(start, end);

  /// The export's "Time slot" row.
  String get provenance {
    final base = '$phrase restaurant time, on each day of the range';
    return crossesMidnight
        ? '$base — crosses midnight, so each night is counted on the day it starts'
        : base;
  }

  /// `_lunch-1200-1700`, the same suffix the web export writes.
  String get fileSuffix {
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+'), '')
        .replaceAll(RegExp(r'-+$'), '');
    String hhmm(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');
    return '_${slug.isEmpty ? '' : '$slug-'}${hhmm(start)}-${hhmm(end)}';
  }
}

/// The export's "Time slot" row for a report cut on [slot] (null = all day).
String timeSlotProvenance(AppliedTimeSlot? slot) => slot?.provenance ?? 'All day';

// --------------------------------------------------------------------- clamps --

const List<String> kSlotClamps = ['slot_unknown', 'time_unparseable', 'time_empty'];

const Map<String, String> _slotClampNotice = {
  'slot_unknown': 'That session no longer exists — showing all day',
  'time_unparseable': 'Those times could not be read — showing all day',
  'time_empty': 'Start and end were the same — showing all day',
};

/// What `meta.window.clamped` means for the footer.
///
/// THE BUG THIS REPLACES: the server sends a LIST (`[]` when nothing was
/// adjusted) and this screen tested `clamped == true`, which a list never is —
/// so a window the server really had shortened was never flagged. An
/// adjustment is a non-empty list, and a slot clamp is not a date clamp: it
/// gets its own sentence, and only the rest shorten the range.
({bool range, String? slot}) clampNotices(Object? clamped) {
  if (clamped is! List) return (range: clamped == true, slot: null);
  final names = [for (final c in clamped) if (c is String) c];
  final range = names.any((c) => !kSlotClamps.contains(c));
  String? slot;
  for (final c in names) {
    if (kSlotClamps.contains(c)) {
      slot = _slotClampNotice[c];
      break;
    }
  }
  return (range: range, slot: slot);
}

// ------------------------------------------------------- the time-wise pill --

/// In the order the segment shows them — the same four words as the web.
const List<(String, String)> kMisBuckets = [
  ('day', 'Day-wise'),
  ('hour', 'Hour-wise'),
  ('hour_of_day', 'By hour of day'),
  ('session', 'By session'),
];

/// The segments this server can answer. The two newer ones arrived with the
/// presets route, so they are offered only once that route has answered.
List<(String, String)> timeWiseOptions(bool slotsAvailable) => slotsAvailable
    ? kMisBuckets
    : [for (final b in kMisBuckets) if (b.$1 == 'day' || b.$1 == 'hour') b];

/// An `hour_of_day` row's bucket (`13:00-14:00`, last `23:00-24:00`) as the
/// custom slot that narrows the report to that hour — or null when the text is
/// not one.
TimeSlotSelection? hourOfDaySlot(String bucket) {
  final m = RegExp(r'^(\d{2}:\d{2})\s*[-–]\s*(\d{2}:\d{2})$').firstMatch(bucket.trim());
  if (m == null) return null;
  final sel = TimeSlotSelection.custom(m.group(1)!, m.group(2)!);
  return sel.isAllDay ? null : sel;
}

/// The saved session a `session` row names (`Lunch (12:00-17:00)`), matched by
/// its times and its label — or null for "Outside sessions" and anything else
/// that is not one of [presets].
TimeSlotPreset? sessionRowPreset(String bucket, List<TimeSlotPreset> presets) {
  final m = RegExp(r'^(.*)\((\d{2}:\d{2})\s*[-–]\s*(\d{2}:\d{2})\)\s*$').firstMatch(bucket.trim());
  if (m == null) return null;
  final label = m.group(1)!.trim();
  for (final p in presets) {
    if (p.start == m.group(2) && p.end == m.group(3) && p.label == label) return p;
  }
  return null;
}

// -------------------------------------------------------------- the editor ----

/// One row of the "Manage sessions" sheet.
class TimeSlotDraft {
  const TimeSlotDraft({this.id, required this.label, required this.start, required this.end});

  /// Kept for a renamed session so its id (and any remembered pick) survives.
  final String? id;
  final String label;
  final String start;
  final String end;
}

/// The checks the editor can make before a round trip. The SERVER stays the
/// authority — overlap on the 24-hour circle and id collisions are its to
/// judge, and its 400 sentence is shown verbatim — but a blank name or "25:00"
/// is caught here, in the same words as the web.
String? validateSlotDrafts(List<TimeSlotDraft> drafts) {
  if (drafts.length > kMaxTimeSlots) return 'A restaurant can keep at most $kMaxTimeSlots sessions.';
  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    final name = d.label.trim();
    final which = name.isEmpty ? 'Session ${i + 1}' : name;
    if (name.isEmpty || name.length > kMaxTimeSlotLabel) {
      return '$which: a session needs a name of 1 to $kMaxTimeSlotLabel characters.';
    }
    if (parseClock(d.start) == null) return '$which: start time must be between 00:00 and 23:59.';
    final end = parseClock(d.end, allow24: true);
    if (end == null) return '$which: end time must be between 00:00 and 24:00.';
    if (parseClock(d.start) == end) return '$which: start and end cannot be the same time.';
  }
  return null;
}

/// The PUT body. An empty list is the server's "reset to the defaults".
Map<String, dynamic> slotDraftsBody(List<TimeSlotDraft> drafts) => {
      'slots': [
        for (final d in drafts)
          {
            if (d.id != null && d.id!.isNotEmpty) 'id': d.id,
            'label': d.label.trim(),
            'start': parseClock(d.start) == null ? d.start.trim() : formatClock(parseClock(d.start)!),
            'end': parseClock(d.end, allow24: true) == null
                ? d.end.trim()
                : formatClock(parseClock(d.end, allow24: true)!),
          },
      ],
    };

// -------------------------------------------------------------------- memory --

/// The reader's slot and the last presets the server sent, for the life of the
/// app session — exactly like [DateRangeMemory], and for the same reason:
/// "Dinner" is a question asked this afternoon, and tomorrow's first look
/// should open on the whole day. Remembering the CATALOGUE too means a remount
/// (every outlet switch remounts the module) sends the remembered slot on its
/// very first request instead of an all-day one thrown away.
///
/// The catalogue is kept PER RESTAURANT: presets are restaurant-wide, and a
/// second sign-in on this device must never be offered the first tenant's
/// sessions for the moment before its own arrive.
abstract final class TimeSlotMemory {
  static final Map<String, TimeSlotSelection> _byScreen = {};
  static final Map<String, TimeSlotCatalogue> _catalogues = {};

  static TimeSlotSelection of(String screen) => _byScreen[screen] ?? TimeSlotSelection.allDay;

  static void remember(String screen, TimeSlotSelection sel) => _byScreen[screen] = sel;

  static TimeSlotCatalogue? catalogueFor(String restaurant) => _catalogues[restaurant];

  static void rememberCatalogue(String restaurant, TimeSlotCatalogue catalogue) =>
      _catalogues[restaurant] = catalogue;

  /// Test seam — a suite must not inherit the previous test's slot.
  static void reset() {
    _byScreen.clear();
    _catalogues.clear();
  }
}
