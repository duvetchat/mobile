/// Members without a device (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo»; decision 14): a member with no
/// identity, or none of whose listed devices connected in 45 days, can't read what's sent meanwhile. The core is told
/// who they are as the person opens the conversation and at each IDENTITY_UPDATE (without_devices, all of them each
/// time), notes for them what this device sends, and names them in apply's catch_up_due once they have a device again:
/// this device then hands them what it noted as a catch-up (PLAN-E2E-API.md, «Rutas», I), its parts up, its key to each
/// of their devices' inbox, and only then confirmed (catch_up_delivered). Each runs in the engine's turn, so one at a
/// time for each member of each conversation; one refused for its limit (a 429: the API takes one a day for each) waits
/// a day, its notes kept. The desktop's deviceless.ts in Dart.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'host.dart';
import 'identity.dart';

const _day = Duration(days: 1);

/// The conversation's members without a device, as the API serves their identities, told to the core: of those its
/// group holds ([held]), all but this user. The core refuses a user its group doesn't list, which a change the queue
/// hasn't brought yet can be.
Future<List<String>> withoutDevices(E2EEngine engine, duvet.Conversation conv, List<String> held) async {
  final members = [
    for (final m in conv.members)
      if (m.userId != engine.user && held.contains(m.userId)) m.userId,
  ];
  final active = <String, bool>{};
  for (var at = 0; at < members.length; at += 50) {
    for (final identity in await engine.api.identities(members.sublist(at, min(at + 50, members.length)))) {
      active[identity.userId] = identity.active;
    }
  }
  // Without an identity (left out of the answer), or with none of their devices seen lately.
  final users = [
    for (final id in members)
      if (active[id] != true) id,
  ];
  await engine.host.handle<Object?>({'cmd': 'without_devices', 'conversation_id': conv.id, 'users': users});
  return users;
}

/// The catch-ups this device hands members who had no device: each package made, and confirmed, in the engine's turn
/// ([_soon]), its upload outside it, so the engine's other work goes on meanwhile. One at a time for each member of
/// each conversation. A package stays until it's delivered: one whose upload failed past its `PUT` resumes, as the API
/// takes the same package and parts again. A refusal for the API's limit (a 429: one a day for each member) waits a day
/// with its notes, as the plan's table says (`duvet_client` keeps no `Retry-After`); any other failure goes again after
/// a wait, 2 s doubling up to an hour.
class CatchUps {
  CatchUps(this._engine, this._soon);

  final E2EEngine _engine;
  final void Function(Future<void> Function() work) _soon;

  /// Catch-ups waiting before they go again (a day, or a backoff), by conversation and member: their timers.
  final _waiting = <String, void Function()>{};

  /// Catch-ups whose turn is on its way: one is enough, as it carries all that's noted by then.
  final _queued = <String>{};

  /// Catch-ups whose package is made and on its way up, or being confirmed: none other starts meanwhile.
  final _going = <String>{};

  /// Each package made and not delivered yet, by conversation and member, and how many tries failed in a row.
  final _made = <String, Map<String, Object?>>{};
  final _failed = <String, int>{};

  /// apply named these members of the conversation due a catch-up: each one's goes in its turn, once, but one waiting
  /// or on its way.
  void due(String conversationId, List<String> users) {
    for (final user in users) {
      final key = '$conversationId:$user';
      if (_waiting.containsKey(key) || _going.contains(key) || !_queued.add(key)) continue;
      _soon(() async {
        _queued.remove(key);
        await _make(conversationId, user);
      });
    }
  }

  /// The turns queued and never run (the engine wasn't ready) go: the next apply asks for them again (M3).
  void dropQueued() => _queued.clear();

  void stop() {
    for (final cancel in _waiting.values) {
      cancel();
    }
    _waiting.clear();
    _queued.clear();
    _going.clear();
  }

  /// In the engine's turn: the member's package, made (or the one made before), then its upload outside the turn.
  Future<void> _make(String conversationId, String user) async {
    final key = '$conversationId:$user';
    if (_waiting.containsKey(key) || _going.contains(key)) return;
    try {
      final made = _made[key] ?? await makeCatchUp(_engine, conversationId, user);
      if (made == null) return _done(key);
      _made[key] = made;
      _going.add(key);
      unawaited(_upload(conversationId, user, made));
    } catch (error) {
      _later(key, conversationId, user, error);
    }
  }

