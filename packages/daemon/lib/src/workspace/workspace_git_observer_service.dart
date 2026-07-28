import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'workspace_registry.dart';

const workspaceGitWatchRemovedStateKey = '__removed__';

final class WorkspaceGitObserverSnapshot {
  const WorkspaceGitObserverSnapshot({required this.currentBranch, this.value});

  final String? currentBranch;
  final Object? value;
}

final class WorkspaceGitSubscription {
  const WorkspaceGitSubscription({required this.unsubscribe});

  final void Function() unsubscribe;
}

abstract interface class WorkspaceGitObserverBackend {
  WorkspaceGitSubscription registerWorkspace(
    String cwd,
    void Function(WorkspaceGitObserverSnapshot snapshot) onSnapshot,
  );
}

final class WorkspaceGitObserverMetrics {
  const WorkspaceGitObserverMetrics({
    required this.watchedDirectoryCount,
    required this.workspaceRecordCount,
    required this.subscriptionCount,
  });

  final int watchedDirectoryCount;
  final int workspaceRecordCount;
  final int subscriptionCount;
}

typedef WorkspaceGitObserverLog =
    void Function(String message, Object error, StackTrace stackTrace);

final class WorkspaceGitObserverService {
  WorkspaceGitObserverService({
    required this.backend,
    required this.describeWorkspaceRecordWithGitData,
    required this.emitWorkspaceUpdateForCwd,
    required this.emitWorkspaceUpdateForWorkspaceId,
    required this.emitStatusUpdate,
    this.onBranchChanged,
    this.log,
  });

  final WorkspaceGitObserverBackend backend;
  final Future<WorkspaceDescriptor> Function(PersistedWorkspaceRecord workspace)
  describeWorkspaceRecordWithGitData;
  final Future<void> Function(String cwd) emitWorkspaceUpdateForCwd;
  final Future<void> Function(String workspaceId)
  emitWorkspaceUpdateForWorkspaceId;
  final void Function(String cwd, WorkspaceGitObserverSnapshot snapshot)
  emitStatusUpdate;
  final void Function(String workspaceId, String? oldBranch, String? newBranch)?
  onBranchChanged;
  final WorkspaceGitObserverLog? log;

  final Map<String, _WorkspaceGitWatchTarget> _watchTargets = {};
  final Map<String, _WorkspaceGitWatchState> _workspaceStates = {};
  final Map<String, void Function()> _subscriptions = {};

  void syncObservers(Iterable<WorkspaceDescriptor> workspaces) {
    for (final workspace in workspaces) {
      _syncObserver(
        workspace.workspaceDirectory,
        isGit: workspace.workspaceKind != WorkspaceKind.directory,
        workspaceId: workspace.id,
      );
      _rememberDescriptorState(workspace.id, workspace);
    }
  }

  Future<void> syncObserverForWorkspace(
    PersistedWorkspaceRecord workspace,
  ) async {
    syncObservers([await describeWorkspaceRecordWithGitData(workspace)]);
  }

  Future<void> warmGitData(PersistedWorkspaceRecord workspace) async {
    await syncObserverForWorkspace(workspace);
    await emitWorkspaceUpdateForWorkspaceId(workspace.workspaceId);
  }

  bool shouldSkipUpdate(String workspaceId, WorkspaceDescriptor? workspace) {
    final state = _workspaceStates[workspaceId];
    if (state == null) return false;
    final next = _descriptorStateKey(workspace);
    if (state.latestDescriptorStateKey == next) return true;
    state.latestDescriptorStateKey = next;
    return false;
  }

  void recordDescriptorState(
    String workspaceId,
    WorkspaceDescriptor? workspace,
  ) {
    final state = _workspaceStates[workspaceId];
    final newBranch = workspace?.gitRuntime?.currentBranch;
    if (state != null &&
        onBranchChanged != null &&
        newBranch != state.lastBranchName) {
      onBranchChanged!(workspaceId, state.lastBranchName, newBranch);
    }
    _rememberDescriptorState(workspaceId, workspace);
  }

