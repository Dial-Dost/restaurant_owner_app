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
//   'reference'  the reference docket, drawn as an image. What NULL, a missing
//                key and anything unrecognised mean.
//   'classic'    the plain ESC/POS text docket — the escape hatch for a kitchen
//                printer that answers an image with BLANK PAPER. On a kitchen
//                printer a blank ticket is an order nobody cooks, so this switch
//                is a recovery control, not a preference.
//
// kot_text_size
//   'small' | 'standard' | 'large'. The client, having printed the reference
//   docket: "The font sizes must be smaller in the KOT." Standard is their
//   reference ticket exactly, and what NULL / a missing key / anything
//   unrecognised mean. IT SIZES THE REFERENCE DOCKET ONLY: the classic text
//   docket prints in the printer's own font and ignores it.
//
// READS FORGIVE, WRITES ARE EXACT. A settings document from a backend that has
// never heard of either key reads as what that backend prints — the reference
// docket, standard size. A save only ever sends one of the listed words, which
// the backend accepts; anything else it refuses with a 400.
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
/// else — including an absent key — is the reference docket.
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
    detail: 'The plain ticket this system printed before. Use it if the new one does not print.',
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
    'and ignores this setting.';

/// Shown under the size choice while the classic docket is the selected style.
const String kotTextSizeClassicNote =
    'Your kitchens are on the classic text docket, so this size is not used until you switch back.';

/// The card's title, its one-line description, and the second control's
/// heading — the web card's CardTitle, CardDescription and Label.
const String kotPrintStyleTitle = 'KOT print style';
const String kotPrintStyleDescription = 'How kitchen dockets are printed. This does not change the customer bill.';
const String kotTextSizeTitle = 'KOT text size';

/// The label a stored word is shown with (the word itself if it is not listed).
String kotDocketOptionLabel(List<KotDocketOption> options, String value) {
  for (final o in options) {
    if (o.value == value) return o.label;
  }
  return value;
}

/// The settings keys the two controls write — one key per save, exactly as the
/// web card sends them.
const String kotPrintStyleKey = 'kot_print_style';
const String kotTextSizeKey = 'kot_text_size';

/// What a save actually stored.
///
/// POST /restaurant/settings answers with the whole settings document, so the
/// stored word is read back from it, on the read rules above. A reply that does
/// not carry the key at all (an older backend, a test double) proves nothing
/// either way, so the word that was sent stands — it is one the backend
/// accepts, or the save would have been refused.
String kotDocketSaved(Object? reply, String key, String sent) {
  if (reply is! Map || !reply.containsKey(key)) return sent;
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
