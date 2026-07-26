import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    DaemonConnectionState initial = DaemonConnectionState.connected,
  }) : _state = initial,
       super(uri: Uri.parse('ws://fake'));

  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState _state;
  final requests = <(String, Map<String, Object?>)>[];
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;

  // Replays the current state to each new subscriber, then follows further
  // changes — matches how StreamProvider.build() subscribes fresh each time
  // and needs an immediate value to resolve `.future`.
  @override
  Stream<DaemonConnectionState> get connectionState async* {
    yield _state;
    yield* connectionController.stream;
  }

  @override
  DaemonConnectionState get currentState => _state;

  void setState(DaemonConnectionState state) {
    _state = state;
    connectionController.add(state);
  }

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return onRequest?.call(type, payload) ?? const {};
  }
}

ProviderContainer makeContainer(FakeDaemonClient client) {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Pumps the microtask queue a few times: enough for the fake's
/// `connectionState` stream to deliver its first (or next) event and for the
/// dependent `AsyncNotifier`s that `ref.watch` it to rebuild and settle.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Subscribes to [provider] so it (and anything it `ref.watch`es, like
/// `connectionStateProvider`) stays alive between the fake's async state
/// changes — a bare `container.read()` doesn't hold an autodispose provider
/// open, so it would be rebuilt from scratch (losing its subscriptions) the
/// moment nothing is listening.
void keepAlive(ProviderContainer container, ProviderSubscription<Object?> sub) {
  addTearDown(sub.close);
}

const _proj = ProjectInfo(path: '/repo', name: 'repo', isGitRepo: true);
const _wt = WorktreeInfo(
  path: '/repo-wt',
  branch: 'feature/x',
  projectPath: '/repo',
);

void main() {
  group('ProjectsNotifier', () {
    test('build() returns empty list while disconnected', () async {
      final client = FakeDaemonClient(
        initial: DaemonConnectionState.disconnected,
      );
      final container = makeContainer(client);

      final projects = await container.read(projectsProvider.future);
      expect(projects, isEmpty);
      expect(client.requests, isEmpty);
    });

    test('build() fetches project.list.request when connected', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.projectListRequest);
        return {
          'projects': [_proj.toJson()],
        };
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      await pump();

      final projects = await container.read(projectsProvider.future);
      expect(projects.single.path, '/repo');
    });

    test('add() requests project.add and appends the result', () async {
      const another = ProjectInfo(
        path: '/other',
        name: 'other',
        isGitRepo: false,
      );
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_proj.toJson()],
          };
        }
        expect(type, MessageTypes.projectAddRequest);
        expect(payload['path'], '/other');
        return {'project': another.toJson()};
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      await pump();
      await container.read(projectsProvider.future);

      final added = await container
          .read(projectsProvider.notifier)
          .add('/other');

      expect(added.path, '/other');
      final projects = container.read(projectsProvider).value!;
      expect(projects.map((p) => p.path), containsAll(['/repo', '/other']));
    });

    test('add() replaces an existing project with the same path', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_proj.toJson()],
          };
        }
        return {
          'project': const ProjectInfo(
            path: '/repo',
            name: 'renamed',
            isGitRepo: true,
          ).toJson(),
        };
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      await pump();
      await container.read(projectsProvider.future);

      await container.read(projectsProvider.notifier).add('/repo');

      final projects = container.read(projectsProvider).value!;
      expect(projects, hasLength(1));
      expect(projects.single.name, 'renamed');
    });

    test('refresh() re-invokes build()', () async {
      final client = FakeDaemonClient();
      var calls = 0;
      client.onRequest = (type, payload) {
        calls++;
        return const {'projects': []};
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      await pump();
      await container.read(projectsProvider.future);
      expect(calls, 1);

      await container.read(projectsProvider.notifier).refresh();
      await container.read(projectsProvider.future);

      expect(calls, 2);
    });
  });

  group('WorktreesNotifier', () {
    test('build() scopes the request to the given project path', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.worktreeListRequest);
        expect(payload['projectPath'], '/repo');
        return {
          'worktrees': [_wt.toJson()],
        };
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();

      final worktrees = await container.read(worktreesProvider('/repo').future);
      expect(worktrees.single.branch, 'feature/x');
    });

    test('create() requests worktree.create and appends the result', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.worktreeListRequest) {
          return const {'worktrees': []};
        }
        expect(type, MessageTypes.worktreeCreateRequest);
        expect(payload['projectPath'], '/repo');
        expect(payload['branch'], 'feature/y');
        expect(payload.containsKey('baseRef'), isFalse);
        return {
          'worktree': const WorktreeInfo(
            path: '/repo-y',
            branch: 'feature/y',
            projectPath: '/repo',
          ).toJson(),
        };
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();
      await container.read(worktreesProvider('/repo').future);

      final created = await container
          .read(worktreesProvider('/repo').notifier)
          .create('feature/y');

      expect(created.path, '/repo-y');
      expect(
        container.read(worktreesProvider('/repo')).value!.map((w) => w.path),
        contains('/repo-y'),
      );
    });

    test('create() forwards baseRef when given', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.worktreeListRequest) {
          return const {'worktrees': []};
        }
        expect(payload['baseRef'], 'main');
        return {
          'worktree': const WorktreeInfo(
            path: '/repo-y',
            branch: 'lucky-otter',
            projectPath: '/repo',
          ).toJson(),
        };
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();
      await container.read(worktreesProvider('/repo').future);

      await container
          .read(worktreesProvider('/repo').notifier)
          .create('lucky-otter', baseRef: 'main');
    });

    test(
      'archive() requests worktree.archive and removes it from state',
      () async {
        final client = FakeDaemonClient();
        client.onRequest = (type, payload) {
          if (type == MessageTypes.worktreeListRequest) {
            return {
              'worktrees': [_wt.toJson()],
            };
          }
          expect(type, MessageTypes.worktreeArchiveRequest);
          expect(payload['path'], '/repo-wt');
          return const {};
        };
        final container = makeContainer(client);
        keepAlive(
          container,
          container.listen(worktreesProvider('/repo'), (_, _) {}),
        );
        await pump();
        await container.read(worktreesProvider('/repo').future);

        await container
            .read(worktreesProvider('/repo').notifier)
            .archive('/repo-wt');

        expect(container.read(worktreesProvider('/repo')).value, isEmpty);
      },
    );

    test('archive() propagates a conflict error for a dirty worktree without '
        'removing it from state', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.worktreeListRequest) {
          return {
            'worktrees': [_wt.toJson()],
          };
        }
        expect(type, MessageTypes.worktreeArchiveRequest);
        expect(payload.containsKey('force'), isFalse);
        throw DaemonRpcException(
          const RpcError(
            code: RpcErrorCodes.conflict,
            message: 'uncommitted changes',
          ),
        );
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();
      await container.read(worktreesProvider('/repo').future);

      await expectLater(
        container.read(worktreesProvider('/repo').notifier).archive('/repo-wt'),
        throwsA(
          isA<DaemonRpcException>().having(
            (e) => e.error.code,
            'code',
            RpcErrorCodes.conflict,
          ),
        ),
      );
      expect(
        container.read(worktreesProvider('/repo')).value!.map((w) => w.path),
        contains('/repo-wt'),
      );
    });

    test(
      'archive(force: true) forwards force and removes it from state',
      () async {
        final client = FakeDaemonClient();
        client.onRequest = (type, payload) {
          if (type == MessageTypes.worktreeListRequest) {
            return {
              'worktrees': [_wt.toJson()],
            };
          }
          expect(type, MessageTypes.worktreeArchiveRequest);
          expect(payload['force'], isTrue);
          return const {};
        };
        final container = makeContainer(client);
        keepAlive(
          container,
          container.listen(worktreesProvider('/repo'), (_, _) {}),
        );
        await pump();
        await container.read(worktreesProvider('/repo').future);

        await container
            .read(worktreesProvider('/repo').notifier)
            .archive('/repo-wt', force: true);

        expect(container.read(worktreesProvider('/repo')).value, isEmpty);
      },
    );
  });

  group('BranchesNotifier', () {
    test('build() returns empty while disconnected', () async {
      final client = FakeDaemonClient(
        initial: DaemonConnectionState.disconnected,
      );
      final container = makeContainer(client);

      final branches = await container.read(branchesProvider('/repo').future);
      expect(branches.branches, isEmpty);
      expect(branches.currentBranch, isEmpty);
    });

    test('build() fetches branch.list scoped to the project path', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.branchListRequest);
        expect(payload['projectPath'], '/repo');
        return const BranchListResponse(
          branches: ['main', 'feature/x'],
          currentBranch: 'main',
        ).toJson();
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(branchesProvider('/repo'), (_, _) {}),
      );
      await pump();

      final branches = await container.read(branchesProvider('/repo').future);
      expect(branches.branches, ['main', 'feature/x']);
      expect(branches.currentBranch, 'main');
    });
  });

  group('DiffNotifier', () {
    test('build() returns an empty diff while disconnected', () async {
      final client = FakeDaemonClient(
        initial: DaemonConnectionState.disconnected,
      );
      final container = makeContainer(client);

      final diff = await container.read(diffProvider('/repo').future);
      expect(diff.files, isEmpty);
    });

    test('build() fetches diff.get scoped to cwd', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.diffGetRequest);
        expect(payload['cwd'], '/repo');
        return {
          'files': [
            const DiffFile(
              path: 'a.txt',
              status: DiffFileStatus.added,
              additions: 1,
            ).toJson(),
          ],
        };
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(diffProvider('/repo'), (_, _) {}));
      await pump();

      final diff = await container.read(diffProvider('/repo').future);
      expect(diff.files.single.path, 'a.txt');
    });

    test('refresh() re-fetches the diff', () async {
      final client = FakeDaemonClient();
      var calls = 0;
      client.onRequest = (type, payload) {
        calls++;
        return const {'files': []};
      };
      final container = makeContainer(client);
      keepAlive(container, container.listen(diffProvider('/repo'), (_, _) {}));
      await pump();
      await container.read(diffProvider('/repo').future);
      expect(calls, 1);

      await container.read(diffProvider('/repo').notifier).refresh();
      await container.read(diffProvider('/repo').future);

      expect(calls, 2);
    });
  });

  group('WorktreesNotifier.refresh', () {
    test('re-fetches worktree.list.request', () async {
      final client = FakeDaemonClient();
      var calls = 0;
      client.onRequest = (type, payload) {
        if (type == MessageTypes.worktreeListRequest) calls++;
        return {
          'worktrees': [_wt.toJson()],
        };
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();
      await container.read(worktreesProvider('/repo').future);
      expect(calls, 1);

      await container.read(worktreesProvider('/repo').notifier).refresh();
      await container.read(worktreesProvider('/repo').future);
      expect(calls, 2);
    });
  });

  group('BranchesNotifier.refresh', () {
    test('re-fetches branch.list.request', () async {
      final client = FakeDaemonClient();
      var calls = 0;
      client.onRequest = (type, payload) {
        if (type == MessageTypes.branchListRequest) calls++;
        return const {'branches': [], 'current': 'main'};
      };
      final container = makeContainer(client);
      keepAlive(
        container,
        container.listen(branchesProvider('/repo'), (_, _) {}),
      );
      await pump();
      await container.read(branchesProvider('/repo').future);
      expect(calls, 1);

      await container.read(branchesProvider('/repo').notifier).refresh();
      await container.read(branchesProvider('/repo').future);
      expect(calls, 2);
    });
  });

  // Resolves the project/branch a worktree path belongs to, by searching every
  // registered git project's worktree list. Drives the "new agent in this
  // worktree" flow, so a wrong answer creates the agent against the wrong repo.
  group('worktreeAgentContextProvider', () {
    ProviderContainer withProjectsAndWorktrees(
      List<ProjectInfo> projects,
      Map<String, List<WorktreeInfo>> worktreesByProject,
    ) {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {'projects': [for (final p in projects) p.toJson()]};
        }
        if (type == MessageTypes.worktreeListRequest) {
          final list =
              worktreesByProject[payload['projectPath'] as String] ?? const [];
          return {'worktrees': [for (final w in list) w.toJson()]};
        }
        return const {};
      };
      return makeContainer(client);
    }

    test('resolves the owning project and branch for a worktree', () async {
      final container = withProjectsAndWorktrees(
        [_proj],
        {'/repo': [_wt]},
      );
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();

      final context = container.read(worktreeAgentContextProvider('/repo-wt'));
      expect(context.projectPath, '/repo');
      expect(context.branch, 'feature/x');
      expect(context.isWorktree, isTrue);
    });

    test('the main worktree reports no branch and isWorktree false', () async {
      const main = WorktreeInfo(
        path: '/repo',
        branch: 'main',
        projectPath: '/repo',
        isMain: true,
      );
      final container = withProjectsAndWorktrees(
        [_proj],
        {'/repo': [main]},
      );
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();

      final context = container.read(worktreeAgentContextProvider('/repo'));
      expect(context.projectPath, '/repo');
      // A main worktree isn't an isolated branch, so no branch is reported.
      expect(context.branch, isNull);
      expect(context.isWorktree, isFalse);
    });

    test('an unknown path falls back to an empty context', () async {
      final container = withProjectsAndWorktrees(
        [_proj],
        {'/repo': [_wt]},
      );
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      keepAlive(
        container,
        container.listen(worktreesProvider('/repo'), (_, _) {}),
      );
      await pump();

      final context = container.read(
        worktreeAgentContextProvider('/somewhere-else'),
      );
      expect(context.projectPath, isNull);
      expect(context.branch, isNull);
      expect(context.isWorktree, isFalse);
    });

    test('non-git projects are skipped', () async {
      const plain = ProjectInfo(path: '/plain', name: 'plain', isGitRepo: false);
      final container = withProjectsAndWorktrees(
        [plain],
        // Even if the daemon returned worktrees, a non-git project is skipped
        // without ever being asked.
        {'/plain': [_wt]},
      );
      keepAlive(container, container.listen(projectsProvider, (_, _) {}));
      await pump();

      final context = container.read(worktreeAgentContextProvider('/repo-wt'));
      expect(context.projectPath, isNull);
    });
  });
}
