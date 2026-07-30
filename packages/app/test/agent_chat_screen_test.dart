import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:coding_agent_app/state/tool_call_detail_level_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:coding_agent_app/widgets/fluent/toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

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

const _managedChild = AgentSummary(
  agentId: 'child-agent',
  title: 'Managed child',
  cwd: '/work/child',
  provider: 'codex',
  model: 'gpt-5.4',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 1,
  parentAgentId: 'a1',
);

const _attentionAgent = AgentSummary(
  agentId: 'attention',
  title: 'Finished agent',
  cwd: '/work/attention',
  provider: 'codex',
  model: 'gpt-5.4',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 2,
  requiresAttention: true,
  attentionReason: AgentAttentionReason.finished,
  attentionTimestamp: '2026-07-26T00:00:00.000Z',
);

/// Scriptable fake covering what AgentChatScreen's chat-only view touches:
/// agent list (for the header) and the timeline fetch.
class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient({
    List<AgentSummary> extraAgents = const [],
    this.subagents = const [],
    DaemonConnectionState initialConnection = DaemonConnectionState.connected,
  }) : agents = [_agent, _worktreeAgent, ...extraAgents],
       _connectionState = initialConnection,
       super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  final requests = <(String, Map<String, Object?>)>[];
  final timelinePages = <AgentTimelinePage>[];
  final timelineErrors = <Object>[];
  Completer<AgentTimelinePage>? nextTimelinePage;
  final timelineDirections = <AgentTimelineDirection>[];
  Object? olderTimelineError;

  /// Mirrors `agentsProvider`'s state so the connect-triggered
  /// `agent.list.request` doesn't race a test's manually-upserted agents out
  /// with the two hardcoded defaults.
  final List<AgentSummary> agents;
  final List<ProviderSubagentDescriptor> subagents;
  DaemonConnectionState _connectionState;

  /// When true, the next `permission.respond.request` throws instead of
  /// responding (consumed after one use).
  bool failNextRespond = false;

  @override
  Stream<RpcEvent> get events => eventsController.stream;

  @override
  Stream<TerminalFrame> get terminalFrames => const Stream.empty();

  @override
  DaemonConnectionState get currentState => _connectionState;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      connectionController.stream;

  void setConnectionState(DaemonConnectionState value) {
    _connectionState = value;
    connectionController.add(value);
  }

  @override
  void sendTerminalFrame(TerminalFrame frame) {}

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async => ListCommandsResponse(
    agentId: agentId,
    commands: const [],
    requestId: 'commands-1',
  );

  @override
  Future<AgentTimelinePage> fetchAgentTimeline({
    required String agentId,
    AgentTimelineDirection direction = AgentTimelineDirection.tail,
    AgentTimelineCursor? cursor,
    int limit = agentTimelineFetchPageSize,
    AgentTimelineProjection projection = AgentTimelineProjection.projected,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    timelineDirections.add(direction);
    if (timelineErrors.isNotEmpty) {
      throw timelineErrors.removeAt(0);
    }
    final pendingPage = nextTimelinePage;
    if (pendingPage != null) {
      nextTimelinePage = null;
      return pendingPage.future;
    }
    final olderError = olderTimelineError;
    if (direction == AgentTimelineDirection.before && olderError != null) {
      throw olderError;
    }
    return timelinePages.isEmpty
        ? AgentTimelinePage.empty(
            agentId: agentId,
            direction: direction,
            projection: projection,
          )
        : timelinePages.removeAt(0);
  }

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
      MessageTypes.providerSubagentListRequest => {
        'subagents': subagents.map((subagent) => subagent.toJson()).toList(),
      },
      MessageTypes.agentDetachRequest => {
        'agent': agents
            .singleWhere((agent) => agent.agentId == payload['agentId'])
            .copyWith(clearParentAgentId: true)
            .toJson(),
      },
      MessageTypes.agentAttentionClearRequest => {
        'agent': agents
            .singleWhere((agent) => agent.agentId == payload['agentId'])
            .copyWith(requiresAttention: false, clearAttention: true)
            .toJson(),
      },
      MessageTypes.diffGetRequest => const DiffResponse(files: []).toJson(),
      MessageTypes.terminalCreateRequest => {
        'terminal': {'terminalId': 'term-1', 'shell': 'bash'},
      },
      MessageTypes.terminalSubscribeRequest => {'slotId': 1},
      _ => const {},
    };
  }
}

