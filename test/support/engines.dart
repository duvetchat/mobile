// Engines on the fake API, for the engine's tests (PLAN-E2E-CLIENTES.md, «El motor»): each one a device of a user, with
// its own core (a CoreGate on a folder and keys of its own), session, gateway connection, record and clock, so a test
// runs as many as it needs in one process. The desktop's testing/engines.ts in Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/db_key.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_api.dart';

/// What the engines' requests say the app is (X-Duvet-Client): the app on Android, whatever a test's platform.
final engineClient = duvetClient(platform: TargetPlatform.android);

/// What a device's page draws of a conversation ([E2EEngine.shown]): the fake's honest drawing unless a test gives one.
typedef PageDrawing = Future<ShownConversation?> Function(String conversationId, {required bool fresh});

/// What the app's chats draw of [me]'s conversations, as its repository keeps it (its _drawnConversation): the last
/// listing [list] gave, made again for a fresh read or before the first, one that fails after a first leaving it. The
/// engines on a real stack get it, which a listing at every look would take past the API's rate limit.
PageDrawing listedDrawing(Future<List<duvet.Conversation>> Function() list, String me) {
  Map<String, ShownConversation>? kept;
  return (conversationId, {required fresh}) async {
    if (fresh || kept == null) {
      try {
        kept = {
          for (final conv in await list())
            if (conv.deletedAt == null) conv.id: drawnOf(conv, me),
        };
      } catch (error) {
        if (kept == null) rethrow;
      }
    }
    return kept?[conversationId];
  };
}

/// The fake API, as the app's router names it.
const fakeRouter = ApiRouter(api: 'fake-api.test');

/// A clock a test moves on by hand: what's due runs as it passes, in order. Its time is the wall clock's, ahead by
/// what the test moved it on, as the desktop's: the API's own times (an inbox message's) are the wall clock's.
class TestClock implements EngineClock {
  var _now = Duration.zero;
  final _timers = <({Duration at, void Function() run})>{};

  @override
  DateTime now() => DateTime.now().add(_now);

  @override
  void Function() later(Duration wait, void Function() run) {
    final timer = (at: _now + wait, run: run);
    _timers.add(timer);
    return () => _timers.remove(timer);
  }

  /// Time moves on by [by].
  void advance(Duration by) {
    final end = _now + by;
    while (true) {
      final due = _timers.where((t) => t.at <= end).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      _timers.remove(due.first);
      _now = due.first.at;
      due.first.run();
    }
    _now = end;
  }
}

/// A record in memory, one for each device, kept as JSON as the app's file keeps it.
class MemoryStore implements EngineStore {
  final _values = <String, String>{};

  /// Everything kept, by key, as JSON.
  Map<String, String> get kept => Map.unmodifiable(_values);

  @override
  Object? read(String key) => switch (_values[key]) {
    final kept? => jsonDecode(kept),
    null => null,
  };

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = jsonEncode(value);
    }
  }

  @override
  Future<void> update(String key, Object? Function(Object? kept) change) => write(key, change(read(key)));

  @override
  Future<void> refresh(List<String> keys) async {}
}

/// A record that keeps nothing: every write fails, as a full disk's would.
class RefusingStore implements EngineStore {
  @override
  Object? read(String key) => null;

  @override
  Future<void> write(String key, Object? value) async => throw const FileSystemException('the disk is full');

  @override
  Future<void> update(String key, Object? Function(Object? kept) change) => write(key, change(read(key)));

  @override
  Future<void> refresh(List<String> keys) async {}
}

final _random = Random.secure();

/// The keys of one device's databases, in memory: two devices of one user in a process keep theirs apart, as two
/// phones would. Each read is a copy, as the gate wipes the one it's handed.
class MemoryKeys implements DbKeys {
  MemoryKeys([Map<String, Uint8List>? keys]) : _keys = keys ?? {};
  final Map<String, Uint8List> _keys;

  @override
  Future<Uint8List?> read(String userId) async => switch (_keys[userId]) {
    final key? => Uint8List.fromList(key),
    null => null,
  };

  @override
  Future<Uint8List> readOrMake(String userId) async =>
      Uint8List.fromList(_keys[userId] ??= Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256))));

  @override
  Future<void> delete(String userId) async => _keys.remove(userId);

  /// The key kept for [userId], as it is.
  Uint8List? keyOf(String userId) => _keys[userId];
}

