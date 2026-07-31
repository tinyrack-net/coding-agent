// Port of Paseo's `agent-stream/layout.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/layout.dart';
import 'package:coding_agent_app/agent_stream/spacing.dart';
import 'package:coding_agent_app/agent_stream/stream_strategy.dart';
import 'package:coding_agent_app/agent_stream/turn_time.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime timestamp(int seed) =>
    DateTime.parse('2026-01-01T00:00:00.000Z').add(Duration(seconds: seed));

TimelineDisplayItem userMessage(String id, int seed) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
  timestamp: timestamp(seed),
);

TimelineDisplayItem assistantMessage(
  String id,
  int seed, {
  String? blockGroupId,
}) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: id, complete: true),
  timestamp: timestamp(seed),
  blockGroupId: blockGroupId,
);

TimelineDisplayItem toolCall(String id, int seed) => TimelineDisplayItem(
  item: ToolCallItem(
    id: id,
    toolName: 'Shell',
    status: ToolCallStatus.success,
    detail: const GenericDetail(input: {}),
  ),
  timestamp: timestamp(seed),
);

TimelineDisplayItem thought(String id, int seed) => TimelineDisplayItem(
  item: ReasoningItem(id: id, text: id, complete: true),
  timestamp: timestamp(seed),
);

Map<String, TurnTiming> timingFor(List<String> ids) {
  final timing = TurnTiming(
    startedAt: timestamp(1),
    completedAt: timestamp(9),
    durationMs: 8000,
  );
  return {for (final id in ids) id: timing};
}

StreamStrategy strategyFor(String platform) =>
    resolveStreamRenderStrategy(platform: platform, isMobileBreakpoint: false);

StreamLayout layoutFor({
  required String platform,
  required List<TimelineDisplayItem> tail,
  String agentStatus = 'idle',
  List<TimelineDisplayItem> head = const [],
  List<String> timingIds = const [],
}) {
  final strategy = strategyFor(platform);
  return layoutStream(
    strategy: strategy,
    agentStatus: agentStatus,
    history: strategy.orderTail(tail),
    liveHead: strategy.orderHead(head),
    timingByAssistantId: timingFor(timingIds),
  );
}

List<String> footerOwners(StreamLayout layout) => [
  for (final row in layout.history)
    if (row.completedFooter != null) row.item.item.id,
  for (final row in layout.liveHead)
    if (row.completedFooter != null) row.item.item.id,
  if (layout.auxiliaryTurnFooter != null) layout.auxiliaryTurnFooter!.itemId,
];

List<String> footerAssistantIds(StreamLayout layout) => [
  for (final row in layout.history)
    if (row.completedFooter case final footer?) footer.itemId,
  for (final row in layout.liveHead)
    if (row.completedFooter case final footer?) footer.itemId,
  if (layout.auxiliaryTurnFooter != null) layout.auxiliaryTurnFooter!.itemId,
];

Map<String, String> inlineFooterPlacementByItemId(StreamLayout layout) => {
  for (final row in [...layout.history, ...layout.liveHead])
    if (row.completedFooter case final footer?) row.item.item.id: footer.itemId,
};

StreamLayoutItem findLayoutItem(StreamLayout layout, String id) =>
    [...layout.history, ...layout.liveHead].firstWhere(
      (candidate) => candidate.item.item.id == id,
      orElse: () => throw StateError('Missing layout item $id'),
    );

