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

  /// The keys of what's kept.
  Future<List<String>> keys();
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

  // The files' names, without `.json`: keys as [_name] makes them, which
  // [read] and [write] take as they are.
  @override
  Future<List<String>> keys() async => [
    await for (final file in (await _dir()).list())
      if (file is File && file.path.endsWith('.json')) file.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), ''),
  ];
}

class MemoryChatCacheStore implements ChatCacheStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String json) async => data[key] = json;
  @override
  Future<void> clear() async => data.clear();
  @override
  Future<List<String>> keys() async => [...data.keys];
}

// A change of the pages' messages ([ChatCache.changeMessages]).
typedef _Change = ChatMessage Function(String chatId, ChatMessage m);

/// The cache over a store, with the models' JSON.
class ChatCache {
  static const pageSize = 50;
  final ChatCacheStore _store;
  ChatCache(this._store);

  final _pending = <String, Timer>{};

  // Each key's writes under way, the last one queued: they go one at a time,
  // in the order they came. Two at once could mix in its file, and a change
  // of the pages, which reads a page and writes it back, could write an older
  // one over a newer.
  final _writes = <String, Future<void>>{};

  // Runs [write] once the writes of [key] before it are done.
  Future<void> _inTurn(String key, Future<void> Function() write) {
    late final Future<void> turn;
    turn = _writes[key] = (_writes[key] ?? Future.value())
        .then((_) => write())
        .catchError((Object e) => debugPrint('cache: $e'))
        .whenComplete(() {
          if (identical(_writes[key], turn)) _writes.remove(key);
        });
    return turn;
  }

