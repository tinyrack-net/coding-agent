import 'diff_highlighter.dart';
import 'tool_call_parsers.dart';

enum ReviewSide {
  old('old'),
  newSide('new');

  const ReviewSide(this.wireName);

  final String wireName;
}

final class ReviewableDiffTargetKeyInput {
  const ReviewableDiffTargetKeyInput({
    required this.filePath,
    required this.side,
    required this.lineNumber,
  });

  final String filePath;
  final ReviewSide side;
  final int lineNumber;
}

String buildReviewableDiffTargetKey(ReviewableDiffTargetKeyInput input) =>
    '${input.filePath}:${input.side.wireName}:${input.lineNumber}';

final class ReviewableDiffTarget {
  const ReviewableDiffTarget({
    required this.key,
    required this.filePath,
    required this.hunkHeader,
    required this.hunkIndex,
    required this.lineIndex,
    required this.oldLineNumber,
    required this.newLineNumber,
    required this.side,
    required this.lineNumber,
    required this.lineType,
    required this.content,
  });

  final String key;
  final String filePath;
  final String hunkHeader;
  final int hunkIndex;
  final int lineIndex;
  final int? oldLineNumber;
  final int? newLineNumber;
  final ReviewSide side;
  final int lineNumber;
  final ParsedDiffLineType lineType;
  final String content;
}

final class NumberedDiffCell {
  const NumberedDiffCell({
    required this.key,
    required this.filePath,
    required this.hunkHeader,
    required this.hunkIndex,
    required this.lineIndex,
    required this.oldLineNumber,
    required this.newLineNumber,
    required this.side,
    required this.lineNumber,
    required this.lineType,
    required this.content,
    required this.line,
  });

  final String key;
  final String filePath;
  final String hunkHeader;
  final int hunkIndex;
  final int lineIndex;
  final int? oldLineNumber;
  final int? newLineNumber;
  final ReviewSide side;
  final int lineNumber;
  final ParsedDiffLineType lineType;
  final String content;
  final ParsedDiffLine line;
}

final class NumberedDiffLine {
  const NumberedDiffLine({
    required this.key,
    required this.filePath,
    required this.hunkHeader,
    required this.hunkIndex,
    required this.lineIndex,
    required this.line,
    required this.oldLineNumber,
    required this.newLineNumber,
    required this.unifiedCell,
    required this.oldCell,
    required this.newCell,
  });

  final String key;
  final String filePath;
  final String hunkHeader;
  final int hunkIndex;
  final int lineIndex;
  final ParsedDiffLine line;
  final int? oldLineNumber;
  final int? newLineNumber;
  final NumberedDiffCell? unifiedCell;
  final NumberedDiffCell? oldCell;
  final NumberedDiffCell? newCell;
}

final class NumberedDiffHunk {
  const NumberedDiffHunk({
    required this.hunkIndex,
    required this.hunkHeader,
    required this.lines,
  });

  final int hunkIndex;
  final String hunkHeader;
  final List<NumberedDiffLine> lines;
}

final class SplitDiffDisplayLine {
  const SplitDiffDisplayLine({
    required this.type,
    required this.content,
    required this.tokens,
    required this.lineNumber,
    required this.reviewTarget,
  });

  final ParsedDiffLineType type;
  final String content;
  final List<ToolDiffToken>? tokens;
  final int? lineNumber;
  final ReviewableDiffTarget? reviewTarget;
}

final class UnifiedDiffDisplayLine {
  const UnifiedDiffDisplayLine({
    required this.key,
    required this.line,
    required this.lineNumber,
    required this.reviewTarget,
  });

  final String key;
  final ParsedDiffLine line;
  final int? lineNumber;
  final ReviewableDiffTarget? reviewTarget;
}

sealed class SplitDiffRow {
  const SplitDiffRow();
}

final class SplitDiffHeaderRow extends SplitDiffRow {
  const SplitDiffHeaderRow({required this.content});

  final String content;
}

final class SplitDiffPairRow extends SplitDiffRow {
  const SplitDiffPairRow({required this.left, required this.right});

  final SplitDiffDisplayLine? left;
  final SplitDiffDisplayLine? right;
}

List<NumberedDiffHunk> buildNumberedDiffHunks(ParsedDiffFile file) {
  final numberedHunks = <NumberedDiffHunk>[];
  for (var hunkIndex = 0; hunkIndex < file.hunks.length; hunkIndex++) {
    final hunk = file.hunks[hunkIndex];
    var oldLineNumber = hunk.oldStart;
    var newLineNumber = hunk.newStart;
    final hunkHeader = _hunkHeader(hunk);
    final lines = <NumberedDiffLine>[];

    for (var lineIndex = 0; lineIndex < hunk.lines.length; lineIndex++) {
      final line = hunk.lines[lineIndex];
      int? oldNumber;
      int? newNumber;
      switch (line.type) {
        case ParsedDiffLineType.remove:
          oldNumber = oldLineNumber++;
        case ParsedDiffLineType.add:
          newNumber = newLineNumber++;
        case ParsedDiffLineType.context:
          oldNumber = oldLineNumber++;
          newNumber = newLineNumber++;
        case ParsedDiffLineType.header:
          break;
      }

      final oldCell = _buildNumberedCell(
        filePath: file.path,
        hunkHeader: hunkHeader,
        hunkIndex: hunkIndex,
        lineIndex: lineIndex,
        line: line,
        oldLineNumber: oldNumber,
        newLineNumber: newNumber,
        side: ReviewSide.old,
      );
      final newCell = _buildNumberedCell(
        filePath: file.path,
        hunkHeader: hunkHeader,
        hunkIndex: hunkIndex,
        lineIndex: lineIndex,
        line: line,
        oldLineNumber: oldNumber,
        newLineNumber: newNumber,
        side: ReviewSide.newSide,
      );
      lines.add(
        NumberedDiffLine(
          key: '$hunkIndex-$lineIndex',
          filePath: file.path,
          hunkHeader: hunkHeader,
          hunkIndex: hunkIndex,
          lineIndex: lineIndex,
          line: line,
          oldLineNumber: oldNumber,
          newLineNumber: newNumber,
          unifiedCell: line.type == ParsedDiffLineType.remove
              ? oldCell
              : newCell,
          oldCell: oldCell,
          newCell: newCell,
        ),
      );
    }
    numberedHunks.add(
      NumberedDiffHunk(
        hunkIndex: hunkIndex,
        hunkHeader: hunkHeader,
        lines: lines,
      ),
    );
  }
  return numberedHunks;
}

