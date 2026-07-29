import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_overview.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_overview_view.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders aggregate label, loading state, and bounded details', (
    tester,
  ) async {
    const call = ToolCallItem(
      id: 'tool-1',
      toolName: 'Bash',
      status: ToolCallStatus.running,
      detail: ShellDetail(command: 'dart test'),
    );
    final projection = projectToolCallDetailLevel(
      level: ToolCallDetailLevel.overview,
      tail: const [],
      head: const [call],
      preparedHistory: prepareToolCallHistory(
        ToolCallDetailLevel.overview,
        const [],
      ),
      isTurnActive: true,
    );
    final group = projection.groupsByHostId['tool-1']!;

    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: ToolCallOverviewGroupView(
            group: group,
            children: const [Text('dart test')],
          ),
        ),
      ),
    );

    expect(find.text('Ran 1 command'), findsOneWidget);
    expect(find.byType(ProgressRing), findsOneWidget);
    final bounded = tester.widget<ConstrainedBox>(
      find
          .descendant(
            of: find.byType(ToolCallOverviewGroupView),
            matching: find.byType(ConstrainedBox),
          )
          .last,
    );
    expect(bounded.constraints.maxHeight, toolCallGroupMaxHeight);

    await tester.tap(find.text('Ran 1 command'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('dart test'), findsOneWidget);
  });

  test('formats empty, two-part, and Oxford-comma summaries', () {
    const empty = ToolCallOverviewSummary(
      editedFileCount: 0,
      commandCount: 0,
      readFileCount: 0,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );
    const two = ToolCallOverviewSummary(
      editedFileCount: 1,
      commandCount: 1,
      readFileCount: 0,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );
    const three = ToolCallOverviewSummary(
      editedFileCount: 1,
      commandCount: 1,
      readFileCount: 1,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );

    expect(formatToolCallOverviewSummary(empty), '');
    expect(
      formatToolCallOverviewSummary(two),
      'Edited 1 file and ran 1 command',
    );
    expect(
      formatToolCallOverviewSummary(three),
      'Edited 1 file, ran 1 command, and read 1 file',
    );
  });
}
