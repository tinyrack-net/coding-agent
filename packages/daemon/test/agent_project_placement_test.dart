import 'dart:io';

import 'package:agent_daemon/src/server/agent_project_placement.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

AgentSummary _agent(String workspaceId) => AgentSummary(
  agentId: 'agent-1',
  title: 'Agent',
  cwd: '/repo/worktree',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  workspaceId: workspaceId,
);

void main() {
  late Directory temp;
  late WorkspaceRegistries registries;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('agent-placement-');
    registries = WorkspaceRegistries(dataDir: temp.path);
    await registries.initialize();
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('projects authoritative worktree registry placement', () async {
    await registries.projects.upsert(
      createPersistedProjectRecord(
        projectId: 'project-1',
        rootPath: '/repo',
        kind: PersistedProjectKind.git,
        displayName: 'repo',
        customName: 'Custom Repo',
        createdAt: '2026-07-28T00:00:00.000Z',
        updatedAt: '2026-07-28T00:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace-1',
        projectId: 'project-1',
        cwd: '/repo/worktree',
        kind: PersistedWorkspaceKind.worktree,
        displayName: 'feature/frozen',
        title: 'Frozen workspace',
        branch: 'feature/frozen',
        worktreeRoot: '/repo/worktree',
        baseBranch: 'main',
        isPaseoOwnedWorktree: true,
        mainRepoRoot: '/repo',
        createdAt: '2026-07-28T00:00:00.000Z',
        updatedAt: '2026-07-28T00:00:00.000Z',
      ),
    );

    expect(
      await buildAgentProjectPlacement(_agent('workspace-1'), registries),
      {
        'projectKey': 'project-1',
        'projectName': 'Custom Repo',
        'workspaceName': 'Frozen workspace',
        'checkout': {
          'cwd': '/repo/worktree',
          'isGit': true,
          'currentBranch': 'feature/frozen',
          'remoteUrl': null,
          'worktreeRoot': '/repo/worktree',
          'isPaseoOwnedWorktree': true,
          'mainRepoRoot': '/repo',
        },
      },
    );
  });

  test('projects directory placement and enforces active ownership', () async {
    await registries.projects.upsert(
      createPersistedProjectRecord(
        projectId: 'project-1',
        rootPath: '/repo',
        kind: PersistedProjectKind.nonGit,
        displayName: 'repo',
        createdAt: '2026-07-28T00:00:00.000Z',
        updatedAt: '2026-07-28T00:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace-1',
        projectId: 'project-1',
        cwd: '/repo',
        kind: PersistedWorkspaceKind.directory,
        displayName: 'repo',
        createdAt: '2026-07-28T00:00:00.000Z',
        updatedAt: '2026-07-28T00:00:00.000Z',
        archivedAt: '2026-07-29T00:00:00.000Z',
      ),
    );

    final historical = await buildAgentProjectPlacement(
      _agent('workspace-1'),
      registries,
    );
    expect(historical?['projectKey'], 'project-1');
    expect(historical?['checkout'], {
      'cwd': '/repo',
      'isGit': false,
      'currentBranch': null,
      'remoteUrl': null,
      'worktreeRoot': null,
      'isPaseoOwnedWorktree': false,
      'mainRepoRoot': null,
    });
    expect(
      await buildAgentProjectPlacement(
        _agent('workspace-1'),
        registries,
        activeOnly: true,
      ),
      isNull,
    );
    expect(
      await buildAgentProjectPlacement(_agent('missing'), registries),
      isNull,
    );
    expect(
      await buildAgentProjectPlacement(
        _agent('workspace-1').copyWith(archivedAt: '2026-07-29T00:00:00.000Z'),
        registries,
        activeOnly: true,
      ),
      isNull,
    );
  });
}
