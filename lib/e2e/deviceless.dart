/// Members without a device (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo»; decision 14): a member with no
/// identity, or none of whose listed devices connected in 45 days, can't read what's sent meanwhile. The core is told
/// who they are as the person opens the conversation and at each IDENTITY_UPDATE (without_devices, all of them each
/// time), notes for them what this device sends, and names them in apply's catch_up_due once they have a device again:
/// this device then hands them what it noted as a catch-up (PLAN-E2E-API.md, «Rutas», I), its parts up, its key to each
/// of their devices' inbox, and only then confirmed (catch_up_delivered). Each runs in the engine's turn, so one at a
/// time for each member of each conversation; one refused for its limit (a 429: the API takes one a day for each) waits
/// a day, its notes kept. The desktop's deviceless.ts in Dart.
library;

import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;

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

/// The catch-ups this device hands members who had no device, each in the engine's turn ([_soon]).
class CatchUps {
  CatchUps(this._engine, this._soon);

  final E2EEngine _engine;
  final void Function(Future<void> Function() work) _soon;

  /// Catch-ups the API refused for its limit, by conversation and member: each waits its day (its timer).
  final _waiting = <String, void Function()>{};

  /// Catch-ups whose turn is on its way: one is enough, as it carries all that's noted by then.
  final _queued = <String>{};

  /// apply named these members of the conversation due a catch-up: each one's goes in its turn, once, but one waiting
  /// its day.
  void due(String conversationId, List<String> users) {
    for (final user in users) {
      final key = '$conversationId:$user';
      if (!_queued.add(key)) continue;
      _soon(() async {
        _queued.remove(key);
        await _deliver(conversationId, user);
      });
    }
  }

  void stop() {
    for (final cancel in _waiting.values) {
      cancel();
    }
    _waiting.clear();
    _queued.clear();
  }

  Future<void> _deliver(String conversationId, String user) async {
    final key = '$conversationId:$user';
    if (_waiting.containsKey(key) || await deliverCatchUp(_engine, conversationId, user)) return;
    _waiting[key] = _engine.clock.later(_day, () {
      _waiting.remove(key);
      due(conversationId, [user]);
    });
  }
}

/// One member's catch-up in the conversation: what this device noted for them, sealed to their listed devices as the
/// API serves them, up, with its key in each of those devices' inbox, then confirmed, the member observed first so the
/// core holds the list it was sealed to. Nothing noted (or nothing their devices can take) is done; false for a 429.
Future<bool> deliverCatchUp(E2EEngine engine, String conversationId, String user) async {
  final E2EEngine(:api, :host) = engine;
  final duvet.Identity identity;
  try {
    identity = await api.identity(user);
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 403 || error.statusCode == 404) return true;
    rethrow;
  }
  await observeUsers(engine, [user]);
  final Map<String, Object?> made;
  try {
    made = await withIdentities(
      engine,
      () => host.share({
        'cmd': 'catch_up',
        'conversation_id': conversationId,
        'user_id': user,
        'devices': identity.certificates,
      }),
    );
  } on CoreError catch (error) {
    // Nothing noted that a catch-up carries, or the member still counted as without a device.
    if (error.code == 'not_found' && error.what == 'catch_up') return true;
    rethrow;
  }
  final shareId = made['share_id']! as String;
  final parts = made['parts']! as int;
  try {
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
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 429) return false;
    rethrow;
  } finally {
    await host.dropShare(shareId);
  }
  await observeUsers(engine, [user]);
  try {
    await host.handle<Object?>({
      'cmd': 'catch_up_delivered',
      'conversation_id': conversationId,
      'user_id': user,
      'share_id': shareId,
    });
  } on CoreError catch (error) {
    // None of the devices it was sealed to is on their list any more: its notes stay for the next catch-up.
    if (error.code != 'not_found') rethrow;
  }
  return true;
}
