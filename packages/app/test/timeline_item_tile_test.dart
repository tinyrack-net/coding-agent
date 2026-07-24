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

  testWidgets('an allowed permission shows the allowed state',
      (tester) async {
    const resolved = PermissionItem(
      id: 'p3',
      permissionId: 'perm-3',
      toolName: 'Bash',
      status: PermissionStatus.allowed,
      detail: ShellDetail(command: 'echo hi'),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimelineItemTile(item: resolved)),
      ),
    );
    expect(find.text('Allowed'), findsOneWidget);
  });

  testWidgets('tapping Allow and Deny on a pending permission dispatch '
      'decisions', (tester) async {
    final decisions = <(String, String)>[];
    const pending = PermissionItem(
      id: 'p4',
      permissionId: 'perm-4',
      toolName: 'Bash',
      status: PermissionStatus.pending,
      detail: ShellDetail(command: 'echo hi'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineItemTile(
            item: pending,
            onPermissionDecision: (id, decision) =>
                decisions.add((id, decision)),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Allow'));
    await tester.tap(find.text('Deny'));

    expect(decisions, [('perm-4', 'allow'), ('perm-4', 'deny')]);
  });

  testWidgets('an incomplete assistant message shows the streaming cursor',
      (tester) async {
    const streaming = AssistantMessageItem(
      id: 'a2',
      text: 'still typing',
      complete: false,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimelineItemTile(item: streaming)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('still typing'), findsOneWidget);
    // The cursor's FadeTransition/AnimationController is only built while
    // the message is incomplete.
    expect(find.byType(FadeTransition), findsWidgets);
  });

  testWidgets(
      'read/write/search/generic tool details render their icons and '
      'summaries, and a null-body detail (Read) collapses to a plain '
      'ListTile', (tester) async {
    const items = <TimelineItem>[
      ToolCallItem(
        id: 't-read',
        toolName: 'Read',
        status: ToolCallStatus.success,
        detail: ReadDetail(path: 'lib/main.dart'),
      ),
      ToolCallItem(
        id: 't-write',
        toolName: 'Write',
        status: ToolCallStatus.running,
        detail: WriteDetail(
          path: 'lib/new.dart',
          contentPreview: 'void main() {}',
        ),
      ),
      ToolCallItem(
        id: 't-search-with-path',
        toolName: 'Grep',
        status: ToolCallStatus.pending,
        detail: SearchDetail(query: 'TODO', path: 'lib'),
      ),
      ToolCallItem(
        id: 't-search-no-path',
        toolName: 'Grep',
        status: ToolCallStatus.error,
        detail: SearchDetail(query: 'TODO'),
      ),
      ToolCallItem(
        id: 't-generic',
        toolName: 'Custom',
        status: ToolCallStatus.success,
        detail: GenericDetail(input: {'key': 'value'}),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final item in items) TimelineItemTile(item: item),
            ],
          ),
        ),
      ),
    );

    // Read: no expandable body (ReadDetail has no output/preview), so it's a
    // plain ListTile with the path as its summary.
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.byIcon(Icons.file_open_outlined), findsOneWidget);

    // Write: content preview is rendered once expanded.
    expect(find.text('lib/new.dart'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    await tester.tap(find.text('Write'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('void main() {}'), findsOneWidget);

    // Search with a path: summary combines query + path.
    expect(find.text('TODO in lib'), findsOneWidget);
    // Search without a path: summary is just the query.
    expect(find.text('TODO'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsNWidgets(2));

    // Generic: summary falls back to the tool name (rendered twice: once as
    // the tool name label, once as the summary); error status chip shown.
    expect(find.text('Custom'), findsNWidgets(2));
    expect(find.byIcon(Icons.build_outlined), findsOneWidget);
    expect(find.text('error'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);

    // Generic body (non-empty input) renders once expanded.
    await tester.tap(find.text('Custom').first);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.textContaining('key'), findsOneWidget);
  });

  testWidgets('an EditDetail tool call with a diff renders the tinted diff '
      'view once expanded', (tester) async {
    const item = ToolCallItem(
      id: 't-edit',
      toolName: 'Edit',
      status: ToolCallStatus.success,
      detail: EditDetail(
        path: 'lib/main.dart',
        diff: '+added line\n-removed line\n context line',
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimelineItemTile(item: item)),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.textContaining('added line'), findsOneWidget);
    expect(find.textContaining('removed line'), findsOneWidget);
    expect(find.textContaining('context line'), findsOneWidget);
  });

  testWidgets('turn divider: started renders nothing, failed shows the '
      'error message, canceled shows its label', (tester) async {
    const items = <TimelineItem>[
      TurnItem(id: 'turn-started', phase: TurnPhase.started),
      TurnItem(
        id: 'turn-failed',
        phase: TurnPhase.failed,
        errorMessage: 'provider timed out',
      ),
      TurnItem(id: 'turn-canceled', phase: TurnPhase.canceled),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TimelineItemTile(item: items[0]),
              TimelineItemTile(item: items[1]),
              TimelineItemTile(item: items[2]),
            ],
          ),
        ),
      ),
    );

    expect(find.textContaining('turn failed'), findsOneWidget);
    expect(find.textContaining('provider timed out'), findsOneWidget);
    expect(find.text('turn canceled'), findsOneWidget);
    // The "started" divider renders as an empty SizedBox: no turn-related
    // text at all from that item.
    expect(find.text('turn started'), findsNothing);
  });
}
