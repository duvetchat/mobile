/// A device's commits (PLAN-E2E-CLIENTES.md, «Qué se manda», its commit rows): each goes to its route, and the core is
/// told the API's word on it, only once the API gave one (Review Focus 11). Taken (2xx) is `accepted`, with its number;
/// refused by the validator (422), `invalid`: it never entered. Any other refusal, another commit's epoch (409)
/// included, is `accepted: false`, which leaves the queue to settle it: the API may have taken it after all, as a
/// resend's answer (M1 of the desktop's review). A request without an answer says nothing: its caller keeps the bytes
/// and sends them again, and the API answers the same bytes as it did («Un commit sin respuesta»). The desktop's
/// commits.ts in Dart.
library;

import 'package:duvet_client/duvet.dart' as duvet;

import 'host.dart';

/// What came of a commit's request: taken; another took its epoch; refused (told not taken); refused by the
/// validator (told invalid); or no answer yet.
enum Sent { accepted, lost, refused, invalid, unanswered }

/// Answers that say nothing of the commit itself: a session's renewal, a timeout, a rate limit, the pause, the server.
bool _passing(int status) => status == 401 || status == 408 || status == 429 || status >= 500;

/// Sends a commit the core made ([send]: its request, always with the same bytes) and tells the core the API's word.
/// A client too old to send it (426) is thrown, the commit kept for after the update. Unanswered (a passing status, a
/// network error), the core is told nothing.
Future<Sent> sendCommit(CoreHost host, String conversationId, Future<duvet.CommitTaken> Function() send) async {
  final duvet.CommitTaken taken;
  try {
    taken = await send();
  } on duvet.DuvetUpdateRequiredException {
    rethrow;
  } on duvet.DuvetApiException catch (error) {
    final status = error.statusCode;
    if (_passing(status)) return Sent.unanswered;
    final invalid = status == 422;
    await host.handle<Object?>({
      'cmd': 'commit_result',
      'conversation_id': conversationId,
      'accepted': false,
      if (invalid) 'invalid': true,
    });
    return invalid
        ? Sent.invalid
        : status == 409
        ? Sent.lost
        : Sent.refused;
  } on Exception {
    // Nothing came back: a cut connection, a timeout.
    return Sent.unanswered;
  }
  await host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversationId,
    'accepted': true,
    'seq': taken.seq,
  });
  return Sent.accepted;
}
