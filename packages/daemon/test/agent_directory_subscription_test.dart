import 'package:agent_daemon/src/server/agent_directory_subscription.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'buffers during bootstrap and retains only the last update per agent',
    () {
      final subscription = AgentDirectorySubscription(
        subscriptionId: 'sub-1',
        filter: null,
      );
      final emitted = <AgentDirectoryUpdate>[];

      subscription
        ..add(
          AgentDirectoryUpsert(
            agent: _agent('agent-1', updatedAt: '2026-01-01T00:00:01.000Z'),
            project: const {'projectKey': 'project-1'},
          ),
          providerVisible: true,
          emit: emitted.add,
        )
        ..add(
          const AgentDirectoryRemove('agent-1'),
          providerVisible: true,
          emit: emitted.add,
        );

      expect(subscription.isBootstrapping, isTrue);
      expect(subscription.pendingUpdateCount, 1);
      expect(emitted, isEmpty);

      subscription.flush(
        snapshotUpdatedAtByAgentId: const {},
        emit: emitted.add,
      );

      expect(subscription.isBootstrapping, isFalse);
      expect(subscription.pendingUpdateCount, 0);
      expect(emitted, [isA<AgentDirectoryRemove>()]);
    },
  );

  test('flush drops an upsert represented by an equal or newer snapshot', () {
    final subscription = AgentDirectorySubscription(
      subscriptionId: 'sub-1',
      filter: null,
    );
    final emitted = <AgentDirectoryUpdate>[];
    subscription.add(
      AgentDirectoryUpsert(
        agent: _agent('agent-1', updatedAt: '2026-01-01T00:00:01.000Z'),
        project: const {'projectKey': 'project-1'},
      ),
      providerVisible: true,
      emit: emitted.add,
    );

    subscription.flush(
      snapshotUpdatedAtByAgentId: {
        'agent-1': DateTime.parse(
          '2026-01-01T00:00:01.000Z',
        ).millisecondsSinceEpoch,
      },
      emit: emitted.add,
    );

    expect(emitted, isEmpty);
  });

  test('flush replays newer upserts and live updates emit immediately', () {
    final subscription = AgentDirectorySubscription(
      subscriptionId: 'sub-1',
      filter: null,
    );
    final emitted = <AgentDirectoryUpdate>[];
    final newer = AgentDirectoryUpsert(
      agent: _agent('agent-1', updatedAt: '2026-01-01T00:00:02.000Z'),
      project: const {'projectKey': 'project-1'},
    );
    subscription.add(newer, providerVisible: true, emit: emitted.add);
    subscription.flush(
      snapshotUpdatedAtByAgentId: {
        'agent-1': DateTime.parse(
          '2026-01-01T00:00:01.000Z',
        ).millisecondsSinceEpoch,
      },
      emit: emitted.add,
    );

    const remove = AgentDirectoryRemove('agent-2');
    subscription.add(remove, providerVisible: true, emit: emitted.add);

    expect(emitted, [same(newer), same(remove)]);
  });

  test('provider visibility suppresses only upserts', () {
    final subscription = AgentDirectorySubscription(
      subscriptionId: 'sub-1',
      filter: null,
    );
    final emitted = <AgentDirectoryUpdate>[];
    subscription.flush(snapshotUpdatedAtByAgentId: const {}, emit: emitted.add);

    subscription
      ..add(
        AgentDirectoryUpsert(
          agent: _agent('agent-1', updatedAt: '2026-01-01T00:00:01.000Z'),
          project: const {'projectKey': 'project-1'},
        ),
        providerVisible: false,
        emit: emitted.add,
      )
      ..add(
        const AgentDirectoryRemove('agent-1'),
        providerVisible: false,
        emit: emitted.add,
      );

    expect(emitted, [isA<AgentDirectoryRemove>()]);
  });

  test('flush is idempotent', () {
    final subscription = AgentDirectorySubscription(
      subscriptionId: 'sub-1',
      filter: null,
    );
    final emitted = <AgentDirectoryUpdate>[];
    subscription.add(
      const AgentDirectoryRemove('agent-1'),
      providerVisible: true,
      emit: emitted.add,
    );
    subscription
      ..flush(snapshotUpdatedAtByAgentId: const {}, emit: emitted.add)
      ..flush(snapshotUpdatedAtByAgentId: const {}, emit: emitted.add);

    expect(emitted, hasLength(1));
  });
}

AgentSummary _agent(String id, {required String updatedAt}) => AgentSummary(
  agentId: id,
  title: id,
  provider: 'codex',
  cwd: r'C:\repo',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: DateTime.parse(
    '2026-01-01T00:00:00.000Z',
  ).millisecondsSinceEpoch,
  updatedAt: updatedAt,
);
