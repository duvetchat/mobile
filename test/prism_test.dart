// Prism, the gem a mention of the user is cut into: where its light is, how it
// arrives, and which mentions arrive.
import 'package:duvet/chat_view.dart' show unreadMentions;
import 'package:duvet/data/models.dart';
import 'package:duvet/widgets/prism.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  group('light', () {
    // The rim's white stop sits 66° into its sweep.
    double hotSpot(double t) => (prismLight(t).angle + 66) % 360;

    test('mid-list, the rim\'s hot spot is at about 10 o\'clock, the side lights halfway', () {
      expect(prismLight(0.5).angle, -124);
      expect(prismLight(0.5).slide, 0.5);
      // 10 o'clock is 300° clockwise from 12.
      expect(hotSpot(0.5), closeTo(300, 5));
    });

    test('it travels clockwise as the bubble moves up the list', () {
      expect(hotSpot(0.25), greaterThan(hotSpot(0.5)));
      expect(hotSpot(0.75), lessThan(hotSpot(0.5)));
      expect(prismLight(0).slide, 1);
      expect(prismLight(1).slide, 0);
    });
  });

  group('arrival', () {
    test('starts unlit, turned back 200°', () {
      final start = prismArrivalAt(0);
      expect(start.offset, -200);
      expect(start.glint, 0);
      expect(start.spill, 0);
      // The turn waits 80 ms, the glint 150, the spill 250.
      expect(prismArrivalAt(80).offset, -200);
      expect(prismArrivalAt(81).offset, greaterThan(-200));
      expect(prismArrivalAt(150).glint, 0);
      expect(prismArrivalAt(250).spill, 0);
      expect(prismArrivalAt(260).spill, greaterThan(0));
    });

    test('the glint crosses the gem in 900 ms, brightest 15% in', () {
      expect(prismArrivalAt(150).glintAt, -1.6);
      expect(prismArrivalAt(150 + 135).glint, closeTo(1, 0.01));
      expect(prismArrivalAt(600).glint, inExclusiveRange(0, 1));
      expect(prismArrivalAt(1050).glintAt, closeTo(2.8, 1e-9));
      expect(prismArrivalAt(1050).glint, closeTo(0, 0.01));
    });

    test('ends at rest: no turn left, no glint, all of the spill', () {
      expect(prismArrivalAt(1150).spill, 1);
      final rest = prismArrivalAt(prismArrival.inMilliseconds.toDouble());
      expect(rest.offset, 0);
      expect(rest.glint, 0);
      expect(rest.spill, 1);
    });
  });

  group('unread mentions', () {
    final me = FakeRepository.me.id;
    ChatMessage from(String id, String text, {String? author, MessageReply? reply}) =>
        FakeRepository.message(id, author: author ?? FakeRepository.maya, name: 'Maya', text: text, reply: reply);
    final messages = [
      from('m1', 'old <@$me>'),
      from('m2', 'nothing here'),
      from('m3', 'you <@$me>'),
      from('m4', '<@${FakeRepository.leo}> not you'),
      // A reply to the user that mentions them counts, as on the server.
      from(
        'm5',
        'agreed',
        reply: MessageReply(messageId: 'm0', authorId: me, authorName: 'Gaby', content: 'hm', mentionAuthor: true),
      ),
      // Their own never does.
      from('m6', 'me <@$me>', author: me),
    ];

    test('the newest ones, as many as the chat has unread', () {
      expect(unreadMentions(messages, me, 2), {'m5', 'm3'});
      expect(unreadMentions(messages, me, 9), {'m5', 'm3', 'm1'});
    });

    test('none when the chat has none unread, or nobody is signed in', () {
      expect(unreadMentions(messages, me, 0), isEmpty);
      expect(unreadMentions(messages, null, 2), isEmpty);
    });
  });
}
