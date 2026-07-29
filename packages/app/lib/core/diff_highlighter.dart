import 'highlight_cache.dart';
import 'tool_call_parsers.dart';

enum ParsedDiffLineType { add, remove, context, header }

final class ParsedDiffLine {
  const ParsedDiffLine({
    required this.type,
    required this.content,
    this.lineNumber,
    this.tokens,
  });

  final ParsedDiffLineType type;
  final String content;
  final int? lineNumber;
  final List<ToolDiffToken>? tokens;
}

final class ParsedDiffHunk {
  const ParsedDiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<ParsedDiffLine> lines;
}

final class ParsedDiffFile {
  const ParsedDiffFile({
    required this.path,
    required this.isNew,
    required this.isDeleted,
    required this.additions,
    required this.deletions,
    required this.hunks,
  });

  final String path;
  final bool isNew;
  final bool isDeleted;
  final int additions;
  final int deletions;
  final List<ParsedDiffHunk> hunks;
}

const _diffMetadataPrefixes = [
  'index ',
  '--- ',
  '+++ ',
  'new file mode',
  'deleted file mode',
];

final _hunkPattern = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

List<ParsedDiffFile> parseDiff(String diffText) {
  if (diffText.trim().isEmpty) return const [];
  final normalized = diffText.replaceAll('\r\n', '\n');
  final sections = normalized
      .split(RegExp(r'^diff --git ', multiLine: true))
      .where((section) => section.isNotEmpty);
  return [for (final section in sections) _parseFileSection(section)];
}

ParsedDiffFile _parseFileSection(String section) {
  final lines = section.split('\n');
  final isNew =
      section.contains('new file mode') || section.contains('--- /dev/null');
  final isDeleted =
      section.contains('deleted file mode') ||
      section.contains('+++ /dev/null');
  final path = _extractDiffPath(lines);
  final parsedHunks = _parseHunks(lines);
  return ParsedDiffFile(
    path: path,
    isNew: isNew,
    isDeleted: isDeleted,
    additions: parsedHunks.additions,
    deletions: parsedHunks.deletions,
    hunks: parsedHunks.hunks,
  );
}

String _extractDiffPath(List<String> lines) {
  final firstLine = lines.firstOrNull ?? '';
  final prefixed = RegExp(r'^a/(.+) b/(.+)$').firstMatch(firstLine);
  if (prefixed != null) return prefixed.group(2)!;

  final metadataPath =
      _extractPathFromMetadata(lines, '+++ ') ??
      _extractPathFromMetadata(lines, '--- ');
  if (metadataPath != null) return metadataPath;

  final pair = RegExp(r'^(\S+)\s+(\S+)$').firstMatch(firstLine);
  if (pair == null) return 'unknown';
  final oldPath = pair.group(1)!;
  final newPath = pair.group(2)!;
  final path = newPath == '/dev/null' ? oldPath : newPath;
  return oldPath.startsWith('a/') && newPath.startsWith('b/')
      ? path.substring(2)
      : path;
}

String? _extractPathFromMetadata(List<String> lines, String prefix) {
  for (final line in lines) {
    if (!line.startsWith(prefix)) continue;
    final rawPath = line.substring(prefix.length);
    final tab = rawPath.indexOf('\t');
    final path = (tab < 0 ? rawPath : rawPath.substring(0, tab)).trimRight();
    return path == '/dev/null' ? null : path;
  }
  return null;
}

