import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/workspace/workspace_git_observer_service.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late _FakeBackend backend;
  late List<(String, String?, String?)> branches;
  late List<String> cwdUpdates;
  late List<String> workspaceUpdates;
  late List<(String, WorkspaceGitObserverSnapshot)> statuses;
  late List<String> logs;
  late WorkspaceGitObserverService observer;

  setUp(() {
    backend = _FakeBackend();
    branches = [];
    cwdUpdates = [];
    workspaceUpdates = [];
    statuses = [];
    logs = [];
    observer = WorkspaceGitObserverService(
      backend: backend,
      describeWorkspaceRecordWithGitData: (workspace) async => descriptor(
        id: workspace.workspaceId,
        cwd: workspace.cwd,
        kind: workspace.kind == PersistedWorkspaceKind.directory
            ? WorkspaceKind.directory
            : WorkspaceKind.worktree,
        branch: workspace.branch,
      ),
      emitWorkspaceUpdateForCwd: (cwd) async => cwdUpdates.add(cwd),
      emitWorkspaceUpdateForWorkspaceId: (id) async => workspaceUpdates.add(id),
      emitStatusUpdate: (cwd, snapshot) => statuses.add((cwd, snapshot)),
      onBranchChanged: (id, oldBranch, newBranch) =>
          branches.add((id, oldBranch, newBranch)),
      log: (message, _, __) => logs.add(message),
    );
  });

  tearDown(() => observer.dispose());

  test('same-directory workspaces share one subscription and identity', () {
    final cwd = p.join(Directory.current.path, 'repo');
    observer.syncObservers([
      descriptor(id: 'one', cwd: cwd, branch: 'main'),
      descriptor(id: 'two', cwd: cwd, branch: 'main'),
    ]);
    expect(observer.getMetrics().watchedDirectoryCount, 1);
    expect(observer.getMetrics().workspaceRecordCount, 2);
    expect(observer.getMetrics().subscriptionCount, 1);
    expect(backend.registrations, 1);

    backend.emit(cwd, 'feature');
    expect(branches, [('one', 'main', 'feature'), ('two', 'main', 'feature')]);
    expect(statuses.single.$1, p.normalize(p.absolute(cwd)));
    expect(cwdUpdates, [p.normalize(p.absolute(cwd))]);

    backend.emit(cwd, 'feature');
    expect(branches, hasLength(2));
  });

  test(
    'descriptor state deduplicates cards and observes branch projection',
    () {
      final initial = descriptor(
        id: 'one',
        cwd: 'repo',
        name: 'Repo',
        branch: 'main',
        additions: 1,
        deletions: 2,
      );
      observer.syncObservers([initial]);
      expect(observer.shouldSkipUpdate('one', initial), isTrue);

      final changed = descriptor(
        id: 'one',
        cwd: 'repo',
        name: 'Renamed',
        branch: 'feature',
        additions: 1,
        deletions: 2,
      );
      expect(observer.shouldSkipUpdate('one', changed), isFalse);
      expect(observer.shouldSkipUpdate('one', changed), isTrue);
      observer.recordDescriptorState('one', changed);
      expect(branches, [('one', 'main', 'feature')]);

      observer.recordDescriptorState('one', null);
      expect(observer.shouldSkipUpdate('one', null), isTrue);
      expect(observer.shouldSkipUpdate('missing', null), isFalse);
    },
  );

  test('moving, becoming non-git, and removing clean subscriptions', () {
    observer.syncObservers([descriptor(id: 'one', cwd: 'first')]);
    observer.syncObservers([descriptor(id: 'one', cwd: 'second')]);
    expect(backend.unsubscribed, [p.normalize(p.absolute('first'))]);
    expect(observer.getMetrics().watchedDirectoryCount, 1);

    observer.syncObservers([
      descriptor(id: 'one', cwd: 'second', kind: WorkspaceKind.directory),
    ]);
    expect(observer.getMetrics().watchedDirectoryCount, 0);
    expect(backend.unsubscribed, [
      p.normalize(p.absolute('first')),
      p.normalize(p.absolute('second')),
    ]);

    observer.removeForWorkspaceId('missing');
    observer.handleBranchSnapshot('missing', 'main');
  });

  test('warm describes, subscribes, and emits the workspace', () async {
    final record = createPersistedWorkspaceRecord(
      workspaceId: 'one',
      projectId: 'project',
      cwd: 'repo',
      kind: PersistedWorkspaceKind.worktree,
      displayName: 'Repo',
      branch: 'main',
      createdAt: '1',
      updatedAt: '1',
    );
    await observer.warmGitData(record);
    expect(observer.getMetrics().subscriptionCount, 1);
    expect(workspaceUpdates, ['one']);
  });

  test('subscription failure rolls back observer state', () {
    backend.error = StateError('watch failed');
    expect(
      () => observer.syncObservers([descriptor(id: 'one', cwd: 'repo')]),
      throwsStateError,
    );
    expect(observer.getMetrics().watchedDirectoryCount, 0);
    expect(observer.getMetrics().workspaceRecordCount, 0);
    expect(observer.getMetrics().subscriptionCount, 0);
  });

  test(
    'async update failure is logged without stopping status updates',
    () async {
      observer = WorkspaceGitObserverService(
        backend: backend,
        describeWorkspaceRecordWithGitData: (_) async =>
            descriptor(id: 'one', cwd: 'repo'),
        emitWorkspaceUpdateForCwd: (_) => Future.error(StateError('emit')),
        emitWorkspaceUpdateForWorkspaceId: (_) async {},
        emitStatusUpdate: (cwd, snapshot) => statuses.add((cwd, snapshot)),
        log: (message, _, __) => logs.add(message),
      );
      observer.syncObservers([descriptor(id: 'one', cwd: 'repo')]);
      backend.emit('repo', 'main');
      await Future<void>.delayed(Duration.zero);
      expect(logs.single, contains('Failed to emit workspace update'));
      expect(statuses, hasLength(1));
    },
  );
}

WorkspaceDescriptor descriptor({
  required String id,
  required String cwd,
  WorkspaceKind kind = WorkspaceKind.worktree,
  String name = 'Repo',
  String? branch,
  num? additions,
  num? deletions,
}) => WorkspaceDescriptor(
  id: id,
  projectId: 'project',
  projectDisplayName: 'Project',
  projectRootPath: cwd,
  workspaceDirectory: cwd,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: kind,
  name: name,
  status: WorkspaceStateBucket.done,
  activityAt: null,
  diffStat: additions == null || deletions == null
      ? null
      : WorkspaceDiffStat(additions: additions, deletions: deletions),
  gitRuntime: WorkspaceGitRuntime(currentBranch: branch),
);

final class _FakeBackend implements WorkspaceGitObserverBackend {
  final Map<String, void Function(WorkspaceGitObserverSnapshot)> callbacks = {};
  final List<String> unsubscribed = [];
  Object? error;
  int registrations = 0;

  @override
  WorkspaceGitSubscription registerWorkspace(
    String cwd,
    void Function(WorkspaceGitObserverSnapshot snapshot) onSnapshot,
  ) {
    final failure = error;
    if (failure != null) throw failure;
    registrations++;
    callbacks[cwd] = onSnapshot;
    return WorkspaceGitSubscription(
      unsubscribe: () {
        callbacks.remove(cwd);
        unsubscribed.add(cwd);
      },
    );
  }

  void emit(String cwd, String? branch) {
    callbacks[p.normalize(p.absolute(cwd))]!(
      WorkspaceGitObserverSnapshot(currentBranch: branch),
    );
  }
}
