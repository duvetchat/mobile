import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

/// The desktop's languages (its `markdown.ts` LANGS), and Dart. Their
/// aliases come with them: `js`, `jsx`, `ts`, `tsx`, `sh`, `html`, `toml`…
/// Svelte and Zig, which highlight.js has no rules for, stay plain.
final _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'dockerfile': langDockerfile,
    'go': langGo,
    'graphql': langGraphql,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'lua': langLua,
    'markdown': langMarkdown,
    'php': langPhp,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

// GitHub's colors, as the desktop's theme has them, without their own
// background: the code block keeps the app's.
final _dark = {...githubDarkTheme}..remove('root');
final _light = {...githubTheme}..remove('root');

/// [code] in [language]'s colors, over [base]; null for a language it
/// doesn't know, which then shows plain.
TextSpan? highlightCode(String code, String language, {required TextStyle base, required bool dark}) {
  final name = language.toLowerCase();
  if (_highlight.getLanguage(name) == null) return null;
  final renderer = TextSpanRenderer(base, dark ? _dark : _light);
  _highlight.highlight(code: code, language: name).render(renderer);
  return renderer.span;
}
