/// What this device sends to a conversation (PLAN-E2E-CLIENTES.md, «Enviar», and «Qué se manda», its message rows): the
/// person's messages, their edits and their deletions. The core encrypts a message and keeps it as pending, its bytes
/// with it, until `sent` binds it to the API's ID: the same nonce gives the same bytes again, so one whose answer was
/// lost goes again as it was, and the API answers it with the message it posted. What waits in a conversation goes
/// first, in the order it was made, its queue applied before; one whose bytes no member could open any more is dropped
/// and its text encrypted again, under another nonce. An edit and a deletion the core makes anew each time, so their
/// bytes are kept here until an answer comes, and the entry that answer gives goes to the core. Only the core keeps
/// text: the record keeps what goes with each message in the clear, by its nonce, so it goes whole after a restart. The
/// desktop's send.ts in Dart.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'content.dart';
import 'conventions.dart';
import 'engine.dart';
import 'host.dart';
import 'identity.dart';
import 'store.dart';
import 'sync.dart';
import 'uuid.dart';

/// A message as the person sends it: its nonce (a UUIDv4, the conventions between clients), its text (none for a
/// sticker, which goes in the clear with an empty envelope), and what goes with it in the clear: the message it
/// answers, whether that mentions its author, and the sticker.
@immutable
class Outgoing {
  const Outgoing({
    required this.conversationId,
    required this.nonce,
    this.text,
    this.replyTo,
    this.mentionReplied,
    this.stickerAttachmentId,
  });

  final String conversationId;
  final String nonce;
  final String? text;
  final String? replyTo;
  final bool? mentionReplied;
  final String? stickerAttachmentId;
}

/// What goes with a message in the clear, kept by its nonce until it's sent.
class _Clear {
  const _Clear(this.conversationId, {this.replyTo, this.mentionReplied, this.stickerAttachmentId, this.first});

  _Clear.of(Outgoing out)
    : this(
        out.conversationId,
        replyTo: out.replyTo,
        mentionReplied: out.mentionReplied,
        stickerAttachmentId: out.stickerAttachmentId,
      );

  final String conversationId;
  final String? replyTo;
  final bool? mentionReplied;
  final String? stickerAttachmentId;

  /// The nonce the person sent it under, once it was made again under another (its first bytes stale): the person's
  /// Retry, Dismiss and the chat know it by that one.
  final String? first;

  /// What goes with it once it's made again under another nonce than [nonce].
  _Clear again(String nonce) => _Clear(
    conversationId,
    replyTo: replyTo,
    mentionReplied: mentionReplied,
    stickerAttachmentId: stickerAttachmentId,
    first: first ?? nonce,
  );

  /// What the record kept, as it's checked when read, as any record's: null for what isn't one.
  static _Clear? read(Object? kept) => switch (kept) {
    {'conversation_id': final String conversation} => _Clear(
      conversation,
      replyTo: kept['reply_to'] as String?,
      mentionReplied: kept['mention_replied'] as bool?,
      stickerAttachmentId: kept['sticker_attachment_id'] as String?,
      first: kept['first'] as String?,
    ),
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'conversation_id': conversationId,
    'reply_to': ?replyTo,
    'mention_replied': ?mentionReplied,
    'sticker_attachment_id': ?stickerAttachmentId,
    'first': ?first,
  };
}

/// A message of the person's still being sent: the nonce they sent it under ([nonce], its row's unless it was made
/// again), the core's row, and what goes with it in the clear.
typedef Pending = ({
  String? nonce,
  ShownMessage row,
  String? replyTo,
  bool? mentionReplied,
  String? stickerAttachmentId,
});

/// An edit (with its text) or a deletion (none) whose request goes on: its bytes, sent again as they are until an
/// answer comes.
class _Change {
  _Change(this.conversationId, this.messageId, this.text);
  final String conversationId;
  final String messageId;

  /// An edit's text, made into bytes again when the API says no member could open them any more.
  final String? text;
  var ciphertext = '';
  var remade = false;
  var tries = 0;
  void Function()? cancel;

