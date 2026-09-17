// THE TWO KITCHEN DOCKET SETTINGS — which docket a restaurant prints, and how
// large the reference docket's type is.
//
// Both live on "Restaurant" and travel in the GET/POST /restaurant/settings
// document (migration 050); the backend's kot_print_style.ts holds the same
// words and the same rules, and the web dashboard's src/lib/kot-print-style.ts
// offers the same choices in the SAME WORDS. The three must not drift: an owner
// who reads "Standard — matches your reference docket" on the web and something
// else here would reasonably wonder whether they are the same setting.
//
// kot_print_style
//   'reference'  the reference docket, drawn as an image. What a NULL column
//                and anything unrecognised mean.
//   'classic'    the plain ESC/POS text docket — the escape hatch for a kitchen
//                printer that answers an image with BLANK PAPER. On a kitchen
//                printer a blank ticket is an order nobody cooks, so this switch
//                is a recovery control, not a preference.
//
// kot_text_size
//   'small' | 'standard' | 'large'. The client, having printed the reference
//   docket: "The font sizes must be smaller in the KOT." Standard is their
//   reference ticket exactly, and what a NULL column / anything
//   unrecognised mean. IT SIZES THE REFERENCE DOCKET ONLY: the classic text
//   docket prints in the printer's own font, at its normal size (never
//   stretched — client item 5), and ignores it.
//
// READS FORGIVE, WRITES ARE EXACT. A stored value this app does not recognise
// reads as the default. A save only ever sends one of the listed words, which
// the backend accepts; anything else it refuses with a 400.
//
// A BACKEND THAT HAS NEVER HEARD OF EITHER KEY IS NOT "THE DEFAULT". The backend
// that was live before these settings (and any backend rolled back to it) sends
// neither key and prints ONLY the classic text docket, in the printer's own
// font — so reading its document forgivingly would show "Match the reference
// docket" and "Standard" to an owner whose kitchen prints neither. And its
// POST /restaurant/settings ignores keys it does not know: a pick is answered
// 200 with nothing stored. So:
//   * the card is shown only when the settings document carries BOTH keys
//     ([kotDocketSettingsSupported]) — this backend always sends both, even
//     before migration 050 is applied by hand;
//   * a save whose reply is a settings document WITHOUT the key stored nothing,
//     and [kotDocketSaved] says so rather than confirming the pick.
// The web card does the same (src/lib/kot-print-style.ts), in the same words.
//
// PURE: no Flutter, no network.

const String kotPrintStyleReference = 'reference';
const String kotPrintStyleClassic = 'classic';

/// Every style, in the order the Settings card offers them.
const List<String> kotPrintStyles = [kotPrintStyleReference, kotPrintStyleClassic];

/// What a restaurant that has never chosen prints.
const String kotPrintStyleDefault = kotPrintStyleReference;

/// Every text size, smallest first — the order the Settings card offers them.
const List<String> kotTextSizes = ['small', 'standard', 'large'];

/// What a restaurant that has never chosen prints: the client's reference ticket.
const String kotTextSizeDefault = 'standard';

/// The style out of a /restaurant/settings document. Exact words only; anything
/// else is the reference docket. (A document with no key at all is a backend
/// without the setting — ask [kotDocketSettingsSupported] before showing this.)
String readKotPrintStyle(Map settings) {
  final v = settings['kot_print_style'];
  return kotPrintStyles.contains(v) ? v as String : kotPrintStyleDefault;
}

/// The text size out of a /restaurant/settings document, on the same terms.
String readKotTextSize(Map settings) {
  final v = settings['kot_text_size'];
  return kotTextSizes.contains(v) ? v as String : kotTextSizeDefault;
}

/// One choice on the card: the word the backend stores, and the owner's words.
typedef KotDocketOption = ({String value, String label, String detail});

/// The style choices — word for word the web card's KOT_PRINT_STYLE_OPTIONS.
const List<KotDocketOption> kotPrintStyleOptions = [
  (
    value: kotPrintStyleReference,
    label: 'Match the reference docket (recommended)',
    detail: 'Clear type, laid out like the printed ticket you approved. Its size is set below.',
  ),
  (
    value: kotPrintStyleClassic,
    label: 'Classic text docket',
    detail: "Plain text in the printer's own font, at its normal size. Use it if the new one does not print.",
  ),
];

/// The sentence under the style choice — the web card's KOT_PRINT_STYLE_HELP.
const String kotPrintStyleHelp =
    'The new docket prints as an image, which almost every thermal printer supports. '
    'If a kitchen printer prints a blank ticket, switch back to the classic text docket here '
    'and the next KOT prints as text again.';

