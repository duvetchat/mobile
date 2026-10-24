import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How a call went, for this device.
enum CallOutcome {
  /// Talked: [CallRecord.duration] long.
  answered,

  /// It rang here and stopped before anyone answered it here.
  missed,

  /// Turned down here.
  declined,

  /// Called from here, and hung up before anyone answered.
  cancelled,

  /// Called from here; nobody answered.
  unanswered,
}

/// A call this device rang for, placed or took part in. Neither the API nor
/// the gateway keeps calls (the gateway forgets one when it ends), so this is
/// the only history there is.
class CallRecord {
  final String conversationId;

  /// The conversation's name then, e.g. the other person's.
  final String title;

  /// Placed from this account (here or on another device).
  final bool outgoing;
  final CallOutcome outcome;

  /// When it rang or was placed.
  final DateTime at;

  /// How long it was talked, when it was.
  final Duration? duration;

  const CallRecord({
    required this.conversationId,
    required this.title,
    required this.outgoing,
    required this.outcome,
    required this.at,
    this.duration,
  });

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'title': title,
    'outgoing': outgoing,
    'outcome': outcome.name,
    'at': at.toUtc().toIso8601String(),
    if (duration != null) 'seconds': duration!.inSeconds,
  };

  static CallRecord? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['conversationId'];
    final title = json['title'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final outcome = CallOutcome.values.where((o) => o.name == json['outcome']).firstOrNull;
    if (id is! String || title is! String || at == null || outcome == null) return null;
    final seconds = json['seconds'];
    return CallRecord(
      conversationId: id,
      title: title,
      outgoing: json['outgoing'] == true,
      outcome: outcome,
      at: at.toLocal(),
      duration: seconds is int ? Duration(seconds: seconds) : null,
    );
  }
}

/// Keeps an account's call history between launches.
abstract interface class CallHistoryStore {
  Future<String?> read(String userId);
  Future<void> write(String userId, String json);
  Future<void> clear(String userId);
}

/// In the keystore, as the recent chats are: who called whom is private.
class SecureCallHistoryStore implements CallHistoryStore {
  final FlutterSecureStorage _storage;
  const SecureCallHistoryStore([this._storage = const FlutterSecureStorage()]);

  static String _key(String userId) => 'duvet_call_history_$userId';

  @override
  Future<String?> read(String userId) => _storage.read(key: _key(userId));

  @override
  Future<void> write(String userId, String json) => _storage.write(key: _key(userId), value: json);

  @override
  Future<void> clear(String userId) => _storage.delete(key: _key(userId));
}

class MemoryCallHistoryStore implements CallHistoryStore {
  final data = <String, String>{};

  @override
  Future<String?> read(String userId) async => data[userId];

  @override
  Future<void> write(String userId, String json) async => data[userId] = json;

  @override
  Future<void> clear(String userId) async => data.remove(userId);
}

/// The signed-in account's calls on this device, the newest first.
class CallHistory {
  static const _max = 100;

  final CallHistoryStore _store;
  CallHistory(this._store);

  final ValueNotifier<List<CallRecord>> calls = ValueNotifier(const []);
  String? _userId;

  /// Loads [userId]'s history: the account that signed in.
  Future<void> load(String userId) async {
    if (_userId == userId) return;
    _userId = userId;
    calls.value = const [];
    try {
      final json = await _store.read(userId);
      if (_userId != userId || json == null) return;
      final list = jsonDecode(json);
      if (list is! List) return;
      calls.value = [for (final item in list) ?CallRecord.fromJson(item)];
    } catch (e) {
      // Unreadable (or no keystore, as in tests): it starts empty.
      debugPrint('call history: $e');
    }
  }

  void add(CallRecord record) {
    final userId = _userId;
    if (userId == null) return;
    calls.value = [record, ...calls.value].take(_max).toList();
    final json = jsonEncode([for (final c in calls.value) c.toJson()]);
    unawaited(_store.write(userId, json).catchError((Object e) => debugPrint('call history: $e')));
  }

  /// Signed out: [forget] deletes what was kept, as signing out does with
  /// the recent chats.
  Future<void> close({bool forget = false}) async {
    final userId = _userId;
    _userId = null;
    calls.value = const [];
    if (forget && userId != null) {
      try {
        await _store.clear(userId);
      } catch (e) {
        debugPrint('call history: $e');
      }
    }
  }

  void dispose() => calls.dispose();
}