AgentTimelinePage timelinePage({
  required int start,
  required int end,
  required bool hasOlder,
  AgentTimelineDirection direction = AgentTimelineDirection.tail,
}) => AgentTimelinePage(
  requestId: 'test-page',
  agentId: 'a1',
  agent: null,
  direction: direction,
  projection: AgentTimelineProjection.projected,
  epoch: '0',
  reset: false,
  staleCursor: false,
  gap: false,
  window: const AgentTimelineWindow(minSeq: 1, maxSeq: 60, nextSeq: 61),
  startCursor: AgentTimelineCursor(epoch: '0', seq: start),
  endCursor: AgentTimelineCursor(epoch: '0', seq: end),
  hasOlder: hasOlder,
  hasNewer: direction != AgentTimelineDirection.tail,
  entries: [
    for (var seq = start; seq <= end; seq++)
      AgentTimelineEntry(
        provider: 'codex',
        item: AssistantMessageItem(
          id: 'message-$seq',
          text: 'timeline message $seq',
          complete: true,
        ),
        timestamp: '2026-07-28T00:00:00.000Z',
        seqStart: seq,
        seqEnd: seq,
        sourceSeqRanges: [AgentTimelineSeqRange(startSeq: seq, endSeq: seq)],
        collapsed: const [],
      ),
  ],
  error: null,
);

