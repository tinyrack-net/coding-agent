import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/widgets/timeline_item_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = <TimelineItem>[
    UserMessageItem(id: 'u1', text: 'run the tests'),
    ReasoningItem(id: 'r1', text: 'I should run flutter test', complete: true),
    ToolCallItem(
      id: 't1',
      toolName: 'Bash',
      status: ToolCallStatus.success,
      detail: ShellDetail(command: 'flutter test', output: 'All tests passed!'),
    ),
    AssistantMessageItem(id: 'a1', text: 'Tests are **green**.', complete: true),
    PermissionItem(
      id: 'p1',
      permissionId: 'perm-1',
      toolName: 'Edit',
      status: PermissionStatus.pending,
      detail: EditDetail(path: 'lib/main.dart', diff: '-old\n+new'),
    ),
    TurnItem(id: 'turn1', phase: TurnPhase.completed),
    ErrorItem(id: 'e1', message: 'provider crashed'),
  ];

  testWidgets('renders a scripted timeline item list', (tester) async {
    final decisions = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final item in items)
                TimelineItemTile(
                  item: item,
                  onPermissionDecision: (id, decision) =>
                      decisions.add((id, decision)),
                ),
            ],
          ),
        ),
      ),
    );

    // User bubble.
    expect(find.text('run the tests'), findsOneWidget);
    // Reasoning collapsed by default: header visible, body hidden.
    expect(find.text('Thinking…'), findsOneWidget);
    expect(find.text('I should run flutter test'), findsNothing);
    // Tool call card: name, summary, status chip; output collapsed.
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('success'), findsOneWidget);
    expect(find.text('All tests passed!'), findsNothing);
    // Assistant markdown rendered (bold stripped of asterisks).
    expect(find.textContaining('green'), findsOneWidget);
    // Permission card with actions.
    expect(find.text('Claude wants to use Edit'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    // Turn divider label + error banner.
    expect(find.text('turn completed'), findsOneWidget);
    expect(find.text('provider crashed'), findsOneWidget);

    // Expanding the tool card reveals output.
    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('All tests passed!'), findsOneWidget);

    // Permission buttons dispatch decisions.
    await tester.tap(find.text('Always allow'));
    expect(decisions, [('perm-1', 'allow_always')]);
  });

  testWidgets('resolved permission hides buttons and shows state',
      (tester) async {
    const resolved = PermissionItem(
      id: 'p2',
      permissionId: 'perm-2',
      toolName: 'Bash',
      status: PermissionStatus.denied,
      detail: ShellDetail(command: 'rm -rf /'),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimelineItemTile(item: resolved)),
      ),
    );
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Denied'), findsOneWidget);
  });
}
