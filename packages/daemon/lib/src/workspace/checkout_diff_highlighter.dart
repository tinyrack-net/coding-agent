import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:highlighting/highlighting.dart';
import 'package:path/path.dart' as p;

import '../git/git_runner.dart';

/// Paseo-compatible server-side syntax highlighting for structured diffs.
///
/// Full old/new file contents are preferred so multiline parser state survives
/// hunk boundaries. Missing content falls back independently to reconstructed
/// hunk content, matching Paseo's diff highlighter.
final class CheckoutDiffHighlighter {
  const CheckoutDiffHighlighter({required this.runner});

  final GitRunner runner;

  Future<DiffResponse> highlight(
    DiffResponse response, {
    required String cwd,
    required CheckoutDiffCompare compare,
  }) async {
    if (!response.files.any(
      (file) => isCheckoutHighlightLanguageSupported(file.path),
    )) {
      return response;
    }

    final normalized = compare.normalized();
    final oldRef = normalized.mode == CheckoutDiffMode.uncommitted
        ? 'HEAD'
        : await _resolveMergeBase(cwd, normalized.baseRef ?? 'HEAD');
    final highlighted = await Future.wait([
      for (final file in response.files)
        _highlightWithContent(
          file,
          cwd: cwd,
          oldRef: oldRef,
          newRef: normalized.mode == CheckoutDiffMode.base ? 'HEAD' : null,
        ),
    ]);
    return DiffResponse(files: highlighted);
  }

  Future<DiffFile> _highlightWithContent(
    DiffFile file, {
    required String cwd,
    required String oldRef,
    required String? newRef,
  }) async {
    if (!isCheckoutHighlightLanguageSupported(file.path)) return file;

    final contents = await Future.wait<String?>([
      file.status == DiffFileStatus.added
          ? Future<String?>.value()
          : _readGitFile(cwd, oldRef, file.oldPath ?? file.path),
      file.status == DiffFileStatus.deleted
          ? Future<String?>.value()
          : newRef == null
          ? _readWorkingFile(cwd, file.path)
          : _readGitFile(cwd, newRef, file.path),
    ]);
    return highlightCheckoutDiffFile(
      file,
      oldFileContent: contents[0],
      newFileContent: contents[1],
    );
  }

  Future<String> _resolveMergeBase(String cwd, String baseRef) async {
    try {
      final result = await runner.run(
        ['merge-base', baseRef, 'HEAD'],
        cwd: cwd,
        check: false,
      );
      final resolved = result.stdout.trim();
      if (result.ok && resolved.isNotEmpty) return resolved;
    } on Object {
      // Fall through to the requested ref.
    }
    return baseRef;
  }

  Future<String?> _readGitFile(String cwd, String ref, String path) async {
    try {
      final result = await runner.run(
        ['show', '$ref:$path'],
        cwd: cwd,
        check: false,
      );
      return result.ok ? result.stdout : null;
    } on Object {
      return null;
    }
  }

  Future<String?> _readWorkingFile(String cwd, String path) async {
    try {
      return await File(p.join(cwd, path)).readAsString();
    } on Object {
      return null;
    }
  }
}