  /// Its request is out, or it was answered: a second send does nothing. A queue's first is sent by a READY's resend
  /// and by the change before it as that one's answered, which can come together.
  var sending = false;
  var answered = false;

  /// Its message's place: the changes of one message go one at a time, in order.
  String get key => '$conversationId:$messageId';

  Map<String, Object?> get kept => {
    'conversation_id': conversationId,
    'message_id': messageId,
    'kind': text == null ? 'delete' : 'edit',
  };
}

/// A new message refused, as [_pendingMost] of its conversation's wait to be sent already: nothing of it is kept.
class TooManyWaiting implements Exception {
  const TooManyWaiting();

  @override
  String toString() => '$_pendingMost messages wait to be sent here already';
}

/// The most users a message names: the API takes 20.
const _mentionsMost = 20;

/// The most messages that wait in a conversation: what the core's first page of it shows, which the engine reads.
const _pendingMost = 100;

/// A change without an answer goes again after 2 s, then twice as long each time, up to a minute apart.
const _retryFirst = Duration(seconds: 2);
const _retryMost = Duration(minutes: 1);

// As the API reads a room's mentions (parseMentionIDs): code blocks, then inline code, taken out first.
final _codeBlock = RegExp(r'```[\s\S]*?```');
final _inlineCode = RegExp('`[^`]+`');
final _mention = RegExp(r'<@([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>');

/// Whom a message's text names (PLAN-E2E-CLIENTES.md, «Enviar»): each `<@id>` outside code, once, 20 at most.
List<String> mentionsIn(String text) {
  final outside = text.replaceAll(_codeBlock, '').replaceAll(_inlineCode, '');
  return {for (final match in _mention.allMatches(outside)) match[1]!}.take(_mentionsMost).toList();
}

/// No word on the message itself: a lost connection, a session's renewal, a timeout, a rate limit, the server, the
/// pause. The core's refusals and the API's others are words on it.
bool _unanswered(Object error) => switch (error) {
  duvet.DuvetApiException(:final statusCode) =>
    statusCode == 401 || statusCode == 408 || statusCode == 429 || statusCode >= 500,
  CoreError() => false,
  Exception() => true,
  _ => false,
};

/// The core's word that no member could open the message's bytes any more.
bool _staleBytes(Object error) => error is CoreError && error.code == 'rule_violation' && error.rule == 'stale_message';

class Sends {
  Sends(this._engine, this._groups, this._soon, this._changed, this._sent, this._refused);

  final E2EEngine _engine;
  final Conversations _groups;

  /// Runs work in the engine's turn, while the device is ready.
  final void Function(Future<void> Function() work) _soon;

  /// A conversation's messages changed on this device.
  final void Function(String conversationId) _changed;

  /// A message the person sent (its first nonce) is the API's message now.
  final void Function(String conversationId, String nonce, duvet.DirectMessage message) _sent;

  /// A change of the person's the API refused for good where nobody waits for its answer (a restart's, or one sent
  /// after another of its message): the person is told, as the core shows it done here (its kind: `edit`, `delete`).
  final void Function(String conversationId, String messageId, String kind) _refused;

  /// The changes not answered yet, by message, in their order: the first goes, the next once it's answered (I3 of the
  /// desktop's task 16 review).
  final _changes = <String, List<_Change>>{};

  /// Conversations whose messages wait for the pause to end, and its end's call.
  final _paused = <String, void Function()>{};

  CoreHost get _host => _engine.host;
  duvet.E2eApi get _api => _engine.api;

