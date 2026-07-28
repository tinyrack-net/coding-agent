import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/desktop/desktop_shell.dart';
import 'package:coding_agent_app/core/desktop/notification_service.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records `notify()` calls instead of touching the real `local_notifier`
/// platform channel (unavailable/flaky in `flutter test`).
class FakeNotificationService extends NotificationService {
  final calls = <({String title, String body})>[];

  @override
  void notify({
    required String title,
    required String body,
    VoidCallback? onClick,
  }) {
    calls.add((title: title, body: body));
  }
}

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
  final directoryEventsController =
      StreamController<DirectoryUpdateEvent>.broadcast();
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
  Stream<DirectoryUpdateEvent> get directoryUpdateEvents =>
      directoryEventsController.stream;

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

  @override
  Future<FetchAgentsResponse> fetchAgents({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    bool subscribe = false,
    String? subscriptionId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((
      FetchAgentsRequest.type,
      {
        'limit': limit,
        'cursor': cursor,
        'subscribe': subscribe,
        'subscriptionId': subscriptionId,
      },
    ));
    final error = requestError;
    if (error != null) throw error;
    final result =
        onRequest?.call(MessageTypes.agentListRequest, const {}) ?? const {};
    final agents = ((result['agents'] as List?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(AgentSummary.fromJson);
    return FetchAgentsResponse(
      requestId: 'fake',
      subscriptionId: subscribe ? 'fake-subscription' : null,
      entries: [
        for (final agent in agents)
          AgentDirectoryEntry(
            agent: agent,
            project: {
              'projectKey': agent.projectPath ?? agent.cwd,
              'projectName': 'Project',
              'workspaceName': agent.branch,
              'checkout': const <String, Object?>{},
            },
          ),
      ],
      pageInfo: const AgentDirectoryPageInfo(
        nextCursor: null,
        prevCursor: null,
        hasMore: false,
      ),
    );
  }
}

class HostAgentsClient extends FakeDaemonClient {
  HostAgentsClient(AgentSummary agent) {
    _state = DaemonConnectionState.connected;
    onRequest = (type, payload) => type == MessageTypes.agentListRequest
        ? {
            'agents': [agent.toJson()],
          }
        : const {};
  }

  @override
  Future<void> connect() async {}
}

class BlockingAgentListClient extends FakeDaemonClient {
  final requestStarted = Completer<void>();
  final response = Completer<FetchAgentsResponse>();

  @override
  Future<FetchAgentsResponse> fetchAgents({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    bool subscribe = false,
    String? subscriptionId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    requests.add((FetchAgentsRequest.type, {'cursor': cursor}));
    requestStarted.complete();
    return response.future;
  }
}

class PagedAgentListClient extends FakeDaemonClient {
  final cursors = <String?>[];
  final subscriptions = <bool>[];

  @override
  Future<FetchAgentsResponse> fetchAgents({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    bool subscribe = false,
    String? subscriptionId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    cursors.add(cursor);
    subscriptions.add(subscribe);
    final first = cursor == null;
    return FetchAgentsResponse(
      requestId: first ? 'first' : 'second',
      subscriptionId: first ? 'paged-subscription' : null,
      entries: [
        AgentDirectoryEntry(
          agent: first ? _a1 : _a2,
          project: const {
            'projectKey': '/work',
            'projectName': 'work',
            'checkout': <String, Object?>{},
          },
        ),
      ],
      pageInfo: AgentDirectoryPageInfo(
        nextCursor: first ? 'next' : null,
        prevCursor: first ? null : '0',
        hasMore: first,
      ),
    );
  }
}

class AgentsHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      _host('server-a', 'a.example:7001'),
      _host('server-b', 'b.example:7002'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

ProviderContainer makeContainer(
  FakeDaemonClient client, {
  NotificationService? notificationService,
}) {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      if (notificationService != null)
        notificationServiceProvider.overrideWithValue(notificationService),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  tearDown(() => windowFocusedNotifier.value = true);

  test(
    'host selection restores independent retained agent directories',
    () async {
      final hostA = HostAgentsClient(_a1);
      final hostB = HostAgentsClient(_a2);
      final container = ProviderContainer(
        overrides: [
          hostRegistryProvider.overrideWith(AgentsHostRegistry.new),
          daemonClientFactoryProvider.overrideWithValue(
            (settings) => settings.host == 'a.example' ? hostA : hostB,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(agentDirectoryReplicaLifecycleProvider);

      container.read(agentsProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(agentsProvider).keys, {'a1'});

      await container
          .read(hostRegistryProvider.notifier)
          .selectHost('server-b');
      container.read(agentsProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        hostB.requests.map((request) => request.$1),
        contains(FetchAgentsRequest.type),
      );
      expect(container.read(agentsProvider).keys, {'a2'});

      await container
          .read(hostRegistryProvider.notifier)
          .selectHost('server-a');
      expect(container.read(agentsProvider).keys, {'a1'});
      expect(container.read(agentDirectoryReplicaStoreProvider).keys, {
        'server-a',
        'server-b',
      });

      await container
          .read(hostRegistryProvider.notifier)
          .removeHost('server-a');
      expect(container.read(agentDirectoryReplicaStoreProvider).keys, {
        'server-b',
      });
    },
  );

  test('build() starts empty and does not fetch when disconnected', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);

    expect(container.read(agentsProvider), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(client.requests, isEmpty);
  });

  test('build() fetches immediately when already connected', () async {
    final client = FakeDaemonClient().._state = DaemonConnectionState.connected;
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

  test('native refresh exhausts pages and subscribes only once', () async {
    final client = PagedAgentListClient()
      .._state = DaemonConnectionState.connected;
    final container = makeContainer(client);
    container.read(agentsProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.cursors, [null, 'next']);
    expect(client.subscriptions, [true, false]);
    expect(container.read(agentsProvider).keys, containsAll(['a1', 'a2']));
  });

  test('agent.state event upserts the agent', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: AgentStatePayload(agent: _a1).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider)['a1']?.runState, AgentRunState.idle);

    final updated = _a1.copyWith(runState: AgentRunState.running);
    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: AgentStatePayload(agent: updated).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(agentsProvider)['a1']?.runState,
      AgentRunState.running,
    );
  });

  test('agent.state event removes an archived agent', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider.notifier).upsert(_a1);

    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: AgentStatePayload(
          agent: _a1.copyWith(archivedAt: '2026-07-26T00:00:00.000Z'),
        ).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(agentsProvider), isEmpty);
  });

  test('native agent directory lifecycle updates the active replica', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.directoryEventsController.add(
      const AgentUpsertDirectoryEvent(agent: _a1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(agentsProvider)['a1'], _a1);

    client.directoryEventsController.add(
      const AgentArchivedDirectoryEvent(
        agentId: 'a1',
        archivedAt: '2026-07-28T00:00:00.000Z',
        requestId: 'archive-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(agentsProvider), isEmpty);
  });

  test(
    'buffers native agent updates behind an authoritative refresh',
    () async {
      final client = BlockingAgentListClient()
        .._state = DaemonConnectionState.connected;
      final container = makeContainer(client);
      container.read(agentsProvider);
      await client.requestStarted.future;

      client.directoryEventsController.add(
        const AgentUpsertDirectoryEvent(agent: _a2),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(agentsProvider), isEmpty);

      client.response.complete(
        const FetchAgentsResponse(
          requestId: 'blocking',
          subscriptionId: 'blocking-subscription',
          entries: [
            AgentDirectoryEntry(
              agent: _a1,
              project: {
                'projectKey': '/work/one',
                'projectName': 'one',
                'checkout': <String, Object?>{},
              },
            ),
          ],
          pageInfo: AgentDirectoryPageInfo(
            nextCursor: null,
            prevCursor: null,
            hasMore: false,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(agentsProvider).keys, containsAll(['a1', 'a2']));
    },
  );

  group('OS notifications on run-state transitions', () {
    test('does not notify on the first sighting of an agent', () async {
      windowFocusedNotifier.value = false;
      final client = FakeDaemonClient();
      final notifications = FakeNotificationService();
      final container = makeContainer(
        client,
        notificationService: notifications,
      );
      container.read(agentsProvider);

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(agent: _a1).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.calls, isEmpty);
    });

    test('notifies once when an agent transitions into awaitingPermission '
        'while the window is unfocused', () async {
      windowFocusedNotifier.value = false;
      final client = FakeDaemonClient();
      final notifications = FakeNotificationService();
      final container = makeContainer(
        client,
        notificationService: notifications,
      );
      container.read(agentsProvider.notifier).upsert(_a1);

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(
            agent: _a1.copyWith(runState: AgentRunState.awaitingPermission),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.calls, hasLength(1));
      expect(notifications.calls.single.title, 'First');
      expect(notifications.calls.single.body, 'Needs your input');
    });

    test('notifies once when a running agent finishes (running -> idle) '
        'while the window is unfocused', () async {
      windowFocusedNotifier.value = false;
      final client = FakeDaemonClient();
      final notifications = FakeNotificationService();
      final container = makeContainer(
        client,
        notificationService: notifications,
      );
      container
          .read(agentsProvider.notifier)
          .upsert(_a1.copyWith(runState: AgentRunState.running));

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(
            agent: _a1.copyWith(runState: AgentRunState.idle),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.calls, hasLength(1));
      expect(notifications.calls.single.body, 'Finished');
    });

    test('notifies once when a running agent errors (running -> error) '
        'while the window is unfocused', () async {
      windowFocusedNotifier.value = false;
      final client = FakeDaemonClient();
      final notifications = FakeNotificationService();
      final container = makeContainer(
        client,
        notificationService: notifications,
      );
      container
          .read(agentsProvider.notifier)
          .upsert(_a1.copyWith(runState: AgentRunState.running));

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(
            agent: _a1.copyWith(runState: AgentRunState.error),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.calls, hasLength(1));
      expect(notifications.calls.single.body, 'Hit an error');
    });

    test('does not notify while the window is focused', () async {
      windowFocusedNotifier.value = true;
      final client = FakeDaemonClient();
      final notifications = FakeNotificationService();
      final container = makeContainer(
        client,
        notificationService: notifications,
      );
      container
          .read(agentsProvider.notifier)
          .upsert(_a1.copyWith(runState: AgentRunState.running));

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStateEvent,
          payload: AgentStatePayload(
            agent: _a1.copyWith(runState: AgentRunState.idle),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.calls, isEmpty);
    });
  });

  test('malformed agent.state event is ignored', () async {
    final client = FakeDaemonClient();
    final container = makeContainer(client);
    container.read(agentsProvider);

    client.eventsController.add(
      const RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: {'agent': 'not-a-map-shape'},
      ),
    );
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

  group('AgentActions', () {
    test('create() requests agent.create and upserts the result', () async {
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.agentCreateRequest);
        expect(payload['cwd'], '/work/one');
        expect(payload['provider'], 'claude');
        expect(payload['model'], 'sonnet');
        expect(payload['mode'], 'normal');
        expect(payload['modeId'], 'auto');
        expect(payload['thinkingOptionId'], 'high');
        expect(payload['features'], {'fast_mode': true});
        expect(payload['title'], 'My title');
        expect(payload['workspaceId'], 'wks_1');
        expect(payload['parentAgentId'], 'parent');
        expect(payload['initialPrompt'], 'Start here');
        expect(payload['clientMessageId'], 'client-1');
        expect(payload['images'], [
          {'data': 'png', 'mimeType': 'image/png'},
        ]);
        expect(payload['attachments'], [
          {
            'type': 'text',
            'mimeType': 'text/plain',
            'title': 'Context',
            'text': 'Details',
          },
        ]);
        return {'agent': _a1.toJson()};
      };
      final container = makeContainer(client);

      final created = await container
          .read(agentActionsProvider)
          .create(
            cwd: '/work/one',
            provider: 'claude',
            model: 'sonnet',
            mode: AgentMode.normal,
            modeId: 'auto',
            thinkingOptionId: 'high',
            featureValues: const {'fast_mode': true},
            title: 'My title',
            workspaceId: 'wks_1',
            parentAgentId: 'parent',
            initialPrompt: 'Start here',
            clientMessageId: 'client-1',
            images: const [
              AgentPromptImage(data: 'png', mimeType: 'image/png'),
            ],
            attachments: const [
              TextAgentAttachment(title: 'Context', text: 'Details'),
            ],
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

      await container
          .read(agentActionsProvider)
          .create(
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

    test('prompt() forwards the optimistic client message id', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);

      await container
          .read(agentActionsProvider)
          .prompt('a1', 'hello', clientMessageId: 'client-1');

      final (type, payload) = client.requests.single;
      expect(type, MessageTypes.agentPromptRequest);
      expect(payload, <String, Object?>{
        'agentId': 'a1',
        'text': 'hello',
        'clientMessageId': 'client-1',
      });
    });

    test('rename() requests agent.rename and upserts the result', () async {
      final client = FakeDaemonClient();
      final renamed = _a1.copyWith(title: 'New title');
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.agentRenameRequest);
        expect(payload, <String, Object?>{
          'agentId': 'a1',
          'title': 'New title',
        });
        return {'agent': renamed.toJson()};
      };
      final container = makeContainer(client);

      final result = await container
          .read(agentActionsProvider)
          .rename('a1', 'New title');

      expect(result.title, 'New title');
      expect(container.read(agentsProvider)['a1']?.title, 'New title');
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
        client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
        isTrue,
      );
    });

    test('detach() requests agent.detach and upserts the result', () async {
      final child = _a1.copyWith(parentAgentId: 'parent');
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.agentDetachRequest);
        expect(payload, <String, Object?>{'agentId': 'a1'});
        return {'agent': child.copyWith(clearParentAgentId: true).toJson()};
      };
      final container = makeContainer(client);
      container.read(agentsProvider.notifier).upsert(child);

      final detached = await container.read(agentActionsProvider).detach('a1');

      expect(detached.parentAgentId, isNull);
      expect(container.read(agentsProvider)['a1']?.parentAgentId, isNull);
    });

    test('clearAttention() requests clear and upserts the result', () async {
      final attention = _a1.copyWith(
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
        attentionTimestamp: '2026-07-26T00:00:00.000Z',
      );
      final client = FakeDaemonClient();
      client.onRequest = (type, payload) {
        expect(type, MessageTypes.agentAttentionClearRequest);
        expect(payload, <String, Object?>{'agentId': 'a1'});
        return {
          'agent': attention
              .copyWith(requiresAttention: false, clearAttention: true)
              .toJson(),
        };
      };
      final container = makeContainer(client);
      container.read(agentsProvider.notifier).upsert(attention);

      final cleared = await container
          .read(agentActionsProvider)
          .clearAttention('a1');

      expect(cleared.requiresAttention, isFalse);
      expect(cleared.attentionReason, isNull);
      expect(container.read(agentsProvider)['a1']?.requiresAttention, isFalse);
    });

    test('respondPermission() sends permissionId and decision', () async {
      final client = FakeDaemonClient();
      final container = makeContainer(client);

      await container
          .read(agentActionsProvider)
          .respondPermission('perm-1', 'allow');

      final (type, payload) = client.requests.single;
      expect(type, MessageTypes.permissionRespondRequest);
      expect(payload, <String, Object?>{
        'permissionId': 'perm-1',
        'decision': 'allow',
      });
    });
  });
}

HostProfile _host(String serverId, String endpoint) => HostProfile(
  serverId: serverId,
  label: serverId,
  connections: [
    DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
  ],
  preferredConnectionId: 'direct:$endpoint',
  createdAt: '2026-07-28T00:00:00.000Z',
  updatedAt: '2026-07-28T00:00:00.000Z',
);
