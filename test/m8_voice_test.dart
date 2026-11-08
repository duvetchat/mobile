// M8 · Voice & calls: the voice room, the incoming call and call screens,
// the bar over the tabs, a DM's call button and banner, and the Calls tab,
// over a fake gateway and a fake WebRTC.
import 'dart:async';

import 'package:duvet/calls.dart' show CallScreen;
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/data/voice_engine.dart' show PeerState;
import 'package:duvet/main.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

class _App {
  final repository = FakeRepository();
  final engine = FakeVoiceEngine();
  DateTime now = DateTime(2026, 10, 23, 10);
  late final voice = VoiceController(
    repository: repository,
    engine: engine,
    historyStore: MemoryCallHistoryStore(),
    clock: () => now,
  );

  FakeVoiceSignaling get gateway => repository.voiceSignaling;
}

void main() {
  Future<_App> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final app = _App();
    await tester.pumpWidget(DuvetApp(repository: app.repository, voice: app.voice));
    await tester.pumpAndSettle();
    return app;
  }

  // The screens tick (a call's clock): settle by time, not by frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Unmounts the app, then ends voice: no timer outlives the test.
  Future<void> finish(WidgetTester tester, _App app) async {
    await tester.pumpWidget(const SizedBox());
    app.voice.dispose();
  }

  Future<void> openLounge(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
  }

  duvet.VoiceStateUpdatedEvent state(String user, int version, {bool joined = true, bool muted = false}) =>
      duvet.VoiceStateUpdatedEvent(
        duvet.VoiceStateEvent(roomId: 'r-lounge', userId: user, joined: joined, muted: muted, version: version),
      );

  testWidgets('a voice room: who\'s in, Join voice, the faces talking, mute, leave', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.gateway.push(state(FakeRepository.maya, 3, muted: true));
    await openLounge(tester);
    // The directory's row says who's in.
    expect(find.text('Maya'), findsOneWidget);

    await tester.tap(find.text('lounge').last);
    await settle(tester);
    expect(find.text('Join voice'), findsOneWidget);
    expect(find.bySemanticsLabel('Maya, muted'), findsOneWidget);

    await tester.tap(find.text('Join voice'));
    await settle(tester);
    expect(app.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC']);
    expect(find.text('Connecting…'), findsOneWidget);
    // The user's own tile, and the controls instead of Join.
    expect(find.bySemanticsLabel('Gaby (you)'), findsOneWidget);
    expect(find.text('Join voice'), findsNothing);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);

    // Connected: Maya talks, and her face's mouth opens.
    app.gateway.push(state(FakeRepository.maya, 4));
    app.gateway.push(
      const duvet.VoiceJoinedPayloadEvent(
        duvet.VoiceJoinedEvent(
          roomId: 'r-lounge',
          answer: duvet.SessionDescription(type: 'answer', sdp: 'a1'),
        ),
      ),
    );
    app.engine.peer.stateHandler!(PeerState.connected);
    app.engine.peer.levels = (local: null, remote: {FakeRepository.maya: 0.2});
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Connecting…'), findsNothing);
    expect(find.bySemanticsLabel('Maya, speaking'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Facehash && w.name == 'Maya' && w.mouthOpen > 0.5), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Mute'));
    await settle(tester);
    expect(app.voice.muted, isTrue);
    expect(app.gateway.last('VOICE_SYNC')!['muted'], isTrue);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Mute')),
      matchesSemantics(
        label: 'Mute',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(find.text('Unmute'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Leave voice'));
    await settle(tester);
    expect(app.gateway.types.last, 'VOICE_LEAVE');
    expect(find.text('Join voice'), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('without JoinVoice the room can\'t be joined', (tester) async {
    final app = await pumpApp(tester);
    app.repository.noJoin.add('r-lounge');
    await openLounge(tester);
    await tester.tap(find.text('lounge'));
    await settle(tester);
    expect(find.text('You can’t join this voice room'), findsOneWidget);
    await tester.tap(find.text('Join voice'));
    await settle(tester);
    expect(app.gateway.sent, isEmpty);
    await finish(tester, app);
  });

  testWidgets('in voice, the bar over the tabs goes back to it, and leaves', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await openLounge(tester);
    await tester.tap(find.text('lounge'));
    await settle(tester);
    await tester.tap(find.text('Join voice'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Back'));
    await settle(tester);

    // The directory marks the room, and the bar shows over the tab bar.
    expect(find.bySemanticsLabel(RegExp(r'^lounge, .*you’re in voice here')), findsOneWidget);
    expect(find.text('lounge · Design Guild'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Voice in lounge · Design Guild, Connecting…')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Leave voice'));
    await settle(tester);
    expect(app.gateway.types.last, 'VOICE_LEAVE');
    expect(find.text('lounge · Design Guild'), findsNothing);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('an incoming call rings full screen; answered, the call screen; hung up, the Calls tab', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.bySemanticsLabel('Incoming call from Maya'), findsOneWidget);
    expect(find.bySemanticsLabel('Decline the call'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Accept the call'));
    await settle(tester);
    expect(app.gateway.types, ['CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
    expect(find.text('Incoming call'), findsNothing);
    expect(find.bySemanticsLabel('Call with Maya, Connecting…'), findsOneWidget);

    app.engine.peer.stateHandler!(PeerState.connected);
    app.now = app.now.add(const Duration(minutes: 1, seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:04'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Hang up the call'));
    await settle(tester);
    expect(app.gateway.types.last, 'CALL_LEAVE');
    expect(find.bySemanticsLabel(RegExp('^Call with Maya')), findsNothing);

    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Calls')));
    await settle(tester);
    expect(find.text('Incoming · 1:04'), findsOneWidget);
    expect(find.textContaining('Duvet keeps no call history'), findsOneWidget);
    expect(find.bySemanticsLabel('Call Maya'), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('signing out while a call rings takes its screen away', (tester) async {
    final app = await pumpApp(tester);
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsOneWidget);

    await app.repository.logOut();
    await settle(tester);
    await settle(tester);
    expect(find.text('Incoming call'), findsNothing);
    expect(find.text('Talk with your people.'), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('a declined call goes, and shows as declined', (tester) async {
    final app = await pumpApp(tester);
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Decline'));
    await settle(tester);
    expect(app.gateway.last('CALL_DECLINE'), {'conversation_id': 'c-maya'});
    expect(find.text('Incoming call'), findsNothing);

    // Rang out without an answer here: missed.
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
      ),
    );
    await settle(tester);
    app.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-leo')));
    await settle(tester);
    expect(find.text('Incoming call'), findsNothing);

    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Calls')));
    await settle(tester);
    expect(find.text('Missed call'), findsOneWidget);
    expect(find.text('Declined'), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('two quick taps on Call place one call and open one call screen', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();

    // The microphone's permission dialog: the call isn't placed yet.
    app.engine.holdMic = Completer<void>();
    await tester.tap(find.bySemanticsLabel('Call'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Call'));
    await tester.pump();
    app.engine.holdMic!.complete();
    app.engine.holdMic = null;
    await settle(tester);
    expect(app.gateway.types.where((t) => t == 'CALL_INITIATE'), hasLength(1));
    expect(find.byType(CallScreen, skipOffstage: false), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a DM\'s Call button calls; cancelled before an answer', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Call'));
    await settle(tester);
    expect(app.gateway.last('CALL_INITIATE'), {
      'conversation_id': 'c-maya',
      'member_ids': [FakeRepository.me.id, FakeRepository.maya],
    });
    expect(find.text('Calling…'), findsWidgets);

    await tester.tap(find.bySemanticsLabel('Cancel the call'));
    await settle(tester);
    expect(app.gateway.types.last, 'CALL_CANCEL');
    expect(find.text('Calling…'), findsNothing);
    // Back in the chat, nothing going on.
    expect(find.text('Call in progress'), findsNothing);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('in voice, voice notes wait: the call has the microphone', (tester) async {
    final semantics = tester.ensureSemantics();
    var recordings = 0;
    VoiceRecorder.create = () => _Recorder(() => recordings++);
    addTearDown(() => VoiceRecorder.create = RecordVoiceRecorder.new);
    final app = await pumpApp(tester);
    await app.voice.joinRoom(
      const Room(id: 'r-lounge', spaceId: 's-guild', name: 'lounge', kind: RoomKind.voice, position: 1),
    );
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Add photos, a sticker or a mention').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Voice note').last);
    await settle(tester);
    expect(recordings, 0);
    expect(find.text('You can’t record while in a call or a voice room'), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a call answered stops the voice note being recorded under it', (tester) async {
    final semantics = tester.ensureSemantics();
    var recordings = 0;
    var cancels = 0;
    VoiceRecorder.create = () => _Recorder(() => recordings++, onCancel: () => cancels++);
    addTearDown(() => VoiceRecorder.create = RecordVoiceRecorder.new);
    final app = await pumpApp(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Add photos, a sticker or a mention').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Voice note').last);
    await settle(tester);
    expect(recordings, 1);

    // The call rings over the chat, which stays underneath.
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Accept the call'));
    await settle(tester);
    expect(app.voice.target, const CallVoice('c-maya'));
    expect(cancels, 1);
    expect(app.repository.voiceNotes, isEmpty);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a voice room with people in it shows on Chats, to join', (tester) async {
    final app = await pumpApp(tester);
    expect(find.text('In voice now'), findsNothing);
    app.gateway.push(state(FakeRepository.maya, 3));
    await tester.pumpAndSettle();
    expect(find.text('In voice now'), findsOneWidget);
    expect(find.text('Live · Design Guild'), findsOneWidget);
    // Anyone in it counts, a friend or not: still one card for the room.
    app.gateway.push(state(FakeRepository.leo, 4));
    await tester.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await settle(tester);
    expect(app.gateway.types, contains('VOICE_JOIN'));
    // In that room now: the voice bar has it, not a card.
    expect(find.text('Live · Design Guild'), findsNothing);
    await finish(tester, app);
  });

  testWidgets('voice going on in a Space shows above its rooms, to join', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.gateway.push(state(FakeRepository.maya, 3));
    await openLounge(tester);
    expect(find.text('Live · Maya'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await settle(tester);
    expect(app.gateway.types, contains('VOICE_JOIN'));
    // In that room now: the voice bar has it, not the banner.
    await tester.tap(find.bySemanticsLabel('Back'));
    await settle(tester);
    expect(find.text('lounge · Design Guild'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-r-lounge')), findsNothing);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a call going on in a DM: its banner joins it', (tester) async {
    final app = await pumpApp(tester);
    // A new session lists the call: someone else's, going on.
    app.gateway.ready(
      calls: [
        duvet.GatewayReadyActiveCall.fromJson({
          'conversation_id': 'c-maya',
          'initiator_id': FakeRepository.maya,
          'voice_states': [
            {'user_id': FakeRepository.maya, 'version': 2},
          ],
        }),
      ],
    );
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    // Who is in it.
    expect(find.text('Call in progress · Maya'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await settle(tester);
    expect(app.gateway.types, containsAllInOrder(['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN']));
    // The call screen, Maya and the user in it.
    expect(find.bySemanticsLabel(RegExp('^Call with Maya')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Facehash && w.name == 'Maya'), findsWidgets);
    await finish(tester, app);
  });

  // A call across the user's devices (duvetchat/gateway#25).
  duvet.VoiceStateUpdatedEvent inCall(String conversation, String user, int version) => duvet.VoiceStateUpdatedEvent(
    duvet.VoiceStateEvent(roomId: conversation, userId: user, joined: true, version: version),
  );
  IconAction button(WidgetTester tester, String label) =>
      tester.widget(find.byWidgetPredicate((w) => w is IconAction && w.label == label));

  testWidgets('the user\'s own call from another device: no Join and no Call until someone answers it', (tester) async {
    final app = await pumpApp(tester);
    // Placed on the user's desktop: it rings nothing here.
    app.gateway.push(const duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: 'c-maya')));
    await settle(tester);
    expect(find.text('Incoming call'), findsNothing);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(find.text('Calling from another device'), findsOneWidget);
    expect(find.text('Join'), findsNothing);
    expect(button(tester, 'Call').onPressed, isNull);

    // Maya answered, and the desktop joined: Join, and Call as it does, move
    // the user's voice here.
    app.gateway.push(
      const duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
    );
    app.gateway.push(inCall('c-maya', FakeRepository.me.id, 1));
    app.gateway.push(inCall('c-maya', FakeRepository.maya, 2));
    await settle(tester);
    expect(find.text('Call in progress · You, Maya'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
    expect(button(tester, 'Call').onPressed, isNotNull);
    await tester.tap(find.bySemanticsLabel('Call'));
    await settle(tester);
    expect(app.gateway.types, ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
    expect(find.bySemanticsLabel(RegExp('^Call with Maya')), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('the Calls tab\'s Call waits too while the user\'s own call rings from another device', (tester) async {
    final app = await pumpApp(tester);
    // Maya called, and the user declined: her row in the Calls tab.
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Decline the call'));
    await settle(tester);
    app.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Calls')));
    await settle(tester);
    expect(button(tester, 'Call Maya').onPressed, isNotNull);

    // The user calls her back from the desktop.
    app.gateway.push(const duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: 'c-maya')));
    await settle(tester);
    expect(button(tester, 'Call Maya').onPressed, isNull);
    app.gateway.push(
      const duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
    );
    await settle(tester);
    expect(button(tester, 'Call Maya').onPressed, isNotNull);
    app.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));

    // A call placed from here: its button opens its screen again.
    await tester.tap(find.bySemanticsLabel('Call Maya'));
    await settle(tester);
    app.gateway.push(const duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: 'c-maya')));
    await settle(tester);
    expect(find.text('Calling…'), findsWidgets);
    await tester.tap(find.bySemanticsLabel('Back'));
    await settle(tester);
    expect(button(tester, 'Call Maya').onPressed, isNotNull);
    await finish(tester, app);
  });

  testWidgets('a call ringing here stops when the user declines or answers it on another device', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    // It rang while the phone was away: READY names its caller.
    app.gateway.ready(
      calls: const [
        duvet.GatewayReadyActiveCall(
          conversationId: 'c-maya',
          initiatorId: FakeRepository.maya,
          initiatorName: 'Maya',
          ringing: true,
          answered: false,
        ),
      ],
    );
    await settle(tester);
    expect(find.bySemanticsLabel('Incoming call from Maya'), findsOneWidget);

    app.gateway.push(
      duvet.CallDeclinedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.me.id)),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsNothing);
    app.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));

    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsOneWidget);
    app.gateway.push(
      duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.me.id)),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsNothing);
    expect(app.gateway.sent, isEmpty);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a group\'s call rung from READY shows its caller, avatar included', (tester) async {
    final app = await pumpApp(tester);
    app.gateway.ready(
      calls: const [
        duvet.GatewayReadyActiveCall(
          conversationId: 'c-team',
          initiatorId: FakeRepository.leo,
          initiatorName: 'leo',
          initiatorAvatar: '0a0a0a0a-0000-4000-8000-0000000000a1',
          ringing: true,
          answered: false,
        ),
      ],
    );
    await settle(tester);
    expect(find.text('Calling Design crew'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is UserAvatar &&
            w.name == 'leo' &&
            w.url == 'https://example.invalid/attachments/0a0a0a0a-0000-4000-8000-0000000000a1',
      ),
      findsOneWidget,
    );
    await finish(tester, app);
  });

  testWidgets('a group\'s call whose ring window ends stops ringing, and its chat shows who is in it, to join', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-team', initiatorId: FakeRepository.leo, initiatorName: 'leo'),
      ),
    );
    await settle(tester);
    expect(find.text('Calling Design crew'), findsOneWidget);

    // Maya answered; nobody else did in 30 s.
    app.gateway.push(
      const duvet.CallOngoingPayloadEvent(
        duvet.CallOngoingEvent(
          conversationId: 'c-team',
          initiatorId: FakeRepository.leo,
          voiceStates: [
            duvet.CallVoiceState(userId: FakeRepository.leo, version: 1),
            duvet.CallVoiceState(userId: FakeRepository.maya, version: 2),
          ],
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Calling Design crew'), findsNothing);
    await tester.tap(find.text('Design crew').last);
    await tester.pumpAndSettle();
    expect(find.text('Call in progress · leo, Maya'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await settle(tester);
    expect(app.gateway.types, ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
    await finish(tester, app);
  });

  testWidgets('in do not disturb an incoming call shows without buzzing', (tester) async {
    var buzzes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') buzzes++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final app = await pumpApp(tester);
    app.repository.profile.value = FakeRepository.me.withStatus(Presence.doNotDisturb);
    app.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
      ),
    );
    await settle(tester);
    expect(find.text('Incoming call'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(buzzes, 0);

    // Back to online while it rings, it buzzes.
    app.repository.profile.value = FakeRepository.me.withStatus(Presence.online);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(buzzes, greaterThan(0));
    await finish(tester, app);
  });
}

/// A recorder that only counts its starts.
class _Recorder implements VoiceRecorder {
  final void Function() onStart;
  final void Function()? onCancel;
  _Recorder(this.onStart, {this.onCancel});

  @override
  Future<bool> start() async {
    onStart();
    return true;
  }

  @override
  Stream<double> get levels => const Stream.empty();

  @override
  Future<Recording?> stop() async => null;

  @override
  Future<void> cancel() async => onCancel?.call();
}
