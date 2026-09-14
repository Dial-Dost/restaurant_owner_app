/// THE PAYMENT MODES THIS RESTAURANT SETTLES WITH — the client half of
/// Restaurant_Backend/payment_methods.ts.
///
/// "There has to be an option to add mode of payments, it's not there." The
/// server now stores the modes in the restaurant's settings (`payment_methods`
/// on GET /restaurant/settings), built-ins and the owner's own alike, and both
/// this app and the web dashboard build every money picker from that one list.
/// This file is the only place the app turns it into pills.
///
/// WHAT IT KEEPS, each for money:
///   * A mode is SENT by its id and SHOWN by its label. A custom mode's id is the
///     name the owner typed and never changes, because it is what every bill
///     settled with it stores and what reports group by; renaming changes the
///     label only.
///   * Nothing is deleted: a mode is switched OFF (`enabled: false`) and is then
///     refused for new payments while its old bills keep their name.
///   * The naming rules below are a COURTESY COPY of the server's, so the editor
///     can say what is wrong before saving. The server refuses regardless (400,
///     with sentences the editor shows verbatim).
///   * A settle is NEVER blocked by a settings read: [PaymentModes.fallback] is
///     exactly what the server settles with for a restaurant with no config.
///
/// PURE: no widgets, no network — test/payment_modes_test.dart.
library;

class PaymentMode {
  const PaymentMode({
    required this.id,
    required this.label,
    this.enabled = true,
    this.requiresScreenshot = false,
    this.online = false,
    this.custom = false,
    this.showToGuests = true,
  });

  final String id;
  final String label;
  final bool enabled;
  final bool requiresScreenshot;
  final bool online;
  final bool custom;
  final bool showToGuests;

  PaymentMode copyWith({String? label, bool? enabled, bool? requiresScreenshot, bool? showToGuests}) => PaymentMode(
        id: id,
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
        requiresScreenshot: requiresScreenshot ?? this.requiresScreenshot,
        online: online,
        custom: custom,
        showToGuests: showToGuests ?? this.showToGuests,
      );

  /// The shape POST /restaurant/settings takes back. `online` is sent only so an
  /// older server reading this body sees what it always saw.
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'enabled': enabled,
        'requires_screenshot': requiresScreenshot,
        'online': online,
        'custom': custom,
        'show_to_guests': showToGuests,
      };

  static PaymentMode? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final label = '${raw['label'] ?? ''}'.trim();
    final custom = raw['custom'] == true;
    return PaymentMode(
      id: id,
      label: label.isEmpty ? id : label,
      enabled: raw['enabled'] != false,
      requiresScreenshot: raw['requires_screenshot'] == true,
      online: raw['online'] == true,
      custom: custom,
      // A custom mode is off the guest page unless the server says it is on.
      showToGuests: custom ? raw['show_to_guests'] == true : raw['show_to_guests'] != false,
    );
  }
}

class PaymentModes {
  PaymentModes._();

  static const int idMax = 32;
  static const int labelMax = 40;
  static const int maxCustom = 24;

  /// The backend's DEFAULT_PAYMENT_METHODS, verbatim.
  static const List<PaymentMode> fallback = [
    PaymentMode(id: 'Razorpay', label: 'Pay online (Razorpay)', online: true),
    PaymentMode(id: 'Upi', label: 'UPI'),
    PaymentMode(id: 'Cash', label: 'Cash'),
    PaymentMode(id: 'Card', label: 'Card'),
    PaymentMode(id: 'Dineout', label: 'Dineout', requiresScreenshot: true),
    PaymentMode(id: 'Zomato', label: 'Zomato', requiresScreenshot: true),
    PaymentMode(id: 'Eazydiner', label: 'EasyDiner', requiresScreenshot: true),
    PaymentMode(id: 'District', label: 'District', requiresScreenshot: true),
  ];

  /// A settings document's `payment_methods`, or [fallback] when it carries
  /// none (an older server, a failed read, a malformed body).
  static List<PaymentMode> parse(Object? raw) {
    if (raw is! List) return List.of(fallback);
    final out = <PaymentMode>[for (final m in raw) ?PaymentMode.fromJson(m)];
    return out.isEmpty ? List.of(fallback) : out;
  }