/// A device's core: the app's gate, on a folder of its own (deleted after the test) and with its own keys, which the
/// same folder and keys open again after a restart.
class TestHost {
  TestHost({Directory? folder, MemoryKeys? keys, Duration lockedWait = const Duration(milliseconds: 300)})
    : folder = folder ?? _folder(),
      keys = keys ?? MemoryKeys() {
    gate = CoreGate(serves: true, keys: this.keys, folder: () async => this.folder, lockedWait: lockedWait);
  }

  final Directory folder;
  final MemoryKeys keys;
  late final CoreGate gate;

  static Directory _folder() {
    final folder = Directory.systemTemp.createTempSync('duvet-engine-');
    addTearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });
    return folder;
  }
}

/// A record in memory whose storage refuses [key], as a full disk's would: the write fails, and nothing is kept.
class KeyRefusingStore extends MemoryStore {
  KeyRefusingStore(this.key);
  final String key;

  @override
  Future<void> write(String key, Object? value) async {
    if (key == this.key) throw const FileSystemException('the disk is full');
    await super.write(key, value);
  }
}

/// A host whose first open finds the database locked, as another engine holds it: the core opens after.
class LockedOnce implements CoreHost, ObservingHost {
  LockedOnce(this._host);
  final CoreHost _host;
  var _locked = true;

  @override
  set onObserved(ObservedListener? listener) {
    if (_host case final ObservingHost observing) observing.onObserved = listener;
  }

  @override
  Future<Opened> open(String userId) async {
    if (!_locked) return _host.open(userId);
    _locked = false;
    return (state: HostState.locked, keyStorage: null, reason: null);
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) => _host.handle<T>(command);

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      _host.sealFile(key, attachmentId, plain, progress: progress);

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      _host.openFile(key, attachmentId, sealed, progress: progress);

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) => _host.share(command);

  @override
  Future<Uint8List> sharePart(String shareId, int n) => _host.sharePart(shareId, n);

  @override
  Future<void> dropShare(String shareId) => _host.dropShare(shareId);

  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) => _host.importShare(shareId, parts);

  @override
  Future<void> close() => _host.close();

  @override
  Future<void> destroy(String userId) => _host.destroy(userId);
}

/// A host that tells what it's asked (each command's name, in order, and the commands themselves), holds a command
/// until the future [hold] gives for it completes, fails one when [fail] gives an error for it, and answers one itself
/// when [answer] gives an answer. Its core's observations go to the engine's contacts as the core it wraps tells them:
/// an observe_user it answers itself isn't the core's, and tells nothing.
class WatchedHost implements CoreHost, ObservingHost {
  WatchedHost(this._host, this.log, {this.hold, this.fail, this.answer, List<Map<String, Object?>>? commands})
    : commands = commands ?? [];

  @override
  set onObserved(ObservedListener? listener) {
    if (_host case final ObservingHost observing) observing.onObserved = listener;
  }

  final CoreHost _host;
  final List<String> log;
  final List<Map<String, Object?>> commands;
  final Future<void>? Function(Map<String, Object?> command)? hold;
  final CoreError? Function(Map<String, Object?> command)? fail;
  final Object? Function(Map<String, Object?> command)? answer;

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    log.add(command['cmd']! as String);
    commands.add(command);
    if (hold?.call(command) case final wait?) await wait;
    if (fail?.call(command) case final error?) throw error;
    if (answer?.call(command) case final answered?) return answered as T;
    return _host.handle<T>(command);
  }

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      _host.sealFile(key, attachmentId, plain, progress: progress);

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      _host.openFile(key, attachmentId, sealed, progress: progress);

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) {
    log.add(command['cmd']! as String);
    commands.add(command);
    return _host.share(command);
  }

  @override
  Future<Uint8List> sharePart(String shareId, int n) => _host.sharePart(shareId, n);

  @override
  Future<void> dropShare(String shareId) => _host.dropShare(shareId);

  /// Told as `history_import` with its `share_id`, and failed as [fail] says for that command.
  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) async {
    final command = {'cmd': 'history_import', 'share_id': shareId};
    log.add('history_import');
    commands.add(command);
    if (fail?.call(command) case final error?) throw error;
    return _host.importShare(shareId, parts);
  }

  @override
  Future<Opened> open(String userId) => _host.open(userId);

  @override
  Future<void> close() => _host.close();

  @override
  Future<void> destroy(String userId) => _host.destroy(userId);
}

