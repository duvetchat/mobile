/// The inbox (PLAN-E2E-CLIENTES.md, «El buzón»): what other devices sent this one, read oldest first at start, at each
/// READY and on DEVICE_MESSAGE. Each message is handled, then deleted with every one before it (DELETE …?through=):
/// one that can't be handled yet ends the round, and waits with those after it for the next one. Tasks 23, 27, 31 and
/// 33 add what their messages are for: a shared history's or a catch-up's key is the core's, and its package
/// history.dart's.
library;

import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'cbor.dart';
import 'conventions.dart' show readApprovalFrame;
import 'engine.dart';
import 'failures.dart';
import 'host.dart';
import 'identity.dart';
import 'store.dart';

/// The most messages a page of the inbox has (the API's most).
const _page = 100;

/// The most messages the record keeps of each kind.
const _kept = 20;

/// What a later round may get past: a cut call, the database, another engine; five rounds a message at most.
const _again = {'internal', 'storage', 'locked'};
const _mostTries = 5;

/// A message the core can't take with what the inbox gives it yet, which its type's task gives (a history or catch-up
/// key, Tasks 23 and 31): a field it lacks, or the users to observe first. Kept for that task: its sender won't send
/// it again.
bool _forLater(CoreError error) =>
    (error.code == 'bad_command' && error.field != null && error.field != 'message') ||
    error.code == 'needs_identities';

/// Keeps [message] in the record under [key], once, with the newest of those before it.
Future<void> _keep(EngineStore store, String key, duvet.InboxMessage message) {
  final kept = [
    for (final one in switch (store.read(key)) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    })
      if (one is Map && one['id'] != message.id) one,
    {
      'id': message.id,
      'from_user_id': message.fromUserId,
      'from_device_id': message.fromDeviceId,
      'message': message.message,
      'created_at': message.createdAt.toUtc().toIso8601String(),
    },
  ];
  return store.write(key, kept.sublist(max(0, kept.length - _kept)));
}

/// Reads the inbox and handles each message. An approval's step from one of the user's own devices is kept for its
/// flow (Task 27), so deleting the inbox through it loses nothing, and another user's is dropped. Anything else goes
/// to receive_direct, with the identity the API serves for the user today (what a rotation's transfer is checked
/// against) and its sender's certificate, from the sender's served identity. A transfer the core keeps for later
/// (`not_found` `code`: an approval whose code wasn't accepted yet) is kept in the record, as is one a later task takes
/// ([_forLater]); one no core here can read goes, as does one whose call is cut five rounds running ([tries], by its
/// ID). One that doesn't open is counted for the API as a failure to decrypt (`direct`, [failures]). A rotation's
/// transfer that keeps a device this device's own waiting change takes off is refused (`removed_device_listed`,
/// duvetchat/e2e#49), which [relisted] hears: that change can never finish. What the core answered goes to [taken]
/// before its message leaves the inbox (a shared history's or a catch-up's key, which the record keeps: history.dart);
/// one [taken] can't keep waits with the round. True when the inbox brought a rotation's
/// transfer, after which the own user is observed (the core's rule).
Future<bool> takeInbox(
  E2EEngine engine,
  Map<String, int> tries, [
  Failures? failures,
  void Function()? relisted,
  Future<void> Function(Map<String, Object?> received)? taken,
]) async {
  final E2EEngine(:api, :host, :store, :user) = engine;
  var rotated = false;
  // Users' identities as served, read once a round when a message needs one: null for one that can't be read.
  final identities = <String, Future<duvet.Identity?>>{};
  Future<duvet.Identity?> identityOf(String of) => identities[of] ??= api
      .identity(of)
      .then<duvet.Identity?>(
        (identity) => identity,
        onError: (Object error) {
          if (error is duvet.DuvetApiException && (error.statusCode == 403 || error.statusCode == 404)) return null;
          throw error;
        },
      );

  /// Whether [message] is done with: handled, kept, or one that never will be.
  Future<bool> handleOne(duvet.InboxMessage message) async {
    try {
      if (readApprovalFrame(message.message) != null) {
        // Approvals are between the user's own devices (M3 of the desktop's review).
        if (message.fromUserId == user) await _keep(store, keptApprovals, message);
        return true;
      }
      final own = await identityOf(user);
      final sender = await identityOf(message.fromUserId);
      final certificate = sender?.certificates.where((one) => certificateDevice(one) == message.fromDeviceId);
      // A catch-up's key (Task 23) or a history's is taken once its sender's identity is known here: observed first.
      final received = await withIdentities(
        engine,
        () => host.handle<Map<String, Object?>>({
          'cmd': 'receive_direct',
          'message': message.message,
          'identity_key': ?own?.identityKey,
          'from_certificate': ?certificate?.firstOrNull,
        }),
      );
      if (received['type'] == 'rotation.transfer') rotated = true;
      await taken?.call(received);
    } on CoreError catch (error) {
      if (_again.contains(error.code)) {
        final tried = (tries[message.id] ?? 0) + 1;
        tries[message.id] = tried;
        if (tried < _mostTries) {
          debugPrint('e2e: the inbox waits for its next round (${error.code}).');
          return false;
        }
        debugPrint('e2e: a message from another device failed $tried times (${error.code}), and goes.');
      } else if (error.code == 'not_found' && error.what == 'code') {
        await _keep(store, keptTransfers, message);
      } else if (_forLater(error)) {
        await _keep(store, keptLater, message);
      } else if (error.code == 'rule_violation' && error.rule == 'removed_device_listed') {
        debugPrint("e2e: another device's change of keys keeps a device this one takes off, and goes.");
        relisted?.call();
      } else {
        if (error.code == 'decrypt_failed') failures?.note('direct');
        debugPrint("e2e: a message from another device can't be read here (${error.code}), and goes.");
      }
    }
    tries.remove(message.id);
    return true;
  }

  // Anything else (an identity that can't be read, the record refusing a message) waits for the next round.
  Future<bool> handle(duvet.InboxMessage message) async {
    try {
      return await handleOne(message);
    } catch (error) {
      debugPrint('e2e: the inbox waits for its next round: $error');
      return false;
    }
  }

  String? after;
  while (true) {
    final page = await api.inbox(after: after);
    // A page that ends where this read began came again as it was (the server's word: the API's after is exclusive),
    // and would for good: the round ends, and the inbox is read again with the next.
    if (after != null && page.lastOrNull?.id == after) return rotated;
    String? handled;
    for (final message in page) {
      if (!await handle(message)) break;
      handled = message.id;
    }
    if (handled != null) await api.clearInbox(handled);
    if (page.length < _page || handled != page.lastOrNull?.id) return rotated;
    after = handled;
  }
}
