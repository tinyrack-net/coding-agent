import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/keyboard/keyboard_action_dispatcher.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/state/workspace_focus_mode_provider.dart';
import 'package:coding_agent_app/state/workspace_setup_provider.dart';
import 'package:coding_agent_app/state/workspace_tab_keyboard_drag_provider.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:coding_agent_app/widgets/worktree_tabbed_pane.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:coding_agent_app/workspace/workspace_tab_drag_accessibility.dart';
import 'package:coding_agent_app/workspace/workspace_tab_layout.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

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

const _managedChild = AgentSummary(
  agentId: 'child',
  title: 'Managed child',
  cwd: _worktreePath,
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 1,
  parentAgentId: 'parent',
);

const _thirdAgent = AgentSummary(
  agentId: 'a3',
  title: 'Third agent',
  cwd: _worktreePath,
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 2,
);

const _fourthAgent = AgentSummary(
  agentId: 'a4',
  title: 'Fourth agent',
  cwd: _worktreePath,
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 3,
);

class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'fake',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {'workspaceFileEditing': true},
    );
  }

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
  Future<AgentTimelinePage> fetchAgentTimeline({
    required String agentId,
    AgentTimelineDirection direction = AgentTimelineDirection.tail,
    AgentTimelineCursor? cursor,
    int limit = agentTimelineFetchPageSize,
    AgentTimelineProjection projection = AgentTimelineProjection.projected,
    Duration timeout = const Duration(seconds: 30),
  }) async => AgentTimelinePage.empty(
    agentId: agentId,
    direction: direction,
    projection: projection,
  );

  @override
  void sendSessionMessage(Map<String, Object?> message) {
    requests.add((message['type']! as String, message));
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type']! as String;
    requests.add((type, message));
    return switch (type) {
      CreateTerminalRequest.type => {
        'type': 'create_terminal_response',
        'payload': {
          'terminal': {
            'id': 'term-1',
            'name': 'Terminal 1',
            'cwd': message['cwd'],
          },
          'requestId': message['requestId'],
        },
      },
      SubscribeTerminalRequest.type => {
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': message['terminalId'],
          'slot': 1,
          'requestId': message['requestId'],
        },
      },
      KillTerminalRequest.type => {
        'type': 'kill_terminal_response',
        'payload': {
          'terminalId': message['terminalId'],
          'success': true,
          'requestId': message['requestId'],
        },
      },
      CheckoutPrStatusRequest.type => CheckoutPrStatusResponse(
        cwd: message['cwd']! as String,
        status: null,
        error: null,
        requestId: message['requestId']! as String,
        githubFeaturesEnabled: true,
        authState: null,
      ).toJson(),
      CheckoutStatusRequest.type => CheckoutStatusResponse(
        CheckoutStatusGitNonPaseo(
          cwd: message['cwd']! as String,
          repoRoot: '/repo',
          mainRepoRoot: null,
          currentBranch: 'main',
          isDirty: false,
          baseRef: null,
          aheadBehind: null,
          aheadOfOrigin: null,
          behindOfOrigin: null,
          hasRemote: false,
          remoteUrl: null,
          error: null,
          requestId: message['requestId']! as String,
        ),
      ).toJson(),
      SubscribeCheckoutDiffRequest.type => SubscribeCheckoutDiffResponse(
        payload: CheckoutDiffPayload(
          subscriptionId: message['subscriptionId']! as String,
          cwd: message['cwd']! as String,
          files: const [],
          error: null,
        ),
        requestId: message['requestId']! as String,
      ).toJson(),
      'file_explorer_request' => _fileExplorerResponse(message),
      _ => {'type': '${type}_response', 'payload': const {}},
    };
  }

  Map<String, Object?> _fileExplorerResponse(Map<String, Object?> message) {
    final path = message['path'] ?? '.';
    final fileMode = message['mode'] == 'file';
    return {
      'type': 'file_explorer_response',
      'payload': {
        'cwd': _worktreePath,
        'path': path,
        'mode': fileMode ? 'file' : 'list',
        'directory': fileMode
            ? null
            : {
                'path': path,
                'entries': [
                  {
                    'name': 'README.md',
                    'path': 'README.md',
                    'kind': 'file',
                    'size': 128,
                  },
                ],
              },
        'file': fileMode
            ? {
                'path': path,
                'kind': 'text',
                'encoding': 'utf-8',
                'content': 'first line\nselected line\nlast line',
                'mimeType': 'text/plain',
                'size': 34,
                'modifiedAt': '2026-07-27T00:00:00.000Z',
                'revision': 'revision',
              }
            : null,
        'error': null,
        'requestId': message['requestId'],
      },
    };
  }

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
      MessageTypes.providerSubagentListRequest => {
        'subagents': [
          const ProviderSubagentDescriptor(
            id: 'child',
            parentAgentId: 'a1',
            provider: 'codex',
            title: 'Research',
            status: ProviderSubagentStatus.running,
            createdAt: '2026-07-26T00:00:00.000Z',
            updatedAt: '2026-07-26T00:00:00.000Z',
          ).toJson(),
        ],
      },
      MessageTypes.providerSubagentTimelineRequest =>
        const ProviderSubagentTimelineResponse(
          parentAgentId: 'a1',
          subagentId: 'child',
          provider: 'codex',
          direction: ProviderSubagentTimelineDirection.tail,
          epoch: 'epoch',
          reset: false,
          staleCursor: false,
          gap: false,
          window: ProviderSubagentTimelineWindow(
            minSeq: 1,
            maxSeq: 1,
            nextSeq: 2,
          ),
          hasOlder: false,
          hasNewer: false,
          rows: [
            ProviderSubagentTimelineRow(
              item: AssistantMessageItem(
                id: 'answer',
                text: 'child result',
                complete: true,
              ),
              timestamp: '2026-07-26T00:00:00.000Z',
              seq: 1,
            ),
          ],
        ).toJson(),
      _ => const {},
    };
  }
}

