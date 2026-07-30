import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:agent_daemon/src/agent/structured_generation.dart';
import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/workspace_forge_status_service.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/agent_attention_policy.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/workspace/polling_workspace_git_backend.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_daemon/src/workspace/workspace_auto_name.dart';
import 'package:agent_daemon/src/workspace/workspace_setup_service.dart';
import 'package:agent_daemon/src/workspace/workspace_v2_service.dart';
import 'package:agent_daemon/src/workspace/worktree_terminal_bootstrap_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late Directory temp;
  late Directory projectDirectory;
  late WorkspaceRegistries registries;
  late _FakeGitService git;
  late List<AgentSummary> agents;
  late List<TerminalWorkspaceContribution> terminals;
  late List<(Map<String, Object?>, Set<String>)> broadcasts;
  late WorkspaceV2Service service;
  late Connection connection;
  var nextWorkspaceId = 0;
  late DateTime now;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('workspace-v2-service-');
    projectDirectory = Directory('${temp.path}${Platform.pathSeparator}project')
      ..createSync();
    registries = WorkspaceRegistries(
      dataDir: temp.path,
      projectIdFactory: () => 'prj_1',
    );
    await registries.initialize();
    git = _FakeGitService(dataDir: temp.path)..root = projectDirectory.path;
    agents = [];
    terminals = [];
    now = DateTime.utc(2026, 7, 26);
    broadcasts = [];
    service = WorkspaceV2Service(
      registries: registries,
      git: git,
      listAgents: () => agents,
      listTerminalContributions: () => terminals,
      broadcast: (message, ids) => broadcasts.add((message, ids)),
      workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
      worktreeSlugFactory: () => 'dazzling-yak',
      now: () => now,
    );
    connection = Connection(_FakeWebSocketChannel(), id: 'connection-1');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<WorkspaceCreateResponse> createWorktree({
    String? cwd,
    String? projectId,
    WorktreeCreateAction? action,
    String? refName,
    String? baseBranch,
    String? branchName,
    Map<String, Object?>? checkoutSource,
    int? githubPrNumber,
    String? worktreeSlug,
    Map<String, Object?>? firstAgentContext,
  }) async => WorkspaceCreateResponse.fromJson(
    (await service.handle(
      connection,
      WorkspaceCreateRequest(
        requestId: 'worktree',
        source: WorktreeWorkspaceCreateSource(
          cwd: cwd,
          projectId: projectId,
          action: action,
          refName: refName,
          baseBranch: baseBranch,
          branchName: branchName,
          checkoutSource: checkoutSource,
          githubPrNumber: githubPrNumber,
          worktreeSlug: worktreeSlug,
        ),
        firstAgentContext: firstAgentContext,
      ).toJson(),
    ))!,
  );

  PersistedProjectRecord project() => createPersistedProjectRecord(
    projectId: 'prj_empty',
    rootPath: projectDirectory.path,
    kind: PersistedProjectKind.nonGit,
    displayName: 'Project',
    createdAt: '1',
    updatedAt: '1',
  );

  PersistedWorkspaceRecord workspace({
    String id = 'wks_1',
    String projectId = 'prj_empty',
    String name = 'main',
    String updatedAt = '1',
    String? cwd,
    String? worktreeRoot,
    bool owned = false,
    String? branch,
    String? baseBranch,
    String? archivedAt,
    PersistedWorkspaceKind? kind,
  }) => createPersistedWorkspaceRecord(
    workspaceId: id,
    projectId: projectId,
    cwd: cwd ?? projectDirectory.path,
    kind:
        kind ??
        (worktreeRoot == null
            ? PersistedWorkspaceKind.directory
            : PersistedWorkspaceKind.worktree),
    displayName: name,
    branch: branch,
    baseBranch: baseBranch,
    worktreeRoot: worktreeRoot,
    isPaseoOwnedWorktree: owned,
    mainRepoRoot: owned ? projectDirectory.path : null,
    createdAt: '1',
    updatedAt: updatedAt,
    archivedAt: archivedAt,
  );

  AgentSummary agent(
    String id,
    String workspaceId,
    AgentRunState runState, {
    String? updatedAt,
    String? parentAgentId,
  }) => AgentSummary(
    agentId: id,
    title: id,
    cwd: projectDirectory.path,
    provider: 'codex',
    model: 'gpt',
    mode: AgentMode.normal,
    runState: runState,
    createdAtMs: 1,
    updatedAt: updatedAt,
    workspaceId: workspaceId,
    parentAgentId: parentAgentId,
  );

  group('import workspace provisioning', () {
    test('reuses a matching active requested workspace', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace());

      final result = await service.runInImportWorkspace(
        cwd: projectDirectory.path,
        requestedWorkspaceId: 'wks_1',
        operation: (selected) async => selected.workspaceId,
      );

      expect(result.value, 'wks_1');
      expect(result.createdWorkspace, isNull);
      expect(await registries.workspaces.list(), hasLength(1));
    });

    test('rejects invalid requested workspace placement', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace());

      await expectLater(
        service.runInImportWorkspace(
          cwd: temp.path,
          requestedWorkspaceId: 'wks_1',
          operation: (_) async => fail('must not import'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Import cwd does not match workspace: wks_1',
          ),
        ),
      );
      await registries.workspaces.archive('wks_1', '2');
      await expectLater(
        service.runInImportWorkspace(
          cwd: projectDirectory.path,
          requestedWorkspaceId: 'wks_1',
          operation: (_) async => fail('must not import'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('creates a fresh workspace and rolls it back on failure', () async {
      final success = await service.runInImportWorkspace(
        cwd: projectDirectory.path,
        operation: (selected) async => selected.workspaceId,
      );
      expect(success.createdWorkspace?.workspaceId, success.value);
      expect(await registries.workspaces.list(), hasLength(1));

      await expectLater(
        service.runInImportWorkspace<void>(
          cwd: projectDirectory.path,
          operation: (_) async => throw StateError('import failed'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await registries.workspaces.list(), hasLength(1));
      expect(await registries.projects.list(), hasLength(1));
    });

    test('removes a newly created project when import fails', () async {
      await expectLater(
        service.runInImportWorkspace<void>(
          cwd: projectDirectory.path,
          operation: (_) async => throw StateError('import failed'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await registries.workspaces.list(), isEmpty);
      expect(await registries.projects.list(), isEmpty);
    });
  });

  group('directory creation', () {
    test('creates a fresh non-git workspace every time', () async {
      final request = WorkspaceCreateRequest(
        requestId: 'req_1',
        title: 'Named',
        source: DirectoryWorkspaceCreateSource(path: projectDirectory.path),
      );

      final first = WorkspaceCreateResponse.fromJson(
        (await service.handle(connection, request.toJson()))!,
      );
      final second = WorkspaceCreateResponse.fromJson(
        (await service.handle(connection, request.toJson()))!,
      );

      expect(first.error, isNull);
      expect(first.workspace?.workspaceKind, WorkspaceKind.directory);
      expect(first.workspace?.name, 'Named');
      expect(second.workspace?.id, isNot(first.workspace?.id));
      expect(await registries.projects.list(), hasLength(1));
      expect(await registries.workspaces.list(), hasLength(2));
    });

    test('discovers git root and branch', () async {
      git
        ..isGit = true
        ..branch = 'feature';
      final response = WorkspaceCreateResponse.fromJson(
        (await service.handle(
          connection,
          WorkspaceCreateRequest(
            requestId: 'req',
            source: DirectoryWorkspaceCreateSource(path: projectDirectory.path),
          ).toJson(),
        ))!,
      );

      expect(response.workspace?.projectKind, WorkspaceProjectKind.git);
      expect(response.workspace?.workspaceKind, WorkspaceKind.localCheckout);
      expect(response.workspace?.name, 'feature');
      expect(response.workspace?.gitRuntime?.currentBranch, 'feature');
      expect(
        (await registries.projects.list()).single.rootPath,
        projectDirectory.path,
      );
    });

    test('returns stable errors for missing directory and project', () async {
      final missing = WorkspaceCreateResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceCreateRequest(
            requestId: 'missing',
            source: DirectoryWorkspaceCreateSource(path: '/missing/path'),
          ).toJson(),
        ))!,
      );
      expect(missing.errorCode, 'directory_not_found');

      final missingProject = WorkspaceCreateResponse.fromJson(
        (await service.handle(
          connection,
          WorkspaceCreateRequest(
            requestId: 'project',
            source: DirectoryWorkspaceCreateSource(
              path: projectDirectory.path,
              projectId: 'prj_missing',
            ),
          ).toJson(),
        ))!,
      );
      expect(missingProject.errorCode, 'project_not_found');
    });
  });

  group('open project compatibility', () {
    test(
      'deduplicates active cwd and creates only the first workspace',
      () async {
        final first = OpenProjectResponse.fromJson(
          (await service.handle(
            connection,
            OpenProjectRequest(
              cwd: projectDirectory.path,
              requestId: 'open-1',
            ).toJson(),
          ))!,
        );
        final second = OpenProjectResponse.fromJson(
          (await service.handle(
            connection,
            OpenProjectRequest(
              cwd: projectDirectory.path,
              requestId: 'open-2',
            ).toJson(),
          ))!,
        );
        expect(first.error, isNull);
        expect(second.workspace?.id, first.workspace?.id);
        expect(await registries.workspaces.list(), hasLength(1));
      },
    );

    test('reports missing directories with the frozen error code', () async {
      final response = OpenProjectResponse.fromJson(
        await service.openProject(
          OpenProjectRequest(
            cwd: '${temp.path}${Platform.pathSeparator}missing',
            requestId: 'missing',
          ),
        ),
      );
      expect(response.workspace, isNull);
      expect(response.errorCode, 'directory_not_found');
      expect(response.error, startsWith('Directory not found:'));
    });
  });

  group('scheduled run workspaces', () {
    test('local isolation creates a durable prompt-titled workspace', () async {
      final created = await service.createScheduleRunWorkspace(
        cwd: projectDirectory.path,
        isolation: 'local',
        prompt: '  Review   the branch  ',
        runId: '12345678-1234-1234-1234-123456789012',
      );

      expect(created.cwd, projectDirectory.path);
      expect(created.title, 'Review the branch');
      expect(created.isPaseoOwnedWorktree, isFalse);
      expect(await registries.workspaces.get(created.workspaceId), isNotNull);
    });

    test('worktree isolation creates and force-archives its sandbox', () async {
      git.isGit = true;
      final created = await service.createScheduleRunWorkspace(
        cwd: projectDirectory.path,
        isolation: 'worktree',
        prompt: 'Implement scheduled change',
        runId: 'abcdef12-3456-7890-abcd-ef1234567890',
      );

      expect(git.createdBranch, 'schedule-abcdef123456');
      expect(created.isPaseoOwnedWorktree, isTrue);
      await service.archiveScheduleRunWorkspace(created.workspaceId);
      expect(git.archivedPaths, [created.worktreeRoot]);
      expect(git.archiveForces, [isTrue]);
      expect(
        (await registries.workspaces.get(created.workspaceId))?.archivedAt,
        isNotNull,
      );
    });
  });

  group('worktree creation', () {
    test('requires an existing git source', () async {
      final noDirectory = await createWorktree(cwd: '/missing');
      expect(noDirectory.errorCode, 'directory_not_found');

      final nonGit = await createWorktree(cwd: projectDirectory.path);
      expect(nonGit.errorCode, 'not_git_repository');
    });

    test('persists Paseo-owned worktree placement', () async {
      git
        ..isGit = true
        ..branch = 'feature';
      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.branchOff,
        refName: 'main',
        branchName: 'feature',
      );

      expect(response.error, isNull);
      expect(response.workspace?.workspaceKind, WorkspaceKind.worktree);
      final record = (await registries.workspaces.list()).single;
      expect(record.isPaseoOwnedWorktree, isTrue);
      expect(record.mainRepoRoot, projectDirectory.path);
      expect(record.baseBranch, 'main');
      expect(git.createdBranch, 'feature');
      expect(git.createdBaseRef, 'main');
    });

    test(
      'omitted branch-off names use a mnemonic placeholder and default branch',
      () async {
        git
          ..isGit = true
          ..branch = 'current-topic'
          ..defaultBranch = 'trunk';

        final response = await createWorktree(
          cwd: projectDirectory.path,
          action: WorktreeCreateAction.branchOff,
        );

        expect(response.error, isNull);
        expect(git.createdBranch, 'dazzling-yak');
        expect(git.createdWorktreeSlug, 'dazzling-yak');
        expect(git.createdBaseRef, 'trunk');
        expect(git.createdBranchOff, isTrue);
        final record = (await registries.workspaces.list()).single;
        expect(record.branch, 'dazzling-yak');
        expect(record.baseBranch, 'trunk');
        final metadata = readWorktreeMetadata(record.worktreeRoot!);
        expect(metadata?.version, 2);
        expect(metadata?.firstAgentBranchAutoName, {
          'status': 'pending',
          'placeholderBranchName': 'dazzling-yak',
        });
      },
    );

    test('uses the focused same-cwd agent for metadata generation', () async {
      final observed = Completer<StructuredGenerationSelection?>();
      final autoName = WorkspaceAutoName(
        workspaces: registries.workspaces,
        git: git,
        generate: (seed, cwd, currentSelection) async {
          observed.complete(currentSelection);
          return const GeneratedWorkspaceName(
            title: 'Focused selection title',
            branch: 'focused-selection-title',
          );
        },
      );
      agents.add(
        AgentSummary(
          agentId: 'focused-agent',
          title: 'Focused',
          cwd: projectDirectory.path,
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 1,
          thinkingOptionId: 'low',
        ),
      );
      connection.clientPresence = const ClientPresenceState(
        appVisible: true,
        lastActivityAtMs: 1,
        focusedAgentId: 'focused-agent',
        focusedTerminalId: null,
      );
      service = WorkspaceV2Service(
        registries: registries,
        git: git,
        listAgents: () => agents,
        broadcast: (message, ids) => broadcasts.add((message, ids)),
        workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
        worktreeSlugFactory: () => 'dazzling-yak',
        workspaceAutoName: autoName,
      );
      final response = WorkspaceCreateResponse.fromJson(
        (await service.handle(
          connection,
          WorkspaceCreateRequest(
            requestId: 'focused-selection',
            source: DirectoryWorkspaceCreateSource(path: projectDirectory.path),
            firstAgentContext: const {'prompt': 'Fix focused flow'},
          ).toJson(),
        ))!,
      );
      expect(response.error, isNull);
      final selection = await observed.future;
      expect(selection?.provider, 'codex');
      expect(selection?.model, 'gpt-5.4');
      expect(selection?.thinkingOptionId, 'low');
      await _waitUntil(
        () async =>
            (await registries.workspaces.get(response.workspace!.id))?.title ==
            'Focused selection title',
      );
    });

    test(
      'explicit branch supplies the managed slug when slug is omitted',
      () async {
        git
          ..isGit = true
          ..defaultBranch = 'main';

        final response = await createWorktree(
          cwd: projectDirectory.path,
          action: WorktreeCreateAction.branchOff,
          branchName: 'feature/exact-name',
        );

        expect(response.error, isNull);
        expect(git.lookedUpWorktreeSlug, 'feature-exact-name');
        expect(git.createdWorktreeSlug, 'feature-exact-name');
        expect(git.createdBaseRef, 'main');
      },
    );

    test(
      'normalizes slugs but strictly validates explicit branch names',
      () async {
        git.isGit = true;
        final normalized = await createWorktree(
          cwd: projectDirectory.path,
          action: WorktreeCreateAction.branchOff,
          worktreeSlug: '  Feature / Exact Name  ',
        );
        expect(normalized.error, isNull);
        expect(git.createdBranch, 'feature-exact-name');
        expect(git.createdWorktreeSlug, 'feature-exact-name');

        git.createdBranch = null;
        final invalid = await createWorktree(
          cwd: projectDirectory.path,
          action: WorktreeCreateAction.branchOff,
          branchName: 'Feature Name',
        );
        expect(invalid.errorCode, 'invalid_worktree_name');
        expect(invalid.error, contains('only lowercase letters'));
        expect(git.createdBranch, isNull);
      },
    );

    test('reuses the worktree already occupying a managed slug', () async {
      git
        ..isGit = true
        ..existingWorktree = WorktreeInfo(
          path:
              '${projectDirectory.path}${Platform.pathSeparator}'
              'steady-otter',
          branch: 'renamed-after-first-agent',
          projectPath: projectDirectory.path,
        );

      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.branchOff,
        worktreeSlug: 'steady-otter',
      );

      expect(response.error, isNull);
      expect(git.lookedUpWorktreeSlug, 'steady-otter');
      expect(git.createdBranch, isNull);
      expect(response.workspace?.name, 'renamed-after-first-agent');
    });

    test('checkout without a target reports the frozen error', () async {
      git.isGit = true;

      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.checkout,
      );

      expect(response.errorCode, 'missing_checkout_target');
      expect(response.error, 'action "checkout" requires refName');
    });

    test('checkout-branch requires and fetches an existing branch', () async {
      git.isGit = true;
      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.checkout,
        refName: 'existing-work',
        branchName: 'existing-work',
        worktreeSlug: 'existing-work-copy',
      );

      expect(response.error, isNull);
      expect(git.createdBranch, 'existing-work');
      expect(git.createdWorktreeSlug, 'existing-work-copy');
      expect(git.createdRequireExistingBranch, isTrue);
      expect(git.createdFetchRef, isNull);
    });

    test(
      'checkout change request selects forge-specific remote refs',
      () async {
        git
          ..isGit = true
          ..originForge = 'gitlab';
        final response = await createWorktree(
          cwd: projectDirectory.path,
          action: WorktreeCreateAction.checkout,
          checkoutSource: const {
            'kind': 'change_request',
            'forge': 'gitlab',
            'number': 42,
          },
          worktreeSlug: 'review-42',
        );

        expect(response.error, isNull);
        expect(git.createdBranch, 'review-42');
        expect(git.createdWorktreeSlug, 'review-42');
        expect(git.createdFetchRef, 'refs/merge-requests/42/head');
        expect(git.createdRequireExistingBranch, isFalse);
      },
    );

    test('checkout change request rejects a mismatched forge', () async {
      git
        ..isGit = true
        ..originForge = 'github';
      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.checkout,
        checkoutSource: const {
          'kind': 'change_request',
          'forge': 'gitlab',
          'number': 42,
        },
      );

      expect(response.errorCode, 'checkout_forge_mismatch');
      expect(response.error, contains('resolved to github'));
      expect(git.createdBranch, isNull);
    });

    test('legacy GitHub PR checkout uses the pull ref namespace', () async {
      git.isGit = true;
      final response = await createWorktree(
        cwd: projectDirectory.path,
        action: WorktreeCreateAction.checkout,
        githubPrNumber: 7,
      );

      expect(response.error, isNull);
      expect(git.createdBranch, 'pr-7');
      expect(git.createdFetchRef, 'refs/pull/7/head');
    });

    test('starts background setup progress for a created worktree', () async {
      final execution = Completer<WorkspaceSetupExecutionResult>();
      final setup = WorkspaceSetupService(
        broadcast: (_) {},
        loadCommands: (_) async => const ['install'],
        executeCommand: (_, _, _, onOutput) {
          onOutput('installing');
          return execution.future;
        },
      );
      service = WorkspaceV2Service(
        registries: registries,
        git: git,
        listAgents: () => agents,
        listTerminalContributions: () => terminals,
        broadcast: (message, ids) => broadcasts.add((message, ids)),
        workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
        now: () => now,
        workspaceSetup: setup,
      );
      git
        ..isGit = true
        ..branch = 'feature';

      final response = await createWorktree(
        cwd: projectDirectory.path,
        branchName: 'feature',
      );
      final workspaceId = response.workspace!.id;
      await _waitUntil(
        () async =>
            setup.snapshotFor(workspaceId)?.detail.commands.isNotEmpty ?? false,
      );
      expect(
        setup.snapshotFor(workspaceId)?.status,
        WorkspaceSetupStatus.running,
      );
      expect(
        setup.snapshotFor(workspaceId)?.detail.commands.single.command,
        'install',
      );

      execution.complete(
        const WorkspaceSetupExecutionResult(exitCode: 0, output: 'installing'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        setup.snapshotFor(workspaceId)?.status,
        WorkspaceSetupStatus.completed,
      );
      // The frozen flow emits setup completion before its final workspace
      // projection update; wait for that asynchronous persistence boundary.
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });

    test(
      'first-agent continuation waits for agent creation, then setup and terminals',
      () async {
        final lifecycle = <String>[];
        final timeline = <TimelineItem>[];
        final setup = WorkspaceSetupService(
          broadcast: (_) {},
          loadCommands: (_) async => const ['install'],
          resolveEnvironment: (_, _, _) async => const {
            'PASEO_WORKTREE_PORT': '45678',
          },
          executeCommand: (_, _, _, _) async {
            lifecycle.add('setup');
            return const WorkspaceSetupExecutionResult(
              exitCode: 0,
              output: 'installed',
            );
          },
        );
        final terminalBootstrap = WorktreeTerminalBootstrapService(
          loadSpecs: (_) async => const [
            WorktreeTerminalSpec(name: 'Dev', command: 'npm run dev'),
          ],
          createTerminal:
              ({required cwd, required workspaceId, required name}) async {
                lifecycle.add('terminal:$name:$workspaceId');
                return {'terminalId': 'term_1', 'name': name};
              },
          waitUntilReady: (_) async => lifecycle.add('ready'),
          sendInput: (_, input) => lifecycle.add('input:$input'),
        );
        service = WorkspaceV2Service(
          registries: registries,
          git: git,
          listAgents: () => agents,
          listTerminalContributions: () => terminals,
          broadcast: (message, ids) => broadcasts.add((message, ids)),
          workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
          now: () => now,
          workspaceSetup: setup,
          terminalBootstrap: terminalBootstrap,
          appendAgentTimeline: (_, item) {
            timeline.add(item);
            return true;
          },
        );
        git
          ..isGit = true
          ..branch = 'feature';
        final response = WorkspaceCreateResponse.fromJson(
          (await service.handle(
            connection,
            WorkspaceCreateRequest(
              requestId: 'agent-continuation',
              source: WorktreeWorkspaceCreateSource(
                cwd: projectDirectory.path,
                branchName: 'feature',
              ),
              firstAgentContext: const {'prompt': 'fix it'},
            ).toJson(),
          ))!,
        );
        final workspaceId = response.workspace!.id;
        expect(response.workspace!.title, 'fix it');

        await Future<void>.delayed(Duration.zero);
        expect(setup.snapshotFor(workspaceId), isNull);
        expect(lifecycle, isEmpty);

        final started = service.startAgentContinuation(
          agent('agent-1', workspaceId, AgentRunState.initializing),
        );
        expect(started, isTrue);
        await _waitUntil(
          () async => timeline.whereType<ToolCallItem>().any(
            (item) =>
                item.toolName == 'paseo_worktree_terminals' &&
                item.status == ToolCallStatus.success,
          ),
        );

        expect(lifecycle, [
          'setup',
          'terminal:Dev:$workspaceId',
          'ready',
          'input:npm run dev\r',
        ]);
        expect(
          timeline.whereType<ToolCallItem>().map((item) => item.toolName),
          [
            'paseo_worktree_setup',
            'paseo_worktree_setup',
            'paseo_worktree_terminals',
            'paseo_worktree_terminals',
          ],
        );
        expect(
          service.startAgentContinuation(
            agent('agent-2', workspaceId, AgentRunState.initializing),
          ),
          isFalse,
        );
      },
    );

    test('failed first-agent creation cleans its pending worktree', () async {
      final setup = WorkspaceSetupService(
        broadcast: (_) {},
        loadCommands: (_) async => const [],
      );
      service = WorkspaceV2Service(
        registries: registries,
        git: git,
        listAgents: () => agents,
        listTerminalContributions: () => terminals,
        broadcast: (message, ids) => broadcasts.add((message, ids)),
        workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
        now: () => now,
        workspaceSetup: setup,
      );
      git
        ..isGit = true
        ..branch = 'feature';
      final response = WorkspaceCreateResponse.fromJson(
        (await service.handle(
          connection,
          WorkspaceCreateRequest(
            requestId: 'agent-failure',
            source: WorktreeWorkspaceCreateSource(
              cwd: projectDirectory.path,
              branchName: 'feature',
            ),
            firstAgentContext: const {},
          ).toJson(),
        ))!,
      );
      final workspaceId = response.workspace!.id;

      expect(await service.cancelAgentContinuation(workspaceId), isTrue);
      expect(git.archivedPaths, [response.workspace!.workspaceDirectory]);
      expect(git.archiveForces, [isTrue]);
      expect(
        (await registries.workspaces.get(workspaceId))?.archivedAt,
        isNotNull,
      );
      expect(await service.cancelAgentContinuation(workspaceId), isFalse);
    });

    test(
      'archives only the workspace record when setup preflight fails',
      () async {
        final setup = WorkspaceSetupService(
          broadcast: (_) {},
          loadCommands: (_) async => const ['install'],
          resolveEnvironment: (_, _, _) => throw StateError('port unavailable'),
        );
        service = WorkspaceV2Service(
          registries: registries,
          git: git,
          listAgents: () => agents,
          listTerminalContributions: () => terminals,
          broadcast: (message, ids) => broadcasts.add((message, ids)),
          workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
          now: () => now,
          workspaceSetup: setup,
        );
        git
          ..isGit = true
          ..branch = 'feature';

        final response = await createWorktree(
          cwd: projectDirectory.path,
          branchName: 'feature',
        );
        final workspaceId = response.workspace!.id;
        await _waitUntil(
          () async =>
              (await registries.workspaces.get(workspaceId))?.archivedAt !=
              null,
        );

        expect(
          setup.snapshotFor(workspaceId)?.status,
          WorkspaceSetupStatus.failed,
        );
        expect(git.archivedPaths, isEmpty);
      },
    );

    test('uses a registered project when cwd is omitted', () async {
      git.isGit = true;
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'prj_existing',
          rootPath: projectDirectory.path,
          kind: PersistedProjectKind.git,
          displayName: 'project',
          createdAt: '1',
          updatedAt: '1',
        ),
      );
      final response = await createWorktree(
        projectId: 'prj_existing',
        branchName: 'feature',
      );
      expect(response.workspace?.projectId, 'prj_existing');
    });

    test('maps git failures into create response', () async {
      git
        ..isGit = true
        ..createError = GitException(
          args: const ['worktree', 'add'],
          exitCode: 1,
          stderr: 'branch is already checked out',
        );
      final response = await createWorktree(
        cwd: projectDirectory.path,
        branchName: 'feature',
      );
      expect(response.errorCode, 'git_error');
      expect(response.error, contains('already checked out'));
    });
  });

  group('legacy worktree compatibility', () {
    test(
      'create adapts the legacy branch-off request to workspace v2',
      () async {
        git
          ..isGit = true
          ..root = projectDirectory.path;

        final response = CreatePaseoWorktreeResponse.fromJson(
          (await service.handle(
            connection,
            const CreatePaseoWorktreeRequest(
              requestId: 'legacy-create',
              cwd: 'unused',
              worktreeSlug: 'feature-x',
              refName: 'develop',
              action: 'branch-off',
            ).toJson()..['cwd'] = projectDirectory.path,
          ))!,
        );

        expect(response.error, isNull);
        expect(response.workspace?['name'], 'feature-x');
        expect(git.createdBranch, 'feature-x');
        expect(git.createdBaseRef, 'develop');
        expect(git.createdWorktreeSlug, 'feature-x');
      },
    );

    test('list projects active owned worktrees once per root', () async {
      final worktreeRoot =
          '${projectDirectory.path}${Platform.pathSeparator}feature';
      await Directory(worktreeRoot).create();
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(
          id: 'wks_a',
          cwd: worktreeRoot,
          worktreeRoot: worktreeRoot,
          owned: true,
          branch: 'feature',
        ),
      );
      await registries.workspaces.upsert(
        workspace(
          id: 'wks_b',
          cwd: worktreeRoot,
          worktreeRoot: worktreeRoot,
          owned: true,
          branch: 'feature',
        ),
      );
      await registries.workspaces.upsert(
        workspace(
          id: 'wks_archived',
          cwd: '${projectDirectory.path}${Platform.pathSeparator}old',
          worktreeRoot: '${projectDirectory.path}${Platform.pathSeparator}old',
          owned: true,
          branch: 'old',
          archivedAt: '2',
        ),
      );

      final response = PaseoWorktreeListResponse.fromJson(
        (await service.handle(
          connection,
          const PaseoWorktreeListRequest(requestId: 'legacy-list').toJson(),
        ))!,
      );

      expect(response.error, isNull);
      expect(response.worktrees, hasLength(1));
      expect(response.worktrees.single.worktreePath, worktreeRoot);
      expect(response.worktrees.single.branchName, 'feature');
    });

    test('worktree scope archives every reference and owned content', () async {
      final worktreeRoot =
          '${projectDirectory.path}${Platform.pathSeparator}feature';
      await Directory(worktreeRoot).create();
      await registries.projects.upsert(project());
      for (final id in const ['wks_a', 'wks_b']) {
        await registries.workspaces.upsert(
          workspace(
            id: id,
            cwd: worktreeRoot,
            worktreeRoot: worktreeRoot,
            owned: true,
            branch: 'feature',
          ),
        );
      }
      final archivedWorkspaceIds = <String>[];
      service = WorkspaceV2Service(
        registries: registries,
        git: git,
        listAgents: () => agents,
        listTerminalContributions: () => terminals,
        archiveOwnedContent: (workspaceId) async {
          archivedWorkspaceIds.add(workspaceId);
          return ['agent-$workspaceId'];
        },
        broadcast: (message, ids) => broadcasts.add((message, ids)),
        workspaceIdFactory: () => 'wks_${nextWorkspaceId++}',
        now: () => now,
      );

      final response = PaseoWorktreeArchiveResponse.fromJson(
        (await service.handle(
          connection,
          PaseoWorktreeArchiveRequest(
            requestId: 'legacy-archive',
            worktreePath: worktreeRoot,
            scope: 'worktree',
          ).toJson(),
        ))!,
      );

      expect(response.success, isTrue);
      expect(
        response.removedAgents,
        unorderedEquals(['agent-wks_a', 'agent-wks_b']),
      );
      expect(archivedWorkspaceIds, containsAll(['wks_a', 'wks_b']));
      expect(
        (await registries.workspaces.list()).where(
          (record) => record.archivedAt == null,
        ),
        isEmpty,
      );
      expect(git.archivedPaths, [worktreeRoot]);
    });

    test('dirty scope fails before archiving content or records', () async {
      final worktreeRoot =
          '${projectDirectory.path}${Platform.pathSeparator}feature';
      await Directory(worktreeRoot).create();
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(
          id: 'wks_dirty',
          cwd: worktreeRoot,
          worktreeRoot: worktreeRoot,
          owned: true,
          branch: 'feature',
        ),
      );
      git.dirtyPaths = ['dirty.txt'];
      final archivedWorkspaceIds = <String>[];
      service = WorkspaceV2Service(
        registries: registries,
        git: git,
        archiveOwnedContent: (workspaceId) async {
          archivedWorkspaceIds.add(workspaceId);
          return const [];
        },
        broadcast: (message, ids) => broadcasts.add((message, ids)),
        now: () => now,
      );

      final response = PaseoWorktreeArchiveResponse.fromJson(
        (await service.handle(
          connection,
          PaseoWorktreeArchiveRequest(
            requestId: 'legacy-dirty',
            worktreePath: worktreeRoot,
            scope: 'worktree',
          ).toJson(),
        ))!,
      );

      expect(response.success, isFalse);
      expect(response.error?['code'], 'DIRTY_WORKTREE');
      expect(archivedWorkspaceIds, isEmpty);
      expect(
        (await registries.workspaces.get('wks_dirty'))?.archivedAt,
        isNull,
      );
    });
  });

  group('fetch and subscriptions', () {
    test(
      'projects rich local Git snapshots into subscribed workspaces',
      () async {
        await _runGit(projectDirectory.path, ['init', '-b', 'main']);
        await _runGit(projectDirectory.path, [
          'config',
          'user.email',
          'test@example.com',
        ]);
        await _runGit(projectDirectory.path, ['config', 'user.name', 'Test']);
        final tracked = File(
          '${projectDirectory.path}${Platform.pathSeparator}tracked.txt',
        )..writeAsStringSync('one\n');
        await _runGit(projectDirectory.path, ['add', '.']);
        await _runGit(projectDirectory.path, ['commit', '-m', 'initial']);
        await _runGit(projectDirectory.path, ['checkout', '-b', 'feature']);
        File(
          '${projectDirectory.path}${Platform.pathSeparator}feature.txt',
        ).writeAsStringSync('feature\n');
        await _runGit(projectDirectory.path, ['add', '.']);
        await _runGit(projectDirectory.path, ['commit', '-m', 'feature']);
        await _runGit(projectDirectory.path, [
          'remote',
          'add',
          'origin',
          'https://github.com/acme/repo.git',
        ]);
        await registries.projects.upsert(
          createPersistedProjectRecord(
            projectId: 'prj_git',
            rootPath: projectDirectory.path,
            kind: PersistedProjectKind.git,
            displayName: 'Git Project',
            createdAt: '1',
            updatedAt: '1',
          ),
        );
        await registries.workspaces.upsert(
          workspace(
            id: 'wks_git',
            projectId: 'prj_git',
            kind: PersistedWorkspaceKind.localCheckout,
            branch: 'feature',
            baseBranch: 'main',
          ),
        );
        final backend = PollingWorkspaceGitBackend(
          pollInterval: const Duration(days: 1),
          forgeStatus: WorkspaceForgeStatusService(
            resolver: ForgeResolver(transport: _WorkspaceForgeTransport()),
          ),
        );
        addTearDown(backend.dispose);
        broadcasts.clear();
        service = WorkspaceV2Service(
          registries: registries,
          git: git,
          gitSnapshots: backend,
          broadcast: (message, ids) => broadcasts.add((message, ids)),
        );

        await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'git',
            hasSubscription: true,
            subscriptionId: 'git-subscription',
          ).toJson(),
        );
        await backend.refreshNow(projectDirectory.path);
        await _waitFor(
          () => broadcasts.any(
            (entry) =>
                entry.$1['type'] == 'workspace_update' &&
                (WorkspaceUpdate.fromJson(entry.$1) as WorkspaceUpsertUpdate)
                        .workspace
                        .gitRuntime
                        ?.isDirty ==
                    false,
          ),
        );

        tracked.writeAsStringSync('two\n');
        await backend.refreshNow(projectDirectory.path);
        await _waitFor(
          () => broadcasts.any(
            (entry) =>
                entry.$1['type'] == 'workspace_update' &&
                (WorkspaceUpdate.fromJson(entry.$1) as WorkspaceUpsertUpdate)
                        .workspace
                        .gitRuntime
                        ?.isDirty ==
                    true,
          ),
        );
        final update =
            WorkspaceUpdate.fromJson(broadcasts.last.$1)
                as WorkspaceUpsertUpdate;
        expect(update.workspace.gitRuntime?.currentBranch, 'feature');
        expect(update.workspace.gitRuntime?.isDirty, isTrue);
        expect(update.workspace.gitRuntime?.aheadBehind?.ahead, 1);
        expect(update.workspace.gitRuntime?.aheadBehind?.behind, 0);
        expect(update.workspace.diffStat?.additions, 1);
        expect(update.workspace.diffStat?.deletions, 1);
        expect(update.workspace.forge, 'github');
        expect(update.workspace.githubRuntime?['featuresEnabled'], isTrue);
        expect(
          (update.workspace.githubRuntime?['pullRequest'] as Map)['number'],
          11,
        );
      },
    );

    test('lists empty projects only on first page', () async {
      await registries.projects.upsert(project());
      final first = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          const FetchWorkspacesRequest(requestId: 'first', limit: 1).toJson(),
        ))!,
      );
      expect(first.emptyProjects.single.projectId, 'prj_empty');

      final afterCursor = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          FetchWorkspacesRequest(
            requestId: 'later',
            limit: 1,
            cursor: base64Url
                .encode(
                  utf8.encode(
                    jsonEncode({
                      'sort': [
                        {'key': 'activity_at', 'direction': 'desc'},
                      ],
                      'values': {'activity_at': null},
                      'id': 'previous',
                    }),
                  ),
                )
                .replaceAll('=', ''),
          ).toJson(),
        ))!,
      );
      expect(afterCursor.emptyProjects, isEmpty);
    });

    test('filters empty projects by project id', () async {
      await registries.projects.upsert(project());

      final matching = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'matching',
            projectId: 'prj_empty',
          ).toJson(),
        ))!,
      );
      final missing = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'missing',
            projectId: 'prj_other',
          ).toJson(),
        ))!,
      );

      expect(matching.emptyProjects.single.projectId, 'prj_empty');
      expect(missing.emptyProjects, isEmpty);
    });

    test('filters, sorts, paginates, and returns cursors', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(id: 'wks_b', name: 'Beta', updatedAt: '2'),
      );
      await registries.workspaces.upsert(
        workspace(id: 'wks_a', name: 'Alpha', updatedAt: '1'),
      );
      final first = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'req',
            query: 'wks_',
            projectId: 'prj_empty',
            sort: [
              WorkspaceSort(
                key: WorkspaceSortKey.name,
                direction: SortDirection.asc,
              ),
            ],
            limit: 1,
          ).toJson(),
        ))!,
      );
      expect(first.entries.single.name, 'Alpha');
      expect(first.pageInfo.hasMore, isTrue);
      expect(first.pageInfo.nextCursor, isNotNull);

      final second = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          FetchWorkspacesRequest(
            requestId: 'req2',
            cursor: first.pageInfo.nextCursor,
            sort: const [
              WorkspaceSort(
                key: WorkspaceSortKey.name,
                direction: SortDirection.asc,
              ),
            ],
            limit: 1,
          ).toJson(),
        ))!,
      );
      expect(second.entries.single.name, 'Beta');
      expect(second.pageInfo.prevCursor, first.pageInfo.nextCursor);
    });

    test(
      'aggregates agent status by workspace identity and priority',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        await registries.workspaces.upsert(workspace(id: 'wks_2'));
        await registries.workspaces.upsert(workspace(id: 'wks_3'));
        agents = [
          agent('idle', 'wks_1', AgentRunState.idle),
          agent('running', 'wks_1', AgentRunState.running),
          agent('failed', 'wks_1', AgentRunState.error),
          agent('permission', 'wks_1', AgentRunState.awaitingPermission),
          agent('sibling', 'wks_2', AgentRunState.running),
          agent('unread', 'wks_3', AgentRunState.idle).copyWith(
            requiresAttention: true,
            attentionReason: AgentAttentionReason.finished,
            attentionTimestamp: '2026-07-26T00:00:00.000Z',
          ),
        ];

        final response = FetchWorkspacesResponse.fromJson(
          (await service.handle(
            connection,
            const FetchWorkspacesRequest(requestId: 'status').toJson(),
          ))!,
        );
        final byId = {for (final entry in response.entries) entry.id: entry};

        expect(byId['wks_1']?.status, WorkspaceStateBucket.needsInput);
        expect(byId['wks_2']?.status, WorkspaceStateBucket.running);
        expect(byId['wks_3']?.status, WorkspaceStateBucket.attention);
        expect(byId['wks_3']?.statusEnteredAt, '2026-07-26T00:00:00.000Z');
      },
    );

    test(
      'statusEnteredAt preserves same bucket and stamps priority unmask',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));

        Future<WorkspaceDescriptor> fetch() async {
          final response = FetchWorkspacesResponse.fromJson(
            (await service.handle(
              connection,
              const FetchWorkspacesRequest(requestId: 'status-time').toJson(),
            ))!,
          );
          return response.entries.single;
        }

        final empty = await fetch();
        expect(empty.status, WorkspaceStateBucket.done);
        expect(empty.statusEnteredAt, '1');

        agents = [
          agent(
            'done',
            'wks_1',
            AgentRunState.idle,
            updatedAt: '2026-07-26T01:00:00.000Z',
          ),
        ];
        // The workspace was already observed in done, so adding another done
        // contributor does not move its bucket entry time.
        expect((await fetch()).statusEnteredAt, '1');

        agents.add(
          agent(
            'permission',
            'wks_1',
            AgentRunState.awaitingPermission,
            updatedAt: '2026-07-26T02:00:00.000Z',
          ),
        );
        now = DateTime.utc(2026, 7, 26, 3);
        final needsInput = await fetch();
        expect(needsInput.status, WorkspaceStateBucket.needsInput);
        expect(needsInput.statusEnteredAt, '2026-07-26T03:00:00.000Z');

        agents.removeWhere((entry) => entry.agentId == 'permission');
        now = DateTime.utc(2026, 7, 26, 4);
        final unmasked = await fetch();
        expect(unmasked.status, WorkspaceStateBucket.done);
        expect(unmasked.statusEnteredAt, '2026-07-26T04:00:00.000Z');

        agents.add(
          agent(
            'later-done',
            'wks_1',
            AgentRunState.idle,
            updatedAt: '2026-07-26T05:00:00.000Z',
          ),
        );
        expect((await fetch()).statusEnteredAt, '2026-07-26T04:00:00.000Z');
      },
    );

    test(
      'first projection uses newest timestamp in the winning bucket',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        agents = [
          agent(
            'running-old',
            'wks_1',
            AgentRunState.running,
            updatedAt: '2026-07-26T01:00:00.000Z',
          ),
          agent(
            'running-new',
            'wks_1',
            AgentRunState.running,
            updatedAt: '2026-07-26T02:00:00.000Z',
          ),
          agent(
            'done-newer',
            'wks_1',
            AgentRunState.idle,
            updatedAt: '2026-07-26T03:00:00.000Z',
          ),
        ];

        final response = FetchWorkspacesResponse.fromJson(
          (await service.handle(
            connection,
            const FetchWorkspacesRequest(requestId: 'newest').toJson(),
          ))!,
        );
        expect(response.entries.single.status, WorkspaceStateBucket.running);
        expect(
          response.entries.single.statusEnteredAt,
          '2026-07-26T02:00:00.000Z',
        );
      },
    );

    test('same-workspace descendants contribute only while running', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace(id: 'wks_1'));
      agents = [
        agent('root', 'wks_1', AgentRunState.idle),
        agent(
          'child',
          'wks_1',
          AgentRunState.awaitingPermission,
          parentAgentId: 'root',
        ),
      ];

      Future<WorkspaceStateBucket> status() async =>
          (FetchWorkspacesResponse.fromJson(
            (await service.handle(
              connection,
              const FetchWorkspacesRequest(requestId: 'child').toJson(),
            ))!,
          )).entries.single.status;

      expect(await status(), WorkspaceStateBucket.done);
      agents[1] = agent(
        'child',
        'wks_1',
        AgentRunState.running,
        parentAgentId: 'root',
      );
      expect(await status(), WorkspaceStateBucket.running);
    });

    test('a cross-workspace child is a root in its own workspace', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace(id: 'wks_1'));
      await registries.workspaces.upsert(workspace(id: 'wks_2'));
      agents = [
        agent('parent', 'wks_1', AgentRunState.idle),
        agent(
          'child',
          'wks_2',
          AgentRunState.awaitingPermission,
          parentAgentId: 'parent',
        ),
      ];

      final response = FetchWorkspacesResponse.fromJson(
        (await service.handle(
          connection,
          const FetchWorkspacesRequest(requestId: 'cross-child').toJson(),
        ))!,
      );
      final byId = {for (final entry in response.entries) entry.id: entry};
      expect(byId['wks_1']?.status, WorkspaceStateBucket.done);
      expect(byId['wks_2']?.status, WorkspaceStateBucket.needsInput);
    });

    test(
      'terminal activity contributes by workspace id and unmask time',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        await registries.workspaces.upsert(workspace(id: 'wks_2'));
        terminals = [
          TerminalWorkspaceContribution(
            cwd: projectDirectory.path,
            workspaceId: 'wks_1',
            activity: const TerminalActivity(
              state: TerminalActivityState.working,
              changedAt: 1785031200000,
            ),
          ),
        ];

        Future<Map<String, WorkspaceDescriptor>> fetch() async {
          final response = FetchWorkspacesResponse.fromJson(
            (await service.handle(
              connection,
              const FetchWorkspacesRequest(requestId: 'terminal').toJson(),
            ))!,
          );
          return {for (final entry in response.entries) entry.id: entry};
        }

        final working = await fetch();
        expect(working['wks_1']?.status, WorkspaceStateBucket.running);
        expect(
          working['wks_1']?.statusEnteredAt,
          DateTime.fromMillisecondsSinceEpoch(
            1785031200000,
            isUtc: true,
          ).toIso8601String(),
        );
        expect(working['wks_2']?.status, WorkspaceStateBucket.done);

        terminals = [];
        now = DateTime.utc(2026, 7, 26, 6);
        final stopped = await fetch();
        expect(stopped['wks_1']?.status, WorkspaceStateBucket.done);
        expect(stopped['wks_1']?.statusEnteredAt, '2026-07-26T06:00:00.000Z');
      },
    );

    test(
      'agent state changes update only the subscribed owning workspace',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        agents = [agent('a1', 'wks_1', AgentRunState.running)];
        await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'subscribe',
            subscriptionId: 'sub',
            hasSubscription: true,
          ).toJson(),
        );
        broadcasts.clear();

        await service.onAgentStateChanged(null);
        await service.onAgentStateChanged('missing');
        await service.onAgentStateChanged('wks_1');

        expect(broadcasts, hasLength(1));
        final payload = broadcasts.single.$1['payload'] as Map<String, Object?>;
        final descriptor = WorkspaceDescriptor.fromJson(
          payload['workspace'] as Map<String, Object?>,
        );
        expect(descriptor.id, 'wks_1');
        expect(descriptor.status, WorkspaceStateBucket.running);
        expect(broadcasts.single.$2, {'connection-1'});
      },
    );

    test(
      'terminal state changes update only the subscribed owning workspace',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        await registries.workspaces.upsert(workspace(id: 'wks_2'));
        terminals = [
          TerminalWorkspaceContribution(
            cwd: '/repo',
            workspaceId: 'wks_2',
            activity: TerminalActivity(
              state: TerminalActivityState.working,
              changedAt: DateTime.utc(2026, 7, 26, 7).millisecondsSinceEpoch,
            ),
          ),
        ];
        await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'subscribe-terminal',
            subscriptionId: 'sub-terminal',
            hasSubscription: true,
          ).toJson(),
        );
        broadcasts.clear();

        await service.onTerminalStateChanged(null);
        await service.onTerminalStateChanged('missing');
        await service.onTerminalStateChanged('wks_2');

        expect(broadcasts, hasLength(1));
        final payload = broadcasts.single.$1['payload'] as Map<String, Object?>;
        final descriptor = WorkspaceDescriptor.fromJson(
          payload['workspace'] as Map<String, Object?>,
        );
        expect(descriptor.id, 'wks_2');
        expect(descriptor.status, WorkspaceStateBucket.running);
        expect(descriptor.statusEnteredAt, '2026-07-26T07:00:00.000Z');
        expect(broadcasts.single.$2, {'connection-1'});
      },
    );

    test(
      'cursor carries sort values and rejects a different current sort',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(
          workspace(id: 'wks_a', name: 'Same', updatedAt: '1'),
        );
        await registries.workspaces.upsert(
          workspace(id: 'wks_b', name: 'Same', updatedAt: '1'),
        );
        final first = FetchWorkspacesResponse.fromJson(
          (await service.handle(
            connection,
            const FetchWorkspacesRequest(
              requestId: 'first',
              sort: [
                WorkspaceSort(
                  key: WorkspaceSortKey.name,
                  direction: SortDirection.asc,
                ),
                WorkspaceSort(
                  key: WorkspaceSortKey.name,
                  direction: SortDirection.desc,
                ),
              ],
              limit: 1,
            ).toJson(),
          ))!,
        );
        expect(first.entries.single.id, 'wks_a');
        final cursorJson =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(first.pageInfo.nextCursor!),
                    ),
                  ),
                )
                as Map<String, Object?>;
        expect(cursorJson['sort'], [
          {'key': 'name', 'direction': 'asc'},
        ]);
        expect(cursorJson['values'], {'name': 'same'});
        expect(cursorJson['id'], 'wks_a');

        await expectLater(
          service.handle(
            connection,
            FetchWorkspacesRequest(
              requestId: 'mismatch',
              cursor: first.pageInfo.nextCursor,
              sort: const [
                WorkspaceSort(
                  key: WorkspaceSortKey.activityAt,
                  direction: SortDirection.desc,
                ),
              ],
            ).toJson(),
          ),
          throwsFormatException,
        );
        await expectLater(
          service.handle(
            connection,
            const FetchWorkspacesRequest(
              requestId: 'invalid',
              cursor: 'not-json',
            ).toJson(),
          ),
          throwsFormatException,
        );
      },
    );

    test('subscribers receive workspace and project updates', () async {
      await service.handle(
        connection,
        const FetchWorkspacesRequest(
          requestId: 'sub',
          hasSubscription: true,
          subscriptionId: 'subscription',
        ).toJson(),
      );
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace());
      await registries.workspaces.archive('wks_1', '3');
      await registries.projects.archive('prj_empty', '4');

      expect(
        broadcasts.map((entry) => entry.$1['type']),
        containsAll(['project.update', 'workspace_update', 'workspace_update']),
      );
      expect(
        broadcasts.every((entry) => entry.$2.contains('connection-1')),
        isTrue,
      );

      final beforeClose = broadcasts.length;
      service.onConnectionClosed('connection-1');
      await registries.projects.remove('prj_empty');
      expect(broadcasts, hasLength(beforeClose));
    });

    test('unknown messages fall through to the v1 adapter', () async {
      expect(
        await service.handle(connection, const {'type': 'agent.list.request'}),
        isNull,
      );
    });
  });

  group('project mutations', () {
    test('project.add registers a project without a workspace', () async {
      final response = ProjectAddResponse.fromJson(
        (await service.handle(
          connection,
          ProjectAddRequest(
            cwd: projectDirectory.path,
            requestId: 'add',
          ).toJson(),
        ))!,
      );
      expect(response.project?.projectId, 'prj_1');
      expect(await registries.projects.list(), hasLength(1));
      expect(await registries.workspaces.list(), isEmpty);

      final missing = ProjectAddResponse.fromJson(
        (await service.handle(
          connection,
          const ProjectAddRequest(
            cwd: '/missing/path',
            requestId: 'missing',
          ).toJson(),
        ))!,
      );
      expect(missing.errorCode, 'directory_not_found');
    });

    test('project.create_directory creates and registers atomically', () async {
      final response = ProjectCreateDirectoryResponse.fromJson(
        (await service.handle(
          connection,
          ProjectCreateDirectoryRequest(
            parentPath: temp.path,
            name: 'new-project',
            requestId: 'create-directory',
          ).toJson(),
        ))!,
      );
      expect(response.error, isNull);
      expect(response.project?.projectId, 'prj_1');
      expect(response.directoryPath, contains('new-project'));
      expect(Directory(response.directoryPath!).existsSync(), isTrue);
      expect(await registries.workspaces.list(), isEmpty);

      final invalid = ProjectCreateDirectoryResponse.fromJson(
        (await service.handle(
          connection,
          ProjectCreateDirectoryRequest(
            parentPath: temp.path,
            name: '..',
            requestId: 'invalid-directory',
          ).toJson(),
        ))!,
      );
      expect(invalid.errorCode, 'invalid_name');
      expect(invalid.project, isNull);
    });

    test(
      'project.rename trims, clears, and refreshes child descriptors',
      () async {
        await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'sub',
            hasSubscription: true,
          ).toJson(),
        );
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace());
        broadcasts.clear();

        final renamed = ProjectRenameResponse.fromJson(
          (await service.handle(
            connection,
            const ProjectRenameRequest(
              projectId: 'prj_empty',
              customName: '  Renamed  ',
              requestId: 'rename',
            ).toJson(),
          ))!,
        );
        expect(renamed.customName, 'Renamed');
        expect(
          (await registries.projects.get('prj_empty'))?.customName,
          'Renamed',
        );
        expect(broadcasts.map((entry) => entry.$1['type']), [
          'project.update',
          'workspace_update',
        ]);
        final updatedWorkspace = WorkspaceUpdate.fromJson(broadcasts.last.$1);
        expect(
          (updatedWorkspace as WorkspaceUpsertUpdate)
              .workspace
              .projectDisplayName,
          'Renamed',
        );

        final cleared = ProjectRenameResponse.fromJson(
          (await service.handle(
            connection,
            const ProjectRenameRequest(
              projectId: 'prj_empty',
              customName: ' ',
              requestId: 'clear',
            ).toJson(),
          ))!,
        );
        expect(cleared.customName, isNull);

        final missing = ProjectRenameResponse.fromJson(
          (await service.handle(
            connection,
            const ProjectRenameRequest(
              projectId: 'missing',
              customName: 'Name',
              requestId: 'missing',
            ).toJson(),
          ))!,
        );
        expect(missing.accepted, isFalse);
        expect(missing.error, 'Project not found');
      },
    );

    test(
      'project.remove archives active children and removes project',
      () async {
        await service.handle(
          connection,
          const FetchWorkspacesRequest(
            requestId: 'sub',
            hasSubscription: true,
          ).toJson(),
        );
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace(id: 'wks_1'));
        await registries.workspaces.upsert(workspace(id: 'wks_2'));
        broadcasts.clear();

        final response = ProjectRemoveResponse.fromJson(
          (await service.handle(
            connection,
            const ProjectRemoveRequest(
              projectId: 'prj_empty',
              requestId: 'remove',
            ).toJson(),
          ))!,
        );
        expect(response.accepted, isTrue);
        expect(response.removedWorkspaceIds, ['wks_1', 'wks_2']);
        expect(await registries.projects.get('prj_empty'), isNull);
        expect(
          (await registries.workspaces.list()).every(
            (entry) => entry.archivedAt != null,
          ),
          isTrue,
        );
        final removals = broadcasts
            .where((entry) => entry.$1['type'] == 'workspace_update')
            .map((entry) => WorkspaceUpdate.fromJson(entry.$1))
            .whereType<WorkspaceRemoveUpdate>();
        expect(
          removals.every((update) => update.removedProjectId == 'prj_empty'),
          isTrue,
        );

        final absent = ProjectRemoveResponse.fromJson(
          (await service.handle(
            connection,
            const ProjectRemoveRequest(
              projectId: 'absent',
              requestId: 'absent',
            ).toJson(),
          ))!,
        );
        expect(absent.accepted, isTrue);
        expect(absent.removedWorkspaceIds, isEmpty);
      },
    );

    test('project.remove reports worktree archive failure', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(worktreeRoot: projectDirectory.path, owned: true),
      );
      git.archiveError = GitDirtyWorktreeException(
        path: projectDirectory.path,
        uncommittedPaths: const ['dirty.txt'],
      );
      final response = ProjectRemoveResponse.fromJson(
        (await service.handle(
          connection,
          const ProjectRemoveRequest(
            projectId: 'prj_empty',
            requestId: 'remove',
          ).toJson(),
        ))!,
      );
      expect(response.accepted, isFalse);
      expect(response.removedWorkspaceIds, isEmpty);
      expect(await registries.projects.get('prj_empty'), isNotNull);
    });
  });

  group('workspace metadata', () {
    test(
      'title trims and clears while missing workspace is rejected',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace());
        final renamed = WorkspaceTitleSetResponse.fromJson(
          (await service.handle(
            connection,
            const WorkspaceTitleSetRequest(
              workspaceId: 'wks_1',
              title: '  Feature  ',
              requestId: 'title',
            ).toJson(),
          ))!,
        );
        expect(renamed.title, 'Feature');
        expect((await registries.workspaces.get('wks_1'))?.title, 'Feature');

        final cleared = WorkspaceTitleSetResponse.fromJson(
          (await service.handle(
            connection,
            const WorkspaceTitleSetRequest(
              workspaceId: 'wks_1',
              title: '',
              requestId: 'clear',
            ).toJson(),
          ))!,
        );
        expect(cleared.title, isNull);

        final missing = WorkspaceTitleSetResponse.fromJson(
          (await service.handle(
            connection,
            const WorkspaceTitleSetRequest(
              workspaceId: 'missing',
              title: 'Name',
              requestId: 'missing',
            ).toJson(),
          ))!,
        );
        expect(missing.accepted, isFalse);
      },
    );

    test('pin stores timestamp and unpin clears it', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace());
      final pinned = WorkspacePinSetResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspacePinSetRequest(
            workspaceId: 'wks_1',
            pinned: true,
            requestId: 'pin',
          ).toJson(),
        ))!,
      );
      expect(pinned.pinnedAt, '2026-07-26T00:00:00.000Z');

      final unpinned = WorkspacePinSetResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspacePinSetRequest(
            workspaceId: 'wks_1',
            pinned: false,
            requestId: 'unpin',
          ).toJson(),
        ))!,
      );
      expect(unpinned.pinnedAt, isNull);

      final missing = WorkspacePinSetResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspacePinSetRequest(
            workspaceId: 'missing',
            pinned: true,
            requestId: 'missing',
          ).toJson(),
        ))!,
      );
      expect(missing.accepted, isFalse);
    });
  });

  group('workspace recovery', () {
    test('reports missing, active, and removed-project states', () async {
      Future<UnavailableWorkspaceState> inspect(String id) async =>
          (WorkspaceRecoveryInspectResponse.fromJson(
                (await service.handle(
                  connection,
                  WorkspaceRecoveryInspectRequest(
                    workspaceId: id,
                    requestId: id,
                  ).toJson(),
                ))!,
              ).state
              as UnavailableWorkspaceState);

      expect((await inspect('missing')).reason, 'workspace_not_found');
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(workspace());
      expect((await inspect('wks_1')).reason, 'workspace_not_archived');
      await registries.workspaces.archive('wks_1', '2');
      await registries.projects.remove('prj_empty');
      expect((await inspect('wks_1')).reason, 'project_not_found');
    });

    test('unarchives when the original directory still exists', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(archivedAt: '2', name: 'Archived'),
      );
      final inspect = WorkspaceRecoveryInspectResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryInspectRequest(
            workspaceId: 'wks_1',
            requestId: 'inspect',
          ).toJson(),
        ))!,
      );
      final state = inspect.state as RecoverableWorkspaceState;
      expect(state.action, 'unarchive');
      expect(state.workspaceName, 'Archived');

      final restored = WorkspaceRecoveryRestoreResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryRestoreRequest(
            workspaceId: 'wks_1',
            requestId: 'restore',
          ).toJson(),
        ))!,
      );
      expect(restored.accepted, isTrue);
      expect((await registries.workspaces.get('wks_1'))?.archivedAt, isNull);
      expect(git.restoredPaths, isEmpty);
    });

    test('classifies missing directory and missing worktree branch', () async {
      await registries.projects.upsert(project());
      final missing = '${temp.path}${Platform.pathSeparator}gone';
      await registries.workspaces.upsert(
        workspace(
          cwd: missing,
          archivedAt: '2',
          kind: PersistedWorkspaceKind.directory,
        ),
      );
      var inspect = WorkspaceRecoveryInspectResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryInspectRequest(
            workspaceId: 'wks_1',
            requestId: 'directory',
          ).toJson(),
        ))!,
      );
      expect(
        (inspect.state as UnavailableWorkspaceState).reason,
        'workspace_directory_missing',
      );

      await registries.workspaces.upsert(
        workspace(
          cwd: missing,
          archivedAt: '2',
          kind: PersistedWorkspaceKind.worktree,
          worktreeRoot: missing,
        ),
      );
      inspect = WorkspaceRecoveryInspectResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryInspectRequest(
            workspaceId: 'wks_1',
            requestId: 'branch',
          ).toJson(),
        ))!,
      );
      expect(
        (inspect.state as UnavailableWorkspaceState).reason,
        'worktree_branch_missing',
      );
    });

    test('classifies missing source repository', () async {
      final missingRoot = '${temp.path}${Platform.pathSeparator}missing-root';
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'prj_empty',
          rootPath: missingRoot,
          kind: PersistedProjectKind.git,
          displayName: 'Missing',
          createdAt: '1',
          updatedAt: '1',
        ),
      );
      final missingWorkspace =
          '${temp.path}${Platform.pathSeparator}missing-worktree';
      await registries.workspaces.upsert(
        workspace(
          cwd: missingWorkspace,
          archivedAt: '2',
          kind: PersistedWorkspaceKind.worktree,
          worktreeRoot: missingWorkspace,
          branch: 'feature',
        ),
      );
      final inspect = WorkspaceRecoveryInspectResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryInspectRequest(
            workspaceId: 'wks_1',
            requestId: 'inspect',
          ).toJson(),
        ))!,
      );
      expect(
        (inspect.state as UnavailableWorkspaceState).reason,
        'project_directory_missing',
      );
    });

    test(
      'recreates a deleted archived worktree and restores the record',
      () async {
        await registries.projects.upsert(
          createPersistedProjectRecord(
            projectId: 'prj_empty',
            rootPath: projectDirectory.path,
            kind: PersistedProjectKind.git,
            displayName: 'Project',
            createdAt: '1',
            updatedAt: '1',
          ),
        );
        final worktreePath =
            '${temp.path}${Platform.pathSeparator}restored-worktree';
        await registries.workspaces.upsert(
          workspace(
            cwd: worktreePath,
            archivedAt: '2',
            kind: PersistedWorkspaceKind.worktree,
            worktreeRoot: worktreePath,
            branch: 'feature',
          ),
        );
        git.createDirectoryOnRestore = true;

        final inspect = WorkspaceRecoveryInspectResponse.fromJson(
          (await service.handle(
            connection,
            const WorkspaceRecoveryInspectRequest(
              workspaceId: 'wks_1',
              requestId: 'inspect',
            ).toJson(),
          ))!,
        );
        expect((inspect.state as RecoverableWorkspaceState).action, 'restore');

        final response = WorkspaceRecoveryRestoreResponse.fromJson(
          (await service.handle(
            connection,
            const WorkspaceRecoveryRestoreRequest(
              workspaceId: 'wks_1',
              requestId: 'restore',
            ).toJson(),
          ))!,
        );
        expect(response.accepted, isTrue);
        expect(git.restoredPaths, [worktreePath]);
        expect((await registries.workspaces.get('wks_1'))?.archivedAt, isNull);
      },
    );

    test('restore failure leaves archived record unchanged', () async {
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'prj_empty',
          rootPath: projectDirectory.path,
          kind: PersistedProjectKind.git,
          displayName: 'Project',
          createdAt: '1',
          updatedAt: '1',
        ),
      );
      final worktreePath =
          '${temp.path}${Platform.pathSeparator}failed-worktree';
      await registries.workspaces.upsert(
        workspace(
          cwd: worktreePath,
          archivedAt: '2',
          kind: PersistedWorkspaceKind.worktree,
          worktreeRoot: worktreePath,
          branch: 'feature',
        ),
      );
      git.restoreError = GitException(
        args: const ['worktree', 'add'],
        exitCode: 1,
        stderr: 'branch unavailable',
      );
      final response = WorkspaceRecoveryRestoreResponse.fromJson(
        (await service.handle(
          connection,
          const WorkspaceRecoveryRestoreRequest(
            workspaceId: 'wks_1',
            requestId: 'restore',
          ).toJson(),
        ))!,
      );
      expect(response.accepted, isFalse);
      expect(response.error, 'branch unavailable');
      expect((await registries.workspaces.get('wks_1'))?.archivedAt, '2');
    });
  });

  group('archive', () {
    test(
      'archives ordinary workspace and returns not found afterward',
      () async {
        await registries.projects.upsert(project());
        await registries.workspaces.upsert(workspace());
        final request = const ArchiveWorkspaceRequest(
          workspaceId: 'wks_1',
          requestId: 'archive',
        );
        final response = ArchiveWorkspaceResponse.fromJson(
          (await service.handle(connection, request.toJson()))!,
        );
        expect(response.archivedAt, '2026-07-26T00:00:00.000Z');

        final again = ArchiveWorkspaceResponse.fromJson(
          (await service.handle(connection, request.toJson()))!,
        );
        expect(again.archivedAt, isNull);
        expect(again.error, 'Workspace not found');
      },
    );

    test('keeps shared worktree until final active reference', () async {
      await registries.projects.upsert(project());
      final first = workspace(
        id: 'wks_1',
        name: 'one',
        worktreeRoot: projectDirectory.path,
        owned: true,
      );
      final second = workspace(
        id: 'wks_2',
        name: 'two',
        worktreeRoot: projectDirectory.path,
        owned: true,
      );
      await registries.workspaces.upsert(first);
      await registries.workspaces.upsert(second);

      await service.handle(
        connection,
        const ArchiveWorkspaceRequest(
          workspaceId: 'wks_1',
          requestId: 'one',
        ).toJson(),
      );
      expect(git.archivedPaths, isEmpty);
      await service.handle(
        connection,
        const ArchiveWorkspaceRequest(
          workspaceId: 'wks_2',
          requestId: 'two',
        ).toJson(),
      );
      expect(git.archivedPaths, [projectDirectory.path]);
    });

    test('dirty final worktree is protected', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(worktreeRoot: projectDirectory.path, owned: true),
      );
      git.archiveError = GitDirtyWorktreeException(
        path: projectDirectory.path,
        uncommittedPaths: const ['dirty.txt'],
      );
      final response = ArchiveWorkspaceResponse.fromJson(
        (await service.handle(
          connection,
          const ArchiveWorkspaceRequest(
            workspaceId: 'wks_1',
            requestId: 'dirty',
          ).toJson(),
        ))!,
      );
      expect(response.error, contains('dirty.txt'));
      expect((await registries.workspaces.get('wks_1'))?.archivedAt, isNull);
    });

    test('git archive errors preserve the record', () async {
      await registries.projects.upsert(project());
      await registries.workspaces.upsert(
        workspace(worktreeRoot: projectDirectory.path, owned: true),
      );
      git.archiveError = GitException(
        args: const ['worktree', 'remove'],
        exitCode: 1,
        stderr: 'cannot remove',
      );
      final response = ArchiveWorkspaceResponse.fromJson(
        (await service.handle(
          connection,
          const ArchiveWorkspaceRequest(
            workspaceId: 'wks_1',
            requestId: 'error',
          ).toJson(),
        ))!,
      );
      expect(response.error, 'cannot remove');
      expect((await registries.workspaces.get('wks_1'))?.archivedAt, isNull);
    });
  });
}

