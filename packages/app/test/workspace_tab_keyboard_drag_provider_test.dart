import 'package:coding_agent_app/state/workspace_tab_keyboard_drag_provider.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _layout = WorkspacePaneLayout(
  root: WorkspacePaneGroup(
    id: 'root',
    direction: WorkspaceSplitDirection.horizontal,
    children: [
      WorkspacePane(id: 'left', tabIds: ['one', 'two'], focusedTabId: 'one'),
      WorkspacePane(
        id: 'right',
        tabIds: ['three', 'four'],
        focusedTabId: 'four',
      ),
    ],
    sizes: [.5, .5],
  ),
  focusedPaneId: 'left',
);

void main() {
  test('keyboard coordinates move inline then into an adjacent pane', () {
    const start = WorkspaceKeyboardTabDrag(
      activePaneId: 'left',
      activeTabId: 'one',
      overPaneId: 'left',
      overTabId: 'one',
      overIndex: 0,
    );
    final inline = moveWorkspaceKeyboardTabDrag(
      drag: start,
      layout: _layout,
      direction: WorkspaceKeyboardDragDirection.right,
    );
    expect(inline.overTabId, 'two');
    expect(inline.overIndex, 1);

    final adjacent = moveWorkspaceKeyboardTabDrag(
      drag: inline,
      layout: _layout,
      direction: WorkspaceKeyboardDragDirection.right,
    );
    expect(adjacent.overPaneId, 'right');
    expect(adjacent.overTabId, 'four');
    expect(adjacent.overIndex, 1);
  });

  test('invalid and empty destinations keep the current coordinates', () {
    const emptyLayout = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'root',
        direction: WorkspaceSplitDirection.vertical,
        children: [
          WorkspacePane(id: 'top', tabIds: ['one']),
          WorkspacePane(id: 'bottom', tabIds: []),
        ],
        sizes: [.5, .5],
      ),
      focusedPaneId: 'top',
    );
    const start = WorkspaceKeyboardTabDrag(
      activePaneId: 'top',
      activeTabId: 'one',
      overPaneId: 'top',
      overTabId: 'one',
      overIndex: 0,
    );
    expect(
      moveWorkspaceKeyboardTabDrag(
        drag: start,
        layout: emptyLayout,
        direction: WorkspaceKeyboardDragDirection.down,
      ),
      same(start),
    );
  });

  test('provider start, move, finish, and cancel are explicit', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      workspaceTabKeyboardDragProvider('/repo').notifier,
    );
    notifier.start(paneId: 'left', tabId: 'one', tabIndex: 0);
    notifier.move(_layout, WorkspaceKeyboardDragDirection.right);
    expect(notifier.finish()?.overTabId, 'two');
    expect(container.read(workspaceTabKeyboardDragProvider('/repo')), isNull);
    notifier.start(paneId: 'left', tabId: 'one', tabIndex: 0);
    notifier.cancel();
    expect(container.read(workspaceTabKeyboardDragProvider('/repo')), isNull);
  });
}
