import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/order_entry.dart';
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/outbox.dart';
import 'package:restaurant_owner_app/services/phone_validation.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';

/// ITEM 5 — "View order" next to "Send order".
///
/// "There should be a view order button next to the send order button so that
/// the order can be viewed and repeated to the guest and only then can the
/// order be sent to the kitchen."
///
/// What these tests hold, in the order of what it would cost to get wrong:
///
///   * ONE ORDER, NEVER TWO. The sheet's "Send to kitchen" answers true and the
///     PAD sends after the sheet has closed. Sent from inside the sheet, the
///     pad's closing pop takes the sheet instead, the pad stays open with the
///     cart live, and the next tap is a second order under a second key.
///   * WHAT IS READ BACK IS WHAT IS SENT: the lines on the sheet, in the order
///     they were added, are the items POST /orders receives.
///   * NO MONEY ON A WAITER'S REVIEW (item 19 / C4), and all of it for an owner.
///   * A dish the menu dropped blocks the send with a sentence, instead of
///     leaving the button on "Sending…" for good.

// ------------------------------------------------------------------ the fake

class _FakeApi extends ApiClient {
  _FakeApi(this.routes, {this.role = 'admin'});

  /// Path -> payload, or `dynamic Function()` for a payload that changes.
  final Map<String, dynamic> routes;
  final String role;

  final List<({String method, String path, Object? body})> writes = [];

  /// While set, every request hangs until the test opens it.
  Completer<void>? gate;

  /// While true, every WRITE dies in transport, as a dropped Wi-Fi does.
  bool writesOffline = false;

  @override
  Future<LoginResult> login(String restaurantName, String user, String password,
          {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'emp-1',
          'restaurantName': 'Gaia Test',
          'restaurantUsername': 'gaiatest',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'employeeUsername': 'ravi',
          'emp_Fname': 'Ravi',
          'role': role,
          'role_all': [role],
          'actions_set': role == 'waiter' ? const ['a1'] : const ['*'],
          'action_names': const ['View Orders', 'Create Order', 'View Tables', 'Occupy Table', 'View Menu'],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token,
      [Object? body, String? outletId]) async {
    if (gate != null) await gate!.future;
    if (method != 'GET') {
      if (writesOffline) throw const SocketException('Network is unreachable');
      writes.add((method: method, path: path, body: body));
      return <String, dynamic>{'success': true};
    }
    if (!routes.containsKey(path)) throw ApiException('No fake route for $path', 404);
    final r = routes[path];
    return r is dynamic Function() ? r() : r;
  }

  Iterable<({String method, String path, Object? body})> to(String path) =>
      writes.where((w) => w.path == path);
}

Future<RestClient> _signIn(_FakeApi api) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(api: api);
  await auth.login('Gaia Test', 'ravi', 'pw');
  return RestClient(auth);
}

List<Map<String, dynamic>> _dishes(int n) => [
      for (var i = 1; i <= n; i++)
        {'id': 'mi-$i', 'name': 'Dish $i', 'price': 100.0 + i, 'category': 'Starters'},
    ];

// No '/bill-for-table' route: the table has no open bill yet, so the
// running-bill strip stays out of the geometry.
Map<String, dynamic> _routes({int dishes = 3}) => {'/menu': _dishes(dishes)};

// ------------------------------------------------------------------- hosts --

/// The pad, pushed from a host route — so a test can see the pad CLOSE, and
/// what it closed with.
class _Host {
  bool? result;
  bool closed = false;
}

Future<(_FakeApi, _Host)> _pumpPad(
  WidgetTester tester, {
  String role = 'admin',
  int dishes = 3,
  Size size = const Size(420, 900),
  String orderType = 'dine_in',
  bool occupyOnSend = false,
  _FakeApi? reuse,
  RestClient? rest,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = reuse ?? _FakeApi(_routes(dishes: dishes), role: role);
  final client = rest ?? await _signIn(api);
  final host = _Host();
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark(),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              host.result = await Navigator.push<bool>(
                ctx,
                MaterialPageRoute(
                  builder: (_) => OrderEntryScreen(
                    rest: client,
                    tableName: orderType == 'dine_in' ? 'T1' : null,
                    orderType: orderType,
                    occupyOnSend: occupyOnSend,
                  ),
                ),
              );
              host.closed = true;
            },
            child: const Text('open pad'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open pad'));
  await tester.pumpAndSettle();
  return (api, host);
}

Finder _card(String dish) => find.ancestor(of: find.text(dish), matching: find.byType(ForkCard)).first;

Future<void> _add(WidgetTester tester, String dish, {int times = 1}) async {
  await tester.ensureVisible(_card(dish));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: _card(dish), matching: find.text('Add')));
  await tester.pumpAndSettle();
  for (var i = 1; i < times; i++) {
    await tester.tap(find.descendant(of: _card(dish), matching: find.byIcon(Icons.add_circle_outline)));
    await tester.pumpAndSettle();
  }
}

