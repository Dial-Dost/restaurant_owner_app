import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/services/outbox.dart';

/// THE QUEUEABLE SET MUST NOT DRIFT FROM THE SERVER'S GUARD.
///
/// Queuing a write means it may be sent twice — the first attempt's response can
/// be lost after the server already applied it. That is only safe where the
/// server deduplicates, and on the backend `idempotent()` is a PER-ROUTE opt-in
/// (27 endpoints across orders/tables/waitlist/inventory/attendance), not global
/// middleware.
///
/// So the danger is a policy that fails OPEN: queue everything, refuse a short
/// list. Then every route added later is silently queueable, gets an automatic
/// retry it never had, and double-applies against a server that never looks for
/// the key. These tests pin the default to REFUSE and name the routes that are
/// allowed, so adding a route to one side without the other fails here rather
/// than in a restaurant.
void main() {
  group('queueable set is an allowlist, not a denylist', () {
    test('the default for an unknown write is REFUSE, not queue', () {
      // Not exotic paths — these are real routes this app posts to today, none
      // of which carry the server-side guard.
      const unguarded = [
        ('PUT', '/menu'), // a bulk save here once wiped 56 items' images/recipes
        ('POST', '/menu'),
        ('POST', '/expenses'),
        ('POST', '/purchase-orders'),
        ('POST', '/campaigns'),
        ('POST', '/add-booking'),
        ('POST', '/employees'),
        ('POST', '/vendors'),
        ('PATCH', '/settings'),
        ('POST', '/audit-logs/abc/undo'),
        ('POST', '/some-route-invented-next-quarter'),
      ];
      for (final (method, path) in unguarded) {
        final d = OutboxPolicy.decide(method, path);
        expect(d.queueable, isFalse,
            reason: '$method $path has no server-side dedup and must not queue');
        expect(d.refusal, isNotEmpty,
            reason: '$method $path must tell the user something');
      }
    });

    test('every guarded route is queueable, with real ids in the path', () {
      const guarded = [
        ('POST', '/orders'),
        ('POST', '/orders/takeaway'),
        ('PATCH', '/orders/7f3a/status'),
        ('POST', '/orders/7f3a/items'),
        ('DELETE', '/orders/7f3a/items/9c2b'),
        ('DELETE', '/orders/7f3a'),
        ('POST', '/orders/7f3a/pause'),
        ('POST', '/orders/7f3a/resume'),
        ('POST', '/orders/7f3a/fire'),
        ('POST', '/orders/7f3a/bark'),
        ('POST', '/orders/7f3a/items/9c2b/serve'),
        ('POST', '/orders/7f3a/items/9c2b/unserve'),
        ('POST', '/orders/7f3a/items/9c2b/pause'),
        ('POST', '/orders/7f3a/items/9c2b/resume'),
        ('POST', '/occupy-table'),
        ('PATCH', '/table-covers'),
        ('POST', '/release-table'),
        ('POST', '/waitlist/w1/call'),
        ('POST', '/waitlist/w1/seat'),
        ('POST', '/waitlist/w1/preorder/confirm'),
        ('POST', '/waitlist/w1/preorder/decline'),
        ('POST', '/waitlist/w1/cancel'),
        ('POST', '/inventory/receive'),
        ('POST', '/inventory/wastage'),
        ('POST', '/inventory/issue'),
        ('POST', '/attendance/clock-in'),
        ('POST', '/attendance/clock-out'),
      ];
      expect(guarded.length, 27, reason: 'mirror of the backend opt-in count');
      for (final (method, path) in guarded) {
        expect(OutboxPolicy.decide(method, path).queueable, isTrue,
            reason: '$method $path carries idempotent() on the server');
      }
    });

    test('a pattern does not swallow deeper paths the server does not guard', () {
      // `/orders/:id` must not match `/orders/:id/split`: splitting a bill is
      // not guarded, and a prefix match would have queued it.
      for (final path in const [
        '/orders/7f3a/split',
        '/orders/7f3a/merge',
        '/orders/7f3a/items/9c2b/anything',
        '/waitlist/w1/preorder',
      ]) {
        expect(OutboxPolicy.decide('POST', path).queueable, isFalse,
            reason: '$path is deeper than any guarded route');
      }
    });

    test('the method is part of the match', () {
      // /orders is guarded for POST only; a PUT there is a different handler.
      expect(OutboxPolicy.decide('POST', '/orders').queueable, isTrue);
      expect(OutboxPolicy.decide('PUT', '/orders').queueable, isFalse);
      expect(OutboxPolicy.decide('DELETE', '/table-covers').queueable, isFalse);
    });

    test('a query string does not defeat the match', () {
      expect(
        OutboxPolicy.decide('POST', '/orders/7f3a/items/9c2b/serve?undo=0').queueable,
        isTrue,
      );
      // ...nor smuggle an unguarded path past it.
      expect(OutboxPolicy.decide('PUT', '/menu?bulk=1').queueable, isFalse);
    });

    test('the hazardous families keep their own explanation', () {
      // These are refused either way, but a waiter needs to know WHY billing
      // needs the line — not the generic "isn't saved offline".
      final billing = OutboxPolicy.decide('POST', '/bills/order/x/close');
      expect(billing.queueable, isFalse);
      expect(billing.refusal, contains('Billing'));
      expect(billing.refusal, isNot(OutboxPolicy.unsupported));

      final printing = OutboxPolicy.decide('POST', '/print/bill');
      expect(printing.queueable, isFalse);
      expect(printing.refusal, contains('Printing'));
    });

    test('GETs are never queued', () {
      expect(OutboxPolicy.decide('GET', '/orders').queueable, isFalse);
    });
  });
}
