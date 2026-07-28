import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/provider_subagent_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/provider_subagents_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeDaemonClient extends DaemonClient {
  _FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final eventController = StreamController<RpcEvent>.broadcast();
  final connectionController =
      StreamController<DaemonConnectionState>.broadcast();
  bool failList = false;
  bool failTimeline = false;
  final List<Map<String, Object?>> timelineRequests = [];
  final List<ProviderSubagentTimelineResponse> queuedTimelineResponses = [];

  @override
  Stream<RpcEvent> get events => eventController.stream;
  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;
  @override
  Stream<DaemonConnectionState> get connectionState =>
      connectionController.stream;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.providerSubagentListRequest) {
      if (failList) throw StateError('list failed');
      return {
        'subagents': [
          _descriptor(status: ProviderSubagentStatus.running).toJson(),
        ],
      };
    }
    if (type == MessageTypes.providerSubagentTimelineRequest) {
      if (failTimeline) throw StateError('timeline failed');
      timelineRequests.add(payload);
      if (queuedTimelineResponses.isNotEmpty) {
        return queuedTimelineResponses.removeAt(0).toJson();
      }
      return _timelineResponse(
        rows: const [
          ProviderSubagentTimelineRow(
            item: AssistantMessageItem(
              id: 'answer',
              text: 'initial',
              complete: false,
            ),
            timestamp: '2026-07-26T00:00:00.000Z',
            seq: 1,
          ),
        ],
      ).toJson();
    }
    return const {};
  }
}

ProviderSubagentTimelineResponse _timelineResponse({
  List<ProviderSubagentTimelineRow> rows = const [],
  ProviderSubagentTimelineDirection direction =
      ProviderSubagentTimelineDirection.tail,
  String epoch = 'epoch-1',
  bool reset = false,
  bool staleCursor = false,
  bool gap = false,
  bool hasOlder = false,
  bool hasNewer = false,
  ProviderSubagentTimelineWindow? window,
  String? error,
}) => ProviderSubagentTimelineResponse(
  parentAgentId: 'parent',
  subagentId: 'child',
  provider: error == null ? 'codex' : null,
  direction: direction,
  epoch: epoch,
  reset: reset,
  staleCursor: staleCursor,
  gap: gap,
  window:
      window ??
      ProviderSubagentTimelineWindow(
        minSeq: rows.isEmpty ? 0 : rows.first.seq,
        maxSeq: rows.isEmpty ? 0 : rows.last.seq,
        nextSeq: rows.isEmpty ? 1 : rows.last.seq + 1,
      ),
  hasOlder: hasOlder,
  hasNewer: hasNewer,
  rows: rows,
  error: error,
);

ProviderSubagentDescriptor _descriptor({
  required ProviderSubagentStatus status,
}) => ProviderSubagentDescriptor(
  id: 'child',
  parentAgentId: 'parent',
  provider: 'codex',
  title: 'Research',
  status: status,
  createdAt: '2026-07-26T00:00:00.000Z',
  updatedAt: '2026-07-26T00:00:00.000Z',
);

