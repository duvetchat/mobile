/// A device's key packages (PLAN-E2E-CLIENTES.md, «Qué se manda», its key packages row): the core's whole live set goes
/// up in place of the one the API keeps. The API's answer names those of the set it handed out already (handed_out),
/// which the core takes as spent, making others in their place; that second upload starts no third, as what it names
/// the answer to the next upload the client starts names again (Task 9b, api#356; Task 3b).
library;

import 'package:duvet_client/duvet.dart' as duvet;

import 'engine.dart';
import 'host.dart';

duvet.KeyPackageUpload _upload(Map<Object?, Object?> made) => duvet.KeyPackageUpload(
  id: made['id']! as String,
  data: made['data']! as String,
  expiresAt: made['expires_at']! as int,
  lastResort: made['last_resort'] == true,
);

/// The core's live set: with [spent], those it's told were handed out leave it, others in their place.
Future<List<duvet.KeyPackageUpload>> _liveSet(CoreHost host, [List<String>? spent]) async {
  try {
    final made = await host.handle<Map<String, Object?>>({'cmd': 'key_packages', 'spent': ?spent});
    return [for (final kp in made['key_packages']! as List<Object?>) _upload(kp! as Map<Object?, Object?>)];
  } on CoreError catch (error) {
    // A spent list the core refuses (more than 200 IDs, or IDs that don't read) goes without it.
    if (spent != null && (error.code == 'bad_command' || error.code == 'too_large')) return _liveSet(host);
    rethrow;
  }
}

/// An upload the client started: the set, then once more what the core makes in place of those handed out.
Future<void> uploadKeyPackages(E2EEngine engine) async {
  final handedOut = await engine.api.putKeyPackages(await _liveSet(engine.host));
  if (handedOut.isNotEmpty) await engine.api.putKeyPackages(await _liveSet(engine.host, handedOut));
}
