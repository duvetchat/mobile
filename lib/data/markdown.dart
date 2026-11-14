/// Message markdown, as the desktop app's `markdown.ts` reads it: `**bold**`,
/// `*italic*` and `_italic_`, `__underline__`, `~~strike~~`, `||spoiler||`,
/// `` `code` ``, fenced code blocks, `> quotes`, lists, `# headings`, `-#`
/// subtext, `[text](https://…)`, bare links and `\` escapes.
///
/// Mentions (`<@id>`) and custom emoji (`<:id:>`) stay in the text leaves; the
/// renderer tokenizes those.
library;

sealed class MdInline {
  const MdInline();
}

final class MdText extends MdInline {
  final String text;
  const MdText(this.text);
}

enum MdStyle { bold, italic, underline, strike }

final class MdStyled extends MdInline {
  final Set<MdStyle> styles;
  final List<MdInline> children;
  const MdStyled(this.styles, this.children);
}

final class MdSpoiler extends MdInline {
  final List<MdInline> children;
  const MdSpoiler(this.children);
}

final class MdCode extends MdInline {
  final String code;
  const MdCode(this.code);
}

final class MdLink extends MdInline {
  final String url;
  final List<MdInline> children;
  const MdLink(this.url, this.children);
}

sealed class MdBlock {
  const MdBlock();
}

/// Lines of text, joined by line breaks.
final class MdParagraph extends MdBlock {
  final List<MdInline> inlines;
  const MdParagraph(this.inlines);
}

final class MdHeading extends MdBlock {
  final int level;
  final List<MdInline> inlines;
  const MdHeading(this.level, this.inlines);
}

/// `-# small print`.
final class MdSubtext extends MdBlock {
  final List<MdInline> inlines;
  const MdSubtext(this.inlines);
}

final class MdQuote extends MdBlock {
  final List<MdInline> inlines;
  const MdQuote(this.inlines);
}

final class MdList extends MdBlock {
  final bool ordered;
  final List<List<MdInline>> items;
  const MdList({required this.ordered, required this.items});
}

enum MdAlign { start, center, end }

/// A `| a | b |` table: its header, then its rows, each cell aligned as the
/// `|:--|:-:|--:|` line under the header says (null: as the text goes).
final class MdTable extends MdBlock {
  final List<List<MdInline>> header;
  final List<MdAlign?> aligns;
  final List<List<List<MdInline>>> rows;
  const MdTable({required this.header, required this.aligns, required this.rows});
}

final class MdCodeBlock extends MdBlock {
  final String? language;
  final String code;
  const MdCodeBlock(this.code, {this.language});
}

// A ``` after an odd number of backslashes is escaped, and opens no block.
final _fence = RegExp(r'(?<!(?:^|[^\\])\\(?:\\\\)*)```([\w+#-]*)\n?([\s\S]*?)```');
final _ul = RegExp(r'^\s*[-*]\s+(.*)$');
final _ol = RegExp(r'^\s*\d+[.)]\s+(.*)$');
final _tableRule = RegExp(r'^(?=.*\|)(?=.*-)[\s|:-]+$');

/// A table line's cells, its outer `|`s dropped.
List<String> _cells(String line) => [
  for (final c in line.trim().replaceFirst(RegExp(r'^\|'), '').replaceFirst(RegExp(r'\|$'), '').split('|')) c.trim(),
];

/// The blocks of a message.
List<MdBlock> parseMarkdown(String input) {
  final blocks = <MdBlock>[];
  var last = 0;
  for (final m in _fence.allMatches(input)) {
    _parseLines(input.substring(last, m.start), blocks);
    final lang = m.group(1)!;
    blocks.add(MdCodeBlock(m.group(2)!.replaceFirst(RegExp(r'\n$'), ''), language: lang.isEmpty ? null : lang));
    last = m.end;
  }
  _parseLines(input.substring(last), blocks);
  return blocks;
}

