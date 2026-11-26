import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/push_decrypt.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/notifications.dart';
import 'package:duvet/push/push_history.dart';
import 'package:duvet/push/push_message.dart';
import 'package:duvet/search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Plain text stays in the core's database (PLAN-E2E-CLIENTES.md, Review Focus 1): Ana's app, its repository with its
// engine, and Bo's device converse with a witness string, sent, read, quoted, edited, deleted and left waiting after a
// cut request, the chat's page drawn and its preview shown; a file whose name and bytes hold it goes each way, its copy
// decrypted in the app's temporary folder alone (Task 19); and it's searched for in the conversation and everywhere,
// noticed in the app and pushed to the phone (Task 21); and all of it shared with Bo, who adds it (Task 31). Then no
// file of the app's (the engine's record, the core's database, the notifications' history), no record of Bo's engine,
// no page of the chat cache, no recent chat kept, no request the API saw (its URL or its body) and no log line holds
// it. The desktop's e2e-witness.test.ts, over what the phone keeps too.
const _slow = Timeout(Duration(minutes: 3));

/// The recent chats as they're kept, each write of them.
class _KeptRecents implements RecentChatsStore {
  final written = <String>[];

  @override
  Future<String?> read(String userId) async => null;

  @override
  Future<void> write(String userId, String json) async => written.add(json);

