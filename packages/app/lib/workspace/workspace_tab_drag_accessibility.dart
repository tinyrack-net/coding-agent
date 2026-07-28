import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const workspaceTabDragScreenReaderInstructions =
    'To pick up a draggable item, press the space bar. '
    'While dragging, use the arrow keys to move the item. '
    'Press space again to drop the item in its new position, or press escape '
    'to cancel.';

String workspaceTabDragStartAnnouncement(String activeId) =>
    'Picked up draggable item $activeId.';

String workspaceTabDragOverAnnouncement(String activeId, String? overId) =>
    overId == null
    ? 'Draggable item $activeId is no longer over a droppable area.'
    : 'Draggable item $activeId was moved over droppable area $overId.';

String workspaceTabDragEndAnnouncement(String activeId, String? overId) =>
    overId == null
    ? 'Draggable item $activeId was dropped.'
    : 'Draggable item $activeId was dropped over droppable area $overId';

String workspaceTabDragCancelAnnouncement(String activeId) =>
    'Dragging was cancelled. Draggable item $activeId was dropped.';

typedef WorkspaceTabDragAnnouncer =
    void Function(BuildContext context, String message);

final workspaceTabDragAnnouncerProvider = Provider<WorkspaceTabDragAnnouncer>(
  (ref) => (context, message) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  },
);

/// Deduplicates live-region updates in the same way dnd-kit's accessibility
/// monitor announces only changes to the current `over` target.
final class WorkspaceTabDragAccessibilitySession {
  WorkspaceTabDragAccessibilitySession({
    required this.activeId,
    required this.announcementSink,
  });

  final String activeId;
  final void Function(String message) announcementSink;
  String? _overId;
  bool _started = false;

  String? get overId => _overId;
  bool get isStarted => _started;

  void start() {
    if (_started) return;
    _started = true;
    _overId = null;
    announcementSink(workspaceTabDragStartAnnouncement(activeId));
  }

  void moveOver(String? overId) {
    if (!_started || _overId == overId) return;
    _overId = overId;
    announcementSink(workspaceTabDragOverAnnouncement(activeId, overId));
  }

  void leave(String overId) {
    if (!_started || _overId != overId) return;
    moveOver(null);
  }

  void end() {
    if (!_started) return;
    announcementSink(workspaceTabDragEndAnnouncement(activeId, _overId));
    _reset();
  }

  void cancel() {
    if (!_started) return;
    announcementSink(workspaceTabDragCancelAnnouncement(activeId));
    _reset();
  }

  void _reset() {
    _started = false;
    _overId = null;
  }
}