  /// What a cashier may settle with at the till: ON and not the online gateway.
  /// The same rule the web dashboard's settle submenu uses.
  static List<PaymentMode> till(List<PaymentMode> modes) =>
      [for (final m in modes) if (m.enabled && !m.online) m];

  /// Case- and punctuation-insensitive — the server's paymentNameKey.
  static String key(String? raw) => (raw ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static const Map<String, String> _builtinAliases = {
    'upi': 'Upi', 'cash': 'Cash', 'card': 'Card', 'dineout': 'Dineout', 'dine out': 'Dineout',
    'zomato': 'Zomato', 'zomato pay': 'Zomato', 'zomatopay': 'Zomato', 'eazydiner': 'Eazydiner',
    'easydiner': 'Eazydiner', 'easy diner': 'Eazydiner', 'district': 'District', 'razorpay': 'Razorpay',
    'split': 'Split',
  };
  static final Map<String, String> _aliasKeys = {
    for (final e in _builtinAliases.entries) key(e.key): e.value,
  };
  static const List<String> _notMoneyComp = [
    'complimentary', 'comp', 'comps', 'nc', 'foc', 'non chargeable', 'nonchargeable', 'staff meal', 'staff meals',
  ];
  static const List<String> _notMoneyCredit = ['credit', 'on account', 'due', 'pay later', 'paylater'];
  static final Set<String> _compKeys = _notMoneyComp.map(key).toSet();
  static final Set<String> _creditKeys = _notMoneyCredit.map(key).toSet();
  static final Set<String> _bucketKeys = {'split', 'other', 'unallocated'}.map(key).toSet();
  static final RegExp _idCharset = RegExp(r"^[A-Za-z0-9 &+.\-/()']+$");

  static List<String> _words(String raw) =>
      raw.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();

  static bool _phraseAt(List<String> words, String phrase, int i) {
    final p = _words(phrase);
    for (var j = 0; j < p.length; j++) {
      if (i + j >= words.length || words[i + j] != p[j]) return false;
    }
    return true;
  }

  /// Whether a name says it is NOT money collected: 'comp' (free food booked as
  /// sales and tax), 'credit' (a bill closed as paid with nothing received), or
  /// null. The server's notMoneyKind, word for word: whole words anywhere in the
  /// name ("Staff Meals", "Due Payment", "Credit/Due" are refused; "Company Card"
  /// and "Duet Pay" are not), plus the whole-name key ("N/C"). "credit" with
  /// "card" after it is a credit CARD — money the acquirer pays out.
  static String? notMoneyKind(String name) {
    final k = key(name);
    if (_compKeys.contains(k)) return 'comp';
    if (_creditKeys.contains(k)) return 'credit';
    final words = _words(name);
    for (var i = 0; i < words.length; i++) {
      if (_notMoneyComp.any((p) => _phraseAt(words, p, i))) return 'comp';
    }
    for (var i = 0; i < words.length; i++) {
      for (final p in _notMoneyCredit) {
        if (!_phraseAt(words, p, i)) continue;
        if (p == 'credit' && words.skip(i + 1).any((w) => w == 'card' || w == 'cards')) continue;
        return 'credit';
      }
    }
    return null;
  }

  /// What a REPORT row calls its mode: the label the server attached (Settings >
  /// Payments), else the stored id, else [fallback]. Display only — the rows
  /// group, and the closed-bill filter matches, on `method`.
  static String reportName(Map row, [String fallback = 'Other']) {
    final label = '${row['label'] ?? ''}'.trim();
    if (label.isNotEmpty) return label;
    final method = '${row['method'] ?? ''}'.trim();
    return method.isEmpty ? fallback : method;
  }

  static PaymentMode? find(String? method, List<PaymentMode> modes) {
    final k = key(method);
    if (k.isEmpty) return null;
    for (final m in modes) {
      if (key(m.id) == k) return m;
    }
    final alias = _aliasKeys[k];
    if (alias == null) return null;
    for (final m in modes) {
      if (!m.custom && m.id == alias) return m;
    }
    return null;
  }

  /// The owner's name for a stored method; the stored string when unknown.
  static String labelFor(String? method, List<PaymentMode> modes) {
    final s = (method ?? '').trim();
    if (s.isEmpty) return '';
    return find(s, modes)?.label ?? s;
  }

  /// Whether settling with [method] needs a payment screenshot — the config's rule.
  static bool needsScreenshot(String? method, List<PaymentMode> modes) =>
      find(method, modes)?.requiresScreenshot == true;

  /// Collapse whitespace and trim — the spelling a name is stored in.
  static String tidy(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Why [rawName] cannot be a new mode here, or null. Sentences match the server's.
  static String? newModeRefusal(String rawName, List<PaymentMode> modes) {
    final name = tidy(rawName);
    if (name.isEmpty) return 'Give the payment mode a name.';
    final k = key(name);
    if (k.isEmpty) return '"$name" needs at least one letter or number.';
    final notMoney = notMoneyKind(name);
    if (notMoney == 'comp') {
      return '"$name" can\'t be a payment mode: a free meal is not money collected, and settling it as '
          'paid books it as sales and tax. Use "Mark as non-chargeable" on the bill instead.';
    }
    if (notMoney == 'credit') {
      return '"$name" can\'t be a payment mode: it would close the bill as paid while no money has arrived.';
    }
    if (_bucketKeys.contains(k)) {
      return '"$name" can\'t be a payment mode: reports already use that name for their own rows.';
    }
    final builtin = _aliasKeys[k];
    if (builtin != null) {
      return '"$name" is already a built-in payment mode ($builtin). Rename or switch on the built-in one '
          'instead of adding a copy.';
    }
    if (name.length > idMax) {
      return '"$name" is too long — a payment mode name can be at most $idMax characters.';
    }
    if (!_idCharset.hasMatch(name)) {
      return '"$name" has characters a payment mode name can\'t use. Letters, numbers, spaces and '
          '& + . - / ( ) \' are allowed.';
    }
    for (final m in modes) {
      if (key(m.id) == k || key(m.label) == k) {
        return m.enabled
            ? 'This restaurant already has "${m.label}".'
            : 'This restaurant already has "${m.label}" — it is switched off. Switch it back on instead of adding it again.';
      }
    }
    if (modes.where((m) => m.custom).length >= maxCustom) {
      return 'A restaurant can have at most $maxCustom payment modes of its own. Switch off one you no longer '
          'use and rename it instead of adding another.';
    }
    return null;
  }

  /// Why [rawLabel] cannot label mode [id], or null. Empty means "back to the default".
  static String? labelRefusal(String rawLabel, String id, List<PaymentMode> modes) {
    final label = tidy(rawLabel);
    if (label.isEmpty) return null;
    if (label.length > labelMax) return 'A label can be at most $labelMax characters.';
    final k = key(label);
    final notMoney = notMoneyKind(label);
    if (notMoney == 'comp') {
      return '"$label" can\'t be used as a label: a free meal is not money collected — use "Mark as non-chargeable" on the bill instead.';
    }
    if (notMoney == 'credit') {
      return '"$label" can\'t be used as a label: it would close the bill as paid while no money has arrived.';
    }
    if (_bucketKeys.contains(k)) {
      return '"$label" can\'t be used as a label: reports already use that name for their own rows.';
    }
    final aliasOf = _aliasKeys[k];
    if (aliasOf != null && key(aliasOf) != key(id)) {
      return '"$label" can\'t label $id: that is the name of the built-in $aliasOf mode.';
    }
    for (final m in modes) {
      if (m.id != id && (key(m.label) == k || key(m.id) == k)) {
        return '"$label" is already used by ${m.label}. Give each mode a different label.';
      }
    }
    return null;
  }

  /// [modes] with a new custom mode appended — what the editor saves.
  static List<PaymentMode> withCustom(
    List<PaymentMode> modes, {
    required String name,
    required bool requiresScreenshot,
    required bool showToGuests,
  }) {
    final id = tidy(name);
    return [
      ...modes,
      PaymentMode(
        id: id,
        label: id,
        requiresScreenshot: requiresScreenshot,
        custom: true,
        showToGuests: showToGuests,
      ),
    ];
  }
}
