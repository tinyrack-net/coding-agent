import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'agents_provider.dart';
import 'daemon_providers.dart';

/// Registered projects, fetched on (re)connect. [add] registers a new path
/// with the daemon and appends it to the list.
class ProjectsNotifier extends AsyncNotifier<List<ProjectInfo>> {
  final Map<String, ProjectInfo> _optimisticProjects = {};

  @override
  Future<List<ProjectInfo>> build() async {
    final client = ref.watch(daemonClientProvider);
    final connection = ref.watch(connectionStateProvider).value;
    if (connection != DaemonConnectionState.connected) {
      return _optimisticProjects.values.toList(growable: false);
    }
    final res = await client.request(MessageTypes.projectListRequest, const {});
    final fetched = ((res['projects'] as List?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(ProjectInfo.fromJson)
        .toList();
    for (final project in fetched) {
      _optimisticProjects.remove(project.path);
    }
    return [
      ...fetched.where(
        (project) => !_optimisticProjects.containsKey(project.path),
      ),
      ..._optimisticProjects.values,
    ];
  }

  Future<ProjectInfo> add(String path) async {
    final client = ref.read(daemonClientProvider);
    final response = await client.addProject(cwd: path.trim());
    final descriptor = response.project;
    if (response.error != null || descriptor == null) {
      throw StateError(response.error ?? 'Unable to add project');
    }
    final project = ProjectInfo(
      path: descriptor.projectRootPath,
      name: descriptor.projectDisplayName,
      isGitRepo: descriptor.projectKind == WorkspaceProjectKind.git,
    );
    upsert(project);
    return project;
  }

  void upsert(ProjectInfo project) {
    _optimisticProjects[project.path] = project;
    final current = state.value ?? const <ProjectInfo>[];
    state = AsyncData([
      ...current.where((candidate) => candidate.path != project.path),
      project,
    ]);
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, List<ProjectInfo>>(
      ProjectsNotifier.new,
    );

/// Worktrees of one project (family arg: the project's path).
class WorktreesNotifier extends AsyncNotifier<List<WorktreeInfo>> {
  WorktreesNotifier(this.projectPath);

  final String projectPath;

  @override
  Future<List<WorktreeInfo>> build() async {
    final client = ref.watch(daemonClientProvider);
    final connection = ref.watch(connectionStateProvider).value;
    if (connection != DaemonConnectionState.connected) return const [];
    final res = await client.request(MessageTypes.worktreeListRequest, {
      'projectPath': projectPath,
    });
    return ((res['worktrees'] as List?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(WorktreeInfo.fromJson)
        .toList();
  }

  Future<WorktreeInfo> create(String branch, {String? baseRef}) async {
    final client = ref.read(daemonClientProvider);
    final res = await client.request(MessageTypes.worktreeCreateRequest, {
      'projectPath': projectPath,
      'branch': branch,
      'baseRef': ?baseRef,
    });
    final worktree = WorktreeInfo.fromJson(
      res['worktree'] as Map<String, Object?>? ?? const {},
    );
    final current = state.value ?? const <WorktreeInfo>[];
    state = AsyncData([
      ...current.where((w) => w.path != worktree.path),
      worktree,
    ]);
    return worktree;
  }

  /// Archives the worktree at [path]. Throws [DaemonRpcException] with
  /// `error.code == RpcErrorCodes.conflict` if it has uncommitted changes
  /// and [force] is false; callers should confirm with the user and retry
  /// with `force: true` to discard those changes.
  Future<void> archive(String path, {bool force = false}) async {
    final client = ref.read(daemonClientProvider);
    await client.request(MessageTypes.worktreeArchiveRequest, {
      'path': path,
      if (force) 'force': force,
    });
    final current = state.value ?? const <WorktreeInfo>[];
    state = AsyncData(current.where((w) => w.path != path).toList());
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

final worktreesProvider =
    AsyncNotifierProvider.family<WorktreesNotifier, List<WorktreeInfo>, String>(
      WorktreesNotifier.new,
    );

/// The project/branch metadata for creating a new agent at [worktreePath],
/// resolved by searching every registered git project's worktree list for a
/// match. `isWorktree` is only true for an isolated (non-main) worktree — a
/// draft session opened in a project's main checkout behaves like "Local"
/// isolation. Null fields (the common case: a non-git "local isolation"
/// project, or a worktree path not yet reconciled) mean no owning
/// project/branch to pass through.
class WorktreeAgentContext {
  const WorktreeAgentContext({
    this.projectPath,
    this.branch,
    this.isWorktree = false,
    this.workspaceId,
  });

  final String? projectPath;
  final String? branch;
  final bool isWorktree;
  final String? workspaceId;
}

final worktreeAgentContextProvider =
    Provider.family<WorktreeAgentContext, String>((ref, worktreePath) {
      final agents = ref.watch(agentsProvider).values;
      String? workspaceId;
      for (final agent in agents) {
        if (resolveWorktreeKey(agent) == worktreePath &&
            agent.workspaceId != null &&
            agent.workspaceId!.isNotEmpty) {
          workspaceId = agent.workspaceId;
          break;
        }
      }
      final projects =
          ref.watch(projectsProvider).value ?? const <ProjectInfo>[];
      for (final project in projects) {
        if (!project.isGitRepo) continue;
        final worktrees =
            ref.watch(worktreesProvider(project.path)).value ??
            const <WorktreeInfo>[];
        for (final worktree in worktrees) {
          if (worktree.path != worktreePath) continue;
          return WorktreeAgentContext(
            projectPath: worktree.projectPath,
            branch: worktree.isMain ? null : worktree.branch,
            isWorktree: !worktree.isMain,
            workspaceId: workspaceId,
          );
        }
      }
      return WorktreeAgentContext(workspaceId: workspaceId);
    });

/// Local branches of one project (family arg: the project's path), most
/// recently committed first, plus the currently checked-out branch. Used by
/// the "Start from" ref picker when creating a workspace in a new worktree.
class BranchesNotifier extends AsyncNotifier<BranchListResponse> {
  BranchesNotifier(this.projectPath);

  final String projectPath;

  @override
  Future<BranchListResponse> build() async {
    final client = ref.watch(daemonClientProvider);
    final connection = ref.watch(connectionStateProvider).value;
    if (connection != DaemonConnectionState.connected) {
      return const BranchListResponse(branches: [], currentBranch: '');
    }
    final res = await client.request(MessageTypes.branchListRequest, {
      'projectPath': projectPath,
    });
    return BranchListResponse.fromJson(res);
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

final branchesProvider =
    AsyncNotifierProvider.family<BranchesNotifier, BranchListResponse, String>(
      BranchesNotifier.new,
    );

/// Working-tree diff for a directory (family arg: cwd). Fetched on demand;
/// call [refresh] (or invalidate) to re-run `git diff` on the daemon.
class DiffNotifier extends AsyncNotifier<DiffResponse> {
  DiffNotifier(this.cwd);

  final String cwd;

  @override
  Future<DiffResponse> build() async {
    final client = ref.watch(daemonClientProvider);
    final connection = ref.watch(connectionStateProvider).value;
    if (connection != DaemonConnectionState.connected) {
      return const DiffResponse(files: []);
    }
    final res = await client.request(MessageTypes.diffGetRequest, {'cwd': cwd});
    return DiffResponse.fromJson(res);
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

final diffProvider =
    AsyncNotifierProvider.family<DiffNotifier, DiffResponse, String>(
      DiffNotifier.new,
    );
