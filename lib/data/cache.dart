import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// What the app keeps to open without the network: who's signed in, the
/// conversations, the Spaces, and the last page of each chat opened.
///
/// It's JSON in the app's own support directory, per account; signing out
/// deletes it.
abstract interface class ChatCacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String json);
  Future<void> clear();
}

class FileChatCacheStore implements ChatCacheStore {
  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/cache').create(recursive: true);
  }

  String _name(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  @override
  Future<String?> read(String key) async {
    final file = File('${(await _dir()).path}/${_name(key)}.json');
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String key, String json) async {
    final file = File('${(await _dir()).path}/${_name(key)}.json');
    await file.writeAsString(json, flush: true);
  }

  @override
  Future<void> clear() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class MemoryChatCacheStore implements ChatCacheStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String json) async => data[key] = json;
  @override
  Future<void> clear() async => data.clear();
}

/// The cache over a store, with the models' JSON.
class ChatCache {
  static const pageSize = 50;
  final ChatCacheStore _store;
  ChatCache(this._store);

  final _pending = <String, Timer>{};

  /// Writes [json] under [key] a moment later, once per burst.
  void _later(String key, Object? Function() json) {
    _pending[key]?.cancel();
    _pending[key] = Timer(const Duration(milliseconds: 500), () async {
      _pending.remove(key);
      try {
        await _store.write(key, jsonEncode(json()));
      } catch (e) {
        debugPrint('cache: $e');
      }
    });
  }

  Future<Map<String, Object?>?> _read(String key) async {
    try {
      final raw = await _store.read(key);
      return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
    } catch (e) {
      debugPrint('cache: $e');
      return null;
    }
  }

  void saveHome({
    required Profile profile,
    required List<ConversationSummary> conversations,
    required List<Space> spaces,
  }) => _later(
    'home',
    () => {
      'profile': profileToJson(profile),
      'conversations': [for (final c in conversations) conversationToJson(c)],
      'spaces': [for (final s in spaces) spaceToJson(s)],
    },
  );

  Future<({Profile profile, List<ConversationSummary> conversations, List<Space> spaces})?> loadHome() async {
    final j = await _read('home');
    if (j == null) return null;
    try {
      return (
        profile: profileFromJson(j['profile']! as Map<String, Object?>),
        conversations: [for (final c in j['conversations']! as List) conversationFromJson(c as Map<String, Object?>)],
        spaces: [for (final s in j['spaces']! as List) spaceFromJson(s as Map<String, Object?>)],
      );
    } catch (e) {
      debugPrint('cache: $e');
      return null;
    }
  }

  void savePage(String chatId, List<ChatMessage> page) {
    final last = page.length > pageSize ? page.sublist(page.length - pageSize) : page;
    _later(
      'chat_$chatId',
      () => {
        'messages': [for (final m in last) messageToJson(m)],
      },
    );
  }

  Future<List<ChatMessage>?> loadPage(String chatId) async {
    final j = await _read('chat_$chatId');
    if (j == null) return null;
    try {
      return [for (final m in j['messages']! as List) messageFromJson(m as Map<String, Object?>)];
    } catch (e) {
      debugPrint('cache: $e');
      return null;
    }
  }

  Future<void> clear() async {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    try {
      await _store.clear();
    } catch (e) {
      debugPrint('cache: $e');
    }
  }
}

// -----------------------------------------------------------------------------
// JSON
// -----------------------------------------------------------------------------

Map<String, Object?> profileToJson(Profile p) => {
  'id': p.id,
  'username': p.username,
  'alias': p.alias,
  'avatarUrl': p.avatarUrl,
  'bannerUrl': p.bannerUrl,
  'bio': p.bio,
  'emailVerified': p.emailVerified,
  'status': p.status.name,
};

Profile profileFromJson(Map<String, Object?> j) => Profile(
  id: j['id']! as String,
  username: j['username']! as String,
  alias: j['alias'] as String?,
  avatarUrl: j['avatarUrl'] as String?,
  bannerUrl: j['bannerUrl'] as String?,
  bio: j['bio'] as String?,
  emailVerified: j['emailVerified'] as bool? ?? true,
  status: j['status'] == Presence.doNotDisturb.name ? Presence.doNotDisturb : Presence.online,
);

Map<String, Object?> conversationToJson(ConversationSummary c) => {
  'id': c.id,
  'title': c.title,
  'isGroup': c.isGroup,
  'avatarUrl': c.avatarUrl,
  'otherUserId': c.otherUserId,
  'memberCount': c.memberCount,
  'updatedAt': c.updatedAt?.toUtc().toIso8601String(),
  'ownerId': c.ownerId,
  'name': c.name,
};

ConversationSummary conversationFromJson(Map<String, Object?> j) => ConversationSummary(
  id: j['id']! as String,
  title: j['title']! as String,
  isGroup: j['isGroup']! as bool,
  avatarUrl: j['avatarUrl'] as String?,
  otherUserId: j['otherUserId'] as String?,
  memberCount: j['memberCount'] as int? ?? 2,
  updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '')?.toLocal(),
  ownerId: j['ownerId'] as String?,
  name: j['name'] as String?,
);

