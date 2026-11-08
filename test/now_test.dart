// Now and pinned chats: the helpers ported from the desktop's now.ts, and a
// pin on Chats.
import 'package:duvet/main.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/widgets/now.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'support/fake_repository.dart';

void main() {
  group('helpers', () {
    test('busiestRooms: empty rooms go, the busiest first, ties keep their order, capped', () {
      final counts = {'a': 1, 'b': 3, 'c': 0, 'd': 3, 'e': 2};
      expect(busiestRooms(counts.keys, (r) => counts[r]!), ['b', 'd', 'e']);
      expect(busiestRooms(counts.keys, (r) => counts[r]!, max: 10), ['b', 'd', 'e', 'a']);
    });

    test('liveIn: a screen beats a camera', () {
      const quiet = duvet.VoiceParticipant(userId: 'u', roomId: 'r');
      const cam = duvet.VoiceParticipant(userId: 'v', roomId: 'r', camera: true);
      const screen = duvet.VoiceParticipant(userId: 'w', roomId: 'r', screenSharing: true);
      expect(liveIn([quiet]), isNull);
      expect(liveIn([quiet, cam]), NowLive.camera);
      expect(liveIn([cam, screen]), NowLive.screen);
    });

    test('capFaces and fitFaces leave a place for the "+N"', () {
      expect(capFaces([1, 2, 3, 4, 5], 4), (faces: [1, 2, 3, 4], more: 1));
      expect(fitFaces([1, 2, 3], 3), (faces: [1, 2, 3], more: 0));
      expect(fitFaces([1, 2, 3, 4], 3), (faces: [1, 2], more: 2));
    });

    test('joinableCalls drops what is skipped; pinKey tells rooms from conversations', () {
      expect(joinableCalls({'a', 'b'}, (id) => id == 'a'), ['b']);
      expect(pinKey(const RoomTarget(spaceId: 's', roomId: 'r')), 'room:r');
      expect(pinKey(const ConversationTarget('c')), 'conv:c');
    });
  });

  testWidgets('long-press pins a chat to the top, and it stays after a refresh', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    double top(String t) => tester.getTopLeft(find.text(t).first).dy;
    expect(top('Design crew'), greaterThan(top('Maya')));

    await tester.longPress(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to top'));
    await tester.pumpAndSettle();
    expect(repository.pinnedChats.value, {'conv:c-team'});
    expect(top('Design crew'), lessThan(top('Maya')));

    // The list rebuilds with new data: the pin holds.
    repository.conversations.value = [...repository.conversations.value];
    await tester.pumpAndSettle();
    expect(top('Design crew'), lessThan(top('Maya')));

    await tester.longPress(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(repository.pinnedChats.value, isEmpty);
  });
}
