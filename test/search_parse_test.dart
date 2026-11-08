import 'package:duvet/data/models.dart';
import 'package:duvet/search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const members = [
    Member(userId: 'u-maya', username: 'maya', alias: 'Maya Lin'),
    Member(userId: 'u-leo', username: 'leo'),
  ];
  const rooms = [
    Room(id: 'r-general', spaceId: 's', name: 'general', kind: RoomKind.text, position: 0),
    Room(id: 'r-crit', spaceId: 's', name: 'Design Crit', kind: RoomKind.text, position: 1),
  ];
  SearchQuery parse(String input) => parseSearch(input, members: members, rooms: rooms, spaceId: 's');

  test('words are the query; filters are taken out of it', () {
    final q = parse('type  ramp from:maya has:image has:LINK in:#design-crit mentions:@Leo');
    expect(q.text, 'type ramp');
    expect(q.spaceId, 's');
    expect(q.authorIds, ['u-maya']);
    expect(q.mentionIds, ['u-leo']);
    expect(q.has, ['image', 'link']);
    expect(q.roomIds, ['r-crit']);
    expect(q.pinned, isNull);
    expect(q.isEmpty, isFalse);
  });

  test('a member by username or display name; an empty filter is ignored', () {
    expect(parse('from:@maya').authorIds, ['u-maya']);
    expect(parse('FROM:maya').authorIds, ['u-maya']);
    expect(parse('from:').isEmpty, isTrue);
  });

  test('what is wrong is said', () {
    expect(
      () => parse('from:nobody'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'No member is called nobody')),
    );
    expect(() => parse('in:random'), throwsFormatException);
    expect(() => parse('has:gif'), throwsFormatException);
    expect(() => parse('pinned:yes'), throwsFormatException);
    expect(() => parse('before:2026-02-30'), throwsFormatException);
  });

  test('pinned: either way; dates are local days, after: leaves its day out, during: is that day', () {
    expect(parse('pinned:false').pinned, isFalse);
    expect(parse('before:2026-11-08').before, DateTime(2026, 11, 8));
    expect(parse('after:2026-11-08').after, DateTime(2026, 11, 9));
    final during = parse('during:2026-12-31');
    expect((during.after, during.before), (DateTime(2026, 12, 31), DateTime(2027, 1, 1)));
    // Several dates narrow each other, in any order.
    final both = parse('after:2026-11-07 during:2026-11-06');
    expect((both.after, both.before), (DateTime(2026, 11, 8), DateTime(2026, 11, 7)));
    final within = parse('before:2026-11-30 during:2026-11-10 after:2026-11-01');
    expect((within.after, within.before), (DateTime(2026, 11, 10), DateTime(2026, 11, 11)));
  });

  test('suggestions: the filters, then members, rooms and values', () {
    List<String> labels(String token) => [
      for (final s in searchSuggestions(
        token,
        members: members,
        rooms: rooms,
        inSpace: true,
        now: DateTime(2026, 11, 8),
      ))
        s.label,
    ];
    // pinned: is a toggle, not a suggestion.
    expect(labels(''), ['from:', 'mentions:', 'in:', 'has:', 'before:', 'after:', 'during:']);
    expect(labels('p'), isEmpty);
    expect(labels('b'), ['before:']);
    expect(labels('from:m'), ['Maya Lin']);
    expect(searchSuggestions('from:m', members: members).single.insert, 'from:maya ');
    expect(labels('in:#d'), ['#Design Crit']);
    expect(searchSuggestions('in:d', members: members, rooms: rooms).single.insert, 'in:design-crit ');
    expect(labels('has:s'), ['sound', 'sticker']);
    expect(labels('during:'), ['2026-11-08']);
    expect(searchSuggestions('', members: members).map((s) => s.label), isNot(contains('in:')));
  });
}