({List<ParsedDiffHunk> hunks, int additions, int deletions}) _parseHunks(
  List<String> lines,
) {
  final hunks = <ParsedDiffHunk>[];
  _HunkBuilder? current;
  var additions = 0;
  var deletions = 0;

  for (var index = 1; index < lines.length; index++) {
    final line = lines[index];
    if (_diffMetadataPrefixes.any(line.startsWith)) continue;

    final hunkMatch = _hunkPattern.firstMatch(line);
    if (hunkMatch != null) {
      if (current != null) hunks.add(current.build());
      current = _HunkBuilder(
        oldStart: int.parse(hunkMatch.group(1)!),
        oldCount: int.parse(hunkMatch.group(2) ?? '1'),
        newStart: int.parse(hunkMatch.group(3)!),
        newCount: int.parse(hunkMatch.group(4) ?? '1'),
        header: hunkMatch.group(0)!,
      );
      continue;
    }
    if (current == null) continue;

    if (line.startsWith('+')) {
      current.lines.add(
        ParsedDiffLine(
          type: ParsedDiffLineType.add,
          content: line.substring(1),
        ),
      );
      additions++;
    } else if (line.startsWith('-')) {
      current.lines.add(
        ParsedDiffLine(
          type: ParsedDiffLineType.remove,
          content: line.substring(1),
        ),
      );
      deletions++;
    } else if (line.startsWith(' ')) {
      current.lines.add(
        ParsedDiffLine(
          type: ParsedDiffLineType.context,
          content: line.substring(1),
        ),
      );
    } else if (line.isNotEmpty && !line.startsWith(r'\')) {
      current.lines.add(
        ParsedDiffLine(type: ParsedDiffLineType.context, content: line),
      );
    }
  }
  if (current != null) hunks.add(current.build());
  return (hunks: hunks, additions: additions, deletions: deletions);
}

Map<int, String> reconstructNewFile(List<ParsedDiffHunk> hunks) {
  final lines = <int, String>{};
  for (final hunk in hunks) {
    var lineNumber = hunk.newStart;
    for (final line in hunk.lines) {
      if (line.type == ParsedDiffLineType.add ||
          line.type == ParsedDiffLineType.context) {
        lines[lineNumber++] = line.content;
      }
    }
  }
  return lines;
}

Map<int, String> reconstructOldFile(List<ParsedDiffHunk> hunks) {
  final lines = <int, String>{};
  for (final hunk in hunks) {
    var lineNumber = hunk.oldStart;
    for (final line in hunk.lines) {
      if (line.type == ParsedDiffLineType.remove ||
          line.type == ParsedDiffLineType.context) {
        lines[lineNumber++] = line.content;
      }
    }
  }
  return lines;
}

ParsedDiffFile highlightDiffFile(ParsedDiffFile file) {
  final extension = extensionFromPath(file.path);
  if (!isHighlightLanguageSupported(extension)) return file;

  final newFileLines = reconstructNewFile(file.hunks);
  final oldFileLines = reconstructOldFile(file.hunks);
  final newHighlighted = tokenizeHighlightDocument(
    _buildFileContent(newFileLines),
    extension!,
  );
  final oldHighlighted = tokenizeHighlightDocument(
    _buildFileContent(oldFileLines),
    extension,
  );
  final newTokensByLine = _buildTokenLookup(newFileLines, newHighlighted);
  final oldTokensByLine = _buildTokenLookup(oldFileLines, oldHighlighted);

  return ParsedDiffFile(
    path: file.path,
    isNew: file.isNew,
    isDeleted: file.isDeleted,
    additions: file.additions,
    deletions: file.deletions,
    hunks: [
      for (final hunk in file.hunks)
        _highlightHunk(hunk, oldTokensByLine, newTokensByLine),
    ],
  );
}

ParsedDiffHunk _highlightHunk(
  ParsedDiffHunk hunk,
  Map<int, List<ToolDiffToken>> oldTokensByLine,
  Map<int, List<ToolDiffToken>> newTokensByLine,
) {
  var oldLineNumber = hunk.oldStart;
  var newLineNumber = hunk.newStart;
  final lines = <ParsedDiffLine>[];
  for (final line in hunk.lines) {
    List<ToolDiffToken>? tokens;
    switch (line.type) {
      case ParsedDiffLineType.header:
        lines.add(line);
        continue;
      case ParsedDiffLineType.add:
        tokens = newTokensByLine[newLineNumber++];
      case ParsedDiffLineType.remove:
        tokens = oldTokensByLine[oldLineNumber++];
      case ParsedDiffLineType.context:
        tokens = newTokensByLine[newLineNumber++];
        oldLineNumber++;
    }
    lines.add(
      tokens == null
          ? line
          : ParsedDiffLine(
              type: line.type,
              content: line.content,
              lineNumber: line.lineNumber,
              tokens: tokens,
            ),
    );
  }
  return ParsedDiffHunk(
    oldStart: hunk.oldStart,
    oldCount: hunk.oldCount,
    newStart: hunk.newStart,
    newCount: hunk.newCount,
    lines: lines,
  );
}

String _buildFileContent(Map<int, String> lineMap) {
  if (lineMap.isEmpty) return '';
  final lineNumbers = lineMap.keys.toList()..sort();
  return [
    for (
      var lineNumber = lineNumbers.first;
      lineNumber <= lineNumbers.last;
      lineNumber++
    )
      lineMap[lineNumber] ?? '',
  ].join('\n');
}

Map<int, List<ToolDiffToken>> _buildTokenLookup(
  Map<int, String> lineMap,
  List<List<ToolDiffToken>> highlighted,
) {
  if (lineMap.isEmpty) return const {};
  final lineNumbers = lineMap.keys.toList()..sort();
  final firstLineNumber = lineNumbers.first;
  return {
    for (var index = 0; index < highlighted.length; index++)
      if (lineMap.containsKey(firstLineNumber + index))
        firstLineNumber + index: highlighted[index],
  };
}

List<ParsedDiffFile> parseAndHighlightDiff(String diffText) =>
    parseDiff(diffText).map(highlightDiffFile).toList();

final class _HunkBuilder {
  _HunkBuilder({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required String header,
  }) : lines = [
         ParsedDiffLine(type: ParsedDiffLineType.header, content: header),
       ];

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<ParsedDiffLine> lines;

  ParsedDiffHunk build() => ParsedDiffHunk(
    oldStart: oldStart,
    oldCount: oldCount,
    newStart: newStart,
    newCount: newCount,
    lines: List.unmodifiable(lines),
  );
}
