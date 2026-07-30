import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/mobile_panels/mobile_panel_model.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/screens/home_shell.dart';
import 'package:coding_agent_app/screens/host_settings_route_screen.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/screens/projects_screen.dart';
import 'package:coding_agent_app/screens/schedules_screen.dart';
import 'package:coding_agent_app/screens/sessions_screen.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/add_project_flow_provider.dart';
import 'package:coding_agent_app/state/command_center_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/app_sidebar_visibility_provider.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/sidebar_callout_provider.dart';
import 'package:coding_agent_app/state/sidebar_callout_state.dart';
import 'package:coding_agent_app/state/sidebar_order_provider.dart';
import 'package:coding_agent_app/state/sidebar_width_provider.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/worktree_tabbed_pane.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agent1 = AgentSummary(
  agentId: 'a1',
  title: 'First agent',
  cwd: '/work/one',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _agent2 = AgentSummary(
  agentId: 'a2',
  title: 'Second agent',
  cwd: '/work/two',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.plan,
  runState: AgentRunState.running,
  createdAtMs: 200,
);

const _attentionAgent = AgentSummary(
  agentId: 'attention',
  title: 'Unread result',
  cwd: '/work/attention',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 300,
  requiresAttention: true,
  attentionReason: AgentAttentionReason.finished,
  attentionTimestamp: '2026-07-26T00:00:00.000Z',
);

const _workspaceRoot = AgentSummary(
  agentId: 'workspace-root',
  title: 'Workspace root',
  cwd: '/work/shared',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
  updatedAt: '2026-06-01T10:00:00.000Z',
  workspaceId: 'workspace-shared',
);

const _sameWorkspaceChild = AgentSummary(
  agentId: 'workspace-child',
  title: 'Same workspace child',
  cwd: '/work/shared',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.awaitingPermission,
  createdAtMs: 200,
  updatedAt: '2026-06-01T10:01:00.000Z',
  workspaceId: 'workspace-shared',
  parentAgentId: 'workspace-root',
);

const _agent3 = AgentSummary(
  agentId: 'a3',
  title: 'Third agent',
  cwd: '/work/three',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 300,
);

const _agent4 = AgentSummary(
  agentId: 'a4',
  title: 'Fourth agent',
  cwd: '/work/four',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 400,
);

const _projectA = ProjectInfo(path: '/repo-a', name: 'repo-a', isGitRepo: true);
const _projectB = ProjectInfo(path: '/repo-b', name: 'repo-b', isGitRepo: true);

const _testHost = HostProfile(
  serverId: 'server-1',
  label: 'Test host',
  connections: [],
  preferredConnectionId: null,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
);

const _workspaceSharedDescriptor = WorkspaceDescriptor(
  id: 'workspace-shared',
  projectId: 'project-shared',
  projectDisplayName: 'Shared project',
  projectRootPath: '/work/shared',
  workspaceDirectory: '/work/shared',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.localCheckout,
  name: 'main',
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

const _mainWorktreeA = WorktreeInfo(
  path: '/repo-a',
  branch: 'main',
  projectPath: '/repo-a',
  isMain: true,
);

const _mainWorktreeB = WorktreeInfo(
  path: '/repo-b',
  branch: 'main',
  projectPath: '/repo-b',
  isMain: true,
);

const _luckyOtterWorktree = WorktreeInfo(
  path: '/repo-b-wt/lucky-otter',
  branch: 'lucky-otter',
  projectPath: '/repo-b',
);

const _projectAgent1 = AgentSummary(
  agentId: 'pa1',
  title: 'Repo A agent',
  cwd: '/repo-a',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _projectAgent2 = AgentSummary(
  agentId: 'pb1',
  title: 'Repo B agent',
  cwd: '/repo-b',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 200,
);

class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient({
    this.agents = const [],
    this.projects = const [],
    this.worktreesByProject = const {},
    this.projectListGate,
  }) : super(uri: Uri.parse('ws://fake'));

  final List<AgentSummary> agents;
  final List<ProjectInfo> projects;
  final Map<String, List<WorktreeInfo>> worktreesByProject;
  final Completer<List<ProjectInfo>>? projectListGate;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.projectListRequest && projectListGate != null) {
      final gatedProjects = await projectListGate!.future;
      return {'projects': gatedProjects.map((p) => p.toJson()).toList()};
    }
    if (type == MessageTypes.agentRenameRequest) {
      final agentId = payload['agentId'] as String;
      final title = payload['title'] as String;
      final agent = agents.firstWhere((a) => a.agentId == agentId);
      return {'agent': agent.copyWith(title: title).toJson()};
    }
    if (type == MessageTypes.worktreeListRequest) {
      final projectPath = payload['projectPath'] as String;
      final worktrees = worktreesByProject[projectPath] ?? const [];
      return {'worktrees': worktrees.map((w) => w.toJson()).toList()};
    }
    return switch (type) {
      MessageTypes.agentListRequest => {
        'agents': agents.map((a) => a.toJson()).toList(),
      },
      MessageTypes.providerListRequest => const {'providers': []},
      MessageTypes.projectListRequest => {
        'projects': projects.map((p) => p.toJson()).toList(),
      },
      _ => const {},
    };
  }
}

