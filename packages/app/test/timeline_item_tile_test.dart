import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachment_service.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:coding_agent_app/widgets/diff/diff_viewer.dart';
import 'package:coding_agent_app/widgets/timeline_item_tile.dart';
import 'package:fluent_ui/fluent_ui.dart';
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
    AssistantMessageItem(
      id: 'a1',
      text: 'Tests are **green**.',
      complete: true,
    ),
    PermissionItem(
      id: 'p1',
      permissionId: 'perm-1',
      toolName: 'Edit',
      status: PermissionStatus.pending,
      detail: EditDetail(path: 'lib/main.dart', diff: '-old\n+new'),
    ),
    TurnItem(id: 'turn1', phase: TurnPhase.completed),
    CompactionItem(
      id: 'compact1',
      status: CompactionStatus.completed,
      trigger: CompactionTrigger.auto,
      preTokens: 190000,
    ),
    ErrorItem(id: 'e1', message: 'provider crashed'),
  ];

  testWidgets('worktree setup uses the frozen display and lifecycle log', (
    tester,
  ) async {
    const item = ToolCallItem(
      id: 'setup',
      toolName: 'paseo_worktree_setup',
      status: ToolCallStatus.success,
      detail: WorktreeSetupToolDetail(
        worktreePath: '/repo/feature',
        branchName: 'feature',
        log: 'dependencies installed',
        commands: [],
      ),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    expect(find.text('Worktree Setup'), findsOneWidget);
    expect(find.text('feature'), findsOneWidget);
    await tester.tap(find.text('Worktree Setup'));
    await tester.pumpAndSettle();
    expect(find.text('dependencies installed'), findsOneWidget);
  });

  testWidgets('tool and permission cards share canonical display mapping', (
    tester,
  ) async {
    final openedFiles = <String>[];
    const tool = ToolCallItem(
      id: 'read',
      toolName: 'read_file',
      status: ToolCallStatus.running,
      detail: ReadDetail(path: r'C:\repo\lib\main.dart'),
    );
    const permission = PermissionItem(
      id: 'permission',
      permissionId: 'permission-1',
      toolName: 'mcp__paseo__create_agent',
      status: PermissionStatus.pending,
      detail: GenericDetail(input: {}),
    );
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Column(
            children: [
              TimelineItemTile(
                item: tool,
                cwd: r'C:\repo',
                onOpenFilePath: openedFiles.add,
              ),
              const TimelineItemTile(item: permission),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Read'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('The agent wants to use Create Agent'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-open-file-read')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedFiles, [r'C:\repo\lib\main.dart']);
  });

  testWidgets('edit tool renders old/new text through the diff viewer', (
    tester,
  ) async {
    const item = ToolCallItem(
      id: 'edit',
      toolName: 'Edit',
      status: ToolCallStatus.success,
      detail: EditDetail(
        path: 'lib/main.dart',
        oldString: 'const value = 1;',
        newString: 'const value = 2;',
      ),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.byType(DiffViewer), findsOneWidget);
    final rendered = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join('\n');
    expect(rendered, contains('-const value = 1;'));
    expect(rendered, contains('+const value = 2;'));
  });

  testWidgets('rich optimistic user content renders images and attachments', (
    tester,
  ) async {
    final store = MemoryAttachmentStore();
    final metadata = await store.save(
      id: 'timeline-image',
      mimeType: 'image/png',
      fileName: 'timeline.png',
      bytes: Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/'
          'x8AAwMCAO+X1r0AAAAASUVORK5CYII=',
        ),
      ),
    );
    final message = OptimisticUserMessage(
      id: 'client-message',
      text: 'local rich text',
      timestamp: 123,
      images: [metadata],
      attachments: const [
        TextAgentAttachment(title: 'Context', text: 'attached'),
      ],
    );

    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: TimelineItemTile(
            item: const UserMessageItem(
              id: 'provider-message',
              text: 'server-rendered text',
            ),
            userMessage: message,
            imageAttachmentService: ComposerImageAttachmentService(
              store: () async => store,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('local rich text'), findsOneWidget);
    expect(find.text('server-rendered text'), findsNothing);
    expect(
      find.byKey(const ValueKey('timeline-image-timeline-image')),
      findsOneWidget,
    );
    expect(find.text('Context'), findsOneWidget);
  });

  testWidgets('renders a scripted timeline item list', (tester) async {
    final decisions = <(String, String)>[];
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: ListView(
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
    // Reasoning collapsed by default: header visible. (Fluent's `Expander`
    // keeps its content mounted with an animated height rather than
    // unmounting it like Material's `ExpansionTile`, so we don't assert the
    // body text is absent here — only that it becomes visible on expand,
    // covered below.)
    expect(find.text('Thinking…'), findsOneWidget);
    // Tool call card: name, summary, status chip.
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('success'), findsOneWidget);
    // Assistant markdown rendered (bold stripped of asterisks).
    expect(find.textContaining('green'), findsOneWidget);
    // Permission card with actions.
    expect(find.text('The agent wants to use Edit'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    // Turn divider label + error banner.
    expect(find.text('turn completed'), findsOneWidget);
    expect(find.text('Automatically compacting context'), findsOneWidget);
    expect(find.text('(190000 tokens)'), findsOneWidget);
    expect(find.text('provider crashed'), findsOneWidget);

    // Expanding the tool card reveals output.
    await tester.tap(find.text('Shell'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('All tests passed!'), findsOneWidget);

    // Permission buttons dispatch decisions.
    await tester.tap(find.text('Always allow'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(decisions, [('perm-1', 'allow_always')]);
  });

  testWidgets('resolved permission hides buttons and shows state', (
    tester,
  ) async {
    const resolved = PermissionItem(
      id: 'p2',
      permissionId: 'perm-2',
      toolName: 'Bash',
      status: PermissionStatus.denied,
      detail: ShellDetail(command: 'rm -rf /'),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: resolved)),
      ),
    );
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Denied'), findsOneWidget);
  });

  testWidgets('an allowed permission shows the allowed state', (tester) async {
    const resolved = PermissionItem(
      id: 'p3',
      permissionId: 'perm-3',
      toolName: 'Bash',
      status: PermissionStatus.allowed,
      detail: ShellDetail(command: 'echo hi'),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: resolved)),
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
      FluentApp(
        home: ScaffoldPage(
          content: TimelineItemTile(
            item: pending,
            onPermissionDecision: (id, decision) =>
                decisions.add((id, decision)),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Allow'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Deny'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(decisions, [('perm-4', 'allow'), ('perm-4', 'deny')]);
  });

  testWidgets('an incomplete assistant message shows the streaming cursor', (
    tester,
  ) async {
    const streaming = AssistantMessageItem(
      id: 'a2',
      text: 'still typing',
      complete: false,
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: streaming)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('still typing'), findsOneWidget);
    // The cursor's FadeTransition/AnimationController is only built while
    // the message is incomplete.
    expect(find.byType(FadeTransition), findsWidgets);
  });

  testWidgets('loading compaction shows progress semantics', (tester) async {
    const item = CompactionItem(
      id: 'compact-loading',
      status: CompactionStatus.loading,
      trigger: CompactionTrigger.manual,
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Compacting context'), findsOneWidget);
    expect(find.byType(ProgressRing), findsOneWidget);
  });

  testWidgets('running empty tools expose loading details', (tester) async {
    const item = ToolCallItem(
      id: 'loading-tool',
      toolName: 'exec_command',
      status: ToolCallStatus.running,
      detail: GenericDetail(input: {}),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    expect(find.text('Exec Command'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading tool details'), findsOneWidget);
    expect(find.byType(Expander), findsOneWidget);
  });

  testWidgets('plan tools render as non-expandable plan cards', (tester) async {
    const item = ToolCallItem(
      id: 'plan-tool',
      toolName: 'ExitPlanMode',
      status: ToolCallStatus.success,
      detail: PlanDetail(text: '1. Implement the feature'),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    expect(find.text('Plan'), findsOneWidget);
    expect(find.textContaining('Implement the feature'), findsOneWidget);
    expect(find.byType(Expander), findsNothing);
  });

  testWidgets(
    'read/write/search/generic tool details render canonical badges and bodies',
    (tester) async {
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
        FluentApp(
          home: ScaffoldPage(
            content: ListView(
              children: [
                for (final item in items) TimelineItemTile(item: item),
              ],
            ),
          ),
        ),
      );

      // Read: the canonical path appears in the badge and mounted detail body.
      expect(find.text('lib/main.dart'), findsNWidgets(2));
      expect(find.byIcon(FluentIcons.view), findsOneWidget);

      // Write: content preview is rendered once expanded.
      expect(find.text('lib/new.dart'), findsOneWidget);
      expect(find.byIcon(FluentIcons.edit), findsOneWidget);
      await tester.tap(find.text('Write'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('void main() {}'), findsOneWidget);

      // Canonical Paseo search summaries show the query, independently of the
      // provider-specific search path metadata.
      expect(find.text('TODO'), findsNWidgets(4));
      expect(find.byIcon(FluentIcons.search), findsNWidgets(2));

      // Unknown details do not infer summaries from raw provider input.
      expect(find.text('Custom'), findsOneWidget);
      expect(find.byIcon(FluentIcons.build), findsOneWidget);
      expect(find.text('error'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('pending'), findsOneWidget);

      // Generic body (non-empty input) renders once expanded.
      await tester.tap(find.text('Custom'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('key'), findsOneWidget);
    },
  );

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
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(
      find.textContaining('added line', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('removed line', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('context line', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('subagent detail renders identity, log, and canceled state', (
    tester,
  ) async {
    const item = ToolCallItem(
      id: 'subagent',
      toolName: 'Sub-agent',
      status: ToolCallStatus.canceled,
      detail: SubAgentDetail(
        subAgentType: 'Research',
        description: 'Inspect routing',
        log: 'Read lib/main.dart',
      ),
    );
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: TimelineItemTile(item: item)),
      ),
    );

    expect(find.byIcon(FluentIcons.robot), findsOneWidget);
    expect(find.text('Inspect routing'), findsOneWidget);
    expect(find.text('canceled'), findsOneWidget);
    await tester.tap(find.text('Research'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Read lib/main.dart'), findsOneWidget);
  });

  testWidgets('tool failures render errors with and without detail bodies', (
    tester,
  ) async {
    const items = <TimelineItem>[
      ToolCallItem(
        id: 'terminal-error',
        toolName: 'paseo_worktree_terminals',
        status: ToolCallStatus.error,
        detail: GenericDetail(input: {}),
        errorMessage: 'terminal creation failed',
      ),
      ToolCallItem(
        id: 'setup-error',
        toolName: 'paseo_worktree_setup',
        status: ToolCallStatus.error,
        detail: WorktreeSetupToolDetail(
          worktreePath: '/repo/feature',
          branchName: 'feature',
          log: 'installing dependencies',
          commands: [],
        ),
        errorMessage: 'setup exited 1',
      ),
    ];
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Column(
            children: [
              TimelineItemTile(item: items[0]),
              TimelineItemTile(item: items[1]),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Worktree Terminals'), findsOneWidget);
    expect(find.textContaining('Paseo'), findsNothing);
    await tester.tap(find.text('Worktree Terminals'));
    await tester.tap(find.text('Worktree Setup'));
    await tester.pumpAndSettle();

    expect(find.text('terminal creation failed'), findsOneWidget);
    expect(find.text('installing dependencies'), findsOneWidget);
    expect(find.text('setup exited 1'), findsOneWidget);
  });

  testWidgets('renders frozen todo, fetch, plain-text, and plan variants', (
    tester,
  ) async {
    const items = <TimelineItem>[
      TodoItem(
        id: 'todo',
        items: [
          TodoEntry(text: 'Inspect protocol', completed: true),
          TodoEntry(text: 'Run tests', completed: false),
        ],
      ),
      ToolCallItem(
        id: 'fetch',
        toolName: 'fetch',
        status: ToolCallStatus.success,
        detail: FetchDetail(
          url: 'https://example.com',
          result: 'Fetched content',
        ),
      ),
      ToolCallItem(
        id: 'plain',
        toolName: 'note',
        status: ToolCallStatus.success,
        detail: PlainTextDetail(label: 'Notice', text: 'Plain content'),
      ),
      ToolCallItem(
        id: 'plan',
        toolName: 'plan',
        status: ToolCallStatus.success,
        detail: PlanDetail(text: '1. Implement'),
      ),
    ];
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: ListView(
            children: [for (final item in items) TimelineItemTile(item: item)],
          ),
        ),
      ),
    );

    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('Inspect protocol'), findsOneWidget);
    expect(find.byIcon(FluentIcons.completed_solid), findsOneWidget);
    expect(find.byIcon(FluentIcons.circle_ring), findsOneWidget);
    expect(find.text('https://example.com'), findsOneWidget);
    expect(find.text('Notice'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);

    await tester.tap(find.text('Fetch'));
    await tester.tap(find.text('Note'));
    await tester.pumpAndSettle();
    expect(find.text('Fetched content'), findsOneWidget);
    expect(find.text('Plain content'), findsOneWidget);
    expect(find.textContaining('Implement'), findsOneWidget);
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
      FluentApp(
        home: ScaffoldPage(
          content: Column(
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
