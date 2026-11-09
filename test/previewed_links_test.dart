import 'package:duvet/data/models.dart';
import 'package:duvet/widgets/link_embeds.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gif = 'https://example.invalid/wave.gif';
  const picture = MessageEmbed(url: gif, imageUrl: gif);
  const article = MessageEmbed(url: 'https://example.invalid/post', title: 'A post', imageUrl: gif);

  test('a picture or GIF link its preview stands in for goes; the words around it stay', () {
    expect(withoutPreviewedLinks(gif, [picture]), '');
    expect(withoutPreviewedLinks('lol $gif', [picture]), 'lol');
    expect(withoutPreviewedLinks('$gif\nso true', [picture]), 'so true');
    expect(withoutPreviewedLinks('look at $gif and laugh', [picture]), 'look at $gif and laugh');
    expect(withoutPreviewedLinks('```\n$gif\n```', [picture]), '```\n$gif\n```');
  });

  test('an article keeps its link; Tenor\'s embed, which names none, takes the only link', () {
    expect(withoutPreviewedLinks('https://example.invalid/post', [article]), 'https://example.invalid/post');
    expect(
      withoutPreviewedLinks('https://tenor.com/view/wave-123', const [
        MessageEmbed(imageUrl: gif, videoUrl: 'https://example.invalid/wave.mp4'),
      ]),
      '',
    );
  });

  test('a card with an author, fields or a footer keeps its link, picture or not', () {
    const post = 'https://example.invalid/post';
    for (final card in const [
      MessageEmbed(url: post, imageUrl: gif, authorName: 'CI'),
      MessageEmbed(url: post, imageUrl: gif, fields: [(name: 'Branch', value: 'dev', inline: true)]),
      MessageEmbed(url: post, imageUrl: gif, footer: 'GitHub'),
    ]) {
      expect(withoutPreviewedLinks(post, [card]), post);
    }
  });

  test('an invite goes for its card, unless there\'s no card', () {
    const invite = 'https://duvet.chat/invite?code=abc';
    expect(withoutPreviewedLinks('join us $invite', const []), 'join us');
    expect(withoutPreviewedLinks('join us $invite', const [], cards: false), 'join us $invite');
  });
}