  @override
  Future<void> clearAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'a_witness_string_sent_and_received_is_nowhere_but_in_the_cores',
    () async {
      final witness = 'witness-${uuidv4()}';
      final logged = <String>[];
      final print = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = print);
      // The app's support folder: the engine's record, the core's database and the notifications' history go there.
      final support = Directory.systemTemp.createTempSync('duvet-witness-');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => support.path);
      addTearDown(() {
        messenger.setMockMethodCallHandler(paths, null);
        support.deleteSync(recursive: true);
      });

      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final target = ConversationTarget(conversation);
      // Ana's app on the fake: it signs her in, and every request it makes goes to the fake, its body noted.
      final bodies = <String>[];
      final session = fake.signIn(ana);
      final client = MockClient((request) async {
        bodies.add('${request.url} ${latin1.decode(request.bodyBytes)}');
        final at = DateTime.now().toUtc().toIso8601String();
        final Object? own = switch ((request.method, request.url.path)) {
          ('POST', '/api/auth/login') => {
            'token': session.token,
            'session_token': 'refresh',
            'device_challenge': session.deviceChallenge,
          },
          ('GET', '/api/users/@me') => {'id': ana, 'username': 'ana', 'created_at': at, 'updated_at': at},
          _ => null,
        };
        if (own != null) return http.Response(jsonEncode(own), 200, headers: {'content-type': 'application/json'});
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await fake.client.send(copy));
      });
      final recents = _KeptRecents();
      final cache = MemoryChatCacheStore();
      late CoreGate anaCore;
      final repository = DuvetRepository(
        store: MemorySessionStore(),
        recentsStore: recents,
        httpClient: () => client,
        connectGateway: false,
        cacheStore: cache,
        encryptionHost: () => anaCore = TestHost(folder: Directory('${support.path}/core')..createSync()).gate,
        onScreen: () => true,
      );
      await repository.logIn('ana@duvet.chat', 'secret');
      // Her gateway's events, as its connection hands them to the repository.
      final end = fake.connect(session.token, null, (event) {
        if (payloadOf(event, ana) case final payload?) repository.handleEvent(payload);
      });
      await until(() => repository.encryption.value.stage == EngineStage.firstDevice);
      await repository.makeIdentity();
      await repository.keySaved();
      await until(() => repository.encryption.value == EngineState.ready);
      final boStore = MemoryStore();
      final b = await firstDevice(
        fake,
        bo,
        store: boStore,
        client: watchedClient(
          fake,
          seen: (request) => bodies.add('${request.url} ${latin1.decode(request.bodyBytes)}'),
        ),
      );
      // Ana opens the DM: her device makes its group, and Bo's joins it.
      repository.chatShown(target);
      Future<int?> anaEpoch() => anaCore
          .handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversation})
          .then<int?>((held) => held['epoch'] as int?, onError: (Object _) => null);
      await until(() async => await anaEpoch() != null && await groupOf(b, conversation) != null);

      Future<String?> textOnAna(String id) async =>
          switch ((await shownMessages(anaCore, conversation, [id])).firstOrNull) {
            final shown? when shown.status == MessageStatus.ok => shown.text,
            _ => null,
          };
      // Sent, read on Bo's device, quoted in his answer, which Ana's chat and its preview show.
      final sent = await repository.send(target, witness, nonce: uuidv4());
      Future<String?> textOnBo(String id) async => switch ((await b.engine.messages(conversation, [id])).firstOrNull) {
        final shown? when shown.status == MessageStatus.ok => shown.text,
        _ => null,
      };
      await until(() async => await textOnBo(sent.id) == witness);
      final reply = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 're: $witness', replyTo: sent.id),
      ))!;
      await until(() => repository.recents.value.any((chat) => chat.previewText?.contains(witness) ?? false));
      final page = await repository.messages(target);
      expect([for (final m in page) m.content], [witness, 're: $witness']);
      expect(page.last.reply?.content, witness);
      // A thread's quotes take their text from the device too (Missing 2 of the desktop's task 16 review).
      final thread = await repository.thread(target, sent.id);
      expect(thread.where((m) => m.id == reply.id).single.reply?.content, witness);
      repository.opened(target, 'Bo', latest: page.last);

      // Edited, and Bo's answer deleted.
      await repository.edit(target, sent.id, '$witness, edited');
      await until(() async => await textOnBo(sent.id) == '$witness, edited');
      await b.engine.deleteMessage(conversation, reply.id);
      // One whose request never reached the API waits on Ana's device, its reply in the clear beside it.
      fake.cutRequest((method: 'POST', path: '/api/users/@me/conversations/$conversation/messages'));
      await expectLater(
        repository.send(target, '$witness, waiting', nonce: uuidv4(), replyTo: sent.id),
        throwsA(anything),
      );
      final waiting = await repository.messages(target);
      expect(
        [
          for (final m in waiting)
            if (m.pending) m.content,
        ],
        ['$witness, waiting'],
      );

      // A file whose name and bytes hold the witness, picked from outside the app's folders: sent from Ana's app and
      // opened on Bo's device; and Bo's, opened in Ana's app, whose copy is in its temporary folder (e2e-media), the
      // one place a file's bytes may be.
      final picked = Directory.systemTemp.createTempSync('duvet-picked-');
      addTearDown(() => picked.deleteSync(recursive: true));
      final source = File('${picked.path}/picked.bin')..writeAsBytesSync(utf8.encode('the file of $witness'));
      final withFile = await repository.send(
        target,
        '',
        nonce: uuidv4(),
        files: [
          OutgoingFile(
            path: source.path,
            name: '$witness.txt',
            contentType: 'text/plain',
            sizeBytes: source.lengthSync(),
          ),
        ],
      );
      late ShownFile anaFile;
      await until(() async {
        final row = (await b.engine.messages(conversation, [withFile.id])).firstOrNull;
        if (row?.status != MessageStatus.ok || row!.attachments.isEmpty) return false;
        anaFile = shownFile(row.attachments.single)!;
        return true;
      });
      expect(anaFile.name, '$witness.txt');
      final listed = await b.api.signedFile(fake.signedUrlOf(anaFile.id));
      final opened = await openSealed(
        anaFile,
        download: (most, progress) async => listed,
        open: (key, id, sealed, progress) => b.engine.openFile(key, id, sealed, progress: progress),
      );
      expect(utf8.decode(opened.bytes), 'the file of $witness');
      final his = (await b.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: utf8.encode('his file of $witness'), name: 'his $witness.txt')],
        ),
      ))!;
      late MessageAttachment hisFile;
      await until(() async {
        final shown = (await repository.messages(target)).where((m) => m.id == his.id).firstOrNull;
        if (shown == null || shown.attachments.isEmpty) return false;
        hisFile = shown.attachments.single;
        return true;
      });
      expect(hisFile.filename, 'his $witness.txt');
      final state = await DecryptedFiles.instance.open(hisFile.sealed!, hisFile.url, his.id);
      expect(File((state as FileReady).path).readAsStringSync(), 'his file of $witness');
      // Searched for, in the conversation and everywhere: on the device (Task 21).
      expect([
        for (final hit in (await repository.search(SearchQuery(witness, conversationId: conversation))).hits)
          hit.message.id,
      ], contains(sent.id));
      expect([
        for (final hit in await searchEverywhere(repository, witness, spaces: const [])) hit.message.id,
      ], contains(sent.id));
      // Noticed in the app, with the chat left: its notice says the device's text.
      repository.chatHidden(target);
      final noticed = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: '$witness, noticed'),
      ))!;
      await until(() => repository.mentionNotices.value.any((n) => n.messageId == noticed.id));
      expect(repository.mentionNotices.value.firstWhere((n) => n.messageId == noticed.id).text, '$witness, noticed');
      // Pushed, and shown on the phone: the app's engine, which holds the core, answers the push's engine.
      final shows = <String>[];
      const notifications = MethodChannel('dexterous.com/flutter/local_notifications');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance = AndroidFlutterLocalNotificationsPlugin();
      messenger.setMockMethodCallHandler(notifications, (call) async {
        if (call.method == 'show') shows.add('${call.arguments}');
        return call.method == 'getActiveNotifications' ? const <Object>[] : null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(notifications, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final answering = answerPushes((ask) => repository.pushTexts(ask.conversationId, ask.entry, ask.lines, ask.wait));
      addTearDown(() => stopAnsweringPushes(answering));
      final pushed = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: '$witness, pushed'),
      ))!;
      await until(() async => await textOnAna(pushed.id) == '$witness, pushed');
      final push = Push.fromData(fake.pushOf(conversation, pushed.id))! as EncryptedMessagePush;
      final notification = await openedPush(
        push,
        earlier: await PushHistory(support).read(conversation),
        session: (token: session.token, sessionToken: 'refresh', refreshedAt: null, userId: ana),
        core: (_) => throw StateError('the app holds the core'),
        router: fakeRouter,
        duvetClient: engineClient,
        client: watchedClient(
          fake,
          seen: (request) => bodies.add('${request.url} ${latin1.decode(request.bodyBytes)}'),
        ),
        store: (_) async => MemoryStore(),
      );
      await showPush(notification!);
      expect(shows.single, contains('$witness, pushed'));
      // All of it shared from Ana's app with Bo's device, which adds it (Task 31): its package's parts go up and come
      // down sealed, its key through the inbox.
      await repository.shareHistory(conversation, bo, 'all');
      await until(() => (b.engine.historyOffers.value[conversation] ?? const []).isNotEmpty);
      await b.engine.takeHistoryOffer(b.engine.historyOffers.value[conversation]!.single.shareId);
      expect(bodies.where((body) => body.contains('/history-shares/') && body.contains('/parts/')), isNotEmpty);
      await b.engine.stop();
      end();
      repository.dispose();
      await pumpEventQueue();

      // The witness, or its bytes in base64 at any of the three offsets a field's bytes can start it at: each
      // encoding's characters that its bytes alone decide (M9 of task 17's review).
      final encoded = utf8.encode(witness);
      final inBase64 = [
        for (var shift = 0; shift < 3; shift++)
          switch (base64Encode([...List.filled(shift, 0), ...encoded])) {
            final whole => whole.substring(shift == 0 ? 0 : 4, whole.length - 4),
          },
      ];
      bool holds(String text) => text.contains(witness) || inBase64.any(text.contains);
      // The app's files: what the engine keeps, the core's database (sealed), the notifications' history; all but the
      // temporary folder's copies of decrypted files, the one place a file's bytes may be, which went with the
      // session's engine.
      final media = '${support.path}/e2e-media/';
      final copies = [
        for (final file in support.listSync(recursive: true).whereType<File>())
          if (file.path.startsWith(media)) file,
      ];
      expect(copies, isEmpty);
      final files = [
        for (final file in support.listSync(recursive: true).whereType<File>())
          if (!file.path.startsWith(media)) file,
      ];
      expect([for (final file in files) file.path], contains(endsWith('client.json')));
      expect([
        for (final file in files)
          if (holds(latin1.decode(file.readAsBytesSync()))) file.path,
      ], isEmpty);
      // Bo's engine's record whole, the chat cache, the recent chats kept, the API's bodies, the log.
      expect(boStore.kept.values.where(holds), isEmpty);
      expect(cache.data.values.where(holds), isEmpty);
      expect(recents.written, isNotEmpty);
      expect(recents.written.where(holds), isEmpty);
      expect(bodies.where(holds), isEmpty);
      expect(logged.where(holds), isEmpty);
    },
    skip: noCore,
    timeout: _slow,
  );
}
