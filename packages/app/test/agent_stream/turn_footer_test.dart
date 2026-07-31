// Port of the behavior in Paseo's `agent-stream/turn-footer.tsx` and the
// `AssistantTurnFooter` / `LiveElapsed` pieces of `components/message.tsx`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/layout.dart';
import 'package:coding_agent_app/agent_stream/stream_strategy.dart';
import 'package:coding_agent_app/agent_stream/turn_boundary.dart';
import 'package:coding_agent_app/agent_stream/turn_footer.dart';
import 'package:coding_agent_app/agent_stream/turn_time.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

TimelineDisplayItem user(String id) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
);

TimelineDisplayItem assistant(
  String id,
  String text, {
  String? messageId,
  StreamTimelinePosition? timelineCursor,
}) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: text, complete: true),
  messageId: messageId,
  timelineCursor: timelineCursor,
);

final _strategy = resolveStreamRenderStrategy(
  platform: 'web',
  isMobileBreakpoint: false,
);

Future<void> pumpFooter(WidgetTester tester, Widget footer) =>
    tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(AppThemeName.dark),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 420, child: footer),
        ),
      ),
    );

void main() {
  setUpAll(initializeDateFormatting);

  testWidgets('running turn shows the working indicator and live elapsed', (
    tester,
  ) async {
    final startedAt = DateTime(2026, 5, 14, 12);
    // Widget tests advance fake async time, which does not move the real
    // wall clock, so drive the ticker from an explicit clock.
    var now = startedAt.add(const Duration(seconds: 5));

    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: true,
        inFlightTurnStartedAt: startedAt,
        host: null,
        strategy: _strategy,
        supportsTimelineCursor: false,
        clock: () => now,
      ),
    );

    expect(
      find.byKey(const ValueKey('turn-working-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('turn-working-elapsed')), findsOneWidget);
    expect(find.text('5s'), findsOneWidget);

    now = startedAt.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('6s'), findsOneWidget);

    // Dispose so the periodic ticker is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a running turn without an authoritative start omits elapsed', (
    tester,
  ) async {
    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: true,
        inFlightTurnStartedAt: null,
        host: null,
        strategy: _strategy,
        supportsTimelineCursor: false,
      ),
    );

    expect(
      find.byKey(const ValueKey('turn-working-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('turn-working-elapsed')), findsNothing);
  });

  testWidgets('an idle turn with no host renders nothing', (tester) async {
    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: false,
        inFlightTurnStartedAt: null,
        host: null,
        strategy: _strategy,
        supportsTimelineCursor: false,
      ),
    );

    expect(find.byKey(const ValueKey('turn-working-indicator')), findsNothing);
    expect(find.byKey(const ValueKey('turn-copy-button')), findsNothing);
  });

  testWidgets('completed turn shows its duration and copies turn content', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final items = [
      user('u1'),
      assistant('a1', 'first paragraph'),
      assistant('a2', 'second paragraph'),
    ];
    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: false,
        inFlightTurnStartedAt: null,
        host: TurnFooterHost(
          itemId: 'a2',
          items: items,
          startIndex: 2,
          timing: TurnTiming(
            startedAt: DateTime(2026, 5, 14, 12),
            completedAt: DateTime(2026, 5, 14, 12, 2, 12),
            durationMs: 132000,
          ),
        ),
        strategy: _strategy,
        supportsTimelineCursor: false,
      ),
    );

    expect(find.text('Worked for 2m 12s'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('turn-copy-button')));
    await tester.pump();

    expect(copied, ['first paragraph\n\nsecond paragraph']);

    // Tapping leaves fluent's hover-button timer armed; drain it so the
    // binding does not report a pending timer after teardown.
    await tester.pumpAndSettle();
  });

  testWidgets('the duration label swaps to the end timestamp on hover', (
    tester,
  ) async {
    final completedAt = DateTime(2026, 5, 14, 12, 2, 12);
    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: false,
        inFlightTurnStartedAt: null,
        host: TurnFooterHost(
          itemId: 'a1',
          items: [user('u1'), assistant('a1', 'text')],
          startIndex: 1,
          timing: TurnTiming(
            startedAt: DateTime(2026, 5, 14, 12),
            completedAt: completedAt,
            durationMs: 132000,
          ),
        ),
        strategy: _strategy,
        supportsTimelineCursor: false,
      ),
    );

    expect(find.text('Worked for 2m 12s'), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('turn-duration-label'))),
    );
    await tester.pump();

    expect(find.text('Worked for 2m 12s'), findsNothing);
    expect(find.byKey(const ValueKey('turn-duration-label')), findsOneWidget);
  });

  testWidgets('a completed turn without timing omits the duration label', (
    tester,
  ) async {
    await pumpFooter(
      tester,
      TurnFooter(
        isRunning: false,
        inFlightTurnStartedAt: null,
        host: TurnFooterHost(
          itemId: 'a1',
          items: [user('u1'), assistant('a1', 'text')],
          startIndex: 1,
        ),
        strategy: _strategy,
        supportsTimelineCursor: false,
      ),
    );

    expect(find.byKey(const ValueKey('turn-copy-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-duration-label')), findsNothing);
  });

  group('fork affordance', () {
    testWidgets('is hidden without a fork handler even when forkable', (
      tester,
    ) async {
      await pumpFooter(
        tester,
        TurnFooter(
          isRunning: false,
          inFlightTurnStartedAt: null,
          host: TurnFooterHost(
            itemId: 'a1',
            items: [
              user('u1'),
              assistant('a1', 'text', messageId: 'msg-1'),
            ],
            startIndex: 1,
          ),
          strategy: _strategy,
          supportsTimelineCursor: false,
        ),
      );

      expect(find.byKey(const ValueKey('turn-fork-button')), findsNothing);
    });

    testWidgets('is hidden when the turn has no resolvable boundary', (
      tester,
    ) async {
      await pumpFooter(
        tester,
        TurnFooter(
          isRunning: false,
          inFlightTurnStartedAt: null,
          host: TurnFooterHost(
            itemId: 'a1',
            items: [user('u1'), assistant('a1', 'text')],
            startIndex: 1,
          ),
          strategy: _strategy,
          supportsTimelineCursor: false,
          onForkAssistantTurn: ({required target, required boundary}) {},
        ),
      );

      expect(find.byKey(const ValueKey('turn-fork-button')), findsNothing);
    });

    testWidgets('forks from the resolved boundary for each target', (
      tester,
    ) async {
      final forks = <(AssistantForkTarget, AssistantTurnForkBoundary)>[];
      await pumpFooter(
        tester,
        TurnFooter(
          isRunning: false,
          inFlightTurnStartedAt: null,
          host: TurnFooterHost(
            itemId: 'a1',
            items: [
              user('u1'),
              assistant(
                'a1',
                'text',
                messageId: 'msg-1',
                timelineCursor: const StreamTimelinePosition(
                  epoch: 'e1',
                  seq: 42,
                ),
              ),
            ],
            startIndex: 1,
          ),
          strategy: _strategy,
          supportsTimelineCursor: true,
          onForkAssistantTurn: ({required target, required boundary}) =>
              forks.add((target, boundary)),
        ),
      );

      expect(find.byKey(const ValueKey('turn-fork-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('turn-fork-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fork into new agent'));
      await tester.pumpAndSettle();

      expect(forks, hasLength(1));
      expect(forks.single.$1, AssistantForkTarget.newAgent);
      expect(
        forks.single.$2.boundaryCursor,
        const StreamTimelinePosition(epoch: 'e1', seq: 42),
      );
      expect(forks.single.$2.boundaryMessageId, 'msg-1');
    });
  });

  testWidgets('LiveElapsed stops ticking while inactive', (tester) async {
    final startedAt = DateTime(2026, 5, 14, 12);
    var now = startedAt.add(const Duration(seconds: 3));
    await pumpFooter(
      tester,
      LiveElapsed(startedAt: startedAt, active: false, clock: () => now),
    );

    expect(find.text('3s'), findsOneWidget);
    now = startedAt.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('3s'), findsOneWidget);
  });
}
