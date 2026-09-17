import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/app_search_field.dart';

import 'search_contract.dart';

/// CLIENT ITEM 6 (2.0.2) — the shared search box on its own: the rules
/// test/search_contract.dart holds every screen to, pinned one at a time
/// where a screen could not show them cleanly (exact emissions, timings, a
/// parent that rebuilds, a controller handed over, Escape in a dialog).

final _field = find.byKey(const ValueKey('probe'));
final _x = find.byKey(const ValueKey('probe-clear'));

/// A screen shaped like the app's: a box, whatever it has sent, and a parent
/// that rebuilds with a changing initial query.
class _Host extends StatefulWidget {
  const _Host({required this.sent, this.debounce = Duration.zero, this.controller, this.compact = false});

  final List<String> sent;
  final Duration debounce;
  final TextEditingController? controller;
  final bool compact;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String initial = '';
  TextEditingController? controller;

  @override
  void initState() {
    super.initState();
    controller = widget.controller;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AppSearchField(
          testId: 'probe',
          hint: 'Search probes…',
          debounce: widget.debounce,
          controller: controller,
          initialQuery: initial,
          compact: widget.compact,
          onQuery: widget.sent.add,
        ),
        TextButton(
          key: const ValueKey('rebuild-with-initial'),
          onPressed: () => setState(() => initial = 'stale'),
          child: const Text('rebuild'),
        ),
      ]),
    );
  }
}

