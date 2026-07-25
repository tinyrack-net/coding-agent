import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/sidebar_grouping_provider.dart';
import 'package:coding_agent_app/state/sidebar_pins_provider.dart';
import 'package:coding_agent_app/state/workspace_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _luckyOtterWorktree = WorktreeInfo(
  path: '/repo-b-wt/lucky-otter',
  branch: 'lucky-otter',
  projectPath: '/repo-b',
);

const _localAgent = AgentSummary(
  agentId: 'a1',
  title: 'Local agent',
  cwd: '/repo-a',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _worktreeAgent = AgentSummary(
  agentId: 'a2',
  title: 'Worktree agent',
  cwd: '/repo-b-wt/lucky-otter',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 200,
  projectPath: '/repo-b',
  branch: 'lucky-otter',
  isWorktree: true,
);

const _orphanAgent = AgentSummary(
  agentId: 'a3',
  title: 'Orphan agent',
  cwd: '/scratch/unregistered',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 300,
);

/// A `FakeDaemonClient` whose `agent.list.request`/`project.list.request`/
/// `worktree.list.request` echo back the fixed data it was constructed
/// with — mirrors the pattern used by `agent_chat_screen_test.dart` /
/// `projects_screen_test.dart` so each notifier's own connect-triggered
/// `refresh()` populates state naturally instead of racing a manual
/// `.upsert()` call.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    this.agents = const [],
    this.projects = const [_projectA, _projectB],
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
    if (type == MessageTypes.agentListRequest) {
      return {'agents': agents.map((a) => a.toJson()).toList()};
    }
    if (type == MessageTypes.projectListRequest) {
      return {'projects': projects.map((p) => p.toJson()).toList()};
    }
    if (type == MessageTypes.worktreeListRequest) {
      final projectPath = payload['projectPath'] as String;
      final worktrees = worktreesByProject[projectPath] ?? const [];
      return {'worktrees': worktrees.map((w) => w.toJson()).toList()};
    }
    return const {};
  }
}

/// `ProjectsNotifier.build()` (and `WorktreesNotifier.build()`) read
/// `connectionStateProvider` (a `StreamProvider` over `client.connectionState`),
/// which needs a few microtask ticks to deliver its first value; without
/// waiting, `build()` runs while the connection still looks unresolved and
/// short-circuits to an empty list. Matches the `pump()` helper in
/// `workspace_providers_test.dart`.
Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<ProviderContainer> makeContainer(
  List<AgentSummary> agents, {
  List<ProjectInfo> projects = const [_projectA, _projectB],
  Map<String, List<WorktreeInfo>> worktreesByProject = const {},
}) async {
  SharedPreferences.setMockInitialValues({});
  final client = FakeDaemonClient(
    agents: agents,
    projects: projects,
    worktreesByProject: worktreesByProject,
  );
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  final projectsSub = container.listen(projectsProvider, (_, _) {});
  addTearDown(projectsSub.close);
  await _pump();
  await container.read(agentsProvider.notifier).refresh();
  await container.read(projectsProvider.future);
  for (final project in projects.where((p) => p.isGitRepo)) {
    final sub = container.listen(worktreesProvider(project.path), (_, _) {});
    addTearDown(sub.close);
    await container.read(worktreesProvider(project.path).future);
  }
  return container;
}

void main() {
  test('groups a local-cwd agent and a worktree agent under their '
      'respective projects (as worktree rows), and buckets an unregistered '
      'cwd as Other', () async {
    final container = await makeContainer(
      [_localAgent, _worktreeAgent, _orphanAgent],
      worktreesByProject: {
        '/repo-a': [_mainWorktreeA],
        '/repo-b': [_mainWorktreeB, _luckyOtterWorktree],
      },
    );

    final groups = container.read(sidebarGroupsProvider);

    expect(groups.pinned, isEmpty);
    expect(groups.projectSections, hasLength(2));
    final sectionA = groups.projectSections.firstWhere(
      (s) => s.project.path == '/repo-a',
    );
    final sectionB = groups.projectSections.firstWhere(
      (s) => s.project.path == '/repo-b',
    );

    expect(sectionA.rows, hasLength(1));
    expect(sectionA.rows.single.worktree?.path, '/repo-a');
    expect(sectionA.rows.single.agents.map((a) => a.agentId), ['a1']);

    expect(sectionB.rows, hasLength(2));
    expect(sectionB.rows.map((r) => r.worktree?.path), [
      '/repo-b',
      '/repo-b-wt/lucky-otter',
    ]);
    expect(sectionB.rows.first.agents, isEmpty);
    expect(sectionB.rows.last.agents.map((a) => a.agentId), ['a2']);

    expect(groups.other.single.agents.map((a) => a.agentId), ['a3']);
  });

  test('a pinned worktree row is hoisted out of its project section, along '
      'with the agent(s) sharing that worktree', () async {
    final container = await makeContainer(
      [_localAgent, _worktreeAgent],
      worktreesByProject: {
        '/repo-a': [_mainWorktreeA],
        '/repo-b': [_mainWorktreeB, _luckyOtterWorktree],
      },
    );
    // Pins are worktree-keyed now (SidebarWorktreeRow.key), not agent-keyed.
    await container.read(sidebarPinsProvider.notifier).togglePin('/repo-a');

    final groups = container.read(sidebarGroupsProvider);

    expect(groups.pinned, hasLength(1));
    expect(groups.pinned.single.worktree?.path, '/repo-a');
    expect(groups.pinned.single.agents.map((a) => a.agentId), ['a1']);

    // The whole row (worktree + its agent) is gone from the project
    // section entirely, not left behind as an idle row.
    expect(groups.projectSections, hasLength(1));
    final sectionB = groups.projectSections.firstWhere(
      (s) => s.project.path == '/repo-b',
    );
    expect(
      sectionB.rows
          .firstWhere((r) => r.worktree?.path == '/repo-b-wt/lucky-otter')
          .agents
          .map((a) => a.agentId),
      ['a2'],
    );
  });

  test('a non-git project with no agents is omitted entirely', () async {
    const localProject = ProjectInfo(
      path: '/local-proj',
      name: 'local-proj',
      isGitRepo: false,
    );
    final container = await makeContainer([], projects: [localProject]);

    final groups = container.read(sidebarGroupsProvider);

    expect(groups.projectSections, isEmpty);
  });

  test('a git project with only an idle worktree still shows a section with '
      'an agent-less row', () async {
    final container = await makeContainer(
      [],
      projects: [_projectA],
      worktreesByProject: {
        '/repo-a': [_mainWorktreeA],
      },
    );

    final groups = container.read(sidebarGroupsProvider);

    expect(groups.projectSections, hasLength(1));
    final rows = groups.projectSections.single.rows;
    expect(rows, hasLength(1));
    expect(rows.single.agents, isEmpty);
    expect(rows.single.worktree?.path, '/repo-a');
  });

  test('empty everywhere reports isEmpty', () async {
    final container = await makeContainer([], projects: const []);

    final groups = container.read(sidebarGroupsProvider);

    expect(groups.isEmpty, isTrue);
  });
}
