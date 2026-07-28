final class FileMentionRange {
  const FileMentionRange({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

final _invalidMentionQueryCharacters = RegExp(r'''[\s\n\r\t"']''');

FileMentionRange? findActiveFileMention({
  required String text,
  required int cursorIndex,
}) {
  final clampedCursor = cursorIndex.clamp(0, text.length);
  final beforeCursor = text.substring(0, clampedCursor);
  for (
    var atIndex = beforeCursor.lastIndexOf('@');
    atIndex >= 0;
    atIndex = atIndex == 0 ? -1 : beforeCursor.lastIndexOf('@', atIndex - 1)
  ) {
    final query = beforeCursor.substring(atIndex + 1);
    if (_invalidMentionQueryCharacters.hasMatch(query)) continue;
    return FileMentionRange(start: atIndex, end: clampedCursor, query: query);
  }
  return null;
}

String formatQuotedFileMentionPath(String relativePath) =>
    '"${relativePath.replaceAll('"', r'\"')}"';

String applyFileMentionReplacement({
  required String text,
  required FileMentionRange mention,
  required String relativePath,
}) {
  final before = text.substring(0, mention.start);
  final after = text.substring(mention.end);
  return '$before${formatQuotedFileMentionPath(relativePath)}$after';
}