/// An http client on the fake that tells [seen] of each request first, and can answer one itself ([answer]: null
/// passes it on) or change the fake's answer ([change]). A request aborted while [answer] holds it never reaches the
/// fake, as a real client's never reaches the API (task 19's review, M10).
http.Client watchedClient(
  FakeApi fake, {
  void Function(http.Request request)? seen,
  Future<http.Response?> Function(http.Request request)? answer,
  Future<http.Response> Function(http.Request request, http.Response answered)? change,
}) => MockClient.streaming((sent, body) async {
  final request = http.Request(sent.method, sent.url)
    ..headers.addAll(sent.headers)
    ..bodyBytes = await body.toBytes();
  var aborted = false;
  if (sent case http.Abortable(:final abortTrigger?)) {
    unawaited(abortTrigger.then((_) => aborted = true, onError: (Object _) => aborted = true));
  }
  seen?.call(request);
  var answered = await answer?.call(request);
  if (aborted) throw http.RequestAbortedException(sent.url);
  if (answered == null) {
    answered = await http.Response.fromStream(await fake.client.send(request));
    if (change != null) answered = await change(request, answered);
  }
  return http.StreamedResponse(
    http.ByteStream.fromBytes(answered.bodyBytes),
    answered.statusCode,
    headers: answered.headers,
    reasonPhrase: answered.reasonPhrase,
    request: sent,
  );
});

/// A gateway event as the app's gateway client hands it on: the fake's READY with what duvet_client reads of it.
duvet.GatewayEventPayload? payloadOf(GatewayEvent event, String user) {
  var data = event.data;
  if (event.type == 'READY') {
    final at = DateTime.now().toUtc().toIso8601String();
    data = {
      ...(data! as Map).cast<String, Object?>(),
      'sessionToken': '',
      'user': {'id': user, 'username': 'someone', 'created_at': at, 'updated_at': at},
    };
  }
  try {
    return duvet.GatewayEnvelope.fromJson({
      'op': 1,
      's': 0,
      'event': 'payload',
      'd': {'type': event.type, 'data': data},
    }).d;
  } catch (_) {
    // One of the fake's events duvet_client reads otherwise: none the engine hears.
    return null;
  }
}

class TestDevice {
  TestDevice._(
    this.engine,
    this.host,
    this.user,
    this.token,
    this.api,
    this.store,
    this.clock,
    this.heard,
    this.registered,
    this.states,
    this.backups,
    this.connect,
  );

  final E2EEngine engine;
  final CoreHost host;
  final String user;
  final String token;

  /// The routes, for this device's session.
  final duvet.E2eApi api;
  final EngineStore store;
  final TestClock clock;

  /// What its connection to the gateway heard.
  final List<GatewayEvent> heard;

  /// Each device the engine said it registered or bound this session to.
  final List<String> registered;

  /// States the engine went through.
  final List<EngineState> states;

  /// What the engine showed of the encrypted backup, each time it changed.
  final List<BackupShown> backups;

  /// Connects to the gateway again, identified with `device`: its READY comes first.
  final void Function(String? device) connect;

  EngineState get state => engine.state.value;
}

