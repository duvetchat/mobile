import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef _Use = ({double score, int at});

/// The emoji used lately, ranked as iOS ranks its Frequently Used: by how
/// often, fading with time, with what was just used up front. Each is a
/// Unicode emoji or a custom emoji's `<:id:>` code. Kept on the device, for
/// every account.
///
/// An emoji's rank, `age` after its last use, is
/// `score × ½^(age / 7 days) + 10 × ½^(age / 1 hour)`, where each use adds 1
/// to the faded score, up to 10.
class RecentEmoji {
  final RecentEmojiStore _store;
  RecentEmoji([RecentEmojiStore? store]) : _store = store ?? const SecureRecentEmojiStore();

  /// The app's; a test puts one over a [MemoryRecentEmojiStore] here.
  static RecentEmoji instance = RecentEmoji();

  // A use counts half a week later: favourites change over weeks, not days.
  static const _halfLife = Duration(days: 7);

  // Where one use a day settles (1 / (1 - ½^(1/7)) ≈ 10). Capped there, a
  // favourite dropped for good sinks under a single use within a month.
  static const _maxScore = 10.0;

  // The last use adds a whole favourite's worth, halving each hour: the one
  // just used shows first, then settles where its count puts it.
  static const _freshHalfLife = Duration(hours: 1);

  /// How many the picker shows: three rows of a phone's eight columns.
  static const shown = 24;

  // Four times [shown]: custom emoji of other spaces stay tracked while hidden.
  static const _tracked = 96;

  final _uses = <String, _Use>{};

  static double _fade(int age, Duration halfLife) => math.pow(0.5, age / halfLife.inMilliseconds).toDouble();

  // A clock set back leaves a use in the future: it counts as just made.
  static int _age(_Use use, int now) => math.max(0, now - use.at);

  /// Every tracked one, the best first. The picker takes the first [shown] of
  /// those it can draw, so a hidden code costs no place.
  List<String> get ranked {
    final now = clock.now().millisecondsSinceEpoch;
    final ranks = {
      for (final MapEntry(:key, value: use) in _uses.entries)
        key: use.score * _fade(_age(use, now), _halfLife) + _maxScore * _fade(_age(use, now), _freshHalfLife),
    };
    return ranks.keys.toList()..sort((a, b) {
      final byRank = ranks[b]!.compareTo(ranks[a]!);
      return byRank != 0 ? byRank : a.compareTo(b);
    });
  }

  Future<void> load() async {
    try {
      // Whatever was used before this lands is newer than what is stored.
      for (final MapEntry(:key, :value) in _parse(await _store.read()).entries) {
        _uses.putIfAbsent(key, () => value);
      }
    } catch (e) {
      debugPrint('recent emoji: $e');
    }
  }

  /// Counts a use of [emojiOrCode], and keeps it.
  Future<void> used(String emojiOrCode) {
    final now = clock.now().millisecondsSinceEpoch;
    final before = _uses[emojiOrCode];
    final faded = before == null ? 0.0 : before.score * _fade(_age(before, now), _halfLife);
    _uses[emojiOrCode] = (score: math.min(_maxScore, faded + 1), at: now);
    // Never the one just used, even when it ties with the rest.
    while (_uses.length > _tracked) {
      _uses.remove(ranked.lastWhere((e) => e != emojiOrCode));
    }
    return _save();
  }

  /// Forgets [emojiOrCode], here and in the store.
  Future<void> remove(String emojiOrCode) {
    _uses.remove(emojiOrCode);
    return _save();
  }

  Future<void> _save() async {
    try {
      await _store.write(
        jsonEncode({
          for (final MapEntry(:key, value: use) in _uses.entries) key: [use.score, use.at],
        }),
      );
    } catch (e) {
      debugPrint('recent emoji: $e');
    }
  }

  // As written: {"😀": [score, last use in ms]}. Anything else is skipped.
  static Map<String, _Use> _parse(String? json) {
    final Object? data;
    try {
      data = json == null ? null : jsonDecode(json);
    } on FormatException {
      return {};
    }
    return {
      if (data is Map)
        for (final entry in data.entries)
          if (entry case MapEntry(
            key: final String key,
            value: [final num score, final int at],
          ) when score.isFinite && score > 0)
            key: (score: math.min(_maxScore, score.toDouble()), at: at),
    };
  }
}

abstract interface class RecentEmojiStore {
  Future<String?> read();
  Future<void> write(String uses);
}

class SecureRecentEmojiStore implements RecentEmojiStore {
  const SecureRecentEmojiStore();
  static const _key = 'duvet_recent_emoji';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String uses) => _storage.write(key: _key, value: uses);
}

class MemoryRecentEmojiStore implements RecentEmojiStore {
  String? uses;

  @override
  Future<String?> read() async => uses;

  @override
  Future<void> write(String uses) async => this.uses = uses;
}