  /// The person's message, sent after what waits in its conversation: the API's message, or null when it was sent
  /// already. What fails leaves it waiting, with its bytes, for the person's Retry or Dismiss.
  Future<duvet.DirectMessage?> send(Outgoing out) async {
    final id = out.conversationId;
    // A message made again waits under another nonce, which its record knows by the person's.
    final nonce = _current(out.nonce);
    if (nonce == out.nonce) await _keep(nonce, _Clear.of(out));
    await _groups.current(id);
    final rows = await pendingRows(_host, id);
    if (!rows.any((row) => row.nonce == nonce)) {
      // Past them, the oldest would be out of the engine's sight (M5 of the desktop's review).
      if (rows.length >= _pendingMost) throw const TooManyWaiting();
      try {
        await _encrypt(id, nonce, out.text);
      } on CoreError catch (error) {
        // Its copy came back from the queue: it went.
        if (error.code != 'exists') rethrow;
        await _forget(nonce);
        return null;
      }
    }
    return _flush(id, wanted: nonce);
  }

  /// The person's Retry of a message that waits on this device, as the record keeps what goes with it: the API's
  /// message, or null when none waits under [nonce] (sent, or dismissed).
  Future<duvet.DirectMessage?> resend(String conversationId, String nonce) async {
    await _groups.current(conversationId);
    return _flush(conversationId, wanted: _current(nonce));
  }

  /// The nonce the message the person sent under [nonce] waits under now: another once it was made again.
  String _current(String nonce) =>
      _record().entries.where((kept) => kept.value.first == nonce).firstOrNull?.key ?? nonce;

  /// What waits in the conversation, in its order, with what goes with each in the clear.
  Future<List<Pending>> pending(String conversationId) async {
    final record = _record();
    return [
      for (final row in await pendingRows(_host, conversationId))
        (
          nonce: record[row.nonce]?.first ?? row.nonce,
          row: row,
          replyTo: record[row.nonce]?.replyTo,
          mentionReplied: record[row.nonce]?.mentionReplied,
          stickerAttachmentId: record[row.nonce]?.stickerAttachmentId,
        ),
    ];
  }

  /// The person's Dismiss: the message the API never took goes, with what was kept of it. The queue is read first: a
  /// message whose request reached the API, its answer and its event lost, went, and its copy settles it there (M3 of
  /// the desktop's review).
  Future<void> discard(String conversationId, String nonce) async {
    final current = _current(nonce);
    try {
      await _groups.sync(conversationId, read: true);
    } catch (error) {
      debugPrint("e2e: the queue wasn't read before a Dismiss: $error");
    }
    if ((await pendingRows(_host, conversationId)).any((row) => row.nonce == current)) return _drop(current);
    await _forget(current);
  }

  /// A message that waits, dropped with what was kept of it.
  Future<void> _drop(String nonce) async {
    try {
      await _host.handle<Object?>({'cmd': 'discard', 'nonce': nonce});
    } on CoreError catch (error) {
      // Gone already: sent, or dismissed.
      if (error.code != 'not_found') rethrow;
    }
    await _forget(nonce);
  }

  /// At the start and at each READY, the queues applied: what waits, in each conversation, and the changes.
  Future<void> resendAll() async {
    for (final id in {for (final clear in _record().values) clear.conversationId}) {
      try {
        await _flush(id);
      } catch (error) {
        debugPrint('e2e: what waits to be sent waits again: $error');
      }
    }
    // The changes a restart left, a message's all at once and in their order (those this run made are queued already):
    // made again, a deletion on its erased row, an edit from the row's text, which is its. Its first goes below.
    final left = <String, List<(String, String, String)>>{};
    for (final kept in _keptChanges()) {
      (left['${kept.$1}:${kept.$2}'] ??= []).add(kept);
    }
    for (final MapEntry(:key, value: kept) in left.entries) {
      if (_changes.containsKey(key)) continue;
      for (final (conversation, message, kind) in kept) {
        try {
          final row = (await shownMessages(_host, conversation, [message])).firstOrNull;
          final text = kind == 'edit' ? row?.text : null;
          if (kind == 'edit' && text == null) {
            await _unnote(conversation, message, kind);
            continue;
          }
          final change = _Change(conversation, message, text);
          change.ciphertext = await _make(change);
          await _queueChange(change, noted: true, send: false);
        } catch (error) {
          debugPrint("e2e: a change wasn't made again: $error");
        }
      }
    }
    for (final queue in [..._changes.values]) {
      try {
        await _sendChange(queue.first);
      } catch (error) {
        debugPrint("e2e: a change wasn't sent: $error");
      }
    }
  }

