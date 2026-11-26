/// Members without a device (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo»; decision 14): a member with no
/// identity, or none of whose listed devices connected in 45 days, can't read what's sent meanwhile. The core is told
/// who they are as the person opens the conversation and at each IDENTITY_UPDATE (without_devices, all of them each
/// time), notes for them what this device sends, and names them in apply's catch_up_due once they have a device again:
/// this device then hands them what it noted as a catch-up (PLAN-E2E-API.md, «Rutas», I), its parts up, its key to each
/// of their devices' inbox, then completed, and only then confirmed (catch_up_delivered). Each runs in the engine's
/// turn, so one at a time for each member of each conversation; a try that fails waits ([packageWait]), one refused
/// before the API took it for its limit (a 429: one a day for each) as long as it says, its notes kept. Their device
/// imports it by itself (history.dart). The desktop's deviceless.ts in Dart.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'history.dart' show PackageUpload, packageWait, uploadPackage;
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
/// each conversation. A package stays until it's delivered: one whose upload failed goes on from where it stopped after
/// a wait ([packageWait]: a minute, doubling up to an hour, a 429 as long as it says). A package the API didn't take
/// for its limit (one a day for each member) goes, and the next try, a day later unless its Retry-After says when,
/// makes another with all that's noted by then; so does one the API refused, or whose parts the core no longer has.
class CatchUps {
  CatchUps(this._engine, this._soon);

  final E2EEngine _engine;
  final void Function(Future<void> Function() work) _soon;

  /// Catch-ups waiting before they go again, by conversation and member: their timers.
  final _waiting = <String, void Function()>{};

  /// Catch-ups whose turn is on its way: one is enough, as it carries all that's noted by then.
  final _queued = <String>{};

  /// Catch-ups whose package is made and on its way up, or being confirmed: none other starts meanwhile.
  final _going = <String>{};

  /// Each package made and not delivered yet, by conversation and member, and how many tries failed in a row.
  final _uploads = <String, PackageUpload>{};
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
      var upload = _uploads[key];
      if (upload == null) {
        final made = await makeCatchUp(_engine, conversationId, user);
        if (made == null) return _done(key);
        upload = _uploads[key] = PackageUpload(conversationId, user, made, kind: 'catch_up');
      }
      _going.add(key);
      unawaited(_upload(key, upload));
    } catch (error) {
      _later(key, conversationId, user, error, null);
    }
  }

  Future<void> _upload(String key, PackageUpload upload) async {
    final PackageUpload(:conversationId, :user, :shareId) = upload;
    try {
      await uploadPackage(_engine, upload);
    } catch (error) {
      _going.remove(key);
      return _later(key, conversationId, user, error, upload);
    }
    _soon(() async {
      try {
        await confirmCatchUp(_engine, conversationId, user, shareId);
        _done(key);
      } catch (error) {
        // Delivered: only the confirmation goes again, with the same package.
        _going.remove(key);
        _later(key, conversationId, user, error, null);
      }
    });
  }

  void _done(String key) {
    _going.remove(key);
    _failed.remove(key);
    _drop(key);
  }

  /// The package goes from the core's engine: the next try makes another.
  void _drop(String key) {
    if (_uploads.remove(key) case final upload?) {
      unawaited(_engine.host.dropShare(upload.shareId).catchError((Object _) {}));
    }
  }

  /// A try that failed waits for its next ([packageWait]; [upload] is the package that went, if one did). A package the
  /// API didn't take goes: for its limit (a 429), as long as its Retry-After says, a day without one; refused
  /// otherwise, the backoff. So does one that ends for good once taken (the core lost its parts, or the API refused
  /// what no try changes). Anything else goes on with the same package after its wait.
  void _later(String key, String conversationId, String user, Object error, PackageUpload? upload) {
    final tries = _failed[key] ?? 0;
    _failed[key] = tries + 1;
    final status = error is duvet.DuvetApiException ? error.statusCode : null;
    // A refusal no try changes, not a session's renewal, a slow answer, a limit or the server.
    final refused = status != null && status < 500 && !const {401, 408, 429}.contains(status);
    if (upload != null && (upload.taken ? upload.endsWith(error) : status == 429 || refused)) _drop(key);
    final wait = packageWait(error, tries, unsaid: upload != null && !upload.taken ? _day : null);
    debugPrint("e2e: a catch-up didn't go, and goes again: $error");
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
