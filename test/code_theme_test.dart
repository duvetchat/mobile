import 'dart:convert';

import 'package:duvet/data/appearance.dart' show bubbleColors, bubbleDarkInk;
import 'package:duvet/data/code_theme.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/code_highlight.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// A VS Code theme as people write them: comments, trailing commas, a link in
// a string that must survive the comment stripping.
const _fixture = r'''
{
  // One Light, cut down.
  "name": "Fixture", /* from https://example.com */
  "homepage": "https://example.com/theme",
  "type": "light",
  "colors": { "editor.foreground": "#383A42", },
  "tokenColors": [
    { "settings": { "foreground": "#000000" } },
    { "scope": "comment, punctuation.definition.comment", "settings": { "foreground": "#A0A1A7" } },
    { "scope": ["comment"], "settings": { "fontStyle": "italic" } },
    { "scope": ["keyword", "storage.type"], "settings": { "foreground": "#A626A4" } },
    { "scope": "keyword.operator", "settings": { "foreground": "#0184BC80" } },
    { "scope": "string", "settings": { "foreground": "#50A14F" } },
    { "scope": "entity.name.function", "settings": { "foreground": "#4078F2", "fontStyle": "bold" } },
    { "scope": "entity.name.type.class", "settings": { "foreground": "#C18401" } },
    { "scope": "variable.language", "settings": { "foreground": "#E45649" } },
    { "scope": "meta.tag string", "settings": { "foreground": "#FF0000" } },
    { "scope": "constant.numeric", "settings": { "foreground": "#986801" } },
  ],
}
''';

/// Every key re_highlight's languages color: the renderer matches them
/// exactly, so a theme must fill each one.
const _keys = [
  'doctag',
  'keyword',
  'meta-keyword',
  'template-tag',
  'template-variable',
  'type',
  'variable.language_',
  'title',
  'title.class_',
  'title.class_.inherited__',
  'title.function_',
  'attr',
  'attribute',
  'literal',
  'meta',
  'number',
  'operator',
  'variable',
  'selector-attr',
  'selector-class',
  'selector-id',
  'regexp',
  'string',
  'meta-string',
  'built_in',
  'symbol',
  'comment',
  'code',
  'formula',
  'name',
  'quote',
  'selector-tag',
  'selector-pseudo',
  'subst',
  'section',
  'bullet',
  'emphasis',
  'strong',
  'addition',
  'deletion',
];

void main() {
  test('JSONC: comments go, strings and their // stay, trailing commas go', () {
    final json = jsonDecode(stripJsonc(_fixture)) as Map;
    expect(json['homepage'], 'https://example.com/theme');
    expect((json['tokenColors'] as List).length, 11);
  });

  test('a VS Code theme fills every key, by the longest matching scope', () {
    final theme = CodeTheme.parse('https://example.com/t.json', _fixture);
    expect(theme.dark, isFalse);
    expect(theme.styles.keys, containsAll(_keys));
    Color? color(String key) => theme.styles[key]?.color;

    // Its color and its italics come from two entries.
    expect(color('comment'), const Color(0xFFA0A1A7));
    expect(theme.styles['comment']?.fontStyle, FontStyle.italic);
    // An array of scopes, and a comma-separated one.
    expect(color('keyword'), const Color(0xFFA626A4));
    expect(color('type'), const Color(0xFFA626A4), reason: 'storage.type');
    // keyword.operator is longer than keyword; its alpha comes last in VS Code.
    expect(color('operator'), const Color(0x800184BC));
    expect(color('string'), const Color(0xFF50A14F));
    expect(color('meta-string'), const Color(0xFF50A14F));
    expect(color('regexp'), const Color(0xFF50A14F), reason: 'string.regexp falls to string');
    expect(color('title.function_'), const Color(0xFF4078F2));
    expect(theme.styles['title.function_']?.fontWeight, FontWeight.bold);
    expect(color('title.class_'), const Color(0xFFC18401));
    expect(color('variable.language_'), const Color(0xFFE45649));
    expect(color('number'), const Color(0xFF986801));
    // No rule: the editor's foreground, not the scopeless rule's, and never a
    // descendant selector's.
    expect(color('literal'), const Color(0xFF383A42));
    expect(color('name'), const Color(0xFF383A42));
    expect(theme.styles['emphasis']?.fontStyle, FontStyle.italic);
    expect(theme.styles['strong']?.fontWeight, FontWeight.bold);
  });

  test('no type is dark; no editor.foreground takes the scopeless rule', () {
    final theme = CodeTheme.parse('u', '{"tokenColors": [{"settings": {"foreground": "#abc"}}]}');
    expect(theme.dark, isTrue);
    expect(theme.styles['keyword']?.color, const Color(0xFFAABBCC));
  });

  test('not a theme: a FormatException', () {
    expect(() => CodeTheme.parse('u', '<html></html>'), throwsFormatException);
    expect(() => CodeTheme.parse('u', '{"name": "no tokens"}'), throwsFormatException);
  });

  test('fetching: web links only, a 200 only', () async {
    final client = MockClient(
      (r) async => r.url.path == '/t.json' ? http.Response(_fixture, 200) : http.Response('gone', 404),
    );
    await expectLater(fetchCodeTheme('ftp://example.com/t.json', client), throwsFormatException);
    await expectLater(fetchCodeTheme('not a link', client), throwsFormatException);
    await expectLater(fetchCodeTheme('https://example.com/nope.json', client), throwsA(isA<http.ClientException>()));
    final got = await fetchCodeTheme(' https://example.com/t.json ', client);
    expect(got.theme.url, 'https://example.com/t.json');
    expect(got.json, _fixture);
  });

  test('code takes the custom theme on a surface of its darkness only', () {
    final theme = CodeTheme.parse('u', _fixture);
    const base = TextStyle(color: Color(0xFF000000));
    Color? keyword(TextSpan span) {
      if (span.text == 'func') return span.style?.color;
      for (final c in span.children ?? const <InlineSpan>[]) {
        if (keyword(c as TextSpan) case final color?) return color;
      }
      return null;
    }

    expect(
      keyword(highlightCode('func main() {}', 'go', base: base, dark: false, custom: theme)!),
      const Color(0xFFA626A4),
    );
    expect(
      keyword(highlightCode('func main() {}', 'go', base: base, dark: true, custom: theme)!),
      isNot(const Color(0xFFA626A4)),
    );
  });

  test('your bubble: azure with white as today; a pale swatch gets dark ink', () {
    expect(bubbleColors(null), (fill: Duvet.azure, ink: const Color(0xFFFFFFFF), onDark: true));
    expect(bubbleColors(0xD6A400), (fill: const Color(0xFFD6A400), ink: bubbleDarkInk, onDark: false));
    expect(bubbleColors(0x8E4EC6).ink, const Color(0xFFFFFFFF));
  });
}