  /// An edit (with its [text]) or a deletion (none) of the user's message: made by the core, which shows it here at
  /// once, sent, and the entry its answer gives taken by the core. Without an answer its bytes go again later.
  Future<void> change(String conversationId, String messageId, String? text) async {
    await _groups.current(conversationId);
    final change = _Change(conversationId, messageId, text);
    change.ciphertext = await _make(change);
    _changed(conversationId);
    await _queueChange(change);
  }

  /// A change kept (in the record too, unless it's [noted] there already) and sent once those of its message before it
  /// are answered: at once when it's first, unless it waits to be [send] with others; the person who asked hears its
  /// refusal from it then.
  Future<void> _queueChange(_Change change, {bool noted = false, bool send = true}) async {
    final kind = change.kept['kind']! as String;
    if (!noted) await _writeChanges([..._keptChanges(), (change.conversationId, change.messageId, kind)]);
    final queue = _changes[change.key] ??= [];
    queue.add(change);
    if (send && queue.length == 1) await _sendChange(change, asked: true);
  }

  /// Stops waiting: what waits stays, in the core and in the record, for the next start.
  void stop() {
    for (final change in _changes.values.expand((queue) => queue)) {
      change.cancel?.call();
    }
    for (final cancel in _paused.values) {
      cancel();
    }
    _changes.clear();
    _paused.clear();
  }

  /// What waits in the conversation, in its order ([wanted]: the person's, whose message this gives). An older one
  /// the API or the core refused stays, for the person's Retry or Dismiss, and the rest go on; one without an answer
  /// stops them all, as does an update.
  Future<duvet.DirectMessage?> _flush(String id, {String? wanted}) async {
    final rows = await pendingRows(_host, id);
    // What the record keeps of a message that no longer waits (sent, or dropped) goes.
    final waiting = {for (final row in rows) row.nonce};
    for (final MapEntry(key: nonce, value: clear) in _record().entries) {
      if (clear.conversationId == id && !waiting.contains(nonce)) await _forget(nonce);
    }
    duvet.DirectMessage? message;
    // Once one is made again, so is each after it, in order: the order they go in stays the order they were made in,
    // and the generations (I2 of the desktop's review).
    var remake = false;
    for (final row in rows) {
      final nonce = row.nonce;
      if (nonce == null) continue;
      final clear = _record()[nonce];
      // A message with nothing in it, and nothing kept of what went with it, waits for the person's Dismiss.
      if (nonce != wanted && clear == null && row.text == null) continue;
      try {
        final (message: sent, :remade) = await _deliver(id, nonce, row.text, clear ?? _Clear(id), remake: remake);
        remake = remake || remade;
        if (nonce == wanted) message = sent;
      } catch (error) {
        if (nonce == wanted || error is duvet.DuvetUpdateRequiredException || _unanswered(error)) rethrow;
        debugPrint('e2e: a message that waits was refused: it stays, to send again or dismiss. $error');
      }
    }
    return message;
  }