/// A device of [user]'s on the fake: an engine with its core ([host], a new one unless given), a session of its own (a
/// sign-in's, whose challenge the engine keeps as the app keeps the login's, unless [token] names one), its record and
/// its clock. It connects to the gateway with no device, then again with the one the engine registers, as the app's
/// one reopen does (Ruling 30). Its page draws what [drawn] gives, else what the fake lists the user now.
TestDevice testDevice(
  FakeApi fake,
  String user, {
  CoreHost? host,
  EngineStore? store,
  String? token,
  http.Client? client,
  bool Function(GatewayEvent event)? hears,
  DateTime? challengedAt,
  double Function()? random,
  PageDrawing? drawn,
}) {
  final signedIn = token == null ? fake.signIn(user) : null;
  final session = token ?? signedIn!.token;
  final core = host ?? TestHost().gate;
  final record = store ?? MemoryStore();
  final clock = TestClock();
  final events = StreamController<duvet.GatewayEventPayload>.broadcast();
  addTearDown(events.close);
  final heard = <GatewayEvent>[];
  final registered = <String>[];
  void Function() end = () {};
  void connect(String? device) {
    end();
    end = fake.connect(session, device, (event) {
      heard.add(event);
      if (hears != null && !hears(event)) return;
      if (payloadOf(event, user) case final payload?) events.add(payload);
    });
  }

  addTearDown(() => end());
  final api = duvet.E2eApi(
    duvet.RestClient(client ?? fake.client, router: fakeRouter, token: session, duvetClient: engineClient),
  );
  final engine = E2EEngine(
    host: core,
    api: api,
    events: events.stream,
    store: record,
    clock: clock,
    user: user,
    deviceName: 'Pixel 8 Pro',
    registered: (device) {
      registered.add(device);
      if (device != (registered.length > 1 ? registered[registered.length - 2] : null)) connect(device);
    },
    loginChallenge: signedIn == null ? null : (challenge: signedIn.deviceChallenge, at: challengedAt ?? DateTime.now()),
    random: random ?? () => 0.5,
    shown: drawn ?? fake.drawnTo(user),
  );
  // Stopped, its core closed, before its core's folder is deleted (teardowns run last first): a turn still writing
  // there failed that deletion now and then (ENOTEMPTY on macOS). A stop that hangs fails the test, naming the turn.
  addTearDown(() => engine.stop().timeout(const Duration(seconds: 10)));
  final states = <EngineState>[];
  engine.state.addListener(() => states.add(engine.state.value));
  final backups = <BackupShown>[];
  engine.backup.addListener(() => backups.add(engine.backup.value));
  connect(null);
  shownWhenStuck(() => heldBy(fake, user, engine.state.value, engine.conversations.value, core));
  return TestDevice._(engine, core, user, session, api, record, clock, heard, registered, states, backups, connect);
}

/// A device through the first device's flow: its identity made, its key saved, both published; the engine ready.
Future<TestDevice> firstDevice(
  FakeApi fake,
  String user, {
  CoreHost? host,
  EngineStore? store,
  http.Client? client,
  bool Function(GatewayEvent event)? hears,
  PageDrawing? drawn,
}) async {
  final device = testDevice(fake, user, host: host, store: store, client: client, hears: hears, drawn: drawn);
  await device.engine.start();
  await device.engine.makeIdentity();
  await device.engine.keySaved();
  if (device.state != EngineState.ready) throw StateError('the first device ended ${device.state}');
  return device;
}

/// The recovery key a first device's state shows, or null.
String? shownKey(EngineState state) => state.stage == EngineStage.firstDevice ? state.recoveryKey : null;

/// The group as a device's core holds it (the core's `group`): its devices by user and ID.
typedef HeldGroup = ({
  int generation,
  int epoch,
  String authenticator,
  bool blocked,
  List<({String user, String device})> devices,
});

/// The conversation's group as the device's core holds it, or null without one.
Future<HeldGroup?> groupOf(TestDevice device, String conversation) async {
  final Map<String, Object?> held;
  try {
    held = await device.host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversation});
  } on CoreError {
    return null;
  }
  return (
    generation: held['generation']! as int,
    epoch: held['epoch']! as int,
    authenticator: held['authenticator']! as String,
    blocked: held['blocked'] == true,
    devices: [
      for (final d in (held['devices']! as List).cast<Map<String, Object?>>())
        (user: d['user_id']! as String, device: d['device_id']! as String),
    ],
  );
}

/// Waits until every device holds the conversation's group at one generation and epoch, with one authenticator.
Future<HeldGroup> sameGroup(List<TestDevice> devices, String conversation, {Duration? timeout}) async {
  late HeldGroup held;
  await until(
    () async {
      final groups = [for (final device in devices) await groupOf(device, conversation)];
      final first = groups.first;
      if (first == null) return false;
      held = first;
      return groups.every(
        (g) =>
            g != null &&
            (g.generation, g.epoch, g.authenticator) == (first.generation, first.epoch, first.authenticator),
      );
    },
    timeout: timeout,
    what: 'one group, at one generation and epoch, on every device',
  );
  return held;
}

