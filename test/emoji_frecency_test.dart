import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:duvet/data/recent_emoji.dart';
import 'package:flutter_test/flutter_test.dart';

const _party = '<:0e0e0e0e-0000-4000-8000-000000000001:>';

/// Recently used emoji: often used and lately used, weighed together.
void main() {
  final start = DateTime.utc(2026, 1, 1);

  // Runs [body] with the clock stopped [after] the start.
  T at<T>(Duration after, T Function() body) => withClock(Clock.fixed(start.add(after)), body);

  Future<void> use(RecentEmoji recent, String emoji, Duration after, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await at(after, () => recent.used(emoji));
    }
  }

  test('the one used more often comes first', () async {
    final recent = RecentEmoji(MemoryRecentEmojiStore());
    await use(recent, '🎉', Duration.zero, times: 3);
    await use(recent, '😀', Duration.zero);
    expect(at(Duration.zero, () => recent.ranked), ['🎉', '😀']);
    expect(at(const Duration(days: 1), () => recent.ranked), ['🎉', '😀']);
  });

  test('the one just used shows first, then settles under a favourite', () async {
    final recent = RecentEmoji(MemoryRecentEmojiStore());
    await use(recent, '🎉', Duration.zero, times: 5);
    await use(recent, '😀', const Duration(days: 1));
    expect(at(const Duration(days: 1), () => recent.ranked), ['😀', '🎉']);
    expect(at(const Duration(days: 2), () => recent.ranked), ['🎉', '😀']);
  });

  test('a favourite left alone sinks under a later single use, however often it was used', () async {
    final recent = RecentEmoji(MemoryRecentEmojiStore());
    // Fifty uses count as ten: uncapped, they would still lead five weeks on.
    await use(recent, '🎉', Duration.zero, times: 50);
    await use(recent, '😀', const Duration(days: 6));
    expect(at(const Duration(days: 7), () => recent.ranked), ['🎉', '😀']);
    await use(recent, '👍', const Duration(days: 34));
    expect(at(const Duration(days: 35), () => recent.ranked).first, '👍');
  });

  test('tracks 96 at most, dropping the lowest', () async {
    final store = MemoryRecentEmojiStore();
    final recent = RecentEmoji(store);
    for (var i = 0; i < 100; i++) {
      await use(recent, 'e$i', Duration(minutes: i));
    }
    final ranked = at(const Duration(minutes: 100), () => recent.ranked);
    expect(ranked, hasLength(96));
    expect(ranked.first, 'e99');
    expect(ranked.last, 'e4');
    expect((jsonDecode(store.uses!) as Map).keys, hasLength(96));
  });

  test('what was used comes back from the store, custom emoji too', () async {
    final store = MemoryRecentEmojiStore();
    final recent = RecentEmoji(store);
    await use(recent, _party, Duration.zero, times: 3);
    await use(recent, '😀', Duration.zero);

    final again = RecentEmoji(store);
    await again.load();
    expect(at(const Duration(days: 1), () => again.ranked), [_party, '😀']);
    // The count came back, not only the order: one more use doesn't overtake three.
    await use(again, '😀', const Duration(days: 1));
    expect(at(const Duration(days: 2), () => again.ranked), [_party, '😀']);
  });

  test('stored data that doesn’t read starts empty', () async {
    for (final stored in [
      'not json',
      '',
      '42',
      'null',
      '[]',
      '["😀","🎉"]',
      '{"😀":"often"}',
      '{"😀":[1]}',
      '{"😀":[null,3]}',
      '{"😀":[1,2.5]}',
      '{"😀":[-1,0]}',
      '{"😀":[1e999,0]}',
    ]) {
      final recent = RecentEmoji(MemoryRecentEmojiStore()..uses = stored);
      await recent.load();
      expect(recent.ranked, isEmpty, reason: stored);
    }
  });

  test('a bad entry is skipped, the rest kept', () async {
    final recent = RecentEmoji(MemoryRecentEmojiStore()..uses = '{"😀":[2,0],"🎉":"x","👍":[0,0]}');
    await recent.load();
    expect(recent.ranked, ['😀']);
  });

  test('a store that fails leaves it working', () async {
    final recent = RecentEmoji(_BrokenStore());
    await recent.load();
    await recent.used('😀');
    expect(recent.ranked, ['😀']);
  });

  test('removing one forgets it, in the store too', () async {
    final store = MemoryRecentEmojiStore();
    final recent = RecentEmoji(store);
    await use(recent, '🎉', Duration.zero, times: 3);
    await use(recent, _party, Duration.zero);
    await recent.remove('🎉');
    expect(recent.ranked, [_party]);
    expect((jsonDecode(store.uses!) as Map).keys, [_party]);

    final again = RecentEmoji(store);
    await again.load();
    expect(again.ranked, [_party]);
  });
}

class _BrokenStore implements RecentEmojiStore {
  @override
  Future<String?> read() async => throw StateError('no storage');

  @override
  Future<void> write(String uses) async => throw StateError('no storage');
}