  /// Writes [json] under [key] a moment later, once per burst.
  void _later(String key, Object? Function() json) {
    _pending[key]?.cancel();
    _pending[key] = Timer(const Duration(milliseconds: 500), () {
      _pending.remove(key);
      final data = json();
      unawaited(_inTurn(key, () => _store.write(key, jsonEncode(data))));
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

  /// The categories folded away, by ID.
  void saveCollapsed(Set<String> categoryIds) => _later(
    'collapsed',
    () => {
      'ids': [...categoryIds],
    },
  );

  Future<Set<String>?> loadCollapsed() async {
    final j = await _read('collapsed');
    if (j == null) return null;
    try {
      return {...(j['ids']! as List).cast<String>()};
    } catch (e) {
      debugPrint('cache: $e');
      return null;
    }
  }

  /// The chats pinned to the top of Chats, by key.
  void savePinned(Set<String> keys) => _later(
    'pinned',
    () => {
      'keys': [...keys],
    },
  );

  Future<Set<String>?> loadPinned() async {
    final j = await _read('pinned');
    if (j == null) return null;
    try {
      return {...(j['keys']! as List).cast<String>()};
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

  static const _page = 'chat_';

  // The pages saved and not written yet, by chat ID.
  final _pages = <String, List<ChatMessage>>{};

  static Map<String, Object?> _pageToJson(List<ChatMessage> page) => {
    'messages': [for (final m in page) messageToJson(m)],
  };

  static List<ChatMessage> _pageFromJson(Map<String, Object?> j) => [
    for (final m in j['messages']! as List) messageFromJson(m as Map<String, Object?>),
  ];

  void savePage(String chatId, List<ChatMessage> page) {
    _pages[chatId] = page.length > pageSize ? page.sublist(page.length - pageSize) : page;
    _later('$_page$chatId', () => _pageToJson(_pages.remove(chatId)!));
  }

  Future<List<ChatMessage>?> loadPage(String chatId) async {
    final j = await _read('$_page$chatId');
    if (j == null) return null;
    try {
      return _pageFromJson(j);
    } catch (e) {
      debugPrint('cache: $e');
      return null;
    }
  }

  // How many times it was cleared: a change of the pages begun before writes
  // nothing after.
  var _clears = 0;

  // The passes over the pages that change them, one after another.
  Future<void> _changes = Future.value();

  // The changes the pass queued last makes, by ID, until it begins: one
  // queued meanwhile for an ID takes the place of the one before.
  Map<String, _Change>? _queued;

  /// Changes the messages of the pages kept, those not written yet included:
  /// [change] answers each as it's to be kept, given its chat's ID, or the
  /// very message to leave it as it is. Only the pages with [id] in them (a
  /// user's, say) are parsed: no other can change. The changes queued while
  /// a pass is under way wait for one more pass, which makes the last one
  /// queued for each ID.
  Future<void> changeMessages(String id, ChatMessage Function(String chatId, ChatMessage m) change) {
    if (_queued case final queued?) {
      queued[id] = change;
      return _changes;
    }
    final queued = _queued = {id: change};
    final clears = _clears;
    return _changes = _changes
        .then((_) {
          if (identical(_queued, queued)) _queued = null;
          return _change(clears, queued);
        })
        .catchError((Object e) => debugPrint('cache: $e'));
  }

  Future<void> _change(int clears, Map<String, _Change> changes) async {
    // The page changed, or null when none of its messages is.
    List<ChatMessage>? changed(String chatId, List<ChatMessage> page) {
      final after = [for (final m in page) changes.values.fold(m, (was, change) => change(chatId, was))];
      return after.indexed.every((e) => identical(e.$2, page[e.$1])) ? null : after;
    }

    // One not written yet changes before it is.
    void changeWaiting(String chatId) {
      if (changed(chatId, _pages[chatId]!) case final page?) _pages[chatId] = page;
    }

    if (clears != _clears) return;
    for (final chatId in [..._pages.keys]) {
      changeWaiting(chatId);
    }
    final List<String> keys;
    try {
      keys = await _store.keys();
    } catch (e) {
      debugPrint('cache: $e');
      return;
    }
    // A page whose first write is under way isn't listed yet: it takes its turn after that write too.
    for (final key in {...keys, ..._writes.keys}) {
      if (clears != _clears) return;
      if (!key.startsWith(_page)) continue;
      final chatId = key.substring(_page.length);
      // In turn with the page's writes: read once the one under way is done,
      // and written back before the next.
      await _inTurn(key, () async {
        final raw = await _store.read(key);
        if (clears != _clears) return;
        // Saved again meanwhile: that page is the one to write.
        if (_pages.containsKey(chatId)) {
          changeWaiting(chatId);
          return;
        }
        if (raw == null || !changes.keys.any(raw.contains)) return;
        if (changed(chatId, _pageFromJson(jsonDecode(raw) as Map<String, Object?>)) case final page?) {
          await _store.write(key, jsonEncode(_pageToJson(page)));
        }
      });
    }
  }

  Future<void> clear() async {
    _clears++;
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _pages.clear();
    _queued = null;
    // A change of the pages under way writes nothing more, and it and the
    // writes under way end before the store goes.
    await _changes;
    await Future.wait([..._writes.values]);
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
  'bannerUrl': s.bannerUrl,
  'ownerId': s.ownerId,
  'sections': [
    for (final section in s.sections)
      {
        'id': section.id,
        'name': section.name,
        'rooms': [
          for (final r in section.rooms)
            {
              'id': r.id,
              'name': r.name,
              'voice': r.kind == RoomKind.voice,
              'position': r.position,
              'description': r.description,
            },
        ],
      },
  ],
};

Space spaceFromJson(Map<String, Object?> j) => Space(
  id: j['id']! as String,
  name: j['name']! as String,
  iconUrl: j['iconUrl'] as String?,
  bannerUrl: j['bannerUrl'] as String?,
  ownerId: j['ownerId'] as String?,
  sections: [
    for (final section in j['sections']! as List)
      RoomSection(
        id: (section as Map)['id'] as String?,
        name: section['name'] as String?,
        rooms: [
          for (final r in section['rooms'] as List)
            Room(
              id: (r as Map)['id'] as String,
              spaceId: j['id']! as String,
              name: r['name'] as String,
              kind: r['voice'] == true ? RoomKind.voice : RoomKind.text,
              position: r['position'] as int? ?? 0,
              description: r['description'] as String?,
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
  if (m.call case final c?)
    'call': {
      'participants': c.participants,
      'startedAt': c.startedAt.toUtc().toIso8601String(),
      'endedAt': c.endedAt.toUtc().toIso8601String(),
    },
  'isVoice': m.isVoice,
  'pinned': m.pinned,
  'fromBot': m.fromBot,
  'fromWebhook': m.fromWebhook,
  'webhookId': ?m.webhookId,
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
      {
        'title': e.title,
        'description': e.description,
        'url': e.url,
        'imageUrl': e.imageUrl,
        'imageWidth': e.imageWidth,
        'imageHeight': e.imageHeight,
        'thumbnailUrl': e.thumbnailUrl,
        'videoUrl': e.videoUrl,
        'videoContentType': e.videoContentType,
        'provider': e.provider,
        if (e.colors.isNotEmpty) 'colors': e.colors,
        'authorName': ?e.authorName,
        'authorUrl': ?e.authorUrl,
        'authorIconUrl': ?e.authorIconUrl,
        if (e.fields.isNotEmpty)
          'fields': [
            for (final f in e.fields) {'name': f.name, 'value': f.value, 'inline': f.inline},
          ],
        'footer': ?e.footer,
        'timestamp': ?e.timestamp?.toUtc().toIso8601String(),
      },
  ],
  if (m.reply case final r?)
    'reply': {
      'messageId': r.messageId,
      'authorId': r.authorId,
      'authorName': r.authorName,
      'content': r.content,
      if (r.mentionAuthor) 'mentionAuthor': true,
      if (r.deleted) 'deleted': true,
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
  call: _callFromJson(j['call']),
  isVoice: j['isVoice'] as bool? ?? false,
  pinned: j['pinned'] as bool? ?? false,
  fromBot: j['fromBot'] as bool? ?? false,
  fromWebhook: j['fromWebhook'] as bool? ?? false,
  webhookId: j['webhookId'] as String?,
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
        imageWidth: e['imageWidth'] as int?,
        imageHeight: e['imageHeight'] as int?,
        thumbnailUrl: e['thumbnailUrl'] as String?,
        videoUrl: e['videoUrl'] as String?,
        videoContentType: e['videoContentType'] as String?,
        provider: e['provider'] as String?,
        colors: [for (final c in e['colors'] as List? ?? const []) c as int],
        authorName: e['authorName'] as String?,
        authorUrl: e['authorUrl'] as String?,
        authorIconUrl: e['authorIconUrl'] as String?,
        fields: [
          for (final f in e['fields'] as List? ?? const [])
            (name: (f as Map)['name'] as String, value: f['value'] as String, inline: f['inline'] as bool? ?? false),
        ],
        footer: e['footer'] as String?,
        timestamp: switch (e['timestamp']) {
          final String t => DateTime.tryParse(t)?.toLocal(),
          _ => null,
        },
      ),
  ],
  reply: switch (j['reply']) {
    final Map r => MessageReply(
      messageId: r['messageId'] as String,
      authorId: r['authorId'] as String?,
      authorName: r['authorName'] as String,
      content: r['content'] as String,
      mentionAuthor: r['mentionAuthor'] as bool? ?? false,
      deleted: r['deleted'] as bool? ?? false,
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

CallNotice? _callFromJson(Object? j) {
  if (j is! Map<String, Object?>) return null;
  final startedAt = DateTime.tryParse(j['startedAt'] as String? ?? '');
  final endedAt = DateTime.tryParse(j['endedAt'] as String? ?? '');
  if (startedAt == null || endedAt == null) return null;
  return CallNotice(
    participants: [
      for (final id in j['participants'] as List? ?? const [])
        if (id is String) id,
    ],
    startedAt: startedAt.toLocal(),
    endedAt: endedAt.toLocal(),
  );
}