Future<ProviderContainer> pumpChatScreen(
  WidgetTester tester, {
  FakeDaemonClient? client,
  String agentId = 'a1',
  List<AgentSummary> extraAgents = const [],
  bool isScreenFocused = true,
  void Function(ProviderContainer container)? beforePump,
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
  beforePump?.call(container);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: AgentChatScreen(
            agentId: agentId,
            isScreenFocused: isScreenFocused,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

Future<void> pumpChatScreenFocus(
  WidgetTester tester,
  ProviderContainer container, {
  required bool isScreenFocused,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: AgentChatScreen(
            agentId: 'a1',
            isScreenFocused: isScreenFocused,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the agent header and empty-timeline placeholder', (
    tester,
  ) async {
    await pumpChatScreen(tester);

    expect(find.text('Demo agent'), findsOneWidget);
    expect(
      find.textContaining('claude · sonnet · normal · /work/demo'),
      findsOneWidget,
    );
    expect(find.text('No messages yet. Say something below.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-reconnecting-toast')),
      findsNothing,
    );
  });

  testWidgets(
    'cold-open timeline failure blocks the empty composer state and retries',
    (tester) async {
      final client = FakeDaemonClient()
        ..timelineErrors.add(StateError('history unavailable'));
      await pumpChatScreen(tester, client: client);

      expect(find.text('Failed to load conversation'), findsOneWidget);
      expect(find.textContaining('history unavailable'), findsOneWidget);
      expect(find.text('No messages yet. Say something below.'), findsNothing);
      expect(find.byType(TextBox), findsNothing);

      final retryPage = Completer<AgentTimelinePage>();
      client.nextTimelinePage = retryPage;
      await tester.tap(find.widgetWithText(Button, 'Retry'));
      await tester.pump();
      expect(find.byType(TextBox), findsNothing);
      expect(find.byType(ProgressRing), findsOneWidget);
      retryPage.complete(timelinePage(start: 1, end: 1, hasOlder: false));
      await tester.pump(const Duration(milliseconds: 150));

      expect(client.timelineDirections, [
        AgentTimelineDirection.tail,
        AgentTimelineDirection.tail,
      ]);
      expect(find.text('Failed to load conversation'), findsNothing);
      expect(find.text('timeline message 1'), findsOneWidget);
      expect(find.byType(TextBox), findsOneWidget);
    },
  );

  testWidgets('failed catch-up retains rendered conversation and composer', (
    tester,
  ) async {
    addTearDown(AppToast.dismissCurrent);
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);
    expect(find.text('timeline message 1'), findsOneWidget);

    client.timelineErrors.add(StateError('catch-up unavailable'));
    await container.read(timelineProvider('a1').notifier).retry();
    await tester.pump();

    expect(find.text('timeline message 1'), findsOneWidget);
    expect(find.text('Timeline sync failed'), findsOneWidget);
    expect(find.textContaining('catch-up unavailable'), findsNothing);
    expect(find.widgetWithText(Button, 'Retry'), findsNothing);
    expect(find.byType(TextBox), findsOneWidget);

    client.setConnectionState(DaemonConnectionState.disconnected);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Timeline sync failed'), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-reconnecting-toast')),
      findsOneWidget,
    );

    client.timelineErrors.add(StateError('still unavailable'));
    client.setConnectionState(DaemonConnectionState.connected);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Timeline sync failed'), findsOneWidget);
  });

  testWidgets(
    'temporary agent-directory gap retains the last ready agent presentation',
    (tester) async {
      addTearDown(AppToast.dismissCurrent);
      final client = FakeDaemonClient()
        ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
      final container = await pumpChatScreen(tester, client: client);

      expect(find.text('Demo agent'), findsOneWidget);
      expect(find.text('timeline message 1'), findsOneWidget);
      client.setConnectionState(DaemonConnectionState.disconnected);
      await tester.pump();
      container.read(agentsProvider.notifier).remove('a1');
      await tester.pump();

      expect(find.text('Demo agent'), findsOneWidget);
      expect(
        find.textContaining('claude · sonnet · normal · /work/demo'),
        findsOneWidget,
      );
      expect(find.text('timeline message 1'), findsOneWidget);
      expect(find.byType(TextBox), findsOneWidget);

      client.setConnectionState(DaemonConnectionState.connected);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('Demo agent'), findsOneWidget);

      container.read(agentsProvider.notifier).remove('a1');
      await tester.pump();
      expect(find.text('Demo agent'), findsNothing);
      expect(find.text('a1'), findsOneWidget);
    },
  );

  testWidgets('last ready agent presentation never leaks across route keys', (
    tester,
  ) async {
    addTearDown(AppToast.dismissCurrent);
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);
    client.setConnectionState(DaemonConnectionState.disconnected);
    await tester.pump();
    container.read(agentsProvider.notifier).remove('a1');
    await tester.pump();
    expect(find.text('Demo agent'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: AgentChatScreen(agentId: 'missing-agent'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('missing-agent'), findsOneWidget);
    expect(find.text('Demo agent'), findsNothing);
    expect(find.textContaining('/work/demo'), findsNothing);
  });

  testWidgets('foregrounding within visibility grace skips catch-up', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);
    expect(client.timelineDirections, [AgentTimelineDirection.tail]);

    await pumpChatScreenFocus(tester, container, isScreenFocused: false);
    await tester.pump(const Duration(seconds: 29));
    await pumpChatScreenFocus(tester, container, isScreenFocused: true);
    await tester.pump();

    expect(client.timelineDirections, [AgentTimelineDirection.tail]);
    expect(find.text('timeline message 1'), findsOneWidget);
  });

  testWidgets('foregrounding after visibility grace catches up silently when '
      'history is hydrated', (tester) async {
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);

    final resumedPage = Completer<AgentTimelinePage>();
    client.nextTimelinePage = resumedPage;
    await pumpChatScreenFocus(tester, container, isScreenFocused: false);
    await tester.pump(const Duration(seconds: 31));
    await pumpChatScreenFocus(tester, container, isScreenFocused: true);
    await tester.pump();

    expect(client.timelineDirections, [
      AgentTimelineDirection.tail,
      AgentTimelineDirection.tail,
    ]);
    expect(find.byKey(const ValueKey('agent-history-overlay')), findsNothing);
    expect(find.text('timeline message 1'), findsOneWidget);
    expect(find.byType(TextBox), findsOneWidget);

    resumedPage.complete(timelinePage(start: 1, end: 1, hasOlder: false));
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('entering a newly visible unhydrated route shows catch-up '
      'overlay until its authoritative page arrives', (tester) async {
    final client = FakeDaemonClient()
      ..timelineErrors.add(StateError('initial history unavailable'));
    final container = await pumpChatScreen(
      tester,
      client: client,
      isScreenFocused: false,
    );
    expect(find.text('Failed to load conversation'), findsOneWidget);

    final visiblePage = Completer<AgentTimelinePage>();
    client.nextTimelinePage = visiblePage;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(content: AgentChatScreen(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('agent-history-overlay')), findsOneWidget);
    expect(find.text('Failed to load conversation'), findsNothing);
    expect(find.byType(TextBox), findsOneWidget);

    visiblePage.complete(
      AgentTimelinePage.empty(
        agentId: 'a1',
        direction: AgentTimelineDirection.tail,
        projection: AgentTimelineProjection.projected,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byKey(const ValueKey('agent-history-overlay')), findsNothing);
    expect(find.text('No messages yet. Say something below.'), findsOneWidget);
  });

  testWidgets('ready conversation keeps reconnect toast until online', (
    tester,
  ) async {
    addTearDown(AppToast.dismissCurrent);
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);

    client.setConnectionState(DaemonConnectionState.disconnected);
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      container.read(connectionStateProvider).value,
      DaemonConnectionState.disconnected,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      find.byKey(const ValueKey('agent-reconnecting-toast')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 5));
    expect(
      find.byKey(const ValueKey('agent-reconnecting-toast')),
      findsOneWidget,
    );

    client.setConnectionState(DaemonConnectionState.connected);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Reconnecting…'), findsNothing);
  });

  testWidgets('online recovery cannot dismiss a replacement toast', (
    tester,
  ) async {
    addTearDown(AppToast.dismissCurrent);
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 1, end: 1, hasOlder: false));
    final container = await pumpChatScreen(tester, client: client);

    client.setConnectionState(DaemonConnectionState.disconnected);
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      container.read(connectionStateProvider).value,
      DaemonConnectionState.disconnected,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Reconnecting…'), findsOneWidget);

    AppToast.show(
      tester.element(find.text('Demo agent')),
      'Unrelated notice',
      duration: null,
    );
    await tester.pump();
    expect(find.text('Unrelated notice'), findsOneWidget);

    client.setConnectionState(DaemonConnectionState.connected);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Unrelated notice'), findsOneWidget);
    AppToast.dismissCurrent();
  });

  testWidgets(
    'overview setting groups consecutive tool calls in the timeline',
    (tester) async {
      final client = FakeDaemonClient();
      await pumpChatScreen(
        tester,
        client: client,
        beforePump: (container) {
          unawaited(
            container
                .read(toolCallDetailLevelProvider.notifier)
                .setLevel(ToolCallDetailLevel.overview),
          );
        },
      );

      client.eventsController
        ..add(
          RpcEvent(
            type: MessageTypes.agentStreamEvent,
            payload: AgentStreamPayload(
              agentId: 'a1',
              epoch: 0,
              seq: 1,
              item: const ToolCallItem(
                id: 'tool-1',
                toolName: 'Bash',
                status: ToolCallStatus.success,
                detail: ShellDetail(command: 'dart test'),
              ),
            ).toJson(),
          ),
        )
        ..add(
          RpcEvent(
            type: MessageTypes.agentStreamEvent,
            payload: AgentStreamPayload(
              agentId: 'a1',
              epoch: 0,
              seq: 2,
              item: const ToolCallItem(
                id: 'tool-2',
                toolName: 'Read',
                status: ToolCallStatus.success,
                detail: ReadDetail(path: 'lib/main.dart'),
              ),
            ).toJson(),
          ),
        );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Ran 1 command and read 1 file'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tool-call-group-tool-1')),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.text('Ran 1 command and read 1 file'),
          matching: find.byType(Expander),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('created-agent handoff reconciles into the canonical user row', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpChatScreen(
      tester,
      client: client,
      beforePump: (current) {
        current
            .read(timelineProvider('a1').notifier)
            .handoffCreatedUserMessage(
              OptimisticUserMessage(
                id: 'message-1',
                text: 'optimistic prompt',
                timestamp: 123,
                images: const [],
                attachments: const [],
              ),
            );
      },
    );

    expect(find.text('optimistic prompt'), findsOneWidget);
    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 1,
          item: const UserMessageItem(id: 'message-1', text: 'server prompt'),
        ).toJson(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('optimistic prompt'), findsOneWidget);
    expect(find.text('server prompt'), findsNothing);
    final timeline = container.read(timelineProvider('a1'));
    expect(timeline.pendingUserMessages, isEmpty);
    expect(
      timeline.userMessagePresentations['message-1']?.text,
      'optimistic prompt',
    );
  });

  testWidgets('focus entry acknowledges finished unread attention', (
    tester,
  ) async {
    final client = FakeDaemonClient(extraAgents: const [_attentionAgent]);
    final container = await pumpChatScreen(
      tester,
      client: client,
      agentId: 'attention',
      extraAgents: const [_attentionAgent],
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any(
        (request) =>
            request.$1 == MessageTypes.agentAttentionClearRequest &&
            request.$2['agentId'] == 'attention',
      ),
      isTrue,
    );
    expect(
      container.read(agentsProvider)['attention']?.requiresAttention,
      isFalse,
    );
  });

  testWidgets(
    'new attention while viewed defers clear until composer interaction',
    (tester) async {
      final client = FakeDaemonClient();
      final container = await pumpChatScreen(tester, client: client);
      client.requests.clear();

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(
            agent: _agent.copyWith(
              requiresAttention: true,
              attentionReason: AgentAttentionReason.finished,
              attentionTimestamp: '2026-07-26T00:00:00.000Z',
            ),
          ).toJson(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        client.requests.where(
          (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
        ),
        isEmpty,
      );

      await tester.tap(find.byType(TextBox));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        client.requests.where(
          (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
        ),
        hasLength(1),
      );
      expect(container.read(agentsProvider)['a1']?.requiresAttention, isFalse);
    },
  );

  testWidgets('resuming into a focused agent clears existing attention', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final client = FakeDaemonClient(extraAgents: const [_attentionAgent]);
    final container = await pumpChatScreen(
      tester,
      client: client,
      agentId: 'attention',
      extraAgents: const [_attentionAgent],
    );

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
      ),
      isEmpty,
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
      ),
      hasLength(1),
    );
    expect(
      container.read(agentsProvider)['attention']?.requiresAttention,
      isFalse,
    );
  });

  testWidgets('entering the active tab clears existing attention', (
    tester,
  ) async {
    final client = FakeDaemonClient(extraAgents: const [_attentionAgent]);
    final container = await pumpChatScreen(
      tester,
      client: client,
      agentId: 'attention',
      extraAgents: const [_attentionAgent],
      isScreenFocused: false,
    );

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
      ),
      isEmpty,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: AgentChatScreen(
              agentId: 'attention',
              isScreenFocused: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
      ),
      hasLength(1),
    );
  });

  testWidgets('leaving the active tab clears deferred attention', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpChatScreen(tester, client: client);
    client.requests.clear();
    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: AgentStatePayload(
          agent: _agent.copyWith(
            requiresAttention: true,
            attentionReason: AgentAttentionReason.finished,
            attentionTimestamp: '2026-07-26T00:00:00.000Z',
          ),
        ).toJson(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: AgentChatScreen(agentId: 'a1', isScreenFocused: false),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentAttentionClearRequest,
      ),
      hasLength(1),
    );
  });

  testWidgets('a agent.stream event renders the new timeline item', (
    tester,
  ) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: const AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 1,
          item: UserMessageItem(id: 'm1', text: 'hello world'),
        ).toJson(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('hello world'), findsOneWidget);
    expect(find.text('No messages yet. Say something below.'), findsNothing);
  });

  testWidgets('provider subagent track opens an addressable child tab', (
    tester,
  ) async {
    final client = FakeDaemonClient(
      subagents: const [
        ProviderSubagentDescriptor(
          id: 'child',
          parentAgentId: 'a1',
          provider: 'codex',
          title: 'Research',
          status: ProviderSubagentStatus.running,
          createdAt: '2026-07-26T00:00:00.000Z',
          updatedAt: '2026-07-26T00:00:00.000Z',
        ),
      ],
    );
    final container = await pumpChatScreen(tester, client: client);

    expect(find.text('1 subagent · 1 running'), findsOneWidget);
    expect(find.text('Research'), findsNothing);
    await tester.tap(find.text('1 subagent · 1 running'));
    await tester.pump();
    expect(find.text('Research'), findsOneWidget);
    await tester.tap(find.text('Research'));
    await tester.pump(const Duration(milliseconds: 150));

    final tabs = container
        .read(worktreeTabsProvider(_agent.cwd))
        .layout
        .tabs
        .where((tab) => tab.kind == WorktreeTabKind.providerSubagent);
    expect(tabs, hasLength(1));
    expect(tabs.single.parentAgentId, 'a1');
    expect(tabs.single.subagentId, 'child');
  });

  testWidgets('managed subagent row opens, detaches, and archives', (
    tester,
  ) async {
    final client = FakeDaemonClient(extraAgents: const [_managedChild]);
    final container = await pumpChatScreen(
      tester,
      client: client,
      extraAgents: const [_managedChild],
    );

    expect(find.text('1 subagent · 1 running'), findsOneWidget);
    await tester.tap(find.text('1 subagent · 1 running'));
    await tester.pump();
    expect(find.text('Managed child'), findsOneWidget);

    await tester.tap(find.text('Managed child'));
    await tester.pump();
    expect(container.read(selectedWorktreeProvider), '/work/child');
    expect(
      container
          .read(worktreeTabsProvider('/work/child'))
          .layout
          .tabs
          .where((tab) => tab.agentId == 'child-agent'),
      hasLength(1),
    );

    container.read(selectedWorktreeProvider.notifier).select(null);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Detach subagent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Detach subagent?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.widgetWithText(FilledButton, 'Detach'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      client.requests.any(
        (request) => request.$1 == MessageTypes.agentDetachRequest,
      ),
      isTrue,
    );
    expect(
      container.read(agentsProvider)['child-agent']?.parentAgentId,
      isNull,
    );
    expect(container.read(selectedWorktreeProvider), '/work/child');

    // Put the child back under the parent to exercise the row archive action.
    container.read(agentsProvider.notifier).upsert(_managedChild);
    await tester.pump();
    await tester.tap(find.text('1 subagent · 1 running'));
    await tester.pump();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Archive subagent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Archive running subagent?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.widgetWithText(FilledButton, 'Archive'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      client.requests.any(
        (request) =>
            request.$1 == MessageTypes.agentArchiveRequest &&
            request.$2['agentId'] == 'child-agent',
      ),
      isTrue,
    );
    expect(container.read(agentsProvider).containsKey('child-agent'), isFalse);
  });

  testWidgets('managed subagent actions honor confirmation cancellation', (
    tester,
  ) async {
    final client = FakeDaemonClient(extraAgents: const [_managedChild]);
    await pumpChatScreen(
      tester,
      client: client,
      extraAgents: const [_managedChild],
    );

    await tester.tap(find.text('1 subagent · 1 running'));
    await tester.pump();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Detach subagent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.widgetWithText(Button, 'Cancel'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Archive subagent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.widgetWithText(Button, 'Cancel'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.where(
        (request) =>
            request.$1 == MessageTypes.agentDetachRequest ||
            request.$1 == MessageTypes.agentArchiveRequest,
      ),
      isEmpty,
    );
  });

  testWidgets('archive finished hides completed provider children', (
    tester,
  ) async {
    final client = FakeDaemonClient(
      subagents: const [
        ProviderSubagentDescriptor(
          id: 'done',
          parentAgentId: 'a1',
          provider: 'codex',
          title: 'Finished child',
          status: ProviderSubagentStatus.completed,
          createdAt: '2026-07-26T00:00:00.000Z',
          updatedAt: '2026-07-26T00:01:00.000Z',
        ),
      ],
    );
    await pumpChatScreen(tester, client: client);

    expect(find.text('1 subagent'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Archive finished',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1 subagent'), findsNothing);
  });

  testWidgets('archiving the agent requests agent.archive and removes it', (
    tester,
  ) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Archive agent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(container.read(agentsProvider).containsKey('a1'), isFalse);
  });

  testWidgets('/clear archives the agent and opens a configured fresh draft', (
    tester,
  ) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.enterText(find.byType(TextBox), '/clear');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('composer-command-autocomplete-clear')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any(
        (request) =>
            request.$1 == MessageTypes.agentArchiveRequest &&
            request.$2['agentId'] == 'a1',
      ),
      isTrue,
    );
    final drafts = container
        .read(worktreeTabsProvider('/work/demo'))
        .layout
        .tabs
        .where((tab) => tab.kind == WorktreeTabKind.draft);
    expect(drafts, hasLength(1));
  });

  testWidgets('/exit uses the current agent archive flow', (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.enterText(find.byType(TextBox), '/exit');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('composer-command-autocomplete-exit')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any(
        (request) =>
            request.$1 == MessageTypes.agentArchiveRequest &&
            request.$2['agentId'] == 'a1',
      ),
      isTrue,
    );
  });

  testWidgets('a failed archive shows a snackbar and keeps the agent', (
    tester,
  ) async {
    final client = FailingArchiveClient()..failArchive = true;
    final container = await pumpChatScreen(tester, client: client);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Archive agent',
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to archive'), findsOneWidget);
    expect(container.read(agentsProvider).containsKey('a1'), isTrue);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a worktree agent shows its branch in the header subtitle', (
    tester,
  ) async {
    await pumpChatScreen(tester, agentId: 'a2');

    expect(find.text('Worktree agent'), findsOneWidget);
    expect(
      find.textContaining(
        'claude · sonnet · normal · feature/x · /work/repo-wt',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'archiving a worktree agent offers to remove the worktree; choosing '
    'Remove requests worktree.archive',
    (tester) async {
      final container = await pumpChatScreen(tester, agentId: 'a2');
      final client = container.read(daemonClientProvider) as FakeDaemonClient;

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Archive agent',
        ),
      );
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
      final archived = client.requests.singleWhere(
        (r) => r.$1 == MessageTypes.worktreeArchiveRequest,
      );
      expect(archived.$2['path'], '/work/repo-wt');
    },
  );

  testWidgets(
    'archiving one of two agents sharing a worktree does not prompt to '
    'delete it',
    (tester) async {
      final container = await pumpChatScreen(
        tester,
        agentId: 'a2',
        extraAgents: [_worktreeAgentSibling],
      );
      final client = container.read(daemonClientProvider) as FakeDaemonClient;

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Archive agent',
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
        isTrue,
      );
      expect(find.text('Delete worktree?'), findsNothing);
      expect(container.read(agentsProvider).containsKey('a3'), isTrue);
    },
  );

  testWidgets(
    'archiving a worktree agent and choosing Keep does not remove the '
    'worktree',
    (tester) async {
      final container = await pumpChatScreen(tester, agentId: 'a2');
      final client = container.read(daemonClientProvider) as FakeDaemonClient;

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Archive agent',
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(
        client.requests.any((r) => r.$1 == MessageTypes.worktreeArchiveRequest),
        isFalse,
      );
    },
  );

  testWidgets('scrolling away from the bottom shows a "jump to latest" button; '
      'tapping it scrolls back down and re-sticks', (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    // Populate enough messages to make the list scrollable.
    for (var i = 0; i < 40; i++) {
      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: AgentStreamPayload(
            agentId: 'a1',
            epoch: 0,
            seq: i + 1,
            item: UserMessageItem(id: 'm$i', text: 'message number $i'),
          ).toJson(),
        ),
      );
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
    'reaching the 96px top edge loads older history without jumping rows',
    (tester) async {
      final client = FakeDaemonClient()
        ..timelinePages.addAll([
          timelinePage(start: 31, end: 60, hasOlder: true),
          timelinePage(
            start: 1,
            end: 30,
            hasOlder: false,
            direction: AgentTimelineDirection.before,
          ),
        ]);
      await pumpChatScreen(tester, client: client);
      final list = tester.widget<ListView>(find.byType(ListView).first);
      final controller = list.controller!;
      expect(controller.position.pixels, controller.position.maxScrollExtent);
      final oldExtent = controller.position.maxScrollExtent;

      await tester.drag(find.byType(ListView).first, const Offset(0, 10000));
      await tester.pump();
      await tester.pump();

      expect(client.timelineDirections, [
        AgentTimelineDirection.tail,
        AgentTimelineDirection.before,
      ]);
      expect(controller.position.maxScrollExtent, greaterThan(oldExtent));
      expect(controller.position.pixels, greaterThan(0));
      expect(find.text('timeline message 31'), findsOneWidget);
    },
  );

  testWidgets('older history failure is surfaced as a toast', (tester) async {
    final client = FakeDaemonClient()
      ..timelinePages.add(timelinePage(start: 31, end: 60, hasOlder: true))
      ..olderTimelineError = StateError('history unavailable');
    await pumpChatScreen(tester, client: client);

    await tester.drag(find.byType(ListView).first, const Offset(0, 10000));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('Failed to load older messages:'),
      findsOneWidget,
    );
    expect(client.timelineDirections.last, AgentTimelineDirection.before);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('responding to a permission via the timeline dispatches '
      'permission.respond.request, and a failure shows a snackbar', (
    tester,
  ) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(
      RpcEvent(
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
      ),
    );
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
    client.eventsController.add(
      RpcEvent(
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
      ),
    );
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
