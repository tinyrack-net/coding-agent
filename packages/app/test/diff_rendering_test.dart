import 'package:coding_agent_app/core/diff_rendering.dart';
import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps empty gutters tall with non-breaking whitespace', () {
    expect(formatDiffGutterText(null), '\u00a0');
    expect(formatDiffGutterText(82), '82');
  });

  test('keeps empty split cells tall with visible whitespace', () {
    expect(formatDiffContentText(null), ' ');
    expect(formatDiffContentText(''), ' ');
    expect(formatDiffContentText('const value = 1;'), 'const value = 1;');
  });

  test('only treats non-empty highlighted tokens as visible', () {
    expect(hasVisibleDiffTokens(null), isFalse);
    expect(hasVisibleDiffTokens(const []), isFalse);
    expect(hasVisibleDiffTokens(const [ToolDiffToken(text: '')]), isFalse);
    expect(
      hasVisibleDiffTokens(const [ToolDiffToken(text: 'const value = 1;')]),
      isTrue,
    );
  });
}
