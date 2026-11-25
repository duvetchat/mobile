/// The core of the app's engine, the one main() runs (PLAN-E2E-CLIENTES.md, Android: the engine that has the core): it
/// opens the user's database and answers the other engines on the port. Imported only where dart:io is
/// (app_host_web.dart in its place on the web).
library;

import 'core_gate.dart';

CoreHost appCoreHost() => CoreGate(serves: true);
