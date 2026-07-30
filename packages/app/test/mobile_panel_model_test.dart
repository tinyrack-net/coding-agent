import 'package:coding_agent_app/mobile_panels/mobile_panel_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MobilePanelSelection', () {
    test('starts on agent and increments only for a changed target', () {
      const initial = MobilePanelSelection.initial();

      expect(initial.target, MobilePanelView.agent);
      expect(initial.revision, 0);
      expect(
        identical(initial.setTarget(MobilePanelView.agent), initial),
        isTrue,
      );

      final opened = initial.setTarget(MobilePanelView.agentList);
      expect(opened.target, MobilePanelView.agentList);
      expect(opened.revision, 1);
      expect(
        opened.setTarget(MobilePanelView.fileExplorer),
        const MobilePanelSelection(
          target: MobilePanelView.fileExplorer,
          revision: 2,
        ),
      );
    });
  });

  group('transitionMobilePanel', () {
    test('ignores stale commands and animates newer selections', () {
      final initial = MobilePanelMotionState.fromSelection(
        const MobilePanelSelection(target: MobilePanelView.agent, revision: 3),
      );

      final stale = transitionMobilePanel(
        initial,
        const MobilePanelCommand(
          MobilePanelSelection(target: MobilePanelView.agentList, revision: 3),
        ),
      );
      expect(identical(stale.state, initial), isTrue);

      final next = transitionMobilePanel(
        initial,
        const MobilePanelCommand(
          MobilePanelSelection(
            target: MobilePanelView.fileExplorer,
            revision: 4,
          ),
        ),
      );
      expect(next.animationTarget, MobilePanelView.fileExplorer);
      expect(next.state.target, MobilePanelView.fileExplorer);
      expect(next.state.motionTarget, MobilePanelView.fileExplorer);
      expect(next.state.settledTarget, MobilePanelView.agent);
      expect(next.state.revision, 4);
    });

    test('begins only from the canonical settled target', () {
      final initial = MobilePanelMotionState.fromSelection(
        const MobilePanelSelection.initial(),
      );
      final begun = transitionMobilePanel(
        initial,
        const MobilePanelGestureBegin(MobilePanelView.agent),
      );
      expect(begun.state.gesture?.startedRevision, 0);

      final duplicate = transitionMobilePanel(
        begun.state,
        const MobilePanelGestureBegin(MobilePanelView.agent),
      );
      expect(identical(duplicate.state, begun.state), isTrue);

      final wrongOrigin = transitionMobilePanel(
        initial,
        const MobilePanelGestureBegin(MobilePanelView.agentList),
      );
      expect(identical(wrongOrigin.state, initial), isTrue);
    });

    test('commits a current successful gesture and rejects stale finishes', () {
      final initial = MobilePanelMotionState.fromSelection(
        const MobilePanelSelection(target: MobilePanelView.agent, revision: 7),
      );
      final begun = transitionMobilePanel(
        initial,
        const MobilePanelGestureBegin(MobilePanelView.agent),
      ).state;

      final stale = transitionMobilePanel(
        begun,
        const MobilePanelGestureFinish(
          startedRevision: 6,
          success: true,
          target: MobilePanelView.agentList,
        ),
      );
      expect(identical(stale.state, begun), isTrue);

      final finished = transitionMobilePanel(
        begun,
        const MobilePanelGestureFinish(
          startedRevision: 7,
          success: true,
          target: MobilePanelView.agentList,
        ),
      );
      expect(finished.animationTarget, MobilePanelView.agentList);
      expect(finished.commit?.startedRevision, 7);
      expect(finished.commit?.target, MobilePanelView.agentList);
      expect(finished.state.gesture, isNull);
      expect(finished.state.motionTarget, MobilePanelView.agentList);
      expect(finished.state.target, MobilePanelView.agent);
    });

    test('failed and cancelled gestures animate to the canonical target', () {
      final initial = MobilePanelMotionState.fromSelection(
        const MobilePanelSelection(
          target: MobilePanelView.agentList,
          revision: 2,
        ),
      );
      final begun = transitionMobilePanel(
        initial,
        const MobilePanelGestureBegin(MobilePanelView.agentList),
      ).state;
      final cancelled = transitionMobilePanel(
        begun,
        const MobilePanelGestureFinish(
          startedRevision: 2,
          success: false,
          target: MobilePanelView.agent,
        ),
      );

      expect(cancelled.animationTarget, MobilePanelView.agentList);
      expect(cancelled.commit, isNull);
      expect(cancelled.state.motionTarget, MobilePanelView.agentList);
    });

    test('settles only the current canonical animation', () {
      final commanded = transitionMobilePanel(
        MobilePanelMotionState.fromSelection(
          const MobilePanelSelection.initial(),
        ),
        const MobilePanelCommand(
          MobilePanelSelection(
            target: MobilePanelView.fileExplorer,
            revision: 1,
          ),
        ),
      ).state;

      final stale = transitionMobilePanel(
        commanded,
        const MobilePanelAnimationFinished(
          revision: 0,
          target: MobilePanelView.fileExplorer,
        ),
      );
      expect(identical(stale.state, commanded), isTrue);

      final settled = transitionMobilePanel(
        commanded,
        const MobilePanelAnimationFinished(
          revision: 1,
          target: MobilePanelView.fileExplorer,
        ),
      );
      expect(settled.state.settledTarget, MobilePanelView.fileExplorer);
    });
  });

  test('gesture guards require the matching settled anchor and revision', () {
    final state = MobilePanelMotionState.fromSelection(
      const MobilePanelSelection(
        target: MobilePanelView.agentList,
        revision: 9,
      ),
    );
    expect(
      canBeginMobilePanelGesture(state, MobilePanelView.agentList, -1),
      isTrue,
    );
    expect(
      canBeginMobilePanelGesture(state, MobilePanelView.agentList, -0.99),
      isFalse,
    );
    final begun = transitionMobilePanel(
      state,
      const MobilePanelGestureBegin(MobilePanelView.agentList),
    ).state;
    expect(isMobilePanelGestureCurrent(begun, 9), isTrue);
    expect(isMobilePanelGestureCurrent(begun, 8), isFalse);
  });

  test('anchors and frames match the frozen left and right geometry', () {
    expect(getMobilePanelAnchor(MobilePanelView.agentList), -1);
    expect(getMobilePanelAnchor(MobilePanelView.agent), 0);
    expect(getMobilePanelAnchor(MobilePanelView.fileExplorer), 1);

    final left = getMobilePanelFrame(-1, 500);
    expect(left.leftBackdropOpacity, 1);
    expect(left.leftTranslateX, 0);
    expect(left.rightBackdropOpacity, 0);
    expect(left.rightTranslateX, 500);

    final center = getMobilePanelFrame(0, 500);
    expect(center.leftBackdropOpacity, 0);
    expect(center.leftTranslateX, -500);
    expect(center.rightBackdropOpacity, 0);
    expect(center.rightTranslateX, 500);

    final right = getMobilePanelFrame(1, 500);
    expect(right.leftBackdropOpacity, 0);
    expect(right.leftTranslateX, -500);
    expect(right.rightBackdropOpacity, 1);
    expect(right.rightTranslateX, 0);
  });
}
