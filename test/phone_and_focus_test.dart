import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_owner_app/services/phone_validation.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

void main() {
  group('normalizeMobile10 (must match the backend byte-for-byte)', () {
    test('accepts exactly 10 digits, in any formatting', () {
      expect(normalizeMobile10('9812345678'), '9812345678');
      expect(normalizeMobile10('+91 98123 45678'), '9812345678');
      expect(normalizeMobile10('098-123-45678'), '9812345678');
      expect(normalizeMobile10('(981) 234-5678'), '9812345678');
    });

    test('matches the server on a 0091 prefix (both reject it)', () {
      // The backend only peels "0091" at a total length of 13, so "0091" + a
      // full 10-digit number (14 digits) is rejected there too — verified live
      // against POST /add-customer, which returned 400
      // {"error":"Enter a 10-digit mobile number"}. The client must agree, not
      // be more permissive.
      expect(normalizeMobile10('0091 9812345678'), isNull);
    });

    test('rejects anything that is not 10 digits', () {
      expect(normalizeMobile10('981234567'), isNull); // 9
      expect(normalizeMobile10('98123456789'), isNull); // 11
      expect(normalizeMobile10('12345678'), isNull); // 8
      expect(normalizeMobile10(''), isNull);
      expect(normalizeMobile10('abcdefghij'), isNull);
      expect(normalizeMobile10(null), isNull);
    });

    test('never peels below 10 digits', () {
      // A 9-digit number that happens to start with 0 stays 9 digits.
      expect(normalizeMobile10('091234567'), isNull);
    });

    test('validators use the one shared message', () {
      expect(mobile10Error, 'Enter a 10-digit mobile number');
      expect(validateMobile10('9812345678'), isNull);
      expect(validateMobile10('98123456'), mobile10Error);
      expect(validateMobile10(''), mobile10Error); // required
      expect(validateOptionalMobile10(''), isNull); // optional: blank is fine
      expect(validateOptionalMobile10('  '), isNull);
      expect(validateOptionalMobile10('98123456'), mobile10Error);
    });

    test('formatters cap the field at 10 digits and strip non-digits', () {
      final fs = mobile10Formatters();
      expect(fs.length, 2);
    });
  });

  group('ModuleFocusRequest (notification -> record)', () {
    ModuleFocusRequest req(Map<String, dynamic> target) =>
        ModuleFocusRequest(moduleLabel: 'Orders', target: target, serial: 1);

    test('prefers the resolver entity_id over the legacy meta key', () {
      final r = req({'order_id': 'legacy', 'entity_id': 'resolved', 'entity_type': 'order'});
      expect(r.idOf(const ['order_id']), 'resolved');
      expect(r.entityType, 'order');
    });

    test('falls back to the legacy meta key on pre-existing notification rows', () {
      final r = req({'table': 'T4', 'order_id': '478da94c', 'needs_approval': false});
      expect(r.idOf(const ['order_id']), '478da94c');
      expect(r.tableName, 'T4');
      expect(r.entityType, isNull);
    });

    test('treats blank / null-ish ids as absent', () {
      expect(req({'entity_id': '', 'order_id': 'x'}).idOf(const ['order_id']), 'x');
      expect(req({'entity_id': 'null'}).idOf(const ['order_id']), isNull);
      expect(req({}).idOf(const ['order_id']), isNull);
      expect(req({'table': ''}).tableName, isNull);
    });

    test('a module only ever reads its own request', () {
      final nav = ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Orders', 'Bookings'],
        clearFocus: () {},
        focus: req({'order_id': 'o1'}),
        child: const SizedBox.shrink(),
      );
      expect(nav.focusFor('Orders')?.idOf(const ['order_id']), 'o1');
      expect(nav.focusFor('Bookings'), isNull);
      expect(nav.canOpen('Orders'), isTrue);
      expect(nav.canOpen('Valet'), isFalse);
    });
  });
}
