enum ToolDiffLineType { add, remove, context, header }

final class ToolDiffSegment {
  const ToolDiffSegment({required this.text, required this.changed});

  final String text;
  final bool changed;

  @override
  bool operator ==(Object other) =>
      other is ToolDiffSegment &&
      other.text == text &&
      other.changed == changed;

  @override
  int get hashCode => Object.hash(text, changed);
}

final class ToolDiffToken {
  const ToolDiffToken({required this.text, this.style});

  final String text;
  final String? style;
}

final class ToolDiffLine {
  const ToolDiffLine({
    required this.type,
    required this.content,
    this.segments,
    this.tokens,
  });

  final ToolDiffLineType type;
  final String content;
  final List<ToolDiffSegment>? segments;
  final List<ToolDiffToken>? tokens;
}

List<String> _splitIntoLines(String text) =>
    text.isEmpty ? const [] : text.replaceAll('\r\n', '\n').split('\n');

List<String> _splitIntoWords(String text) {
  final result = <String>[];
  var current = '';
  var inWord = false;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    final isWordCharacter = RegExp(r'^\w$').hasMatch(character);
    if (isWordCharacter) {
      if (!inWord && current.isNotEmpty) {
        result.add(current);
        current = '';
      }
      inWord = true;
      current += character;
    } else {
      if (inWord && current.isNotEmpty) {
        result.add(current);
        current = '';
      }
      inWord = false;
      current += character;
    }
  }
  if (current.isNotEmpty) result.add(current);
  return result;
}

({List<ToolDiffSegment> oldSegments, List<ToolDiffSegment> newSegments})
_computeWordLevelDiff(String oldLine, String newLine) {
  final oldWords = _splitIntoWords(oldLine);
  final newWords = _splitIntoWords(newLine);
  final rows = oldWords.length;
  final columns = newWords.length;
  final lengths = List.generate(
    rows + 1,
    (_) => List<int>.filled(columns + 1, 0),
  );
  for (var row = rows - 1; row >= 0; row--) {
    for (var column = columns - 1; column >= 0; column--) {
      lengths[row][column] = oldWords[row] == newWords[column]
          ? lengths[row + 1][column + 1] + 1
          : lengths[row + 1][column] >= lengths[row][column + 1]
          ? lengths[row + 1][column]
          : lengths[row][column + 1];
    }
  }

  final oldInLcs = <int>{};
  final newInLcs = <int>{};
  var oldIndex = 0;
  var newIndex = 0;
  while (oldIndex < rows && newIndex < columns) {
    if (oldWords[oldIndex] == newWords[newIndex]) {
      oldInLcs.add(oldIndex++);
      newInLcs.add(newIndex++);
    } else if (lengths[oldIndex + 1][newIndex] >=
        lengths[oldIndex][newIndex + 1]) {
      oldIndex++;
    } else {
      newIndex++;
    }
  }

  List<ToolDiffSegment> buildSegments(List<String> words, Set<int> inLcs) {
    if (words.isEmpty) return const [];
    final segments = <ToolDiffSegment>[];
    var currentText = '';
    bool? currentChanged;
    for (var index = 0; index < words.length; index++) {
      final changed = !inLcs.contains(index);
      if (currentChanged == null) {
        currentText = words[index];
        currentChanged = changed;
      } else if (changed == currentChanged) {
        currentText += words[index];
      } else {
        segments.add(
          ToolDiffSegment(text: currentText, changed: currentChanged),
        );
        currentText = words[index];
        currentChanged = changed;
      }
    }
    if (currentText.isNotEmpty) {
      segments.add(
        ToolDiffSegment(text: currentText, changed: currentChanged ?? false),
      );
    }
    return segments;
  }

  return (
    oldSegments: buildSegments(oldWords, oldInLcs),
    newSegments: buildSegments(newWords, newInLcs),
  );
}