  /// One message that waits: its bytes (the same as before, or made again under a new nonce once no member could open
  /// them), its request, and `sent` once the API took it.
  Future<({duvet.DirectMessage message, bool remade})> _deliver(
    String id,
    String first,
    String? text,
    _Clear given, {
    bool remake = false,
  }) async {
    var (nonce, clear) = (first, given);
    if (remake) (nonce, clear) = await _again(id, nonce, text, clear);
    for (var remade = remake; ; remade = true) {
      final String ciphertext;
      try {
        ciphertext = await _encrypt(id, nonce, text);
      } catch (error) {
        if (remade || !_staleBytes(error)) rethrow;
        (nonce, clear) = await _again(id, nonce, text, clear);
        continue;
      }
      final duvet.DirectMessage message;
      try {
        message = await _api.sendMessage(
          id,
          duvet.EncryptedMessage(
            ciphertext: ciphertext,
            nonce: nonce,
            mentions: text == null ? const [] : mentionsIn(text),
            messageReference: switch (clear.replyTo) {
              final reply? => duvet.MessageReference(type: duvet.MessageReferenceType.reply, messageId: reply),
              null => null,
            },
            allowedMentions: switch (clear.mentionReplied) {
              final mention? => duvet.AllowedMentions(repliedUser: mention),
              null => null,
            },
            stickerAttachmentId: clear.stickerAttachmentId,
          ),
        );
      } catch (error) {
        if (error is duvet.DuvetPausedException) _afterPause(id, error.retryAfter);
        if (remade || error is! duvet.DuvetStaleMessageException) rethrow;
        // The core learns the epochs the API is at first, so the new bytes are of them.
        await _groups.sync(id, read: true);
        (nonce, clear) = await _again(id, nonce, text, clear);
        continue;
      }
      await _host.handle<Object?>({
        'cmd': 'sent',
        'conversation_id': id,
        'nonce': nonce,
        'message_id': message.id,
        'seq': message.seq,
        'reply_to': ?clear.replyTo,
      });
      await _forget(nonce);
      _changed(id);
      _sent(id, clear.first ?? nonce, message);
      return (message: message, remade: remade);
    }
  }

  /// A message made again (no member could open its bytes any more, or one before it was made again), dropped and
  /// encrypted again under a new nonce: the new nonce, and what goes with it, which keeps the person's.
  Future<(String, _Clear)> _again(String id, String nonce, String? text, _Clear clear) async {
    await _drop(nonce);
    final fresh = uuidv4();
    final kept = clear.again(nonce);
    await _keep(fresh, kept);
    await _encrypt(id, fresh, text);
    return (fresh, kept);
  }

  /// The core's encrypt: the message kept as pending, or, for a nonce it has, its bytes again. What keeps this device
  /// from sending there is dealt with once: users to observe, leaves and removals to commit, a group to join or make.
  Future<String> _encrypt(String id, String nonce, String? text) async {
    Future<String> run() async =>
        (await withIdentities(
              _engine,
              () => _host.handle<Map<String, Object?>>({
                'cmd': 'encrypt',
                'conversation_id': id,
                'nonce': nonce,
                'envelope': messageEnvelope(text ?? '', const []),
              }),
            ))['ciphertext']!
            as String;
    try {
      return await run();
    } on CoreError catch (error) {
      if (error.code == 'pending_proposals') {
        await _groups.commitDue(id);
      } else if (error.code == 'pending_commit') {
        // A commit of this device's waits for its word: «Un commit sin respuesta» settles it (Missing 1 of the
        // desktop's review), and the message is encrypted once more; past that, the refusal stays.
        await _groups.settleCommit(id);
      } else if (error.code == 'not_found' && error.what == 'group') {
        await _groups.current(id);
      } else {
        rethrow;
      }
      return run();
    }
  }

  /// The messages of a conversation the pause held, sent once it ends: the API says when to try.
  void _afterPause(String id, Duration wait) {
    if (_paused.containsKey(id)) return;
    _paused[id] = _engine.clock.later(wait, () {
      _paused.remove(id);
      _soon(() async {
        await _flush(id);
      });
    });
  }

  /// An edit's or a deletion's bytes, as the core makes them now.
  Future<String> _make(_Change change) async =>
      (await withIdentities(
            _engine,
            () => _host.handle<Map<String, Object?>>({
              'cmd': change.text == null ? 'delete' : 'edit',
              'conversation_id': change.conversationId,
              'message_id': change.messageId,
              'text': ?change.text,
            }),
          ))['ciphertext']!
          as String;

  /// An edit's or a deletion's request, its bytes as they are: its answer's entry to the core. Without an answer it
  /// goes again later and at each READY; bytes the API says no member could open now are made again, once.
  Future<void> _sendChange(_Change change, {bool asked = false}) async {
    if (change.sending || change.answered) return;
    change.sending = true;
    try {
      await _trySend(change, asked: asked);
    } finally {
      change.sending = false;
    }
  }

