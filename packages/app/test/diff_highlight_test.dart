import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/diff_highlight.dart';
import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attaches old and new TypeScript tokens to line diff', () {
    final highlighted = highlightDiffLines(
      buildLineDiff(
        'const value = 1;\nconst keep = true;',
        'const value = 2;\nconst keep = true;',
      ),
      'example.ts',
    );

    expect(highlighted.map((line) => line.tokens), everyElement(isNotNull));
    for (final line in highlighted) {
      expect(
        line.tokens!.map((token) => token.text).join(),
        line.content.substring(1),
      );
    }
    expect(
      highlighted
          .expand((line) => line.tokens!)
          .any((token) => token.style == 'keyword'),
      isTrue,
    );
  });

  test('highlights bare hunk diffs but leaves headers tokenless', () {
    final highlighted = highlightDiffLines(
      parseUnifiedDiff(
        '@@\n'
        '-const oldValue = 1;\n'
        '+const newValue = 2;\n'
        ' const keep = true;',
      ),
      'example.ts',
    );

    expect(highlighted, hasLength(4));
    expect(highlighted.first.type, ToolDiffLineType.header);
    expect(highlighted.first.tokens, isNull);
    expect(
      highlighted.skip(1).map((line) => line.tokens),
      everyElement(isNotNull),
    );
  });

  test('returns the exact input for unsupported or absent paths', () {
    final input = buildLineDiff('old', 'new');
    expect(identical(highlightDiffLines(input, 'example.txt'), input), isTrue);
    expect(identical(highlightDiffLines(input, null), input), isTrue);
  });

  test('returns the exact empty input', () {
    final input = <ToolDiffLine>[];
    expect(identical(highlightDiffLines(input, 'example.ts'), input), isTrue);
  });

  test('highlights legacy structured files while preserving server tokens', () {
    const serverTokens = [DiffToken(text: 'server token', style: 'definition')];
    const diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/example.dart',
          status: DiffFileStatus.modified,
          hunks: [
            DiffHunk(
              header: '@@ -1,2 +1,2 @@',
              lines: [
                DiffLine(
                  type: DiffLineType.context,
                  text: 'server token',
                  oldLineNo: 1,
                  newLineNo: 1,
                  tokens: serverTokens,
                ),
                DiffLine(
                  type: DiffLineType.add,
                  text: 'const value = 1;',
                  newLineNo: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    final highlighted = highlightLegacyDiff(diff);
    final lines = highlighted.files.single.hunks.single.lines;
    expect(lines.first.tokens, same(serverTokens));
    expect(lines.last.tokens, isNotEmpty);
    expect(
      lines.last.tokens!.map((token) => token.text).join(),
      'const value = 1;',
    );
    expect(lines.last.tokens!.any((token) => token.style == 'keyword'), isTrue);
  });

  test('legacy unsupported files retain identity', () {
    const diff = DiffResponse(
      files: [
        DiffFile(
          path: 'notes.unknownext',
          status: DiffFileStatus.modified,
          hunks: [
            DiffHunk(
              header: '@@',
              lines: [
                DiffLine(
                  type: DiffLineType.context,
                  text: 'plain text',
                  oldLineNo: 1,
                  newLineNo: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    expect(identical(highlightLegacyDiff(diff), diff), isTrue);
  });
}
