import 'package:coding_agent_app/core/diff_highlighter.dart';
import 'package:coding_agent_app/core/diff_layout.dart';
import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedDiffFile makeFile(
  List<ParsedDiffLine> lines, {
  int oldStart = 10,
  int newStart = 10,
}) => ParsedDiffFile(
  path: 'example.ts',
  isNew: false,
  isDeleted: false,
  additions: lines.where((line) => line.type == ParsedDiffLineType.add).length,
  deletions: lines
      .where((line) => line.type == ParsedDiffLineType.remove)
      .length,
  hunks: [
    ParsedDiffHunk(
      oldStart: oldStart,
      oldCount: 4,
      newStart: newStart,
      newCount: 5,
      lines: lines,
    ),
  ],
);

void expectReviewTarget(
  ReviewableDiffTarget? target, {
  required String hunkHeader,
  required int hunkIndex,
  required int lineIndex,
  required int? oldLineNumber,
  required int? newLineNumber,
  required ReviewSide side,
  required int lineNumber,
  required ParsedDiffLineType lineType,
  required String content,
}) {
  expect(target, isNotNull);
  expect(target!.filePath, 'example.ts');
  expect(target.hunkHeader, hunkHeader);
  expect(target.hunkIndex, hunkIndex);
  expect(target.lineIndex, lineIndex);
  expect(target.oldLineNumber, oldLineNumber);
  expect(target.newLineNumber, newLineNumber);
  expect(target.side, side);
  expect(target.lineNumber, lineNumber);
  expect(target.lineType, lineType);
  expect(target.content, content);
  expect(
    target.key,
    buildReviewableDiffTargetKey(
      ReviewableDiffTargetKeyInput(
        filePath: 'example.ts',
        side: side,
        lineNumber: lineNumber,
      ),
    ),
  );
}