void main() {
  test(
    'loads list/timeline and applies live upsert, timeline, and remove',
    () async {
      final client = _FakeDaemonClient();
      addTearDown(client.eventController.close);
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      container.listen(
        providerSubagentsProvider('parent'),
        (_, _) {},
        fireImmediately: true,
      );
      await pumpEventQueue();

      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .descriptors['child']
            ?.title,
        'Research',
      );
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');
      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .timelines['child']
            ?.rows
            .single
            .seq,
        1,
      );

      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: ProviderSubagentUpsert(
            subagent: _descriptor(status: ProviderSubagentStatus.completed),
          ).toJson(),
        ),
      );
      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: const ProviderSubagentTimelineUpdate(
            parentAgentId: 'parent',
            subagentId: 'child',
            provider: 'codex',
            item: AssistantMessageItem(
              id: 'answer',
              text: 'complete',
              complete: true,
            ),
            timestamp: '2026-07-26T00:01:00.000Z',
            seq: 2,
            epoch: 'epoch-1',
          ).toJson(),
        ),
      );
      await pumpEventQueue();
      final live = container.read(providerSubagentsProvider('parent'));
      expect(
        live.descriptors['child']?.status,
        ProviderSubagentStatus.completed,
      );
      expect(
        (live.timelines['child']!.projectedRows.single.item
                as AssistantMessageItem)
            .text,
        'complete',
      );

      client.queuedTimelineResponses.add(
        _timelineResponse(
          epoch: 'epoch-2',
          reset: true,
          rows: const [
            ProviderSubagentTimelineRow(
              item: ErrorItem(id: 'error', message: 'new epoch'),
              timestamp: '2026-07-26T00:02:00.000Z',
              seq: 5,
            ),
          ],
        ),
      );
      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: const ProviderSubagentTimelineUpdate(
            parentAgentId: 'parent',
            subagentId: 'child',
            provider: 'codex',
            item: ErrorItem(id: 'error', message: 'new epoch'),
            timestamp: '2026-07-26T00:02:00.000Z',
            seq: 5,
            epoch: 'epoch-2',
          ).toJson(),
        ),
      );
      await pumpEventQueue();
      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .timelines['child']
            ?.rows
            .single
            .seq,
        5,
      );

      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: const ProviderSubagentRemove(
            parentAgentId: 'parent',
            subagentId: 'child',
          ).toJson(),
        ),
      );
      await pumpEventQueue();
      expect(
        container.read(providerSubagentsProvider('parent')).descriptors,
        isEmpty,
      );
    },
  );

  test('list and timeline request failures settle loading state', () async {
    final client = _FakeDaemonClient()..failList = true;
    addTearDown(client.eventController.close);
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    container.listen(
      providerSubagentsProvider('parent'),
      (_, _) {},
      fireImmediately: true,
    );
    await pumpEventQueue();
    expect(
      container.read(providerSubagentsProvider('parent')).loading,
      isFalse,
    );

    client.failTimeline = true;
    await container
        .read(providerSubagentsProvider('parent').notifier)
        .loadTimeline('child');
    expect(
      container
          .read(providerSubagentsProvider('parent'))
          .timelines['child']
          ?.loading,
      isFalse,
    );
  });

  test(
    'loads older pages and merges canonical rows in sequence order',
    () async {
      final client = _FakeDaemonClient()
        ..queuedTimelineResponses.addAll([
          _timelineResponse(
            rows: const [
              ProviderSubagentTimelineRow(
                item: AssistantMessageItem(
                  id: 'new',
                  text: 'new',
                  complete: true,
                ),
                timestamp: '2026-07-26T00:02:00.000Z',
                seq: 3,
              ),
            ],
            hasOlder: true,
          ),
          _timelineResponse(
            direction: ProviderSubagentTimelineDirection.before,
            rows: const [
              ProviderSubagentTimelineRow(
                item: UserMessageItem(id: 'old', text: 'old'),
                timestamp: '2026-07-26T00:00:00.000Z',
                seq: 1,
              ),
              ProviderSubagentTimelineRow(
                item: ReasoningItem(
                  id: 'middle',
                  text: 'middle',
                  complete: true,
                ),
                timestamp: '2026-07-26T00:01:00.000Z',
                seq: 2,
              ),
            ],
            hasNewer: true,
          ),
        ]);
      addTearDown(client.eventController.close);
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      container.listen(
        providerSubagentsProvider('parent'),
        (_, _) {},
        fireImmediately: true,
      );
      await pumpEventQueue();
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadOlder('child');

      final timeline = container
          .read(providerSubagentsProvider('parent'))
          .timelines['child']!;
      expect(timeline.rows.map((row) => row.seq), [1, 2, 3]);
      expect(timeline.hasOlder, isFalse);
      expect(client.timelineRequests.last['direction'], 'before');
      expect(client.timelineRequests.last['cursor'], {
        'epoch': 'epoch-1',
        'seq': 3,
      });
    },
  );

  test('repairs a live sequence gap with an after-cursor fetch', () async {
    final client = _FakeDaemonClient();
    addTearDown(client.eventController.close);
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    container.listen(
      providerSubagentsProvider('parent'),
      (_, _) {},
      fireImmediately: true,
    );
    await pumpEventQueue();
    await container
        .read(providerSubagentsProvider('parent').notifier)
        .loadTimeline('child');
    client.queuedTimelineResponses.add(
      _timelineResponse(
        direction: ProviderSubagentTimelineDirection.after,
        rows: const [
          ProviderSubagentTimelineRow(
            item: ReasoningItem(
              id: 'missing',
              text: 'recovered',
              complete: true,
            ),
            timestamp: '2026-07-26T00:01:00.000Z',
            seq: 2,
          ),
          ProviderSubagentTimelineRow(
            item: ErrorItem(id: 'late', message: 'late'),
            timestamp: '2026-07-26T00:02:00.000Z',
            seq: 3,
          ),
        ],
      ),
    );
    client.eventController.add(
      RpcEvent(
        type: MessageTypes.providerSubagentUpdateEvent,
        payload: const ProviderSubagentTimelineUpdate(
          parentAgentId: 'parent',
          subagentId: 'child',
          provider: 'codex',
          item: ErrorItem(id: 'late', message: 'late'),
          timestamp: '2026-07-26T00:02:00.000Z',
          seq: 3,
          epoch: 'epoch-1',
        ).toJson(),
      ),
    );
    await pumpEventQueue(times: 10);

    final timeline = container
        .read(providerSubagentsProvider('parent'))
        .timelines['child']!;
    expect(timeline.rows.map((row) => row.seq), [1, 2, 3]);
    expect(timeline.gap, isFalse);
    expect(client.timelineRequests.last['direction'], 'after');
    expect(client.timelineRequests.last['cursor'], {
      'epoch': 'epoch-1',
      'seq': 1,
    });
  });

  test(
    'merges a tail refresh and preserves a loaded replica on request errors',
    () async {
      final client = _FakeDaemonClient()
        ..queuedTimelineResponses.add(
          _timelineResponse(
            rows: const [
              ProviderSubagentTimelineRow(
                item: AssistantMessageItem(
                  id: 'answer',
                  text: 'one',
                  complete: false,
                ),
                timestamp: '2026-07-26T00:00:00.000Z',
                seq: 1,
              ),
            ],
            hasOlder: true,
          ),
        );
      addTearDown(client.eventController.close);
      addTearDown(client.connectionController.close);
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      container.listen(
        providerSubagentsProvider('parent'),
        (_, _) {},
        fireImmediately: true,
      );
      await pumpEventQueue();
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');

      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: const ProviderSubagentTimelineUpdate(
            parentAgentId: 'parent',
            subagentId: 'child',
            provider: 'codex',
            item: AssistantMessageItem(
              id: 'answer',
              text: 'two',
              complete: true,
            ),
            timestamp: '2026-07-26T00:01:00.000Z',
            seq: 2,
            epoch: 'epoch-1',
          ).toJson(),
        ),
      );
      await pumpEventQueue();

      client.queuedTimelineResponses.add(
        _timelineResponse(
          rows: const [
            ProviderSubagentTimelineRow(
              item: AssistantMessageItem(
                id: 'answer',
                text: 'one',
                complete: false,
              ),
              timestamp: '2026-07-26T00:00:00.000Z',
              seq: 1,
            ),
          ],
          hasOlder: true,
          window: const ProviderSubagentTimelineWindow(
            minSeq: 1,
            maxSeq: 2,
            nextSeq: 3,
          ),
        ),
      );
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');
      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .timelines['child']!
            .rows
            .map((row) => row.seq),
        [1, 2],
      );

      client.eventController.add(
        RpcEvent(
          type: MessageTypes.providerSubagentUpdateEvent,
          payload: const ProviderSubagentTimelineUpdate(
            parentAgentId: 'parent',
            subagentId: 'child',
            provider: 'codex',
            item: AssistantMessageItem(
              id: 'answer',
              text: 'two updated',
              complete: true,
            ),
            timestamp: '2026-07-26T00:01:01.000Z',
            seq: 2,
            epoch: 'epoch-1',
          ).toJson(),
        ),
      );
      await pumpEventQueue();
      expect(
        (container
                    .read(providerSubagentsProvider('parent'))
                    .timelines['child']!
                    .rows
                    .last
                    .item
                as AssistantMessageItem)
            .text,
        'two updated',
      );

      client.failTimeline = true;
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadOlder('child');
      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .timelines['child']!
            .rows,
        hasLength(2),
      );

      client.failTimeline = false;
      client.queuedTimelineResponses.add(
        _timelineResponse(error: 'provider history unavailable'),
      );
      await container
          .read(providerSubagentsProvider('parent').notifier)
          .loadTimeline('child');
      expect(
        container
            .read(providerSubagentsProvider('parent'))
            .timelines['child']!
            .loading,
        isFalse,
      );

      client.connectionController.add(DaemonConnectionState.connected);
      await pumpEventQueue();
      expect(client.currentState, DaemonConnectionState.connected);
    },
  );

  testWidgets(
    'provider subagent screen renders descriptor and child timeline',
    (tester) async {
      final client = _FakeDaemonClient();
      addTearDown(client.eventController.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [daemonClientProvider.overrideWithValue(client)],
          child: const FluentApp(
            home: ScaffoldPage(
              content: ProviderSubagentScreen(
                parentAgentId: 'parent',
                subagentId: 'child',
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Research'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('initial'), findsOneWidget);
    },
  );

  testWidgets('provider subagent screen loads older activity', (tester) async {
    final client = _FakeDaemonClient()
      ..queuedTimelineResponses.addAll([
        _timelineResponse(
          rows: const [
            ProviderSubagentTimelineRow(
              item: AssistantMessageItem(
                id: 'new',
                text: 'new activity',
                complete: true,
              ),
              timestamp: '2026-07-26T00:01:00.000Z',
              seq: 2,
            ),
          ],
          hasOlder: true,
        ),
        _timelineResponse(
          direction: ProviderSubagentTimelineDirection.before,
          rows: const [
            ProviderSubagentTimelineRow(
              item: UserMessageItem(id: 'old', text: 'old activity'),
              timestamp: '2026-07-26T00:00:00.000Z',
              seq: 1,
            ),
          ],
          hasNewer: true,
        ),
      ]);
    addTearDown(client.eventController.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [daemonClientProvider.overrideWithValue(client)],
        child: const FluentApp(
          home: ScaffoldPage(
            content: ProviderSubagentScreen(
              parentAgentId: 'parent',
              subagentId: 'child',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Load older activity'), findsOneWidget);
    await tester.tap(find.text('Load older activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('old activity'), findsOneWidget);
    expect(find.text('new activity'), findsOneWidget);
  });
}
