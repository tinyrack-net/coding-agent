import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/providers/agent_commands.dart';
import 'package:coding_agent_app/state/agent_commands_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _command = AgentSlashCommand(
  name: 'review',
  description: 'Review changes',
  argumentHint: '<path>',
  kind: AgentSlashCommandKind.skill,
);

final class _CommandsClient extends DaemonClient {
  _CommandsClient() : super(uri: Uri.parse('ws://fake'));

  final connections = StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState current = DaemonConnectionState.connected;
  int calls = 0;
  String? error;
  ListCommandsDraftConfig? lastDraft;

  @override
  DaemonConnectionState get currentState => current;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls++;
    lastDraft = draftConfig;
    return ListCommandsResponse(
      agentId: agentId,
      commands: error == null ? const [_command] : const [],
      requestId: 'request-$calls',
      error: error,
    );
  }

  @override
  void dispose() {
    connections.close();
    super.dispose();
  }
}

void main() {
  test('builds stable session and draft query identities', () {
    final client = _CommandsClient();
    addTearDown(client.dispose);
    final session = AgentCommandsScope(
      client: client,
      serverId: 'server-1',
      agentId: 'agent-1',
    );
    final draft = AgentCommandsScope(
      client: client,
      serverId: 'server-1',
      agentId: 'draft-a',
      draftConfig: const ListCommandsDraftConfig(
        provider: 'codex',
        cwd: r'C:\repo\\',
        model: 'gpt-5.4',
        featureValues: {'fast_mode': true},
      ),
    );
    final equivalentDraft = AgentCommandsScope(
      client: client,
      serverId: 'server-1',
      agentId: 'draft-b',
      draftConfig: const ListCommandsDraftConfig(
        provider: 'codex',
        cwd: 'C:/repo',
        model: 'gpt-5.4',
        featureValues: {'fast_mode': true},
      ),
    );

    expect(session.queryRoot, ['agentCommands', 'server-1']);
    expect(session.queryKey, [
      'agentCommands',
      'server-1',
      'session',
      'agent-1',
    ]);
    expect(draft.queryKey, containsAllInOrder(['draft', 'codex', 'C:/repo']));
    expect(draft, equivalentDraft);
  });

  test('loads, caches, invalidates, reconnects, and reports errors', () async {
    final client = _CommandsClient();
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scope = AgentCommandsScope(
      client: client,
      serverId: 'server-1',
      agentId: 'agent-1',
    );
    final provider = agentCommandsProvider(scope);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final notifier = container.read(provider.notifier);

    await notifier.ensureLoaded();
    expect(container.read(provider).commands, const [_command]);
    expect(client.calls, 1);
    await notifier.ensureLoaded();
    expect(client.calls, 1);

    invalidateAgentCommandsForServer('server-1');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.calls, 2);

    client.connections.add(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.calls, 3);

    client.error = 'provider failed';
    await notifier.fetch(force: true);
    expect(container.read(provider).isError, isTrue);
    expect('${container.read(provider).error}', contains('provider failed'));
  });

  test(
    'draft cache is infinite and disconnected or disabled queries gate',
    () async {
      final client = _CommandsClient();
      addTearDown(client.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const config = ListCommandsDraftConfig(
        provider: 'codex',
        cwd: 'C:/repo',
        model: 'gpt-5.4',
      );
      final draft = agentCommandsProvider(
        AgentCommandsScope(
          client: client,
          serverId: 'server-1',
          agentId: '__new_agent__',
          draftConfig: config,
        ),
      );
      final subscription = container.listen(draft, (_, _) {});
      addTearDown(subscription.close);
      await container.read(draft.notifier).ensureLoaded();
      await container.read(draft.notifier).ensureLoaded();
      expect(client.calls, 1);
      expect(client.lastDraft?.model, 'gpt-5.4');

      client.current = DaemonConnectionState.disconnected;
      final disconnected = agentCommandsProvider(
        AgentCommandsScope(
          client: client,
          serverId: 'server-1',
          agentId: 'agent-2',
        ),
      );
      final disconnectedSubscription = container.listen(
        disconnected,
        (_, _) {},
      );
      addTearDown(disconnectedSubscription.close);
      await container.read(disconnected.notifier).ensureLoaded();
      expect(client.calls, 1);

      final disabled = agentCommandsProvider(
        AgentCommandsScope(
          client: client,
          serverId: 'server-1',
          agentId: 'agent-3',
          enabled: false,
        ),
      );
      expect(container.read(disabled).isLoading, isFalse);
    },
  );
}