  Future<void> _upload(String conversationId, String user, Map<String, Object?> made) async {
    final key = '$conversationId:$user';
    try {
      await uploadCatchUp(_engine, conversationId, user, made);
    } catch (error) {
      _going.remove(key);
      // Its parts went with the core's host (a restart): made again next time.
      if (error is CoreError && error.code == 'not_found') _made.remove(key);
      return _later(key, conversationId, user, error);
    }
    _soon(() async {
      try {
        await confirmCatchUp(_engine, conversationId, user, made['share_id']! as String);
        _done(key);
      } catch (error) {
        _going.remove(key);
        _later(key, conversationId, user, error);
      }
    });
  }

  void _done(String key) {
    _going.remove(key);
    _failed.remove(key);
    if (_made.remove(key)?['share_id'] case final String share) {
      unawaited(_engine.host.dropShare(share).catchError((Object _) {}));
    }
  }

  /// A failure: a 429 waits a day, its package dropped (the day's slot is spent); anything else waits its backoff.
  void _later(String key, String conversationId, String user, Object error) {
    final Duration wait;
    if (error is duvet.DuvetApiException && error.statusCode == 429) {
      wait = _day;
      _done(key);
    } else {
      final tries = _failed[key] = (_failed[key] ?? 0) + 1;
      final backoff = const Duration(seconds: 2) * (1 << min(tries - 1, 11));
      wait = backoff < const Duration(hours: 1) ? backoff : const Duration(hours: 1);
      debugPrint("e2e: a catch-up didn't go, and goes again: $error");
    }
    _waiting[key]?.call();
    _waiting[key] = _engine.clock.later(wait, () {
      _waiting.remove(key);
      due(conversationId, [user]);
    });
  }
}

/// One member's catch-up made: what this device noted for them, sealed to their listed devices as the API serves them,
/// the member observed first so the core holds the list it seals to. Null when there's nothing to give (nothing noted
/// that a catch-up carries, the member still counted as without a device, or no identity of theirs to read).
Future<Map<String, Object?>?> makeCatchUp(E2EEngine engine, String conversationId, String user) async {
  final E2EEngine(:api, :host) = engine;
  final duvet.Identity identity;
  try {
    identity = await api.identity(user);
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 403 || error.statusCode == 404) return null;
    rethrow;
  }
  await observeUsers(engine, [user]);
  try {
    return await withIdentities(
      engine,
      () => host.share({
        'cmd': 'catch_up',
        'conversation_id': conversationId,
        'user_id': user,
        'devices': identity.certificates,
      }),
    );
  } on CoreError catch (error) {
    if (error.code == 'not_found' && error.what == 'catch_up') return null;
    rethrow;
  }
}

/// A catch-up's package up, part by part, completed, then its key in each device's inbox. The same package and parts
/// again are taken as they were, so one that failed midway goes again from the start.
Future<void> uploadCatchUp(E2EEngine engine, String conversationId, String user, Map<String, Object?> made) async {
  final E2EEngine(:api, :host) = engine;
  final shareId = made['share_id']! as String;
  final parts = made['parts']! as int;
  await api.putShare(
    conversationId,
    shareId,
    duvet.HistoryShareUpload(
      toUserId: user,
      kind: 'catch_up',
      startsAt: DateTime.fromMillisecondsSinceEpoch(made['start']! as int, isUtc: true),
      size: made['size']! as int,
      parts: parts,
    ),
  );
  for (var n = 0; n < parts; n++) {
    await api.putSharePart(conversationId, shareId, n, await host.sharePart(shareId, n));
  }
  await api.completeShare(conversationId, shareId);
  for (final key in (made['keys']! as List).cast<Map<String, Object?>>()) {
    await api.sendToDevice(key['device_id']! as String, key['message']! as String);
  }
}

/// The catch-up delivered, confirmed to the core once its user is observed again: its notes go. None of the devices it
/// was sealed to on their list any more leaves its notes for the next catch-up.
Future<void> confirmCatchUp(E2EEngine engine, String conversationId, String user, String shareId) async {
  await observeUsers(engine, [user]);
  try {
    await engine.host.handle<Object?>({
      'cmd': 'catch_up_delivered',
      'conversation_id': conversationId,
      'user_id': user,
      'share_id': shareId,
    });
  } on CoreError catch (error) {
    if (error.code != 'not_found') rethrow;
  }
}
