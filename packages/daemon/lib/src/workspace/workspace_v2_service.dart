/// Native Paseo v2 workspace session handlers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/create_agent_title.dart';
import '../git/git_runner.dart';
import '../git/git_service.dart';
import '../server/connection.dart';
import '../terminal/terminal_manager.dart';
import '../utils/path_identity.dart';
import 'polling_workspace_git_backend.dart';
import 'workspace_git_observer_service.dart';
import 'workspace_registry.dart';
import 'workspace_setup_service.dart';
import 'worktree_terminal_bootstrap_service.dart';

typedef WorkspaceV2Broadcast =
    void Function(Map<String, Object?> message, Set<String> connectionIds);

final class ImportWorkspaceResult<T> {
  const ImportWorkspaceResult({
    required this.value,
    required this.createdWorkspace,
  });

  final T value;
  final PersistedWorkspaceRecord? createdWorkspace;
}

final class AutomationWorkspaceArchiveResult {
  const AutomationWorkspaceArchiveResult({
    required this.workspaceId,
    required this.removedDirectory,
  });

  final String workspaceId;
  final bool removedDirectory;
}

final class WorkspaceV2Service {
  WorkspaceV2Service({
    required this.registries,
    required this.git,
    required WorkspaceV2Broadcast broadcast,
    Iterable<AgentSummary> Function()? listAgents,
    Iterable<TerminalWorkspaceContribution> Function()?
    listTerminalContributions,
    this.gitSnapshots,
    this.workspaceSetup,
    this.terminalBootstrap,
    bool Function(String agentId, TimelineItem item)? appendAgentTimeline,
    String Function()? workspaceIdFactory,
    DateTime Function()? now,
  }) : _broadcast = broadcast,
       _listAgents = listAgents ?? _noAgents,
       _listTerminalContributions =
           listTerminalContributions ?? _noTerminalContributions,
       _appendAgentTimeline = appendAgentTimeline ?? _ignoreAgentTimeline,
       _workspaceIdFactory = workspaceIdFactory ?? generateWorkspaceId,
       _now = now ?? DateTime.now {
    registries.workspaces.subscribeToMutations(_onWorkspaceMutation);
    registries.projects.subscribeToMutations(_onProjectMutation);
  }

  final WorkspaceRegistries registries;
  final GitService git;
  final PollingWorkspaceGitBackend? gitSnapshots;
  final WorkspaceSetupService? workspaceSetup;
  final WorktreeTerminalBootstrapService? terminalBootstrap;
  final WorkspaceV2Broadcast _broadcast;
  final Iterable<AgentSummary> Function() _listAgents;
  final Iterable<TerminalWorkspaceContribution> Function()
  _listTerminalContributions;
  final bool Function(String agentId, TimelineItem item) _appendAgentTimeline;
  final String Function() _workspaceIdFactory;
  final DateTime Function() _now;
  final Set<String> _workspaceSubscribers = {};
  final Map<String, _WorkspaceBucketHistoryEntry> _bucketHistory = {};
  final Map<String, WorkspaceGitSubscription> _gitSubscriptions = {};
  final Map<String, _PendingAgentBootstrap> _pendingAgentBootstraps = {};

