import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

/// Registered projects, fetched on (re)connect. [add] registers a new path
/// with the daemon and appends it to the list.
class ProjectsNotifier extends AsyncNotifier<List<ProjectInfo>> {
  @override
  Future<List<ProjectInfo>> build() async {
    final client = ref.watch(daemonClientProvider);
    final connection = ref.watch(connectionStateProvider).value;
    if (connection != DaemonConnectionState.connected) return const [];
    final res = await client.request(MessageTypes.projectListRequest, const {});
    return ((res['projects'] as List?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(ProjectInfo.fromJson)
        .toList();
  }

  Future<ProjectInfo> add(String path) async {
    final client = ref.read(daemonClientProvider);
    final res = await client.request(MessageTypes.projectAddRequest, {
      'path': path,
    });
    final project = ProjectInfo.fromJson(
      res['project'] as Map<String, Object?>? ?? const {},
    );
    final current = state.value ?? const <ProjectInfo>[];
    state = AsyncData([
      ...current.where((p) => p.path != project.path),
      project,
    ]);
    return project;
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

  Future<WorktreeInfo> create(String branch) async {
    final client = ref.read(daemonClientProvider);
    final res = await client.request(MessageTypes.worktreeCreateRequest, {
      'projectPath': projectPath,
      'branch': branch,
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

  Future<void> archive(String path) async {
    final client = ref.read(daemonClientProvider);
    await client.request(MessageTypes.worktreeArchiveRequest, {'path': path});
    final current = state.value ?? const <WorktreeInfo>[];
    state = AsyncData(current.where((w) => w.path != path).toList());
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

final worktreesProvider =
    AsyncNotifierProvider.family<WorktreesNotifier, List<WorktreeInfo>, String>(
      WorktreesNotifier.new,
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
