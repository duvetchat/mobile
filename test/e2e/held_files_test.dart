import 'package:duvet/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

// What a chat shows of an encrypted message once its row is read again (ChatMessage.heldAs, chat_view's _readAgain):
// the files and the voice note the row brings, which a message that came live before the device held its row lacked
// until its chat was opened again (mobile#404).

const _row = 'https://api.test/attachments/f?sig=1';

ChatMessage _message({List<MessageAttachment> files = const [], bool voice = false, bool loading = false}) =>
    ChatMessage(
      id: 'm',
      authorId: 'a',
      authorName: 'Ana',
      content: '',
      createdAt: DateTime(2026, 11, 28),
      attachments: files,
      isVoice: voice,
      loading: loading,
    );

MessageAttachment _file(String id, {String url = _row}) =>
    MessageAttachment(id: id, filename: 'voice-note.webm', contentType: 'audio/webm', url: url, sizeBytes: 10);

void main() {
  test('a_live_message_takes_the_files_and_the_voice_note_its_row_brings', () {
    final live = _message(loading: true);
    final shown = live.heldAs(_message(files: [_file('f')], voice: true));
    expect(shown.attachments.map((a) => a.id), ['f']);
    expect(shown.isVoice, isTrue);
    expect(shown.loading, isFalse);
  });

  test("a_file_shown_at_a_renewed_link_keeps_it_when_its_row_is_read_again", () {
    final renewed = _message(files: [_file('f', url: 'https://api.test/attachments/f?sig=2')]);
    expect(identical(renewed.heldAs(_message(files: [_file('f')])), renewed), isTrue);
  });

  test('a_file_shown_at_no_link_takes_the_one_its_row_has', () {
    final unavailable = _message(files: [_file('f', url: '')]);
    expect(unavailable.heldAs(_message(files: [_file('f')])).attachments.single.url, _row);
  });

  test("the_files_a_row_brings_beside_one_shown_keep_that_one's_link", () {
    final renewed = _file('f', url: 'https://api.test/attachments/f?sig=2');
    final shown = _message(files: [renewed]).heldAs(_message(files: [_file('f'), _file('g')]));
    expect(shown.attachments.map((a) => a.id), ['f', 'g']);
    expect(identical(shown.attachments.first, renewed), isTrue);
  });

  test("the_API's_copy_of_a_message_keeps_the_files_and_the_voice_note_the_chat_shows", () {
    final copy = _message();
    final shown = copy.heldAs(_message(files: [_file('f')], voice: true));
    expect(shown.attachments.single.id, 'f');
    expect(shown.isVoice, isTrue);
  });
}