DiffFile highlightCheckoutDiffFile(
  DiffFile file, {
  String? oldFileContent,
  String? newFileContent,
}) {
  final extension = checkoutHighlightExtension(file.path);
  if (!isCheckoutHighlightLanguageSupported(file.path) ||
      file.binary ||
      file.tooLarge) {
    return file;
  }

  try {
    final reconstructed = _reconstructedTokenLookups(file, extension!);
    final oldTokens = oldFileContent == null
        ? reconstructed.oldTokens
        : _fullFileTokenLookup(oldFileContent, extension);
    final newTokens = newFileContent == null
        ? reconstructed.newTokens
        : _fullFileTokenLookup(newFileContent, extension);
    return _applyTokens(file, oldTokens: oldTokens, newTokens: newTokens);
  } on Object {
    return file;
  }
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

String? checkoutHighlightExtension(String? path) {
  if (path == null || path.isEmpty) return null;
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

bool isCheckoutHighlightLanguageSupported(String? path) {
  final extension = checkoutHighlightExtension(path);
  return extension != null && _languageByExtension.containsKey(extension);
}

({Map<int, List<DiffToken>> oldTokens, Map<int, List<DiffToken>> newTokens})
_reconstructedTokenLookups(DiffFile file, String extension) {
  final oldLines = <int, String>{};
  final newLines = <int, String>{};
  for (final hunk in file.hunks) {
    for (final line in hunk.lines) {
      if (line.oldLineNo case final lineNumber?) {
        oldLines[lineNumber] = line.text;
      }
      if (line.newLineNo case final lineNumber?) {
        newLines[lineNumber] = line.text;
      }
    }
  }
  return (
    oldTokens: _reconstructedTokenLookup(oldLines, extension),
    newTokens: _reconstructedTokenLookup(newLines, extension),
  );
}

Map<int, List<DiffToken>> _reconstructedTokenLookup(
  Map<int, String> lines,
  String extension,
) {
  if (lines.isEmpty) return const {};
  final lineNumbers = lines.keys.toList()..sort();
  final first = lineNumbers.first;
  final last = lineNumbers.last;
  final content = [
    for (var lineNumber = first; lineNumber <= last; lineNumber++)
      lines[lineNumber] ?? '',
  ].join('\n');
  final highlighted = _tokenize(content, extension);
  return {
    for (var index = 0; index < highlighted.length; index++)
      if (lines.containsKey(first + index)) first + index: highlighted[index],
  };
}

Map<int, List<DiffToken>> _fullFileTokenLookup(
  String content,
  String extension,
) {
  final highlighted = _tokenize(content, extension);
  return {
    for (var index = 0; index < highlighted.length; index++)
      index + 1: highlighted[index],
  };
}

List<List<DiffToken>> _tokenize(String code, String extension) {
  final language = _languageByExtension[extension]!;
  final result = highlight.parse(code, languageId: language);
  final lines = <List<DiffToken>>[<DiffToken>[]];
  _flattenNode(result.rootNode, null, lines);
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].isEmpty) {
      lines[index] = const [DiffToken(text: '')];
    }
  }
  return lines;
}

void _flattenNode(
  Node node,
  String? inheritedStyle,
  List<List<DiffToken>> lines,
) {
  final style =
      checkoutHighlightTokenStyleForScope(node.className) ?? inheritedStyle;
  if (node.value case final value?) {
    _appendText(value, style, lines);
  }
  for (final child in node.children) {
    _flattenNode(child, style, lines);
  }
}

void _appendText(String text, String? style, List<List<DiffToken>> lines) {
  final parts = text.split('\n');
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.isNotEmpty) {
      final line = lines.last;
      if (line.isNotEmpty && line.last.style == style) {
        final previous = line.removeLast();
        line.add(DiffToken(text: previous.text + part, style: style));
      } else {
        line.add(DiffToken(text: part, style: style));
      }
    }
    if (index < parts.length - 1) lines.add(<DiffToken>[]);
  }
}

String? checkoutHighlightTokenStyleForScope(String? scope) {
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

DiffFile _applyTokens(
  DiffFile file, {
  required Map<int, List<DiffToken>> oldTokens,
  required Map<int, List<DiffToken>> newTokens,
}) {
  return DiffFile(
    path: file.path,
    status: file.status,
    oldPath: file.oldPath,
    binary: file.binary,
    tooLarge: file.tooLarge,
    additions: file.additions,
    deletions: file.deletions,
    hunks: [
      for (final hunk in file.hunks)
        DiffHunk(
          header: hunk.header,
          lines: [
            for (final line in hunk.lines)
              DiffLine(
                type: line.type,
                text: line.text,
                oldLineNo: line.oldLineNo,
                newLineNo: line.newLineNo,
                tokens: switch (line.type) {
                  DiffLineType.add => newTokens[line.newLineNo],
                  DiffLineType.del => oldTokens[line.oldLineNo],
                  DiffLineType.context => newTokens[line.newLineNo],
                },
              ),
          ],
        ),
    ],
  );
}
