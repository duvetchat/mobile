// The app's stores kept in memory, for tests: the app itself keeps them on the
// device.
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/cache.dart';
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/launchpad.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';

class MemoryAppearanceStore implements AppearanceStore {
  String? mode;
  String? replyGesture;
  @override
  Future<String?> read() async => mode;

  @override
  Future<void> write(String mode) async => this.mode = mode;

  @override
  Future<String?> readReplyGesture() async => replyGesture;

  @override
  Future<void> writeReplyGesture(String gesture) async => replyGesture = gesture;
}

/// Keeps the tokens until the app exits.
class MemorySessionStore implements SessionStore {
  StoredSession? _session;
  MemorySessionStore([this._session]);

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
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

class MemoryLaunchpadStore implements LaunchpadStore {
  String? choice;
  MemoryLaunchpadStore([this.choice]);

  @override
  Future<String?> read() async => choice;

  @override
  Future<void> write(String choice) async => this.choice = choice;
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

class MemoryCallHistoryStore implements CallHistoryStore {
  final data = <String, String>{};

  @override
  Future<String?> read(String userId) async => data[userId];

  @override
  Future<void> write(String userId, String json) async => data[userId] = json;

  @override
  Future<void> clearAll() async => data.clear();
}
