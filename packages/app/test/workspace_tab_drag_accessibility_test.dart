import 'package:coding_agent_app/workspace/workspace_tab_drag_accessibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const activeId = 'tab-1:agent';
  const overId = 'tab-2:terminal';

  test('matches dnd-kit 6.3.1 default screen reader copy exactly', () {
    expect(
      workspaceTabDragScreenReaderInstructions,
      'To pick up a draggable item, press the space bar. '
      'While dragging, use the arrow keys to move the item. '
      'Press space again to drop the item in its new position, or press escape '
      'to cancel.',
    );
    expect(
      workspaceTabDragStartAnnouncement(activeId),
      'Picked up draggable item tab-1:agent.',
    );
    expect(
      workspaceTabDragOverAnnouncement(activeId, overId),
      'Draggable item tab-1:agent was moved over droppable area '
      'tab-2:terminal.',
    );
    expect(
      workspaceTabDragOverAnnouncement(activeId, null),
      'Draggable item tab-1:agent is no longer over a droppable area.',
    );
    expect(
      workspaceTabDragEndAnnouncement(activeId, overId),
      'Draggable item tab-1:agent was dropped over droppable area '
      'tab-2:terminal',
    );
    expect(
      workspaceTabDragEndAnnouncement(activeId, null),
      'Draggable item tab-1:agent was dropped.',
    );
    expect(
      workspaceTabDragCancelAnnouncement(activeId),
      'Dragging was cancelled. Draggable item tab-1:agent was dropped.',
    );
  });

  test(
    'announces changed over targets once and completes with the last one',
    () {
      final announcements = <String>[];
      final session = WorkspaceTabDragAccessibilitySession(
        activeId: activeId,
        announcementSink: announcements.add,
      );

      session.start();
      session.start();
      session.moveOver(activeId);
      session.moveOver(activeId);
      session.moveOver(overId);
      session.leave(activeId);
      session.end();
      session.end();

      expect(announcements, [
        workspaceTabDragStartAnnouncement(activeId),
        workspaceTabDragOverAnnouncement(activeId, activeId),
        workspaceTabDragOverAnnouncement(activeId, overId),
        workspaceTabDragEndAnnouncement(activeId, overId),
      ]);
      expect(session.isStarted, isFalse);
      expect(session.overId, isNull);
    },
  );

  test('leave and cancel reproduce the no-target and cancel announcements', () {
    final announcements = <String>[];
    final session = WorkspaceTabDragAccessibilitySession(
      activeId: activeId,
      announcementSink: announcements.add,
    );

    session.start();
    session.moveOver(overId);
    session.leave(overId);
    session.cancel();

    expect(announcements, [
      workspaceTabDragStartAnnouncement(activeId),
      workspaceTabDragOverAnnouncement(activeId, overId),
      workspaceTabDragOverAnnouncement(activeId, null),
      workspaceTabDragCancelAnnouncement(activeId),
    ]);
  });
}
