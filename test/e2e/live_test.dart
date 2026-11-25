// The live tests (PLAN-E2E-CLIENTES.md, Task 11): the app's code against a real API and gateway, which the API's suite
// clients-mobile starts and names: E2E_LIVE_API and E2E_LIVE_WS, its seeded accounts (E2E_LIVE_ACCOUNTS, JSON: each
// one's id and email) and their password (E2E_LIVE_PASSWORD). Outside that suite, as in the app's own run, they're
// skipped. Each engine task adds its cases here, on the core the app carries (packages/duvet_e2e).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _env = Platform.environment;

/// The stack's API and gateway, as the app's router names them.
ApiRouter _router() {
  final api = Uri.parse(_env['E2E_LIVE_API']!);
  return ApiRouter(api: api.authority, ws: Uri.parse(_env['E2E_LIVE_WS']!).authority, secure: api.scheme == 'https');
}

/// The stack's nth seeded account.
({String id, String email}) _account(int n) {
  final account = (jsonDecode(_env['E2E_LIVE_ACCOUNTS'] ?? '[]') as List<dynamic>)[n] as Map<String, dynamic>;
  return (id: account['id'] as String, email: account['email'] as String);
}

void main() {
  final skip = _env['E2E_LIVE_API'] == null ? "only against a stack, in the API's clients-mobile suite" : null;

  test(
    'the client reaches the stack',
    () async {
      final router = _router();
      final alice = _account(0);
      final rest = duvet.RestClient(http.Client(), router: router);
      await rest.logIn(alice.email, _env['E2E_LIVE_PASSWORD'] ?? '');
      final gateway = duvet.GatewayManager(rest, router: router, platform: duvet.ClientPlatform.mobile);
      addTearDown(gateway.destroy);
      // Before connecting: READY comes right after the identify, on a broadcast stream.
      final ready = gateway.ready;
      await gateway.connectAll();
      expect((await ready.timeout(const Duration(seconds: 15))).user.id, alice.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