/// The size choices — word for word the web card's KOT_TEXT_SIZE_OPTIONS.
const List<KotDocketOption> kotTextSizeOptions = [
  (value: 'small', label: 'Small', detail: 'A size down: more of a long order fits on less paper.'),
  (
    value: 'standard',
    label: 'Standard — matches your reference docket',
    detail: 'The same size as the printed ticket you approved.',
  ),
  (
    value: 'large',
    label: 'Large',
    detail: 'A size up, for a pass read from further away. Long dish names wrap sooner.',
  ),
];

/// The sentence under the size choice — the web card's KOT_TEXT_SIZE_HELP.
const String kotTextSizeHelp =
    "Applies to the new docket only. The classic text docket prints in the printer's own font "
    'at its normal size, and ignores this setting.';

/// Shown under the size choice while the classic docket is the selected style.
const String kotTextSizeClassicNote =
    'Your kitchens are on the classic text docket, so this size is not used until you switch back.';

/// The card's title, its one-line description, and the second control's
/// heading — the web card's CardTitle, CardDescription and Label.
const String kotPrintStyleTitle = 'KOT print style';
const String kotPrintStyleDescription = 'How kitchen dockets are printed. This does not change the customer bill.';
const String kotTextSizeTitle = 'KOT text size';

/// The settings keys the two controls write — one key per save, exactly as the
/// web card sends them.
const String kotPrintStyleKey = 'kot_print_style';
const String kotTextSizeKey = 'kot_text_size';

/// Where the Settings loader records [kotDocketSettingsSupported] in the page's
/// payload. The app's own key — no backend sends it.
const String kotDocketSupportedKey = 'kot_docket_supported';

/// Whether this backend has the two docket settings at all: its settings
/// document carries BOTH keys. The one live before them sends neither and
/// prints only the classic docket, so the card is not shown against it.
bool kotDocketSettingsSupported(Object? settings) =>
    settings is Map && settings.containsKey(kotPrintStyleKey) && settings.containsKey(kotTextSizeKey);

/// The sentence a save shows when the server stored nothing — the web card's
/// KOT_DOCKET_NOT_SUPPORTED.
const String kotDocketNotSupported = 'This server does not support this setting yet, so nothing was saved.';

/// Thrown by [kotDocketSaved] for a reply that proves nothing was stored. Its
/// text is the owner's sentence, so the card can show it as it shows any error.
class KotDocketNotStored implements Exception {
  const KotDocketNotStored();
  @override
  String toString() => kotDocketNotSupported;
}

/// What a save actually stored.
///
/// POST /restaurant/settings answers with the whole settings document, so the
/// stored word is read back from it, on the read rules above. A settings
/// document WITHOUT the key comes from a backend that ignored it — an older one,
/// or one rolled back since the card loaded — so nothing was stored and this
/// throws [KotDocketNotStored]; the card puts the old choice back and says so.
/// A reply that is not a document at all says nothing either way, so the word
/// that was sent stands (it is one the backend accepts, or the save would have
/// been refused) — as the web reads an unparseable reply.
String kotDocketSaved(Object? reply, String key, String sent) {
  if (reply is! Map) return sent;
  if (!reply.containsKey(key)) throw const KotDocketNotStored();
  return key == kotPrintStyleKey ? readKotPrintStyle(reply) : readKotTextSize(reply);
}

/// The sentence a successful save shows — the web card's toast descriptions.
///
/// A size saved while the kitchens are on the classic docket says it is kept for
/// later, because nothing on the paper changes until the style is switched back.
String kotDocketSavedMessage(String key, String saved, {required String style}) {
  if (key == kotPrintStyleKey) {
    return saved == kotPrintStyleClassic
        ? 'The next kitchen docket prints as plain text.'
        : 'The next kitchen docket prints in the reference layout.';
  }
  return style == kotPrintStyleClassic
      ? 'Saved. It applies when the kitchen is back on the new docket.'
      : 'The next kitchen docket prints at the $saved size.';
}

// ---------------------------------------------------------------------------
// "PRINT A TEST KOT" — the card's third control (client item 5).
//
// The server has always had POST /print/test (the Print permission). It prints
// one slip in THIS restaurant's docket style and text size, on its own roll,
// through the routing a real ticket takes — the answer to "what will the
// kitchen get?" after changing either setting. Nothing called it; the web card
// and this card now do, in the same words (src/lib/kot-print-style.ts).
//
// ONLINE ONLY: every /print write is refused offline by OutboxPolicy (never
// queued — a test slip printed an hour late tests nothing), and the card shows
// [kotTestPrintOffline] for it. The SERVER's queue is the one exception, and
// the card says so ([kotTestPrintReplayNote]): a slip that went to every device
// and none printed is kept for `replayMinutes` (five) for a kitchen device that
// connects late — one per role, the newest — and dropped after that. ONE TAP,
// ONE SLIP: the button is disabled while the request is out. A REFUSAL (403
// without the Print permission) is shown in the server's own sentence.
//
// NEVER DURING A SAVE, AND NO SAVE DURING A TEST ([kotDocketLocks]). The server
// reads the style and size when it builds the slip, and a pick moves the card
// before its save lands — so a test pressed mid-save prints the setting the
// card has already moved away from, under "the style and size chosen above".
// ---------------------------------------------------------------------------