/// How long a test waits for what an engine does in its own time: a minute, or E2E_WAIT_SECONDS.
final _wait = Duration(seconds: int.tryParse(Platform.environment['E2E_WAIT_SECONDS'] ?? '') ?? 60);

/// What each device the running test made holds, which a wait that gives up tells.
final _shown = <Future<String> Function()>[];

/// [describe] tells what one of the running test's devices holds, when a wait gives up ([until]).
void shownWhenStuck(Future<String> Function() describe) {
  _shown.add(describe);
  addTearDown(() => _shown.remove(describe));
}

/// What a device holds, as a wait that gave up tells it: its engine's state, then for each conversation of the fake,
/// the group its core holds and what the conversation says.
Future<String> heldBy(
  FakeApi fake,
  String who,
  EngineState state,
  Map<String, ConversationState> states,
  CoreHost host,
) async {
  final lines = ['$who: $state'];
  for (final id in fake.conversationIds) {
    String group;
    try {
      final held = await host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': id});
      group = 'generation ${held['generation']}, epoch ${held['epoch']}${held['blocked'] == true ? ', blocked' : ''}';
    } on CoreError catch (error) {
      group = error.code == 'not_found' ? 'no group' : 'its group not read (${error.code})';
    }
    lines.add('  conversation $id: $group; ${states[id] ?? 'no notice'}');
  }
  return lines.join('\n');
}

/// Waits until [holds] is true, as an engine's work after an event ends in its own time: past [timeout], it fails,
/// telling [what] it waited for and what each of the test's devices holds.
Future<void> until(FutureOr<bool> Function() holds, {Duration? timeout, String? what}) async {
  final end = DateTime.now().add(timeout ?? _wait);
  while (!await holds()) {
    if (DateTime.now().isAfter(end)) {
      fail(
        [
          'what the test waited for never came${what == null ? '' : ': $what'}',
          for (final describe in [..._shown]) await describe(),
        ].join('\n'),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Waits for the work the device's engine took on until now, what the events delivered so far asked for included: a
/// tap that does nothing on a ready device, which waits its turn after them; then the encrypted backup's pass, whose
/// requests run outside the turn.
Future<void> turnEnded(TestDevice device) async {
  await pumpEventQueue();
  await device.engine.uploadLater();
  await device.engine.backupSettled();
}

/// The person's yes on the device to the members its conversation's question names now: those its bar draws.
Future<void> acceptAsShown(TestDevice device, String conversation) =>
    device.engine.acceptMembers(conversation, device.engine.conversationState(conversation)?.users ?? const []);

/// A command run by hand on the device's core, the users it asks for observed first, as the engine does.
Future<Map<String, Object?>> byHand(TestDevice device, Map<String, Object?> command) async {
  for (var round = 1; ; round++) {
    try {
      return await device.host.handle<Map<String, Object?>>(command);
    } on CoreError catch (error) {
      if (error.code != 'needs_identities' || round >= 3) rethrow;
      for (final identity in await device.api.identities(error.users!)) {
        await device.host.handle<Object?>({
          'cmd': 'observe_user',
          'user_id': identity.userId,
          'identity_key': identity.identityKey,
          'device_list': identity.deviceList,
          'certificates': identity.certificates,
        });
      }
    }
  }
}

/// A commit of the device's own, made and sent by hand, with its engine stopped (its core open): its leaf's renewal,
/// posted, and the API's answer told to the core.
Future<duvet.CommitTaken> commitByHand(TestDevice device, String conversation) async {
  final held = (await groupOf(device, conversation))!;
  final made = await byHand(device, {'cmd': 'refresh', 'conversation_id': conversation});
  final taken = await device.api.commit(
    conversation,
    duvet.Commit(
      generation: held.generation,
      epoch: held.epoch,
      commit: made['commit']! as String,
      groupInfo: made['group_info']! as String,
    ),
  );
  await device.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': true,
    'seq': taken.seq,
  });
  return taken;
}

/// A message of the device's own, sent by hand with its engine stopped (its core open): the API's message. [spoil]
/// changes a byte of its tag, so no member can open it.
Future<duvet.DirectMessage> sentByHand(
  TestDevice device,
  String conversation,
  String text, {
  bool spoil = false,
}) async {
  final nonce = '0f4b6c1e-${text.hashCode.toRadixString(16).padLeft(8, '0').substring(0, 4)}-4000-8000-000000000000';
  final made = await device.host.handle<Map<String, Object?>>({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': {'text': text},
  });
  var ciphertext = made['ciphertext']! as String;
  if (spoil) {
    // One byte of its tag changed: no member can open it.
    final bytes = base64Decode(ciphertext);
    bytes[bytes.length - 1] ^= 0xff;
    ciphertext = base64Encode(bytes);
  }
  final message = await device.api.sendMessage(
    conversation,
    duvet.EncryptedMessage(ciphertext: ciphertext, nonce: nonce),
  );
  if (!spoil) {
    await device.host.handle<Object?>({
      'cmd': 'sent',
      'conversation_id': conversation,
      'nonce': nonce,
      'message_id': message.id,
      'seq': message.seq,
    });
  }
  return message;
}

/// The device's engine stopped, and its core opened again, for commits by hand.
Future<void> stoppedByHand(TestDevice device) async {
  await device.engine.stop();
  await device.host.open(device.user);
}

/// The owner's removal of a user, by hand (Task 23 does it in the app): its commit, posted, and taken.
Future<duvet.CommitTaken> removeByHand(TestDevice owner, String conversation, String user) async {
  final held = (await groupOf(owner, conversation))!;
  final made = await byHand(owner, {
    'cmd': 'remove_members',
    'conversation_id': conversation,
    'users': [user],
  });
  final taken = await owner.api.removeMember(
    conversation,
    user,
    duvet.Commit(
      generation: held.generation,
      epoch: held.epoch,
      commit: made['commit']! as String,
      groupInfo: made['group_info']! as String,
    ),
  );
  await owner.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': true,
    'seq': taken.seq,
  });
  return taken;
}

