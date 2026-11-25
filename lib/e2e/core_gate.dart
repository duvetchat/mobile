/// The end-to-end encryption core in the app (PLAN-E2E-CLIENTES.md, the core's host and Android: the engine that has
/// the core), behind what every client's engine sees of it: open a user's database, run a command, seal and open a
/// file part by part, make and import a shared history, close, destroy.
///
/// One engine writes a database: the app's (the one main() runs), which opens it and answers the others on the port
/// named [corePortName], as answerRenewals does for the session (lib/push/renewal.dart). Another engine (a push's,
/// WorkManager's, audio_service's) asks the one that answers there, and opens the database itself only when no engine
/// answers, then closes it once its work is done. The core's lock settles a race: an open it refuses waits for the
/// port, or for the database to be free, [CoreGate.lockedWait] at most.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet_e2e/duvet_e2e.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'db_key.dart';

/// The name the app's engine answers the others under.
const corePortName = 'duvet-e2e-core';

/// What opening a user's database came to: open; another engine has it ([HostState.locked]); no core for this
/// platform ([HostState.unsupported]); or it can't be opened, its key gone, say ([HostState.failed]).
enum HostState { ready, locked, unsupported, failed }

typedef Opened = ({HostState state, String? keyStorage});

const _ready = (state: HostState.ready, keyStorage: 'provided');
const _failed = (state: HostState.failed, keyStorage: null);

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

/// The commands [CoreGate.handle] refuses: each has a way of its own, which keeps its bytes out of one JSON.
const ownWay = {'attachment_encrypt', 'attachment_decrypt', 'history_share', 'catch_up', 'history_import'};

/// A file's parts as the core seals them: 64 KiB of the file each, and its 16-byte tag.
const attachmentPart = 65536;
const partTag = 16;

/// The most parts [CoreGate.importShare] hands the core at once, which reads the whole command before it looks at
/// them.
const maxShareParts = 64;

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

// Bytes between engines: TransferableTypedData, the one kind of typed data the SDK promises between isolate groups,
// which another engine's isolate is in.
TransferableTypedData _transfer(Uint8List bytes) => TransferableTypedData.fromList([bytes]);
Uint8List _received(Object? bytes) => (bytes! as TransferableTypedData).materialize().asUint8List();

/// The app's engine didn't take a request in time, or ended before it answered.
class _Gone implements Exception {
  const _Gone();
}

/// The core of one engine: its own, or the one the app's engine has, through the port.
final class CoreGate {
  CoreGate({
    required this.serves,
    DbKeys keys = const DbKeys(),
    Future<Directory> Function()? folder,
    this.lockedWait = const Duration(seconds: 10),
    this.answerWait = const Duration(seconds: 5),
  }) : _keys = keys,
       _folder = folder ?? getApplicationSupportDirectory;

  /// Whether this is the app's engine: it opens the database itself and answers the others on [corePortName], and
  /// it alone makes a database and its key. Another engine asks the one that answers there.
  final bool serves;

  /// How long an open the core refuses as locked waits for the database to be free, or for an engine to answer on
  /// the port.
  final Duration lockedWait;

  /// How long the app's engine has to take a request: one that doesn't went away, though its name may have stayed.
  final Duration answerWait;

  final DbKeys _keys;

  /// The app's support folder: each user's database is `e2e/<user_id>/core.db` in it.
  final Future<Directory> Function() _folder;

  /// Whose database this engine uses, here or through the port; null once closed.
  String? _user;

  /// The core, while the database is open here.
  DuvetE2eCore? _core;

  /// The app's engine, while this one uses the database through it, and its isolate, whose end ends a request's wait.
  SendPort? _app;
  Isolate? _engine;

  /// The control port of the last engine that took a request of this one's.
  SendPort? _taker;

  /// What this engine answers the others on, while it does.
  ReceivePort? _port;

  /// The parts of each package [share] made here, until dropped.
  final _shares = <String, List<Uint8List>>{};

  static const _again = Duration(milliseconds: 100);

  // open, close and destroy run one at a time: two first opens at once would each make a key, and the one that lost
  // the key's write would hold the database.
  Future<void> _turn = Future.value();

  Future<T> _inTurn<T>(Future<T> Function() work) {
    final done = _turn.then((_) => work());
    _turn = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Opens [userId]'s database on this phone, or makes it (the app's engine only), closing what this engine had open.
  Future<Opened> open(String userId) async {
    if (!_uuid.hasMatch(userId)) throw CoreError('bad_command', message: "a user's ID is a UUID", field: 'user_id');
    return _inTurn(() => _open(userId));
  }