  Future<void> _trySend(_Change change, {required bool asked}) async {
    final id = change.conversationId;
    final duvet.MlsEntry entry;
    try {
      entry = change.text == null
          ? (await _api.deleteMessage(id, change.messageId, change.ciphertext)).entry
          : (await _api.editMessage(id, change.messageId, change.ciphertext)).entry;
    } catch (error) {
      // No answer, or an update: kept, for later or for after the update.
      if (error is duvet.DuvetUpdateRequiredException) rethrow;
      if (_unanswered(error)) return _retryLater(change, error is duvet.DuvetPausedException ? error.retryAfter : null);
      if (error is duvet.DuvetStaleMessageException && !change.remade) {
        await _groups.sync(id, read: true);
        change.ciphertext = await _make(change);
        change.remade = true;
        return _trySend(change, asked: asked);
      }
      // Refused for good: it goes, the device's view is read again, and the person is told: by the one who asked, or
      // here when nobody waits for it.
      await _answered(change);
      _changed(id);
      if (asked) rethrow;
      _refused(id, change.messageId, change.kept['kind']! as String);
      debugPrint('e2e: a change was refused: $error');
      return;
    }
    await _answered(change);
    await _groups.take(id, [entryOf(entry)]);
    _changed(id);
  }

  /// A change answered (taken, or refused for good): it leaves its message's queue and the record, and the next goes.
  Future<void> _answered(_Change change) async {
    change.answered = true;
    change.cancel?.call();
    final queue = _changes[change.key];
    queue?.remove(change);
    if (queue != null && queue.isEmpty) _changes.remove(change.key);
    await _unnote(change.conversationId, change.messageId, change.kept['kind']! as String);
    if (queue?.firstOrNull case final next?) _soon(() => _sendChange(next));
  }

  List<(String, String, String)> _keptChanges() => [
    for (final kept in _engine.store.read(pendingChanges) as List? ?? const [])
      if (kept case {'conversation_id': final String c, 'message_id': final String m, 'kind': final String k})
        (c, m, k),
  ];

  Future<void> _unnote(String conversation, String message, String kind) async {
    final kept = _keptChanges();
    final i = kept.indexOf((conversation, message, kind));
    if (i < 0) return;
    await _writeChanges(kept..removeAt(i));
  }

  Future<void> _writeChanges(List<(String, String, String)> kept) => _engine.store
      .write(
        pendingChanges,
        kept.isEmpty
            ? null
            : [
                for (final (c, m, k) in kept) {'conversation_id': c, 'message_id': m, 'kind': k},
              ],
      )
      .catchError((Object error) => debugPrint("e2e: a change not answered yet wasn't kept: $error"));

  void _retryLater(_Change change, [Duration? after]) {
    change.cancel?.call();
    final backoff = _retryFirst * (1 << min(change.tries++, 5));
    final wait = after ?? (backoff < _retryMost ? backoff : _retryMost);
    change.cancel = _engine.clock.later(wait, () {
      change.cancel = null;
      _soon(() => _sendChange(change));
    });
  }

  /// What the record keeps by each nonce: what it holds is checked as it's read, as any record's.
  Map<String, _Clear> _record() => switch (_engine.store.read(pendingSends)) {
    final Map<Object?, Object?> kept => {
      for (final MapEntry(:key, :value) in kept.entries)
        if (key is String) key: ?_Clear.read(value),
    },
    _ => {},
  };

  Future<void> _keep(String nonce, _Clear clear) => _write({..._record(), nonce: clear});

  Future<void> _forget(String nonce) async {
    final record = _record();
    if (record.remove(nonce) != null) await _write(record);
  }

  // A record its storage refuses keeps the message's clear parts out of a restart's resend: Retry still sends it.
  Future<void> _write(Map<String, _Clear> record) => _engine.store
      .write(
        pendingSends,
        record.isEmpty ? null : {for (final MapEntry(:key, :value) in record.entries) key: value.toJson()},
      )
      .catchError((Object error) => debugPrint("e2e: what goes with a message waiting to be sent wasn't kept: $error"));
}
