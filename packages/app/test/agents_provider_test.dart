import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _a1 = AgentSummary(
  agentId: 'a1',
  title: 'First',
  cwd: '/work/one',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _a2 = AgentSummary(
  agentId: 'a2',
  title: 'Second',
  cwd: '/work/two',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.plan,
  runState: AgentRunState.running,
  createdAtMs: 200,
);

/// Scriptable fake: connectionState/currentState/events are settable per test
/// and `request()` records calls and returns canned responses by type.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  final requests = <(String, Map<String, Object?>)>[];

  DaemonConnectionState _state = DaemonConnectionState.disconnected;
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
      onRequest;
  Object? requestError;

  @override
  Stream<RpcEvent> get events => eventsController.stream;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      connectionController.stream;

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
    final error = requestError;
    if (error != null) throw error;
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

void main() {
  test('build() starts empty and does not fetch when disconnected', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);

    expect(container.read(agentsProvider), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(client.requests, isEmpty);
  });

  test('build() fetches immediately when already connected', () async {
    final client = FakeDaemonClient()
      .._state = DaemonConnectionState.connected;
    client.onRequest = (type, payload) {
      if (type == MessageTypes.agentListRequest) {
        return {
          'agents': [_a1.toJson()],
        };
      }
      return const {};
    };
    final container = makeContainer(client);
    container.read(agentsProvider); // build

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider)['a1']?.title, 'First');
  });

  test('reconnecting triggers a refresh()', () async {
    final client = FakeDaemonClient();
    client.onRequest = (type, payload) {
      if (type == MessageTypes.agentListRequest) {
        return {
          'agents': [_a1.toJson()],
        };
      }
      return const {};
    };
    final container = makeContainer(client);
    container.read(agentsProvider);
    expect(container.read(agentsProvider), isEmpty);

    client.setState(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider).keys, contains('a1'));
  });

  test('agent.state event upserts the agent', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStateEvent,
      payload: AgentStatePayload(agent: _a1).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider)['a1']?.runState, AgentRunState.idle);

    final updated = _a1.copyWith(runState: AgentRunState.running);
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStateEvent,
      payload: AgentStatePayload(agent: updated).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(agentsProvider)['a1']?.runState,
      AgentRunState.running,
    );
  });

  test('malformed agent.state event is ignored', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.eventsController.add(const RpcEvent(
      type: MessageTypes.agentStateEvent,
      payload: {'agent': 'not-a-map-shape'},
    ));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider), isEmpty);
  });

  test('events of other types are ignored', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.eventsController.add(const RpcEvent(type: 'terminal.exited'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider), isEmpty);
  });

  test('refresh() swallows request failures and keeps prior state', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider.notifier).upsert(_a1);

    client.requestError = StateError('not connected');
    await container.read(agentsProvider.notifier).refresh();

    expect(container.read(agentsProvider)['a1'], _a1);
  });

  test('remove() drops an agent; no-op when absent', () {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    final notifier = container.read(agentsProvider.notifier);
    notifier.upsert(_a1);
    notifier.upsert(_a2);

    notifier.remove('a1');
    expect(container.read(agentsProvider).keys, ['a2']);

    // No-op / no crash when key is absent.
    notifier.remove('does-not-exist');
    expect(container.read(agentsProvider).keys, ['a2']);
  });

  test('sortedAgentsProvider orders most-recent first', () {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    final notifier = container.read(agentsProvider.notifier);
    notifier.upsert(_a1);
    notifier.upsert(_a2);

    final sorted = container.read(sortedAgentsProvider);
    expect(sorted.map((a) => a.agentId).toList(), ['a2', 'a1']);
  });

  test('agentSummaryProvider looks up by id', () {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider.notifier).upsert(_a1);

    expect(container.read(agentSummaryProvider('a1')), _a1);
    expect(container.read(agentSummaryProvider('missing')), isNull);
  });

  test('selectedAgentProvider selects and clears', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(selectedAgentProvider), isNull);

    container.read(selectedAgentProvider.notifier).select('a1');
    expect(container.read(selectedAgentProvider), 'a1');

    container.read(selectedAgentProvider.notifier).select(null);
    expect(container.read(selectedAgentProvider), isNull);
  });

  group('AgentActions', () {
    test('create() requests agent.create and upserts the result', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.agentCreateRequest);
        expect(payload['cwd'], '/work/one');
        expect(payload['provider'], 'claude');
        expect(payload['model'], 'sonnet');
        expect(payload['mode'], 'normal');
        expect(payload['title'], 'My title');
        return {'agent': _a1.toJson()};
      };
      final container = makeContainer(client);

      final created = await container.read(agentActionsProvider).create(
            cwd: '/work/one',
            provider: 'claude',
            model: 'sonnet',
            mode: AgentMode.normal,
            title: 'My title',
          );

      expect(created.agentId, _a1.agentId);
      expect(created.title, _a1.title);
      expect(container.read(agentsProvider)['a1']?.agentId, 'a1');
    });

    test('create() omits an empty/null title', () async {
      final client = FakeDaemonClient();
      Map<String, Object?>? seenPayload;
      client.onRequest = (type, payload) {
        seenPayload = payload;
        return {'agent': _a1.toJson()};
      };
      final container = makeContainer(client);

      await container.read(agentActionsProvider).create(
            cwd: '/work/one',
            provider: 'claude',
            model: 'sonnet',
            mode: AgentMode.normal,
          );

      expect(seenPayload!.containsKey('title'), isFalse);
    });

    test('prompt() sends agentId and text', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);

      await container.read(agentActionsProvider).prompt('a1', 'hello');

      final (type, payload) = client.requests.single;
      expect(type, MessageTypes.agentPromptRequest);
      expect(payload, <String, Object?>{'agentId': 'a1', 'text': 'hello'});
    });

    test('interrupt() sends agentId', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);

      await container.read(agentActionsProvider).interrupt('a1');

      final (type, payload) = client.requests.single;
      expect(type, MessageTypes.agentInterruptRequest);
      expect(payload, <String, Object?>{'agentId': 'a1'});
    });

    test('archive() removes the agent and does not touch terminals '
        'that were never opened', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);
      container.read(agentsProvider.notifier).upsert(_a1);

      await container.read(agentActionsProvider).archive('a1');

      expect(container.read(agentsProvider).containsKey('a1'), isFalse);
      expect(
        client.requests.any(
          (r) => r.$1 == MessageTypes.agentArchiveRequest,
        ),
        isTrue,
      );
    });

    test('respondPermission() sends permissionId and decision', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);

      await container
          .read(agentActionsProvider)
          .respondPermission('perm-1', 'allow');

      final (type, payload) = client.requests.single;
      expect(type, MessageTypes.permissionRespondRequest);
      expect(
        payload,
        <String, Object?>{'permissionId': 'perm-1', 'decision': 'allow'},
      );
    });
  });
}
