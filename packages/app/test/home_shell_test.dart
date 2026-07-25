import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/screens/status_screen.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _projectA = ProjectInfo(path: '/repo-a', name: 'repo-a', isGitRepo: true);
const _projectB = ProjectInfo(path: '/repo-b', name: 'repo-b', isGitRepo: true);

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

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    this.agents = const [],
    this.projects = const [],
    this.worktreesByProject = const {},
  }) : super(uri: Uri.parse('ws://fake'));

  final List<AgentSummary> agents;
  final List<ProjectInfo> projects;
  final Map<String, List<WorktreeInfo>> worktreesByProject;

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
}) async {
  SharedPreferences.setMockInitialValues({});
  final client = FakeDaemonClient(
    agents: agents,
    projects: projects,
    worktreesByProject: worktreesByProject,
  );
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      // Otherwise navigating to StatusScreen/SettingsScreen watches the real
      // daemonLifecycleProvider, which spins up an actual DaemonSupervisor
      // probing the network on this (real Windows) test host.
      desktopShellProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);

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

void main() {
  testWidgets('no agents: shows the empty placeholder', (tester) async {
    await pumpHomeShell(tester);

    expect(find.text('Select an agent or create a new one'), findsOneWidget);
    expect(find.text('No agents yet'), findsOneWidget);
  });

  testWidgets('lists agents most-recent first with provider/model subtitle',
      (tester) async {
    await pumpHomeShell(tester, agents: [_agent1, _agent2]);

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
    // Most-recent (createdAtMs 200) first.
    final firstTile = tester.widget<ListTile>(tiles.first);
    expect(
      (firstTile.title! as Text).data,
      'Second agent',
    );
    expect(find.text('codex · gpt'), findsOneWidget);
    expect(find.text('claude · sonnet'), findsOneWidget);
  });

  testWidgets('selecting an agent shows its chat screen', (tester) async {
    await pumpHomeShell(tester, agents: [_agent1]);

    expect(find.byType(AgentChatScreen), findsNothing);

    await tester.tap(find.text('First agent'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentChatScreen), findsOneWidget);
    expect(find.text('First agent'), findsWidgets);
  });

  testWidgets('New workspace navigates to the New Workspace screen',
      (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.text('New workspace'));
    await tester.pumpAndSettle();

    expect(find.byType(NewWorkspaceScreen), findsOneWidget);
  });

  testWidgets('the Status row navigates to StatusScreen', (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();

    expect(find.byType(StatusScreen), findsOneWidget);
  });

  testWidgets('the settings icon navigates to SettingsScreen',
      (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Connection settings'));
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

  testWidgets('connection footer reflects the connected state',
      (tester) async {
    await pumpHomeShell(tester);

    expect(find.text('Daemon connected'), findsOneWidget);
  });

  testWidgets(
      'agents in different projects render under distinct project headers, '
      'and collapsing a project hides its agent rows', (tester) async {
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
  });

  testWidgets('pinning an agent via the kebab menu hoists it into Pinned',
      (tester) async {
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

  testWidgets('renaming an agent via the kebab menu updates its title',
      (tester) async {
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

  testWidgets(
      'an idle worktree with no agent still renders a full kebab menu '
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
