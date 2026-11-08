import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

/// A VS Code color theme, turned into re_highlight's styles: code blocks
/// take it on surfaces of its own [dark]ness, as the desktop's custom theme.
class CodeTheme {
  /// Where it came from.
  final String url;
  final bool dark;
  final Map<String, TextStyle> styles;
  const CodeTheme({required this.url, required this.dark, required this.styles});

  /// [text] (a VS Code theme, comments and trailing commas allowed) from
  /// [url]; a [FormatException] when it isn't one.
  factory CodeTheme.parse(String url, String text) {
    final json = jsonDecode(stripJsonc(text));
    if (json is! Map || json['tokenColors'] is! List) throw const FormatException('No tokenColors');
    return CodeTheme(url: url, dark: json['type'] != 'light', styles: themeFromVsCode(json));
  }
}

/// Fetches the theme at [url]. Throws when it can't be had or read.
Future<({CodeTheme theme, String json})> fetchCodeTheme(String url, http.Client client) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
    throw const FormatException('Not a web address');
  }
  final response = await client.get(uri).timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) throw http.ClientException('Answered ${response.statusCode}', uri);
  // A theme is a few tens of KB; anything this big isn't one.
  if (response.bodyBytes.length > 1 << 20) throw const FormatException('Too big');
  final text = utf8.decode(response.bodyBytes, allowMalformed: true);
  return (theme: CodeTheme.parse(uri.toString(), text), json: text);
}

/// [text] without its `//` and `/* */` comments (outside strings) and the
/// commas before a `}` or `]`: JSONC as plain JSON. Ported from the desktop's
/// `markdown.ts`.
String stripJsonc(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    if (text[i] == '"') {
      final start = i++;
      while (i < text.length && text[i] != '"') {
        if (text[i] == '\\') i++;
        i++;
      }
      i++;
      out.write(text.substring(start, i > text.length ? text.length : i));
    } else if (text.startsWith('//', i)) {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
    } else if (text.startsWith('/*', i)) {
      i += 2;
      while (i < text.length && !text.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else if (text[i] == ',') {
      // Trailing comma: drop it when the next non-space char closes a container.
      var j = i + 1;
      while (j < text.length && ' \t\r\n'.contains(text[j])) {
        j++;
      }
      if (j >= text.length || (text[j] != '}' && text[j] != ']')) out.write(',');
      i++;
    } else {
      out.write(text[i++]);
    }
  }
  return out.toString();
}

/// Each re_highlight key and the TextMate scopes to color it by, the first
/// the theme has a rule for winning. The renderer looks keys up exactly, with
/// no fallback to a parent, so the dotted ones are all here too.
const _scopes = <String, List<String>>{
  'doctag': ['comment.block.documentation', 'storage.type.class.jsdoc', 'keyword'],
  'keyword': ['keyword', 'keyword.control', 'storage'],
  'meta-keyword': ['keyword.control.directive', 'keyword'],
  'template-tag': ['keyword', 'storage'],
  'template-variable': ['variable.other', 'variable'],
  'type': ['entity.name.type', 'support.type', 'storage.type'],
  'variable.language_': ['variable.language'],
  'title': ['entity.name.function', 'entity.name'],
  'title.class_': ['entity.name.class', 'entity.name.type.class', 'entity.name.type'],
  'title.class_.inherited__': ['entity.other.inherited-class', 'entity.name.class', 'entity.name.type'],
  'title.function_': ['entity.name.function', 'support.function'],
  'attr': ['entity.other.attribute-name', 'variable.other.property'],
  'attribute': ['entity.other.attribute-name'],
  'literal': ['constant.language', 'constant'],
  'meta': ['meta.preprocessor', 'keyword.control.directive'],
  'number': ['constant.numeric', 'constant'],
  'operator': ['keyword.operator'],
  'variable': ['variable.other', 'variable'],
  'selector-attr': ['entity.other.attribute-name'],
  'selector-class': ['entity.other.attribute-name.class.css', 'entity.other.attribute-name'],
  'selector-id': ['entity.other.attribute-name.id.css', 'entity.other.attribute-name'],
  'regexp': ['string.regexp', 'string'],
  'string': ['string.quoted', 'string'],
  'meta-string': ['string'],
  'built_in': ['support.function.builtin', 'support.function', 'support'],
  'symbol': ['constant.other.symbol', 'constant'],
  'comment': ['comment'],
  'code': ['markup.inline.raw', 'markup.raw', 'comment'],
  'formula': ['comment'],
  'name': ['entity.name.tag'],
  'quote': ['markup.quote', 'comment'],
  'selector-tag': ['entity.name.tag.css', 'entity.name.tag'],
  'selector-pseudo': ['entity.other.attribute-name.pseudo-class', 'entity.other.attribute-name'],
  'subst': ['meta.embedded', 'punctuation.section.embedded'],
  'section': ['markup.heading', 'entity.name.section'],
  'bullet': ['markup.list', 'punctuation.definition.list'],
  'emphasis': ['markup.italic'],
  'strong': ['markup.bold'],
  'addition': ['markup.inserted'],
  'deletion': ['markup.deleted'],
};

/// [theme]'s `tokenColors` as a style for every re_highlight key; a key it
/// has no rule for takes `editor.foreground`.
Map<String, TextStyle> themeFromVsCode(Map theme) {
  final rules = <String, Map>{};
  Color? foreground = _color((theme['colors'] as Map?)?['editor.foreground']);
  for (final entry in theme['tokenColors'] as List? ?? const []) {
    if (entry is! Map || entry['settings'] is! Map) continue;
    final settings = entry['settings'] as Map;
    final scope = entry['scope'];
    final selectors = switch (scope) {
      String s => s.split(','),
      List l => l.whereType<String>(),
      _ => null,
    };
    // The rule with no scope is the theme's default text.
    if (selectors == null) {
      foreground ??= _color(settings['foreground']);
      continue;
    }
    for (final s in selectors.map((s) => s.trim())) {
      // re_highlight has no nesting to match "a b" or exclusions against.
      if (s.isEmpty || s.contains(' ') || s.startsWith('-')) continue;
      // Later entries add to earlier ones: a color here, italics there.
      (rules[s] ??= {}).addAll(settings);
    }
  }

  // [property] for [scope], each property on its own as VS Code does: from
  // the longest selector it starts with, at a dot, that sets it.
  Object? valueFor(String scope, String property) {
    String? best;
    for (final MapEntry(key: s, value: settings) in rules.entries) {
      if ((scope == s || scope.startsWith('$s.')) &&
          settings.containsKey(property) &&
          s.length > (best?.length ?? -1)) {
        best = s;
      }
    }
    return best == null ? null : rules[best]![property];
  }

  return {
    for (final MapEntry(key: key, value: scopes) in _scopes.entries)
      key: () {
        Object? first(String property) => scopes.map((s) => valueFor(s, property)).nonNulls.firstOrNull;
        final style = '${first('fontStyle') ?? ''}';
        return TextStyle(
          color: _color(first('foreground')) ?? foreground,
          fontStyle: style.contains('italic') || key == 'emphasis' ? FontStyle.italic : null,
          fontWeight: style.contains('bold') || key == 'strong' ? FontWeight.bold : null,
        );
      }(),
  };
}

/// `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA` as a [Color].
Color? _color(Object? hex) {
  if (hex is! String || !hex.startsWith('#')) return null;
  var h = hex.substring(1);
  if (h.length == 3 || h.length == 4) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = '${h}ff';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  // VS Code's alpha comes last; Flutter's first.
  return v == null ? null : Color(((v & 0xFF) << 24) | (v >> 8));
}
