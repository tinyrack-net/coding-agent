import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake daemon that answers Paseo v2 timeline page requests from a scriptable
/// queue and lets tests push legacy-compatible `agent.stream` events directly.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    DaemonConnectionState initial = DaemonConnectionState.connected,
  }) : _state = initial,
       super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final nativeEventsController =
      StreamController<AgentStreamPayload>.broadcast();
  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState _state;
  final fetchRequests = <Map<String, Object?>>[];
  final List<TimelineFetchResponse> fetchResponses = [];
  final List<Object> fetchErrors = [];
  final List<bool> hasOlderResponses = [];
  final List<bool> hasNewerResponses = [];
  Completer<void>? nextFetchGate;

  @override
  Stream<RpcEvent> get events => eventsController.stream;

  @override
  Stream<AgentStreamPayload> get agentStreamEvents =>
      nativeEventsController.stream;

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
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    fetchRequests.add(message);
    final gate = nextFetchGate;
    if (gate != null) {
      nextFetchGate = null;
      await gate.future;
    }
    if (fetchErrors.isNotEmpty) throw fetchErrors.removeAt(0);
    final response = fetchResponses.isEmpty
        ? const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: [])
        : fetchResponses.removeAt(0);
    final firstSeq = response.items.isEmpty
        ? null
        : response.lastSeq - response.items.length + 1;
    return {
      'type': AgentTimelinePage.responseType,
      'payload': {
        'requestId': message['requestId'],
        'agentId': message['agentId'],
        'agent': null,
        'direction': message['direction'] ?? 'tail',
        'projection': message['projection'] ?? 'projected',
        'epoch': response.epoch.toString(),
        'reset': false,
        'staleCursor': false,
        'gap': false,
        'window': {
          'minSeq': firstSeq ?? 0,
          'maxSeq': response.lastSeq,
          'nextSeq': response.lastSeq + 1,
        },
        'startCursor': firstSeq == null
            ? null
            : {'epoch': response.epoch.toString(), 'seq': firstSeq},
        'endCursor': firstSeq == null
            ? null
            : {'epoch': response.epoch.toString(), 'seq': response.lastSeq},
        'hasOlder': hasOlderResponses.isEmpty
            ? false
            : hasOlderResponses.removeAt(0),
        'hasNewer': hasNewerResponses.isEmpty
            ? false
            : hasNewerResponses.removeAt(0),
        'entries': [
          for (var index = 0; index < response.items.length; index++)
            {
              'provider': 'codex',
              'item': PaseoTimelineCodec.encode(response.items[index]),
              'timestamp': '2026-07-28T00:00:00.000Z',
              'seqStart': firstSeq! + index,
              'seqEnd': firstSeq + index,
              'sourceSeqRanges': [
                {'startSeq': firstSeq + index, 'endSeq': firstSeq + index},
              ],
              'collapsed': <Object?>[],
            },
        ],
        'error': null,
      },
    };
  }
}

class HostTimelineClient extends FakeDaemonClient {
  @override
  Future<void> connect() async {}
}

class TimelineHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      timelineHost('server-a', 'a.example:7001'),
      timelineHost('server-b', 'b.example:7002'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

const _msg1 = UserMessageItem(id: 'm1', text: 'hello');
const _msg2 = AssistantMessageItem(id: 'm2', text: 'hi there', complete: true);
const _image = AttachmentMetadata(
  id: 'image-1',
  mimeType: 'image/png',
  storageType: AttachmentStorageType.desktopFile,
  storageKey: 'image-1',
  createdAt: 1,
);

OptimisticUserMessage optimistic({
  String id = 'client-message',
  String text = 'typed text',
}) => OptimisticUserMessage(
  id: id,
  text: text,
  timestamp: 123,
  images: const [_image],
  attachments: const [
    TextAgentAttachment(title: 'Context', text: 'attached context'),
  ],
);

ProviderContainer makeContainer(DaemonClient client) {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('build() does not fetch while disconnected', () async {
    final client = FakeDaemonClient(
      initial: DaemonConnectionState.disconnected,
    );
    final container = makeContainer(client);

    final state = container.read(timelineProvider('a1'));
    expect(state.items, isEmpty);
    expect(state.loading, isTrue);

    await Future<void>.delayed(Duration.zero);
    expect(client.fetchRequests, isEmpty);
  });

  test('build() fetches immediately when already connected', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(
          epoch: 1,
          lastSeq: 2,
          items: [_msg1, _msg2],
        ),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(timelineProvider('a1'));
    expect(state.loading, isFalse);
    expect(state.items.map((i) => i.id), ['m1', 'm2']);
    expect(state.epoch, '1');
    expect(state.lastSeq, 2);
    expect(client.fetchRequests.single.containsKey('epoch'), isFalse);
  });

  test('reconnecting triggers a fetch', () async {
    final client = FakeDaemonClient(initial: DaemonConnectionState.disconnected)
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    expect(client.fetchRequests, isEmpty);

    client.setState(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items, hasLength(1));
  });

  test(
    'authoritative catch-up exposes phase, retains error across live events, '
    'and clears it only after sync succeeds',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
        );
      final container = makeContainer(client);
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final gate = Completer<void>();
      client.nextFetchGate = gate;
      client.fetchErrors.add(StateError('catch-up failed'));
      client.setState(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      var state = container.read(timelineProvider('a1'));
      expect(state.items.map((item) => item.id), ['m1']);
      expect(state.catchUpPhase, TimelineCatchUpPhase.syncing);
      expect(state.syncError, isNull);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      state = container.read(timelineProvider('a1'));
      expect(state.items.map((item) => item.id), ['m1']);
      expect(state.catchUpPhase, TimelineCatchUpPhase.error);
      expect(state.syncError, contains('catch-up failed'));

      client.nativeEventsController.add(
        const AgentStreamPayload(agentId: 'a1', epoch: 0, seq: 2, item: _msg2),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(timelineProvider('a1')).syncError,
        contains('catch-up failed'),
      );

      client.fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 2, items: [_msg2]),
      );
      await container.read(timelineProvider('a1').notifier).retry();
      state = container.read(timelineProvider('a1'));
      expect(state.items.map((item) => item.id), ['m2']);
      expect(state.catchUpPhase, TimelineCatchUpPhase.idle);
      expect(state.syncError, isNull);
    },
  );

  test(
    'host selection restores independent retained timeline replicas',
    () async {
      final hostA = HostTimelineClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
        );
      final hostB = HostTimelineClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg2]),
        );
      final container = ProviderContainer(
        overrides: [
          hostRegistryProvider.overrideWith(TimelineHostRegistry.new),
          daemonClientFactoryProvider.overrideWithValue(
            (settings) => settings.host == 'a.example' ? hostA : hostB,
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(timelineProvider('a1')).items.map((item) => item.id),
        ['m1'],
      );

      await container
          .read(hostRegistryProvider.notifier)
          .selectHost('server-b');
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(timelineProvider('a1')).items.map((item) => item.id),
        ['m2'],
      );

      await container
          .read(hostRegistryProvider.notifier)
          .selectHost('server-a');
      expect(
        container.read(timelineProvider('a1')).items.map((item) => item.id),
        ['m1'],
      );
      final replicas = container.read(timelineReplicaStoreProvider);
      expect(replicas.keys.map((key) => (key.serverId, key.agentId)).toSet(), {
        ('server-a', 'a1'),
        ('server-b', 'a1'),
      });
    },
  );

  test('removing a host clears only its retained timeline replicas', () async {
    final container = ProviderContainer(
      overrides: [hostRegistryProvider.overrideWith(TimelineHostRegistry.new)],
    );
    addTearDown(container.dispose);
    container.read(timelineReplicaLifecycleProvider);
    final store = container.read(timelineReplicaStoreProvider.notifier);
    store
      ..write(
        const TimelineReplicaKey(serverId: 'server-a', agentId: 'a1'),
        const TimelineState(loading: false),
      )
      ..write(
        const TimelineReplicaKey(serverId: 'server-b', agentId: 'a1'),
        const TimelineState(loading: false),
      );

    await container.read(hostRegistryProvider.notifier).removeHost('server-a');

    expect(container.read(timelineReplicaStoreProvider).keys, {
      const TimelineReplicaKey(serverId: 'server-b', agentId: 'a1'),
    });
  });

  test(
    'in-epoch stream event with seq == lastSeq+1 upserts directly',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
        );
      final container = makeContainer(client);
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(client.fetchRequests, hasLength(1));

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: const AgentStreamPayload(
            agentId: 'a1',
            epoch: 0,
            seq: 2,
            item: _msg2,
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      expect(state.items.map((i) => i.id), ['m1', 'm2']);
      expect(state.lastSeq, 2);
      // No re-fetch needed for a contiguous seq.
      expect(client.fetchRequests, hasLength(1));
    },
  );

  test(
    'native v2 stream upserts and preserves permission request detail',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
        );
      final container = makeContainer(client);
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      client.nativeEventsController.add(
        const AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 1,
          item: PermissionItem(
            id: 'perm_permission-1',
            permissionId: 'permission-1',
            toolName: 'shell',
            status: PermissionStatus.pending,
            detail: ShellDetail(command: 'rm file'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      client.nativeEventsController.add(
        const AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 2,
          item: PermissionItem(
            id: 'perm_permission-1',
            permissionId: 'permission-1',
            toolName: '',
            status: PermissionStatus.denied,
            detail: GenericDetail(input: {}),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final permission = container
          .read(timelineProvider('a1'))
          .items
          .whereType<PermissionItem>()
          .single;
      expect(permission.status, PermissionStatus.denied);
      expect(permission.toolName, 'shell');
      expect(permission.detail, isA<ShellDetail>());
    },
  );

  test('events for other agents are ignored', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: const AgentStreamPayload(
          agentId: 'other-agent',
          epoch: 0,
          seq: 1,
          item: _msg1,
        ).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items, isEmpty);
  });

  test('a seq gap triggers an incremental re-fetch', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // seq 5 skips 2..4: a gap, triggers _fetch() (incremental).
    client.fetchResponses.add(
      const TimelineFetchResponse(epoch: 0, lastSeq: 5, items: [_msg2]),
    );
    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: const AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 5,
          item: _msg2,
        ).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.fetchRequests, hasLength(2));
    expect(client.fetchRequests.last['direction'], 'after');
    expect(client.fetchRequests.last['cursor'], {'epoch': '0', 'seq': 1});
    final state = container.read(timelineProvider('a1'));
    expect(state.items.map((i) => i.id), ['m1', 'm2']);
    expect(state.lastSeq, 5);
  });

  test(
    'an epoch change triggers a full refetch that replaces the snapshot',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
        );
      final container = makeContainer(client);
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      client.fetchResponses.add(
        const TimelineFetchResponse(epoch: 1, lastSeq: 1, items: [_msg2]),
      );
      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: const AgentStreamPayload(
            agentId: 'a1',
            epoch: 1,
            seq: 1,
            item: _msg2,
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      // Full snapshot: only the new epoch's items remain.
      expect(state.items.map((i) => i.id), ['m2']);
      expect(state.epoch, '1');
    },
  );

  test('a stream event before any successful fetch (epoch < 0) triggers '
      'a fetch instead of upserting directly', () async {
    final client = FakeDaemonClient(
      initial: DaemonConnectionState.disconnected,
    );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    expect(container.read(timelineProvider('a1')).epoch, isNull);

    client.fetchResponses.add(
      const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
    );
    client.eventsController.add(
      RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: const AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: 1,
          item: _msg1,
        ).toJson(),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items.map((i) => i.id), [
      'm1',
    ]);
  });

  test('malformed agent.stream event is ignored', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    client.eventsController.add(
      const RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: {'agentId': 'a1'}, // missing required `item`
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items, isEmpty);
  });

  test(
    'request failure stops loading and exposes the recovery error',
    () async {
      final client = _ThrowingDaemonClient();
      final container = makeContainer(client);
      container.read(timelineProvider('a1'));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      expect(state.loading, isFalse);
      expect(state.error, contains('boom'));
    },
  );

  test('loadOlder prepends a before page and widens the cursor', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 2, items: [_msg2]),
      )
      ..hasOlderResponses.addAll([true, false]);
    final container = makeContainer(client);
    final notifier = container.read(timelineProvider('a1').notifier);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    client.fetchResponses.add(
      const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
    );
    expect(await notifier.loadOlder(), isTrue);

    final state = container.read(timelineProvider('a1'));
    expect(state.items.map((item) => item.id), ['m1', 'm2']);
    expect(state.cursor?.startSeq, 1);
    expect(state.cursor?.endSeq, 2);
    expect(state.hasOlder, isFalse);
    expect(client.fetchRequests.last['direction'], 'before');
    expect(client.fetchRequests.last['cursor'], {'epoch': '0', 'seq': 2});
  });

  test(
    'before-page overlap updates the existing projected item once',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 2, items: [_msg2]),
        )
        ..hasOlderResponses.addAll([true, false]);
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      client.fetchResponses.add(
        const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 2,
          items: [
            _msg1,
            AssistantMessageItem(
              id: 'm2',
              text: 'updated overlap',
              complete: true,
            ),
          ],
        ),
      );
      expect(await notifier.loadOlder(), isTrue);

      final state = container.read(timelineProvider('a1'));
      expect(state.items.map((item) => item.id), ['m1', 'm2']);
      expect(
        (state.items.last as AssistantMessageItem).text,
        'updated overlap',
      );
    },
  );

  test(
    'optimistic rows move from tail placement to active head placement',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
        );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        notifier.appendOptimisticUserMessage(
          optimistic(id: 'tail-pending', text: 'tail'),
        ),
        isTrue,
      );
      expect(
        container
            .read(timelineProvider('a1'))
            .pendingTailUserMessages
            .single
            .id,
        'tail-pending',
      );

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: const AgentStreamPayload(
            agentId: 'a1',
            epoch: 0,
            seq: 2,
            item: AssistantMessageItem(
              id: 'head-live',
              text: 'live',
              complete: true,
            ),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        notifier.appendOptimisticUserMessage(
          optimistic(id: 'head-pending', text: 'head'),
        ),
        isTrue,
      );
      expect(
        container
            .read(timelineProvider('a1'))
            .pendingHeadUserMessages
            .single
            .id,
        'head-pending',
      );
      expect(
        container
            .read(timelineProvider('a1'))
            .displayItems
            .map((item) => item.item.id),
        ['m1', 'tail-pending', 'head-live', 'head-pending'],
      );
    },
  );

  test('timelineCountProvider reflects the item count', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 2,
          items: [_msg1, _msg2],
        ),
      );
    final container = makeContainer(client);
    expect(container.read(timelineCountProvider('a1')), 0);

    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineCountProvider('a1')), 2);
  });

  test(
    'optimistic append is idempotent and rollback releases image ownership',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
        );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.appendOptimisticUserMessage(optimistic()), isTrue);
      expect(notifier.appendOptimisticUserMessage(optimistic()), isFalse);
      final state = container.read(timelineProvider('a1'));
      expect(state.items, isEmpty);
      expect(state.displayItems.single.item.id, 'client-message');
      expect(state.displayItems.single.userMessage?.images, const [_image]);
      expect(
        container
            .read(timelineAttachmentOwnersProvider.notifier)
            .attachmentIds(),
        {'image-1'},
      );
      expect(notifier.removeOptimisticUserMessage('missing'), isFalse);
      expect(notifier.removeOptimisticUserMessage('client-message'), isTrue);
      expect(container.read(timelineProvider('a1')).displayItems, isEmpty);
      expect(
        container
            .read(timelineAttachmentOwnersProvider.notifier)
            .attachmentIds(),
        isEmpty,
      );
    },
  );

  test(
    'live canonical user echo replaces the first optimistic FIFO item',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
        );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      notifier
        ..appendOptimisticUserMessage(
          optimistic(id: 'first', text: 'first text'),
        )
        ..appendOptimisticUserMessage(
          optimistic(id: 'second', text: 'second text'),
        );

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: const AgentStreamPayload(
            agentId: 'a1',
            epoch: 0,
            seq: 1,
            item: UserMessageItem(id: 'provider-first', text: 'rendered'),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      expect(state.items.single.id, 'provider-first');
      expect(state.pendingUserMessages.single.id, 'second');
      expect(
        state.userMessagePresentations['provider-first']?.text,
        'first text',
      );
      expect(state.displayItems.map((display) => display.userMessage?.text), [
        'first text',
        'second text',
      ]);
    },
  );

  test(
    'clientMessageId reconciles the matching optimistic item before FIFO',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
        );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      notifier
        ..appendOptimisticUserMessage(
          optimistic(id: 'first', text: 'first text'),
        )
        ..appendOptimisticUserMessage(
          optimistic(id: 'second', text: 'second text'),
        );

      client.eventsController.add(
        RpcEvent(
          type: MessageTypes.agentStreamEvent,
          payload: const AgentStreamPayload(
            agentId: 'a1',
            epoch: 0,
            seq: 1,
            item: UserMessageItem(
              id: 'provider-second',
              clientMessageId: 'second',
              text: 'rendered',
            ),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      expect(state.pendingUserMessages.single.id, 'first');
      expect(
        state.userMessagePresentations['provider-second']?.text,
        'second text',
      );
      expect(state.displayItems.map((display) => display.userMessage?.text), [
        'second text',
        'first text',
      ]);
    },
  );

  test(
    'canonical fetch matches optimistic content by clientMessageId',
    () async {
      final client = FakeDaemonClient(
        initial: DaemonConnectionState.disconnected,
      );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      notifier.appendOptimisticUserMessage(
        optimistic(id: 'same-id', text: 'local rich text'),
      );
      client.fetchResponses.add(
        const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 1,
          items: [
            UserMessageItem(
              id: 'provider-id',
              clientMessageId: 'same-id',
              text: 'server text',
            ),
          ],
        ),
      );

      client.setState(DaemonConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(timelineProvider('a1'));
      expect(state.pendingUserMessages, isEmpty);
      expect(state.items.single.id, 'provider-id');
      expect(
        state.userMessagePresentations['provider-id']?.text,
        'local rich text',
      );
      expect(state.attachmentIds, {'image-1'});
    },
  );

  test(
    'created message handoff enriches the first canonical user once',
    () async {
      final client = FakeDaemonClient()
        ..fetchResponses.add(
          const TimelineFetchResponse(
            epoch: 0,
            lastSeq: 1,
            items: [UserMessageItem(id: 'provider-user', text: 'server text')],
          ),
        );
      final container = makeContainer(client);
      final notifier = container.read(timelineProvider('a1').notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final message = optimistic(text: '');
      expect(notifier.handoffCreatedUserMessage(message), isTrue);
      expect(notifier.handoffCreatedUserMessage(message), isFalse);
      final state = container.read(timelineProvider('a1'));
      expect(state.items, hasLength(1));
      expect(state.pendingUserMessages, isEmpty);
      expect(state.userMessagePresentations['provider-user']?.images, const [
        _image,
      ]);
      notifier.appendOptimisticUserMessage(
        optimistic(id: 'clear-me', text: 'pending'),
      );
      notifier.clearOptimisticUserMessages();
      expect(container.read(timelineProvider('a1')).displayItems, hasLength(1));
    },
  );
}

class _ThrowingDaemonClient extends DaemonClient {
  _ThrowingDaemonClient() : super(uri: Uri.parse('ws://fake'));

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    throw StateError('boom');
  }
}

HostProfile timelineHost(String serverId, String endpoint) => HostProfile(
  serverId: serverId,
  label: serverId,
  connections: [
    DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
  ],
  preferredConnectionId: 'direct:$endpoint',
  createdAt: '2026-07-28T00:00:00.000Z',
  updatedAt: '2026-07-28T00:00:00.000Z',
);
