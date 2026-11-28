/// What a TLS failure is, where dart:io is (tls_web.dart in its place on the web).
library;

import 'dart:io';

/// A TLS handshake or certificate that failed (a wrong clock, a network that inspects TLS): no answer came, and
/// IOClient passes it on as it is, where it wraps a socket's failure in a ClientException.
bool tlsFailed(Object error) => error is TlsException;