/// The existing route, and the one body the card sends to it.
const String kotTestPrintPath = '/print/test';
const Map<String, String> kotTestPrintBody = {'role': 'kot'};

const String kotTestPrintLabel = 'Print a test KOT';
const String kotTestPrintSending = 'Sending a test KOT…';
const String kotTestPrintHelp =
    'Sends one test docket to the kitchen printer in the style and size chosen above, '
    'so you can check the paper before service.';
const String kotTestPrintSentTitle = 'Test KOT sent';
const String kotTestPrintFailedTitle = "Couldn't print a test KOT";
const String kotTestPrintOffline = 'A test KOT needs a connection — reconnect and try again.';

/// What the server did with the slip, in one sentence — the web card's
/// kotTestPrintOutcome, word for word.
///
/// POST /print/test answers `{results: [{role, mode, reason, destination, …}]}`.
/// 'directed' went to one named printer; 'broadcast' went to every connected
/// device, each printing it on its own kitchen printer — and when the routed
/// printer's device is offline, the owner should know that is why. A reply this
/// card cannot read still means the request was accepted.
String kotTestPrintOutcome(Object? reply) {
  final raw = reply is Map ? reply['results'] : null;
  if (raw is! List) return "Sent. Check the kitchen printer's paper.";
  final results = raw.whereType<Map>().toList();
  if (results.isEmpty) return 'Nothing was sent to print.';
  final first = results.first;
  final d = first['destination'];
  final destination = d is String && d.trim().isNotEmpty ? d.trim() : null;
  if (first['mode'] == 'directed') {
    return 'Sent to ${destination ?? 'the kitchen printer'}. Check the paper there.';
  }
  if (first['reason'] == 'no_device_online' && destination != null) {
    return '$destination is not online, so every connected device with a kitchen printer '
        'was asked to print it. Check the paper. ${kotTestPrintReplayNote(reply)}';
  }
  return 'Every connected device with a kitchen printer was asked to print it. Check the paper. '
      '${kotTestPrintReplayNote(reply)}';
}

/// What becomes of a broadcast slip that no device printed — the web card's
/// kotTestPrintReplayNote, word for word.
///
/// The server keeps it for the `replayMinutes` its reply names, for the first
/// kitchen device that connects late, and never after. A reply without the
/// number (a backend before the window) may keep it far longer, so this says
/// only that it may still print.
String kotTestPrintReplayNote(Object? reply) {
  final raw = reply is Map ? reply['replayMinutes'] : null;
  // A whole, positive number of minutes — as the web reads it (Number.isInteger),
  // so 5.0 counts and 2.5, '5' or infinity do not.
  if (raw is num && raw.isFinite && raw > 0 && raw == raw.roundToDouble()) {
    final minutes = raw.toInt();
    return 'If nothing came out, it prints on the first kitchen device to connect within '
        '$minutes minute${minutes == 1 ? '' : 's'}, and not after that.';
  }
  return 'If nothing came out, it may still print when a kitchen device connects.';
}

/// Which of the card's controls are off — the web card's kotDocketCardLocks.
typedef KotDocketLocks = ({bool choicesDisabled, bool testDisabled});

/// THE CARD'S CONTROLS LOCK EACH OTHER OUT (see "never during a save" above).
/// The test button waits out the load, any save and its own request, but never
/// the settings permission (the route checks the Print one); the choices wait
/// out the load, any save and a test in flight. This app's card is admin-only
/// and seeded before it is built, so it passes the defaults for those two.
KotDocketLocks kotDocketLocks({
  bool canEdit = true,
  bool loading = false,
  required bool saving,
  required bool testing,
}) =>
    (
      choicesDisabled: !canEdit || loading || saving || testing,
      testDisabled: loading || saving || testing,
    );

/// The snackbar lines: the web toast's title and description, on one line.
String kotTestPrintSentMessage(Object? reply) => '$kotTestPrintSentTitle — ${kotTestPrintOutcome(reply)}';
String kotTestPrintFailedMessage(String sentence) => '$kotTestPrintFailedTitle — $sentence';
