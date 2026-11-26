/// What an engine sees of the core, whoever runs it (PLAN-E2E-CLIENTES.md, the core's host): what opening a database
/// comes to, the core's errors, and the calls an engine makes. core_gate.dart runs the core in the app; it needs
/// dart:io and isolates, which a web build doesn't have, so the engine and the app's code import this file alone.
library;

import 'dart:typed_data';

/// A file's parts as the core seals them: 64 KiB of the file each, and its 16-byte tag.
const attachmentPart = 65536;
const partTag = 16;

/// What opening a user's database came to: open; another engine has it ([HostState.locked]); no core for this
/// platform ([HostState.unsupported]); or it can't be opened, its key gone, say ([HostState.failed]).
enum HostState { ready, locked, unsupported, failed }

/// An open's [state], where its key is kept once ready, and why it failed: `bad_key` for a database no key opens
/// any more (its key gone, or another one there), which no other open gets past; null for a failure another open
/// may get past.
typedef Opened = ({HostState state, String? keyStorage, String? reason});

/// The calls an engine makes of the core, as the app's CoreGate runs them: a test can watch them, or fail one.
abstract interface class CoreHost {
  /// Opens [userId]'s database on this phone, or makes it.
  Future<Opened> open(String userId);

  /// Runs one command, and gives the reply's `ok`; throws a [CoreError] (its code and extra fields).
  Future<T> handle<T>(Map<String, Object?> command);

  /// Seals a whole file, part by part, so its bytes never go in one JSON; [progress] hears how many are done.
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int done)? progress});

  /// Opens a sealed file, part by part; [progress] hears how many of its bytes are done.
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int done)? progress});

  /// Closes what's open: the database stays.
  Future<void> close();

  /// Closes, then deletes [userId]'s database and its key.
  Future<void> destroy(String userId);
}

/// An error of the core, as the engine decides by it: its stable code, never its message, and what it names beside it.
class CoreError implements Exception {
  CoreError(
    this.code, {
    String? message,
    this.field,
    this.what,
    this.from,
    this.users,
    this.rule,
    this.kind,
    this.limit,
  }) : message = message == null || message.isEmpty ? code : message;

  /// The error of a core's reply, `{error: {code, message, ...}}`: its code, its message, and those of the fields it
  /// names that are what the core writes there.
  factory CoreError.of(Map<String, Object?> error) {
    String? text(String key) => switch (error[key]) {
      final String value => value,
      _ => null,
    };
    int? number(String key) => switch (error[key]) {
      final int value => value,
      _ => null,
    };
    return CoreError(
      text('code') ?? 'internal',
      message: text('message'),
      field: text('field'),
      what: text('what'),
      from: number('from'),
      users: switch (error['users']) {
        final List<Object?> users when users.every((user) => user is String) => users.cast<String>().toList(),
        _ => null,
      },
      rule: text('rule'),
      kind: text('kind'),
      limit: number('limit'),
    );
  }

  final String code;
  final String message;

  /// bad_command: the field of the command it refused.
  final String? field;

  /// not_found: what isn't there (a group, a message, a device...).
  final String? what;

  /// gap: the first number missing.
  final int? from;

  /// needs_identities: the users to observe before the command goes again.
  final List<String>? users;

  /// rule_violation: the rule.
  final String? rule;

  /// decrypt_failed: what didn't open.
  final String? kind;

  /// too_large: the limit passed.
  final int? limit;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'field': ?field,
    'what': ?what,
    'from': ?from,
    'users': ?users,
    'rule': ?rule,
    'kind': ?kind,
    'limit': ?limit,
  };

  @override
  String toString() => 'CoreError($code): $message';
}

/// A core's reply, as every host reads one: its `ok`, else its error thrown as a [CoreError]; anything else is
/// internal.
Object? replyOk(Object? reply) {
  if (reply is Map) {
    if (reply.containsKey('ok') && !reply.containsKey('error')) return reply['ok'];
    if (reply case {'error': final Map error} when !reply.containsKey('ok') && error['code'] is String) {
      throw CoreError.of(error.cast<String, Object?>());
    }
  }
  throw CoreError('internal', message: "the core's reply is neither ok nor an error");
}
