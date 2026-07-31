// Port of Paseo's `agent-stream/model.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/render_model.dart';
import 'package:coding_agent_app/agent_stream/turn_time.dart';
import 'package:coding_agent_app/agent_stream/web_virtualization.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Upstream builds these by interpolating the seed into the seconds field,
/// which silently yields an `Invalid Date` once a fixture exceeds 59 and is
/// never asserted on. Dart throws on that input, so seconds roll over here
/// instead; every assertion only depends on the relative offsets, which are
/// unchanged.
DateTime createTimestamp(int seed) =>
    DateTime.parse('2026-01-01T00:00:00.000Z').add(Duration(seconds: seed));

TimelineDisplayItem userMessage(String id, int seed) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
  timestamp: createTimestamp(seed),
);

TimelineDisplayItem assistantMessage(String id, int seed) =>
    TimelineDisplayItem(
      item: AssistantMessageItem(id: id, text: id, complete: true),
      timestamp: createTimestamp(seed),
    );

void main() {
  tearDown(setWebVirtualizationOverrides);

  test('keeps head separate from committed history on desktop web', () {
    final tail = <TimelineDisplayItem>[];
    for (var index = 0; index < 60; index += 1) {
      final seed = index * 2;
      tail
        ..add(userMessage('u$index', seed + 1))
        ..add(assistantMessage('a$index', seed + 2));
    }
    final head = [assistantMessage('live-a', 21)];

    final model = buildAgentStreamRenderModel(
      agentStatus: 'running',
      tail: tail,
      head: head,
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );

    expect(model.segments.historyVirtualized, isNotEmpty);
    expect(model.segments.historyMounted, isNotEmpty);
    expect(model.segments.liveHead.map((item) => item.item.id), ['live-a']);
    expect(model.history, isNot(contains(head.first)));
    expect(model.boundary.hasVirtualizedHistory, isTrue);
    expect(model.boundary.hasMountedHistory, isTrue);
    expect(model.boundary.hasLiveHead, isTrue);
  });

  test('keeps the full committed tail mounted on mobile web', () {
    final tail = [userMessage('u1', 1), assistantMessage('a1', 2)];
    final head = [assistantMessage('live-a', 3)];

    final model = buildAgentStreamRenderModel(
      agentStatus: 'running',
      tail: tail,
      head: head,
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: true,
    );

    expect(model.segments.historyVirtualized, isEmpty);
    expect(identical(model.segments.historyMounted, tail), isTrue);
    expect(identical(model.segments.liveHead, head), isTrue);
    expect(model.boundary.hasVirtualizedHistory, isFalse);
  });

  test('reuses ordered committed history when only the live head changes', () {
    final tail = [userMessage('u1', 1), assistantMessage('a1', 2)];
    final firstHead = [assistantMessage('live-a', 3)];
    final secondHead = [assistantMessage('live-b', 4)];

    final first = buildAgentStreamRenderModel(
      agentStatus: 'running',
      tail: tail,
      head: firstHead,
      platform: StreamRenderPlatform.native,
      isMobileBreakpoint: false,
    );
    final second = buildAgentStreamRenderModel(
      agentStatus: 'running',
      tail: tail,
      head: secondHead,
      platform: StreamRenderPlatform.native,
      isMobileBreakpoint: false,
    );

    expect(identical(first.history, second.history), isTrue);
    expect(
      identical(first.segments.historyMounted, second.segments.historyMounted),
      isTrue,
    );
    expect(second.segments.liveHead.map((item) => item.item.id), ['live-b']);
  });

  test(
    'derives running turn timing across committed history and live head',
    () {
      final tail = [userMessage('u1', 1)];
      final head = [assistantMessage('live-a', 4)];

      final model = buildAgentStreamRenderModel(
        agentStatus: 'running',
        tail: tail,
        head: head,
        platform: StreamRenderPlatform.web,
        isMobileBreakpoint: false,
      );

      expect(model.turnTiming.runningStartedAt, tail.first.timestamp);
      expect(model.turnTiming.byAssistantId.containsKey('live-a'), isFalse);
    },
  );

  test(
    'maps completed turn timing to assistant ids across committed history and '
    'live head',
    () {
      final tail = [userMessage('u1', 1)];
      final head = [assistantMessage('live-a', 4)];

      final model = buildAgentStreamRenderModel(
        agentStatus: 'idle',
        tail: tail,
        head: head,
        platform: StreamRenderPlatform.web,
        isMobileBreakpoint: false,
      );

      expect(model.turnTiming.runningStartedAt, isNull);
      expect(
        model.turnTiming.byAssistantId['live-a'],
        TurnTiming(
          startedAt: tail.first.timestamp!,
          completedAt: head.first.timestamp!,
          durationMs: 3000,
        ),
      );
    },
  );

  test('derives the same timing for native inverted rendering', () {
    final tail = [userMessage('u1', 1), assistantMessage('a1', 4)];

    final model = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.native,
      isMobileBreakpoint: false,
    );

    expect(model.segments.historyMounted.map((item) => item.item.id), [
      'a1',
      'u1',
    ]);
    expect(
      model.turnTiming.byAssistantId['a1'],
      TurnTiming(
        startedAt: tail.first.timestamp!,
        completedAt: tail.last.timestamp!,
        durationMs: 3000,
      ),
    );
  });

  test('does not create completed timing for adjacent user messages', () {
    final tail = [userMessage('u1', 1), userMessage('u2', 4)];

    final model = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );

    expect(model.turnTiming.byAssistantId, isEmpty);
  });

  test('splits desktop web history at the mounted window user boundary', () {
    setWebVirtualizationOverrides(
      partialVirtualizationThreshold: 6,
      mountedRecentStreamItems: 4,
    );
    final tail = <TimelineDisplayItem>[];
    for (var index = 0; index < 5; index += 1) {
      final seed = index * 2;
      tail
        ..add(userMessage('u$index', seed + 1))
        ..add(assistantMessage('a$index', seed + 2));
    }

    final model = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );

    expect(model.segments.historyVirtualized.map((item) => item.item.id), [
      'u0',
      'a0',
      'u1',
      'a1',
      'u2',
      'a2',
    ]);
    expect(model.segments.historyMounted.map((item) => item.item.id), [
      'u3',
      'a3',
      'u4',
      'a4',
    ]);
    expect(identical(model.history, tail), isTrue);
  });

  test('reuses the split for the same tail and re-splits when the mounted '
      'window changes', () {
    setWebVirtualizationOverrides(
      partialVirtualizationThreshold: 2,
      mountedRecentStreamItems: 4,
    );
    final tail = <TimelineDisplayItem>[];
    for (var index = 0; index < 5; index += 1) {
      final seed = index * 2;
      tail
        ..add(userMessage('u$index', seed + 1))
        ..add(assistantMessage('a$index', seed + 2));
    }

    final first = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );
    final second = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );
    expect(
      identical(first.segments.historyMounted, second.segments.historyMounted),
      isTrue,
    );

    setWebVirtualizationOverrides(
      partialVirtualizationThreshold: 2,
      mountedRecentStreamItems: 2,
    );
    final third = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );
    expect(third.segments.historyMounted.map((item) => item.item.id), [
      'u4',
      'a4',
    ]);
  });

  test('recomputes turn timing when the agent status changes', () {
    final tail = [userMessage('u1', 1), assistantMessage('a1', 4)];

    final running = buildAgentStreamRenderModel(
      agentStatus: 'running',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );
    final idle = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: tail,
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );

    expect(running.turnTiming.runningStartedAt, tail.first.timestamp);
    expect(running.turnTiming.byAssistantId, isEmpty);
    expect(idle.turnTiming.runningStartedAt, isNull);
    expect(idle.turnTiming.byAssistantId.containsKey('a1'), isTrue);
  });

  test('reports an all-empty boundary for an empty stream', () {
    final model = buildAgentStreamRenderModel(
      agentStatus: 'idle',
      tail: const [],
      head: const [],
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );

    expect(model.boundary.hasVirtualizedHistory, isFalse);
    expect(model.boundary.hasMountedHistory, isFalse);
    expect(model.boundary.hasLiveHead, isFalse);
    expect(model.auxiliary.pendingPermissions, isNull);
    expect(model.auxiliary.turnFooter, isNull);
  });
}