  Future<Map<String, Object?>?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    return switch (message['type']) {
      'fetch_workspaces_request' => _fetch(
        connection,
        FetchWorkspacesRequest.fromJson(message),
      ),
      'workspace.create.request' => _create(
        WorkspaceCreateRequest.fromJson(message),
      ),
      OpenProjectRequest.type => openProject(
        OpenProjectRequest.fromJson(message),
      ),
      'archive_workspace_request' => _archive(
        ArchiveWorkspaceRequest.fromJson(message),
      ),
      'project.add.request' => _projectAdd(ProjectAddRequest.fromJson(message)),
      'project.rename.request' => _projectRename(
        ProjectRenameRequest.fromJson(message),
      ),
      'project.remove.request' => _projectRemove(
        ProjectRemoveRequest.fromJson(message),
      ),
      'workspace.title.set.request' => _workspaceTitleSet(
        WorkspaceTitleSetRequest.fromJson(message),
      ),
      'workspace.pin.set.request' => _workspacePinSet(
        WorkspacePinSetRequest.fromJson(message),
      ),
      'workspace.recovery.inspect.request' => _recoveryInspect(
        WorkspaceRecoveryInspectRequest.fromJson(message),
      ),
      'workspace.recovery.restore.request' => _recoveryRestore(
        WorkspaceRecoveryRestoreRequest.fromJson(message),
      ),
      _ => null,
    };
  }

  /// Creates a workspace for the daemon MCP automation surface.
  ///
  /// This deliberately shares the native v2 creation path so project
  /// ownership, worktree metadata, setup, and registry broadcasts cannot drift
  /// between the UI and unattended agents.
  Future<PersistedWorkspaceRecord> createAutomationWorkspace(
    WorkspaceCreateSource source, {
    String? title,
  }) async {
    final (workspace, project) = await switch (source) {
      DirectoryWorkspaceCreateSource directory => _createDirectory(
        directory,
        title,
      ),
      WorktreeWorkspaceCreateSource worktree => _createWorktree(
        worktree,
        title,
      ),
    };
    _ensureGitSnapshot(workspace);
    final setup = workspaceSetup;
    if (source is WorktreeWorkspaceCreateSource && setup != null) {
      unawaited(_runWorkspaceSetup(setup, workspace, project));
    }
    return workspace;
  }

  Future<List<PersistedWorkspaceRecord>>
  listActiveAutomationWorkspaces() async => [
    for (final workspace in await registries.workspaces.list())
      if (workspace.archivedAt == null) workspace,
  ];

  Future<PersistedWorkspaceRecord> requireActiveAutomationWorkspace(
    String workspaceId,
  ) async {
    final workspace = await registries.workspaces.get(workspaceId);
    if (workspace == null || workspace.archivedAt != null) {
      throw StateError('Workspace not found: $workspaceId');
    }
    return workspace;
  }

  Future<PersistedWorkspaceRecord> renameAutomationWorkspace(
    String workspaceId,
    String title,
  ) async {
    final workspace = await requireActiveAutomationWorkspace(workspaceId);
    final updated = workspace.copyWith(title: title, updatedAt: _timestamp());
    await registries.workspaces.upsert(updated);
    return updated;
  }

  /// Archives only the requested workspace record. Its owned agents and
  /// terminals are torn down by the MCP boundary before this call.
  Future<AutomationWorkspaceArchiveResult> archiveAutomationWorkspace(
    String workspaceId,
  ) async {
    final workspace = await requireActiveAutomationWorkspace(workspaceId);
    final ownedPath = workspace.isPaseoOwnedWorktree
        ? workspace.worktreeRoot
        : null;
    final existed = ownedPath != null && Directory(ownedPath).existsSync();
    await _archiveWorkspace(workspace, archivedAt: _timestamp());
    return AutomationWorkspaceArchiveResult(
      workspaceId: workspaceId,
      removedDirectory: existed && !Directory(ownedPath).existsSync(),
    );
  }

  /// Runs a provider-session import in the exact workspace placement used by
  /// Paseo 0.2.0. Targeted imports reuse only an active, cwd-equivalent
  /// workspace. Untargeted imports always get a fresh directory workspace and
  /// creation is rolled back if the provider import fails.
  Future<ImportWorkspaceResult<T>> runInImportWorkspace<T>({
    required String cwd,
    String? requestedWorkspaceId,
    required Future<T> Function(PersistedWorkspaceRecord workspace) operation,
  }) async {
    if (requestedWorkspaceId != null) {
      final workspace = await registries.workspaces.get(requestedWorkspaceId);
      if (workspace == null || workspace.archivedAt != null) {
        throw StateError('Workspace not found: $requestedWorkspaceId');
      }
      final project = await registries.projects.get(workspace.projectId);
      if (project == null || project.archivedAt != null) {
        throw StateError('Project not found: ${workspace.projectId}');
      }
      if (!realpathAwarePathMatcher(workspace.cwd)(cwd)) {
        throw StateError(
          'Import cwd does not match workspace: ${workspace.workspaceId}',
        );
      }
      return ImportWorkspaceResult(
        value: await operation(workspace),
        createdWorkspace: null,
      );
    }

    final projectsBeforeImport = {
      for (final project in await registries.projects.list())
        project.projectId: project,
    };
    final (workspace, _) = await _createDirectory(
      DirectoryWorkspaceCreateSource(path: cwd),
      null,
    );
    final previousProject = projectsBeforeImport[workspace.projectId];
    try {
      return ImportWorkspaceResult(
        value: await operation(workspace),
        createdWorkspace: workspace,
      );
    } catch (_) {
      await _rollbackFailedImportWorkspace(workspace, previousProject);
      rethrow;
    }
  }

  Future<void> _rollbackFailedImportWorkspace(
    PersistedWorkspaceRecord workspace,
    PersistedProjectRecord? previousProject,
  ) async {
    await registries.workspaces.remove(workspace.workspaceId);
    final projectHasActiveWorkspace = (await registries.workspaces.list()).any(
      (candidate) =>
          candidate.projectId == workspace.projectId &&
          candidate.archivedAt == null,
    );
    if (projectHasActiveWorkspace) return;
    if (previousProject?.archivedAt != null) {
      await registries.projects.upsert(previousProject!);
    } else if (previousProject == null) {
      await registries.projects.remove(workspace.projectId);
    }
  }

  Future<Map<String, Object?>> openProject(OpenProjectRequest request) async {
    final cwd = p.normalize(p.absolute(_expandTilde(request.cwd)));
    if (!Directory(cwd).existsSync()) {
      return OpenProjectResponse(
        requestId: request.requestId,
        workspace: null,
        error: 'Directory not found: $cwd',
        errorCode: 'directory_not_found',
      ).toJson();
    }
    try {
      PersistedWorkspaceRecord? workspace;
      for (final candidate in await registries.workspaces.list()) {
        if (candidate.archivedAt == null && p.equals(candidate.cwd, cwd)) {
          workspace = candidate;
          break;
        }
      }
      PersistedProjectRecord project;
      if (workspace == null) {
        final created = await _createDirectory(
          DirectoryWorkspaceCreateSource(path: cwd),
          null,
        );
        workspace = created.$1;
        project = created.$2;
      } else {
        final existingProject = await registries.projects.get(
          workspace.projectId,
        );
        if (existingProject == null || existingProject.archivedAt != null) {
          final created = await _createDirectory(
            DirectoryWorkspaceCreateSource(path: cwd),
            null,
          );
          workspace = created.$1;
          project = created.$2;
        } else {
          project = existingProject;
        }
      }
      _ensureGitSnapshot(workspace);
      return OpenProjectResponse(
        requestId: request.requestId,
        workspace: _descriptor(
          workspace,
          project,
          _listAgents(),
          _listTerminalContributions(),
        ),
        error: null,
      ).toJson();
    } catch (error) {
      return OpenProjectResponse(
        requestId: request.requestId,
        workspace: null,
        error: _errorMessage(error, 'Failed to open project'),
      ).toJson();
    }
  }

  void onConnectionClosed(String connectionId) {
    _workspaceSubscribers.remove(connectionId);
  }

  /// Creates the per-run workspace used by Paseo-compatible unattended
  /// schedules. Even local runs get a durable workspace record so the run can
  /// be inspected and recovered consistently.
  Future<PersistedWorkspaceRecord> createScheduleRunWorkspace({
    required String cwd,
    required String isolation,
    required String prompt,
    required String runId,
  }) async {
    final title = _promptTitle(prompt);
    final (workspace, _) = switch (isolation) {
      'local' => await _createDirectory(
        DirectoryWorkspaceCreateSource(path: cwd),
        title,
      ),
      'worktree' => await _createWorktree(
        WorktreeWorkspaceCreateSource(
          cwd: cwd,
          action: WorktreeCreateAction.branchOff,
          branchName: 'schedule-${runId.replaceAll('-', '').substring(0, 12)}',
        ),
        title,
      ),
      _ => throw ArgumentError.value(isolation, 'isolation'),
    };
    _ensureGitSnapshot(workspace);
    return workspace;
  }

  /// Schedule-owned workspaces are disposable execution sandboxes. Worktree
  /// cleanup is forced because an interrupted agent may have left edits.
  Future<void> archiveScheduleRunWorkspace(String workspaceId) async {
    final workspace = await registries.workspaces.get(workspaceId);
    if (workspace == null || workspace.archivedAt != null) return;
    await _archiveWorkspace(
      workspace,
      archivedAt: _timestamp(),
      forceWorktree: true,
    );
  }

  Future<Map<String, Object?>> _fetch(
    Connection connection,
    FetchWorkspacesRequest request,
  ) async {
    if (request.hasSubscription) {
      _workspaceSubscribers.add(connection.id);
    }
    final projects = {
      for (final project in await registries.projects.list())
        if (project.archivedAt == null) project.projectId: project,
    };
    final agents = _listAgents().toList(growable: false);
    final terminals = _listTerminalContributions().toList(growable: false);
    final workspaceRecords = await registries.workspaces.list();
    for (final workspace in workspaceRecords) {
      if (workspace.archivedAt == null) _ensureGitSnapshot(workspace);
    }
    var entries = <WorkspaceDescriptor>[
      for (final workspace in workspaceRecords)
        if (workspace.archivedAt == null &&
            projects.containsKey(workspace.projectId))
          _descriptor(
            workspace,
            projects[workspace.projectId]!,
            agents,
            terminals,
          ),
    ];
    final query = request.query?.trim().toLowerCase();
    final projectId = request.projectId?.trim();
    entries = entries.where((workspace) {
      if (projectId != null &&
          projectId.isNotEmpty &&
          workspace.projectId != projectId) {
        return false;
      }
      if (query != null && query.isNotEmpty) {
        return [
          workspace.name,
          workspace.projectId,
          workspace.id,
        ].any((value) => value.toLowerCase().contains(query));
      }
      return true;
    }).toList();
    final sort = _normalizeSort(request.sort);
    _sort(entries, sort);

    if (request.cursor != null) {
      final cursor = _decodeCursor(request.cursor!, sort);
      entries = entries
          .where((entry) => _compareWithCursor(entry, cursor, sort) > 0)
          .toList();
    }
    final limit = request.limit ?? 200;
    final hasMore = entries.length > limit;
    final pageEntries = entries.take(limit).toList();
    final nextCursor = hasMore && pageEntries.isNotEmpty
        ? _encodeCursor(pageEntries.last, sort)
        : null;
    final activeProjectIds = {
      for (final workspace in workspaceRecords)
        if (workspace.archivedAt == null) workspace.projectId,
    };
    final emptyProjects = request.cursor == null
        ? [
            for (final project in projects.values)
              if (!activeProjectIds.contains(project.projectId) &&
                  (projectId == null ||
                      projectId.isEmpty ||
                      project.projectId == projectId))
                _projectDescriptor(project),
          ]
        : const <WorkspaceProjectDescriptor>[];

    return FetchWorkspacesResponse(
      requestId: request.requestId,
      subscriptionId: request.hasSubscription ? request.subscriptionId : null,
      entries: pageEntries,
      emptyProjects: emptyProjects,
      pageInfo: WorkspacePageInfo(
        nextCursor: nextCursor,
        prevCursor: request.cursor,
        hasMore: hasMore,
      ),
    ).toJson();
  }

  Future<Map<String, Object?>> _create(WorkspaceCreateRequest request) async {
    try {
      final title = resolveCreateAgentTitles(
        configTitle: request.title,
        initialPrompt: request.firstAgentContext?['prompt'] is String
            ? request.firstAgentContext!['prompt']! as String
            : null,
      ).provisionalTitle;
      final created = switch (request.source) {
        DirectoryWorkspaceCreateSource source => _createDirectory(
          source,
          title,
        ),
        WorktreeWorkspaceCreateSource source => _createWorktree(source, title),
      };
      final (workspace, project) = await created;
      _ensureGitSnapshot(workspace);
      final setup = workspaceSetup;
      if (request.source is WorktreeWorkspaceCreateSource && setup != null) {
        if (request.firstAgentContext == null) {
          unawaited(_runWorkspaceSetup(setup, workspace, project));
        } else {
          _pendingAgentBootstraps[workspace.workspaceId] =
              _PendingAgentBootstrap(
                setup: setup,
                workspace: workspace,
                project: project,
              );
        }
      }
      return WorkspaceCreateResponse(
        requestId: request.requestId,
        workspace: _descriptor(
          workspace,
          project,
          _listAgents(),
          _listTerminalContributions(),
        ),
        setupTerminalId: null,
        error: null,
      ).toJson();
    } on _WorkspaceRequestException catch (error) {
      return WorkspaceCreateResponse(
        requestId: request.requestId,
        workspace: null,
        setupTerminalId: null,
        error: error.message,
        errorCode: error.code,
      ).toJson();
    } on GitException catch (error) {
      return WorkspaceCreateResponse(
        requestId: request.requestId,
        workspace: null,
        setupTerminalId: null,
        error: error.message,
        errorCode: 'git_error',
      ).toJson();
    }
  }

  /// Starts Paseo's agent-continuation bootstrap only after the agent exists,
  /// so setup and configured terminal lifecycle cards belong to that agent.
  bool startAgentContinuation(
    AgentSummary agent, {
    Future<void> Function()? onReady,
  }) {
    final workspaceId = agent.workspaceId;
    if (workspaceId == null) return false;
    final pending = _pendingAgentBootstraps.remove(workspaceId);
    if (pending == null) return false;
    unawaited(() async {
      final ready = await _runAgentContinuation(agent.agentId, pending);
      if (ready) await onReady?.call();
    }());
    return true;
  }

  /// Removes and cleans up a worktree whose coupled first-agent creation
  /// failed before the continuation could start.
  Future<bool> cancelAgentContinuation(String? workspaceId) async {
    if (workspaceId == null) return false;
    final pending = _pendingAgentBootstraps.remove(workspaceId);
    if (pending == null) return false;
    await _archiveWorkspace(
      pending.workspace,
      archivedAt: _timestamp(),
      forceWorktree: true,
    );
    return true;
  }

  Future<bool> _runAgentContinuation(
    String agentId,
    _PendingAgentBootstrap pending,
  ) async {
    final workspace = pending.workspace;
    final setupCallId =
        'worktree_setup_${DateTime.now().microsecondsSinceEpoch}';
    _appendAgentTimeline(
      agentId,
      ToolCallItem(
        id: setupCallId,
        toolName: 'paseo_worktree_setup',
        status: ToolCallStatus.running,
        detail: WorktreeSetupToolDetail(
          worktreePath: workspace.cwd,
          branchName: workspace.branch ?? workspace.displayName,
          log: '',
          commands: const [],
        ),
      ),
    );
    final setupResult = await _runWorkspaceSetup(
      pending.setup,
      workspace,
      pending.project,
    );
    final setupSnapshot = pending.setup.snapshotFor(workspace.workspaceId);
    final setupSucceeded = setupResult.status == WorkspaceSetupStatus.completed;
    final setupStored = _appendAgentTimeline(
      agentId,
      ToolCallItem(
        id: setupCallId,
        toolName: 'paseo_worktree_setup',
        status: setupSucceeded ? ToolCallStatus.success : ToolCallStatus.error,
        detail: WorktreeSetupToolDetail(
          worktreePath: workspace.cwd,
          branchName: workspace.branch ?? workspace.displayName,
          log: setupSnapshot?.detail.log ?? '',
          commands: setupSnapshot?.detail.commands ?? const [],
          truncated: setupSnapshot?.detail.truncated ?? false,
        ),
        errorMessage: setupSnapshot?.error,
      ),
    );
    if (!setupSucceeded || !setupStored) return false;

    final bootstrap = terminalBootstrap;
    if (bootstrap == null) return true;
    List<WorktreeTerminalSpec> specs;
    try {
      specs = await bootstrap.loadSpecs(workspace.cwd);
    } catch (error) {
      _appendTerminalBootstrapFailure(agentId, workspace, '$error');
      return false;
    }
    if (specs.isEmpty) return true;
    final terminalCallId =
        'worktree_terminals_${DateTime.now().microsecondsSinceEpoch}';
    final input = {
      'worktreePath': workspace.cwd,
      'branchName': workspace.branch ?? workspace.displayName,
    };
    final started = _appendAgentTimeline(
      agentId,
      ToolCallItem(
        id: terminalCallId,
        toolName: 'paseo_worktree_terminals',
        status: ToolCallStatus.running,
        detail: GenericDetail(input: input),
      ),
    );
    if (!started) return false;
    final results = await bootstrap.runSpecs(
      specs,
      workspacePath: workspace.cwd,
      workspaceId: workspace.workspaceId,
    );
    _appendAgentTimeline(
      agentId,
      ToolCallItem(
        id: terminalCallId,
        toolName: 'paseo_worktree_terminals',
        status: ToolCallStatus.success,
        detail: GenericDetail(
          input: input,
          output: {
            'worktreePath': workspace.cwd,
            'terminals': results.map((result) => result.toJson()).toList(),
          },
        ),
      ),
    );
    return true;
  }

  void _appendTerminalBootstrapFailure(
    String agentId,
    PersistedWorkspaceRecord workspace,
    String error,
  ) {
    _appendAgentTimeline(
      agentId,
      ToolCallItem(
        id: 'worktree_terminals_${DateTime.now().microsecondsSinceEpoch}',
        toolName: 'paseo_worktree_terminals',
        status: ToolCallStatus.error,
        detail: GenericDetail(
          input: {
            'worktreePath': workspace.cwd,
            'branchName': workspace.branch ?? workspace.displayName,
          },
          errorMessage: error,
        ),
        errorMessage: error,
      ),
    );
  }

  Future<WorkspaceSetupRunResult> _runWorkspaceSetup(
    WorkspaceSetupService setup,
    PersistedWorkspaceRecord workspace,
    PersistedProjectRecord project,
  ) async {
    final result = await setup.run(
      workspaceId: workspace.workspaceId,
      workspacePath: workspace.cwd,
      branchName: workspace.branch ?? workspace.displayName,
      sourceCheckoutPath: workspace.mainRepoRoot ?? project.rootPath,
      shouldBootstrap: true,
    );
    if (result.status == WorkspaceSetupStatus.failed && !result.setupStarted) {
      await registries.workspaces.archive(workspace.workspaceId, _timestamp());
      return result;
    }
    await registries.workspaces.update(
      workspace.workspaceId,
      (current) => current.copyWith(updatedAt: _timestamp()),
    );
    return result;
  }

  Future<(PersistedWorkspaceRecord, PersistedProjectRecord)> _createDirectory(
    DirectoryWorkspaceCreateSource source,
    String? title,
  ) async {
    final cwd = p.normalize(p.absolute(source.path));
    if (!Directory(cwd).existsSync()) {
      throw _WorkspaceRequestException(
        'directory does not exist: ${source.path}',
        'directory_not_found',
      );
    }
    final now = _timestamp();
    final isGit = await git.isGitRepo(cwd);
    final project = await _resolveProject(
      projectId: source.projectId,
      cwd: cwd,
      isGit: isGit,
      timestamp: now,
    );
    final branch = isGit ? await git.currentBranch(cwd) : null;
    final workspace = createPersistedWorkspaceRecord(
      workspaceId: await _uniqueWorkspaceId(),
      projectId: project.projectId,
      cwd: cwd,
      kind: isGit
          ? PersistedWorkspaceKind.localCheckout
          : PersistedWorkspaceKind.directory,
      displayName: branch ?? p.basename(cwd),
      title: title,
      branch: branch,
      createdAt: now,
      updatedAt: now,
    );
    await registries.workspaces.upsert(workspace);
    return (workspace, project);
  }

  Future<(PersistedWorkspaceRecord, PersistedProjectRecord)> _createWorktree(
    WorktreeWorkspaceCreateSource source,
    String? title,
  ) async {
    final now = _timestamp();
    final existingProject = source.projectId == null
        ? null
        : await registries.projects.get(source.projectId!);
    final cwd = source.cwd ?? existingProject?.rootPath;
    if (cwd == null || !Directory(cwd).existsSync()) {
      throw const _WorkspaceRequestException(
        'project directory does not exist',
        'directory_not_found',
      );
    }
    if (!await git.isGitRepo(cwd)) {
      throw const _WorkspaceRequestException(
        'worktree source must be a git repository',
        'not_git_repository',
      );
    }
    final project = await _resolveProject(
      projectId: source.projectId,
      cwd: cwd,
      isGit: true,
      timestamp: now,
    );
    final changeRequest = _changeRequestSource(source);
    final checkoutBranch =
        source.action == WorktreeCreateAction.checkout && changeRequest == null;
    String branch;
    String? fetchRef;
    if (changeRequest != null) {
      final requestedForge = changeRequest.$1;
      final detectedForge = await git.resolveOriginForge(project.rootPath);
      if (requestedForge != null &&
          detectedForge != null &&
          requestedForge != detectedForge) {
        throw _WorkspaceRequestException(
          'Checkout source is for $requestedForge, but this workspace '
              'resolved to $detectedForge',
          'checkout_forge_mismatch',
        );
      }
      final forge = requestedForge ?? detectedForge ?? 'github';
      if (!const {
        'github',
        'gitlab',
        'gitea',
        'forgejo',
        'codeberg',
      }.contains(forge)) {
        throw _WorkspaceRequestException(
          'Checkout from change request is not supported for $forge yet',
          'unsupported_forge_checkout',
        );
      }
      final number = changeRequest.$2;
      branch =
          source.branchName ??
          source.worktreeSlug ??
          '${forge == 'gitlab' ? 'mr' : 'pr'}-$number';
      fetchRef = forge == 'gitlab'
          ? 'refs/merge-requests/$number/head'
          : 'refs/pull/$number/head';
    } else {
      final selected = source.branchName ?? source.refName;
      if (selected == null || selected.isEmpty) {
        throw const _WorkspaceRequestException(
          'branchName or refName is required',
          'branch_required',
        );
      }
      branch = selected;
    }
    final created = await git.createWorktree(
      project.rootPath,
      branch,
      baseRef: source.action == WorktreeCreateAction.branchOff
          ? source.refName ?? source.baseBranch
          : null,
      worktreeSlug: source.worktreeSlug,
      requireExistingBranch: checkoutBranch,
      fetchRef: fetchRef,
    );
    final workspace = createPersistedWorkspaceRecord(
      workspaceId: await _uniqueWorkspaceId(),
      projectId: project.projectId,
      cwd: created.path,
      kind: PersistedWorkspaceKind.worktree,
      displayName: created.branch.isEmpty ? branch : created.branch,
      title: title,
      branch: created.branch.isEmpty ? branch : created.branch,
      worktreeRoot: created.path,
      baseBranch: source.baseBranch ?? source.refName,
      isPaseoOwnedWorktree: true,
      mainRepoRoot: project.rootPath,
      createdAt: now,
      updatedAt: now,
    );
    await registries.workspaces.upsert(workspace);
    return (workspace, project);
  }

  (String?, int)? _changeRequestSource(WorktreeWorkspaceCreateSource source) {
    final raw = source.checkoutSource;
    if (raw != null) {
      final kind = raw['kind'];
      if (kind != 'change_request' && kind != 'github_pr') {
        throw const _WorkspaceRequestException(
          'checkoutSource.kind must be change_request',
          'invalid_checkout_source',
        );
      }
      final number = raw['number'];
      if (number is! num ||
          number != number.roundToDouble() ||
          number.toInt() <= 0) {
        throw const _WorkspaceRequestException(
          'checkoutSource.number must be a positive integer',
          'invalid_checkout_source',
        );
      }
      final forge = raw['forge'];
      if (forge != null && (forge is! String || forge.trim().isEmpty)) {
        throw const _WorkspaceRequestException(
          'checkoutSource.forge must be a non-empty string',
          'invalid_checkout_source',
        );
      }
      return (forge == null ? null : (forge as String).trim(), number.toInt());
    }
    final legacy = source.githubPrNumber;
    return legacy == null ? null : ('github', legacy);
  }

  Future<PersistedProjectRecord> _resolveProject({
    required String? projectId,
    required String cwd,
    required bool isGit,
    required String timestamp,
  }) async {
    if (projectId != null) {
      final project = await registries.projects.get(projectId);
      if (project == null || project.archivedAt != null) {
        throw _WorkspaceRequestException(
          'project not found: $projectId',
          'project_not_found',
        );
      }
      return project;
    }
    var rootPath = cwd;
    if (isGit) {
      rootPath = await git.repositoryRoot(cwd);
    }
    return registries.projects.getOrCreateActiveByRoot(
      rootPath: rootPath,
      kind: isGit ? PersistedProjectKind.git : PersistedProjectKind.nonGit,
      displayName: p.basename(rootPath),
      timestamp: timestamp,
    );
  }

  Future<Map<String, Object?>> _archive(ArchiveWorkspaceRequest request) async {
    final workspace = await registries.workspaces.get(request.workspaceId);
    if (workspace == null || workspace.archivedAt != null) {
      return ArchiveWorkspaceResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        archivedAt: null,
        error: 'Workspace not found',
      ).toJson();
    }
    final archivedAt = _timestamp();
    try {
      await _archiveWorkspace(workspace, archivedAt: archivedAt);
    } on GitDirtyWorktreeException catch (error) {
      return ArchiveWorkspaceResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        archivedAt: null,
        error: error.message,
      ).toJson();
    } on GitException catch (error) {
      return ArchiveWorkspaceResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        archivedAt: null,
        error: error.message,
      ).toJson();
    }
    return ArchiveWorkspaceResponse(
      requestId: request.requestId,
      workspaceId: request.workspaceId,
      archivedAt: archivedAt,
      error: null,
    ).toJson();
  }

  Future<Map<String, Object?>> _projectAdd(ProjectAddRequest request) async {
    final cwd = p.normalize(p.absolute(_expandTilde(request.cwd)));
    if (!Directory(cwd).existsSync()) {
      return ProjectAddResponse(
        requestId: request.requestId,
        project: null,
        error: 'Directory not found: $cwd',
        errorCode: 'directory_not_found',
      ).toJson();
    }
    try {
      final isGit = await git.isGitRepo(cwd);
      final project = await _resolveProject(
        projectId: null,
        cwd: cwd,
        isGit: isGit,
        timestamp: _timestamp(),
      );
      return ProjectAddResponse(
        requestId: request.requestId,
        project: _projectDescriptor(project),
        error: null,
      ).toJson();
    } catch (error) {
      return ProjectAddResponse(
        requestId: request.requestId,
        project: null,
        error: _errorMessage(error, 'Failed to add project'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _projectRename(
    ProjectRenameRequest request,
  ) async {
    final project = await registries.projects.get(request.projectId);
    if (project == null) {
      return ProjectRenameResponse(
        requestId: request.requestId,
        projectId: request.projectId,
        accepted: false,
        customName: null,
        error: 'Project not found',
      ).toJson();
    }
    final trimmed = request.customName?.trim() ?? '';
    final customName = trimmed.isEmpty ? null : trimmed;
    try {
      await registries.projects.upsert(
        project.copyWith(customName: customName, updatedAt: _timestamp()),
      );
      return ProjectRenameResponse(
        requestId: request.requestId,
        projectId: request.projectId,
        accepted: true,
        customName: customName,
        error: null,
      ).toJson();
    } catch (error) {
      return ProjectRenameResponse(
        requestId: request.requestId,
        projectId: request.projectId,
        accepted: false,
        customName: null,
        error: _errorMessage(error, 'Failed to rename project'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _projectRemove(
    ProjectRemoveRequest request,
  ) async {
    final removedWorkspaceIds = <String>[];
    try {
      final workspaces = [
        for (final workspace in await registries.workspaces.list())
          if (workspace.projectId == request.projectId &&
              workspace.archivedAt == null)
            workspace,
      ];
      for (final workspace in workspaces) {
        await _archiveWorkspace(
          workspace,
          archivedAt: _timestamp(),
          removedProjectId: request.projectId,
        );
        removedWorkspaceIds.add(workspace.workspaceId);
      }
      await registries.projects.remove(request.projectId);
      return ProjectRemoveResponse(
        requestId: request.requestId,
        projectId: request.projectId,
        accepted: true,
        removedWorkspaceIds: removedWorkspaceIds,
        error: null,
      ).toJson();
    } catch (error) {
      return ProjectRemoveResponse(
        requestId: request.requestId,
        projectId: request.projectId,
        accepted: false,
        removedWorkspaceIds: const [],
        error: _errorMessage(error, 'Failed to remove project'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _workspaceTitleSet(
    WorkspaceTitleSetRequest request,
  ) async {
    final trimmed = request.title?.trim() ?? '';
    final title = trimmed.isEmpty ? null : trimmed;
    try {
      final updated = await registries.workspaces.update(
        request.workspaceId,
        (workspace) =>
            workspace.copyWith(title: title, updatedAt: _timestamp()),
      );
      return WorkspaceTitleSetResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: updated != null,
        title: updated == null ? null : title,
        error: updated == null ? 'Workspace not found' : null,
      ).toJson();
    } catch (error) {
      return WorkspaceTitleSetResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: false,
        title: null,
        error: _errorMessage(error, 'Failed to set workspace title'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _workspacePinSet(
    WorkspacePinSetRequest request,
  ) async {
    final pinnedAt = request.pinned ? _timestamp() : null;
    try {
      final updated = await registries.workspaces.update(
        request.workspaceId,
        (workspace) =>
            workspace.copyWith(pinnedAt: pinnedAt, updatedAt: _timestamp()),
      );
      return WorkspacePinSetResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: updated != null,
        pinnedAt: updated == null ? null : pinnedAt,
        error: updated == null ? 'Workspace not found' : null,
      ).toJson();
    } catch (error) {
      return WorkspacePinSetResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: false,
        pinnedAt: null,
        error: _errorMessage(error, 'Failed to pin workspace'),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _recoveryInspect(
    WorkspaceRecoveryInspectRequest request,
  ) async => WorkspaceRecoveryInspectResponse(
    requestId: request.requestId,
    state: await _inspectRecovery(request.workspaceId),
  ).toJson();

  Future<Map<String, Object?>> _recoveryRestore(
    WorkspaceRecoveryRestoreRequest request,
  ) async {
    try {
      final state = await _inspectRecovery(request.workspaceId);
      if (state case UnavailableWorkspaceState(:final message)) {
        throw _WorkspaceRequestException(message, state.reason);
      }
      final recoverable = state as RecoverableWorkspaceState;
      final workspace = (await registries.workspaces.get(request.workspaceId))!;
      if (recoverable.action == 'restore') {
        final project = (await registries.projects.get(workspace.projectId))!;
        final sourceRoot = workspace.mainRepoRoot ?? project.rootPath;
        final worktreeRoot = workspace.worktreeRoot ?? workspace.cwd;
        await git.restoreWorktree(
          projectPath: sourceRoot,
          worktreePath: worktreeRoot,
          branch: workspace.branch!,
        );
        if (!Directory(workspace.cwd).existsSync()) {
          try {
            await git.archiveWorktree(worktreeRoot, force: true);
          } catch (_) {
            // Preserve the selected-directory recovery failure.
          }
          throw const _WorkspaceRequestException(
            'Selected project directory is missing from the restored worktree.',
            'workspace_directory_missing',
          );
        }
      }
      await registries.workspaces.restore(request.workspaceId, _timestamp());
      return WorkspaceRecoveryRestoreResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: true,
        error: null,
      ).toJson();
    } catch (error) {
      return WorkspaceRecoveryRestoreResponse(
        requestId: request.requestId,
        workspaceId: request.workspaceId,
        accepted: false,
        error: _errorMessage(error, 'Failed to recover workspace'),
      ).toJson();
    }
  }

  Future<WorkspaceRecoveryState> _inspectRecovery(String workspaceId) async {
    final workspace = await registries.workspaces.get(workspaceId);
    if (workspace == null) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'workspace_not_found',
        message: 'This workspace is no longer known to the host.',
      );
    }
    if (workspace.archivedAt == null) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'workspace_not_archived',
        message:
            'This workspace is not archived, but it is unavailable from the host.',
      );
    }
    final project = await registries.projects.get(workspace.projectId);
    if (project == null) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'project_not_found',
        message: 'The project for this archived workspace no longer exists.',
      );
    }
    if (Directory(workspace.cwd).existsSync()) {
      return RecoverableWorkspaceState(
        workspaceId: workspaceId,
        workspaceName: resolveWorkspaceDisplayName(workspace),
        action: 'unarchive',
        branch: workspace.branch,
      );
    }
    if (workspace.kind != PersistedWorkspaceKind.worktree) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'workspace_directory_missing',
        message:
            'The archived workspace directory no longer exists and cannot be recreated.',
      );
    }
    if (workspace.branch == null || workspace.branch!.isEmpty) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'worktree_branch_missing',
        message:
            'The archived worktree has no branch recorded, so it cannot be restored.',
      );
    }
    final sourceRoot = workspace.mainRepoRoot ?? project.rootPath;
    if (!Directory(sourceRoot).existsSync()) {
      return UnavailableWorkspaceState(
        workspaceId: workspaceId,
        reason: 'project_directory_missing',
        message:
            'The source repository needed to restore this worktree no longer exists.',
      );
    }
    return RecoverableWorkspaceState(
      workspaceId: workspaceId,
      workspaceName: resolveWorkspaceDisplayName(workspace),
      action: 'restore',
      branch: workspace.branch,
    );
  }

  Future<void> _archiveWorkspace(
    PersistedWorkspaceRecord workspace, {
    required String archivedAt,
    String? removedProjectId,
    bool forceWorktree = false,
  }) async {
    final normalizedCwd = p.normalize(p.absolute(workspace.cwd));
    final hasActiveSibling = (await registries.workspaces.list()).any(
      (candidate) =>
          candidate.workspaceId != workspace.workspaceId &&
          candidate.archivedAt == null &&
          p.equals(p.normalize(p.absolute(candidate.cwd)), normalizedCwd),
    );
    final stoppedSnapshot = !hasActiveSibling
        ? await _stopGitSnapshot(workspace.cwd)
        : false;
    try {
      if (workspace.isPaseoOwnedWorktree &&
          workspace.worktreeRoot != null &&
          await registries.workspaces.activeWorktreeReferenceCount(
                workspace.worktreeRoot!,
              ) ==
              1) {
        await git.archiveWorktree(
          workspace.worktreeRoot!,
          force: forceWorktree,
        );
      }
      await registries.workspaces.archive(
        workspace.workspaceId,
        archivedAt,
        removedProjectId: removedProjectId,
      );
    } catch (_) {
      if (stoppedSnapshot) _ensureGitSnapshot(workspace);
      rethrow;
    }
  }

  String _promptTitle(String prompt) {
    final compact = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (compact.isEmpty) return 'Scheduled agent';
    return compact.length <= 60 ? compact : '${compact.substring(0, 57)}...';
  }

  WorkspaceDescriptor _descriptor(
    PersistedWorkspaceRecord workspace,
    PersistedProjectRecord project,
    Iterable<AgentSummary> agents,
    Iterable<TerminalWorkspaceContribution> terminals,
  ) {
    final status = _workspaceStatus(
      workspaceId: workspace.workspaceId,
      workspaceCreatedAt: workspace.createdAt,
      agents: agents,
      terminals: terminals,
      previous: _bucketHistory[workspace.workspaceId],
      nowIso: _timestamp(),
    );
    _bucketHistory[workspace.workspaceId] = _WorkspaceBucketHistoryEntry(
      bucket: status.bucket,
      enteredAt: status.enteredAt,
    );
    final snapshot = gitSnapshots?.peekSnapshot(workspace.cwd);
    final forgeSnapshot = gitSnapshots?.peekForgeSnapshot(workspace.cwd);
    return WorkspaceDescriptor(
      id: workspace.workspaceId,
      projectId: workspace.projectId,
      projectDisplayName: resolveProjectDisplayName(project),
      projectCustomName: project.customName,
      projectRootPath: project.rootPath,
      workspaceDirectory: workspace.cwd,
      projectKind: project.kind == PersistedProjectKind.git
          ? WorkspaceProjectKind.git
          : WorkspaceProjectKind.nonGit,
      workspaceKind: switch (workspace.kind) {
        PersistedWorkspaceKind.localCheckout => WorkspaceKind.localCheckout,
        PersistedWorkspaceKind.worktree => WorkspaceKind.worktree,
        PersistedWorkspaceKind.directory => WorkspaceKind.directory,
      },
      name: resolveWorkspaceDisplayName(workspace),
      title: workspace.title,
      pinnedAt: workspace.pinnedAt,
      status: status.bucket,
      statusEnteredAt: status.enteredAt,
      activityAt: workspace.updatedAt,
      diffStat: snapshot?.diffStat,
      scripts: const [],
      gitRuntime: workspace.kind == PersistedWorkspaceKind.directory
          ? null
          : snapshot?.toWire(
                  isPaseoOwnedWorktree: workspace.isPaseoOwnedWorktree,
                ) ??
                WorkspaceGitRuntime(
                  currentBranch: workspace.branch,
                  isPaseoOwnedWorktree: workspace.isPaseoOwnedWorktree,
                ),
      githubRuntime: forgeSnapshot?.toGithubRuntimeJson(),
      forge: forgeSnapshot?.forge,
    );
  }

  void _ensureGitSnapshot(PersistedWorkspaceRecord workspace) {
    final backend = gitSnapshots;
    if (backend == null ||
        workspace.kind == PersistedWorkspaceKind.directory ||
        workspace.archivedAt != null) {
      return;
    }
    final cwd = p.normalize(p.absolute(workspace.cwd));
    if (!_gitSubscriptions.containsKey(cwd)) {
      _gitSubscriptions[cwd] = backend.registerWorkspace(cwd, (_) {
        unawaited(_emitGitSnapshotUpdate(cwd));
      });
    }
    backend.setBaseRef(cwd, workspace.baseBranch);
  }

  Future<bool> _stopGitSnapshot(String cwd) async {
    final normalized = p.normalize(p.absolute(cwd));
    final subscription = _gitSubscriptions.remove(normalized);
    if (subscription == null) return false;
    final unsubscribeAndWait = subscription.unsubscribeAndWait;
    if (unsubscribeAndWait == null) {
      subscription.unsubscribe();
    } else {
      await unsubscribeAndWait();
    }
    return true;
  }

  Future<void> _emitGitSnapshotUpdate(String cwd) async {
    if (_workspaceSubscribers.isEmpty) return;
    final projects = {
      for (final project in await registries.projects.list())
        if (project.archivedAt == null) project.projectId: project,
    };
    final agents = _listAgents().toList(growable: false);
    final terminals = _listTerminalContributions().toList(growable: false);
    for (final workspace in await registries.workspaces.list()) {
      final project = projects[workspace.projectId];
      if (workspace.archivedAt != null ||
          project == null ||
          !p.equals(p.normalize(p.absolute(workspace.cwd)), cwd)) {
        continue;
      }
      _broadcast(
        WorkspaceUpsertUpdate(
          _descriptor(workspace, project, agents, terminals),
        ).toJson(),
        Set.unmodifiable(_workspaceSubscribers),
      );
    }
  }

  WorkspaceProjectDescriptor _projectDescriptor(
    PersistedProjectRecord project,
  ) => WorkspaceProjectDescriptor(
    projectId: project.projectId,
    projectDisplayName: resolveProjectDisplayName(project),
    projectCustomName: project.customName,
    projectRootPath: project.rootPath,
    projectKind: project.kind == PersistedProjectKind.git
        ? WorkspaceProjectKind.git
        : WorkspaceProjectKind.nonGit,
  );

  void _sort(List<WorkspaceDescriptor> entries, List<WorkspaceSort> sort) {
    entries.sort((left, right) => _compareWorkspace(left, right, sort));
  }

  Future<void> _onWorkspaceMutation(WorkspaceMutation mutation) async {
    if (mutation.workspace != null) {
      _ensureGitSnapshot(mutation.workspace!);
    }
    if (_workspaceSubscribers.isEmpty) return;
    if (mutation.kind == RegistryMutationKind.upsert &&
        mutation.workspace != null) {
      final project = await registries.projects.get(
        mutation.workspace!.projectId,
      );
      if (project == null || project.archivedAt != null) return;
      _broadcast(
        WorkspaceUpsertUpdate(
          _descriptor(
            mutation.workspace!,
            project,
            _listAgents(),
            _listTerminalContributions(),
          ),
        ).toJson(),
        Set.unmodifiable(_workspaceSubscribers),
      );
      return;
    }
    if (mutation.kind != RegistryMutationKind.upsert) {
      final project = mutation.workspace == null
          ? null
          : await registries.projects.get(mutation.workspace!.projectId);
      final activeForProject = project == null
          ? const <PersistedWorkspaceRecord>[]
          : [
              for (final workspace in await registries.workspaces.list())
                if (workspace.projectId == project.projectId &&
                    workspace.archivedAt == null)
                  workspace,
            ];
      _broadcast(
        WorkspaceRemoveUpdate(
          id: mutation.workspaceId,
          emptyProject:
              project != null &&
                  project.archivedAt == null &&
                  activeForProject.isEmpty
              ? _projectDescriptor(project)
              : null,
          removedProjectId: mutation.removedProjectId,
        ).toJson(),
        Set.unmodifiable(_workspaceSubscribers),
      );
    }
  }

  Future<void> _onProjectMutation(ProjectMutation mutation) async {
    if (_workspaceSubscribers.isEmpty) return;
    final update =
        mutation.kind == RegistryMutationKind.upsert && mutation.project != null
        ? ProjectUpsertUpdate(_projectDescriptor(mutation.project!))
        : ProjectRemoveUpdate(mutation.projectId);
    _broadcast(update.toJson(), Set.unmodifiable(_workspaceSubscribers));
    if (mutation.kind == RegistryMutationKind.upsert &&
        mutation.project != null) {
      for (final workspace in await registries.workspaces.list()) {
        if (workspace.projectId == mutation.projectId &&
            workspace.archivedAt == null) {
          _broadcast(
            WorkspaceUpsertUpdate(
              _descriptor(
                workspace,
                mutation.project!,
                _listAgents(),
                _listTerminalContributions(),
              ),
            ).toJson(),
            Set.unmodifiable(_workspaceSubscribers),
          );
        }
      }
    }
  }

  /// Re-project an agent lifecycle change to the owning workspace. Paseo
  /// ownership is per workspace id, so same-directory sibling workspaces are
  /// deliberately unaffected.
  Future<void> onAgentStateChanged(String? workspaceId) async {
    if (workspaceId == null || _workspaceSubscribers.isEmpty) return;
    final workspace = await registries.workspaces.get(workspaceId);
    if (workspace == null || workspace.archivedAt != null) return;
    final project = await registries.projects.get(workspace.projectId);
    if (project == null || project.archivedAt != null) return;
    _broadcast(
      WorkspaceUpsertUpdate(
        _descriptor(
          workspace,
          project,
          _listAgents(),
          _listTerminalContributions(),
        ),
      ).toJson(),
      Set.unmodifiable(_workspaceSubscribers),
    );
  }

  Future<void> onTerminalStateChanged(String? workspaceId) =>
      onAgentStateChanged(workspaceId);

  Future<String> _uniqueWorkspaceId() async {
    while (true) {
      final id = _workspaceIdFactory();
      if (await registries.workspaces.get(id) == null) return id;
    }
  }

  String _timestamp() => _now().toUtc().toIso8601String();
}

Iterable<AgentSummary> _noAgents() => const <AgentSummary>[];

bool _ignoreAgentTimeline(String _, TimelineItem __) => false;

Iterable<TerminalWorkspaceContribution> _noTerminalContributions() =>
    const <TerminalWorkspaceContribution>[];

final class _PendingAgentBootstrap {
  const _PendingAgentBootstrap({
    required this.setup,
    required this.workspace,
    required this.project,
  });

  final WorkspaceSetupService setup;
  final PersistedWorkspaceRecord workspace;
  final PersistedProjectRecord project;
}

_WorkspaceStatusProjection _workspaceStatus({
  required String workspaceId,
  required String workspaceCreatedAt,
  required Iterable<AgentSummary> agents,
  required Iterable<TerminalWorkspaceContribution> terminals,
  required _WorkspaceBucketHistoryEntry? previous,
  required String nowIso,
}) {
  var winning = WorkspaceStateBucket.done;
  final activeAgents = [
    for (final agent in agents)
      if (agent.archivedAt == null && agent.workspaceId == workspaceId) agent,
  ];
  final agentsById = {
    for (final agent in agents)
      if (agent.archivedAt == null) agent.agentId: agent,
  };
  for (final agent in activeAgents) {
    final root = _resolveWorkspaceRootAgent(agent, agentsById);
    final isRoot = root.agentId == agent.agentId;
    if (!isRoot && agent.runState != AgentRunState.running) continue;
    final candidate = isRoot
        ? deriveAgentStateBucket(
            status: agent.runState,
            requiresAttention: agent.requiresAttention,
            attentionReason: agent.attentionReason,
          )
        : WorkspaceStateBucket.running;
    if (_statusPriority(candidate) < _statusPriority(winning)) {
      winning = candidate;
    }
  }

  final terminalEntries = <_TerminalBucketEntry>[];
  for (final terminal in terminals) {
    if (terminal.workspaceId != workspaceId || terminal.activity == null) {
      continue;
    }
    final bucket = _terminalBucket(terminal.activity!);
    if (bucket == null) continue;
    terminalEntries.add(
      _TerminalBucketEntry(
        bucket: bucket,
        changedAt: DateTime.fromMillisecondsSinceEpoch(
          terminal.activity!.changedAt.toInt(),
          isUtc: true,
        ).toIso8601String(),
      ),
    );
    if (_statusPriority(bucket) < _statusPriority(winning)) {
      winning = bucket;
    }
  }

  final hasContributors = activeAgents.isNotEmpty || terminalEntries.isNotEmpty;
  if (!hasContributors) {
    final enteredAt = previous == null
        ? workspaceCreatedAt
        : previous.bucket == WorkspaceStateBucket.done
        ? previous.enteredAt
        : nowIso;
    return _WorkspaceStatusProjection(
      bucket: WorkspaceStateBucket.done,
      enteredAt: enteredAt,
    );
  }
  if (previous == null) {
    return _WorkspaceStatusProjection(
      bucket: winning,
      enteredAt:
          _newestTimestampInBucket(
            agents: activeAgents,
            terminals: terminalEntries,
            bucket: winning,
          ) ??
          nowIso,
    );
  }
  if (previous.bucket != winning) {
    return _WorkspaceStatusProjection(bucket: winning, enteredAt: nowIso);
  }
  return _WorkspaceStatusProjection(
    bucket: winning,
    enteredAt: previous.enteredAt,
  );
}

int _statusPriority(WorkspaceStateBucket status) =>
    getWorkspaceStateBucketPriority(status);

final class _WorkspaceStatusProjection {
  const _WorkspaceStatusProjection({
    required this.bucket,
    required this.enteredAt,
  });

  final WorkspaceStateBucket bucket;
  final String enteredAt;
}

final class _WorkspaceBucketHistoryEntry {
  const _WorkspaceBucketHistoryEntry({
    required this.bucket,
    required this.enteredAt,
  });

  final WorkspaceStateBucket bucket;
  final String enteredAt;
}

final class _TerminalBucketEntry {
  const _TerminalBucketEntry({required this.bucket, required this.changedAt});

  final WorkspaceStateBucket bucket;
  final String changedAt;
}

AgentSummary _resolveWorkspaceRootAgent(
  AgentSummary agent,
  Map<String, AgentSummary> agentsById,
) {
  var current = agent;
  final seen = <String>{agent.agentId};
  while (current.parentAgentId != null) {
    final parent = agentsById[current.parentAgentId];
    if (parent == null ||
        parent.workspaceId != agent.workspaceId ||
        !seen.add(parent.agentId)) {
      break;
    }
    current = parent;
  }
  return current;
}

WorkspaceStateBucket? _terminalBucket(TerminalActivity activity) {
  return switch (deriveTerminalActivityStatusBucket(activity)) {
    TerminalActivityStatusBucket.needsInput => WorkspaceStateBucket.needsInput,
    TerminalActivityStatusBucket.running => WorkspaceStateBucket.running,
    TerminalActivityStatusBucket.attention => WorkspaceStateBucket.attention,
    null => null,
  };
}

String? _newestTimestampInBucket({
  required Iterable<AgentSummary> agents,
  required Iterable<_TerminalBucketEntry> terminals,
  required WorkspaceStateBucket bucket,
}) {
  final candidates = <String>[];
  for (final agent in agents) {
    final derived = deriveAgentStateBucket(
      status: agent.runState,
      requiresAttention: agent.requiresAttention,
      attentionReason: agent.attentionReason,
    );
    if (derived != bucket) continue;
    final timestamp =
        agent.attentionTimestamp ??
        agent.updatedAt ??
        DateTime.fromMillisecondsSinceEpoch(
          agent.createdAtMs,
          isUtc: true,
        ).toIso8601String();
    if (timestamp.isNotEmpty) candidates.add(timestamp);
  }
  for (final terminal in terminals) {
    if (terminal.bucket == bucket) candidates.add(terminal.changedAt);
  }
  candidates.sort();
  return candidates.isEmpty ? null : candidates.last;
}

List<WorkspaceSort> _normalizeSort(List<WorkspaceSort> requested) {
  if (requested.isEmpty) {
    return const [
      WorkspaceSort(
        key: WorkspaceSortKey.activityAt,
        direction: SortDirection.desc,
      ),
    ];
  }
  final seen = <WorkspaceSortKey>{};
  return [
    for (final entry in requested)
      if (seen.add(entry.key)) entry,
  ];
}

int _compareWorkspace(
  WorkspaceDescriptor left,
  WorkspaceDescriptor right,
  List<WorkspaceSort> sort,
) {
  for (final field in sort) {
    final comparison = _compareSortValues(
      _sortValue(left, field.key),
      _sortValue(right, field.key),
    );
    if (comparison != 0) {
      return field.direction == SortDirection.asc ? comparison : -comparison;
    }
  }
  return left.id.compareTo(right.id);
}

int _compareWithCursor(
  WorkspaceDescriptor workspace,
  _WorkspaceCursor cursor,
  List<WorkspaceSort> sort,
) {
  for (final field in sort) {
    final comparison = _compareSortValues(
      _sortValue(workspace, field.key),
      cursor.values[_wireSortKey(field.key)],
    );
    if (comparison != 0) {
      return field.direction == SortDirection.asc ? comparison : -comparison;
    }
  }
  return workspace.id.compareTo(cursor.id);
}

Object? _sortValue(WorkspaceDescriptor workspace, WorkspaceSortKey key) =>
    switch (key) {
      WorkspaceSortKey.statusPriority => _statusPriority(workspace.status),
      WorkspaceSortKey.activityAt => _dateMilliseconds(workspace.activityAt),
      WorkspaceSortKey.name => workspace.name.toLowerCase(),
      WorkspaceSortKey.projectId => workspace.projectId.toLowerCase(),
    };

int _compareSortValues(Object? left, Object? right) {
  if (left == right) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (left is num && right is num) {
    return left < right ? -1 : 1;
  }
  return left.toString().compareTo(right.toString());
}

int? _dateMilliseconds(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.millisecondsSinceEpoch;
}

String _encodeCursor(WorkspaceDescriptor workspace, List<WorkspaceSort> sort) {
  final values = <String, Object?>{
    for (final field in sort)
      _wireSortKey(field.key): _sortValue(workspace, field.key),
  };
  final bytes = utf8.encode(
    jsonEncode({
      'sort': sort.map((entry) => entry.toJson()).toList(),
      'values': values,
      'id': workspace.id,
    }),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}

_WorkspaceCursor _decodeCursor(
  String cursor,
  List<WorkspaceSort> expectedSort,
) {
  const invalid = FormatException('Invalid fetch_workspaces cursor');
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
    );
    if (decoded is! Map) throw invalid;
    final payload = decoded.cast<String, Object?>();
    final rawSort = payload['sort'];
    final rawValues = payload['values'];
    final id = payload['id'];
    if (rawSort is! List || rawValues is! Map || id is! String) {
      throw invalid;
    }
    final cursorSort = rawSort.map((entry) {
      if (entry is! Map) throw invalid;
      return WorkspaceSort.fromJson(entry.cast<String, Object?>());
    }).toList();
    if (cursorSort.length != expectedSort.length) {
      throw const FormatException(
        'fetch_workspaces cursor does not match current sort',
      );
    }
    for (var index = 0; index < cursorSort.length; index++) {
      if (cursorSort[index].key != expectedSort[index].key ||
          cursorSort[index].direction != expectedSort[index].direction) {
        throw const FormatException(
          'fetch_workspaces cursor does not match current sort',
        );
      }
    }
    return _WorkspaceCursor(
      values: Map.unmodifiable(rawValues.cast<String, Object?>()),
      id: id,
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw invalid;
  }
}

String _wireSortKey(WorkspaceSortKey key) => switch (key) {
  WorkspaceSortKey.statusPriority => 'status_priority',
  WorkspaceSortKey.activityAt => 'activity_at',
  WorkspaceSortKey.name => 'name',
  WorkspaceSortKey.projectId => 'project_id',
};

final class _WorkspaceCursor {
  const _WorkspaceCursor({required this.values, required this.id});

  final Map<String, Object?> values;
  final String id;
}

String _expandTilde(String value) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) return value;
  if (value == '~') return home;
  return p.join(home, value.substring(2));
}

String _errorMessage(Object error, String fallback) {
  if (error is _WorkspaceRequestException) return error.message;
  if (error is GitException) return error.message;
  final message = error.toString();
  return message.isEmpty ? fallback : message;
}

final class _WorkspaceRequestException implements Exception {
  const _WorkspaceRequestException(this.message, this.code);

  final String message;
  final String code;
}
