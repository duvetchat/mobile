import 'dart:convert';
import 'dart:io';

import 'push_message.dart';

/// The last messages pushed for each chat, which its notification shows. They're kept on disk
/// (`push/<chatId>.json` under [dir]), as a push is shown by the background isolate or the app's own, whichever
/// runs.
class PushHistory {
  /// How many messages a chat's notification shows.
  static const kept = 6;

  final Directory dir;
  const PushHistory(this.dir);

  File _file(String chatId) => File('${dir.path}/push/$chatId.json');

  /// Adds [pushes], messages of one chat, to its history, once per message, and returns the chat's last [kept], oldest
  /// first.
  Future<List<MessagePush>> addAll(List<MessagePush> pushes) async {
    final file = _file(pushes.first.chatId);
    final byMessage = {for (final p in await _read(file)) p.messageId: p, for (final p in pushes) p.messageId: p};
    final all = byMessage.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    final last = all.length > kept ? all.sublist(all.length - kept) : all;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode([for (final p in last) p.toData()]));
    return last;
  }

  /// Adds [push] to its chat's history ([addAll]).
  Future<List<MessagePush>> add(MessagePush push) => addAll([push]);

  /// A chat's history, oldest first: what its notification shows.
  Future<List<MessagePush>> read(String chatId) => _read(_file(chatId));

  /// Forgets a chat's history, as its notification goes.
  Future<void> forget(String chatId) async {
    try {
      await _file(chatId).delete();
    } on PathNotFoundException {
      // None kept.
    }
  }

  /// Forgets every chat's history, and the photos they showed, as the session ends. What the app asked of the user
  /// (whether to allow notifications) stays.
  Future<void> forgetAll() async {
    try {
      await for (final entry in Directory('${dir.path}/push').list()) {
        if (entry is File && entry.path.endsWith('.json') || entry is Directory) await entry.delete(recursive: true);
      }
    } on PathNotFoundException {
      // None kept.
    }
  }

  // A history it can't read starts over: it's only what a notification shows.
  Future<List<MessagePush>> _read(File file) async {
    try {
      final list = jsonDecode(await file.readAsString());
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            if (Push.fromData(item) case final MessagePush push) push,
      ];
    } on FileSystemException {
      return [];
    } on FormatException {
      return [];
    }
  }
}
