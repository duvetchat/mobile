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
  const _Clear(
    this.conversationId, {
    this.replyTo,
    this.mentionReplied,
    this.stickerAttachmentId,
    this.first,
    this.place,
  });

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

  /// Its place among the messages that wait (I3 of task 17's review): given as it's first kept, after every message
  /// that waits, and carried by its remakes, so what waits goes in the order the person made it, whatever the core's.
  final int? place;

  /// What goes with it once it's made again under another nonce than [nonce].
  _Clear again(String nonce) => _Clear(
    conversationId,
    replyTo: replyTo,
    mentionReplied: mentionReplied,
    stickerAttachmentId: stickerAttachmentId,
    first: first ?? nonce,
    place: place,
  );

  /// The same, in [at].
  _Clear placed(int at) => _Clear(
    conversationId,
    replyTo: replyTo,
    mentionReplied: mentionReplied,
    stickerAttachmentId: stickerAttachmentId,
    first: first,
    place: at,
  );

  /// What the record kept, as it's checked when read, as any record's: null for what isn't one.
  static _Clear? read(Object? kept) => switch (kept) {
    {'conversation_id': final String conversation} => _Clear(
      conversation,
      replyTo: kept['reply_to'] as String?,
      mentionReplied: kept['mention_replied'] as bool?,
      stickerAttachmentId: kept['sticker_attachment_id'] as String?,
      first: kept['first'] as String?,
      place: kept['place'] as int?,
    ),
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'conversation_id': conversationId,
    'reply_to': ?replyTo,
    'mention_replied': ?mentionReplied,
    'sticker_attachment_id': ?stickerAttachmentId,
    'first': ?first,
    'place': ?place,
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

  /// The pause holds it until its Retry-After, which a READY doesn't cut short (M4 of task 17's review).
  var paused = false;

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

/// Where a row the record doesn't know goes among what waits: after every message it knows.
const _unplaced = 1 << 40;

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

/// A message's bytes no member can open any more, the core's word or the API's: it's made again, with each after it.
class _Stale implements Exception {
  const _Stale();
}

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

  /// The person's messages made again that went (its answer, its copy, or the queue said so), by the nonce they sent
  /// each with: the nonce it went under and the API's ID. A Retry of one answers as of a message sent, a Dismiss gives
  /// its ID, and the gateway's copy reaches the views under the person's nonce, while the app runs (I1 of task 17's
  /// review, the desktop's N1).
  final _went = <String, ({String nonce, String message})>{};

  /// A message's nonces made again, to the one the person sent it with: kept while the app runs, past the record.
  final _firstOf = <String, String>{};

  CoreHost get _host => _engine.host;
  duvet.E2eApi get _api => _engine.api;

  /// The person's message, sent after what waits in its conversation: the API's message, or null when it was sent
  /// already. What fails leaves it waiting, with its bytes, for the person's Retry or Dismiss.
  Future<duvet.DirectMessage?> send(Outgoing out) async {
    final id = out.conversationId;
    // Made again, it went under its new nonce, as its answer or its copy said: it was sent.
    if (_went.containsKey(out.nonce)) return null;
    // A message made again waits under another nonce, which its record knows by the person's.
    final nonce = _current(out.nonce);
    await _groups.current(id);
    final rows = await pendingRows(_host, id);
    final waiting = rows.any((row) => row.nonce == nonce);
    // Past them, the oldest would be out of the engine's sight (M5 of the desktop's review).
    if (!waiting && nonce == out.nonce && rows.length >= _pendingMost) throw const TooManyWaiting();
    // What goes with it in the clear, kept once it's to be sent (M6 of task 17's review: after the refusals).
    if (nonce == out.nonce && !_record().containsKey(nonce)) await _keep(nonce, _Clear.of(out));
    if (!waiting) {
      try {
        await _encrypt(id, nonce, out.text);
      } on CoreError catch (error) {
        // Its copy came back from the queue: it went.
        if (error.code != 'exists') rethrow;
        final first = firstOf(nonce);
        if (first != nonce) {
          if ((await _bound(id))[nonce] case final message?) _went[first] = (nonce: nonce, message: message);
        }
        await _forget(nonce);
        return null;
      }
    }
    return _flush(id, wanted: nonce);
  }

  /// The person's Retry of a message that waits on this device, as the record keeps what goes with it: the API's
  /// message, or null when none waits under [nonce] (sent, or dismissed).
  Future<duvet.DirectMessage?> resend(String conversationId, String nonce) async {
    if (_went.containsKey(nonce)) return null;
    await _groups.current(conversationId);
    return _flush(conversationId, wanted: _current(nonce));
  }

  /// The nonce the message the person sent under [nonce] waits under now, or went under: another once it was made
  /// again.
  String current(String nonce) => _current(nonce);

  String _current(String nonce) =>
      _went[nonce]?.nonce ?? _record().entries.where((kept) => kept.value.first == nonce).lastOrNull?.key ?? nonce;

  /// The nonce the person sent the message under whose nonce is [nonce] now.
  String firstOf(String nonce) => _record()[nonce]?.first ?? _firstOf[nonce] ?? nonce;

  /// What waits in the conversation, in the person's order, one row a message, with what goes with each in the clear.
  Future<List<Pending>> pending(String conversationId) async {
    final record = _record();
    return [
      for (final row in (await _waiting(conversationId)).rows)
        (
          nonce: switch (row.nonce) {
            final nonce? => firstOf(nonce),
            null => null,
          },
          row: row,
          replyTo: record[row.nonce]?.replyTo,
          mentionReplied: record[row.nonce]?.mentionReplied,
          stickerAttachmentId: record[row.nonce]?.stickerAttachmentId,
        ),
    ];
  }

  /// The person's Dismiss: the message the API never took goes, every row of it, with what was kept of it. The queue is
  /// read first: a message whose request reached the API, its answer and its event lost, went, and its copy settles it
  /// there (M3 of the desktop's review); this gives the API's ID of one that went, whose copy the views show in its
  /// place (M5 of task 17's), and null for one dropped.
  Future<String?> discard(String conversationId, String nonce) async {
    try {
      await _groups.sync(conversationId, read: true);
    } catch (error) {
      debugPrint("e2e: the queue wasn't read before a Dismiss: $error");
    }
    final (:rows, :older) = await _waiting(conversationId);
    final its = [
      for (final row in [...rows, ...older])
        if (row.nonce case final rowNonce? when firstOf(rowNonce) == nonce) rowNonce,
    ];
    for (final rowNonce in its) {
      await _drop(rowNonce);
    }
    await _prune(conversationId, [...rows, ...older]);
    final went = _went.remove(nonce);
    return its.isEmpty ? went?.message : null;
  }

  /// The gateway's copy of a message of the person's: one made again carries its new nonce, which no view knows. It's
  /// the message they sent under the first, which the views are told once its conversation's turn took it, as its
  /// answer would tell them; and a Retry of it is of the message sent (I1 of task 17's review).
  void heard(duvet.DirectMessage message) {
    final (nonce, conversation) = (message.nonce, message.conversationId);
    if (nonce == null || conversation == null) return;
    final first = firstOf(nonce);
    final kept = _record()[nonce]?.conversationId;
    if (first == nonce || (kept != null && kept != conversation)) return;
    _went[first] = (nonce: nonce, message: message.id);
    _soon(() async => _sent(conversation, first, message));
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
      // The pause holds its conversation's messages until its Retry-After, which a READY doesn't cut short.
      if (_paused.containsKey(id)) continue;
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
          if (error is CoreError && error.code == 'not_found') {
            // Its message isn't on this device any more: nothing to change (M4 of task 17's review).
            await _unnote(conversation, message, kind);
          } else {
            debugPrint("e2e: a change wasn't made again: $error");
          }
        }
      }
    }
    for (final queue in [..._changes.values]) {
      if (queue.first.paused) continue;
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
  /// are answered: at once when it's first, unless it waits to be [send] with others.
  Future<void> _queueChange(_Change change, {bool noted = false, bool send = true}) async {
    final kind = change.kept['kind']! as String;
    if (!noted) await _writeChanges([..._keptChanges(), (change.conversationId, change.messageId, kind)]);
    final queue = _changes[change.key] ??= [];
    queue.add(change);
    if (send && queue.length == 1) await _sendChange(change);
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

  /// What waits in the conversation, in the person's order ([wanted]: the person's, whose message this gives). An
  /// older one the API or the core refused stays, for the person's Retry or Dismiss, and the rest go on; one without an
  /// answer stops them all, as does an update. Once a message's bytes no member could open any more, it and each after
  /// it are made again together, before any of them goes (I3 of task 17's review), and the flush goes on from it.
  Future<duvet.DirectMessage?> _flush(String id, {String? wanted}) async {
    final wantedFirst = wanted == null ? null : firstOf(wanted);
    final waiting = await _waiting(id);
    // A message's old bytes beside new ones a remake made, which carry it, go unsent (I2 of task 17's review).
    for (final row in waiting.older) {
      await _drop(row.nonce!);
    }
    await _prune(id, waiting.rows);
    final done = <String>{};
    final remade = <String>{};
    duvet.DirectMessage? message;
    var rows = waiting.rows;
    for (var at = 0; at < rows.length; at++) {
      final row = rows[at];
      final nonce = row.nonce;
      if (nonce == null) continue;
      final first = firstOf(nonce);
      if (!done.add(first)) continue;
      final clear = _record()[nonce];
      // A message with nothing in it, and nothing kept of what went with it, waits for the person's Dismiss.
      if (first != wantedFirst && clear == null && row.text == null) continue;
      try {
        final sent = await _deliver(id, nonce, row.text, clear ?? _Clear(id));
        if (first == wantedFirst) message = sent;
      } on _Stale {
        // Made again in this flush and stale again: it waits, as refused.
        if (remade.contains(first)) {
          if (first == wantedFirst) rethrow;
          debugPrint('e2e: a message made again is stale again: it stays, to send again or dismiss.');
          continue;
        }
        final tail = [
          for (final next in rows.sublist(at))
            if (next.nonce != null) next,
        ];
        final firsts = [for (final next in tail) firstOf(next.nonce!)];
        remade.addAll(firsts);
        done.removeAll(firsts);
        await _remake(id, tail);
        rows = [
          ...rows.sublist(0, at),
          for (final next in (await _waiting(id)).rows)
            if (next.nonce case final later? when !done.contains(firstOf(later))) next,
        ];
        at--;
      } catch (error) {
        if (first == wantedFirst || error is duvet.DuvetUpdateRequiredException || _unanswered(error)) rethrow;
        debugPrint('e2e: a message that waits was refused: it stays, to send again or dismiss. $error');
      }
    }
    return message;
  }

  /// One message that waits: its bytes as the core made them, its request, and `sent` once the API took it. Bytes no
  /// member could open any more throw [_Stale].
  Future<duvet.DirectMessage> _deliver(String id, String nonce, String? text, _Clear clear) async {
    final String ciphertext;
    try {
      ciphertext = await _encrypt(id, nonce, text);
    } catch (error) {
      if (_staleBytes(error)) throw const _Stale();
      rethrow;
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
    } on duvet.DuvetStaleMessageException {
      // The core learns the epochs the API is at first, so the new bytes are of them.
      await _groups.sync(id, read: true);
      throw const _Stale();
    } on duvet.DuvetPausedException catch (error) {
      _afterPause(id, error.retryAfter);
      rethrow;
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
    final first = clear.first ?? nonce;
    if (first != nonce) _went[first] = (nonce: nonce, message: message.id);
    _changed(id);
    _sent(id, first, message);
    return message;
  }

  /// Messages made again, in the person's order (no member could open the first one's bytes any more, and those after
  /// it go after it): each one's new bytes made under a new nonce before its old ones go, so a failure or a close in
  /// between leaves it waiting as it was, for the next flush, which drops old bytes a remake made new ones of (I2 of
  /// task 17's review). Each keeps the nonce the person sent it with, and its place.
  Future<void> _remake(String id, List<ShownMessage> rows) async {
    for (final row in rows) {
      final old = row.nonce!;
      final clear = _record()[old];
      // One with nothing in it, and nothing kept of what went with it, stays for the person's Dismiss.
      if (clear == null && row.text == null) continue;
      final kept = (clear ?? _Clear(id)).again(old);
      final fresh = uuidv4();
      await _keep(fresh, kept);
      try {
        await _encrypt(id, fresh, row.text);
      } catch (error) {
        await _forget(fresh);
        rethrow;
      }
      _firstOf[fresh] = kept.first!;
      await _drop(old);
    }
  }

  /// What waits in the conversation: one row a message, the newest of its rows (the core lists them in the order they
  /// were made), in the person's order (each message's place, a row the record doesn't know after them, in the core's
  /// order); and the older rows of messages a newer row carries, which go unsent.
  Future<({List<ShownMessage> rows, List<ShownMessage> older})> _waiting(String id) async {
    final record = _record();
    final all = await pendingRows(_host, id);
    final newest = <String, int>{};
    for (var at = 0; at < all.length; at++) {
      newest[switch (all[at].nonce) {
            final nonce? => firstOf(nonce),
            null => '#$at',
          }] =
          at;
    }
    final kept = {...newest.values};
    int placeOf(int at) => record[all[at].nonce]?.place ?? _unplaced + at;
    final order = [...kept]..sort((a, b) => placeOf(a).compareTo(placeOf(b)));
    return (
      rows: [for (final at in order) all[at]],
      older: [
        for (var at = 0; at < all.length; at++)
          if (!kept.contains(at)) all[at],
      ],
    );
  }

  /// What the record keeps of the conversation's messages that no longer wait goes. One whose copy the queue brought
  /// back, which the core bound under its nonce, went: a Retry or a Dismiss of it, by the person's nonce, says so.
  Future<void> _prune(String id, List<ShownMessage> rows) async {
    final waiting = {for (final row in rows) row.nonce};
    final gone = [
      for (final MapEntry(key: nonce, value: clear) in _record().entries)
        if (clear.conversationId == id && !waiting.contains(nonce)) (nonce, clear),
    ];
    if (gone.isEmpty) return;
    final bound = await _bound(id);
    for (final (nonce, clear) in gone) {
      if (bound[nonce] case final message?) _went[clear.first ?? nonce] = (nonce: nonce, message: message);
      await _forget(nonce);
    }
  }

  /// The person's messages the core bound to the API's IDs, by nonce, as its newest page shows them.
  Future<Map<String, String>> _bound(String id) async {
    // shortcut: the newest page alone (100 rows): one bound further back reads as not gone, rare, as it waited.
    final page = await _host.handle<Map<String, Object?>>({'cmd': 'messages', 'conversation_id': id, 'limit': 100});
    return {
      for (final row in page['messages']! as List)
        if (ShownMessage.of((row as Map).cast<String, Object?>()) case ShownMessage(:final nonce?, :final messageId?))
          nonce: messageId,
    };
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
  /// goes again later and at each READY; bytes the API says no member could open now are made again, once. A refusal
  /// for good resolves (the device shows the change), and the person is told wherever they are (M3 of task 17's
  /// review).
  Future<void> _sendChange(_Change change) async {
    if (change.sending || change.answered) return;
    change.sending = true;
    try {
      await _trySend(change);
    } finally {
      change.sending = false;
    }
  }

  Future<void> _trySend(_Change change) async {
    final id = change.conversationId;
    final duvet.MlsEntry entry;
    try {
      entry = change.text == null
          ? (await _api.deleteMessage(id, change.messageId, change.ciphertext)).entry
          : (await _api.editMessage(id, change.messageId, change.ciphertext)).entry;
    } catch (error) {
      // An update keeps it, for after the update.
      if (error is duvet.DuvetUpdateRequiredException) rethrow;
      if (error is duvet.DuvetStaleMessageException && !change.remade) {
        try {
          await _groups.sync(id, read: true);
          change.ciphertext = await _make(change);
        } catch (failed) {
          // What throws past its request waits as no answer does (M4 of task 17's review, the desktop's N6).
          debugPrint('e2e: a change goes again later: $failed');
          return _retryLater(change);
        }
        change.remade = true;
        return _trySend(change);
      }
      // A deletion of a message that isn't there any more (its own answer a restart cut off, or another device's
      // first): it's gone for everyone, as it was to be (M4 of task 17's review, the desktop's N5).
      if (change.text == null && error is duvet.DuvetApiException && error.statusCode == 404) {
        await _answered(change);
        _changed(id);
        return;
      }
      // Anything but the API's word waits as no answer does.
      if (error is! duvet.DuvetApiException || _unanswered(error)) {
        return _retryLater(change, error is duvet.DuvetPausedException ? error.retryAfter : null);
      }
      // Refused for good: it goes, the device's view is read again, and the person is told.
      await _answered(change);
      _changed(id);
      _refused(id, change.messageId, change.kept['kind']! as String);
      debugPrint('e2e: a change was refused: $error');
      return;
    }
    await _answered(change);
    try {
      await _groups.take(id, [entryOf(entry)]);
    } catch (error) {
      // An entry the core can't take now (a gap before it) comes with the conversation's queue, at its next turn.
      debugPrint("e2e: a change's entry waits for its conversation's queue: $error");
    }
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

  /// A change without an answer goes again later: after the backoff, or after the pause's [after].
  void _retryLater(_Change change, [Duration? after]) {
    change.cancel?.call();
    final backoff = _retryFirst * (1 << min(change.tries++, 5));
    final wait = after ?? (backoff < _retryMost ? backoff : _retryMost);
    change.paused = after != null;
    change.cancel = _engine.clock.later(wait, () {
      change.cancel = null;
      change.paused = false;
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

  /// A message kept by its nonce, in its place: a new one after every message that waits.
  Future<void> _keep(String nonce, _Clear clear) {
    final record = _record();
    final last = record.values.fold(0, (most, kept) => max(most, kept.place ?? 0));
    return _write({...record, nonce: clear.place == null ? clear.placed(last + 1) : clear});
  }

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
