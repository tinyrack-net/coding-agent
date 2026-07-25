import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/worktree_tabbed_pane.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _worktreePath = '/repo-wt/lucky-otter';

const _idleAgent = AgentSummary(
  agentId: 'a1',
  title: 'Idle agent',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

const _runningAgent = AgentSummary(
  agentId: 'a2',
  title: 'Running agent',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 0,
);

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];

  /// Mirrors `agentsProvider`'s state so the connect-triggered
  /// `agent.list.request` doesn't race a test's manually-upserted agents out
  /// with an empty list.
  List<AgentSummary> agents = const [];

  @override
  Stream<TerminalFrame> get terminalFrames => const Stream.empty();

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  void sendTerminalFrame(TerminalFrame frame) {}

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentListRequest) {
      return {'agents': agents.map((a) => a.toJson()).toList()};
    }
    requests.add((type, payload));
    return switch (type) {
      MessageTypes.terminalCreateRequest => {
          'terminal': {'terminalId': 'term-1', 'shell': 'bash'},
        },
      MessageTypes.terminalSubscribeRequest => {'slotId': 1},
      MessageTypes.diffGetRequest => const DiffResponse(files: []).toJson(),
      MessageTypes.agentTimelineFetchRequest => const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 0,
          items: [],
        ).toJson(),
      _ => const {},
    };
  }
}

Finder _closeButtonFor(String tabLabel) => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is Tab && (w.text as Text).data == tabLabel,
      ),
      matching: find.byType(IconButton),
    );

Future<ProviderContainer> pumpPane(
  WidgetTester tester, {
  FakeDaemonClient? client,
  List<AgentSummary> agents = const [],
}) async {
  final resolvedClient = client ?? FakeDaemonClient();
  resolvedClient.agents = agents;
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(resolvedClient)],
  );
  addTearDown(container.dispose);
  for (final agent in agents) {
    container.read(agentsProvider.notifier).upsert(agent);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const FluentApp(
        home: ScaffoldPage(content: WorktreeTabbedPane(worktreePath: _worktreePath)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('reconciles a tab for each live agent sharing the worktree, '
      'no draft tab alongside them', (tester) async {
    await pumpPane(tester, agents: [_idleAgent, _runningAgent]);

    // The active tab's body (AgentChatScreen) also shows the agent's title
    // in its own header, so its label can legitimately match twice.
    expect(find.text('Idle agent'), findsWidgets);
    expect(find.text('Running agent'), findsOneWidget);
    expect(find.text('New session'), findsNothing);
  });

  testWidgets('the dropdown\'s "New terminal" adds a top-level terminal tab',
      (tester) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('New terminal'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final tabs =
        container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.terminal), hasLength(1));
    expect(find.text('Terminal 1'), findsOneWidget);
  });

  testWidgets('the dropdown\'s "View diff" inserts a diff tab once and '
      'reactivates it on repeat calls', (tester) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('View diff'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    var tabs = container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.diff), hasLength(1));

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('View diff'));
    await tester.pump(const Duration(milliseconds: 150));

    tabs = container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.diff), hasLength(1));
  });

  testWidgets('closing the diff tab is a plain removal, reopenable via '
      'View diff', (tester) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);
    container.read(worktreeTabsProvider(_worktreePath).notifier).showDiffTab();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(_closeButtonFor('Diff'));
    await tester.pump(const Duration(milliseconds: 150));

    var tabs = container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.diff), isEmpty);

    container.read(worktreeTabsProvider(_worktreePath).notifier).showDiffTab();
    await tester.pump(const Duration(milliseconds: 150));
    tabs = container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.diff), hasLength(1));
  });

  testWidgets('closing an idle agent tab archives it with no confirmation '
      'dialog', (tester) async {
    final client = FakeDaemonClient();
    final container =
        await pumpPane(tester, client: client, agents: [_idleAgent]);

    await tester.tap(_closeButtonFor('Idle agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Archive running agent?'), findsNothing);
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((t) => t.agentId == 'a1'),
      isEmpty,
    );
  });

  testWidgets('closing a running agent tab confirms first; cancelling leaves '
      'it running and open', (tester) async {
    final client = FakeDaemonClient();
    final container =
        await pumpPane(tester, client: client, agents: [_runningAgent]);

    await tester.tap(_closeButtonFor('Running agent'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Archive running agent?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isFalse,
    );
    expect(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((t) => t.agentId == 'a2'),
      hasLength(1),
    );
  });

  testWidgets('closing a running agent tab and confirming archives it and '
      'removes the tab', (tester) async {
    final client = FakeDaemonClient();
    final container =
        await pumpPane(tester, client: client, agents: [_runningAgent]);

    await tester.tap(_closeButtonFor('Running agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Archive'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((t) => t.agentId == 'a2'),
      isEmpty,
    );
  });

  testWidgets('closing a terminal tab confirms, then shuts down the daemon '
      'session and removes the tab', (tester) async {
    final client = FakeDaemonClient();
    final container =
        await pumpPane(tester, client: client, agents: [_idleAgent]);
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .addTab(WorktreeTabKind.terminal);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(_closeButtonFor('Terminal 1'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Close terminal?'), findsOneWidget);
    client.requests.clear();
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.terminalUnsubscribeRequest),
      isTrue,
    );
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.terminalKillRequest),
      isTrue,
    );
    expect(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((t) => t.kind == WorktreeTabKind.terminal),
      isEmpty,
    );
  });
}
