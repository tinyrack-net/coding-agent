import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake daemon that answers `agent.timeline.fetch.request` from a scriptable
/// queue of responses and lets tests push `agent.stream` events directly.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({DaemonConnectionState initial = DaemonConnectionState.connected})
      : _state = initial,
        super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState _state;
  final fetchRequests = <Map<String, Object?>>[];
  final List<TimelineFetchResponse> fetchResponses = [];

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
    if (type != MessageTypes.agentTimelineFetchRequest) return const {};
    fetchRequests.add(payload);
    if (fetchResponses.isEmpty) return const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []).toJson();
    return fetchResponses.removeAt(0).toJson();
  }
}

const _msg1 = UserMessageItem(id: 'm1', text: 'hello');
const _msg2 = AssistantMessageItem(id: 'm2', text: 'hi there', complete: true);

ProviderContainer makeContainer(DaemonClient client) {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('build() does not fetch while disconnected', () async {
    final client = FakeDaemonClient(initial: DaemonConnectionState.disconnected);
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
        const TimelineFetchResponse(epoch: 1, lastSeq: 2, items: [_msg1, _msg2]),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(timelineProvider('a1'));
    expect(state.loading, isFalse);
    expect(state.items.map((i) => i.id), ['m1', 'm2']);
    expect(state.epoch, 1);
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

  test('in-epoch stream event with seq == lastSeq+1 upserts directly',
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

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 2,
        item: _msg2,
      ).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);

    final state = container.read(timelineProvider('a1'));
    expect(state.items.map((i) => i.id), ['m1', 'm2']);
    expect(state.lastSeq, 2);
    // No re-fetch needed for a contiguous seq.
    expect(client.fetchRequests, hasLength(1));
  });

  test('events for other agents are ignored', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 0, items: []),
      );
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'other-agent',
        epoch: 0,
        seq: 1,
        item: _msg1,
      ).toJson(),
    ));
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
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 5,
        item: _msg2,
      ).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.fetchRequests, hasLength(2));
    expect(client.fetchRequests.last['afterSeq'], 1);
    final state = container.read(timelineProvider('a1'));
    expect(state.items.map((i) => i.id), ['m1', 'm2']);
    expect(state.lastSeq, 5);
  });

  test('an epoch change triggers a full refetch that replaces the snapshot',
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
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 1,
        seq: 1,
        item: _msg2,
      ).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(timelineProvider('a1'));
    // Full snapshot: only the new epoch's items remain.
    expect(state.items.map((i) => i.id), ['m2']);
    expect(state.epoch, 1);
  });

  test('a stream event before any successful fetch (epoch < 0) triggers '
      'a fetch instead of upserting directly', () async {
    final client = FakeDaemonClient(initial: DaemonConnectionState.disconnected);
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    expect(container.read(timelineProvider('a1')).epoch, -1);

    client.fetchResponses.add(
      const TimelineFetchResponse(epoch: 0, lastSeq: 1, items: [_msg1]),
    );
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 1,
        item: _msg1,
      ).toJson(),
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items.map((i) => i.id), ['m1']);
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

    client.eventsController.add(const RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: {'agentId': 'a1'}, // missing required `item`
    ));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).items, isEmpty);
  });

  test('request failure during fetch leaves state as loading, no crash',
      () async {
    final client = _ThrowingDaemonClient();
    final container = makeContainer(client);
    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineProvider('a1')).loading, isTrue);
  });

  test('timelineCountProvider reflects the item count', () async {
    final client = FakeDaemonClient()
      ..fetchResponses.add(
        const TimelineFetchResponse(epoch: 0, lastSeq: 2, items: [_msg1, _msg2]),
      );
    final container = makeContainer(client);
    expect(container.read(timelineCountProvider('a1')), 0);

    container.read(timelineProvider('a1'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(timelineCountProvider('a1')), 2);
  });
}

class _ThrowingDaemonClient extends DaemonClient {
  _ThrowingDaemonClient() : super(uri: Uri.parse('ws://fake'));

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    throw StateError('boom');
  }
}
