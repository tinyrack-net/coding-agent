import 'highlight_cache.dart';
import 'tool_call_parsers.dart';

List<ToolDiffLine> highlightDiffLines(
  List<ToolDiffLine> diffLines,
  String? filePath,
) {
  final extension = extensionFromPath(filePath);
  if (!isHighlightLanguageSupported(extension) || diffLines.isEmpty) {
    return diffLines;
  }

  final oldCode = <String>[];
  final newCode = <String>[];
  final positions = <({int oldIndex, int newIndex})>[];
  for (final line in diffLines) {
    final code = _diffLineCode(line);
    switch (line.type) {
      case ToolDiffLineType.context:
        positions.add((oldIndex: oldCode.length, newIndex: newCode.length));
        oldCode.add(code);
        newCode.add(code);
      case ToolDiffLineType.remove:
        positions.add((oldIndex: oldCode.length, newIndex: -1));
        oldCode.add(code);
      case ToolDiffLineType.add:
        positions.add((oldIndex: -1, newIndex: newCode.length));
        newCode.add(code);
      case ToolDiffLineType.header:
        positions.add((oldIndex: -1, newIndex: -1));
    }
  }

  final oldTokens = oldCode.isEmpty
      ? null
      : tokenizeToLines(oldCode.join('\n'), extension);
  final newTokens = newCode.isEmpty
      ? null
      : tokenizeToLines(newCode.join('\n'), extension);
  if (oldTokens == null && newTokens == null) return diffLines;

  return [
    for (var index = 0; index < diffLines.length; index++)
      _withTokens(diffLines[index], positions[index], oldTokens, newTokens),
  ];
}

String _diffLineCode(ToolDiffLine line) {
  final marker = switch (line.type) {
    ToolDiffLineType.add => '+',
    ToolDiffLineType.remove => '-',
    ToolDiffLineType.context => ' ',
    ToolDiffLineType.header => '',
  };
  return marker.isNotEmpty && line.content.startsWith(marker)
      ? line.content.substring(1)
      : line.content;
}

ToolDiffLine _withTokens(
  ToolDiffLine line,
  ({int oldIndex, int newIndex}) position,
  List<List<ToolDiffToken>>? oldTokens,
  List<List<ToolDiffToken>>? newTokens,
) {
  List<ToolDiffToken>? tokens;
  if ((line.type == ToolDiffLineType.add ||
          line.type == ToolDiffLineType.context) &&
      newTokens != null &&
      position.newIndex >= 0) {
    tokens = newTokens[position.newIndex];
  } else if (line.type == ToolDiffLineType.remove &&
      oldTokens != null &&
      position.oldIndex >= 0) {
    tokens = oldTokens[position.oldIndex];
  }
  if (tokens == null) return line;
  return ToolDiffLine(
    type: line.type,
    content: line.content,
    segments: line.segments,
    tokens: tokens,
  );
}