final Finder _sheet = find.byKey(const ValueKey('order-review-sheet'));
final Finder _review = find.byKey(const ValueKey('order-review'));
final Finder _send = find.byKey(const ValueKey('order-send'));
final Finder _sendToKitchen = find.byKey(const ValueKey('order-review-send'));

Finder _inSheet(Finder f) => find.descendant(of: _sheet, matching: f);

Future<void> _openReview(WidgetTester tester) async {
  await tester.tap(_review);
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget, reason: 'View order opened no review');
}

/// Every glyph painted inside the review sheet.
List<String> _paintedInSheet(WidgetTester tester) => [
      for (final rt in tester.widgetList<RichText>(_inSheet(find.byType(RichText))))
        rt.text.toPlainText(includeSemanticsLabels: false, includePlaceholders: false),
    ];

String _sendLabel(WidgetTester tester) {
  final t = tester.widget<Text>(find.descendant(of: _send, matching: find.byType(Text)));
  return t.data!;
}

bool _enabled(WidgetTester tester, Finder button) =>
    (tester.widget(button) as ButtonStyleButton).onPressed != null;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Outbox.instance.debugReset();
  });

  // ======================================================== 1. the button row

  group('the View order button', () {
    testWidgets('hidden with an empty cart; then beside Send order, in the same row', (tester) async {
      await _pumpPad(tester);
      expect(_review, findsNothing);
      expect(_send, findsNothing);

      await _add(tester, 'Dish 1');
      expect(_review, findsOneWidget);
      expect(_send, findsOneWidget);
      final review = tester.getRect(_review);
      final send = tester.getRect(_send);
      expect(review.center.dy, closeTo(send.center.dy, 1), reason: 'one row, not stacked');
      expect(review.right, lessThanOrEqualTo(send.left), reason: 'View order sits before Send order');
      // Its label must never contain the phrase the pad's send is found by.
      expect(find.text('View order'), findsOneWidget);
      expect(find.textContaining('Send order'), findsOneWidget);
    });

    testWidgets('no dead tap: live while the cart has a dish, and it opens something', (tester) async {
      await _pumpPad(tester);
      await _add(tester, 'Dish 2');
      expect(_enabled(tester, _review), isTrue);
      await _openReview(tester);
    });

    testWidgets('Send order is still the one-tap send, with no review in the way', (tester) async {
      final (api, host) = await _pumpPad(tester);
      await _add(tester, 'Dish 1');
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(api.to('/orders'), hasLength(1));
      expect(host.result, isTrue);
    });
  });

  // ============================================== 2. what the review reads back

  group('the review', () {
    testWidgets('lists the draft in the order it was ADDED, with the hold and the note, and writes nothing',
        (tester) async {
      final (api, _) = await _pumpPad(tester);
      await _add(tester, 'Dish 3');
      await _add(tester, 'Dish 1', times: 2);
      await _add(tester, 'Dish 2');

      // A note on Dish 1, from the menu row.
      await tester.tap(find.descendant(of: _card('Dish 1'), matching: find.byIcon(Icons.sticky_note_2_outlined)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'no onions');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      // Dish 3 held.
      await tester.tap(find.descendant(of: _card('Dish 3'), matching: find.byIcon(Icons.front_hand_outlined)));
      await tester.pumpAndSettle();

      await _openReview(tester);
      expect(_inSheet(find.text('Review order · T1')), findsOneWidget);
      expect(_inSheet(find.text('Read it back to the guest, then send.')), findsOneWidget);
      final lines = ['1 × Dish 3', '2 × Dish 1', '1 × Dish 2'];
      for (final l in lines) {
        expect(_inSheet(find.text(l)), findsOneWidget, reason: '$l is missing from the read-back');
      }
      final ys = [for (final l in lines) tester.getRect(_inSheet(find.text(l))).top];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'the review must read in the order the dishes were added');
      expect(_inSheet(find.text('HOLD')), findsOneWidget);
      expect(_inSheet(find.text('no onions')), findsOneWidget);
      expect(tester.widget<Text>(_inSheet(find.byKey(const ValueKey('order-review-summary')))).data,
          startsWith('4 items · 3 dishes'));
      expect(api.writes, isEmpty, reason: 'looking at the order sent something');

      // Back to menu: the pad is as it was, nothing sent.
      await tester.tap(find.byKey(const ValueKey('order-review-back')));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(_send, findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('a waiter\'s review prices nothing at all', (tester) async {
      await _pumpPad(tester, role: 'waiter');
      await _add(tester, 'Dish 1', times: 2);
      await _add(tester, 'Dish 2');
      await _openReview(tester);
      final painted = _paintedInSheet(tester);
      expect(painted, isNotEmpty);
      for (final shown in painted) {
        expect(shown.contains('₹'), isFalse, reason: 'money on a waiter\'s review: "$shown"');
      }
      expect(tester.widget<Text>(_inSheet(find.byKey(const ValueKey('order-review-summary')))).data,
          '3 items · 2 dishes');
    });

    testWidgets('an owner\'s review prices every line, and the total is the Send button\'s figure',
        (tester) async {
      await _pumpPad(tester, role: 'admin');
      await _add(tester, 'Dish 1', times: 2); // 2 × 101
      await _add(tester, 'Dish 2'); //           1 × 102
      final label = _sendLabel(tester);
      expect(label, 'Send order · 3 items · ₹304.00');
      await _openReview(tester);
      expect(_inSheet(find.text('₹202.00')), findsOneWidget);
      expect(_inSheet(find.text('₹102.00')), findsOneWidget);
      expect(tester.widget<Text>(_inSheet(find.byKey(const ValueKey('order-review-summary')))).data,
          '3 items · 2 dishes · ₹304.00');
    });

    testWidgets('+, − and remove in the review are the pad\'s own: the menu row and Send follow',
        (tester) async {
      await _pumpPad(tester, role: 'waiter');
      await _add(tester, 'Dish 1');
      await _add(tester, 'Dish 2');
      await _openReview(tester);

      await tester.tap(find.descendant(
          of: find.ancestor(of: _inSheet(find.text('1 × Dish 1')), matching: find.byType(ForkCard)).first,
          matching: find.byIcon(Icons.add_circle_outline)));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('2 × Dish 1')), findsOneWidget);
      expect(_sendLabel(tester), 'Send order · 3 items');

      await tester.tap(find.descendant(
          of: find.ancestor(of: _inSheet(find.text('2 × Dish 1')), matching: find.byType(ForkCard)).first,
          matching: find.byIcon(Icons.remove_circle_outline)));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('1 × Dish 1')), findsOneWidget);

      // Remove Dish 2 outright: gone from the review AND from the pad's cart.
      await tester.tap(find.byKey(const ValueKey('order-review-remove-mi-2')));
      await tester.pumpAndSettle();
      expect(_inSheet(find.textContaining('Dish 2')), findsNothing);
      expect(_sendLabel(tester), 'Send order · 1 item');

      // The hold toggled from the review lands on the pad's own menu row.
      await tester.tap(_inSheet(find.byIcon(Icons.front_hand_outlined)));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('HOLD')), findsOneWidget);

      // Removing the last dish ends the review — and the pad's buttons go with it.
      await tester.tap(find.byKey(const ValueKey('order-review-remove-mi-1')));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(_review, findsNothing);
      expect(_send, findsNothing);

      // And the hold went with its dish: re-adding it is a fresh, unheld line.
      await _add(tester, 'Dish 1');
      await _openReview(tester);
      expect(_inSheet(find.text('HOLD')), findsNothing);
    });
  });

  // =========================================== 3. Send to kitchen: ONE order

  group('Send to kitchen', () {
    testWidgets('posts exactly one order, of the lines read back, and closes the sheet AND the pad',
        (tester) async {
      final (api, host) = await _pumpPad(tester);
      await _add(tester, 'Dish 2', times: 2);
      await tester.tap(find.descendant(of: _card('Dish 2'), matching: find.byIcon(Icons.sticky_note_2_outlined)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '  less oil ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _add(tester, 'Dish 1');
      await tester.tap(find.descendant(of: _card('Dish 1'), matching: find.byIcon(Icons.front_hand_outlined)));
      await tester.pumpAndSettle();

      await _openReview(tester);
      await tester.tap(_sendToKitchen);
      await tester.pumpAndSettle();

      expect(api.to('/orders'), hasLength(1), reason: 'one tap, one order');
      final body = api.to('/orders').single.body as Map;
      expect(body['table'], 'T1');
      expect(body['items'], [
        {'id': 'mi-2', 'name': 'Dish 2', 'price': 102.0, 'quantity': 2, 'note': 'less oil'},
        {'id': 'mi-1', 'name': 'Dish 1', 'price': 101.0, 'quantity': 1, 'course_hold': true},
      ]);
      expect(body['subtotal'], 305.0);
      expect(body['total'], 305.0);

      // THE DUPLICATE GUARD: the pad is gone, not merely the sheet. A pad left
      // open here with the cart live is one tap from a second order.
      expect(_sheet, findsNothing);
      expect(find.byType(OrderEntryScreen), findsNothing);
      expect(host.closed, isTrue);
      expect(host.result, isTrue);
      expect(api.writes, hasLength(1));
    });

    testWidgets('a waiter on a free table: covers first, then the seating, then the order', (tester) async {
      final (api, host) = await _pumpPad(tester, role: 'waiter', occupyOnSend: true);
      await _add(tester, 'Dish 1');
      await _openReview(tester);
      await tester.tap(_sendToKitchen);
      await tester.pumpAndSettle();

      expect(_sheet, findsNothing, reason: 'the covers question is asked after the review has closed');
      expect(find.text('How many guests at this table?'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '4');
      await tester.tap(find.widgetWithText(FilledButton, 'Send order'));
      await tester.pumpAndSettle();

      expect(api.writes.map((w) => w.path).toList(), ['/occupy-table', '/orders']);
      expect((api.to('/occupy-table').single.body as Map)['num_covers'], 4);
      expect(host.result, isTrue);
    });

    testWidgets('cancelling that covers question leaves the pad as found, cart and all', (tester) async {
      final (api, host) = await _pumpPad(tester, role: 'waiter', occupyOnSend: true);
      await _add(tester, 'Dish 1', times: 2);
      await _openReview(tester);
      await tester.tap(_sendToKitchen);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(api.writes, isEmpty);
      expect(host.closed, isFalse);
      expect(_sendLabel(tester), 'Send order · 2 items');
      expect(_enabled(tester, _send), isTrue);
    });

    testWidgets('the line is down: ONE order saved on the device, the pad closes, no second copy',
        (tester) async {
      final (api, host) = await _pumpPad(tester);
      await _add(tester, 'Dish 1');
      api.writesOffline = true;

      await _openReview(tester);
      await tester.tap(_sendToKitchen);
      await tester.pumpAndSettle();

      expect(Outbox.instance.pendingCount, 1, reason: 'the order must be queued exactly once');
      expect(Outbox.instance.entries.single.path, '/orders');
      expect(host.result, isTrue, reason: 'left open, the next tap queues a second copy under a new key');
      expect(find.byType(OrderEntryScreen), findsNothing);
      expect(find.textContaining('The kitchen has NOT seen it yet'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(Outbox.instance.pendingCount, 1);
    });
  });

  // ============================================ 4. what may not be sent yet

  group('a draft that cannot be sent', () {
    testWidgets('a dish the menu dropped: named, flagged, not sendable — and never stuck on "Sending…"',
        (tester) async {
      var menu = _dishes(2);
      final api = _FakeApi({'/menu': () => menu}, role: 'admin');
      final rest = await _signIn(api);
      // Warm: the pad has seen this menu before, so the next open paints it from
      // the saved copy while the network refresh is still on its way.
      await _pumpPad(tester, reuse: api, rest: rest);
      expect(find.text('Dish 2'), findsOneWidget);

      api.gate = Completer<void>();
      final (_, host) = await _pumpPad(tester, reuse: api, rest: rest);
      expect(find.text('Dish 2'), findsOneWidget, reason: 'precondition: the saved menu painted');
      await _add(tester, 'Dish 1');
      await _add(tester, 'Dish 2', times: 2);

      // The refresh lands, and Dish 2 is off the menu.
      menu = _dishes(1);
      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(find.text('Dish 2'), findsNothing, reason: 'precondition: the refresh dropped the dish');

      // The pad's own Send: refused with a sentence, the review opened on it.
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      const refusal = 'Dish 2 is no longer on the menu — remove it to send';
      expect(find.text(refusal), findsWidgets);
      expect(_sheet, findsOneWidget, reason: 'the review is the only place the dish can still be removed');
      expect(_inSheet(find.text('2 × Dish 2')), findsOneWidget);
      expect(_inSheet(find.text('No longer on the menu')), findsOneWidget);
      expect(_enabled(tester, _sendToKitchen), isFalse);

      // Back on the pad, the button is not wedged.
      await tester.tap(find.byKey(const ValueKey('order-review-back')));
      await tester.pumpAndSettle();
      expect(find.text('Sending…'), findsNothing);
      expect(_enabled(tester, _send), isTrue);
      expect(_sendLabel(tester), startsWith('Send order · 3 items'));

      // Remove it in the review; now it sends, without it, once.
      await _openReview(tester);
      await tester.tap(find.byKey(const ValueKey('order-review-remove-mi-2')));
      await tester.pumpAndSettle();
      expect(_enabled(tester, _sendToKitchen), isTrue);
      await tester.tap(_sendToKitchen);
      await tester.pumpAndSettle();
      expect(api.to('/orders'), hasLength(1));
      expect(((api.to('/orders').single.body as Map)['items'] as List).map((i) => (i as Map)['id']), ['mi-1']);
      expect(host.result, isTrue);
    });

    testWidgets('a takeaway with a 5-digit phone: Send to kitchen is off, and says why', (tester) async {
      final (api, _) = await _pumpPad(tester, orderType: 'takeaway');
      await _add(tester, 'Dish 1');
      await tester.enterText(find.widgetWithText(TextField, '10-digit mobile (optional)'), '98765');
      await tester.pumpAndSettle();
      expect(_enabled(tester, _send), isFalse);

      await _openReview(tester);
      expect(_inSheet(find.text('Review order · Takeaway')), findsOneWidget);
      expect(_enabled(tester, _sendToKitchen), isFalse);
      expect(_inSheet(find.text(validateOptionalMobile10('98765')!)), findsOneWidget);
      expect(_inSheet(find.text('98765')), findsOneWidget, reason: 'the number is read back too');
      expect(api.writes, isEmpty);
    });
  });

  // ======================================================== 5. on a phone

  testWidgets('360px, an owner, twelve dishes: nothing overflows and the whole figure is there',
      (tester) async {
    await _pumpPad(tester, role: 'admin', dishes: 12, size: const Size(360, 800));
    for (var i = 1; i <= 12; i++) {
      await _add(tester, 'Dish $i');
    }
    expect(tester.takeException(), isNull);
    // 101 + 102 + … + 112
    expect(find.text('Send order · 12 items · ₹1278.00'), findsOneWidget);
    final send = tester.getRect(_send);
    expect(send.right, lessThanOrEqualTo(360));
    expect(tester.getRect(_review).right, lessThanOrEqualTo(send.left));
    await _openReview(tester);
    expect(tester.takeException(), isNull);
    expect(_inSheet(find.text('₹112.00')), findsOneWidget, reason: '1 × Dish 12');
    expect(tester.getRect(_sendToKitchen).right, lessThanOrEqualTo(360));
  });

  // ================================================ 6. the wiring, in source

  test('the sheet never sends; the pad sends after it closes, from the same lines', () {
    final src = File('lib/screens/order_entry.dart').readAsStringSync();
    final sheetAt = src.indexOf('class _OrderReviewSheet');
    expect(sheetAt, greaterThan(0));
    final sheet = src.substring(sheetAt);
    expect(sheet.contains('_send('), isFalse, reason: 'Send to kitchen must pop true, not post');
    expect(sheet.contains("Navigator.pop(context, true)"), isTrue);

    final open = RegExp(r'Future<void> _openReview\(\) async \{[\s\S]*?\n  \}').firstMatch(src)!.group(0)!;
    expect(open, contains('await showModalBottomSheet<bool>'));
    expect(open, contains('if (go == true && mounted) await _send();'));

    final send = RegExp(r'Future<void> _send\(\) async \{[\s\S]*?\n  \}').firstMatch(src)!.group(0)!;
    expect(send, contains("'items': orderDraftPayload(lines)"));
    expect(send, isNot(contains('_itemsById[e.key]!')));
    expect(send.indexOf('orderDraftBlock('), lessThan(send.indexOf('_sending = true;')),
        reason: 'refuse before the flag is raised, or the button wedges on "Sending…"');
  });
}