/// A message on one line, as a reply's quote shows it: code blocks as inline
/// code; headings, quotes and lists as plain text.
List<MdInline> parseLine(String input) => parseInline(
  input
      .replaceAllMapped(_fence, (m) => '`${m.group(2)!.trim().replaceAll(RegExp(r'\s+'), ' ')}`')
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^(?:#{1,3} |-# |>>> |> |\s*[-*]\s+|\s*\d+[.)]\s+)'), ''))
      .join(' '),
);

void _parseLines(String text, List<MdBlock> blocks) {
  if (text.trim().isEmpty) return;
  // Masked before the lines are read, so an escaped `|` is a table cell's text.
  text = _mask(text);
  // A fence's own line break isn't a blank line of the text around it.
  final lines = text.replaceFirst(RegExp(r'^\n'), '').replaceFirst(RegExp(r'\n$'), '').split('\n');
  final paragraph = <String>[];
  final quote = <String>[];

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MdParagraph(_inline(paragraph.join('\n'))));
      paragraph.clear();
    }
    if (quote.isNotEmpty) {
      blocks.add(MdQuote(_inline(quote.join('\n'))));
      quote.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    // A table, as the desktop reads one: a line with a `|`, then one of only
    // `|`, `:`, `-` and spaces; its rows are the lines with a `|` after.
    if (line.contains('|') && i + 1 < lines.length && _tableRule.hasMatch(lines[i + 1])) {
      flush();
      final aligns = [
        for (final c in _cells(lines[i + 1]))
          switch ((c.startsWith(':'), c.endsWith(':'))) {
            (true, true) => MdAlign.center,
            (false, true) => MdAlign.end,
            (true, false) => MdAlign.start,
            (false, false) => null,
          },
      ];
      final header = [for (final c in _cells(line)) _inline(c)];
      final rows = <List<List<MdInline>>>[];
      for (i += 2; i < lines.length && lines[i].contains('|'); i++) {
        rows.add([for (final c in _cells(lines[i])) _inline(c)]);
      }
      blocks.add(MdTable(header: header, aligns: aligns, rows: rows));
      continue;
    }
    final list = _ul.hasMatch(line) ? _ul : (_ol.hasMatch(line) ? _ol : null);
    if (list != null) {
      flush();
      final items = <List<MdInline>>[];
      while (i < lines.length) {
        final m = list.firstMatch(lines[i]);
        if (m == null) break;
        items.add(_inline(m.group(1)!));
        i++;
      }
      blocks.add(MdList(ordered: identical(list, _ol), items: items));
      continue;
    }
    if (RegExp(r'^(#{1,3}) (.*)$').firstMatch(line) case final m?) {
      flush();
      blocks.add(MdHeading(m.group(1)!.length, _inline(m.group(2)!)));
    } else if (RegExp(r'^-# (.*)$').firstMatch(line) case final m?) {
      flush();
      blocks.add(MdSubtext(_inline(m.group(1)!)));
    } else if (RegExp(r'^(?:>>>|>) ?(.*)$').firstMatch(line) case final m?) {
      if (paragraph.isNotEmpty) {
        blocks.add(MdParagraph(_inline(paragraph.join('\n'))));
        paragraph.clear();
      }
      quote.add(m.group(1)!);
    } else {
      if (quote.isNotEmpty) {
        blocks.add(MdQuote(_inline(quote.join('\n'))));
        quote.clear();
      }
      paragraph.add(line);
    }
    i++;
  }
  flush();
}

typedef _Rule = (RegExp, MdInline Function(Match m));

// A backslash before ASCII punctuation, CommonMark's escape, makes it text,
// which opens and closes nothing, and the backslash goes; in code it's the
// code's. Not before `<`: the API reads `<@id>` after it as a mention, and
// notifies them, so the text shows it as one.
const _escapable = r'''!"#$%&'()*+,-./:;=>?@[\]^_`{|}~''';
final _codeOrEscape = RegExp(r'''`[^`\n]+`|\\([!-/:;=-@\[-`{-~])''');

// Until it's a leaf, an escaped character stands in the text as the
// noncharacter U+FDD0 + its place in [_escapable], which no rule reads; a
// message's own noncharacters there go, so none can pass for one.
final _placeholder = RegExp('[\uFDD0-\uFDEF]');

// Left to right, so a ` after an odd number of backslashes is escaped and
// opens no code, and code keeps its backslashes.
String _mask(String s) => s
    .replaceAll(_placeholder, '')
    .replaceAllMapped(
      _codeOrEscape,
      (m) => m[1] == null ? m[0]! : String.fromCharCode(0xFDD0 + _escapable.indexOf(m[1]!)),
    );