void main() {
  for (final platform in const ['web', 'android']) {
    test('keeps split assistant block spacing identical to unsplit history on '
        '$platform', () {
      final firstBlock = assistantMessage(
        'turn:block:0',
        2,
        blockGroupId: 'turn',
      );
      final secondBlock = assistantMessage(
        'turn:block:1',
        3,
        blockGroupId: 'turn',
      );
      final thirdBlock = assistantMessage(
        'turn:block:2',
        4,
        blockGroupId: 'turn',
      );
      final timingIds = [
        firstBlock.item.id,
        secondBlock.item.id,
        thirdBlock.item.id,
      ];
      final splitLayout = layoutFor(
        platform: platform,
        agentStatus: 'running',
        tail: [userMessage('u1', 1), firstBlock],
        head: [secondBlock, thirdBlock],
        timingIds: timingIds,
      );
      final unsplitLayout = layoutFor(
        platform: platform,
        agentStatus: 'running',
        tail: [userMessage('u1', 1), firstBlock, secondBlock, thirdBlock],
        timingIds: timingIds,
      );

      expect(
        findLayoutItem(splitLayout, firstBlock.item.id).belowItem?.item.id,
        secondBlock.item.id,
      );
      expect(
        findLayoutItem(splitLayout, secondBlock.item.id).aboveItem?.item.id,
        firstBlock.item.id,
      );
      expect(
        findLayoutItem(splitLayout, firstBlock.item.id).assistantSpacing,
        findLayoutItem(unsplitLayout, firstBlock.item.id).assistantSpacing,
      );
      expect(
        findLayoutItem(splitLayout, secondBlock.item.id).assistantSpacing,
        findLayoutItem(unsplitLayout, secondBlock.item.id).assistantSpacing,
      );
      expect(
        findLayoutItem(splitLayout, firstBlock.item.id).gapBelow,
        findLayoutItem(unsplitLayout, firstBlock.item.id).gapBelow,
      );
      expect(
        findLayoutItem(splitLayout, secondBlock.item.id).gapBelow,
        findLayoutItem(unsplitLayout, secondBlock.item.id).gapBelow,
      );
    });
  }

  test('does not duplicate footers when a native assistant turn spans history '
      'and live head', () {
    final historyBlock = assistantMessage(
      'turn:block:0',
      2,
      blockGroupId: 'turn',
    );
    final headBlock = assistantMessage('turn:head', 3, blockGroupId: 'turn');
    final layout = layoutFor(
      platform: 'android',
      tail: [userMessage('u1', 1), historyBlock],
      head: [headBlock],
      timingIds: [historyBlock.item.id, headBlock.item.id],
    );

    expect(footerOwners(layout), [headBlock.item.id]);
    expect(
      findLayoutItem(layout, historyBlock.item.id).belowItem?.item.id,
      headBlock.item.id,
    );
    expect(
      findLayoutItem(layout, historyBlock.item.id).completedFooter,
      isNull,
    );
  });

  test('does not duplicate footers when a web assistant turn spans history and '
      'live head', () {
    final historyBlock = assistantMessage(
      'turn:block:0',
      2,
      blockGroupId: 'turn',
    );
    final headBlock = assistantMessage('turn:head', 3, blockGroupId: 'turn');
    final layout = layoutFor(
      platform: 'web',
      tail: [userMessage('u1', 1), historyBlock],
      head: [headBlock],
      timingIds: [historyBlock.item.id, headBlock.item.id],
    );

    expect(footerOwners(layout), [headBlock.item.id]);
    expect(
      findLayoutItem(layout, historyBlock.item.id).belowItem?.item.id,
      headBlock.item.id,
    );
    expect(
      findLayoutItem(layout, headBlock.item.id).aboveItem?.item.id,
      historyBlock.item.id,
    );
  });

  test('keeps the completed footer visually after the assistant after a native '
      'user reply', () {
    final assistant = assistantMessage('a1', 2);
    final layout = layoutFor(
      platform: 'android',
      tail: [userMessage('u1', 1), assistant, userMessage('u2', 3)],
      timingIds: [assistant.item.id],
    );
    final assistantRow = findLayoutItem(layout, assistant.item.id);

    expect(layout.auxiliaryTurnFooter, isNull);
    expect(assistantRow.completedFooter?.itemId, assistant.item.id);
    expect(assistantRow.belowItem?.item.id, 'u2');
    expect(assistantRow.frameOrder, StreamFrameChildOrder.footerThenContent);
  });

  test('keeps forward stream content before its completed footer', () {
    final assistant = assistantMessage('a1', 2);
    final layout = layoutFor(
      platform: 'web',
      tail: [userMessage('u1', 1), assistant, userMessage('u2', 3)],
      timingIds: [assistant.item.id],
    );
    final assistantRow = findLayoutItem(layout, assistant.item.id);

    expect(assistantRow.completedFooter?.itemId, assistant.item.id);
    expect(assistantRow.frameOrder, StreamFrameChildOrder.contentThenFooter);
  });

  test('compacts assistant block spacing across the history and live-head '
      'boundary', () {
    final historyBlock = assistantMessage(
      'turn:block:0',
      2,
      blockGroupId: 'turn',
    );
    final headBlock = assistantMessage('turn:head', 3, blockGroupId: 'turn');
    final layout = layoutFor(
      platform: 'android',
      tail: [userMessage('u1', 1), historyBlock],
      head: [headBlock],
      timingIds: [historyBlock.item.id, headBlock.item.id],
    );

    expect(
      findLayoutItem(layout, historyBlock.item.id).assistantSpacing,
      AssistantBlockSpacing.compactBottom,
    );
    expect(
      findLayoutItem(layout, headBlock.item.id).assistantSpacing,
      AssistantBlockSpacing.compactTop,
    );
  });

  for (final platform in const ['web', 'android']) {
    test(
      'keeps split tool sequencing and gapBelow identical to unsplit history '
      'on $platform',
      () {
        final shell = toolCall('tool-1', 2);
        final thinking = thought('thought-1', 3);
        final assistant = assistantMessage('a1', 4);
        final splitLayout = layoutFor(
          platform: platform,
          tail: [userMessage('u1', 1), shell],
          head: [thinking, assistant],
        );
        final unsplitLayout = layoutFor(
          platform: platform,
          tail: [userMessage('u1', 1), shell, thinking, assistant],
        );

        expect(
          findLayoutItem(splitLayout, shell.item.id).belowItem?.item.id,
          thinking.item.id,
        );
        expect(
          findLayoutItem(splitLayout, thinking.item.id).aboveItem?.item.id,
          shell.item.id,
        );
        expect(
          findLayoutItem(splitLayout, shell.item.id).toolSequence,
          findLayoutItem(unsplitLayout, shell.item.id).toolSequence,
        );
        expect(
          findLayoutItem(splitLayout, thinking.item.id).toolSequence,
          findLayoutItem(unsplitLayout, thinking.item.id).toolSequence,
        );
        expect(
          findLayoutItem(splitLayout, shell.item.id).gapBelow,
          findLayoutItem(unsplitLayout, shell.item.id).gapBelow,
        );
        expect(
          findLayoutItem(splitLayout, thinking.item.id).gapBelow,
          findLayoutItem(unsplitLayout, thinking.item.id).gapBelow,
        );
      },
    );
  }

  test('computes tool sequence position from strategy-aware neighbors', () {
    final shell = toolCall('tool-1', 2);
    final thinking = thought('thought-1', 3);
    final layout = layoutFor(
      platform: 'android',
      tail: [userMessage('u1', 1), shell, thinking, assistantMessage('a1', 4)],
    );

    expect(
      findLayoutItem(layout, shell.item.id).toolSequence,
      StreamToolSequence.first,
    );
    expect(
      findLayoutItem(layout, thinking.item.id).toolSequence,
      StreamToolSequence.last,
    );
  });

  test('keeps bottom and inline footer ownership mutually exclusive', () {
    final assistant = assistantMessage('a1', 2);
    final layout = layoutFor(
      platform: 'web',
      tail: [userMessage('u1', 1), assistant],
      timingIds: [assistant.item.id],
    );

    expect(layout.auxiliaryTurnFooter?.itemId, assistant.item.id);
    expect(findLayoutItem(layout, assistant.item.id).completedFooter, isNull);
    expect(footerOwners(layout), [assistant.item.id]);
  });

  for (final platform in const ['web', 'android']) {
    test(
      'places inline footer after trailing visible tool rows before the next '
      'user on $platform',
      () {
        final assistant = assistantMessage('a1', 2);
        final tool = toolCall('tool-1', 3);
        final layout = layoutFor(
          platform: platform,
          tail: [userMessage('u1', 1), assistant, tool, userMessage('u2', 4)],
          timingIds: [assistant.item.id],
        );

        expect(layout.auxiliaryTurnFooter, isNull);
        expect(
          findLayoutItem(layout, assistant.item.id).completedFooter,
          isNull,
        );
        expect(
          findLayoutItem(layout, tool.item.id).completedFooter?.itemId,
          assistant.item.id,
        );
        expect(footerOwners(layout), [tool.item.id]);
        expect(footerAssistantIds(layout), [assistant.item.id]);
      },
    );
  }

  for (final platform in const ['web', 'android']) {
    test('places split live-head tool footer using the assistant from history '
        'on $platform', () {
      final assistant = assistantMessage('a1', 2);
      final tool = toolCall('tool-1', 3);
      final layout = layoutFor(
        platform: platform,
        tail: [userMessage('u1', 1), assistant],
        head: [tool, userMessage('u2', 4)],
        timingIds: [assistant.item.id],
      );

      expect(layout.auxiliaryTurnFooter, isNull);
      expect(findLayoutItem(layout, assistant.item.id).completedFooter, isNull);
      expect(
        findLayoutItem(layout, tool.item.id).completedFooter?.itemId,
        assistant.item.id,
      );
      expect(inlineFooterPlacementByItemId(layout), {
        tool.item.id: assistant.item.id,
      });
    });
  }

  for (final platform in const ['web', 'android']) {
    test('uses the latest assistant for footer content while placing after the '
        'visible turn end on $platform', () {
      final firstAssistant = assistantMessage('a1', 2);
      final firstTool = toolCall('tool-1', 3);
      final latestAssistant = assistantMessage('a2', 4);
      final latestTool = toolCall('tool-2', 5);
      final layout = layoutFor(
        platform: platform,
        tail: [
          userMessage('u1', 1),
          firstAssistant,
          firstTool,
          latestAssistant,
          latestTool,
          userMessage('u2', 6),
        ],
        timingIds: [firstAssistant.item.id, latestAssistant.item.id],
      );

      expect(layout.auxiliaryTurnFooter, isNull);
      expect(
        findLayoutItem(layout, firstAssistant.item.id).completedFooter,
        isNull,
      );
      expect(
        findLayoutItem(layout, latestAssistant.item.id).completedFooter,
        isNull,
      );
      expect(
        findLayoutItem(layout, latestTool.item.id).completedFooter?.itemId,
        latestAssistant.item.id,
      );
      expect(footerOwners(layout), [latestTool.item.id]);
      expect(footerAssistantIds(layout), [latestAssistant.item.id]);
    });
  }

  for (final platform in const ['web', 'android']) {
    test('keeps every completed turn footer while placing each one after that '
        "turn's last visible item on $platform", () {
      final firstAssistant = assistantMessage('a1', 2);
      final secondAssistant = assistantMessage('a2', 4);
      final secondTool = toolCall('tool-2', 5);
      final layout = layoutFor(
        platform: platform,
        tail: [
          userMessage('u1', 1),
          firstAssistant,
          userMessage('u2', 3),
          secondAssistant,
          secondTool,
          userMessage('u3', 6),
        ],
        timingIds: [firstAssistant.item.id, secondAssistant.item.id],
      );

      expect(layout.auxiliaryTurnFooter, isNull);
      expect(
        findLayoutItem(layout, firstAssistant.item.id).completedFooter?.itemId,
        firstAssistant.item.id,
      );
      expect(
        findLayoutItem(layout, secondAssistant.item.id).completedFooter,
        isNull,
      );
      expect(
        findLayoutItem(layout, secondTool.item.id).completedFooter?.itemId,
        secondAssistant.item.id,
      );
      expect(inlineFooterPlacementByItemId(layout), {
        firstAssistant.item.id: firstAssistant.item.id,
        secondTool.item.id: secondAssistant.item.id,
      });
    });
  }

  for (final platform in const ['web', 'android']) {
    test('keeps bottom footer on the latest assistant turn when trailing tool '
        'rows end the turn on $platform', () {
      final assistant = assistantMessage('a1', 2);
      final tool = toolCall('tool-1', 3);
      final layout = layoutFor(
        platform: platform,
        tail: [userMessage('u1', 1), assistant, tool],
        timingIds: [assistant.item.id],
      );

      expect(layout.auxiliaryTurnFooter?.itemId, assistant.item.id);
      expect(findLayoutItem(layout, assistant.item.id).completedFooter, isNull);
      expect(footerOwners(layout), [assistant.item.id]);
    });
  }

  for (final platform in const ['web', 'android']) {
    test(
      'does not render a completed footer before tool rows while the turn is '
      'running on $platform',
      () {
        final assistant = assistantMessage('a1', 2);
        final tool = toolCall('tool-1', 3);
        final layout = layoutFor(
          platform: platform,
          agentStatus: 'running',
          tail: [userMessage('u1', 1), assistant, tool],
          timingIds: [assistant.item.id],
        );

        expect(layout.auxiliaryTurnFooter, isNull);
        expect(
          findLayoutItem(layout, assistant.item.id).completedFooter,
          isNull,
        );
        expect(footerOwners(layout), isEmpty);
      },
    );
  }

  test('carries the turn timing onto its footer host', () {
    final assistant = assistantMessage('a1', 2);
    final layout = layoutFor(
      platform: 'web',
      tail: [userMessage('u1', 1), assistant],
      timingIds: [assistant.item.id],
    );

    expect(layout.auxiliaryTurnFooter?.timing?.durationMs, 8000);
    expect(layout.auxiliaryTurnFooter?.startIndex, 1);
  });

  test('leaves the footer timing null when no timing was derived', () {
    final assistant = assistantMessage('a1', 2);
    final layout = layoutFor(
      platform: 'web',
      tail: [userMessage('u1', 1), assistant],
    );

    expect(layout.auxiliaryTurnFooter?.itemId, assistant.item.id);
    expect(layout.auxiliaryTurnFooter?.timing, isNull);
  });

  test('marks user group boundaries', () {
    final layout = layoutFor(
      platform: 'web',
      tail: [
        userMessage('u1', 1),
        userMessage('u2', 2),
        assistantMessage('a1', 3),
      ],
    );

    expect(findLayoutItem(layout, 'u1').isFirstInUserGroup, isTrue);
    expect(findLayoutItem(layout, 'u1').isLastInUserGroup, isFalse);
    expect(findLayoutItem(layout, 'u2').isFirstInUserGroup, isFalse);
    expect(findLayoutItem(layout, 'u2').isLastInUserGroup, isTrue);
    expect(findLayoutItem(layout, 'a1').isFirstInUserGroup, isFalse);
  });

  test('marks the last row of a tool sequence', () {
    final layout = layoutFor(
      platform: 'web',
      tail: [
        userMessage('u1', 1),
        toolCall('tool-1', 2),
        thought('thought-1', 3),
        assistantMessage('a1', 4),
      ],
    );

    expect(findLayoutItem(layout, 'tool-1').isLastInToolSequence, isFalse);
    expect(findLayoutItem(layout, 'thought-1').isLastInToolSequence, isTrue);
    expect(findLayoutItem(layout, 'a1').isLastInToolSequence, isFalse);
  });

  test('lays out an empty stream without a footer', () {
    final layout = layoutFor(platform: 'web', tail: const []);

    expect(layout.history, isEmpty);
    expect(layout.liveHead, isEmpty);
    expect(layout.auxiliaryTurnFooter, isNull);
  });

  test('reuses cached history layout for an unchanged history list', () {
    final tail = [userMessage('u1', 1), assistantMessage('a1', 2)];
    final strategy = strategyFor('web');
    final history = strategy.orderTail(tail);

    final first = layoutStream(
      strategy: strategy,
      agentStatus: 'running',
      history: history,
      liveHead: const [],
      timingByAssistantId: const {},
    );
    final second = layoutStream(
      strategy: strategy,
      agentStatus: 'running',
      history: history,
      liveHead: const [],
      timingByAssistantId: const {},
    );

    expect(identical(first.history, second.history), isTrue);
  });
}