Future<void> _runGit(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for workspace update');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _FakeGitService extends GitService {
  _FakeGitService({required super.dataDir});

  bool isGit = false;
  String root = '';
  String branch = 'main';
  String? createdBranch;
  String? createdBaseRef;
  String? createdWorktreeSlug;
  String? createdFetchRef;
  bool createdRequireExistingBranch = false;
  bool createdBranchOff = false;
  String defaultBranch = 'main';
  String? lookedUpWorktreeSlug;
  WorktreeInfo? existingWorktree;
  String? originForge;
  Object? createError;
  Object? archiveError;
  Object? restoreError;
  bool createDirectoryOnRestore = false;
  final List<String> archivedPaths = [];
  final List<bool> archiveForces = [];
  final List<String> restoredPaths = [];
  List<String> dirtyPaths = const [];

  @override
  Future<bool> isGitRepo(String path) async => isGit;

  @override
  Future<String> repositoryRoot(String path) async => root;

  @override
  Future<String> currentBranch(String projectPath) async => branch;

  @override
  Future<bool> localBranchExists(String projectPath, String name) async =>
      false;

  @override
  Future<String> renameCurrentBranch(String projectPath, String name) async {
    branch = name;
    return branch;
  }

  @override
  Future<String> resolveDefaultBranch(String projectPath) async =>
      defaultBranch;

  @override
  Future<WorktreeInfo?> findWorktreeBySlug(
    String projectPath,
    String worktreeSlug,
  ) async {
    lookedUpWorktreeSlug = worktreeSlug;
    return existingWorktree;
  }

  @override
  Future<WorktreeInfo> createWorktree(
    String projectPath,
    String branch, {
    String? baseRef,
    String? worktreeSlug,
    bool requireExistingBranch = false,
    String? fetchRef,
    bool branchOff = false,
  }) async {
    if (createError case final error?) throw error;
    createdBranch = branch;
    createdBaseRef = baseRef;
    createdWorktreeSlug = worktreeSlug;
    createdFetchRef = fetchRef;
    createdRequireExistingBranch = requireExistingBranch;
    createdBranchOff = branchOff;
    final path =
        '$projectPath${Platform.pathSeparator}${worktreeSlug ?? branch}';
    Directory('$path${Platform.pathSeparator}.git').createSync(recursive: true);
    writeWorktreeBaseMetadata(path, baseRefName: baseRef ?? defaultBranch);
    return WorktreeInfo(path: path, branch: branch, projectPath: projectPath);
  }

  @override
  Future<String?> resolveOriginForge(String projectPath) async => originForge;

  @override
  Future<List<String>> uncommittedPaths(String path) async => dirtyPaths;

  @override
  Future<void> archiveWorktree(String path, {bool force = false}) async {
    if (archiveError case final error?) throw error;
    archivedPaths.add(path);
    archiveForces.add(force);
  }

  @override
  Future<void> restoreWorktree({
    required String projectPath,
    required String worktreePath,
    required String branch,
  }) async {
    if (restoreError case final error?) throw error;
    restoredPaths.add(worktreePath);
    if (createDirectoryOnRestore) {
      await Directory(worktreePath).create(recursive: true);
    }
  }
}

final class _FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  final _incoming = StreamController<Object?>.broadcast();
  late final WebSocketSink _sink = _FakeSink();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;
}

final class _FakeSink extends DelegatingStreamSink implements WebSocketSink {
  _FakeSink() : super(_DiscardSink());

  @override
  Future close([int? closeCode, String? closeReason]) => super.close();
}

final class _DiscardSink implements StreamSink<Object?> {
  @override
  void add(Object? event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();
}

final class _WorkspaceForgeTransport implements ForgeCommandTransport {
  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (args.first == 'auth') {
      return const ForgeCommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    return ForgeCommandResult(
      exitCode: 0,
      stdout: jsonEncode([
        {
          'number': 11,
          'url': 'https://github.com/acme/repo/pull/11',
          'title': 'Feature',
          'state': 'OPEN',
          'isDraft': false,
          'baseRefName': 'main',
          'headRefName': 'feature',
          'headRefOid': 'unused',
          'mergedAt': null,
          'reviewDecision': 'APPROVED',
          'mergeable': 'MERGEABLE',
          'headRepositoryOwner': {'login': 'acme'},
          'statusCheckRollup': [],
        },
      ]),
      stderr: '',
    );
  }
}