List<UnifiedDiffDisplayLine> buildUnifiedDiffLines(ParsedDiffFile file) => [
  for (final hunk in buildNumberedDiffHunks(file))
    for (final numberedLine in hunk.lines)
      UnifiedDiffDisplayLine(
        key: numberedLine.key,
        line: numberedLine.line,
        lineNumber: numberedLine.unifiedCell?.lineNumber,
        reviewTarget: numberedLine.unifiedCell == null
            ? null
            : _toReviewTarget(numberedLine.unifiedCell!),
      ),
];

List<SplitDiffRow> buildSplitDiffRows(ParsedDiffFile file) {
  final rows = <SplitDiffRow>[];
  for (final hunk in buildNumberedDiffHunks(file)) {
    rows.add(SplitDiffHeaderRow(content: hunk.hunkHeader));
    var removals = <NumberedDiffCell>[];
    var additions = <NumberedDiffCell>[];

    void flushPendingRows() {
      final pairCount = removals.length > additions.length
          ? removals.length
          : additions.length;
      for (var index = 0; index < pairCount; index++) {
        rows.add(
          SplitDiffPairRow(
            left: index < removals.length
                ? _toSplitDisplayLine(removals[index])
                : null,
            right: index < additions.length
                ? _toSplitDisplayLine(additions[index])
                : null,
          ),
        );
      }
      removals = [];
      additions = [];
    }

    for (final numberedLine in hunk.lines) {
      switch (numberedLine.line.type) {
        case ParsedDiffLineType.header:
          continue;
        case ParsedDiffLineType.remove:
          if (numberedLine.oldCell case final cell?) removals.add(cell);
          continue;
        case ParsedDiffLineType.add:
          if (numberedLine.newCell case final cell?) additions.add(cell);
          continue;
        case ParsedDiffLineType.context:
          flushPendingRows();
          rows.add(
            SplitDiffPairRow(
              left: _toSplitDisplayLine(numberedLine.oldCell!),
              right: _toSplitDisplayLine(numberedLine.newCell!),
            ),
          );
      }
    }
    flushPendingRows();
  }
  return rows;
}

String _hunkHeader(ParsedDiffHunk hunk) {
  for (final line in hunk.lines) {
    if (line.type == ParsedDiffLineType.header) return line.content;
  }
  return '@@';
}

NumberedDiffCell? _buildNumberedCell({
  required String filePath,
  required String hunkHeader,
  required int hunkIndex,
  required int lineIndex,
  required ParsedDiffLine line,
  required int? oldLineNumber,
  required int? newLineNumber,
  required ReviewSide side,
}) {
  if (line.type == ParsedDiffLineType.header ||
      (line.type == ParsedDiffLineType.remove && side != ReviewSide.old) ||
      (line.type == ParsedDiffLineType.add && side != ReviewSide.newSide)) {
    return null;
  }
  final lineNumber = side == ReviewSide.old ? oldLineNumber : newLineNumber;
  if (lineNumber == null) return null;
  return NumberedDiffCell(
    key: buildReviewableDiffTargetKey(
      ReviewableDiffTargetKeyInput(
        filePath: filePath,
        side: side,
        lineNumber: lineNumber,
      ),
    ),
    filePath: filePath,
    hunkHeader: hunkHeader,
    hunkIndex: hunkIndex,
    lineIndex: lineIndex,
    oldLineNumber: oldLineNumber,
    newLineNumber: newLineNumber,
    side: side,
    lineNumber: lineNumber,
    lineType: line.type,
    content: line.content,
    line: line,
  );
}

ReviewableDiffTarget _toReviewTarget(NumberedDiffCell cell) =>
    ReviewableDiffTarget(
      key: cell.key,
      filePath: cell.filePath,
      hunkHeader: cell.hunkHeader,
      hunkIndex: cell.hunkIndex,
      lineIndex: cell.lineIndex,
      oldLineNumber: cell.oldLineNumber,
      newLineNumber: cell.newLineNumber,
      side: cell.side,
      lineNumber: cell.lineNumber,
      lineType: cell.lineType,
      content: cell.content,
    );

SplitDiffDisplayLine _toSplitDisplayLine(NumberedDiffCell cell) =>
    SplitDiffDisplayLine(
      type: cell.lineType,
      content: cell.content,
      tokens: cell.line.tokens,
      lineNumber: cell.lineNumber,
      reviewTarget: _toReviewTarget(cell),
    );