  void handleBranchSnapshot(String cwd, String? branchName) {
    final target = _watchTargets[_normalizeCwd(cwd)];
    if (target == null) return;
    for (final workspaceId in target.workspaceIds) {
      final state = _workspaceStates[workspaceId];
      if (state == null || branchName == state.lastBranchName) continue;
      final previous = state.lastBranchName;
      state.lastBranchName = branchName;
      onBranchChanged?.call(workspaceId, previous, branchName);
    }
  }

  WorkspaceGitObserverMetrics getMetrics() => WorkspaceGitObserverMetrics(
    watchedDirectoryCount: _watchTargets.length,
    workspaceRecordCount: _workspaceStates.length,
    subscriptionCount: _subscriptions.length,
  );

  void removeForWorkspaceId(String workspaceId) {
    final state = _workspaceStates.remove(workspaceId);
    if (state == null) return;
    final target = _watchTargets[state.cwd];
    target?.workspaceIds.remove(workspaceId);
    if (target?.workspaceIds.isEmpty ?? false) {
      _removeForCwd(state.cwd);
    }
  }

  void dispose() {
    for (final unsubscribe in _subscriptions.values) {
      unsubscribe();
    }
    _subscriptions.clear();
    _watchTargets.clear();
    _workspaceStates.clear();
  }

  void _syncObserver(
    String cwd, {
    required bool isGit,
    required String workspaceId,
  }) {
    final normalized = _normalizeCwd(cwd);
    final current = _workspaceStates[workspaceId];
    if (current != null && current.cwd != normalized) {
      removeForWorkspaceId(workspaceId);
    }
    if (!isGit) {
      removeForWorkspaceId(workspaceId);
      return;
    }
    final target = _watchTargets[normalized] ?? _WorkspaceGitWatchTarget();
    _watchTargets[normalized] = target;
    target.workspaceIds.add(workspaceId);
    _workspaceStates.putIfAbsent(
      workspaceId,
      () => _WorkspaceGitWatchState(cwd: normalized),
    );
    if (_subscriptions.containsKey(normalized)) return;
    try {
      final subscription = backend.registerWorkspace(normalized, (snapshot) {
        handleBranchSnapshot(normalized, snapshot.currentBranch);
        unawaited(
          emitWorkspaceUpdateForCwd(normalized).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            log?.call(
              'Failed to emit workspace update after git branch snapshot',
              error,
              stackTrace,
            );
          }),
        );
        emitStatusUpdate(normalized, snapshot);
      });
      _subscriptions[normalized] = subscription.unsubscribe;
    } catch (_) {
      removeForWorkspaceId(workspaceId);
      rethrow;
    }
  }

  void _removeForCwd(String cwd) {
    final normalized = _normalizeCwd(cwd);
    final target = _watchTargets.remove(normalized);
    for (final workspaceId in target?.workspaceIds ?? const <String>{}) {
      _workspaceStates.remove(workspaceId);
    }
    _subscriptions.remove(normalized)?.call();
  }

  void _rememberDescriptorState(
    String workspaceId,
    WorkspaceDescriptor? workspace,
  ) {
    final state = _workspaceStates[workspaceId];
    if (state == null) return;
    state.latestDescriptorStateKey = _descriptorStateKey(workspace);
    state.lastBranchName = workspace?.gitRuntime?.currentBranch;
  }
}

final class _WorkspaceGitWatchTarget {
  final Set<String> workspaceIds = {};
}

final class _WorkspaceGitWatchState {
  _WorkspaceGitWatchState({required this.cwd});

  final String cwd;
  String? latestDescriptorStateKey;
  String? lastBranchName;
}

String _descriptorStateKey(WorkspaceDescriptor? workspace) {
  if (workspace == null) return workspaceGitWatchRemovedStateKey;
  return jsonEncode([
    workspace.name,
    if (workspace.diffStat == null)
      null
    else
      [workspace.diffStat!.additions, workspace.diffStat!.deletions],
  ]);
}

String _normalizeCwd(String cwd) => p.normalize(p.absolute(cwd));
