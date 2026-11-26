/// This device's search of its conversations' messages (decision 42; PLAN-E2E-CLIENTES.md, Task 21, as the desktop's
/// Task 20): the core's `search` over its own database, by what a message's text says (its words, its mentions) and
/// what its envelope holds (the kinds of its files), and by its author and when the API took it. The API can't read a
/// message, so it never gets words: it only knows what it keeps in the clear, which pins and stickers are. The desktop's
/// engine/search.ts in Dart.
library;

import 'content.dart';
import 'host.dart';

/// The most rows a page of the core's search gives.
const devicePage = 100;

/// The search box's has: values the device finds, as the core names them: `file` is any file.
const _deviceKinds = {'image': 'image', 'video': 'video', 'sound': 'audio', 'file': 'file'};

/// What the core's search takes: every conversation's messages without [conversationId], newest first, a page of
/// [limit] rows ([devicePage] at most) past [offset].
class DeviceSearch {
  const DeviceSearch({
    this.text,
    this.conversationId,
    this.from = const [],
    this.mentions = const [],
    this.after,
    this.before,
    this.has = const [],
    this.limit = devicePage,
    this.offset = 0,
  });

  /// Its words, each the start of one of a message's words (a one-letter one whole), its case and accents aside.
  final String? text;
  final String? conversationId;

  /// Written by one of these users.
  final List<String> from;

  /// Mentioning one of these users, in its text or in the list its sender gave the API.
  final List<String> mentions;

  /// Taken by the API at [after] or later, and before [before].
  final DateTime? after;
  final DateTime? before;

  /// With a file of one of these kinds, as the core names them.
  final List<String> has;
  final int limit;
  final int offset;

  /// The same search, of [conversationId] (every conversation without it), a page of [limit] rows past [offset].
  DeviceSearch page({String? conversationId, required int limit, int offset = 0}) => DeviceSearch(
    text: text,
    conversationId: conversationId,
    from: from,
    mentions: mentions,
    after: after,
    before: before,
    has: has,
    limit: limit,
    offset: offset,
  );

  Map<String, Object?> toCommand() => {
    'cmd': 'search',
    'text': ?text,
    'conversation_id': ?conversationId,
    if (from.isNotEmpty) 'from': from,
    if (mentions.isNotEmpty) 'mentions': mentions,
    'after': ?after?.millisecondsSinceEpoch,
    'before': ?before?.millisecondsSinceEpoch,
    if (has.isNotEmpty) 'has': has,
    'limit': limit,
    'offset': offset,
  };
}

/// Whether a search's text has words: a letter or a digit, as the core's search and the API's read words.
bool hasWords(String text) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

/// What a search box's search takes to the device: its words, authors, mentions, dates and kinds of files. Null when it
/// needs what only the API knows ([pinned], has:sticker), names only kinds of files the device can't tell (link, embed:
/// a conversation's message has no preview, and its links aren't searched), or has nothing to search for (no filter,
/// and no words: punctuation alone is none, for which the core adds no filter and would list every message), which the
/// API answers as it answers a Space's.
DeviceSearch? deviceSearchOf({
  String text = '',
  List<String> authors = const [],
  List<String> mentions = const [],
  List<String> has = const [],
  bool? pinned,
  DateTime? after,
  DateTime? before,
}) {
  final kinds = [for (final value in has) ?_deviceKinds[value]];
  if (pinned != null || has.contains('sticker') || (has.isNotEmpty && kinds.isEmpty)) return null;
  final words = hasWords(text);
  if (!words && authors.isEmpty && mentions.isEmpty && after == null && before == null && kinds.isEmpty) return null;
  return DeviceSearch(
    text: words ? text : null,
    from: authors,
    mentions: mentions,
    after: after,
    before: before,
    has: kinds,
  );
}

/// Whether the API's search of a conversation takes it, as its e2e answers one: never words, and of has: only file and
/// sticker (ConversationController.SearchMessages). A text without words goes to it as no text.
bool apiTakes({String text = '', List<String> has = const []}) =>
    !hasWords(text) && has.every((value) => value == 'file' || value == 'sticker');

/// A page of what the core found, and how many it found in all: neither a deleted message nor one that waits.
typedef DeviceFound = ({int total, List<ShownMessage> messages});

/// The core's search: the one way this device's database is searched.
Future<DeviceFound> searchDevice(CoreHost host, DeviceSearch search) async {
  final found = await host.handle<Map<String, Object?>>(search.toCommand());
  return (
    total: found['total']! as int,
    messages: [for (final row in found['messages']! as List) ShownMessage.of((row as Map).cast<String, Object?>())],
  );
}

/// [most] of what [search] finds that [keep] keeps (a row it gives null for is left out: the person's own still being
/// sent, a conversation the app doesn't list), newest first, the core's pages read from [request]'s offset on past the
/// rows left out, so they push none of the others out (M3 of the desktop's review); with the core's total, and where
/// the next page starts: past the last row read, null at the end.
Future<({List<T> found, int total, int? next})> deviceFinds<T>(
  Future<DeviceFound> Function(DeviceSearch request) search,
  DeviceSearch request, {
  required int most,
  required T? Function(ShownMessage row) keep,
}) async {
  final found = <T>[];
  var offset = request.offset;
  while (true) {
    final page = await search(
      request.page(conversationId: request.conversationId, limit: request.limit, offset: offset),
    );
    for (final row in page.messages) {
      offset++;
      if (keep(row) case final kept?) found.add(kept);
      if (found.length == most) return (found: found, total: page.total, next: offset < page.total ? offset : null);
    }
    if (page.messages.isEmpty || offset >= page.total) return (found: found, total: page.total, next: null);
  }
}
