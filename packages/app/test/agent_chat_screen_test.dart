import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Demo agent',
  cwd: '/work/demo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

const _worktreeAgent = AgentSummary(
  agentId: 'a2',
  title: 'Worktree agent',
  cwd: '/work/repo-wt',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
  projectPath: '/work/repo',
  branch: 'feature/x',
  isWorktree: true,
);

/// A second agent sharing `_worktreeAgent`'s cwd — used to verify the
/// worktree-delete prompt only fires when archiving the *last* agent at
/// that cwd, not any one of several.
const _worktreeAgentSibling = AgentSummary(
  agentId: 'a3',
  title: 'Worktree sibling',
  cwd: '/work/repo-wt',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  projectPath: '/work/repo',
  branch: 'feature/x',
  isWorktree: true,
);

/// Scriptable fake covering what AgentChatScreen's chat-only view touches:
/// agent list (for the header) and the timeline fetch.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({List<AgentSummary> extraAgents = const []})
      : agents = [_agent, _worktreeAgent, ...extraAgents],
        super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final requests = <(String, Map<String, Object?>)>[];

  /// Mirrors `agentsProvider`'s state so the connect-triggered
  /// `agent.list.request` doesn't race a test's manually-upserted agents out
  /// with the two hardcoded defaults.
  final List<AgentSummary> agents;

  /// When true, the next `permission.respond.request` throws instead of
  /// responding (consumed after one use).
  bool failNextRespond = false;

  @override
  Stream<RpcEvent> get events => eventsController.stream;

  @override
  Stream<TerminalFrame> get terminalFrames => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  void sendTerminalFrame(TerminalFrame frame) {}

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.permissionRespondRequest && failNextRespond) {
      failNextRespond = false;
      throw StateError('permission service unavailable');
    }
    return switch (type) {
      MessageTypes.agentListRequest => {
          'agents': agents.map((a) => a.toJson()).toList(),
        },
      MessageTypes.agentTimelineFetchRequest => const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 0,
          items: [],
        ).toJson(),
      MessageTypes.diffGetRequest => const DiffResponse(files: []).toJson(),
      MessageTypes.terminalCreateRequest => {
          'terminal': {'terminalId': 'term-1', 'shell': 'bash'},
        },
      MessageTypes.terminalSubscribeRequest => {'slotId': 1},
      _ => const {},
    };
  }
}

Future<ProviderContainer> pumpChatScreen(
  WidgetTester tester, {
  FakeDaemonClient? client,
  String agentId = 'a1',
  List<AgentSummary> extraAgents = const [],
}) async {
  client ??= FakeDaemonClient(extraAgents: extraAgents);
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  container.read(agentsProvider.notifier).upsert(_agent);
  container.read(agentsProvider.notifier).upsert(_worktreeAgent);
  for (final agent in extraAgents) {
    container.read(agentsProvider.notifier).upsert(agent);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(content: AgentChatScreen(agentId: agentId)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('shows the agent header and empty-timeline placeholder',
      (tester) async {
    await pumpChatScreen(tester);

    expect(find.text('Demo agent'), findsOneWidget);
    expect(find.textContaining('claude · sonnet · normal · /work/demo'),
        findsOneWidget);
    expect(find.text('No messages yet. Say something below.'), findsOneWidget);
  });

  testWidgets('a agent.stream event renders the new timeline item',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 1,
        item: UserMessageItem(id: 'm1', text: 'hello world'),
      ).toJson(),
    ));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('hello world'), findsOneWidget);
    expect(find.text('No messages yet. Say something below.'), findsNothing);
  });

  testWidgets('archiving the agent requests agent.archive and removes it',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(container.read(agentsProvider).containsKey('a1'), isFalse);
  });

  testWidgets('a failed archive shows a snackbar and keeps the agent',
      (tester) async {
    final client = FailingArchiveClient()..failArchive = true;
    final container = await pumpChatScreen(tester, client: client);

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to archive'), findsOneWidget);
    expect(container.read(agentsProvider).containsKey('a1'), isTrue);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a worktree agent shows its branch in the header subtitle',
      (tester) async {
    await pumpChatScreen(tester, agentId: 'a2');

    expect(find.text('Worktree agent'), findsOneWidget);
    expect(
      find.textContaining('claude · sonnet · normal · feature/x · /work/repo-wt'),
      findsOneWidget,
    );
  });

  testWidgets(
      'archiving a worktree agent offers to remove the worktree; choosing '
      'Remove requests worktree.archive', (tester) async {
    final container = await pumpChatScreen(tester, agentId: 'a2');
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(find.text('Delete worktree?'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.worktreeArchiveRequest),
      isTrue,
    );
    final archived = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.worktreeArchiveRequest);
    expect(archived.$2['path'], '/work/repo-wt');
  });

  testWidgets(
      'archiving one of two agents sharing a worktree does not prompt to '
      'delete it', (tester) async {
    final container = await pumpChatScreen(
      tester,
      agentId: 'a2',
      extraAgents: [_worktreeAgentSibling],
    );
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(find.text('Delete worktree?'), findsNothing);
    expect(container.read(agentsProvider).containsKey('a3'), isTrue);
  });

  testWidgets(
      'archiving a worktree agent and choosing Keep does not remove the '
      'worktree', (tester) async {
    final container = await pumpChatScreen(tester, agentId: 'a2');
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive agent'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.worktreeArchiveRequest),
      isFalse,
    );
  });

  testWidgets(
      'scrolling away from the bottom shows a "jump to latest" button; '
      'tapping it scrolls back down and re-sticks', (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    // Populate enough messages to make the list scrollable.
    for (var i = 0; i < 40; i++) {
      client.eventsController.add(RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: i + 1,
          item: UserMessageItem(id: 'm$i', text: 'message number $i'),
        ).toJson(),
      ));
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byIcon(FluentIcons.down), findsNothing);

    // Manually scroll away from the bottom to trigger _onScroll.
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byIcon(FluentIcons.down), findsOneWidget);

    await tester.tap(find.byIcon(FluentIcons.down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byIcon(FluentIcons.down), findsNothing);
  });

  testWidgets(
      'responding to a permission via the timeline dispatches '
      'permission.respond.request, and a failure shows a snackbar',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 1,
        item: PermissionItem(
          id: 'perm-item',
          permissionId: 'perm-1',
          toolName: 'Bash',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'rm -rf /'),
        ),
      ).toJson(),
    ));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    // Success case.
    await tester.tap(find.text('Always allow'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      client.requests.any(
        (r) =>
            r.$1 == MessageTypes.permissionRespondRequest &&
            r.$2['decision'] == 'allow_always',
      ),
      isTrue,
    );

    // Failure case: script the next respond call to throw.
    client.failNextRespond = true;
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 2,
        item: PermissionItem(
          id: 'perm-item-2',
          permissionId: 'perm-2',
          toolName: 'Bash',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'echo hi'),
        ),
      ).toJson(),
    ));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Deny').last);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to respond'), findsOneWidget);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });
}

/// Variant of [FakeDaemonClient] whose `agent.archive.request` can be made to
/// fail, so the chat screen's failure-snackbar branch is exercisable.
class FailingArchiveClient extends FakeDaemonClient {
  bool failArchive = false;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentArchiveRequest && failArchive) {
      throw StateError('archive rejected');
    }
    return super.request(type, payload, timeout: timeout);
  }
}
