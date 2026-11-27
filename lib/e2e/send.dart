/// What this device sends to a conversation (PLAN-E2E-CLIENTES.md, «Enviar», and «Qué se manda», its message rows): the
/// person's messages, their edits and their deletions. The core encrypts a message and keeps it as pending, its bytes
/// with it, until `sent` binds it to the API's ID: the same nonce gives the same bytes again, so one whose answer was
/// lost goes again as it was while its group stays where they were made, and the API answers it with the message it
/// posted. What waits in a conversation goes first, in the order it was made, its queue applied before; one whose bytes
/// aren't of its group as it is now (T-C1 of step 4's closing re-reviews), or no member could open any more, is dropped
/// and its text encrypted again, under another nonce, after the queue's read. An edit and a deletion the core makes
/// anew each time, so their bytes are kept here until an answer comes, made again once the group moved, and the entry
/// that answer gives goes to the core. Only the core keeps text: the record keeps what goes with each message in the
/// clear, by its nonce, so it goes whole after a restart. The desktop's send.ts in Dart.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'content.dart';
import 'conventions.dart';
import 'engine.dart';
import 'files.dart';
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
    this.files = const [],
  });

  final String conversationId;
  final String nonce;
  final String? text;
  final String? replyTo;
  final bool? mentionReplied;
  final String? stickerAttachmentId;

  /// Its files, sealed as it's first made (files.dart): their sealed bytes stay in this run's memory alone.
  final List<FileToSeal> files;
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

/// Bytes the core made for a conversation's group, with the generation and epoch of the group they're for.
typedef _Made = ({String ciphertext, int generation, int epoch});

_Made _madeOf(Map<String, Object?> answer) => (
  ciphertext: answer['ciphertext']! as String,
  generation: answer['generation']! as int,
  epoch: answer['epoch']! as int,
);

/// An edit (with its text) or a deletion (none) whose request goes on: its bytes, sent again as they are until an
/// answer comes, or made again once the group moved.
class _Change {
  _Change(this.conversationId, this.messageId, this.text);
  final String conversationId;
  final String messageId;

  /// An edit's text, made into bytes again when the group moved, or the API says no member could open them any more.
  final String? text;
  _Made? made;
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

/// A new message refused, as one fewer than [_pendingMost] of its conversation's wait to be sent already: nothing of
/// it is kept.
class TooManyWaiting implements Exception {
  const TooManyWaiting();

  @override
  String toString() => '${_pendingMost - 1} messages wait to be sent here already';
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

/// A cut call to the core, its database or another engine (inbox.dart's rule): no word on the message it was for.
const _again = {'internal', 'storage', 'locked'};

/// No word on the message itself: a lost connection, a session's renewal, a timeout, a rate limit, the server, the
/// pause, a cut call to the core. The core's refusals and the API's others are words on it.
bool _unanswered(Object error) => switch (error) {
  duvet.DuvetApiException(:final statusCode) =>
    statusCode == 401 || statusCode == 408 || statusCode == 429 || statusCode >= 500,
  CoreError(:final code) => _again.contains(code),
  Exception() => true,
  _ => false,
};

/// A message's bytes no member can open any more, the core's word or the API's, or bytes of another epoch than the
/// group's as it is now (T-C1 of step 4's closing re-reviews): it's made again, with each after it.
class _Stale implements Exception {
  const _Stale();

  @override
  String toString() => "_Stale: the message's bytes aren't of the group as it is now; they're made again";
}

/// The core's word that no member could open the message's bytes any more.
bool _staleBytes(Object error) => error is CoreError && error.code == 'rule_violation' && error.rule == 'stale_message';

/// A message held for the person's yes, a verified contact's key changed ([Sends._delivered]): it waits, as an
/// unanswered one does.
bool _heldForYes(Object error) => error is CoreError && error.code == 'key_changed';

/// The person's Cancel of a message's upload, which stopped it before its request went or while it waited.
class UploadCancelled implements Exception {
  const UploadCancelled();

