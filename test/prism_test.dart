// Prism, the light a mention of the user throws on its bubble: how it arrives,
// and which mentions arrive.
import 'package:duvet/chat_view.dart' show unreadMentions;
import 'package:duvet/data/models.dart';
import 'package:duvet/widgets/prism.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  group('arrival', () {
    test('the spill waits 250 ms unlit, then comes up over 900', () {
      expect(prismSpillAt(0), 0);
      expect(prismSpillAt(250), 0);
      expect(prismSpillAt(700), inExclusiveRange(0, 1));
      expect(prismSpillAt(prismArrival.inMilliseconds.toDouble()), 1);
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