List<ToolDiffLine> buildLineDiff(String originalText, String updatedText) {
  final originalLines = _splitIntoLines(originalText);
  final updatedLines = _splitIntoLines(updatedText);
  if (originalLines.isEmpty && updatedLines.isEmpty) return const [];

  final rows = originalLines.length;
  final columns = updatedLines.length;
  final lengths = List.generate(
    rows + 1,
    (_) => List<int>.filled(columns + 1, 0),
  );
  for (var row = rows - 1; row >= 0; row--) {
    for (var column = columns - 1; column >= 0; column--) {
      lengths[row][column] = originalLines[row] == updatedLines[column]
          ? lengths[row + 1][column + 1] + 1
          : lengths[row + 1][column] >= lengths[row][column + 1]
          ? lengths[row + 1][column]
          : lengths[row][column + 1];
    }
  }

  final diff = <ToolDiffLine>[];
  var originalIndex = 0;
  var updatedIndex = 0;
  while (originalIndex < rows && updatedIndex < columns) {
    if (originalLines[originalIndex] == updatedLines[updatedIndex]) {
      diff.add(
        ToolDiffLine(
          type: ToolDiffLineType.context,
          content: ' ${originalLines[originalIndex]}',
        ),
      );
      originalIndex++;
      updatedIndex++;
    } else if (lengths[originalIndex + 1][updatedIndex] >=
        lengths[originalIndex][updatedIndex + 1]) {
      diff.add(
        ToolDiffLine(
          type: ToolDiffLineType.remove,
          content: '-${originalLines[originalIndex++]}',
        ),
      );
    } else {
      diff.add(
        ToolDiffLine(
          type: ToolDiffLineType.add,
          content: '+${updatedLines[updatedIndex++]}',
        ),
      );
    }
  }
  while (originalIndex < rows) {
    diff.add(
      ToolDiffLine(
        type: ToolDiffLineType.remove,
        content: '-${originalLines[originalIndex++]}',
      ),
    );
  }
  while (updatedIndex < columns) {
    diff.add(
      ToolDiffLine(
        type: ToolDiffLineType.add,
        content: '+${updatedLines[updatedIndex++]}',
      ),
    );
  }

  for (var index = 0; index < diff.length - 1; index++) {
    final current = diff[index];
    final next = diff[index + 1];
    if (current.type != ToolDiffLineType.remove ||
        next.type != ToolDiffLineType.add) {
      continue;
    }
    final segments = _computeWordLevelDiff(
      current.content.substring(1),
      next.content.substring(1),
    );
    diff[index] = ToolDiffLine(
      type: current.type,
      content: current.content,
      segments: segments.oldSegments,
    );
    diff[index + 1] = ToolDiffLine(
      type: next.type,
      content: next.content,
      segments: segments.newSegments,
    );
  }
  return diff;
}

List<ToolDiffLine> parseUnifiedDiff(String? diffText) {
  if (diffText == null || diffText.isEmpty) return const [];
  final diff = <ToolDiffLine>[];
  for (final line in _splitIntoLines(diffText)) {
    if (line.isEmpty) {
      diff.add(const ToolDiffLine(type: ToolDiffLineType.context, content: ''));
    } else if (line.startsWith('@@') || line.startsWith(r'\ No newline')) {
      diff.add(ToolDiffLine(type: ToolDiffLineType.header, content: line));
    } else if (line.startsWith('+')) {
      if (!line.startsWith('+++')) {
        diff.add(ToolDiffLine(type: ToolDiffLineType.add, content: line));
      }
    } else if (line.startsWith('-')) {
      if (!line.startsWith('---')) {
        diff.add(ToolDiffLine(type: ToolDiffLineType.remove, content: line));
      }
    } else if (!line.startsWith('diff --git') &&
        !line.startsWith('index ') &&
        !line.startsWith('---') &&
        !line.startsWith('+++')) {
      diff.add(ToolDiffLine(type: ToolDiffLineType.context, content: line));
    }
  }
  return diff;
}

String diffLinePrefix(ToolDiffLine line) => switch (line.type) {
  ToolDiffLineType.add => '+',
  ToolDiffLineType.remove => '-',
  ToolDiffLineType.context => ' ',
  ToolDiffLineType.header => '',
};

enum TaskEntryStatus { pending, inProgress, completed }

final class TaskEntry {
  const TaskEntry({
    required this.text,
    required this.status,
    required this.completed,
  });

  final String text;
  final TaskEntryStatus status;
  final bool completed;
}

TaskEntryStatus? _strictTaskStatus(Object? value) => switch (value) {
  'pending' => TaskEntryStatus.pending,
  'in_progress' => TaskEntryStatus.inProgress,
  'completed' => TaskEntryStatus.completed,
  _ => null,
};

List<TaskEntry>? extractTaskEntriesFromToolCall(
  String toolName,
  Object? input,
) {
  final normalized = toolName
      .trim()
      .replaceAll(RegExp(r'[.\s-]+'), '_')
      .toLowerCase();
  if (normalized == 'exitplanmode') return null;
  if (input is! Map) return null;

  if (normalized == 'todowrite' || normalized == 'todo_write') {
    final todos = input['todos'];
    if (todos is! List) return null;
    final result = <TaskEntry>[];
    for (final raw in todos) {
      if (raw is! Map || raw['content'] is! String) return null;
      final status = _strictTaskStatus(raw['status']);
      if (status == null) return null;
      final content = raw['content'] as String;
      final activeForm = raw['activeForm'];
      if (activeForm != null && activeForm is! String) return null;
      final preferred = activeForm is String && activeForm.trim().isNotEmpty
          ? activeForm.trim()
          : content.trim();
      result.add(
        TaskEntry(
          text: preferred.isNotEmpty ? preferred : content,
          status: status,
          completed: status == TaskEntryStatus.completed,
        ),
      );
    }
    return result;
  }

  if (normalized == 'update_plan') {
    final plan = input['plan'];
    if (plan is! List) return null;
    final result = <TaskEntry>[];
    for (final raw in plan) {
      if (raw is! Map || raw['step'] is! String) return null;
      final text = (raw['step'] as String).trim();
      if (text.isEmpty) continue;
      final status =
          _strictTaskStatus(raw['status']) ?? TaskEntryStatus.pending;
      result.add(
        TaskEntry(
          text: text,
          status: status,
          completed: status == TaskEntryStatus.completed,
        ),
      );
    }
    return result;
  }
  return null;
}
