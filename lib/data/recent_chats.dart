import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// A chat in the Chats tab: one you opened, or a DM with something new. The
/// API has no such list; the client keeps it, per account, on the device.
class RecentChat {
  final ChatTarget target;

  /// The title it was opened with, e.g. `# general` or a DM's name.
  final String title;

  /// When it last had a message, or was opened.
  final DateTime at;

  /// The newest message, as the list shows it.
  final String? previewId;
  final String? previewAuthorId;
  final String? previewAuthor;
  final String? previewText;

  const RecentChat({
    required this.target,
    required this.title,
    required this.at,
    this.previewId,
    this.previewAuthorId,
    this.previewAuthor,
    this.previewText,
  });

  RecentChat _withMessage(ChatMessage m, String Function(String content) readable) => RecentChat(
    target: target,
    title: title,
    at: m.createdAt.isAfter(at) ? m.createdAt : at,
    previewId: m.id,
    previewAuthorId: m.authorId,
    previewAuthor: m.authorName,
    previewText: previewOf(m, readable),
  );

  Map<String, Object?> toJson() => {
    'kind': target is RoomTarget ? 'room' : 'conversation',
    'id': target.id,
    if (target case RoomTarget(:final spaceId)) 'spaceId': spaceId,
    'title': title,
    'at': at.toUtc().toIso8601String(),
    'previewId': previewId,
    'previewAuthorId': previewAuthorId,
    'previewAuthor': previewAuthor,
    'previewText': previewText,
  };

  static RecentChat? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final title = json['title'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (id is! String || title is! String || at == null) return null;
    final ChatTarget? target = switch ((json['kind'], json['spaceId'])) {
      ('room', final String spaceId) => RoomTarget(spaceId: spaceId, roomId: id),
      ('conversation', _) => ConversationTarget(id),
      _ => null,
    };
    if (target == null) return null;
    return RecentChat(
      target: target,
      title: title,
      at: at.toLocal(),
      previewId: json['previewId'] as String?,
      previewAuthorId: json['previewAuthorId'] as String?,
      previewAuthor: json['previewAuthor'] as String?,
      previewText: json['previewText'] as String?,
    );
  }
}

/// A message as a one-line preview: its text, or what it carries.
String previewOf(ChatMessage m, String Function(String content) readable) {
  if (m.isNotice) return 'pinned a message';
  if (m.stickerUrl != null) return 'Sticker';
  if (m.content.isNotEmpty) return readable(m.content).replaceAll('\n', ' ');
  if (m.attachments.isNotEmpty) {
    final images = m.attachments.where((a) => a.isImage).length;
    final noun = images == m.attachments.length
        ? (images == 1 ? 'photo' : 'photos')
        : (m.attachments.length == 1 ? 'file' : 'files');
    return m.attachments.length == 1 ? 'Sent a $noun' : 'Sent ${m.attachments.length} $noun';
  }
  if (m.embeds.isNotEmpty) return m.embeds.first.title ?? 'Sent a link';
  return 'Sent a message';
}

/// Keeps an account's recent chats between launches.
abstract interface class RecentChatsStore {
  Future<String?> read(String userId);
  Future<void> write(String userId, String json);

  /// Deletes every account's: a session can end before its account was
  /// known (refused at launch), and the phone has one account at a time.
  Future<void> clearAll();
}

/// In the keystore, next to the session: previews are message text.
class SecureRecentChatsStore implements RecentChatsStore {
  final FlutterSecureStorage _storage;
  const SecureRecentChatsStore([this._storage = const FlutterSecureStorage()]);

  static const _prefix = 'duvet_recent_chats_';

  @override
  Future<String?> read(String userId) => _storage.read(key: '$_prefix$userId');

  @override
  Future<void> write(String userId, String json) => _storage.write(key: '$_prefix$userId', value: json);

  @override
  Future<void> clearAll() async {
    for (final key in (await _storage.readAll()).keys) {
      if (key.startsWith(_prefix)) await _storage.delete(key: key);
    }
  }
}

class MemoryRecentChatsStore implements RecentChatsStore {
  final _data = <String, String>{};

  @override
  Future<String?> read(String userId) async => _data[userId];

  @override
  Future<void> write(String userId, String json) async => _data[userId] = json;

  @override
  Future<void> clearAll() async => _data.clear();
}

/// The recent chats, the newest first, for whoever is signed in.
class RecentChats {
  static const limit = 50;

  final RecentChatsStore _store;

  /// A message's text as people read it: mentions and custom emoji by name.
  final String Function(String content) _readable;
  RecentChats(this._store, {String Function(String content)? readable}) : _readable = readable ?? _same;

  static String _same(String content) => content;

  final ValueNotifier<List<RecentChat>> chats = ValueNotifier(const []);
  String? _userId;
  bool _saving = false;

  /// Loads [userId]'s list, keeping anything recorded while it loaded.
  Future<void> load(String userId) async {
    _userId = userId;
    List<RecentChat> saved;
    try {
      final raw = await _store.read(userId);
      saved = raw == null ? const [] : [for (final j in jsonDecode(raw) as List) ?RecentChat.fromJson(j)];
    } catch (e) {
      debugPrint('recent chats: $e');
      saved = const [];
    }
    if (_userId != userId) return;
    final live = {for (final c in chats.value) c.target.id};
    _publish([...chats.value, ...saved.where((c) => !live.contains(c.target.id))]);
  }