Map<String, Object?> spaceToJson(Space s) => {
  'id': s.id,
  'name': s.name,
  'iconUrl': s.iconUrl,
  'sections': [
    for (final section in s.sections)
      {
        'name': section.name,
        'rooms': [
          for (final r in section.rooms)
            {'id': r.id, 'name': r.name, 'voice': r.kind == RoomKind.voice, 'position': r.position},
        ],
      },
  ],
};

Space spaceFromJson(Map<String, Object?> j) => Space(
  id: j['id']! as String,
  name: j['name']! as String,
  iconUrl: j['iconUrl'] as String?,
  sections: [
    for (final section in j['sections']! as List)
      RoomSection(
        name: (section as Map)['name'] as String?,
        rooms: [
          for (final r in section['rooms'] as List)
            Room(
              id: (r as Map)['id'] as String,
              spaceId: j['id']! as String,
              name: r['name'] as String,
              kind: r['voice'] == true ? RoomKind.voice : RoomKind.text,
              position: r['position'] as int? ?? 0,
            ),
        ],
      ),
  ],
);

Map<String, Object?> messageToJson(ChatMessage m) => {
  'id': m.id,
  'authorId': m.authorId,
  'authorName': m.authorName,
  'authorAvatarUrl': m.authorAvatarUrl,
  'content': m.content,
  'createdAt': m.createdAt.toUtc().toIso8601String(),
  'edited': m.edited,
  'isNotice': m.isNotice,
  'isVoice': m.isVoice,
  'pinned': m.pinned,
  'fromBot': m.fromBot,
  'fromWebhook': m.fromWebhook,
  if (m.isLoading) 'isLoading': true,
  if (m.isComponentsV2) 'isComponentsV2': true,
  if (m.rawComponents.isNotEmpty) 'components': m.rawComponents,
  'stickerUrl': m.stickerUrl,
  'attachments': [
    for (final a in m.attachments)
      {
        'id': a.id,
        'filename': a.filename,
        'contentType': a.contentType,
        'url': a.url,
        'width': a.width,
        'height': a.height,
        'sizeBytes': a.sizeBytes,
      },
  ],
  'embeds': [
    for (final e in m.embeds)
      {'title': e.title, 'description': e.description, 'url': e.url, 'imageUrl': e.imageUrl, 'provider': e.provider},
  ],
  if (m.reply case final r?)
    'reply': {
      'messageId': r.messageId,
      'authorId': r.authorId,
      'authorName': r.authorName,
      'content': r.content,
      if (r.mentionAuthor) 'mentionAuthor': true,
    },
  'reactions': [
    for (final r in m.reactions)
      {
        'emoji': r.emoji,
        'emojiId': r.emojiId,
        'users': [...r.users],
      },
  ],
};

ChatMessage messageFromJson(Map<String, Object?> j) => ChatMessage(
  id: j['id']! as String,
  authorId: j['authorId'] as String?,
  authorName: j['authorName']! as String,
  authorAvatarUrl: j['authorAvatarUrl'] as String?,
  content: j['content']! as String,
  createdAt: DateTime.parse(j['createdAt']! as String).toLocal(),
  edited: j['edited'] as bool? ?? false,
  isNotice: j['isNotice'] as bool? ?? false,
  isVoice: j['isVoice'] as bool? ?? false,
  pinned: j['pinned'] as bool? ?? false,
  fromBot: j['fromBot'] as bool? ?? false,
  fromWebhook: j['fromWebhook'] as bool? ?? false,
  isLoading: j['isLoading'] as bool? ?? false,
  isComponentsV2: j['isComponentsV2'] as bool? ?? false,
  components: componentsFromJson([
    for (final c in j['components'] as List? ?? const [])
      if (c is Map<String, dynamic>) c,
  ]),
  rawComponents: [
    for (final c in j['components'] as List? ?? const [])
      if (c is Map<String, dynamic>) c,
  ],
  stickerUrl: j['stickerUrl'] as String?,
  attachments: [
    for (final a in j['attachments'] as List? ?? const [])
      MessageAttachment(
        id: (a as Map)['id'] as String,
        filename: a['filename'] as String,
        contentType: a['contentType'] as String,
        url: a['url'] as String,
        width: a['width'] as int?,
        height: a['height'] as int?,
        sizeBytes: a['sizeBytes'] as int? ?? 0,
      ),
  ],
  embeds: [
    for (final e in j['embeds'] as List? ?? const [])
      MessageEmbed(
        title: (e as Map)['title'] as String?,
        description: e['description'] as String?,
        url: e['url'] as String?,
        imageUrl: e['imageUrl'] as String?,
        provider: e['provider'] as String?,
      ),
  ],
  reply: switch (j['reply']) {
    final Map r => MessageReply(
      messageId: r['messageId'] as String,
      authorId: r['authorId'] as String?,
      authorName: r['authorName'] as String,
      content: r['content'] as String,
      mentionAuthor: r['mentionAuthor'] as bool? ?? false,
    ),
    _ => null,
  },
  reactions: [
    for (final r in j['reactions'] as List? ?? const [])
      Reaction(
        emoji: (r as Map)['emoji'] as String,
        emojiId: r['emojiId'] as String?,
        users: {for (final u in r['users'] as List) u as String},
      ),
  ],
);