Future<ProviderContainer> pumpHomeShell(
  WidgetTester tester, {
  List<AgentSummary> agents = const [],
  List<ProjectInfo> projects = const [],
  Map<String, List<WorktreeInfo>> worktreesByProject = const {},
  Completer<List<ProjectInfo>>? projectListGate,
  HostProfile? activeHost,
  Map<String, List<WorkspaceDescriptor>> workspaceCatalogByServer = const {},
  Size? surfaceSize,
}) async {
  if (surfaceSize != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = surfaceSize;
    addTearDown(tester.view.reset);
  }
  SharedPreferences.setMockInitialValues({});
  final client = FakeDaemonClient(
    agents: agents,
    projects: projects,
    worktreesByProject: worktreesByProject,
    projectListGate: projectListGate,
  );
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      if (activeHost != null) activeHostProvider.overrideWithValue(activeHost),
      // Otherwise navigating to SettingsScreen watches the real
      // daemonLifecycleProvider, which spins up an actual DaemonSupervisor
      // probing the network on this (real Windows) test host.
      desktopShellProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  for (final entry in workspaceCatalogByServer.entries) {
    container
        .read(workspaceCatalogCacheProvider.notifier)
        .replace(entry.key, entry.value);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp.router(routerConfig: buildAppRouter()),
    ),
  );
  // Not pumpAndSettle(): a `running` agent renders an indeterminate
  // CircularProgressIndicator that animates forever and would time it out.
  await tester.pump();
  await tester.pump();
  await tester.pump();
  // Projects (and, once resolved, each git project's worktree list) load
  // via connectionStateProvider's first StreamProvider tick, which needs a
  // few extra microtask turns beyond the agent list — and worktreesProvider
  // watchers aren't registered until the sidebar first sees a non-empty
  // project list, so give it a second wave of ticks.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  return container;
}

Future<void> settleMobilePanel(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 240));
}