/// The owner's addition of a user, with key packages of theirs claimed earlier, by hand (Task 23 does it in the app):
/// its commit and welcome, posted, and taken.
Future<duvet.MemberAdded> addByHand(
  TestDevice owner,
  String conversation,
  String user,
  List<duvet.ClaimedKeyPackage> keyPackages,
) async {
  final held = (await groupOf(owner, conversation))!;
  final made = await byHand(owner, {
    'cmd': 'add_members',
    'conversation_id': conversation,
    'users': [
      {
        'user_id': user,
        'key_packages': [for (final kp in keyPackages) kp.data],
      },
    ],
  });
  final added = await owner.api.addMember(
    conversation,
    user,
    duvet.Commit(
      generation: held.generation,
      epoch: held.epoch,
      commit: made['commit']! as String,
      groupInfo: made['group_info']! as String,
      welcome: made['welcome'] as String?,
    ),
  );
  await owner.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': true,
    'seq': added.commit.seq,
  });
  return added;
}

/// The device again after its app restarted: a new engine on the same core, record and session, started.
Future<TestDevice> restarted(
  FakeApi fake,
  TestDevice device, {
  CoreHost? host,
  http.Client? client,
  bool Function(GatewayEvent event)? hears,
  PageDrawing? drawn,
}) async {
  await device.engine.stop();
  final again = testDevice(
    fake,
    device.user,
    host: host ?? device.host,
    store: device.store,
    token: device.token,
    client: client,
    hears: hears,
    drawn: drawn,
  );
  await again.engine.start();
  return again;
}

/// Another device of the first one's user, set up by the first one's approval by QR (Task 27 does it in the app) and
/// on the user's list: its engine started and ready, its requests through [client] when given, hearing what [hears]
/// lets through.
Future<TestDevice> approvedDevice(
  FakeApi fake,
  TestDevice first, {
  CoreHost? host,
  http.Client? client,
  bool Function(GatewayEvent event)? hears,
  PageDrawing? drawn,
}) async {
  final fresh = testDevice(fake, first.user, host: host, client: client, drawn: drawn);
  await fresh.engine.start();
  if (fresh.state != EngineState.newDevice) throw StateError('the new device is ${fresh.state}');
  await stoppedByHand(fresh);
  final begun = await fresh.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
  final approved = await first.host.handle<Map<String, Object?>>({'cmd': 'approval_from_qr', 'qr': begun['qr']});
  await fresh.host.handle<Object?>({'cmd': 'approval_receive', 'transfer': approved['transfer']});
  final served = await fresh.api.identity(first.user);
  final version = await fresh.api.putDeviceList(
    duvet.DeviceListUpload(
      deviceList: approved['device_list']! as String,
      certificate: approved['certificate']! as String,
      baseVersion: served.deviceListVersion,
    ),
  );
  await fresh.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': version});
  final again = await restarted(fake, fresh, client: client, hears: hears, drawn: drawn);
  if (again.state != EngineState.ready) throw StateError('the approved device is ${again.state}');
  return again;
}

