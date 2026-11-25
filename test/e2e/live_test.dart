// The live tests (PLAN-E2E-CLIENTES.md, Task 11): the app's code against a real API and gateway, which the API's suite
// clients-mobile starts and names: E2E_LIVE_API and E2E_LIVE_WS, its seeded accounts (E2E_LIVE_ACCOUNTS, JSON: each
// one's id and email) and their password (E2E_LIVE_PASSWORD). Outside that suite, as in the app's own run, they're
// skipped. Each engine task adds its cases here, on the core the app carries (packages/duvet_e2e).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';

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

/// A device of an account's on the stack, as the app runs one: a session saying what the app is, whose login's
/// challenge the engine keeps; a gateway identified with no device, then once more, as a new session, with the one
/// the engine registers (Ruling 30); and the engine, on a core of its own.
class _Live {
  _Live._(this.rest, this.host, this.readies);

  final duvet.RestClient rest;
  final TestHost host;

  /// The device each READY's identify named.
  final List<String?> readies;
  late final E2EEngine engine;
  String? device;
  duvet.GatewayManager? _gateway;
  StreamSubscription<duvet.GatewayEventPayload>? _heard;

  duvet.E2eApi get api => duvet.E2eApi(rest);

  static Future<_Live> start(ApiRouter router, ({String id, String email}) account) async {
    final rest = duvet.RestClient(http.Client(), router: router, duvetClient: duvetClient());
    final signedIn = await rest.logIn(account.email, _env['E2E_LIVE_PASSWORD'] ?? '');
    final live = _Live._(rest, TestHost(), []);
    final events = StreamController<duvet.GatewayEventPayload>.broadcast();
    String? named;
    Future<void> connect() async {
      await live._heard?.cancel();
      live._gateway?.destroy();
      // A client of the gateway's own: destroying the manager closes its client's, and the engine's goes on.
      final own = duvet.RestClient(
        http.Client(),
        router: router,
        token: rest.token,
        sessionToken: rest.sessionToken,
        duvetClient: rest.duvetClient,
      );
      final gateway = live._gateway = duvet.GatewayManager(
        own,
        router: router,
        platform: duvet.ClientPlatform.mobile,
        identifyDevice: () => named = live.device,
      );
      live._heard = gateway.onEvent.listen((event) {
        if (event is duvet.ReadyEvent) live.readies.add(named);
        events.add(event);
      });
      await gateway.connectAll();
    }

    await connect();
    live.engine = E2EEngine(
      host: live.host.gate,
      api: live.api,
      events: events.stream,
      store: MemoryStore(),
      clock: const SystemClock(),
      user: account.id,
      deviceName: 'Pixel 8 Pro',
      registered: (device) {
        live.device = device;
        if (named != device) unawaited(connect());
      },
      loginChallenge: switch (signedIn.deviceChallenge) {
        final challenge? => (challenge: challenge, at: DateTime.now()),
        null => null,
      },
    );
    addTearDown(() async {
      await live.engine.stop();
      await live._heard?.cancel();
      live._gateway?.destroy();
      await events.close();
      rest.client.close();
    });
    return live;
  }
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

  // The engine's start (PLAN-E2E-CLIENTES.md, Task 13): a first device, from its registration to its key packages.
  test(
    'a_device_registers,_binds_its_session,_publishes_its_identity_and_its_key_packages',
    () async {
      await loadCore();
      final router = _router();
      final (alice, bob) = (_account(0), _account(1));
      final a = await _Live.start(router, alice);
      await a.engine.start();
      expect(a.engine.state.value, const EngineState.firstDevice());
      final device = a.device!;
      expect(
        [for (final d in await a.api.devices()) (d.id, d.name, d.listed, d.current)],
        [(device, 'Pixel 8 Pro', false, true)],
      );

      await a.engine.makeIdentity();
      expect(shownKey(a.engine.state.value), recoveryKeyShape);
      await a.engine.keySaved();
      expect(a.engine.state.value, EngineState.ready);

      // The API has the identity the core made, with this device listed as its one device.
      final status = await a.host.gate.handle<Map<String, Object?>>({'cmd': 'status'});
      final identity = await a.api.identity(alice.id);
      expect((identity.identityKey, identity.deviceListVersion), (status['identity_key'], 1));
      expect(identity.certificates, [status['certificate']]);
      expect([for (final d in await a.api.devices()) (d.id, d.listed, d.current)], [(device, true, true)]);
      // The gateway took an identify naming the device, a new session's: it hands the device its own events.
      await eventually(() => expect(a.readies, contains(device)), timeout: const Duration(seconds: 15));

      // Its key packages went up (M2 of the desktop's review): Bob, set up too and now her friend, claims one for it.
      final b = await _Live.start(router, bob);
      await b.engine.start();
      await b.engine.makeIdentity();
      await b.engine.keySaved();
      expect(b.engine.state.value, EngineState.ready);
      final asked = await b.rest.sendFriendRequest(alice.id);
      await a.rest.acceptFriendRequest(asked.id);
      final claimed = await b.api.claimKeyPackages(alice.id);
      expect([for (final kp in claimed) kp.deviceId], [device]);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
