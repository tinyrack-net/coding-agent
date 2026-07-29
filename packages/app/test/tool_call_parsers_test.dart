import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'buildLineDiff preserves lines and highlights adjacent word changes',
    () {
      final diff = buildLineDiff(
        'const value = 1;\nkeep\n',
        'const value = 2;\nkeep\n',
      );

      expect(diff.map((line) => line.type), [
        ToolDiffLineType.remove,
        ToolDiffLineType.add,
        ToolDiffLineType.context,
        ToolDiffLineType.context,
      ]);
      expect(diff[0].content, '-const value = 1;');
      expect(diff[1].content, '+const value = 2;');
      expect(diff[0].segments, [
        const ToolDiffSegment(text: 'const value = ', changed: false),
        const ToolDiffSegment(text: '1', changed: true),
        const ToolDiffSegment(text: ';', changed: false),
      ]);
      expect(diff[1].segments, [
        const ToolDiffSegment(text: 'const value = ', changed: false),
        const ToolDiffSegment(text: '2', changed: true),
        const ToolDiffSegment(text: ';', changed: false),
      ]);
    },
  );

  test('parseUnifiedDiff filters metadata and classifies display lines', () {
    final parsed = parseUnifiedDiff(
      'diff --git a/a b/a\n'
      'index 123..456 100644\n'
      '--- a/a\n'
      '+++ b/a\n'
      '@@ -1 +1 @@\n'
      '-old\n'
      '+new\n'
      ' context\n'
      r'\ No newline at end of file',
    );

    expect(parsed.map((line) => line.type), [
      ToolDiffLineType.header,
      ToolDiffLineType.remove,
      ToolDiffLineType.add,
      ToolDiffLineType.context,
      ToolDiffLineType.header,
    ]);
    expect(parsed.map((line) => line.content), [
      '@@ -1 +1 @@',
      '-old',
      '+new',
      ' context',
      r'\ No newline at end of file',
    ]);
  });

  test('extracts TodoWrite and update_plan entries with frozen validation', () {
    final todos = extractTaskEntriesFromToolCall('TodoWrite', {
      'todos': [
        {
          'content': 'Task 1',
          'activeForm': ' Doing task 1 ',
          'status': 'in_progress',
        },
        {'content': 'Task 2', 'status': 'completed'},
      ],
    });
    expect(todos?.map((entry) => entry.text), ['Doing task 1', 'Task 2']);
    expect(todos?.map((entry) => entry.completed), [false, true]);

    final plan = extractTaskEntriesFromToolCall('update_plan', {
      'plan': [
        {'step': ' First ', 'status': 'unknown'},
        {'step': ' ', 'status': 'completed'},
      ],
    });
    expect(plan, hasLength(1));
    expect(plan!.single.status, TaskEntryStatus.pending);
    expect(extractTaskEntriesFromToolCall('ExitPlanMode', {}), isNull);
  });
}
