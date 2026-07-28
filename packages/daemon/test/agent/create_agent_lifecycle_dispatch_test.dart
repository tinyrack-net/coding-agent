import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/create_agent_lifecycle_dispatch.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'auto-archive self-releases once and cancellation waits harmlessly',
    () async {
      const agentId = '4a7e2521-286d-4ad5-af35-e091c55302e3';
      final subscriptions = <_Subscription>[];
      var archiveCount = 0;
      final registration = registerAgentAutoArchive(
        subscribe: (subscriber, {agentId}) {
          final subscription = _Subscription(
            subscriber: subscriber,
            agentId: agentId,
          );
          subscriptions.add(subscription);
          return () => subscriptions.remove(subscription);
        },
        agentId: agentId,
        archive: () async {
          archiveCount += 1;
        },
      );

      _emit(subscriptions, agentId, TurnPhase.started);
      expect(archiveCount, 0);
      expect(subscriptions, hasLength(1));
      _emit(subscriptions, 'other-agent', TurnPhase.completed);
      expect(archiveCount, 0);
      _emit(subscriptions, agentId, TurnPhase.completed);
      await registration.cancel();
      await registration.cancel();
      _emit(subscriptions, agentId, TurnPhase.failed);

      expect(archiveCount, 1);
      expect(subscriptions, isEmpty);
    },
  );

  test('failed and canceled turns are terminal auto-archive edges', () async {
    for (final phase in const [TurnPhase.failed, TurnPhase.canceled]) {
      final subscriptions = <_Subscription>[];
      var archiveCount = 0;
      final registration = registerAgentAutoArchive(
        subscribe: (subscriber, {agentId}) {
          final subscription = _Subscription(
            subscriber: subscriber,
            agentId: agentId,
          );
          subscriptions.add(subscription);
          return () => subscriptions.remove(subscription);
        },
        agentId: 'agent',
        archive: () async {
          archiveCount += 1;
        },
      );

      _emit(subscriptions, 'agent', phase);
      await registration.cancel();

      expect(archiveCount, 1, reason: phase.name);
      expect(subscriptions, isEmpty, reason: phase.name);
    }
  });
}

final class _Subscription {
  const _Subscription({required this.subscriber, required this.agentId});

  final AgentStreamSubscriber subscriber;
  final String? agentId;
}

void _emit(List<_Subscription> subscriptions, String agentId, TurnPhase phase) {
  final payload = AgentStreamPayload(
    agentId: agentId,
    epoch: 1,
    seq: 1,
    item: TurnItem(id: 'turn:$agentId', phase: phase),
    provider: 'codex',
    timestamp: '2026-07-29T00:00:00.000Z',
  );
  for (final subscription in subscriptions.toList(growable: false)) {
    if (subscription.agentId == null || subscription.agentId == agentId) {
      subscription.subscriber(payload);
    }
  }
}