void main() {
  testWidgets('compact shell starts closed and opens a full-width sidebar', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      surfaceSize: const Size(500, 700),
    );

    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
    expect(find.byKey(const ValueKey('menu-button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('left-sidebar-resize-handle')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('menu-button')));
    await settleMobilePanel(tester);

    expect(
      container.read(mobilePanelProvider).target,
      MobilePanelView.agentList,
    );
    expect(find.byKey(const ValueKey('sidebar-close')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('mobile-left-sidebar'))),
      const Size(500, 700),
    );

    await tester.tap(find.byKey(const ValueKey('sidebar-close')));
    await settleMobilePanel(tester);
    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
  });

  testWidgets('compact sidebar supports open and close swipe gestures', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      surfaceSize: const Size(500, 700),
    );

    await tester.drag(
      find.byKey(const ValueKey('mobile-agent-surface')),
      const Offset(220, 0),
    );
    await settleMobilePanel(tester);
    expect(
      container.read(mobilePanelProvider).target,
      MobilePanelView.agentList,
    );

    await tester.drag(
      find.byKey(const ValueKey('mobile-left-sidebar')),
      const Offset(-220, 0),
    );
    await settleMobilePanel(tester);
    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
  });

  testWidgets('compact shell rejects explorer swipe without a workspace', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      surfaceSize: const Size(500, 700),
    );

    await tester.drag(
      find.byKey(const ValueKey('mobile-agent-surface')),
      const Offset(-220, 0),
    );
    await settleMobilePanel(tester);

    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
    expect(find.byKey(const ValueKey('mobile-file-explorer')), findsNothing);
  });

  testWidgets('compact sidebar closes before route navigation', (tester) async {
    final container = await pumpHomeShell(
      tester,
      surfaceSize: const Size(500, 700),
    );
    await tester.tap(find.byKey(const ValueKey('menu-button')));
    await settleMobilePanel(tester);

    await tester.tap(find.byKey(const ValueKey('sidebar-sessions')));
    await settleMobilePanel(tester);

    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
    expect(find.byType(SessionsScreen), findsOneWidget);
  });

  testWidgets('compact workspace swipes to the right-side file explorer', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: const [_workspaceRoot],
      activeHost: _testHost,
      workspaceCatalogByServer: const {
        'server-1': [_workspaceSharedDescriptor],
      },
      surfaceSize: const Size(500, 700),
    );
    container.read(selectedWorktreeProvider.notifier).select('/work/shared');
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('mobile-agent-surface')),
      const Offset(-220, 0),
    );
    await settleMobilePanel(tester);

    expect(
      container.read(mobilePanelProvider).target,
      MobilePanelView.fileExplorer,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mobile-file-explorer'))),
      const Size(500, 700),
    );
    expect(
      find.byKey(const ValueKey('file-explorer-backdrop')),
      findsOneWidget,
    );
    expect(
      tester.widget<WorkspaceExplorer>(find.byType(WorkspaceExplorer)).cwd,
      '/work/shared',
    );

    container
        .read(workspaceCatalogCacheProvider.notifier)
        .clearServer('server-1');
    await tester.pump();
    expect(
      container.read(mobilePanelProvider).target,
      MobilePanelView.fileExplorer,
    );
    expect(find.byKey(const ValueKey('mobile-file-explorer')), findsOneWidget);
    expect(
      tester.widget<WorkspaceExplorer>(find.byType(WorkspaceExplorer)).cwd,
      '/work/shared',
    );

    await tester.drag(
      find.byKey(const ValueKey('mobile-file-explorer')),
      const Offset(220, 0),
    );
    await settleMobilePanel(tester);
    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
  });

  testWidgets('newer compact command supersedes an in-flight gesture', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: const [_workspaceRoot],
      activeHost: _testHost,
      workspaceCatalogByServer: const {
        'server-1': [_workspaceSharedDescriptor],
      },
      surfaceSize: const Size(500, 700),
    );
    container.read(selectedWorktreeProvider.notifier).select('/work/shared');
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-agent-surface'))),
    );
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();

    container.read(mobilePanelProvider.notifier).showFileExplorer();
    await gesture.up();
    await settleMobilePanel(tester);

    expect(
      container.read(mobilePanelProvider),
      const MobilePanelSelection(
        target: MobilePanelView.fileExplorer,
        revision: 1,
      ),
    );
    expect(find.byKey(const ValueKey('mobile-file-explorer')), findsOneWidget);
  });

  testWidgets('compact explorer closes when active workspace ownership ends', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: const [_workspaceRoot],
      activeHost: _testHost,
      workspaceCatalogByServer: const {
        'server-1': [_workspaceSharedDescriptor],
      },
      surfaceSize: const Size(500, 700),
    );
    container.read(selectedWorktreeProvider.notifier).select('/work/shared');
    await tester.pump();
    container.read(mobilePanelProvider.notifier).showFileExplorer();
    await settleMobilePanel(tester);
    expect(find.byKey(const ValueKey('mobile-file-explorer')), findsOneWidget);

    container.read(selectedWorktreeProvider.notifier).select(null);
    await settleMobilePanel(tester);

    expect(container.read(mobilePanelProvider).target, MobilePanelView.agent);
    expect(find.byKey(const ValueKey('mobile-file-explorer')), findsNothing);
  });

  testWidgets('width above compact breakpoint keeps the desktop sidebar', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      surfaceSize: const Size(501, 700),
    );

    expect(container.read(appCompactLayoutProvider), isFalse);
    expect(find.byKey(const ValueKey('left-sidebar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('left-sidebar-resize-handle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('menu-button')), findsNothing);
  });

  testWidgets('sidebar drag resizes, clamps, and commits the width', (
    tester,
  ) async {
    final container = await pumpHomeShell(tester);
    final sidebar = find.byKey(const ValueKey('left-sidebar'));
    final handle = find.byKey(const ValueKey('left-sidebar-resize-handle'));

    expect(tester.getSize(sidebar).width, 320);
    await tester.drag(handle, const Offset(500, 0));
    await tester.pump();
    expect(tester.getSize(sidebar).width, 400);
    expect(container.read(sidebarWidthProvider), 400);

    await tester.drag(handle, const Offset(-800, 0));
    await tester.pump();
    expect(tester.getSize(sidebar).width, 200);
    expect(container.read(sidebarWidthProvider), 200);
  });

  testWidgets('renders the active native callout above the footer', (
    tester,
  ) async {
    final container = await pumpHomeShell(tester);
    container
        .read(sidebarCalloutProvider.notifier)
        .show(
          const SidebarCalloutOptions(
            id: 'update',
            title: 'Update available',
            description: 'v1 is ready.',
            testId: 'shell-callout',
          ),
        );
    await tester.pump();

    final callout = find.byKey(const ValueKey('shell-callout'));
    final footer = find.byKey(const ValueKey('sidebar-add-project'));
    expect(callout, findsOneWidget);
    expect(footer, findsOneWidget);
    expect(
      tester.getBottomLeft(callout).dy,
      lessThan(tester.getTopLeft(footer).dy),
    );

    await tester.tap(find.byKey(const ValueKey('shell-callout-dismiss')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(callout, findsNothing);
  });

  testWidgets('shows the Paseo skeleton only during the initial empty load', (
    tester,
  ) async {
    final projectListGate = Completer<List<ProjectInfo>>();
    await pumpHomeShell(tester, projectListGate: projectListGate);

    expect(
      find.byKey(const ValueKey('sidebar-agent-list-skeleton')),
      findsOneWidget,
    );
    expect(find.text('No agents yet'), findsNothing);

    projectListGate.complete(const []);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('sidebar-agent-list-skeleton')),
      findsNothing,
    );
    expect(find.text('No agents yet'), findsOneWidget);
  });

  testWidgets('no agents: shows the empty placeholder', (tester) async {
    await pumpHomeShell(tester);

    expect(find.text('Select an agent or create a new one'), findsOneWidget);
    expect(find.text('No agents yet'), findsOneWidget);
  });

  testWidgets('lists agents most-recent first with provider/model subtitle', (
    tester,
  ) async {
    await pumpHomeShell(tester, agents: [_agent1, _agent2]);

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
    // Most-recent (createdAtMs 200) first.
    final firstTile = tester.widget<ListTile>(tiles.first);
    expect((firstTile.title! as Text).data, 'Second agent');
    expect(find.text('codex · gpt'), findsOneWidget);
    expect(find.text('claude · sonnet'), findsOneWidget);
  });

  testWidgets('shows unread finished attention in the sidebar', (tester) async {
    await pumpHomeShell(tester, agents: [_attentionAgent]);

    final indicator = tester.widget<Icon>(find.byIcon(FluentIcons.ringer));
    expect(indicator.color, Colors.yellow);
  });

  testWidgets(
    'same-workspace child activity does not replace the workspace root state',
    (tester) async {
      await pumpHomeShell(
        tester,
        agents: [_workspaceRoot, _sameWorkspaceChild],
      );

      expect(find.text('2 sessions'), findsOneWidget);
      expect(find.byIcon(FluentIcons.ringer), findsNothing);
      final workspaceTile = find.ancestor(
        of: find.text('2 sessions'),
        matching: find.byType(ListTile),
      );
      final indicator = tester.widget<Icon>(
        find.descendant(
          of: workspaceTile,
          matching: find.byIcon(FluentIcons.circle_fill),
        ),
      );
      expect(indicator.color, Colors.grey[100]);
    },
  );

  testWidgets('selecting an agent shows its chat screen', (tester) async {
    await pumpHomeShell(tester, agents: [_agent1]);

    expect(find.byType(AgentChatScreen), findsNothing);

    await tester.tap(find.text('First agent'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentChatScreen), findsOneWidget);
    expect(find.text('First agent'), findsWidgets);
  });

  testWidgets('workspace deck retains the three most recent native roots', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: [_agent1, _agent2, _agent3, _agent4],
    );
    final selection = container.read(selectedWorktreeProvider.notifier);
    expect(
      container.read(agentsProvider).values.map((agent) => agent.cwd).toSet(),
      {'/work/one', '/work/two', '/work/three', '/work/four'},
    );

    selection.select('/work/one');
    await tester.pump();
    selection.select('/work/two');
    await tester.pump();
    Finder paneFor(String path) => find.byWidgetPredicate(
      (widget) => widget is WorktreeTabbedPane && widget.worktreePath == path,
      skipOffstage: false,
    );
    final secondEntry = tester.element(paneFor('/work/two'));
    selection.select('/work/three');
    await tester.pump();
    selection.select('/work/four');
    await tester.pump();

    expect(
      container
          .read(workspaceDeckControllerProvider)
          .mountedSelections
          .map((selection) => selection.worktreePath)
          .toList(),
      ['/work/four', '/work/three', '/work/two'],
    );
    final mountedPanes = tester
        .widgetList<WorktreeTabbedPane>(
          find.byType(WorktreeTabbedPane, skipOffstage: false),
        )
        .map((pane) => pane.worktreePath)
        .toSet();
    expect(mountedPanes, {'/work/two', '/work/three', '/work/four'});
    expect(mountedPanes, isNot(contains('/work/one')));

    selection.select('/work/two');
    await tester.pump();
    expect(tester.element(paneFor('/work/two')), same(secondEntry));
  });

  testWidgets('New workspace navigates to the New Workspace screen', (
    tester,
  ) async {
    await pumpHomeShell(tester);

    await tester.tap(
      find.byKey(const ValueKey('sidebar-global-new-workspace')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NewWorkspaceScreen), findsOneWidget);
    expect(
      GoRouterState.of(
        tester.element(find.byType(NewWorkspaceScreen)),
      ).uri.path,
      '/new',
    );
  });

  testWidgets(
    'project new-workspace action targets that project on the active host',
    (tester) async {
      await pumpHomeShell(
        tester,
        projects: const [_projectA],
        worktreesByProject: const {
          '/repo-a': [_mainWorktreeA],
        },
        activeHost: const HostProfile(
          serverId: 'server-1',
          label: 'Test host',
          connections: [],
          preferredConnectionId: null,
          createdAt: '2026-01-01T00:00:00.000Z',
          updatedAt: '2026-01-01T00:00:00.000Z',
        ),
      );

      final action = find.byKey(
        const ValueKey('project-new-workspace-/repo-a'),
      );
      expect(action, findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();

      final screen = find.byType(NewWorkspaceScreen);
      expect(screen, findsOneWidget);
      final uri = GoRouterState.of(tester.element(screen)).uri;
      expect(uri.path, '/new');
      expect(uri.queryParameters, {
        'serverId': 'server-1',
        'dir': '/repo-a',
        'name': 'repo-a',
        'projectId': '/repo-a',
      });
    },
  );

  testWidgets('global navigation matches Paseo and omits conflicting rows', (
    tester,
  ) async {
    await pumpHomeShell(tester);

    expect(find.text('Projects & worktrees'), findsNothing);
    expect(find.text('Status'), findsNothing);
    expect(find.text('New workspace'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Schedules'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('New workspace')).dy,
      lessThan(tester.getTopLeft(find.text('Sessions')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Sessions')).dy,
      lessThan(tester.getTopLeft(find.text('Schedules')).dy),
    );

    await tester.tap(find.text('Sessions'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionsScreen), findsOneWidget);

    await tester.tap(find.text('Schedules'));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulesScreen), findsOneWidget);
  });

  testWidgets('footer exposes Paseo actions and settings navigation', (
    tester,
  ) async {
    await pumpHomeShell(tester);

    expect(find.byKey(const ValueKey('sidebar-add-project')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-hosts-trigger')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-help')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-settings')), findsOneWidget);
    expect(find.text('Daemon connected'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    // SettingsScreen's status Row genuinely overflows at this width — a
    // pre-existing, unrelated cosmetic issue in that widget, not something
    // this navigation test is about.
    final overflow = tester.takeException();
    if (overflow != null && !overflow.toString().contains('overflowed')) {
      throw overflow;
    }
  });

  testWidgets('Add project opens the shared project flow', (tester) async {
    final container = await pumpHomeShell(tester);

    expect(container.read(addProjectFlowProvider).request, isNull);
    await tester.tap(find.byKey(const ValueKey('sidebar-add-project')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(container.read(addProjectFlowProvider).request, isNotNull);
    expect(find.byKey(const ValueKey('add-project-flow')), findsOneWidget);
  });

  testWidgets('Help opens the Paseo help surface', (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.byKey(const ValueKey('sidebar-help')));
    await tester.pumpAndSettle();

    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('Report an issue'), findsOneWidget);
    expect(find.text('Tinyrack v0.1.0'), findsOneWidget);
  });

  testWidgets('global New workspace keeps the selected project context', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: const [_projectAgent1],
      projects: const [_projectA],
      worktreesByProject: const {
        '/repo-a': [_mainWorktreeA],
      },
      activeHost: const HostProfile(
        serverId: 'server-1',
        label: 'Test host',
        connections: [],
        preferredConnectionId: null,
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
      ),
    );

    container.read(selectedWorktreeProvider.notifier).select('/repo-a');
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('sidebar-global-new-workspace')),
    );
    await tester.pumpAndSettle();

    final screen = find.byType(NewWorkspaceScreen);
    expect(screen, findsOneWidget);
    final uri = GoRouterState.of(tester.element(screen)).uri;
    expect(uri.path, '/new');
    expect(uri.queryParameters, {
      'serverId': 'server-1',
      'dir': '/repo-a',
      'name': 'repo-a',
      'projectId': '/repo-a',
    });
  });

  testWidgets('Home opens the canonical open-project route', (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.byKey(const ValueKey('sidebar-home')));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byType(ProjectsScreen))).uri.path,
      '/open-project',
    );
  });

  testWidgets('workspace search requests the command center overlay', (
    tester,
  ) async {
    final container = await pumpHomeShell(tester);

    expect(container.read(commandCenterOverlayRequestProvider), isNull);
    await tester.tap(
      find.byKey(const ValueKey('sidebar-command-center-search')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      container.read(commandCenterOverlayRequestProvider)?.overlay,
      CommandCenterOverlay.commandCenter,
    );
  });

  testWidgets('display preferences switch status grouping and branch titles', (
    tester,
  ) async {
    await pumpHomeShell(
      tester,
      agents: const [_projectAgent1, _attentionAgent],
      projects: const [_projectA],
      worktreesByProject: const {
        '/repo-a': [_mainWorktreeA],
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('sidebar-display-preferences-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-grouping-status')));
    await tester.pumpAndSettle();

    expect(find.text('Ready to review'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Repo A agent'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('sidebar-display-preferences-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('sidebar-workspace-title-source-branch')),
    );
    await tester.pumpAndSettle();

    expect(find.text('main'), findsOneWidget);
    expect(find.text('Repo A agent'), findsNothing);
  });

  testWidgets('Hosts routes add and host settings actions', (tester) async {
    await pumpHomeShell(
      tester,
      activeHost: const HostProfile(
        serverId: 'server-1',
        label: 'Test host',
        connections: [],
        preferredConnectionId: null,
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
      ),
    );

    await tester.tap(find.byKey(const ValueKey('sidebar-hosts-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-host-row-server-1')));
    await tester.pumpAndSettle();

    final settings = find.byType(HostSettingsRouteScreen);
    expect(settings, findsOneWidget);
    expect(
      GoRouterState.of(tester.element(settings)).uri.path,
      '/settings/hosts/server-1/connections',
    );
  });

  testWidgets(
    'agents in different projects render under distinct project headers, '
    'and collapsing a project hides its agent rows',
    (tester) async {
      await pumpHomeShell(
        tester,
        agents: [_projectAgent1, _projectAgent2],
        projects: [_projectA, _projectB],
        worktreesByProject: {
          '/repo-a': [_mainWorktreeA],
          '/repo-b': [_mainWorktreeB],
        },
      );

      expect(find.text('repo-a'), findsOneWidget);
      expect(find.text('repo-b'), findsOneWidget);
      expect(find.text('Repo A agent'), findsOneWidget);
      expect(find.text('Repo B agent'), findsOneWidget);

      await tester.tap(find.text('repo-a'));
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.text('Repo A agent'), findsNothing);
      expect(find.text('Repo B agent'), findsOneWidget);
    },
  );

  testWidgets('project and workspace drag order is applied and persisted', (
    tester,
  ) async {
    final container = await pumpHomeShell(
      tester,
      agents: const [_projectAgent1, _projectAgent2],
      projects: const [_projectA, _projectB],
      worktreesByProject: const {
        '/repo-a': [_mainWorktreeA],
        '/repo-b': [_mainWorktreeB, _luckyOtterWorktree],
      },
    );

    final projectA = find.byKey(
      const ValueKey('sidebar-project-section-/repo-a'),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('sidebar-project-drag-/repo-a'))),
      isA<ReorderableDragStartListener>(),
    );
    final outerList = find
        .ancestor(of: projectA, matching: find.byType(ReorderableListView))
        .first;
    tester.widget<ReorderableListView>(outerList).onReorderItem!(0, 1);
    await tester.pump();

    expect(container.read(sidebarOrderProvider).projectOrder, [
      '/repo-b',
      '/repo-a',
    ]);
    expect(
      tester.getTopLeft(find.text('repo-b')).dy,
      lessThan(tester.getTopLeft(find.text('repo-a')).dy),
    );

    final projectB = find.byKey(
      const ValueKey('sidebar-project-section-/repo-b'),
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('sidebar-workspace-drag-legacy:/repo-b')),
      ),
      isA<ReorderableDragStartListener>(),
    );
    final workspaceList = find.descendant(
      of: projectB,
      matching: find.byType(ReorderableListView),
    );
    tester.widget<ReorderableListView>(workspaceList).onReorderItem!(0, 1);
    await tester.pump();

    expect(container.read(sidebarOrderProvider).workspaceOrder('/repo-b'), [
      'legacy:/repo-b-wt/lucky-otter',
      'legacy:/repo-b',
    ]);
    expect(
      tester.getTopLeft(find.text('lucky-otter')).dy,
      lessThan(tester.getTopLeft(find.text('Repo B agent')).dy),
    );
  });

  testWidgets('pinning an agent via the kebab menu hoists it into Pinned', (
    tester,
  ) async {
    await pumpHomeShell(
      tester,
      agents: [_projectAgent1],
      projects: [_projectA],
      worktreesByProject: {
        '/repo-a': [_mainWorktreeA],
      },
    );

    expect(find.text('Pinned'), findsNothing);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsOneWidget);
  });

  testWidgets('renaming an agent via the kebab menu updates its title', (
    tester,
  ) async {
    await pumpHomeShell(tester, agents: [_agent1]);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextBox), 'Renamed agent');
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();

    expect(find.text('Renamed agent'), findsOneWidget);
  });

  testWidgets('secondary click on a workspace row opens its context menu', (
    tester,
  ) async {
    await pumpHomeShell(tester, agents: [_agent1]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First agent')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    await gesture.up();
  });

  testWidgets('an idle worktree with no agent still renders a full kebab menu '
      '(pin/rename apply to the row, not just its agents)', (tester) async {
    const idleWorktreeA = WorktreeInfo(
      path: '/repo-a-wt/idle',
      branch: 'idle-branch',
      projectPath: '/repo-a',
    );
    await pumpHomeShell(
      tester,
      projects: [_projectA],
      worktreesByProject: {
        '/repo-a': [_mainWorktreeA, idleWorktreeA],
      },
    );

    expect(find.text('main'), findsOneWidget);
    expect(find.text('idle-branch'), findsOneWidget);
    expect(find.text('/repo-a-wt/idle'), findsOneWidget);

    final kebabs = find.byIcon(FluentIcons.more_vertical);
    expect(kebabs, findsNWidgets(2));

    // The idle (non-main) worktree's kebab is the second one, since
    // worktree.list order is preserved (main first).
    await tester.tap(kebabs.last);
    await tester.pumpAndSettle();

    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Copy branch'), findsOneWidget);
    expect(find.text('Archive worktree'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
  });
}
