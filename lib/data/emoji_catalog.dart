import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A Unicode emoji, named as emoji-datasource names it (the desktop app's set).
class EmojiEntry {
  final String emoji;
  final String name;
  final List<String> keywords;
  const EmojiEntry(this.emoji, this.name, [this.keywords = const []]);
}

class EmojiCategory {
  final String label;

  /// The emoji its tab shows.
  final String icon;
  final List<EmojiEntry> emojis;
  const EmojiCategory(this.label, this.icon, this.emojis);
}

/// The Unicode emoji, from `assets/emoji.json` (generated from emoji-datasource
/// 16.0.0, keeping what Twemoji draws, as the desktop app does), and the ones
/// used lately.
class EmojiCatalog {
  final List<EmojiCategory> categories;
  EmojiCatalog(this.categories);

  static Future<EmojiCatalog>? _loading;

  /// Loads the bundled set once.
  static Future<EmojiCatalog> load([AssetBundle? bundle]) =>
      _loading ??= (bundle ?? rootBundle).loadString('assets/emoji.json').then(parse);

  /// Hands out [catalog] at once: a test loads the asset off its fake clock,
  /// where a plain future's callbacks wouldn't run.
  @visibleForTesting
  static void debugUse(EmojiCatalog catalog) => _loading = SynchronousFuture(catalog);

  @visibleForTesting
  static EmojiCatalog parse(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return EmojiCatalog([
      for (final c in data['categories'] as List)
        EmojiCategory(c['label'] as String, c['icon'] as String, [
          for (final e in c['emojis'] as List)
            EmojiEntry(e[0] as String, e[1] as String, e.length > 2 ? (e[2] as String).split(' ').toList() : const []),
        ]),
    ]);
  }

  late final List<EmojiEntry> all = [for (final c in categories) ...c.emojis];

  /// Emoji whose name or a keyword matches [query], the best first: an exact
  /// name, a name's start, inside a name, then keywords, as on desktop.
  List<EmojiEntry> search(String query, {int limit = 60}) {
    final q = query.toLowerCase().trim().replaceAll('_', ' ');
    if (q.isEmpty) return const [];
    final scored = <(EmojiEntry, int)>[];
    for (final e in all) {
      var score = 0;
      if (e.name == q) {
        score = 100;
      } else if (e.name.startsWith(q)) {
        score = 80;
      } else if (e.name.contains(q)) {
        score = 50;
      } else {
        for (final k in e.keywords) {
          if (k == q) {
            score = 70;
            break;
          } else if (k.startsWith(q)) {
            score = score < 40 ? 40 : score;
          } else if (k.contains(q)) {
            score = score < 20 ? 20 : score;
          }
        }
      }
      if (score > 0) scored.add((e, score));
    }
    scored.sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : a.$1.name.length - b.$1.name.length);
    return [for (final (e, _) in scored.take(limit)) e];
  }

  /// The emoji's name, for screen readers and search.
  String? nameOf(String emoji) => _byEmoji[emoji]?.name;

  late final Map<String, EmojiEntry> _byEmoji = {for (final e in all) e.emoji: e};

  /// Used this session, the latest first: Unicode emoji, or a custom emoji's
  /// `<:id:>` code.
  static final ValueNotifier<List<String>> recent = ValueNotifier(const []);

  static void used(String emojiOrCode) {
    recent.value = [emojiOrCode, ...recent.value.where((e) => e != emojiOrCode)].take(24).toList();
  }
}

// Everything an emoji is drawn from: pictographs and their variation
// selectors, joiners, skin tones, keycaps, flags' regional indicators and tags.
// The analyzer checks these without the unicode flag, which \p{…} and astral
// ranges need; the tests run them.
final _emojiParts = RegExp(
  // ignore: valid_regexps
  '[\\p{Extended_Pictographic}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}\u{1F3FB}-\u{1F3FF}\u{1F1E6}-\u{1F1FF}\u{E0020}-\u{E007F}]',
  unicode: true,
);
final _customEmoji = RegExp(r'<:[0-9a-fA-F-]{8,}:>');
// ignore: valid_regexps
final _pictograph = RegExp('\\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

/// Whether [text] is only emoji (and spaces), at most [max] of them: such a
/// message shows them large, as on desktop.
bool isJumboEmoji(String text, {int max = 5}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  final withoutCustom = trimmed.replaceAll(_customEmoji, '');
  if (withoutCustom.replaceAll(_emojiParts, '').replaceAll(RegExp(r'\s'), '').isNotEmpty) return false;
  final count = _customEmoji.allMatches(trimmed).length + _pictograph.allMatches(withoutCustom).length;
  return count > 0 && count <= max;
}
