import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_owner_app/screens/modules.dart';

// THE FEEDBACK CARD SENDS ONLY WHAT THE OWNER CHANGED.
//
// Valet parking now has a second editor (web Settings > Feedback form) and the
// backend writes feedback settings as a patch. A card opened before someone
// flipped valet on the web used to post its whole, stale form on any save and
// write the old valet value back. These pin the diff that replaces that.

Map<String, dynamic> _form({
  String title = 'Gaia Feedback',
  String subtitle = 'Tell us',
  bool valet = false,
  bool requireImage = false,
  String reviewUrl = '',
  List<String> cats = const ['Food Quality', 'Ambience'],
}) =>
    {
      'title': title,
      'subtitle': subtitle,
      'valet_enabled': valet,
      'require_image': requireImage,
      'review_url': reviewUrl,
      'categories': [for (final c in cats) {'label': c, 'key': c.toLowerCase().replaceAll(' ', '_')}],
    };

void main() {
  test('an unrelated edit does not carry the stale valet value', () {
    final changes = feedbackSettingsChanges(_form(), _form(subtitle: 'We love hearing from you'));
    expect(changes, {'subtitle': 'We love hearing from you'});
    expect(changes.containsKey('valet_enabled'), isFalse);
  });

  test('flipping valet sends valet only', () {
    expect(feedbackSettingsChanges(_form(), _form(valet: true)), {'valet_enabled': true});
  });

  test('nothing changed is nothing to send', () {
    expect(feedbackSettingsChanges(_form(), _form()), isEmpty);
  });

  test('categories go as the whole new list when any label changed, was added, removed or reordered', () {
    expect(feedbackSettingsChanges(_form(), _form(cats: ['Food Quality', 'Ambience', 'Cleanliness']))['categories'],
        hasLength(3));
    expect(feedbackSettingsChanges(_form(), _form(cats: ['Ambience', 'Food Quality'])).containsKey('categories'), isTrue);
    expect(feedbackSettingsChanges(_form(), _form(cats: ['Food Quality'])).containsKey('categories'), isTrue);
  });
}
