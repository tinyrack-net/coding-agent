import 'dart:io';

import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:agent_daemon/src/workspace/workspace_auto_name.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_daemon/src/workspace/worktree_branch_name_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('branch generator prompt keeps the frozen safety contract', () {
    final prompt = buildWorktreeBranchNamePrompt(
      '<user-prompt>\nFix race\n</user-prompt>',
      titleStyle: 'Custom title rules',
      branchStyle: 'Custom branch rules',
    );
    expect(prompt, contains('Do not read files, write files, run tools'));
    expect(prompt, contains('NEVER derived from or slugified from the title'));
    expect(prompt, contains('Title style:\nCustom title rules'));
    expect(prompt, contains('Branch style:\nCustom branch rules'));
    expect(prompt, endsWith('<user-prompt>\nFix race\n</user-prompt>'));
  });

  late Directory temp;
  late String worktree;
  late WorkspaceRegistries registries;
  late _FakeGit git;
  late PersistedWorkspaceRecord workspace;
  late int generations;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('workspace-auto-name-');
    worktree = p.join(temp.path, 'worktree');
    Directory(p.join(worktree, '.git')).createSync(recursive: true);
    writeWorktreeBaseMetadata(worktree, baseRefName: 'main');
    writeWorktreeFirstAgentBranchAutoNameMetadata(
      worktree,
      placeholderBranchName: 'swift-otter',
    );
    registries = WorkspaceRegistries(dataDir: temp.path);
    await registries.initialize();
    git = _FakeGit(dataDir: temp.path)..branch = 'swift-otter';
    workspace = createPersistedWorkspaceRecord(
      workspaceId: 'wks_1',
      projectId: 'prj_1',
      cwd: worktree,
      kind: PersistedWorkspaceKind.worktree,
      displayName: 'swift-otter',
      title: 'Fix the flaky test',
      branch: 'swift-otter',
      worktreeRoot: worktree,
      isPaseoOwnedWorktree: true,
      mainRepoRoot: temp.path,
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    await registries.workspaces.upsert(workspace);
    generations = 0;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  WorkspaceAutoName service({
    String title = 'Stabilize test concurrency',
    String branch = 'stabilize-test-concurrency',
  }) => WorkspaceAutoName(
    workspaces: registries.workspaces,
    git: git,
    generate: (seed, cwd) async {
      generations++;
      return GeneratedWorkspaceName(title: title, branch: branch);
    },
    now: () => DateTime.utc(2026, 7, 29),
  );

  test('renames placeholder branch and persists generated title', () async {
    await service().run(workspace, {'prompt': 'Fix the flaky test'});

    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(updated.title, 'Stabilize test concurrency');
    expect(updated.branch, 'stabilize-test-concurrency');
    expect(updated.displayName, 'stabilize-test-concurrency');
    expect(git.branch, 'stabilize-test-concurrency');
    expect(generations, 1);
    expect(
      readWorktreeMetadata(worktree)!.firstAgentBranchAutoName?['status'],
      'attempted',
    );
  });

  test('uses a numbered branch when the generated branch collides', () async {
    git.existing.add('stabilize-test-concurrency');
    await service().run(workspace, {'prompt': 'Fix the flaky test'});
    expect(git.branch, 'stabilize-test-concurrency-2');
  });

  test('marks attempted and keeps branch when user changed it first', () async {
    git.branch = 'manual-branch';
    await service().run(workspace, {'prompt': 'Fix the flaky test'});
    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(updated.branch, 'swift-otter');
    expect(updated.title, 'Stabilize test concurrency');
    expect(git.branch, 'manual-branch');
    expect(generations, 1);
    expect(
      readWorktreeMetadata(worktree)!.firstAgentBranchAutoName?['status'],
      'attempted',
    );
  });

  test('does not overwrite a user-edited workspace title', () async {
    await registries.workspaces.upsert(workspace.copyWith(title: 'My title'));
    await service().run(workspace, {'prompt': 'Fix the flaky test'});
    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(updated.title, 'My title');
    expect(updated.branch, 'stabilize-test-concurrency');
  });
}

final class _FakeGit extends GitService {
  _FakeGit({required super.dataDir});

  String branch = 'main';
  final Set<String> existing = {};

  @override
  Future<String> currentBranch(String projectPath) async => branch;

  @override
  Future<bool> localBranchExists(String projectPath, String name) async =>
      existing.contains(name);

  @override
  Future<String> renameCurrentBranch(String projectPath, String name) async {
    branch = name;
    return branch;
  }
}