Future<void> _pump(WidgetTester tester, Widget body, {DesignSystem ds = DesignSystem.rustic}) async {
  useSearchView(tester);
  await tester.pumpWidget(searchThemed(ds, Scaffold(body: body)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing waits out the debounce; emptying the box does not wait at all', (tester) async {
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent, debounce: const Duration(milliseconds: 300)));
    await tester.enterText(_field, 'd');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(_field, 'dal');
    await tester.pump(const Duration(milliseconds: 299));
    expect(sent, isEmpty, reason: 'a keystroke is not a query');
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, ['dal']);

    // Emptied — by select-all and delete, not only the x — and heard in the
    // same frame.
    await tester.enterText(_field, '');
    expect(sent, ['dal', '']);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['dal', ''], reason: 'nothing may land after the box was emptied');
  }, variant: searchPlatforms);

  testWidgets('the x inside the debounce window: the word it cleared never lands', (tester) async {
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent, debounce: const Duration(milliseconds: 300)));
    await tester.enterText(_field, 'dal');
    await tester.pump(const Duration(milliseconds: 100));
    expect(_x, findsOneWidget, reason: 'the x follows the box, not the debounce');
    await tester.tapAt(tester.getCenter(_x), kind: searchPointer);
    await tester.pump(const Duration(seconds: 1));
    expect(searchBoxText(tester, _field), isEmpty);
    expect(sent, isNot(contains('dal')));
    expect(sent, isEmpty, reason: 'the screen was never told "dal", so it need not be told ""');
  }, variant: searchPlatforms);

  testWidgets('queries are trimmed, sent once, and a caret move does not restart the wait', (tester) async {
    final sent = <String>[];
    final c = TextEditingController();
    addTearDown(c.dispose);
    await _pump(tester, _Host(sent: sent, controller: c, debounce: const Duration(milliseconds: 300)));
    await tester.enterText(_field, ' dal');
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, ['dal']);
    await tester.enterText(_field, ' dal  ');
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, ['dal'], reason: 'the same query, differently spaced, is not a new one');

    await tester.enterText(_field, 'dals');
    await tester.pump(const Duration(milliseconds: 200));
    c.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(sent, ['dal', 'dals'], reason: 'moving the caret restarted the debounce');

    // Only spaces is an empty search, at once.
    await tester.enterText(_field, '   ');
    expect(sent, ['dal', 'dals', '']);
    await tester.pump();
    expect(_x, findsOneWidget, reason: 'there is still something in the box to clear');
  }, variant: searchPlatforms);

  testWidgets('Enter searches at once', (tester) async {
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent, debounce: const Duration(milliseconds: 450)));
    await tester.showKeyboard(_field);
    await tester.enterText(_field, '101 ');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(sent, ['101']);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['101'], reason: 'the debounce must not send it a second time');
  }, variant: searchPlatforms);

  testWidgets('the initial query is read once: a parent rebuild never puts it back', (tester) async {
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent));
    await tester.enterText(_field, 'dal');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rebuild-with-initial')));
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, _field), 'dal');
    await tester.enterText(_field, '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rebuild-with-initial')));
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, _field), isEmpty);
    expect(sent, ['dal', '']);
  }, variant: searchPlatforms);

  testWidgets("a screen's own clear() reaches the query, and a new controller is a fresh start", (tester) async {
    final sent = <String>[];
    final a = TextEditingController();
    final b = TextEditingController(text: 'naan');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await _pump(tester, _Host(sent: sent, controller: a, debounce: const Duration(milliseconds: 300)));
    await tester.enterText(_field, 'dal');
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, ['dal']);
    a.clear(); // "Clear filters", somewhere else on the screen
    expect(sent, ['dal', '']);
    await tester.pump();
    expect(_x, findsNothing);

    final host = tester.state<_HostState>(find.byType(_Host));
    // ignore: invalid_use_of_protected_member
    host.setState(() => host.controller = b);
    await tester.pump(const Duration(seconds: 1));
    expect(searchBoxText(tester, _field), 'naan');
    expect(sent, ['dal', ''], reason: 'the screen handed "naan" over; it is not news to it');
    expect(_x, findsOneWidget);
    a.text = 'ignored';
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['dal', ''], reason: 'the old controller is no longer listened to');
    await tester.enterText(_field, 'naan roti');
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, ['dal', '', 'naan roti']);
  }, variant: searchPlatforms);

  testWidgets('the x puts the caret back in the box, even after it had left', (tester) async {
    // A phone: type, put the keyboard away to read the list, then press the x.
    // The next thing anyone does is type the next word, so the box takes the
    // caret (and the keyboard) back.
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent));
    await tester.tapAt(tester.getCenter(_field), kind: searchPointer);
    await tester.enterText(_field, 'dal');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(searchBoxFocused(tester, _field), isFalse);
    await tester.tapAt(tester.getCenter(_x), kind: searchPointer);
    await tester.pump();
    expect(searchBoxText(tester, _field), isEmpty);
    expect(searchBoxFocused(tester, _field), isTrue);
  }, variant: searchPlatforms);

  testWidgets('a box taken away mid-debounce sends nothing afterwards', (tester) async {
    final sent = <String>[];
    await _pump(tester, _Host(sent: sent, debounce: const Duration(milliseconds: 300)));
    await tester.enterText(_field, 'dal');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(sent, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: searchPlatforms);

  testWidgets('a box built away mid-debounce and back: the word its screen never heard is waited out again',
      (tester) async {
    // A screen that keeps its own controller (a box shown only for some
    // reports, a row that moved) can lose the box while a word waits. The word
    // is not sent from a box that is gone, but the next box over the same
    // controller must not take it as sent: that box showed "102" and its x
    // over an unfiltered list, and Enter did nothing.
    final sent = <String>[];
    final c = TextEditingController();
    addTearDown(c.dispose);
    Future<void> show(bool shown) => tester.pumpWidget(searchThemed(
          DesignSystem.rustic,
          Scaffold(
            body: Column(children: [
              if (shown)
                AppSearchField(
                  testId: 'probe',
                  hint: 'Search bills…',
                  controller: c,
                  debounce: const Duration(milliseconds: 350),
                  onQuery: sent.add,
                ),
            ]),
          ),
        ));
    useSearchView(tester);
    await show(true);
    await tester.enterText(_field, '102');
    await tester.pump(const Duration(milliseconds: 100));
    await show(false);
    await tester.pump(const Duration(milliseconds: 600));
    expect(sent, isEmpty, reason: 'nothing is sent from a box that is gone');

    await show(true);
    expect(searchBoxText(tester, _field), '102');
    expect(_x, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 349));
    expect(sent, isEmpty, reason: 'the word waits out the debounce again, like fresh typing');
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, ['102']);

    // Again, and this time Enter: it sends at once, and only once.
    await tester.enterText(_field, '1024');
    await tester.pump(const Duration(milliseconds: 100));
    await show(false);
    await show(true);
    await tester.showKeyboard(_field);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(sent, ['102', '1024'], reason: 'Enter did nothing over a word the screen never heard');
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['102', '1024']);

    // A word the screen DID hear is not news to the next box.
    await show(false);
    await show(true);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['102', '1024']);

    // An emptied box never waits, even one emptied while no box was listening:
    // the next box tells the screen on the next timer tick (not from inside
    // the build that made it, where the screen may not setState).
    await show(false);
    c.clear();
    await show(true);
    expect(sent, ['102', '1024']);
    await tester.pump(Duration.zero);
    expect(sent, ['102', '1024', '']);
    expect(_x, findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: searchPlatforms);

  testWidgets('a box scrolled out of a lazy list mid-debounce still delivers its word, then lets go', (tester) async {
    // Settled bills sits in the Accounting ListView and the Gaia guest box in
    // the guest list. A fling past the list's cache disposes whatever it
    // passes, and a box that had lost the caret (a click on the list, the
    // phone keyboard put away) is not kept alive by the TextField itself.
    final sent = <String>[];
    final c = TextEditingController();
    final scroll = ScrollController();
    addTearDown(c.dispose);
    addTearDown(scroll.dispose);
    await _pump(
      tester,
      ListView(controller: scroll, children: [
        AppSearchField(
          testId: 'probe',
          hint: 'Search bill no, table, customer…',
          controller: c,
          debounce: const Duration(milliseconds: 350),
          onQuery: sent.add,
        ),
        for (var i = 0; i < 60; i++) SizedBox(height: 80, child: Text('bill $i')),
      ]),
    );
    await tester.tapAt(tester.getCenter(_field), kind: searchPointer);
    await tester.enterText(_field, '102');
    await tester.pump(const Duration(milliseconds: 100));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    scroll.jumpTo(3000);
    await tester.pump();
    final alive = find.byKey(const ValueKey('probe'), skipOffstage: false);
    expect(alive, findsOneWidget, reason: 'the list dropped the box, and its word, mid-wait');

    await tester.pump(const Duration(milliseconds: 250));
    expect(sent, ['102']);
    await tester.pumpAndSettle();
    expect(alive, findsNothing, reason: 'the box is kept only while a word waits');

    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(searchBoxText(tester, _field), '102');
    expect(_x, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['102'], reason: 'heard once is enough');
    expect(tester.takeException(), isNull);
  }, variant: searchPlatforms);

  for (final ds in DesignSystem.values) {
    testWidgets('the x: in the suffix, a 40px+ button, labelled, keeps focus (${ds.id})', (tester) async {
      final sent = <String>[];
      await _pump(tester, _Host(sent: sent), ds: ds);
      expect(_x, findsNothing, reason: 'nothing to clear yet');
      await tester.tapAt(tester.getCenter(_field), kind: searchPointer);
      await tester.enterText(_field, 'dal');
      await tester.pump();
      expect(find.descendant(of: _field, matching: _x), findsOneWidget, reason: 'inside the field, not beside it');
      expect(tester.widget(_x), isA<IconButton>());
      expect(find.descendant(of: _field, matching: find.byTooltip(AppSearchField.clearTooltip)), findsOneWidget);
      final size = tester.getSize(_x);
      expect(size.width, greaterThanOrEqualTo(40));
      expect(size.height, greaterThanOrEqualTo(40));
      final field = tester.getRect(_field);
      expect(tester.getRect(_x).right, lessThanOrEqualTo(field.right + 0.5), reason: 'at the right end of the box');
      await tester.tapAt(tester.getCenter(_x), kind: searchPointer);
      await tester.pump();
      expect(searchBoxText(tester, _field), isEmpty);
      expect(searchBoxFocused(tester, _field), isTrue);
      expect(_x, findsNothing);
      expect(sent, ['dal', '']);
    }, variant: searchPlatforms);

    testWidgets('a 360dp phone: the box, the compact box and a long word do not overflow (${ds.id})', (tester) async {
      useSearchView(tester, const Size(360, 640));
      await tester.pumpWidget(searchThemed(
        ds,
        Scaffold(
          body: Column(children: [
            Row(children: [
              Expanded(child: _Host(sent: <String>[])),
              const SizedBox(width: 8),
              const SizedBox(width: 120, child: Text('Payment method')),
            ]),
            SizedBox(width: 360, child: _Host(sent: <String>[], compact: true)),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      for (final f in find.byKey(const ValueKey('probe')).evaluate().toList()) {
        await tester.enterText(find.byElementPredicate((e) => e == f), 'a very long dish name that runs on and on');
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('probe-clear')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }, variant: searchPlatforms);

    testWidgets('Escape: clears a box that has text and keeps its dialog; an empty box lets the dialog close (${ds.id})',
        (tester) async {
      final sent = <String>[];
      useSearchView(tester);
      await tester.pumpWidget(searchThemed(
        ds,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(child: _Host(sent: sent)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(_field), kind: searchPointer);
      await tester.enterText(_field, 'dal');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget, reason: 'Escape on a box with text only clears it');
      expect(searchBoxText(tester, _field), isEmpty);
      expect(searchBoxFocused(tester, _field), isTrue);
      expect(sent.last, '');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing, reason: 'Escape on an empty box still closes the dialog');
    }, variant: searchPlatforms);
  }
}