  @override
  String toString() => 'UploadCancelled: the person cancelled the upload';
}

/// A message's upload as it goes: the person's send's, with its request's progress and its Cancel, or a flush's own for
/// a message it sends again. Whichever flush delivers the message uses it, and a Dismiss stops its request and waits
/// for it to settle (task 19's review, M4, the desktop's N1).
class _Upload {
  _Upload(this.onProgress, this.cancel) {
    cancel?.then((_) => abort());
  }

  final void Function(int sent, int total)? onProgress;

  /// The person's Cancel of their send.
  final Future<void>? cancel;
  final _aborted = Completer<void>();

  /// Its delivery's end, the API's answer bound here: what a Dismiss waits for.
  Future<void> settled = Future<void>.value();

  /// Its Cancel or a Dismiss stopped it.
  bool get cancelled => _aborted.isCompleted;
  Future<void> get aborted => _aborted.future;

  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
  }
}

/// The person's send, as its lane settles it, or its Cancel's refusal at once: a newer message's Cancel never waits for
/// an older one's upload (task 18's review, I2). The lane goes on, and lets the cancelled message be as its turn comes.
Future<T> _untilCancelled<T>(Future<T> work, Future<void>? cancel) {
  if (cancel == null) return work;
  final done = Completer<T>();
  work.then(
    (value) {
      if (!done.isCompleted) done.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  cancel.then((_) {
    if (!done.isCompleted) done.completeError(const UploadCancelled());
  });
  return done.future;
}

class Sends {
  Sends(
    this._engine,
    this._groups,
    this._soon,
    this._turn,
    this._changed,
    this._sent,
    this._refused,
    this._deleted,
    this._held,
  );

  final E2EEngine _engine;
  final Conversations _groups;

  /// Runs work in the engine's turn, while the device is ready.
  final void Function(Future<void> Function() work) _soon;

  /// Runs work in the engine's turn as the person's act, and gives what it gives: refused while this device isn't
  /// ready. Only the core's calls take it: a message's request waits in its conversation's lane (task 18's review, I2).
  final Future<T> Function<T>(Future<T> Function() work) _turn;

  /// The person's messages this device deleted: their files go (task 18's review, M4).
  final void Function(String conversationId, List<String> messageIds) _deleted;

  /// A conversation's messages changed on this device.
  final void Function(String conversationId) _changed;

  /// A message the person sent (its first nonce) is the API's message now.
  final void Function(String conversationId, String nonce, duvet.DirectMessage message) _sent;

  /// A change of the person's the API refused for good where nobody waits for its answer (a restart's, or one sent
  /// after another of its message): the person is told, as the core shows it done here (its kind: `edit`, `delete`).
  final void Function(String conversationId, String messageId, String kind) _refused;

  /// The conversation's people whose changed key holds what goes there until the person's yes (contacts.dart), read in
  /// the engine's turn.
  final Future<List<String>> Function(String conversationId) _held;

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

  /// Each waiting message's files, sealed, by the nonce the person sent it with: in this run's memory alone, as the
  /// record keeps no file (the core's row keeps what its envelope says of them).
  final _files = <String, SealedFiles>{};

  /// Messages with files the API refused, by the nonce the person sent each with: they go again only on the person's
  /// Retry, as a refusal of their files wouldn't change, where every flush would send them whole (task 18's review,
  /// I3).
  final _refusedFiles = <String>{};

  /// Each conversation's flushes, one after the other («Los pendientes van primero y en orden»), outside the turn.
  final _lanes = <String, Future<void>>{};

  /// Each message's upload, by the nonce the person sent it with, while a send or a flush delivers it; a cancelled one
  /// until its Dismiss, so no later flush sends it meanwhile (task 19's review, M4).
  final _uploads = <String, _Upload>{};

  CoreHost get _host => _engine.host;
  duvet.E2eApi get _api => _engine.api;

  /// Whether this run holds the sealed bytes of the files of the person's message [nonce]: one that waits from before
  /// the app started again holds none, and can only be dismissed.
  bool holdsFiles(String nonce) => _files.containsKey(firstOf(nonce));

  /// The person's message, sent after what waits in its conversation: the API's message, or null when it was sent
  /// already. What fails leaves it waiting, with its bytes, for the person's Retry or Dismiss. Its files are sealed
  /// once, as it's first made; [onProgress] follows its request's upload, and [cancel] stops it: the send then fails at
  /// once, also while an older message's upload goes on in its lane.
  Future<duvet.DirectMessage?> send(
    Outgoing out, {
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    final id = out.conversationId;
    // Made again, it went under its new nonce, as its answer or its copy said: it was sent.
    if (_went.containsKey(out.nonce)) return null;
    final waits = await _turn(() async {
      // A message made again waits under another nonce, which its record knows by the person's.
      final nonce = _current(out.nonce);
      await _groups.current(id);
      final rows = await pendingRows(_host, id);
      final waiting = rows.any((row) => row.nonce == nonce);
      // Past them, the oldest would be out of the engine's sight (M5 of the desktop's review). One under the page: a
      // message made again has two rows for a moment, its new bytes made before its old ones go, and the older must
      // stay in sight to be dropped (N2 of task 17's re-review).
      if (!waiting && nonce == out.nonce && rows.length >= _pendingMost - 1) throw const TooManyWaiting();
      // What goes with it in the clear, kept once it's to be sent (M6 of task 17's review: after the refusals).
      if (nonce == out.nonce && !_record().containsKey(nonce)) await _keep(nonce, _Clear.of(out));
      if (waiting) return true;
      final sealed = out.files.isEmpty ? null : await SealedFiles.of(_host, out.files);
      try {
        await _encryptMade(id, nonce, out.text, sealed);
      } on CoreError catch (error) {
        // Its copy came back from the queue: it went.
        if (error.code != 'exists') rethrow;
        final first = firstOf(nonce);
        if (first != nonce) {
          if ((await _bound(id))[nonce] case final message?) _went[first] = (nonce: nonce, message: message);
        }
        await _forget(nonce);
        return false;
      }
      if (sealed != null) _files[nonce] = sealed;
      return true;
    });
    if (!waits) return null;
    return _personal(id, firstOf(out.nonce), _Upload(onProgress, cancel));
  }

  /// The person's Retry of a message that waits on this device, as the record keeps what goes with it: the API's
  /// message, or null when none waits under [nonce] (sent, or dismissed).
  Future<duvet.DirectMessage?> resend(String conversationId, String nonce) async {
    if (_went.containsKey(nonce)) return null;
    await _turn(() => _groups.current(conversationId));
    return _personal(conversationId, firstOf(nonce), _Upload(null, null));
  }

  /// The person's own send or Retry of their message [first], in its conversation's lane: a refusal of its files kept
  /// it from going with the others, not from this.
  Future<duvet.DirectMessage?> _personal(String id, String first, _Upload upload) {
    _refusedFiles.remove(first);
    _uploads[first] = upload;
    final run = _inLane(id, () => _flush(id, wantedFirst: first, upload: upload));
    unawaited(run.then<void>((_) => _letGo(first, upload), onError: (Object _) => _letGo(first, upload)));
    return _untilCancelled(run, upload.cancel);
  }

  /// A message's upload once its delivery or its send ended: a cancelled one stays for its Dismiss.
  void _letGo(String first, _Upload upload) {
    if (identical(_uploads[first], upload) && !upload.cancelled) _uploads.remove(first);
  }

  /// The person's Dismiss of their message [nonce] stops its request, if one is out, and waits for it to settle,
  /// outside the turn: a message the API took first is bound here, and the Dismiss gives its ID (task 19's review, M4).
  Future<void> settle(String nonce) async {
    final upload = _uploads[firstOf(nonce)];
    if (upload == null) return;
    upload.abort();
    await upload.settled;
  }

  /// Work in the conversation's lane, after what's already there: a failure there never stops what comes after.
  Future<T> _inLane<T>(String id, Future<T> Function() work) {
    final run = (_lanes[id] ?? Future<void>.value()).then((_) => work());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _lanes[id] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_lanes[id], tail)) _lanes.remove(id);
      }),
    );
    return run;
  }

  /// The nonce the message the person sent under [nonce] waits under now, or went under: another once it was made
  /// again.
  String current(String nonce) => _current(nonce);

  String _current(String nonce) =>
      _went[nonce]?.nonce ??
      _record().entries.where((kept) => kept.value.first == nonce).lastOrNull?.key ??
      // This run's newest remake of it, once the record let it go (its bound row past the rows `_bound` reads: N3 of
      // task 17's re-review): a Retry goes under it, which the core answers `exists`.
      _firstOf.entries.where((made) => made.value == nonce).lastOrNull?.key ??
      nonce;

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
    _files.remove(nonce);
    _refusedFiles.remove(nonce);
    _uploads.remove(nonce);
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

  /// At the start and at each READY, the queues applied: what waits, in each conversation, and the changes. The
  /// messages go in their conversations' lanes, which this, in the engine's turn, doesn't wait for.
  Future<void> resendAll() async {
    for (final id in {for (final clear in _record().values) clear.conversationId}) {
      // The pause holds its conversation's messages until its Retry-After, which a READY doesn't cut short.
      if (_paused.containsKey(id)) continue;
      unawaited(
        _inLane(
          id,
          () => _flush(id),
        ).then<void>((_) {}, onError: (Object error) => debugPrint('e2e: what waits to be sent waits again: $error')),
      );
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
          // Made again only for a group as the person sees it: else it, and its message's changes after it, wait in
          // the record for the next start or READY (N-I3 of step 4's closing re-review).
          if (!await _asDrawn(conversation)) break;
          final change = _Change(conversation, message, text);
          change.made = await _make(change);
          await _queueChange(change, noted: true, send: false);
        } catch (error) {
          if (error case CoreError(code: 'not_found', what: 'message')) {
            // Its message isn't on this device any more: nothing to change (M4 of task 17's review).
            await _unnote(conversation, message, kind);
          } else if (error case CoreError(code: 'not_found')) {
            // The device is out of its group (`membership`), or holds none: it, and its message's changes after it,
            // wait in the record for the next start or READY (mobile#377).
            break;
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
  /// once ([taken] is told then), sent, and the entry its answer gives taken by the core. Without an answer its bytes
  /// go again later.
  Future<void> change(String conversationId, String messageId, String? text, {void Function()? taken}) async {
    await _groups.current(conversationId);
    final change = _Change(conversationId, messageId, text);
    change.made = await _make(change);
    _changed(conversationId);
    if (text == null) _deleted(conversationId, [messageId]);
    taken?.call();
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
    _files.clear();
    _refusedFiles.clear();
    _lanes.clear();
    _uploads.clear();
  }

  /// What waits in the conversation, in the person's order ([wantedFirst]: the nonce the person sent theirs with, whose
  /// message this gives, its upload followed by [upload]). An older one the API or the core refused stays, for the
  /// person's Retry or Dismiss, and the rest go on; one without an answer (a cut call to the core too) stops them all,
  /// as does an update. Once a message's bytes no member could open any more, it and each after it are made again
  /// together, before any of them goes (I3 of task 17's review), and the flush goes on from it. One with files whose
  /// sealed bytes this run no longer has waits for its Dismiss, and one with files the API refused for the person's
  /// Retry. It runs in its conversation's lane, each of the core's calls in the turn.
  Future<duvet.DirectMessage?> _flush(String id, {String? wantedFirst, _Upload? upload}) async {
    var rows = await _turn(() async {
      final waiting = await _waiting(id);
      // A message's old bytes beside new ones a remake made, which carry it, go unsent (I2 of task 17's review).
      for (final row in waiting.older) {
        await _drop(row.nonce!);
      }
      await _prune(id, waiting.rows);
      return waiting.rows;
    });
    final done = <String>{};
    final remade = <String>{};
    duvet.DirectMessage? message;
    for (var at = 0; at < rows.length; at++) {
      final row = rows[at];
      final nonce = row.nonce;
      if (nonce == null) continue;
      final first = firstOf(nonce);
      if (!done.add(first)) continue;
      final clear = _record()[nonce];
      final wanted = first == wantedFirst;
      // A message with nothing in it, and nothing kept of what went with it, waits for the person's Dismiss.
      if (!wanted && clear == null && row.text == null && row.attachments.isEmpty) continue;
      // One the API refused with its files goes again only on the person's Retry (task 18's review, I3).
      if (!wanted && _refusedFiles.contains(first)) continue;
      // Its own upload, whichever flush sends it; one whose Cancel came waits for its Dismiss (task 19's review, M4).
      final own = wanted ? upload : _uploads[first];
      if (!wanted && (own?.cancelled ?? false)) continue;
      final files = row.attachments.isEmpty ? null : _files[first];
      if (row.attachments.isNotEmpty && files == null) {
        if (wanted) throw const FilesGone();
        continue;
      }
      // Sent again by this flush: an upload of its own, which a Dismiss stops.
      final delivery = own ?? (_uploads[first] = _Upload(null, null));
      try {
        final sent = await _deliver(id, row, clear ?? _Clear(id), files, delivery);
        if (wanted) message = sent;
      } on _Stale {
        // Made again in this flush and stale again: it waits, and so does every message after it, so none goes before
        // it (choice 2 of task 17's re-review). The person's, unless it went already, says it didn't.
        if (remade.contains(first)) {
          if (message == null && wantedFirst != null) rethrow;
          debugPrint('e2e: a message made again is stale again: it and those after it wait, to send again.');
          return message;
        }
        final tail = [
          for (final next in rows.sublist(at))
            if (next.nonce != null) next,
        ];
        final firsts = [for (final next in tail) firstOf(next.nonce!)];
        remade.addAll(firsts);
        done.removeAll(firsts);
        final now = await _turn(() async {
          // The queue first, whoever said the bytes were stale (the core, their epoch, the API's 409): a copy the API
          // took binds its message, which isn't made again, and the new bytes are of the epochs the API is at.
          await _groups.sync(id, read: true);
          // What a Dismiss let go meanwhile isn't made again.
          final waiting = {for (final other in (await _waiting(id)).rows) other.nonce};
          await _remake(id, [
            for (final next in tail)
              if (waiting.contains(next.nonce)) next,
          ]);
          return (await _waiting(id)).rows;
        });
        rows = [
          ...rows.sublist(0, at),
          for (final next in now)
            if (next.nonce case final later? when !done.contains(firstOf(later))) next,
        ];
        at--;
      } catch (error) {
        // Stopped by its Cancel or a Dismiss: it went nowhere, and the rest go on.
        if (!wanted && delivery.cancelled) continue;
        final passing = error is duvet.DuvetUpdateRequiredException || _unanswered(error) || _heldForYes(error);
        // Its files' refusal won't change: it waits for the person's Retry.
        if (files != null && !passing && error is duvet.DuvetApiException) _refusedFiles.add(first);
        if (wanted || passing) rethrow;
        debugPrint('e2e: a message that waits was refused: it stays, to send again or dismiss. $error');
      } finally {
        if (own == null) _letGo(first, delivery);
      }
    }
    return message;
  }

  /// One message that waits: its bytes as the core made them and `sent` once the API took it, in the turn, and its
  /// request with its sealed files between them, outside it. Bytes no member could open any more throw [_Stale]. Null
  /// when it no longer waits as its turn comes: a Dismiss let it go, or the queue brought its copy back.
  Future<duvet.DirectMessage?> _deliver(
    String id,
    ShownMessage row,
    _Clear clear,
    SealedFiles? files,
    _Upload upload,
  ) async {
    final settled = Completer<void>();
    upload.settled = settled.future;
    try {
      return await _delivered(id, row, clear, files, upload);
    } finally {
      settled.complete();
    }
  }

  Future<duvet.DirectMessage?> _delivered(
    String id,
    ShownMessage row,
    _Clear clear,
    SealedFiles? files,
    _Upload upload,
  ) async {
    final nonce = row.nonce!;
    final made = await _turn(() async {
      if (!(await pendingRows(_host, id)).any((other) => other.nonce == nonce)) return null;
      // Nothing goes to a group that holds someone the person doesn't see there (C1 of step 4's closing reviews): the
      // look, whose read and due commit are the group's last moves before the bytes.
      await _groups.asShown(id);
      final _Made bytes;
      try {
        bytes = await _encrypt(id, nonce, row.text, row.attachments);
      } catch (error) {
        if (_staleBytes(error)) throw const _Stale();
        rethrow;
      }
      // Only bytes of the group as the core holds it now go (T-C1 of step 4's closing re-reviews): the core gives a
      // nonce's kept bytes back up to 5 epochs behind, so ones made before the look moved it are made again.
      if (!await _groups.isAt(id, bytes.generation, bytes.epoch)) throw const _Stale();
      // Whom it reaches whose changed key waits for the person's yes, known by now (its encrypt may have just observed
      // it), read in the same turn.
      final holding = await _held(id);
      // And after the bytes, a comparison that reads nothing: a difference waits.
      await _groups.stillAsShown(id);
      return (ciphertext: bytes.ciphertext, holding: holding);
    });
    if (made == null) return null;
    // Its Cancel, or a Dismiss, came while older messages went: it isn't sent.
    if (upload.cancelled) throw const UploadCancelled();
    // A verified contact's changed key: it waits for the person's yes, its bytes kept in the core, as decision 25 asks
    // before anything more goes there. It counts as unanswered: what waits after it stays.
    if (made.holding.isNotEmpty) {
      throw CoreError(
        'key_changed',
        message: "a verified contact's key changed: the person says whether to send",
        users: made.holding,
      );
    }
    final ciphertext = made.ciphertext;
    final text = row.text;
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
          attachmentIds: files?.ids ?? const [],
        ),
        files: files?.parts ?? const [],
        onProgress: upload.onProgress,
        abortTrigger: upload.aborted,
      );
    } on duvet.DuvetStaleMessageException {
      // Made again, after the queue's read ([_flush]).
      throw const _Stale();
    } on duvet.DuvetPausedException catch (error) {
      _afterPause(id, error.retryAfter);
      rethrow;
    }
    await _turn(() async {
      try {
        await _host.handle<Object?>({
          'cmd': 'sent',
          'conversation_id': id,
          'nonce': nonce,
          'message_id': message.id,
          'seq': message.seq,
          'reply_to': ?clear.replyTo,
        });
      } on CoreError catch (error) {
        // Dismissed while its request was out, and the API took it all the same: it went.
        if (error.code != 'not_found') rethrow;
      }
      await _forget(nonce);
      final first = clear.first ?? nonce;
      _files.remove(first);
      _refusedFiles.remove(first);
      _uploads.remove(first);
      if (first != nonce) _went[first] = (nonce: nonce, message: message.id);
      _changed(id);
      _sent(id, first, message);
    });
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
      if (clear == null && row.text == null && row.attachments.isEmpty) continue;
      final kept = (clear ?? _Clear(id)).again(old);
      final fresh = uuidv4();
      await _keep(fresh, kept);
      try {
        // The same files, under the same IDs: the API takes them again (task 18's review, choice 7).
        await _encrypt(id, fresh, row.text, row.attachments);
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

  /// A new message's encrypt, its files' envelope as [sealed] made it: while the core finds the message too large, the
  /// largest thumbnail inside it goes apart, a file of its own, and it's encrypted again under the same nonce (the core
  /// keeps nothing of a too-large encrypt).
  Future<_Made> _encryptMade(String id, String nonce, String? text, SealedFiles? sealed) async {
    while (true) {
      try {
        return await _encrypt(id, nonce, text, sealed?.attachments ?? const []);
      } on CoreError catch (error) {
        if (error.code != 'too_large' || sealed == null || !await sealed.apart()) rethrow;
      }
    }
  }

  /// The core's encrypt: the message kept as pending, or, for a nonce it has, its bytes again (of the epoch they were
  /// made at), which takes the same envelope back, its files' row as the core keeps it ([attachments]). What keeps
  /// this device from sending there is dealt with once: users to observe, leaves and removals to commit, a group to
  /// join or make.
  Future<_Made> _encrypt(String id, String nonce, String? text, List<Map<String, Object?>> attachments) async {
    Future<_Made> run() async => _madeOf(
      await withIdentities(
        _engine,
        () => _host.handle<Map<String, Object?>>({
          'cmd': 'encrypt',
          'conversation_id': id,
          'nonce': nonce,
          'envelope': messageEnvelope(text ?? '', attachments),
        }),
      ),
    );
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
      unawaited(
        _inLane(id, () => _flush(id)).then<void>(
          (_) {},
          onError: (Object error) => debugPrint("e2e: what waited for the pause's end waits again: $error"),
        ),
      );
    });
  }

  /// An edit's or a deletion's bytes, as the core makes them now, for the group as it is: it moves nothing.
  Future<_Made> _make(_Change change) async => _madeOf(
    await withIdentities(
      _engine,
      () => _host.handle<Map<String, Object?>>({
        'cmd': change.text == null ? 'delete' : 'edit',
        'conversation_id': change.conversationId,
        'message_id': change.messageId,
        'text': ?change.text,
      }),
    ),
  );

  /// An edit's or a deletion's request, its bytes as they are while its group stays where they were made: its answer's
  /// entry to the core. Without an answer it goes again later and at each READY; bytes the API says no member could
  /// open now are made again, once. A refusal
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
    // An edit is new text: while a verified contact's changed key waits for the person's yes it waits as an unanswered
    // one does, its bytes as the core last made them, each try looking again, and the yes sends it (review 28's I2). A
    // deletion carries no text, and goes.
    if (change.text != null && (await _held(id)).isNotEmpty) return _retryLater(change);
    // Nor while its group holds someone the person doesn't see there, each try looking as a message's delivery does
    // (N-I3 of step 4's closing re-review): it waits as an unanswered one does.
    if (!await _asDrawn(id)) return _retryLater(change);
    final _Made made;
    try {
      // Its bytes of the group as it is after that look, made again once it moved (T-C1 of step 4's closing
      // re-reviews), and a comparison that reads nothing after them.
      final kept = change.made;
      made = change.made = kept != null && await _groups.isAt(id, kept.generation, kept.epoch)
          ? kept
          : await _make(change);
      await _groups.stillAsShown(id);
    } catch (failed) {
      // Its message isn't on this device any more (the person's deletion of it, made at once, behind it): nothing to
      // change, as a start's resend lets such a change go. Out of its group (`membership`), or with none, it waits
      // (mobile#377).
      if (failed case CoreError(code: 'not_found', what: 'message')) {
        await _answered(change);
        _changed(id);
        return;
      }
      // What throws past its request waits as no answer does (M4 of task 17's review, the desktop's N6).
      debugPrint('e2e: a change goes again later: $failed');
      return _retryLater(change);
    }
    final duvet.MlsEntry entry;
    try {
      entry = change.text == null
          ? (await _api.deleteMessage(id, change.messageId, made.ciphertext)).entry
          : (await _api.editMessage(id, change.messageId, made.ciphertext)).entry;
    } catch (error) {
      // An update keeps it, for after the update.
      if (error is duvet.DuvetUpdateRequiredException) rethrow;
      if (error is duvet.DuvetStaleMessageException && !change.remade) {
        try {
          await _groups.sync(id, read: true);
        } catch (failed) {
          debugPrint('e2e: a change goes again later: $failed');
          return _retryLater(change);
        }
        // Made again by the next try, after its look, for the epochs the API is at.
        change.made = null;
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

  /// Whether the conversation's group is as the person sees it ([Conversations.asShown]): false, logged, while it isn't,
  /// or while that can't be told.
  Future<bool> _asDrawn(String id) async {
    try {
      await _groups.asShown(id);
      return true;
    } catch (error) {
      debugPrint('e2e: a change waits for its group to be as drawn: $error');
      return false;
    }
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