// Text leaves, each escaped character one of its own, so no mention or emoji
// reads across it (`<\@id>` is text, as the API reads it).
void _text(List<MdInline> out, String s) {
  var at = 0;
  for (final m in _placeholder.allMatches(s)) {
    if (m.start > at) out.add(MdText(s.substring(at, m.start)));
    out.add(MdText(_escapable[m[0]!.codeUnitAt(0) - 0xFDD0]));
    at = m.end;
  }
  if (at < s.length) out.add(MdText(s.substring(at)));
}

// No code, link or URL holds an escape, as on the desktop: one ends a bare link.
final List<_Rule> _rules = [
  (RegExp(r'`([^`\n\uFDD0-\uFDEF]+)`'), (m) => MdCode(m.group(1)!)),
  (RegExp(r'\[([^\]\n]+)\]\((https?://[^)\s\uFDD0-\uFDEF]+)\)'), (m) => MdLink(m.group(2)!, _inline(m.group(1)!))),
  // A bare link ends before trailing punctuation; a balanced `(…)` stays in
  // it (Wikipedia's `Foo_(bar)`), while the `)` closing a sentence doesn't.
  (
    RegExp(
      r'''(?:https?|duvet)://(?:[^\s<>()\uFDD0-\uFDEF]|\([^\s<>()\uFDD0-\uFDEF]*\))*'''
      r'''(?:[^\s<>.,;:!?()\]}"'\uFDD0-\uFDEF]|\([^\s<>()\uFDD0-\uFDEF]*\))''',
    ),
    (m) => MdLink(m.group(0)!, [MdText(m.group(0)!)]),
  ),
  (RegExp(r'\*\*\*(.+?)\*\*\*', dotAll: true), (m) => MdStyled({MdStyle.bold, MdStyle.italic}, _inline(m.group(1)!))),
  (RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => MdStyled({MdStyle.bold}, _inline(m.group(1)!))),
  (RegExp(r'__(.+?)__', dotAll: true), (m) => MdStyled({MdStyle.underline}, _inline(m.group(1)!))),
  (RegExp(r'\*([^\s*](?:[^*]*[^\s*])?)\*', dotAll: true), (m) => MdStyled({MdStyle.italic}, _inline(m.group(1)!))),
  (
    RegExp(r'(?<![\w])_([^\s_](?:[^_]*[^\s_])?)_(?![\w])', dotAll: true),
    (m) => MdStyled({MdStyle.italic}, _inline(m.group(1)!)),
  ),
  (RegExp(r'~~(.+?)~~', dotAll: true), (m) => MdStyled({MdStyle.strike}, _inline(m.group(1)!))),
  (RegExp(r'\|\|(.+?)\|\|', dotAll: true), (m) => MdSpoiler(_inline(m.group(1)!))),
];

/// A line's inline markup.
List<MdInline> parseInline(String s) => _inline(_mask(s));

List<MdInline> _inline(String s) {
  final out = <MdInline>[];
  var pos = 0;
  while (pos < s.length) {
    // The earliest match wins; at a tie, the rule listed first.
    Match? best;
    _Rule? rule;
    for (final r in _rules) {
      final m = r.$1.allMatches(s, pos).firstOrNull;
      if (m != null && (best == null || m.start < best.start)) {
        best = m;
        rule = r;
      }
    }
    if (best == null || rule == null) {
      _text(out, s.substring(pos));
      break;
    }
    if (best.start > pos) _text(out, s.substring(pos, best.start));
    out.add(rule.$2(best));
    pos = best.end;
  }
  return out;
}

/// The plain text of some inlines, as a screen reader says them: a hidden
/// spoiler as "spoiler".
String plainInline(List<MdInline> inlines, {bool revealSpoilers = false}) {
  final b = StringBuffer();
  void walk(List<MdInline> list) {
    for (final i in list) {
      switch (i) {
        case MdText(:final text):
          b.write(text);
        case MdCode(:final code):
          b.write(code);
        case MdStyled(:final children) || MdLink(:final children):
          walk(children);
        case MdSpoiler(:final children):
          if (revealSpoilers) {
            walk(children);
          } else {
            b.write('spoiler');
          }
      }
    }
  }

  walk(inlines);
  return b.toString();
}
