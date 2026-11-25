// The core the tests run on (PLAN-E2E-CLIENTES.md, Task 9): the vendored plugin's Linux build, which CI names in
// DUVET_E2E_LIB, or another build the variable names. Elsewhere (macOS, Windows, an arm64 Linux) there's no core,
// and the tests that need one are skipped.
import 'dart:ffi';
import 'dart:io';

import 'package:duvet_e2e/duvet_e2e.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// The library of the core, or null on a host with none.
final String? coreLibrary =
    Platform.environment['DUVET_E2E_LIB'] ??
    (Abi.current() == Abi.linuxX64 ? 'packages/duvet_e2e/linux-x64/libduvet_e2e.so' : null);

/// Why a test that needs the core is skipped here, or null when it runs.
final String? noCore = coreLibrary == null ? 'no core for this host: DUVET_E2E_LIB names one' : null;

/// Loads the core in this isolate, once, however many tests ask: an isolate that opens a database loads it for itself.
Future<void> loadCore() => _loaded ??= DuvetE2e.init(library: ExternalLibrary.open(coreLibrary!));
Future<void>? _loaded;
