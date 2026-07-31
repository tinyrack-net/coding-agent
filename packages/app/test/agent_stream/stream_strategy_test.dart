import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/stream_strategy.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port of Paseo's `agent-stream/render-strategy.test.ts`.
TimelineDisplayItem userMessage(String id, String text) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: text),
);

TimelineDisplayItem assistantMessage(String id, String text) =>
    TimelineDisplayItem(
      item: AssistantMessageItem(id: id, text: text, complete: true),
    );

void main() {
  group('resolveStreamRenderStrategy', () {
    test('uses forward_stream on web', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );

      expect(strategy.useVirtualizedList, isFalse);
      expect(strategy.flatListInverted, isFalse);
      expect(strategy.overlayScrollbarInverted, isFalse);
      expect(strategy.anchorBottomOnContentSizeChange, isTrue);
      expect(
        strategy.bottomAnchorTransportBehavior,
        const BottomAnchorTransportBehavior(
          verificationDelayFrames: 0,
          verificationRetryMode: BottomAnchorVerificationRetryMode.rescroll,
        ),
      );
    });

    test('uses inverted_stream on native', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'ios',
        isMobileBreakpoint: false,
      );

      expect(strategy.useVirtualizedList, isTrue);
      expect(strategy.flatListInverted, isTrue);
      expect(strategy.overlayScrollbarInverted, isTrue);
      expect(strategy.anchorBottomOnContentSizeChange, isFalse);
      expect(
        strategy.bottomAnchorTransportBehavior,
        const BottomAnchorTransportBehavior(
          verificationDelayFrames: 2,
          verificationRetryMode: BottomAnchorVerificationRetryMode.recheck,
        ),
      );
    });

    test('delays native verification while viewport settling is in flight', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'ios',
        isMobileBreakpoint: false,
      );

      expect(
        resolveBottomAnchorTransportBehavior(
          strategy: strategy,
          isViewportSettling: true,
        ),
        const BottomAnchorTransportBehavior(
          verificationDelayFrames: 4,
          verificationRetryMode: BottomAnchorVerificationRetryMode.recheck,
        ),
      );
    });

    test(
      'does not inflate forward-stream verification delays during web resize',
      () {
        final strategy = resolveStreamRenderStrategy(
          platform: 'web',
          isMobileBreakpoint: false,
        );

        expect(
          resolveBottomAnchorTransportBehavior(
            strategy: strategy,
            isViewportSettling: true,
          ),
          const BottomAnchorTransportBehavior(
            verificationDelayFrames: 0,
            verificationRetryMode: BottomAnchorVerificationRetryMode.rescroll,
          ),
        );
      },
    );
  });

  group('stream ordering', () {
    final streamItems = [
      userMessage('u1', 'user-1'),
      assistantMessage('a1', 'assistant-1'),
      assistantMessage('a2', 'assistant-2'),
    ];

    test('keeps forward_stream order unchanged for tail and head', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );

      final tail = strategy.orderTail(streamItems);
      final head = strategy.orderHead(streamItems);

      expect(tail.map((item) => item.item.id), ['u1', 'a1', 'a2']);
      expect(head.map((item) => item.item.id), ['u1', 'a1', 'a2']);
    });

    test('reverses inverted_stream order for tail and head', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'android',
        isMobileBreakpoint: false,
      );

      final tail = strategy.orderTail(streamItems);
      final head = strategy.orderHead(streamItems);

      expect(tail.map((item) => item.item.id), ['a2', 'a1', 'u1']);
      expect(head.map((item) => item.item.id), ['a2', 'a1', 'u1']);
    });
  });

  group('neighbor and traversal semantics', () {
    test('maps above/below indices for forward and inverted streams', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );
      final inverted = resolveStreamRenderStrategy(
        platform: 'ios',
        isMobileBreakpoint: false,
      );

      expect(forward.getNeighborIndex(3, NeighborRelation.above), 2);
      expect(forward.getNeighborIndex(3, NeighborRelation.below), 4);
      expect(inverted.getNeighborIndex(3, NeighborRelation.above), 4);
      expect(inverted.getNeighborIndex(3, NeighborRelation.below), 2);
    });

    test(
      'collects assistant turn content with strategy traversal direction',
      () {
        final chronological = [
          userMessage('u1', 'user-1'),
          assistantMessage('a1', 'assistant-1'),
          assistantMessage('a2', 'assistant-2'),
          userMessage('u2', 'user-2'),
        ];

        final forward = resolveStreamRenderStrategy(
          platform: 'web',
          isMobileBreakpoint: false,
        );
        final forwardStartIndex = chronological.indexWhere(
          (item) => item.item.id == 'a2',
        );
        expect(
          forward.collectAssistantTurnContent(chronological, forwardStartIndex),
          'assistant-1\n\nassistant-2',
        );

        final inverted = resolveStreamRenderStrategy(
          platform: 'android',
          isMobileBreakpoint: false,
        );
        final invertedItems = inverted.orderTail(chronological);
        final invertedStartIndex = invertedItems.indexWhere(
          (item) => item.item.id == 'a2',
        );
        expect(
          inverted.collectAssistantTurnContent(
            invertedItems,
            invertedStartIndex,
          ),
          'assistant-1\n\nassistant-2',
        );
      },
    );

    test('returns null neighbor when index would be out of bounds', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );
      final items = [userMessage('u1', 'user-1')];

      expect(forward.getNeighborItem(items, 0, NeighborRelation.above), isNull);
      expect(forward.getNeighborItem(items, 0, NeighborRelation.below), isNull);
    });
  });

  group('scroll/bottom calculations', () {
    test(
      'computes near-bottom using forward_stream distance-from-bottom math',
      () {
        final strategy = resolveStreamRenderStrategy(
          platform: 'web',
          isMobileBreakpoint: false,
        );

        expect(
          strategy.isNearBottom(
            offsetY: 680,
            viewportHeight: 300,
            contentHeight: 1000,
            threshold: 24,
          ),
          isTrue,
        );
        expect(
          strategy.isNearBottom(
            offsetY: 600,
            viewportHeight: 300,
            contentHeight: 1000,
            threshold: 24,
          ),
          isFalse,
        );
      },
    );

    test(
      'computes near-bottom and scroll-to-bottom offset for inverted_stream',
      () {
        final strategy = resolveStreamRenderStrategy(
          platform: 'ios',
          isMobileBreakpoint: false,
        );

        expect(
          strategy.isNearBottom(
            offsetY: 12,
            viewportHeight: 300,
            contentHeight: 1000,
            threshold: 24,
          ),
          isTrue,
        );
        expect(
          strategy.isNearBottom(
            offsetY: 40,
            viewportHeight: 300,
            contentHeight: 1000,
            threshold: 24,
          ),
          isFalse,
        );
        expect(
          strategy.getBottomOffset(viewportHeight: 300, contentHeight: 1000),
          0,
        );
      },
    );

    test('maps scroll-to-bottom to max offset for forward_stream', () {
      final strategy = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );

      expect(
        strategy.getBottomOffset(viewportHeight: 320, contentHeight: 1000),
        680,
      );
    });
  });

  group('edge slot semantics', () {
    test(
      'uses footer slot for forward_stream and header slot for inverted_stream',
      () {
        final forward = resolveStreamRenderStrategy(
          platform: 'web',
          isMobileBreakpoint: false,
        );
        final inverted = resolveStreamRenderStrategy(
          platform: 'android',
          isMobileBreakpoint: false,
        );

        expect(forward.edgeSlot, StreamEdgeSlot.footer);
        expect(inverted.edgeSlot, StreamEdgeSlot.header);
      },
    );
  });

  group('layout strategy edges', () {
    final streamItems = [
      userMessage('u1', 'user-1'),
      assistantMessage('a1', 'assistant-1'),
    ];

    test('uses the newest history edge as the history/live boundary', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );
      final inverted = resolveStreamRenderStrategy(
        platform: 'android',
        isMobileBreakpoint: false,
      );

      final forwardHistory = forward.orderTail(streamItems);
      final invertedHistory = inverted.orderTail(streamItems);

      expect(forward.getHistoryLiveBoundaryIndex(forwardHistory), 1);
      expect(inverted.getHistoryLiveBoundaryIndex(invertedHistory), 0);
    });

    test(
      'uses the oldest live-head edge as the live-head/history boundary',
      () {
        final forward = resolveStreamRenderStrategy(
          platform: 'web',
          isMobileBreakpoint: false,
        );
        final inverted = resolveStreamRenderStrategy(
          platform: 'ios',
          isMobileBreakpoint: false,
        );

        final forwardHead = forward.orderHead(streamItems);
        final invertedHead = inverted.orderHead(streamItems);

        expect(forward.getLiveHeadHistoryBoundaryIndex(forwardHead), 0);
        expect(inverted.getLiveHeadHistoryBoundaryIndex(invertedHead), 1);
      },
    );

    test('names the frame child order needed by native inverted cells', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );
      final inverted = resolveStreamRenderStrategy(
        platform: 'android',
        isMobileBreakpoint: false,
      );

      expect(forward.frameChildOrder, StreamFrameChildOrder.contentThenFooter);
      expect(inverted.frameChildOrder, StreamFrameChildOrder.footerThenContent);
    });

    test('reports null history/live boundaries for empty lists', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );

      expect(forward.getHistoryLiveBoundaryIndex(const []), isNull);
      expect(forward.getLiveHeadHistoryBoundaryIndex(const []), isNull);
      expect(forward.getLatestItemIndex(const []), isNull);
    });

    test('getLatestItemIndex follows the history/live boundary edge', () {
      final forward = resolveStreamRenderStrategy(
        platform: 'web',
        isMobileBreakpoint: false,
      );
      final inverted = resolveStreamRenderStrategy(
        platform: 'android',
        isMobileBreakpoint: false,
      );

      expect(forward.getLatestItemIndex(streamItems), 1);
      expect(inverted.getLatestItemIndex(streamItems), 0);
    });
  });
}
