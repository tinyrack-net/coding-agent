import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/turn_time.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port of Paseo's `timeline/turn-time.test.ts` onto
/// [deriveStreamTurnTiming].
TimelineDisplayItem user(
  String id,
  DateTime timestamp, {
  bool optimistic = false,
}) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
  timestamp: timestamp,
  optimistic: optimistic,
);

TimelineDisplayItem assistant(String id, DateTime timestamp) =>
    TimelineDisplayItem(
      item: AssistantMessageItem(id: id, text: id, complete: true),
      timestamp: timestamp,
    );

void main() {
  test('reserves a running footer for an optimistic prompt before the host '
      'starts the turn', () {
    final timing = deriveStreamTurnTiming(
      agentStatus: 'idle',
      tail: const [],
      head: [
        user(
          'optimistic',
          DateTime.parse('2026-05-15T00:00:00.000Z'),
          optimistic: true,
        ),
      ],
    );

    expect(timing.isActive, isTrue);
  });

  test('does not start elapsed time from an optimistic prompt', () {
    final timing = deriveStreamTurnTiming(
      agentStatus: 'running',
      tail: const [],
      head: [
        user(
          'optimistic',
          DateTime.parse('2026-05-15T00:00:00.000Z'),
          optimistic: true,
        ),
      ],
    );

    expect(timing.runningStartedAt, isNull);
  });

  test('uses the last user message as the running turn start', () {
    final secondUserAt = DateTime.parse('2026-05-15T00:01:00.000Z');

    final timing = deriveStreamTurnTiming(
      agentStatus: 'running',
      tail: [
        user('u1', DateTime.parse('2026-05-15T00:00:00.000Z')),
        assistant('a1', DateTime.parse('2026-05-15T00:00:05.000Z')),
        user('u2', secondUserAt),
      ],
      head: [assistant('a2', DateTime.parse('2026-05-15T00:01:04.000Z'))],
    );

    expect(timing.runningStartedAt, secondUserAt);
    expect(timing.byAssistantId.containsKey('a2'), isFalse);
  });

  test(
    'derives completed turn timing from user and assistant item timestamps',
    () {
      final userAt = DateTime.parse('2026-05-15T00:00:00.000Z');
      final assistantAt = DateTime.parse('2026-05-15T00:00:07.000Z');

      final timing = deriveStreamTurnTiming(
        agentStatus: 'idle',
        tail: [
          user('u1', userAt),
          assistant('a1', assistantAt),
          user('u2', DateTime.parse('2026-05-15T00:01:00.000Z')),
        ],
        head: const [],
      );

      expect(
        timing.byAssistantId['a1'],
        TurnTiming(
          startedAt: userAt,
          completedAt: assistantAt,
          durationMs: 7000,
        ),
      );
    },
  );

  test('maps multiple assistant chunks in one turn to the same timing', () {
    final userAt = DateTime.parse('2026-05-15T00:00:00.000Z');
    final firstAssistantAt = DateTime.parse('2026-05-15T00:00:03.000Z');
    final lastAssistantAt = DateTime.parse('2026-05-15T00:00:07.000Z');

    final timing = deriveStreamTurnTiming(
      agentStatus: 'idle',
      tail: [
        user('u1', userAt),
        assistant('a1', firstAssistantAt),
        assistant('a2', lastAssistantAt),
      ],
      head: const [],
    );

    final expected = TurnTiming(
      startedAt: userAt,
      completedAt: lastAssistantAt,
      durationMs: 7000,
    );
    expect(timing.byAssistantId['a1'], expected);
    expect(timing.byAssistantId['a2'], expected);
  });

  test('items without a timestamp are skipped rather than throwing', () {
    final timing = deriveStreamTurnTiming(
      agentStatus: 'idle',
      tail: [
        const TimelineDisplayItem(
          item: UserMessageItem(id: 'u1', text: 'u1'),
        ),
        assistant('a1', DateTime.parse('2026-05-15T00:00:07.000Z')),
      ],
      head: const [],
    );

    expect(timing.byAssistantId, isEmpty);
    expect(timing.isActive, isFalse);
  });

  test('a non-running status with no user message stays inactive', () {
    final timing = deriveStreamTurnTiming(
      agentStatus: 'idle',
      tail: const [],
      head: const [],
    );

    expect(timing.isActive, isFalse);
    expect(timing.runningStartedAt, isNull);
    expect(timing.byAssistantId, isEmpty);
  });
}