  /// Forgets the list in memory, on signing out; [forget] also deletes what
  /// was kept, any account's.
  Future<void> close({bool forget = false}) async {
    _userId = null;
    chats.value = const [];
    if (!forget) return;
    try {
      await _store.clearAll();
    } catch (e) {
      debugPrint('recent chats: $e');
    }
  }

  /// A chat was opened, showing [latest] as its newest message.
  /// It's dated by that message, as the list is by activity; by now only
  /// when it has none.
  void opened(ChatTarget target, String title, {ChatMessage? latest}) {
    final known = _find(target.id);
    var chat = RecentChat(
      target: target,
      title: title,
      at: latest?.createdAt ?? known?.at ?? DateTime.now(),
      previewId: known?.previewId,
      previewAuthorId: known?.previewAuthorId,
      previewAuthor: known?.previewAuthor,
      previewText: known?.previewText,
    );
    if (latest != null) chat = chat._withMessage(latest, _readable);
    _put(chat);
  }

  /// A message arrived in a room, which is listed once opened.
  void roomMessage(String roomId, ChatMessage m) {
    if (_find(roomId) case final known?) _put(known._withMessage(m, _readable));
  }

  /// A message arrived in a DM, which is listed from then on, under [title]
  /// when it's new here.
  void conversationMessage(String conversationId, ChatMessage m, {String? title}) {
    final known =
        _find(conversationId) ??
        RecentChat(target: ConversationTarget(conversationId), title: title ?? m.authorName, at: m.createdAt);
    _put(known._withMessage(m, _readable));
  }

  /// [m] is the chat's newest message, fetched again: what was sent while the
  /// app wasn't listening never reached the list. It shows unless the list
  /// has one as new (a live message can come before the fetch's answer).
  void caughtUp(String chatId, ChatMessage m) {
    if (_find(chatId) case final known? when known.previewId == null || m.createdAt.isAfter(known.at)) {
      _put(known._withMessage(m, _readable));
    }
  }

  /// The previewed message was edited: its text changes, not who wrote it,
  /// whom the event may not name.
  void edited(String chatId, ChatMessage m) {
    if (_find(chatId) case final known? when known.previewId == m.id) {
      _put(
        RecentChat(
          target: known.target,
          title: known.title,
          at: known.at,
          previewId: known.previewId,
          previewAuthorId: known.previewAuthorId,
          previewAuthor: known.previewAuthor,
          previewText: previewOf(m, _readable),
        ),
      );
    }
  }

  /// [userId] changed their name: the previews of their messages name them
  /// as [nameIn] says each chat does, and the list stays as it is when they
  /// all do already. A webhook's message has no author ID: its preview keeps
  /// the name it was sent with.
  void renamed(String userId, String Function(ChatTarget target) nameIn) {
    if (!chats.value.any((c) => c.previewAuthorId == userId && c.previewAuthor != nameIn(c.target))) return;
    _publish([
      for (final c in chats.value)
        if (c.previewAuthorId == userId)
          RecentChat(
            target: c.target,
            title: c.title,
            at: c.at,
            previewId: c.previewId,
            previewAuthorId: c.previewAuthorId,
            previewAuthor: nameIn(c.target),
            previewText: c.previewText,
          )
        else
          c,
    ]);
  }

  /// The previewed message was deleted: the one before it isn't known here.
  void deleted(String chatId, String messageId) {
    if (_find(chatId) case final known? when known.previewId == messageId) {
      _put(RecentChat(target: known.target, title: known.title, at: known.at, previewText: 'Message deleted'));
    }
  }

  /// A Space was deleted: its rooms leave the list. Answers their IDs.
  Set<String> forgetSpace(String spaceId) {
    final gone = {
      for (final c in chats.value)
        if (c.target case RoomTarget(spaceId: final space) when space == spaceId) c.target.id,
    };
    if (gone.isNotEmpty) _publish(chats.value.where((c) => !gone.contains(c.target.id)).toList());
    return gone;
  }

  RecentChat? _find(String id) => chats.value.where((c) => c.target.id == id).firstOrNull;

  void _put(RecentChat chat) => _publish([chat, ...chats.value.where((c) => c.target.id != chat.target.id)]);

  void _publish(List<RecentChat> list) {
    list.sort((a, b) => b.at.compareTo(a.at));
    chats.value = list.length > limit ? list.sublist(0, limit) : list;
    _save();
  }

  // One write per burst of changes: a busy room shouldn't write per message.
  void _save() {
    if (_saving || _userId == null) return;
    _saving = true;
    scheduleMicrotask(() async {
      _saving = false;
      final userId = _userId;
      if (userId == null) return;
      try {
        await _store.write(userId, jsonEncode([for (final c in chats.value) c.toJson()]));
      } catch (e) {
        debugPrint('recent chats: $e');
      }
    });
  }

  void dispose() => chats.dispose();
}
