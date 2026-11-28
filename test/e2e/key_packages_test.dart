import 'dart:convert';

import 'package:duvet/e2e/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';
import '../support/fake_api.dart';

// A device's key packages (PLAN-E2E-CLIENTES.md, «Qué se manda», its key packages row): its core's whole live set goes
// up at start, every 24 h and on KEY_PACKAGES_LOW, and the API's answer names those it handed out already, which the
// core takes as spent once per upload the client started (Task 9b, api#356; Task 3b). The desktop's
// key-packages.test.ts, case for case.
const _upload = '/api/users/@me/devices/@me/key-packages';

bool _isUpload(http.Request request) => request.method == 'PUT' && request.url.path == _upload;

/// The IDs of each set a request uploaded, in order.
List<String> _ids(http.Request request) => [
  for (final kp in (jsonDecode(request.body) as Map)['key_packages'] as List) (kp as Map)['id'] as String,
];

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test('key_packages_go_up_at_start,_every_day_and_when_they_run_low', () async {
    final fake = FakeApi();
    final (ana, bo) = (fake.addUser(), fake.addUser());
    fake.addConversation(group: false, members: [ana, bo]);
    // Each session's uploads, by its token.
    final uploads = <String, List<List<String>>>{};
    final client = watchedClient(
      fake,
      seen: (request) {
        if (_isUpload(request)) (uploads[request.headers['authorization']!] ??= []).add(_ids(request));
      },
    );
    List<List<String>> of(TestDevice d) => uploads['Bearer ${d.token}'] ?? const [];
    final a = await firstDevice(fake, ana, client: client);
    expect(of(a), hasLength(1));
    expect(of(a).single, hasLength(101));

    a.clock.advance(const Duration(days: 1));
    await eventually(() => expect(of(a), hasLength(2)));

    // Bo's device claims Ana's until she has under 20 to hand out: she hears it, uploads, learns 81 were handed out,
    // and uploads once more what her core makes in their place.
    final b = await firstDevice(fake, bo, client: client);
    for (var n = 0; n < 81; n++) {
      await b.api.claimKeyPackages(ana);
    }
    await eventually(() => expect(of(a), hasLength(4)));
    final [_, _, low, renewed] = of(a);
    expect(low.where((id) => !renewed.contains(id)), hasLength(81));
    // That upload started nothing more: what's handed out of it, the next upload the client starts names.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(of(a), hasLength(4));
    await a.engine.stop();
    await b.engine.stop();
  }, skip: noCore);

  test('an_upload_the_client_started_takes_one_more_round_for_what_was_handed_out,_never_two', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final sets = <List<String>>[];
    final log = <String>[];
    // An API that always names the first key package of the set as handed out.
    final client = watchedClient(
      fake,
      change: (request, answered) async {
        if (!_isUpload(request)) return answered;
        final set = _ids(request);
        sets.add(set);
        return http.Response(
          jsonEncode({
            'handed_out': [set.first],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log), client: client);
    expect(sets, hasLength(2));
    // The second set has another in the first one's place.
    expect(sets[1], isNot(contains(sets[0].first)));
    expect(log.where((cmd) => cmd == 'key_packages'), hasLength(2));
    await a.engine.stop();
  }, skip: noCore);

  test('a_spent_list_the_core_refuses_goes_without_it', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    var answers = 0;
    // The API's first answer names more than the core takes (200 at most): too_large.
    final client = watchedClient(
      fake,
      change: (request, answered) async {
        if (!_isUpload(request) || answers++ > 0) return answered;
        return http.Response(
          jsonEncode({
            'handed_out': [for (var n = 0; n < 201; n++) base64Encode(utf8.encode('id $n'))],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    final commands = <Map<String, Object?>>[];
    final a = await firstDevice(
      fake,
      ana,
      host: WatchedHost(TestHost().gate, [], commands: commands),
      client: client,
    );
    // Asked with the 201, refused, then asked without them: and that set went up.
    expect(
      [for (final c in commands.where((c) => c['cmd'] == 'key_packages')) (c['spent'] as List?)?.length],
      [null, 201, null],
    );
    expect(answers, 2);
    expect(a.state, EngineState.ready);
    await a.engine.stop();
  }, skip: noCore);
}