  Future<Opened> _open(String userId) async {
    await _close();
    final until = DateTime.now().add(lockedWait);
    SendPort? gone;
    while (true) {
      final app = serves ? null : IsolateNameServer.lookupPortByName(corePortName);
      if (app != null && app != gone) {
        try {
          final answer = jsonDecode((await _ask(app, 'open', userId))! as String) as Map<String, Object?>;
          final opened = (state: HostState.values.byName(answer['state']! as String), keyStorage: 'provided');
          if (opened.state != HostState.ready) return _failed;
          _app = app;
          _engine = Isolate(_taker!);
          _user = userId;
          return opened;
        } on _Gone {
          // Its engine ended, and its name stayed.
          gone = app;
        }
      }
      final opened = await _openHere(userId);
      if (opened.state == HostState.ready) {
        _user = userId;
        if (serves) _serve();
        return opened;
      }
      if (opened.state != HostState.locked || !DateTime.now().isBefore(until)) return opened;
      await Future<void>.delayed(_again);
    }
  }

  Future<String> _path(String userId) async => '${(await _folder()).path}/e2e/$userId/core.db';

  Future<Opened> _openHere(String userId) async {
    try {
      await DuvetE2e.init();
    } catch (error) {
      debugPrint('e2e: no core here: ${error.runtimeType}');
      return (state: HostState.unsupported, keyStorage: null);
    }
    final String path;
    final Uint8List? key;
    try {
      path = await _path(userId);
      final made = await File(path).exists();
      // The app's engine makes the key, and only for a database that isn't there yet: one whose key is gone opens
      // with no other. Another engine opens only a database there is.
      key = serves && !made ? await _keys.readOrMake(userId) : (made ? await _keys.read(userId) : null);
      if (key == null) {
        debugPrint(made ? "e2e: the database's key is gone" : 'e2e: no database yet');
        return _failed;
      }
      await File(path).parent.create(recursive: true);
    } catch (error) {
      debugPrint("e2e: the database's key or folder: ${error.runtimeType}");
      return _failed;
    }
    try {
      _core = await DuvetE2e.open(jsonEncode({'path': path}), key);
      return _ready;
    } on DuvetE2eException catch (error) {
      if (error.code == 'locked') return (state: HostState.locked, keyStorage: null);
      debugPrint('e2e: the database refused to open: ${error.code}');
      return _failed;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The port: the app's engine answers, another engine asks.

  void _serve() {
    final port = _port = ReceivePort();
    IsolateNameServer.removePortNameMapping(corePortName);
    IsolateNameServer.registerPortWithName(port.sendPort, corePortName);
    port.listen(_answer);
  }

  void _stopServing() {
    final port = _port;
    if (port == null) return;
    _port = null;
    // Only its own name: another engine may answer under it since.
    if (IsolateNameServer.lookupPortByName(corePortName) == port.sendPort) {
      IsolateNameServer.removePortNameMapping(corePortName);
    }
    port.close();
  }

  // A request is [reply, op, user, args]. Its asker hears it's taken, with this isolate's control port (its end ends
  // the asker's wait), then its progress, then its answer: [ok, value] or [error, the CoreError's JSON].
  Future<void> _answer(Object? request) async {
    if (request case [final SendPort reply, final String op, final String user, final List<Object?> args]) {
      reply.send(['taken', Isolate.current.controlPort]);
      try {
        reply.send([
          'ok',
          await _answerOp(op, user, args, (done) => reply.send(['progress', done])),
        ]);
      } on CoreError catch (error) {
        reply.send(['error', jsonEncode(error.toJson())]);
      } catch (error) {
        reply.send(['error', jsonEncode(CoreError('internal', message: '$error').toJson())]);
      }
    }
  }

  // What crosses between engines: text, numbers and bytes; anything structured as its JSON.
  Future<Object?> _answerOp(String op, String user, List<Object?> args, void Function(int) progress) async {
    // Only the database this engine has open: another user's gets nothing of it.
    if (op == 'open') {
      return jsonEncode({'state': user == _user && _core != null ? 'ready' : 'failed'});
    }
    if (user != _user || _core == null) throw CoreError('internal', message: 'no core is open for that user');
    switch (op) {
      case 'handle':
        return jsonEncode(await handle<Object?>(jsonDecode(args[0]! as String) as Map<String, Object?>));
      case 'sealFile':
        return _transfer(
          await sealFile(args[0]! as String, args[1]! as String, _received(args[2]), progress: progress),
        );
      case 'openFile':
        return _transfer(
          await openFile(args[0]! as String, args[1]! as String, _received(args[2]), progress: progress),
        );
      case 'share':
        return jsonEncode(await share(jsonDecode(args[0]! as String) as Map<String, Object?>));
      case 'sharePart':
        return _transfer(await sharePart(args[0]! as String, args[1]! as int));
      case 'dropShare':
        await dropShare(args[0]! as String);
        return null;
      case 'importShare':
        final parts = [for (final part in args[1]! as List) _received(part)];
        return jsonEncode(await importShare(args[0]! as String, parts));
      case 'destroy':
        await destroy(user);
        return null;
    }
    throw CoreError('bad_command', message: 'no such op: $op', field: 'op');
  }

  /// Asks the app's engine; throws [_Gone] when it doesn't take the request in time, or ends before it answers.
  Future<Object?> _ask(
    SendPort app,
    String op,
    String user, [
    List<Object?> args = const [],
    void Function(int)? progress,
  ]) async {
    final answers = ReceivePort();
    final replies = StreamIterator<Object?>(answers);
    // Its engine's end ends the wait. Listened for before the request goes, as an isolate that has ended sends no exit
    // message: an end right after it took the request isn't missed. The open that first finds the engine, which
    // answers at once, waits for each reply as for the taking.
    final engine = _engine;
    engine?.addOnExitListener(answers.sendPort, response: const ['gone']);
    Future<bool> next() =>
        engine == null ? replies.moveNext().timeout(answerWait, onTimeout: () => false) : replies.moveNext();
    try {
      app.send([answers.sendPort, op, user, args]);
      if (!await replies.moveNext().timeout(answerWait, onTimeout: () => false)) throw const _Gone();
      if (replies.current case ['taken', final SendPort control]) _taker = control;
      while (await next()) {
        switch (replies.current) {
          case ['progress', final int done]:
            progress?.call(done);
          case ['ok', final value]:
            return value;
          case ['error', final String error]:
            throw CoreError.of(jsonDecode(error) as Map<String, Object?>);
          case ['gone']:
            throw const _Gone();
        }
      }
      throw const _Gone();
    } finally {
      engine?.removeOnExitListener(answers.sendPort);
      await replies.cancel();
      answers.close();
    }
  }

  /// Runs [here] on this engine's core, or [there] through the app's engine. A call whose engine went away is
  /// internal, and the next one opens the database again first, as every client's host does after a cut call.
  Future<Object?> _either(
    Future<Object?> Function() here,
    Future<Object?> Function(SendPort app, String user) there,
  ) async {
    final user = _user;
    if (user == null) throw CoreError('internal', message: 'no core is open');
    if (_core == null && _app == null) {
      final opened = await open(user);
      if (opened.state != HostState.ready) {
        // The next call tries again.
        _user = user;
        throw CoreError('internal', message: "the core didn't open again: ${opened.state.name}");
      }
    }
    if (_core != null) return here();
    try {
      return await there(_app!, user);
    } on _Gone {
      _app = null;
      _engine = null;
      throw CoreError('internal', message: "the app's engine went away");
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // What the engine sees of the core.

  /// Runs one command, and gives the reply's `ok`; throws a [CoreError] (its code and extra fields).
  Future<T> handle<T>(Map<String, Object?> command) async {
    final cmd = command['cmd'];
    if (ownWay.contains(cmd)) {
      throw CoreError('bad_command', message: '$cmd has a way of its own', field: 'cmd');
    }
    return await _either(
          () => _run(command),
          (app, user) async => jsonDecode((await _ask(app, 'handle', user, [jsonEncode(command)]))! as String),
        )
        as T;
  }

  Future<Object?> _run(Map<String, Object?> command) async {
    final core = _core;
    if (core == null) throw CoreError('internal', message: 'no core is open');
    final String reply;
    try {
      reply = await core.handle(jsonEncode(command));
    } catch (error) {
      // A panic of the core, whose command rolled back.
      throw CoreError('internal', message: '$error');
    }
    // Closed while it answered (this engine closed, switched account or destroyed): the core's not_found would read as
    // a missing group or nothing pending.
    if (!identical(_core, core)) throw CoreError('internal', message: 'the core closed while it answered');
    final Object? answer;
    try {
      answer = jsonDecode(reply);
    } on FormatException {
      throw CoreError('internal', message: "the core's reply isn't JSON");
    }
    return replyOk(answer);
  }

  /// Seals a whole file, part by part, so its bytes never go in one JSON; [progress] hears how many are done.
  Future<Uint8List> sealFile(
    String key,
    String attachmentId,
    Uint8List plain, {
    void Function(int done)? progress,
  }) async =>
      await _either(
            () => _parts('attachment_encrypt', key, attachmentId, plain, attachmentPart, progress),
            (app, user) async =>
                _received(await _ask(app, 'sealFile', user, [key, attachmentId, _transfer(plain)], progress)),
          )
          as Uint8List;

  /// Opens a sealed file, part by part; [progress] hears how many of its bytes are done.
  Future<Uint8List> openFile(
    String key,
    String attachmentId,
    Uint8List sealed, {
    void Function(int done)? progress,
  }) async =>
      await _either(
            () => _parts('attachment_decrypt', key, attachmentId, sealed, attachmentPart + partTag, progress),
            (app, user) async =>
                _received(await _ask(app, 'openFile', user, [key, attachmentId, _transfer(sealed)], progress)),
          )
          as Uint8List;

  /// A file through the core a part at a time, [size] bytes of it each, the last one marked: an empty file is one.
  Future<Uint8List> _parts(
    String cmd,
    String key,
    String id,
    Uint8List bytes,
    int size,
    void Function(int)? progress,
  ) async {
    final count = max(1, (bytes.length + size - 1) ~/ size);
    final done = BytesBuilder(copy: false);
    for (var index = 0; index < count; index++) {
      final part = Uint8List.sublistView(bytes, index * size, min(bytes.length, (index + 1) * size));
      final made = await _run({
        'cmd': cmd,
        'key': key,
        'attachment_id': id,
        'index': index,
        'last': index == count - 1,
        'data': base64Encode(part),
      });
      done.add(base64Decode((made! as Map)['data']! as String));
      progress?.call(min(bytes.length, (index + 1) * size));
    }
    return done.takeBytes();
  }

  /// `history_share` or `catch_up`: its reply with its parts counted, as `parts`, which stay in the engine that made
  /// them until dropped.
  Future<Map<String, Object?>> share(Map<String, Object?> command) async {
    if (command['cmd'] != 'history_share' && command['cmd'] != 'catch_up') {
      throw CoreError('bad_command', message: 'share makes a history_share or a catch_up', field: 'cmd');
    }
    final made = await _either(() async {
      final made = (await _run(command))! as Map<String, Object?>;
      final parts = [for (final part in made['parts']! as List) base64Decode(part as String)];
      _shares[made['share_id']! as String] = parts;
      return {...made, 'parts': parts.length};
    }, (app, user) async => jsonDecode((await _ask(app, 'share', user, [jsonEncode(command)]))! as String));
    return (made! as Map).cast<String, Object?>();
  }

  /// A package's part [n], as [share] made it.
  Future<Uint8List> sharePart(String shareId, int n) async =>
      await _either(() async {
            final parts = _shares[shareId];
            if (parts == null || n < 0 || n >= parts.length) {
              throw CoreError('not_found', message: 'this engine keeps no such part', what: 'share');
            }
            return parts[n];
          }, (app, user) async => _received(await _ask(app, 'sharePart', user, [shareId, n])))
          as Uint8List;

  /// Lets a package's parts go.
  Future<void> dropShare(String shareId) async {
    await _either(() async => _shares.remove(shareId), (app, user) => _ask(app, 'dropShare', user, [shareId]));
  }

  /// `history_import`, with the parts handed in: [maxShareParts] at most.
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) async {
    if (parts.length > maxShareParts) {
      throw CoreError('too_large', message: 'a package has $maxShareParts parts at most', limit: maxShareParts);
    }
    final imported = await _either(
      () => _run({
        'cmd': 'history_import',
        'share_id': shareId,
        'parts': [for (final part in parts) base64Encode(part)],
      }),
      (app, user) async => jsonDecode(
        (await _ask(app, 'importShare', user, [
              shareId,
              [for (final part in parts) _transfer(part)],
            ]))!
            as String,
      ),
    );
    return (imported! as Map).cast<String, Object?>();
  }

  /// Closes what this engine has open: the database, or its use of the app's engine's, which stays open there.
  Future<void> close() => _inTurn(_close);

  Future<void> _close() async {
    _user = null;
    _app = null;
    _engine = null;
    _shares.clear();
    _stopServing();
    final core = _core;
    _core = null;
    await core?.close();
  }

  /// Closes, then deletes [userId]'s database and its key: what «Remove this device and delete its data» does. The
  /// database is taken first, here or by the app's engine, so no engine has it open while it goes: one that's locked
  /// is refused. One no key opens is deleted all the same, as nothing can read it. The core's lock file stays, empty,
  /// as the core's own destroy leaves it: an open racing this one takes the same lock.
  Future<void> destroy(String userId) async {
    if (!_uuid.hasMatch(userId)) throw CoreError('bad_command', message: "a user's ID is a UUID", field: 'user_id');
    return _inTurn(() => _destroy(userId));
  }

  Future<void> _destroy(String userId) async {
    if (_user != userId || (_core == null && _app == null)) {
      if ((await _open(userId)).state == HostState.locked) {
        throw CoreError('locked', message: 'another engine has the database open');
      }
    }
    if (_app case final app? when _core == null) {
      try {
        await _ask(app, 'destroy', userId);
      } on _Gone {
        throw CoreError('internal', message: "the app's engine went away");
      } finally {
        await _close();
      }
      return;
    }
    // Closed with the port still answering, so another engine asks, and finds no core, rather than opening it.
    final core = _core;
    _core = null;
    await core?.close();
    final path = await _path(userId);
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
    await _keys.delete(userId);
    await _close();
  }
}