void main() {
  group('buildSplitDiffRows', () {
    test('uses canonical persisted keys for both context sides', () {
      final rows = buildSplitDiffRows(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,1 +20,1 @@',
          ),
          ParsedDiffLine(
            type: ParsedDiffLineType.context,
            content: 'same line',
          ),
        ], newStart: 20),
      );
      final pair = rows[1] as SplitDiffPairRow;
      expect(pair.left!.reviewTarget!.key, 'example.ts:old:10');
      expect(pair.right!.reviewTarget!.key, 'example.ts:new:20');
    });

    test('pairs replacement runs by index', () {
      final rows = buildSplitDiffRows(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,2 +10,2 @@',
          ),
          ParsedDiffLine(
            type: ParsedDiffLineType.remove,
            content: 'before one',
          ),
          ParsedDiffLine(
            type: ParsedDiffLineType.remove,
            content: 'before two',
          ),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'after one'),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'after two'),
        ]),
      );

      expect(rows, hasLength(3));
      final first = rows[1] as SplitDiffPairRow;
      final second = rows[2] as SplitDiffPairRow;
      expect((first.left!.content, first.left!.lineNumber), ('before one', 10));
      expect(
        (first.right!.content, first.right!.lineNumber),
        ('after one', 10),
      );
      expect(
        (second.left!.content, second.left!.lineNumber),
        ('before two', 11),
      );
      expect(
        (second.right!.content, second.right!.lineNumber),
        ('after two', 11),
      );
    });

    test('keeps unmatched additions on the right side only', () {
      final rows = buildSplitDiffRows(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,1 +10,2 @@',
          ),
          ParsedDiffLine(type: ParsedDiffLineType.remove, content: 'before'),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'after one'),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'after two'),
        ]),
      );

      final unmatched = rows[2] as SplitDiffPairRow;
      expect(unmatched.left, isNull);
      expect(
        (unmatched.right!.content, unmatched.right!.lineNumber),
        ('after two', 11),
      );
    });

    test('duplicates context cells and emits side-specific review targets', () {
      final rows = buildSplitDiffRows(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,1 +20,1 @@',
          ),
          ParsedDiffLine(
            type: ParsedDiffLineType.context,
            content: 'same line',
            tokens: [ToolDiffToken(text: 'same', style: 'string')],
          ),
        ], newStart: 20),
      );

      expect((rows.first as SplitDiffHeaderRow).content, '@@ -10,1 +20,1 @@');
      final pair = rows[1] as SplitDiffPairRow;
      expect((pair.left!.lineNumber, pair.right!.lineNumber), (10, 20));
      expect(pair.left!.tokens!.single.text, 'same');
      expectReviewTarget(
        pair.left!.reviewTarget,
        hunkHeader: '@@ -10,1 +20,1 @@',
        hunkIndex: 0,
        lineIndex: 1,
        oldLineNumber: 10,
        newLineNumber: 20,
        side: ReviewSide.old,
        lineNumber: 10,
        lineType: ParsedDiffLineType.context,
        content: 'same line',
      );
      expectReviewTarget(
        pair.right!.reviewTarget,
        hunkHeader: '@@ -10,1 +20,1 @@',
        hunkIndex: 0,
        lineIndex: 1,
        oldLineNumber: 10,
        newLineNumber: 20,
        side: ReviewSide.newSide,
        lineNumber: 20,
        lineType: ParsedDiffLineType.context,
        content: 'same line',
      );
    });

    test('does not create targets for headers or empty split cells', () {
      final rows = buildSplitDiffRows(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,1 +10,2 @@',
          ),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'after'),
        ]),
      );

      expect(rows.first, isA<SplitDiffHeaderRow>());
      final pair = rows[1] as SplitDiffPairRow;
      expect(pair.left, isNull);
      expectReviewTarget(
        pair.right!.reviewTarget,
        hunkHeader: '@@ -10,1 +10,2 @@',
        hunkIndex: 0,
        lineIndex: 1,
        oldLineNumber: null,
        newLineNumber: 10,
        side: ReviewSide.newSide,
        lineNumber: 10,
        lineType: ParsedDiffLineType.add,
        content: 'after',
      );
    });
  });

  group('buildUnifiedDiffLines', () {
    test('computes line numbers per line type within a hunk', () {
      final lines = buildUnifiedDiffLines(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,3 +10,4 @@',
          ),
          ParsedDiffLine(type: ParsedDiffLineType.context, content: 'before'),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'inserted'),
          ParsedDiffLine(type: ParsedDiffLineType.remove, content: 'removed'),
          ParsedDiffLine(type: ParsedDiffLineType.context, content: 'after'),
        ]),
      );

      expect(
        lines.map((entry) => (entry.line.type, entry.lineNumber)).toList(),
        [
          (ParsedDiffLineType.header, null),
          (ParsedDiffLineType.context, 10),
          (ParsedDiffLineType.add, 11),
          (ParsedDiffLineType.remove, 11),
          (ParsedDiffLineType.context, 12),
        ],
      );
    });

    test('restarts numbering at every hunk boundary', () {
      const file = ParsedDiffFile(
        path: 'example.ts',
        isNew: false,
        isDeleted: false,
        additions: 1,
        deletions: 0,
        hunks: [
          ParsedDiffHunk(
            oldStart: 75,
            oldCount: 2,
            newStart: 75,
            newCount: 3,
            lines: [
              ParsedDiffLine(
                type: ParsedDiffLineType.header,
                content: '@@ -75,2 +75,3 @@',
              ),
              ParsedDiffLine(
                type: ParsedDiffLineType.context,
                content: 'first',
              ),
              ParsedDiffLine(type: ParsedDiffLineType.add, content: 'inserted'),
              ParsedDiffLine(
                type: ParsedDiffLineType.context,
                content: 'second',
              ),
            ],
          ),
          ParsedDiffHunk(
            oldStart: 165,
            oldCount: 2,
            newStart: 166,
            newCount: 2,
            lines: [
              ParsedDiffLine(
                type: ParsedDiffLineType.header,
                content: '@@ -165,2 +166,2 @@',
              ),
              ParsedDiffLine(
                type: ParsedDiffLineType.context,
                content: 'third',
              ),
              ParsedDiffLine(
                type: ParsedDiffLineType.context,
                content: 'fourth',
              ),
            ],
          ),
        ],
      );

      final lines = buildUnifiedDiffLines(file);
      expect(lines.map((entry) => entry.lineNumber).toList(), [
        null,
        75,
        76,
        77,
        null,
        166,
        167,
      ]);
    });

    test('emits canonical targets for context, remove, and add lines', () {
      final lines = buildUnifiedDiffLines(
        makeFile(const [
          ParsedDiffLine(
            type: ParsedDiffLineType.header,
            content: '@@ -10,2 +20,2 @@',
          ),
          ParsedDiffLine(type: ParsedDiffLineType.context, content: 'before'),
          ParsedDiffLine(type: ParsedDiffLineType.remove, content: 'removed'),
          ParsedDiffLine(type: ParsedDiffLineType.add, content: 'inserted'),
        ], newStart: 20),
      );

      expect(lines.first.reviewTarget, isNull);
      expectReviewTarget(
        lines[1].reviewTarget,
        hunkHeader: '@@ -10,2 +20,2 @@',
        hunkIndex: 0,
        lineIndex: 1,
        oldLineNumber: 10,
        newLineNumber: 20,
        side: ReviewSide.newSide,
        lineNumber: 20,
        lineType: ParsedDiffLineType.context,
        content: 'before',
      );
      expectReviewTarget(
        lines[2].reviewTarget,
        hunkHeader: '@@ -10,2 +20,2 @@',
        hunkIndex: 0,
        lineIndex: 2,
        oldLineNumber: 11,
        newLineNumber: null,
        side: ReviewSide.old,
        lineNumber: 11,
        lineType: ParsedDiffLineType.remove,
        content: 'removed',
      );
      expectReviewTarget(
        lines[3].reviewTarget,
        hunkHeader: '@@ -10,2 +20,2 @@',
        hunkIndex: 0,
        lineIndex: 3,
        oldLineNumber: null,
        newLineNumber: 21,
        side: ReviewSide.newSide,
        lineNumber: 21,
        lineType: ParsedDiffLineType.add,
        content: 'inserted',
      );
    });

    test('uses the frozen fallback header when a hunk has no header line', () {
      final hunk = buildNumberedDiffHunks(
        makeFile(const [
          ParsedDiffLine(type: ParsedDiffLineType.context, content: 'context'),
        ]),
      ).single;
      expect(hunk.hunkHeader, '@@');
      expect(hunk.lines.single.hunkHeader, '@@');
    });
  });
}
