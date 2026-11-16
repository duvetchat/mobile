import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';

/// What the composer is completing: a mention after `@`, a room after `#`, or
/// an emoji after `:` (two letters at least, so "10:30" stays a time).
typedef ComposerQuery = ({String trigger, String query, int start});

/// The composer's text as people read it, `@Maya`, `#general` and `:party:`,
/// holding which mention, room and custom emoji each picked token stands for.
/// [encoded] writes them as the API wants them: `<@id>`, `<#id>` and `<:id:>`.
///
/// The field shows the readable text itself, so the caret and selection
/// keep their places; picked tokens are drawn in the accent.
class ComposerController extends TextEditingController {
  final Color Function() accent;
  ComposerController({required this.accent});

  final _mentions = <String, String>{}; // '@Maya' → user ID
  final _emojis = <String, String>{}; // ':party:' → emoji ID
  final _rooms = <String, String>{}; // '#general' → room ID

  /// The `@`/`#`/`:` token the caret is in, if any.
  ComposerQuery? get query {
    final caret = selection.baseOffset;
    if (!selection.isCollapsed || caret < 0 || caret > text.length) return null;
    final before = text.substring(0, caret);
    final match = RegExp(r'(?:^|\s)([@:#])([^\s@:#]*)$').firstMatch(before);
    if (match == null) return null;
    final trigger = match.group(1)!;
    final q = match.group(2)!;
    if (trigger == ':' && q.length < 2) return null;
    return (trigger: trigger, query: q, start: caret - q.length - 1);
  }

  void insertMention(Member member) {
    final token = '@${member.displayName}';
    _mentions[token] = member.userId;
    _replaceQueryWith('$token ');
  }

  void insertRoom(Room room) {
    final token = '#${room.name}';
    _rooms[token] = room.id;
    _replaceQueryWith('$token ', trigger: '#');
  }

  void insertCustomEmoji(CustomEmoji emoji) {
    final token = ':${emoji.name}:';
    _emojis[token] = emoji.id;
    _replaceQueryWith('$token ', trigger: ':');
  }

  /// Puts a Unicode emoji at the caret, or in place of the `:query` typed.
  void insertEmoji(String emoji) => _replaceQueryWith(emoji, trigger: ':');

  /// Puts `@` at the caret, with a space before it when needed, which opens
  /// the mention suggestions.
  void startMention() {
    final caret = selection.isValid ? selection.baseOffset : text.length;
    final needsSpace = caret > 0 && !RegExp(r'\s').hasMatch(text[caret - 1]);
    _insert(caret, caret, needsSpace ? ' @' : '@');
  }

  void _replaceQueryWith(String replacement, {String? trigger}) {
    final q = query;
    if (q != null && (trigger == null || q.trigger == trigger)) {
      _insert(q.start, q.start + q.query.length + 1, replacement);
    } else {
      final caret = selection.isValid ? selection.baseOffset : text.length;
      final end = selection.isValid ? selection.extentOffset : caret;
      _insert(caret < end ? caret : end, caret < end ? end : caret, replacement);
    }
  }

  void _insert(int start, int end, String replacement) {
    value = TextEditingValue(
      text: text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  /// The text to send, mentions, rooms and custom emoji written as codes.
  String get encoded {
    var out = text;
    // Longest first, so "@Maya Lee" wins over "@Maya".
    final tokens = [..._mentions.keys, ..._emojis.keys, ..._rooms.keys]..sort((a, b) => b.length - a.length);
    for (final token in tokens) {
      final code = switch (token[0]) {
        '@' => '<@${_mentions[token]}>',
        '#' => '<#${_rooms[token]}>',
        _ => '<:${_emojis[token]}:>',
      };
      out = out.replaceAll(token, code);
    }
    return out;
  }

  @override
  void clear() {
    _mentions.clear();
    _emojis.clear();
    _rooms.clear();
    super.clear();
  }

  /// Loads a message's text, as sent, to edit it: its mention, room and emoji
  /// codes become `@Name`, `#name` and `:name:` again, kept as tokens.
  void setEncoded(
    String content, {
    required String? Function(String userId) nameOf,
    required String? Function(String emojiId) emojiNameOf,
    String? Function(String roomId)? roomNameOf,
  }) {
    _mentions.clear();
    _emojis.clear();
    _rooms.clear();
    final readable = content.replaceAllMapped(
      RegExp(r'<@([0-9a-fA-F-]{8,})>|<:([0-9a-fA-F-]{8,}):>|<#([0-9a-fA-F-]{8,})>'),
      (m) {
        if (m.group(1) case final id?) {
          final token = '@${nameOf(id) ?? id.substring(0, 8)}';
          _mentions[token] = id;
          return token;
        }
        if (m.group(3) case final id?) {
          final token = '#${roomNameOf?.call(id) ?? 'unknown'}';
          _rooms[token] = id;
          return token;
        }
        final id = m.group(2)!;
        final token = ':${emojiNameOf(id) ?? 'emoji'}:';
        _emojis[token] = id;
        return token;
      },
    );
    value = TextEditingValue(
      text: readable,
      selection: TextSelection.collapsed(offset: readable.length),
    );
  }

  /// The picked mentions, rooms and custom emoji: their tokens to user, room
  /// and emoji IDs.
  ({Map<String, String> mentions, Map<String, String> emojis, Map<String, String> rooms}) get picked =>
      (mentions: Map.unmodifiable(_mentions), emojis: Map.unmodifiable(_emojis), rooms: Map.unmodifiable(_rooms));

  /// Puts back a draft's text and picked tokens.
  void restore(
    String text, {
    Map<String, String> mentions = const {},
    Map<String, String> emojis = const {},
    Map<String, String> rooms = const {},
  }) {
    _mentions
      ..clear()
      ..addAll(mentions);
    _emojis
      ..clear()
      ..addAll(emojis);
    _rooms
      ..clear()
      ..addAll(rooms);
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final tokens = [..._mentions.keys, ..._emojis.keys, ..._rooms.keys].where(text.contains).toList();
    // Emoji as large as in the bubble; while an IME composes, its underline.
    final composing = withComposing && value.isComposingRangeValid;
    List<TextSpan> plain(String text) =>
        style == null || composing ? [TextSpan(text: text)] : DuvetType.withEmoji(text, base: style);
    if (tokens.isEmpty) {
      if (composing || style == null || DuvetType.emojiScale == 1) {
        return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
      }
      return TextSpan(style: style, children: plain(text));
    }
    tokens.sort((a, b) => b.length - a.length);
    final pattern = RegExp(tokens.map(RegExp.escape).join('|'));
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > at) spans.addAll(plain(text.substring(at, m.start)));
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(color: accent(), fontWeight: FontWeight.w700),
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.addAll(plain(text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}