/// The path of a conversation's commits, for the fake's switches.
String commitsPath(String conversation) => '/api/users/@me/conversations/$conversation/mls/commits';

/// What a device asked the API: each request's method and path, with its query.
List<String> requestsOf(List<http.Request> seen) => [
  for (final request in seen)
    '${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}',
];

/// A recovery key as the core makes one (decision 22): 48 base58 characters.
final recoveryKeyShape = matches(RegExp(r'^[1-9A-HJ-NP-Za-km-z]{48}$'));

/// The group blocked on every device: a commit no device can process gets in, as a server that takes anything would
/// let it: Ana's leaf renewal, one byte of its signature changed, sent under Bo's session. Ana's own renewal never
/// went. Her device again after its app restarted, with the two others.
Future<List<TestDevice>> blockedByHand(FakeApi fake, String conversation, List<TestDevice> devices) async {
  var [a, b, c] = devices;
  final before = (await groupOf(a, conversation))!;
  await stoppedByHand(a);
  final made = await byHand(a, {'cmd': 'refresh', 'conversation_id': conversation});
  final bytes = base64Decode(made['commit']! as String);
  bytes[bytes.length - 1] ^= 0xff;
  await b.api.commit(
    conversation,
    duvet.Commit(
      generation: before.generation,
      epoch: before.epoch,
      commit: base64Encode(bytes),
      groupInfo: made['group_info']! as String,
    ),
  );
  await a.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': false,
    'invalid': true,
  });
  a = await restarted(fake, a);
  await until(
    () => [a, b, c].every((d) => d.engine.conversationState(conversation)?.name == ConversationNotice.blocked),
  );
  return [a, b, c];
}

/// The device's files of a message, once its core holds the message, as a view reads them.
Future<List<ShownFile>> filesOn(TestDevice device, String conversation, String id) async {
  var files = <ShownFile>[];
  await until(() async {
    final row = (await device.engine.messages(conversation, [id])).firstOrNull;
    if (row?.status != MessageStatus.ok) return false;
    files = [for (final raw in row!.attachments) ?shownFile(raw)];
    return true;
  });
  return files;
}

/// A file as another client could send it, its envelope written by hand: the core seals it and encrypts what it's
/// told, and nothing checks what the sender says of it. Sent beside Ana's engine, which is idle.
Future<duvet.DirectMessage> sendWritten(
  TestDevice device,
  String conversation,
  List<({Uint8List bytes, Map<String, Object?> said})> files,
) async {
  final attachments = <Map<String, Object?>>[];
  final sealed = <Uint8List>[];
  for (final (:bytes, :said) in files) {
    final key = (await device.host.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
    final id = uuidv7();
    sealed.add(await device.host.sealFile(key, id, bytes));
    attachments.add({
      'id': id,
      'key': key,
      'sha256': base64Encode(sha256.convert(bytes).bytes),
      'name': 'file',
      'type': 'application/octet-stream',
      'size': bytes.length,
      ...said,
    });
  }
  final nonce = uuidv4();
  final made = await device.host.handle<Map<String, Object?>>({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': {'attachments': attachments},
  });
  final message = await device.api.sendMessage(
    conversation,
    duvet.EncryptedMessage(
      ciphertext: made['ciphertext']! as String,
      nonce: nonce,
      attachmentIds: [for (final a in attachments) a['id']! as String],
    ),
    files: sealed,
  );
  await device.host.handle<Object?>({
    'cmd': 'sent',
    'conversation_id': conversation,
    'nonce': nonce,
    'message_id': message.id,
    'seq': message.seq,
  });
  return message;
}