Finder _closeButtonFor(String tabLabel) =>
    find.byKey(ValueKey('workspace-tab-close-label-$tabLabel'));

Finder _setupTabIcon(IconData icon) => find.descendant(
  of: find.byKey(const ValueKey('workspace-tab-drop-setup_workspace-1')),
  matching: find.byIcon(icon),
);

Future<ProviderContainer> pumpPane(
  WidgetTester tester, {
  FakeDaemonClient? client,
  List<AgentSummary> agents = const [],
  String? projectPath,
  bool isWorktree = false,
  String? workspaceId,
  WorkspaceTabDragAnnouncer? dragAnnouncer,
}) async {
  final resolvedClient = client ?? FakeDaemonClient();
  resolvedClient.agents = agents;
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(resolvedClient),
      if (dragAnnouncer != null)
        workspaceTabDragAnnouncerProvider.overrideWithValue(dragAnnouncer),
    ],
  );
  addTearDown(container.dispose);
  for (final agent in agents) {
    container.read(agentsProvider.notifier).upsert(agent);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        theme: buildAppTheme(),
        home: ScaffoldPage(
          content: WorktreeTabbedPane(
            worktreePath: _worktreePath,
            projectPath: projectPath,
            isWorktree: isWorktree,
            workspaceId: workspaceId,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('setup tab renders cached commands and carriage-return log', (
    tester,
  ) async {
    final container = await pumpPane(tester, workspaceId: 'workspace-1');
    container
        .read(workspaceSetupStoreProvider.notifier)
        .upsert(
          serverId: 'fake',
          workspaceId: 'workspace-1',
          snapshot: const WorkspaceSetupSnapshot(
            status: WorkspaceSetupStatus.running,
            detail: WorkspaceSetupDetail(
              worktreePath: _worktreePath,
              branchName: 'feature',
              log: 'downloading 20%\rdownloading 100%',
              commands: [
                WorkspaceSetupCommand(
                  index: 1,
                  command: 'flutter pub get',
                  cwd: _worktreePath,
                  status: WorkspaceSetupCommandStatus.running,
                  exitCode: null,
                  durationMs: 2500,
                ),
              ],
            ),
            error: null,
          ),
        );
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusOpenIntentTarget(
          const WorkspaceSetupTabTarget(workspaceId: 'workspace-1'),
        );
    await tester.pump();

    expect(find.byKey(const ValueKey('workspace-setup-panel')), findsOneWidget);
    expect(find.text('flutter pub get'), findsOneWidget);
    expect(find.text('2s'), findsOneWidget);
    expect(find.text('downloading 100%'), findsOneWidget);
    expect(find.textContaining('20%'), findsNothing);
    expect(_setupTabIcon(FluentIcons.command_prompt), findsOneWidget);
  });

  testWidgets('setup tab shows completed empty and failed error states', (
    tester,
  ) async {
    final container = await pumpPane(tester, workspaceId: 'workspace-1');
    final store = container.read(workspaceSetupStoreProvider.notifier);
    store.upsert(
      serverId: 'fake',
      workspaceId: 'workspace-1',
      snapshot: const WorkspaceSetupSnapshot(
        status: WorkspaceSetupStatus.completed,
        detail: WorkspaceSetupDetail(
          worktreePath: _worktreePath,
          branchName: 'feature',
          log: '',
          commands: [],
        ),
        error: null,
      ),
    );
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusOpenIntentTarget(
          const WorkspaceSetupTabTarget(workspaceId: 'workspace-1'),
        );
    await tester.pump();
    expect(find.text('No setup commands were run.'), findsOneWidget);
    expect(_setupTabIcon(FluentIcons.completed_solid), findsOneWidget);

    store.upsert(
      serverId: 'fake',
      workspaceId: 'workspace-1',
      snapshot: const WorkspaceSetupSnapshot(
        status: WorkspaceSetupStatus.failed,
        detail: WorkspaceSetupDetail(
          worktreePath: _worktreePath,
          branchName: 'feature',
          log: '',
          commands: [],
        ),
        error: 'Bootstrap failed',
      ),
    );
    await tester.pump();
    expect(find.text('Bootstrap failed'), findsOneWidget);
    expect(_setupTabIcon(FluentIcons.error_badge), findsOneWidget);
  });

  testWidgets(
    'pane shortcuts split, focus, move, close, and toggle focus mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await pumpPane(tester, agents: [_idleAgent]);
      bool dispatch(String id) => keyboardActionDispatcher.dispatch(
        KeyboardActionDefinition(id: id, scope: KeyboardActionScope.workspace),
      );

      expect(dispatch('workspace.pane.split.right'), isTrue);
      await tester.pump();
      var layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(collectWorkspacePanes(layout.paneLayout!.root), hasLength(2));
      expect(find.byKey(const ValueKey('workspace-pane-pane_root')), findsOne);

      expect(dispatch('workspace.pane.focus.left'), isTrue);
      layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(layout.paneLayout!.focusedPaneId, 'pane_root');

      expect(dispatch('workspace.pane.move-tab.right'), isTrue);
      await tester.pump();
      layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(collectWorkspacePanes(layout.paneLayout!.root), hasLength(1));

      expect(container.read(workspaceFocusModeProvider), isFalse);
      expect(dispatch('workspace.focus.toggle'), isTrue);
      await tester.pump();
      expect(container.read(workspaceFocusModeProvider), isTrue);

      expect(dispatch('workspace.pane.split.down'), isTrue);
      await tester.pump();
      expect(dispatch('workspace.pane.close'), isTrue);
      await tester.pump();
      layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(collectWorkspacePanes(layout.paneLayout!.root), hasLength(1));
    },
  );

  testWidgets('close-current shortcut closes the active workspace tab', (
    tester,
  ) async {
    final container = await pumpPane(tester);
    final before = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .activeTabId;

    expect(
      keyboardActionDispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'workspace.tab.close.current',
          scope: KeyboardActionScope.workspace,
        ),
      ),
      isTrue,
    );
    await tester.pump();

    final after = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .activeTabId;
    expect(after, isNot(before));
  });

  testWidgets('archive shortcut archives the active isolated workspace', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpPane(
      tester,
      client: client,
      projectPath: '/repo',
      isWorktree: true,
    );

    expect(
      keyboardActionDispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'workspace.archive',
          scope: KeyboardActionScope.sidebar,
        ),
      ),
      isTrue,
    );
    await tester.pump();

    expect(
      client.requests.map((request) => request.$1),
      contains(MessageTypes.worktreeArchiveRequest),
    );
  });

  testWidgets(
    'split divider drag resizes panes and persists normalized sizes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await pumpPane(tester, agents: [_idleAgent]);
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      notifier.splitFocusedPane(WorkspaceSplitDirection.horizontal);
      await tester.pump();

      var paneLayout = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .paneLayout!;
      final group = paneLayout.root as WorkspacePaneGroup;
      final handle = find.byKey(ValueKey('workspace-resize-${group.id}-0'));
      expect(handle, findsOneWidget);

      await tester.drag(handle, const Offset(220, 0));
      await tester.pump();

      paneLayout = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .paneLayout!;
      final sizes = (paneLayout.root as WorkspacePaneGroup).sizes;
      expect(sizes[0], greaterThan(.5));
      expect(sizes[1], greaterThanOrEqualTo(WorkspacePaneLayout.minSplitSize));
      expect(sizes.reduce((left, right) => left + right), closeTo(1, 1e-9));
    },
  );

  testWidgets('vertical divider exposes hover affordance and resizes rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
    );
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    notifier.splitFocusedPane(WorkspaceSplitDirection.vertical);
    await tester.pump();
    var paneLayout = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .paneLayout!;
    final group = paneLayout.root as WorkspacePaneGroup;
    final handle = find.byKey(ValueKey('workspace-resize-${group.id}-0'));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pump();
    await mouse.moveTo(Offset.zero);
    await mouse.removePointer();
    await tester.pump();

    await tester.drag(handle, const Offset(0, 120));
    await tester.pump();
    paneLayout = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .paneLayout!;
    final sizes = (paneLayout.root as WorkspacePaneGroup).sizes;
    expect(sizes.first, greaterThan(.5));
    expect(sizes.last, greaterThanOrEqualTo(WorkspacePaneLayout.minSplitSize));
  });

  testWidgets('mouse tab drag reorders tabs within the same pane', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
    );
    final state = container.read(worktreeTabsProvider(_worktreePath));
    final first = state.layout.tabs.first;
    final second = state.layout.tabs.last;
    final source = find.byKey(ValueKey('workspace-tab-drag-${first.tabId}'));
    final target = find.byKey(ValueKey('workspace-tab-drop-${second.tabId}'));
    final targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveTo(Offset(targetRect.right - 2, targetRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final reordered = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      findWorkspacePane(reordered.layout.paneLayout!.root, 'pane_root')!.tabIds,
      [second.tabId, first.tabId],
    );
  });

  testWidgets(
    'pointer sensor stays pending through 8 pixels and activates beyond it '
    'for mouse and touch',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await pumpPane(
        tester,
        agents: [_idleAgent, _runningAgent],
      );
      final tabId = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .first
          .tabId;
      final source = find.byKey(ValueKey('workspace-tab-drag-$tabId'));
      final feedback = find.byKey(
        ValueKey('workspace-tab-drag-feedback-$tabId'),
      );

      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        final gesture = await tester.startGesture(
          tester.getCenter(source),
          kind: kind,
        );
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump();
        expect(feedback, findsNothing, reason: '$kind must not activate at 8');

        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        expect(
          feedback,
          findsOneWidget,
          reason: '$kind must activate beyond 8',
        );
        final feedbackContainer = tester.widget<Container>(feedback);
        final feedbackDecoration =
            feedbackContainer.decoration! as BoxDecoration;
        final palette = paseoPaletteFor(AppThemeName.dark);
        expect(
          feedbackContainer.constraints,
          const BoxConstraints.tightFor(width: 200, height: 29),
        );
        expect(
          feedbackContainer.padding,
          const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        );
        expect(feedbackDecoration.color, palette.surface1);
        expect(feedbackDecoration.borderRadius, BorderRadius.circular(6));
        expect(feedbackDecoration.border!.top.width, 1);
        expect(feedbackDecoration.border!.top.color, palette.borderAccent);
        expect(
          tester
              .widget<Icon>(
                find.byKey(ValueKey('workspace-tab-drag-feedback-icon-$tabId')),
              )
              .color,
          palette.foreground,
        );
        expect(
          find.byKey(ValueKey('workspace-tab-drag-feedback-icon-$tabId')),
          findsOneWidget,
        );
        final feedbackText = tester.widget<Text>(
          find.descendant(of: feedback, matching: find.text(_idleAgent.title)),
        );
        expect(feedbackText.maxLines, 1);
        expect(feedbackText.style!.fontSize, 14);
        expect(feedbackText.style!.color, palette.foreground);
        expect(
          tester
              .widgetList<Opacity>(
                find.descendant(of: source, matching: find.byType(Opacity)),
              )
              .any((widget) => widget.opacity == .3),
          isTrue,
          reason: '$kind source must match Paseo external-drag opacity',
        );

        await gesture.cancel();
        await tester.pump();
        expect(feedback, findsNothing);
      }
    },
  );

  testWidgets('touch tab drag reorders tabs after the 8 pixel threshold', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
    );
    final state = container.read(worktreeTabsProvider(_worktreePath));
    final first = state.layout.tabs.first;
    final second = state.layout.tabs.last;
    final source = find.byKey(ValueKey('workspace-tab-drag-${first.tabId}'));
    final target = find.byKey(ValueKey('workspace-tab-drop-${second.tabId}'));
    final targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(9, 0));
    await tester.pump();
    await gesture.moveTo(Offset(targetRect.right - 2, targetRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final reordered = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      findWorkspacePane(reordered.layout.paneLayout!.root, 'pane_root')!.tabIds,
      [second.tabId, first.tabId],
    );
  });

  testWidgets(
    'Escape cancels an active pointer drag and announces dnd-kit cancellation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final announcements = <String>[];
      final container = await pumpPane(
        tester,
        agents: [_idleAgent, _runningAgent],
        dragAnnouncer: (_, message) => announcements.add(message),
      );
      final tabId = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .first
          .tabId;
      final source = find.byKey(ValueKey('workspace-tab-drag-$tabId'));
      final feedback = find.byKey(
        ValueKey('workspace-tab-drag-feedback-$tabId'),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(9, 0));
      await tester.pump();
      expect(feedback, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(feedback, findsNothing);

      final activeId = '$tabId:agent';
      expect(announcements.first, workspaceTabDragStartAnnouncement(activeId));
      expect(announcements.last, workspaceTabDragCancelAnnouncement(activeId));
      expect(
        announcements,
        isNot(contains(workspaceTabDragEndAnnouncement(activeId, null))),
      );

      await gesture.up();
    },
  );

  testWidgets(
    'keyboard drag exposes the frozen instructions and announces each '
    'dnd-kit state transition',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final announcements = <String>[];
      final container = await pumpPane(
        tester,
        agents: [_idleAgent, _runningAgent],
        dragAnnouncer: (_, message) => announcements.add(message),
      );
      final state = container.read(worktreeTabsProvider(_worktreePath));
      final first = state.layout.tabs.first;
      final second = state.layout.tabs.last;
      final keyboard = find.byKey(
        ValueKey('workspace-tab-keyboard-${first.tabId}'),
      );
      expect(
        tester.getSemantics(keyboard).getSemanticsData().hint,
        workspaceTabDragScreenReaderInstructions,
      );

      tester.widget<Focus>(keyboard).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      final activeId = '${first.tabId}:agent';
      final overId = '${second.tabId}:agent';
      expect(announcements, [
        workspaceTabDragStartAnnouncement(activeId),
        workspaceTabDragOverAnnouncement(activeId, activeId),
        workspaceTabDragOverAnnouncement(activeId, overId),
        workspaceTabDragEndAnnouncement(activeId, overId),
      ]);

      announcements.clear();
      tester.widget<Focus>(keyboard).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(announcements, [
        workspaceTabDragStartAnnouncement(activeId),
        workspaceTabDragOverAnnouncement(activeId, activeId),
        workspaceTabDragCancelAnnouncement(activeId),
      ]);
    },
  );

  testWidgets('keyboard tab drag reorders and moves tabs across panes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
    );
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    var state = container.read(worktreeTabsProvider(_worktreePath));
    final first = state.layout.tabs.first;
    final second = state.layout.tabs.last;

    tester
        .widget<Focus>(
          find.byKey(ValueKey('workspace-tab-keyboard-${first.tabId}')),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(
      container
          .read(workspaceTabKeyboardDragProvider(_worktreePath))
          ?.activeTabId,
      first.tabId,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(
      container
          .read(workspaceTabKeyboardDragProvider(_worktreePath))
          ?.overTabId,
      second.tabId,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    state = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      findWorkspacePane(state.layout.paneLayout!.root, 'pane_root')!.tabIds,
      [second.tabId, first.tabId],
    );

    final rightPaneId = notifier.splitFocusedPane(
      WorkspaceSplitDirection.horizontal,
    )!;
    await tester.pump();
    tester
        .widget<Focus>(
          find.byKey(ValueKey('workspace-tab-keyboard-${first.tabId}')),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    state = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      findWorkspacePaneContainingTab(
        state.layout.paneLayout!.root,
        first.tabId,
      )!.id,
      rightPaneId,
    );
  });

  testWidgets('tab drag to another pane center moves it across panes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final announcements = <String>[];
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
      dragAnnouncer: (_, message) => announcements.add(message),
    );
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    final sourceTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .first
        .tabId;
    final targetPaneId = notifier.splitFocusedPane(
      WorkspaceSplitDirection.horizontal,
    )!;
    await tester.pump();

    final source = find.byKey(ValueKey('workspace-tab-drag-$sourceTabId'));
    final target = find.byKey(ValueKey('workspace-pane-drop-$targetPaneId'));
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('workspace-split-drop-preview')),
      findsOneWidget,
    );
    final targetRect = tester.getRect(target);
    final previewRect = tester.getRect(
      find.byKey(const ValueKey('workspace-split-drop-preview')),
    );
    final preview = tester.widget<Container>(
      find.byKey(const ValueKey('workspace-split-drop-preview')),
    );
    final previewDecoration = preview.decoration! as BoxDecoration;
    final palette = paseoPaletteFor(AppThemeName.dark);
    expect(previewDecoration.color, palette.accent.withValues(alpha: .6));
    expect(previewDecoration.borderRadius, BorderRadius.circular(6));
    expect(previewDecoration.border!.top.color, palette.accent);
    expect(previewDecoration.border!.top.width, 2);
    expect(previewRect.left, closeTo(targetRect.left + 8, .01));
    expect(previewRect.top, closeTo(targetRect.top + 8, .01));
    expect(previewRect.right, closeTo(targetRect.right - 8, .01));
    expect(previewRect.bottom, closeTo(targetRect.bottom - 8, .01));
    await gesture.up();
    await tester.pump();

    final layout = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .paneLayout!;
    expect(
      findWorkspacePaneContainingTab(layout.root, sourceTabId)!.id,
      targetPaneId,
    );
    final activeId = '$sourceTabId:agent';
    expect(announcements.first, workspaceTabDragStartAnnouncement(activeId));
    expect(
      announcements.last,
      workspaceTabDragEndAnnouncement(
        activeId,
        'split-pane-drop:$targetPaneId',
      ),
    );
  });

  testWidgets('tab drag to a pane edge creates a positioned split', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent],
    );
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    final sourceTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .first
        .tabId;
    final targetPaneId = notifier.splitFocusedPane(
      WorkspaceSplitDirection.horizontal,
    )!;
    await tester.pump();

    final source = find.byKey(ValueKey('workspace-tab-drag-$sourceTabId'));
    final target = find.byKey(ValueKey('workspace-pane-drop-$targetPaneId'));
    final targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveTo(
      Offset(targetRect.left + targetRect.width * .05, targetRect.center.dy),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('workspace-split-drop-preview')),
      findsOneWidget,
    );
    final previewRect = tester.getRect(
      find.byKey(const ValueKey('workspace-split-drop-preview')),
    );
    expect(previewRect.left, closeTo(targetRect.left, 2.01));
    expect(previewRect.width, closeTo(targetRect.width / 2, 2.01));
    expect(previewRect.height, closeTo(targetRect.height, 2.01));
    await gesture.up();
    await tester.pump();

    final layout = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .paneLayout!;
    final sourcePane = findWorkspacePaneContainingTab(
      layout.root,
      sourceTabId,
    )!;
    expect(sourcePane.id, isNot(targetPaneId));
    expect(sourcePane.id, layout.focusedPaneId);
    final group = layout.root as WorkspacePaneGroup;
    expect(group.children.map((node) => (node as WorkspacePane).id), [
      'pane_root',
      sourcePane.id,
      targetPaneId,
    ]);
  });

  testWidgets('splitting the only tab preserves a usable empty target pane', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(tester, agents: [_idleAgent]);
    final tabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .single
        .tabId;
    final source = find.byKey(ValueKey('workspace-tab-drag-$tabId'));
    final target = find.byKey(const ValueKey('workspace-pane-drop-pane_root'));
    final targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveTo(Offset(targetRect.right - 4, targetRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final layout = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .paneLayout!;
    expect(collectWorkspacePanes(layout.root), hasLength(2));
    expect(findWorkspacePane(layout.root, 'pane_root')!.tabIds, isEmpty);
    expect(find.text('No tabs in this pane.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-pane-drop-pane_root')),
      findsOneWidget,
    );
    final emptyPane = find.byKey(const ValueKey('workspace-pane-pane_root'));
    await tester.tap(
      find.descendant(of: emptyPane, matching: find.byIcon(FluentIcons.add)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('No tabs in this pane.'), findsNothing);
    expect(
      findWorkspacePane(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .root,
        'pane_root',
      )!.tabIds,
      isNotEmpty,
    );
  });

  testWidgets('reconciles a tab for each live agent sharing the worktree, '
      'no draft tab alongside them', (tester) async {
    await pumpPane(tester, agents: [_idleAgent, _runningAgent]);

    // The active tab's body (AgentChatScreen) also shows the agent's title
    // in its own header, so its label can legitimately match twice.
    expect(find.text('Idle agent'), findsWidgets);
    expect(find.text('Running agent'), findsOneWidget);
    expect(find.text('New agent'), findsNothing);
  });

  testWidgets(
    'workspace tab row uses the frozen 36px row and responsive equal widths',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(520, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await pumpPane(
        tester,
        agents: [_idleAgent, _runningAgent, _thirdAgent],
      );
      container
          .read(workspaceExplorerVisibilityProvider(_worktreePath).notifier)
          .hide();
      await tester.pump();

      const paneId = 'pane_root';
      final row = find.byKey(const ValueKey('workspace-tabs-row-$paneId'));
      expect(tester.getSize(row).height, 36);
      final rowWidth = tester.getSize(row).width;
      final expected = computeWorkspaceTabLayout(
        viewportWidth: rowWidth,
        tabLabelLengths: const [10, 13, 11],
        metrics: const WorkspaceTabLayoutMetrics(
          rowHorizontalInset: 0,
          actionsReservedWidth: 140,
          rowPaddingHorizontal: 0,
          tabGap: 0,
          maxTabWidth: 200,
          tabIconWidth: 14,
          tabHorizontalPadding: 12,
          estimatedCharWidth: 7,
          closeButtonWidth: 22,
        ),
      );
      final tabs = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs;
      for (var index = 0; index < tabs.length; index++) {
        expect(
          tester.getSize(
            find.byKey(ValueKey('workspace-tab-drag-${tabs[index].tabId}')),
          ),
          Size(expected.items[index].width, 35),
        );
      }
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('workspace-inline-add-slot-$paneId')),
            )
            .width,
        36,
      );
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey('workspace-tab-trailing-actions-$paneId'),
              ),
            )
            .width,
        104,
      );
      expect(
        find.byKey(ValueKey('workspace-tab-body-${tabs.first.tabId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey('workspace-tab-body-${tabs.last.tabId}'),
          skipOffstage: false,
        ),
        findsNothing,
      );
    },
  );

  testWidgets('pane retains the three most recently active tab bodies', (
    tester,
  ) async {
    final container = await pumpPane(
      tester,
      agents: [_idleAgent, _runningAgent, _thirdAgent, _fourthAgent],
    );
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    String tabIdFor(String agentId) =>
        tabs.singleWhere((tab) => tab.agentId == agentId).tabId;

    for (final agentId in const ['a2', 'a3', 'a4']) {
      notifier.setActiveTab(tabIdFor(agentId));
      await tester.pump();
    }

    expect(
      find.byKey(
        ValueKey('workspace-tab-body-${tabIdFor('a1')}'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    for (final agentId in const ['a2', 'a3', 'a4']) {
      expect(
        find.byKey(
          ValueKey('workspace-tab-body-${tabIdFor(agentId)}'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('workspace tab row matches the frozen Windows geometry golden', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(880, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await pumpPane(tester);
    container
        .read(workspaceExplorerVisibilityProvider(_worktreePath).notifier)
        .hide();
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .addTab(WorktreeTabKind.draft);
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('workspace-tabs-row-pane_root')),
      matchesGoldenFile('goldens/workspace_tab_row_880x36.png'),
    );
  });

  testWidgets('the dropdown\'s "New terminal" adds a top-level terminal tab', (
    tester,
  ) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('New terminal'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.terminal), hasLength(1));
    expect(find.text('Terminal 1'), findsOneWidget);
  });

  testWidgets('the workspace dropdown opens the import-session sheet', (
    tester,
  ) async {
    await pumpPane(tester, agents: [_idleAgent]);

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Import session'), findsOneWidget);
    await tester.tap(find.text('Import session'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('import-session-sheet')), findsOneWidget);
    expect(find.text('Update the host to import sessions.'), findsOneWidget);
  });

  testWidgets('provider subagent opens as an independent workspace tab', (
    tester,
  ) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusProviderSubagent('a1', 'child');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Research'), findsWidgets);
    expect(find.text('child result'), findsOneWidget);
    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    expect(
      tabs.where((tab) => tab.kind == WorktreeTabKind.providerSubagent),
      hasLength(1),
    );
  });

  testWidgets('workspace files open in reusable main and split-pane tabs', (
    tester,
  ) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .openFile(
          const WorkspaceFileLocation(path: 'lib/main.dart', lineStart: 2),
        );
    await tester.pump();
    await tester.pump();

    expect(find.text('main.dart'), findsWidgets);
    expect(
      tester
          .widget<TextBox>(
            find.byKey(const ValueKey('workspace-file-editor')).first,
          )
          .controller
          ?.text,
      contains('selected line'),
    );
    expect(find.byKey(const ValueKey('workspace-file-pane')), findsOneWidget);

    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .openFileInSidePane(
          const WorkspaceFileLocation(path: 'test/app_test.dart'),
        );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('workspace-file-pane')), findsNWidgets(2));
    final sideFileTab = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .singleWhere((tab) => tab.filePath == 'test/app_test.dart');
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .closeTab(sideFileTab.tabId);
    await tester.pump();
    expect(find.byKey(const ValueKey('workspace-file-pane')), findsOneWidget);
  });

  testWidgets('workspace explorer file press opens a main file tab', (
    tester,
  ) async {
    final container = await pumpPane(tester, agents: [_idleAgent]);
    await tester.tap(find.text('Files'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('README.md'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final fileTabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .where((tab) => tab.kind == WorktreeTabKind.file)
        .toList();
    expect(fileTabs, hasLength(1));
    expect(fileTabs.single.filePath, 'README.md');
  });

  testWidgets('changes and files live in the workspace explorer instead of '
      'top-level tabs', (tester) async {
    final container = await pumpPane(
      tester,
      agents: [_idleAgent],
      projectPath: '/repo',
    );

    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    expect(tabs.where((t) => t.kind == WorktreeTabKind.diff), isEmpty);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('View diff'), findsNothing);
  });

  testWidgets('non-git workspace explorer exposes only Files', (tester) async {
    await pumpPane(tester, agents: [_idleAgent], projectPath: null);

    expect(find.text('Changes'), findsNothing);
    expect(find.text('Files'), findsOneWidget);
    expect(find.byKey(const ValueKey('explorer-tab-pr')), findsNothing);
  });

  testWidgets('the workspace explorer closes and reopens from tab actions', (
    tester,
  ) async {
    await pumpPane(tester, agents: [_idleAgent], projectPath: '/repo');

    await tester.tap(
      find.descendant(
        of: find.byType(WorkspaceExplorer),
        matching: find.byIcon(FluentIcons.chrome_close),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Changes'), findsNothing);

    await tester.tap(find.byIcon(FluentIcons.chevron_down));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Show explorer'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
  });

  testWidgets('closing an idle agent tab archives it with no confirmation '
      'dialog', (tester) async {
    final client = FakeDaemonClient();
    final container = await pumpPane(
      tester,
      client: client,
      agents: [_idleAgent],
    );

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

  testWidgets('closing a managed child tab only changes layout', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpPane(
      tester,
      client: client,
      agents: [_managedChild],
    );
    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusAgent('child');
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(_closeButtonFor('Managed child'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Archive running agent?'), findsNothing);
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isFalse,
    );
    expect(container.read(agentsProvider).containsKey('child'), isTrue);
    expect(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((tab) => tab.agentId == 'child'),
      isEmpty,
    );
  });

  testWidgets('closing a running agent tab confirms first; cancelling leaves '
      'it running and open', (tester) async {
    final client = FakeDaemonClient();
    final container = await pumpPane(
      tester,
      client: client,
      agents: [_runningAgent],
    );

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
    final container = await pumpPane(
      tester,
      client: client,
      agents: [_runningAgent],
    );

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
    final container = await pumpPane(
      tester,
      client: client,
      agents: [_idleAgent],
    );
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
      client.requests.any((r) => r.$1 == 'unsubscribe_terminal_request'),
      isTrue,
    );
    expect(
      client.requests.any((r) => r.$1 == KillTerminalRequest.type),
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
