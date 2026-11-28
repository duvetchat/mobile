/// The core of the app's engine, the one main() runs (PLAN-E2E-CLIENTES.md, Android: the engine that has the core): it
/// opens the user's database and answers the other engines on the port. Imported only where dart:io is
/// (app_host_web.dart in its place on the web).
library;

import 'core_gate.dart';

CoreHost appCoreHost() => CoreGate(serves: true);

/// The core of a push's engine (lib/e2e/push_decrypt.dart): it asks the app's engine when one holds the core, and opens
/// it here only when none does, never making a database or a key, waiting for a locked one [lockedWait] at most.
CoreHost pushCoreHost([Duration lockedWait = const Duration(seconds: 10)]) =>
    CoreGate(serves: false, lockedWait: lockedWait);
