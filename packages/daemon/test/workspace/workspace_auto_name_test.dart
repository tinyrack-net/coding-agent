import 'dart:io';

import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:agent_daemon/src/agent/structured_generation.dart';
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

  test('reads frozen nested paseo.json metadata instructions', () async {
    final directory = Directory.systemTemp.createTempSync(
      'workspace-metadata-style-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File(p.join(directory.path, 'paseo.json')).writeAsStringSync('''
{"metadataGeneration":{"title":{"instructions":"Project title style"},"branchName":{"instructions":"Project branch style"}}}
''');
    final styles = await resolveWorktreeMetadataStyles(directory.path);
    expect(styles.$1, 'Project title style');
    expect(styles.$2, 'Project branch style');
  });

  late Directory temp;
  late String worktree;
  late WorkspaceRegistries registries;
  late _FakeGit git;
  late PersistedWorkspaceRecord workspace;
  late int generations;
  late List<(String, String)> mutations;

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
    mutations = [];
  });

  tearDown(() => temp.deleteSync(recursive: true));

  WorkspaceAutoName service({
    String title = 'Stabilize test concurrency',
    String branch = 'stabilize-test-concurrency',
  }) => WorkspaceAutoName(
    workspaces: registries.workspaces,
    git: git,
    generate: (seed, cwd, currentSelection) async {
      generations++;
      return GeneratedWorkspaceName(title: title, branch: branch);
    },
    notifyGitMutation: (cwd, mutation) async => mutations.add((cwd, mutation)),
    now: () => DateTime.utc(2026, 7, 29),
  );

  test('renames placeholder branch and persists generated title', () async {
    await service().run(workspace, {'prompt': 'Fix the flaky test'});

    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(updated.title, 'Stabilize test concurrency');
    expect(updated.branch, 'stabilize-test-concurrency');
    expect(updated.displayName, 'swift-otter');
    expect(git.branch, 'stabilize-test-concurrency');
    expect(generations, 1);
    expect(mutations, [(worktree, 'rename-branch')]);
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

  test('keeps generated title when the generated branch is invalid', () async {
    await service(
      branch: 'Invalid Branch',
    ).run(workspace, {'prompt': 'Fix the flaky test'});
    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(updated.title, 'Stabilize test concurrency');
    expect(updated.branch, 'swift-otter');
    expect(git.branch, 'swift-otter');
    expect(mutations, isEmpty);
  });

  test('forwards the focused provider selection to generation', () async {
    StructuredGenerationSelection? observed;
    final autoName = WorkspaceAutoName(
      workspaces: registries.workspaces,
      git: git,
      generate: (seed, cwd, currentSelection) async {
        observed = currentSelection;
        return const GeneratedWorkspaceName(
          title: 'Focused provider title',
          branch: 'focused-provider-title',
        );
      },
    );
    await autoName.run(
      workspace,
      {'prompt': 'Fix the flaky test'},
      currentSelection: const StructuredGenerationSelection(
        provider: 'codex',
        model: 'gpt-5.4',
        thinkingOptionId: 'low',
      ),
    );
    expect(observed?.provider, 'codex');
    expect(observed?.model, 'gpt-5.4');
    expect(observed?.thinkingOptionId, 'low');
  });

  test('marks attempted when generation returns no result', () async {
    final autoName = WorkspaceAutoName(
      workspaces: registries.workspaces,
      git: git,
      generate: (seed, cwd, currentSelection) async => null,
    );
    await autoName.run(workspace, {'prompt': 'Fix the flaky test'});
    expect(git.branch, 'swift-otter');
    expect(
      readWorktreeMetadata(worktree)!.firstAgentBranchAutoName?['status'],
      'attempted',
    );
  });

  test('does not rename when the branch changes during generation', () async {
    final autoName = WorkspaceAutoName(
      workspaces: registries.workspaces,
      git: git,
      generate: (seed, cwd, currentSelection) async {
        git.branch = 'manual-during-generation';
        return const GeneratedWorkspaceName(
          title: 'Generated title',
          branch: 'generated-branch',
        );
      },
    );
    await autoName.run(workspace, {'prompt': 'Fix the flaky test'});
    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(git.branch, 'manual-during-generation');
    expect(updated.branch, 'swift-otter');
    expect(updated.title, 'Generated title');
  });

  test('stops after fifty occupied branch candidates', () async {
    git.existing.add('stabilize-test-concurrency');
    for (var suffix = 2; suffix <= 50; suffix++) {
      git.existing.add('stabilize-test-concurrency-$suffix');
    }
    await service().run(workspace, {'prompt': 'Fix the flaky test'});
    final updated = (await registries.workspaces.get('wks_1'))!;
    expect(git.branch, 'swift-otter');
    expect(updated.branch, 'swift-otter');
    expect(updated.title, 'Stabilize test concurrency');
    expect(mutations, isEmpty);
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
