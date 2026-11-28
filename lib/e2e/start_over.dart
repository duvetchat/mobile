/// Starting over (PLAN-E2E-CLIENTES.md, Tasks 26 and 27; decision 47): a new device with neither the recovery key nor
/// another device makes a new identity for the user (reset_identity, which the core runs as it runs create_identity),
/// shows its recovery key until it's saved, and uploads it in the place of the identity the API serves, with `reset`
/// (identity.dart's publishIdentity): the devices before stay registered and off the new list, the user's contacts see
/// the identity change, and the identity before keeps its backup 30 days, in case its key turns up. Its conversations
/// take this device back once another member commits the removal of the devices before (sync.dart, `wait_rejoin`).
/// The desktop's start-over.ts in Dart.
library;

import 'engine.dart';
import 'identity.dart';
import 'store.dart';

/// The identity a start over under way replaces, as the record keeps it; null when none is under way.
String? replacedByReset(EngineStore store) => switch (store.read(keptReset)) {
  {'replaces': final String replaces} when replaces.isNotEmpty => replaces,
  _ => null,
};

/// The new identity, on the person's tap after the app's warning, in the place of [replaces]: kept in the record
/// first, so a start that finds the core's identity waiting for its upload knows it for a start over and not a first
/// device's (a record that can't keep it runs nothing). Run again before its upload, the core gives the same identity
/// and key.
Future<IdentityMade> makeReset(E2EEngine engine, String replaces) async {
  await engine.store.write(keptReset, {'replaces': replaces});
  return IdentityMade.of(await engine.host.handle<Map<String, Object?>>({'cmd': 'reset_identity'}));
}
