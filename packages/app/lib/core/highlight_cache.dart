import 'dart:collection';

import 'package:highlighting/highlighting.dart';

import 'tool_call_parsers.dart';

const maxHighlightChars = 100000;
const _maxCachedHighlights = 200;

final class KeyedHighlightToken {
  const KeyedHighlightToken({required this.key, required this.token});

  final String key;
  final ToolDiffToken token;
}

final class KeyedHighlightLine {
  const KeyedHighlightLine({required this.key, required this.tokens});

  final String key;
  final List<KeyedHighlightToken> tokens;
}

const _languageByExtension = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'c': 'c',
  'h': 'c',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'hxx': 'cpp',
  'm': 'cpp',
  'mm': 'cpp',
  'json': 'json',
  'css': 'css',
  'scss': 'scss',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'java': 'java',
  'py': 'python',
  'go': 'go',
  'php': 'php',
  'yaml': 'yaml',
  'yml': 'yaml',
  'rs': 'rust',
  'swift': 'swift',
  'dart': 'dart',
  'cs': 'csharp',
  'ex': 'elixir',
  'exs': 'elixir',
  'md': 'markdown',
  'mdx': 'markdown',
};

final LinkedHashMap<String, List<List<ToolDiffToken>>> _tokenizationCache =
    LinkedHashMap();

String? extensionFromPath(String? filePath) {
  if (filePath == null || filePath.isEmpty) return null;
  final name = filePath.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

bool isHighlightLanguageSupported(String? extension) =>
    extension != null && _languageByExtension.containsKey(extension);

List<List<ToolDiffToken>>? tokenizeToLines(String code, String? extension) {
  if (!isHighlightLanguageSupported(extension) ||
      code.length > maxHighlightChars) {
    return null;
  }
  final cacheKey = '$extension:$code';
  final cached = _tokenizationCache.remove(cacheKey);
  if (cached != null) {
    _tokenizationCache[cacheKey] = cached;
    return cached;
  }

  try {
    final result = highlight.parse(
      code,
      languageId: _languageByExtension[extension]!,
    );
    final lines = <List<ToolDiffToken>>[<ToolDiffToken>[]];
    _flattenNode(result.rootNode, null, lines);
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].isEmpty) {
        lines[index] = const [ToolDiffToken(text: '')];
      }
    }
    if (_tokenizationCache.length >= _maxCachedHighlights) {
      _tokenizationCache.remove(_tokenizationCache.keys.first);
    }
    _tokenizationCache[cacheKey] = lines;
    return lines;
  } on Object {
    return null;
  }
}

List<KeyedHighlightLine>? highlightToKeyedLines(
  String code,
  String? extension,
) {
  final lines = tokenizeToLines(code, extension);
  if (lines == null) return null;
  return [
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++)
      KeyedHighlightLine(
        key: 'line-$lineIndex',
        tokens: [
          for (
            var tokenIndex = 0;
            tokenIndex < lines[lineIndex].length;
            tokenIndex++
          )
            KeyedHighlightToken(
              key: '$lineIndex-$tokenIndex',
              token: lines[lineIndex][tokenIndex],
            ),
        ],
      ),
  ];
}

void _flattenNode(
  Node node,
  String? inheritedStyle,
  List<List<ToolDiffToken>> lines,
) {
  final style = _tokenStyle(node.className) ?? inheritedStyle;
  if (node.value case final value?) {
    _appendText(value, style, lines);
  }
  for (final child in node.children) {
    _flattenNode(child, style, lines);
  }
}

void _appendText(String text, String? style, List<List<ToolDiffToken>> lines) {
  final parts = text.split('\n');
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.isNotEmpty) {
      final line = lines.last;
      if (line.isNotEmpty && line.last.style == style) {
        final previous = line.removeLast();
        line.add(ToolDiffToken(text: previous.text + part, style: style));
      } else {
        line.add(ToolDiffToken(text: part, style: style));
      }
    }
    if (index < parts.length - 1) lines.add(<ToolDiffToken>[]);
  }
}

String? _tokenStyle(String? scope) {
  if (scope == null || scope.isEmpty) return null;
  final parts = scope.split('.');
  bool has(String value) => parts.contains(value);
  if (has('keyword')) return 'keyword';
  if (has('comment') || has('doctag')) return 'comment';
  if (has('string') || has('quote')) return 'string';
  if (has('number')) return 'number';
  if (has('literal') || has('built_in') || has('symbol')) return 'literal';
  if (has('function')) return 'function';
  if (has('class')) return 'class';
  if (has('title') || has('name')) return 'definition';
  if (has('type')) return 'type';
  if (has('tag')) return 'tag';
  if (has('attr') || has('attribute')) return 'attribute';
  if (has('property')) return 'property';
  if (has('variable') || has('params') || has('subst')) return 'variable';
  if (has('operator')) return 'operator';
  if (has('punctuation') || has('bullet')) return 'punctuation';
  if (has('regexp')) return 'regexp';
  if (has('escape') || has('char')) return 'escape';
  if (has('meta')) return 'meta';
  if (has('section')) return 'heading';
  if (has('link')) return 'link';
  return null;
}
