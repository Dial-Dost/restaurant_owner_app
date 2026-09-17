import 'dart:async';

import 'package:flutter/material.dart';

import '../gaia/gaia.dart';
import '../theme/app_colors.dart';

/// CLIENT ITEM 6 (2.0.2) — the one search box for the whole app.
///
/// "Pressing the x does not clear the search. It only works in the menu
/// section." It was never one bug. Every screen hand-rolled its own box, so
/// each could get the x wrong its own way, and they did: an x that reset the
/// filter but left the word in the box (the order pad in 2.0.0), no x at all
/// (Guests, the audit trail, the timezone and tag-dishes dialogs), an x that
/// only turned up after the debounce (Settled bills), a 24x16 target beside the
/// field instead of in it (the Gaia Guests box), and a Menu search that any
/// shell rebuild — the phone keyboard closing, a window resize — wiped.
///
/// So the rules live here, once, and a screen can no longer break them:
///
///  1. The box's text lives in ONE controller, and the only thing that turns
///     it into a query is a listener on that controller. Typing, the x, Escape,
///     a screen's "Clear filters" calling `controller.clear()`, select-all and
///     delete: all of them change the controller, so all of them reach
///     [onQuery]. There is no `onChanged` path for a screen to forget.
///  2. An empty box is never debounced. It cancels whatever is pending and
///     emits '' at once, so an x pressed inside the debounce window cannot be
///     followed by the old word landing a moment later.
///  3. The x is an [IconButton] in the field's own suffix slot: a real 40-48px
///     target, inside the field's tap region (so a mouse click on Windows is
///     not "a tap outside" that drops focus), and drawn whenever the BOX has
///     text, whatever the debounce is doing. Pressing it clears the box and
///     keeps the focus there, because the next thing anyone does is type the
///     next word.
///  4. Nothing re-seeds the text from outside. [initialQuery] is read once;
///     a parent rebuild cannot put a stale word back or wipe a live one.
///  5. One widget for both design systems. Gaia changes how it looks, never
///     how it clears.
///  6. A word waiting out the debounce is not lost when the box is built away.
///     While it waits, the box asks a lazily built list to keep it alive, as a
///     focused TextField already does, so a fling past the list's cache
///     (Settled bills, the Gaia guest list) still delivers it. And what the
///     screen has heard is kept with the CONTROLLER, not with this State: a box
///     built afresh over the same controller waits out a word its screen never
///     heard, instead of taking it as sent. Nothing is sent once the box is
///     gone, because the screen may be going with it.
///
/// Escape clears a box that has text. On an empty box it is passed on,
/// exactly as before: a dialog still closes, and the shell's back trail still
/// stays off a focused text field.
///
/// A screen passes its own [controller] when something else on the screen
/// clears the search too (the audit trail's "Clear filters"), or when the box
/// can be built away and back while the search should survive (a lazily built
/// list, a field shown only for some reports). The screen owns and disposes
/// it; otherwise the field owns one.
///
/// Every call site names a [testId]: the TextField is keyed `testId`, the x
/// `'$testId-clear'`, and test/search_clear_registry_test.dart refuses a
/// testId that has no contract row.
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    required this.testId,
    required this.onQuery,
    this.hint,
    this.label,
    this.controller,
    this.initialQuery = '',
    this.debounce = Duration.zero,
    this.autofocus = false,
    this.compact = false,
  }) : assert(hint != null || label != null, 'a search box says what it searches');

  final String testId;

  /// The query: trimmed, sent only when it changes, and '' the moment the box
  /// is emptied.
  final ValueChanged<String> onQuery;

  final String? hint;

  /// A floating label instead of (or as well as) the hint, for the dialogs
  /// whose boxes always had one.
  final String? label;

  final TextEditingController? controller;

  /// The text an owned controller starts with. Read once, never again.
  final String initialQuery;

  /// How long typing waits before [onQuery] hears it — for the boxes that ask
  /// the server. Clearing never waits.
  final Duration debounce;

  final bool autofocus;

  /// The reports toolbar's smaller box (13px text, 16px glyph).
  final bool compact;

  /// The tooltip, and the words a screen reader says, on the x.
  static const String clearTooltip = 'Clear search';

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> with AutomaticKeepAliveClientMixin<AppSearchField> {
  TextEditingController? _owned;
  late TextEditingController _c;
  final FocusNode _focus = FocusNode(debugLabel: 'AppSearchField');
  late final Map<Type, Action<Intent>> _actions = {DismissIntent: _EscapeClears(this)};
  Timer? _pending;

  /// What each controller's screen has last been told, by whichever box was
  /// showing it. Weak, so a controller that is dropped takes its entry along.
  static final Expando<String> _heardBy = Expando<String>('AppSearchField.heard');

  /// The last query [AppSearchField.onQuery] was given for [_c].
  ///
  /// This used to live on the State and start as the controller's text, on the
  /// grounds that a screen already knows what its own controller holds. That
  /// is true only while no box has had a word in it waiting. A box built away
  /// mid-debounce took the word with it unsent, and the next box over the same
  /// controller took it as sent. That box then showed "102" and its x over an
  /// unfiltered list, and Enter did nothing, since "102" was the query it
  /// believed was out already.
  String get _heard => _heardBy[_c] ?? '';
  set _heard(String query) => _heardBy[_c] = query;

  /// The text the listener last acted on. The controller also notifies on a
  /// caret move, which must not restart the debounce.
  late String _seen;

  /// Keep this box while a word waits: a lazily built list would otherwise
  /// dispose it, and the word, once it scrolled past the cache.
  @override
  bool get wantKeepAlive => _pending != null;

  @override
  void initState() {
    super.initState();
    _c = widget.controller ?? (_owned = TextEditingController(text: widget.initialQuery));
    _listen();
  }

  @override
  void didUpdateWidget(AppSearchField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      // A screen that hands over a different controller knows what it holds,
      // so it is taken as a fresh start rather than as an edit to report.
      // Handed back to an owned one, the box keeps its text, and with it what
      // the screen has heard of that text.
      _stopWaiting();
      _c.removeListener(_onText);
      final text = _c.text;
      final heard = _heardBy[_c];
      _owned?.dispose();
      _owned = null;
      final given = widget.controller;
      if (given != null) {
        _c = given;
      } else {
        _c = _owned = TextEditingController(text: text);
        _heardBy[_c] = heard;
      }
      _listen();
    }
    // Deliberately no `if (widget.initialQuery != _c.text) _c.text = ...`: that
    // re-seed is what let a shell rebuild wipe the Menu search.
  }

  /// Starts on [_c]. A controller no box has shown before is the screen's own
  /// start, so the screen knows what it holds: it is not news. A controller an
  /// earlier box showed says what its screen heard, and a word the screen has
  /// not heard is waited out again here, as if it had just been typed.
  void _listen() {
    _seen = _c.text;
    final query = _c.text.trim();
    final heard = _heardBy[_c];
    if (heard == null) {
      _heard = query;
    } else if (heard != query) {
      // Never sent from here: this runs inside a build, and the screen's
      // setState is not allowed until it ends. So even an emptied box waits
      // one timer tick.
      _wait(query.isEmpty ? Duration.zero : widget.debounce);
    }
    _c.addListener(_onText);
  }

  @override
  void dispose() {
    // A word still waiting is dropped here, not sent. A lazy list keeps the
    // box while a word waits, so what gets here mid-wait is a box whose screen
    // may be going too, and a screen's onQuery must not run after that. A box
    // built again over the same controller picks the word up (see _listen).
    _pending?.cancel();
    _pending = null;
    _c.removeListener(_onText);
    _owned?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _wait(Duration delay) {
    final wasWaiting = _pending != null;
    _pending?.cancel();
    _pending = Timer(delay, () {
      _pending = null;
      updateKeepAlive();
      _send(_c.text.trim());
    });
    if (!wasWaiting) updateKeepAlive();
  }

  void _stopWaiting() {
    if (_pending == null) return;
    _pending!.cancel();
    _pending = null;
    updateKeepAlive();
  }

  void _onText() {
    final text = _c.text;
    if (text == _seen) return;
    final hadText = _seen.isNotEmpty;
    _seen = text;
    if (hadText != text.isNotEmpty) setState(() {/* the x comes or goes */});
    if (text.trim().isEmpty) {
      _stopWaiting();
      _send('');
    } else if (widget.debounce == Duration.zero) {
      _stopWaiting();
      _send(text.trim());
    } else {
      _wait(widget.debounce);
    }
  }

  void _send(String query) {
    if (!mounted || query == _heard) return;
    _heard = query;
    widget.onQuery(query);
  }

  void _submit(String text) {
    _stopWaiting();
    _send(text.trim());
  }

  void _clear() {
    _c.clear(); // the listener sends '' and takes the x away
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // the keep-alive above
    final gaia = Gaia.of(context);
    final compact = widget.compact;
    final glyph = compact ? 16.0 : 18.0;
    final size = compact ? 13.0 : 14.0;
    final dim = gaia ? GaiaColors.text3AA : AppColors.textTertiary;
    final field = TextField(
      key: ValueKey(widget.testId),
      controller: _c,
      focusNode: _focus,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      style: gaia
          ? GaiaType.sans(size: size, color: GaiaColors.text)
          : compact
              ? TextStyle(fontSize: size)
              : null,
      cursorColor: gaia ? GaiaColors.champagne : null,
      cursorWidth: gaia ? 1 : 2,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        labelText: widget.label,
        hintStyle: gaia ? GaiaType.sans(size: size, color: GaiaColors.text3AA) : null,
        prefixIcon: Icon(Icons.search, size: glyph, color: dim),
        prefixIconConstraints: compact ? const BoxConstraints(minWidth: 34, minHeight: 30) : null,
        contentPadding: compact ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10) : null,
        suffixIcon: _c.text.isEmpty
            ? null
            : IconButton(
                key: ValueKey('${widget.testId}-clear'),
                tooltip: AppSearchField.clearTooltip,
                icon: Icon(Icons.close, size: glyph),
                onPressed: _clear,
              ),
      ),
    );
    return Actions(actions: _actions, child: field);
  }
}

/// Escape: clears a box that has text; on an empty one, hands the key to
/// whoever would have had it without this field (a dialog closes, the shell's
/// guard keeps it off the back trail).
///
/// It has to be enabled either way and forward by hand. `Actions.invoke` stops
/// at the FIRST mapping it meets, enabled or not, so an action that merely
/// switched itself off on an empty box would swallow the Escape that used to
/// close the dialog around it.
class _EscapeClears extends Action<DismissIntent> {
  _EscapeClears(this._field);

  final _AppSearchFieldState _field;

  @override
  Object? invoke(DismissIntent intent) {
    if (_field._c.text.isNotEmpty) {
      _field._clear();
      return null;
    }
    // The field's own context sits above this Actions widget, so the search
    // starts at the ancestors a plain TextField would have reached.
    return Actions.maybeInvoke<DismissIntent>(_field.context, intent);
  }
}
