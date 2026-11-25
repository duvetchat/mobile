/// A call's notification's Decline (duvetchat/api#276): the app may not be running, and has no connection to the
/// gateway, which holds the calls, so the API declines it for the user.
library;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/duvet_repository.dart' show duvetRouter;
import '../data/links.dart' show isDuvetId;
import '../data/session_store.dart';
import '../e2e/client.dart';

/// Declines the call of [conversationId] that started at [startedAt] (Unix ms, as its ring gave it; 0, when the app put
/// the notification up not knowing it, is whatever call goes on there) for the user signed in on this phone, through
/// the API (`POST …/conversations/{id}/call/decline`), which declines it as the app's own CALL_DECLINE would: the
/// caller hears it, and the user's other devices stop ringing. It goes with the session [store] keeps, as it is: a
/// session that needs renewing first declines nothing, and the call rings out instead, as renewing here could race the
/// app's own.
Future<void> declineFromNotification(
  String conversationId, {
  required int startedAt,
  SessionStore store = const SecureSessionStore(),
  http.Client? client,
}) async {
  if (!isDuvetId(conversationId)) return;
  final saved = await store.read();
  if (saved == null) return;
  final httpClient = client ?? http.Client();
  try {
    final api = duvet.RestClient(
      httpClient,
      router: duvetRouter,
      duvetClient: duvetClient(),
      token: saved.token,
      sessionToken: saved.sessionToken,
    );
    await api.request(
      'POST',
      '/api/users/@me/conversations/$conversationId/call/decline',
      'decline a call',
      json: startedAt > 0 ? {'started_at': startedAt} : null,
      renew: false,
    );
  } catch (e) {
    debugPrint('push: declining the call: $e');
  } finally {
    if (client == null) httpClient.close();
  }
}
