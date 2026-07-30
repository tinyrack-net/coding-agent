import 'dart:async';

import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/workspace/checkout_diff_service.dart';
import 'package:agent_daemon/src/workspace/workspace_git_observer_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late _FakeGitService git;
  late _FakeBackend backend;
  late CheckoutDiffService service;
  late List<Map<String, Object?>> sent;
  late Connection connection;

  setUp(() {
    git = _FakeGitService();
    backend = _FakeBackend();
    service = CheckoutDiffService(
      git: git,
      backend: backend,
      debounce: Duration.zero,
    );
    sent = [];
    connection = Connection.external(
      frames: const Stream.empty(),
      send: (_) {},
      close: (_, _) {},
      id: 'connection-1',
      transport: 'test',
      externalSessionKey: null,
      relayConnectionId: null,
    )..onJsonSent = sent.add;
  });

  tearDown(() => service.dispose());

  test(
    'returns an initial snapshot using the normalized compare contract',
    () async {
      git.currentDiff = const DiffResponse(
        files: [
          DiffFile(
            path: 'b.txt',
            status: DiffFileStatus.modified,
            additions: 1,
          ),
        ],
      );

      final response = SubscribeCheckoutDiffResponse.fromJson(
        await service.subscribe(connection, _subscribe(baseRef: 'origin/main')),
      );

      expect(response.requestId, 'request-1');
      expect(response.payload.files.single.path, 'b.txt');
      expect(git.compares.single.mode, CheckoutDiffMode.base);
      expect(git.compares.single.baseRef, 'origin/main');
      expect(backend.activeCount, 1);
    },
  );

  test('pushes only changed snapshots after backend notifications', () async {
    await service.subscribe(connection, _subscribe());
    backend.emit('/repo');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);

    git.currentDiff = const DiffResponse(
      files: [
        DiffFile(path: 'new.txt', status: DiffFileStatus.added, additions: 2),
      ],
    );
    backend.emit('/repo');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(sent, hasLength(1));
    final update = CheckoutDiffUpdate.fromJson(
      Map<String, Object?>.from(sent.single['message']! as Map),
    );
    expect(update.payload.files.single.path, 'new.txt');
  });

  test(
    'duplicate ids replace watchers and unsubscribe is session scoped',
    () async {
      await service.subscribe(connection, _subscribe());
      await service.subscribe(connection, _subscribe());
      expect(backend.activeCount, 1);

      final other = Connection.external(
        frames: const Stream.empty(),
        send: (_) {},
        close: (_, _) {},
        id: 'connection-2',
        transport: 'test',
        externalSessionKey: null,
        relayConnectionId: null,
      );
      await service.subscribe(other, _subscribe());
      expect(backend.activeCount, 2);

      service.unsubscribe('connection-1', {
        'type': UnsubscribeCheckoutDiffRequest.type,
        'subscriptionId': 'subscription-1',
      });
      expect(backend.activeCount, 1);
      service.onConnectionClosed('connection-2');
      expect(backend.activeCount, 0);
    },
  );
}

Map<String, Object?> _subscribe({String? baseRef}) =>
    SubscribeCheckoutDiffRequest(
      subscriptionId: 'subscription-1',
      cwd: '/repo',
      compare: CheckoutDiffCompare(
        mode: baseRef == null
            ? CheckoutDiffMode.uncommitted
            : CheckoutDiffMode.base,
        baseRef: baseRef,
      ),
      requestId: 'request-1',
    ).toJson();

final class _FakeGitService extends GitService {
  _FakeGitService() : super(dataDir: '.');

  DiffResponse currentDiff = const DiffResponse(files: []);
  final compares = <CheckoutDiffCompare>[];

  @override
  Future<DiffResponse> checkoutDiff(
    String cwd,
    CheckoutDiffCompare compare,
  ) async {
    compares.add(compare);
    return currentDiff;
  }
}

final class _FakeBackend implements WorkspaceGitObserverBackend {
  final Map<String, List<void Function(WorkspaceGitObserverSnapshot)>>
  listeners = {};

  int get activeCount =>
      listeners.values.fold(0, (count, values) => count + values.length);

  @override
  WorkspaceGitSubscription registerWorkspace(
    String cwd,
    void Function(WorkspaceGitObserverSnapshot snapshot) onSnapshot,
  ) {
    listeners.putIfAbsent(cwd, () => []).add(onSnapshot);
    return WorkspaceGitSubscription(
      unsubscribe: () => listeners[cwd]?.remove(onSnapshot),
    );
  }

  void emit(String cwd) {
    for (final listener in [...?listeners[cwd]]) {
      listener(const WorkspaceGitObserverSnapshot(currentBranch: 'main'));
    }
  }
}
