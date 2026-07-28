import 'package:coding_agent_app/workspace/workspace_deck_retention.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceDeckSelection workspace(
  String workspaceId, [
  String serverId = 'server',
]) => WorkspaceDeckSelection(
  serverId: serverId,
  workspaceId: workspaceId,
  worktreePath: '/$workspaceId',
);

List<String> ids(List<WorkspaceDeckSelection> selections) =>
    selections.map((selection) => selection.workspaceId).toList();

void main() {
  test('retains the same deck while the active workspace is null', () {
    final mounted = [workspace('A'), workspace('B')];
    expect(
      pruneMountedWorkspaceSelections(
        currentSelections: mounted,
        activeSelection: null,
      ),
      same(mounted),
    );
  });

  test('keeps the active and two most recent inactive workspaces', () {
    var mounted = <WorkspaceDeckSelection>[];
    for (final id in const ['A', 'B', 'C', 'D']) {
      mounted = pruneMountedWorkspaceSelections(
        currentSelections: mounted,
        activeSelection: workspace(id),
      );
    }
    expect(ids(mounted), const ['D', 'C', 'B']);
  });

  test('retains active, deduplicates, and permits at least one entry', () {
    expect(
      ids(
        pruneMountedWorkspaceSelections(
          currentSelections: [workspace('B'), workspace('A'), workspace('B')],
          activeSelection: workspace('A'),
        ),
      ),
      const ['A', 'B'],
    );
    expect(
      ids(
        pruneMountedWorkspaceSelections(
          currentSelections: [workspace('A'), workspace('B')],
          activeSelection: workspace('C'),
          maxMountedWorkspaces: 0,
        ),
      ),
      const ['C'],
    );
  });

  test('uses server and workspace as identity, not the local path', () {
    final left = WorkspaceDeckSelection(
      serverId: 'server',
      workspaceId: 'workspace',
      worktreePath: '/old',
    );
    final right = WorkspaceDeckSelection(
      serverId: 'server',
      workspaceId: 'workspace',
      worktreePath: '/new',
    );
    expect(left, right);
    expect(workspace('workspace', 'one'), isNot(workspace('workspace', 'two')));
  });

  test('orders retained roots by stable composite key', () {
    expect(
      ids(
        orderWorkspaceSelectionsForStableRender([
          workspace('B'),
          workspace('A'),
        ]),
      ),
      const ['A', 'B'],
    );
    expect(
      ids(
        orderWorkspaceSelectionsForStableRender([
          workspace('A'),
          workspace('B'),
        ]),
      ),
      const ['A', 'B'],
    );
  });

  test('mount policy preserves active and pre-hydration entries', () {
    expect(
      shouldKeepWorkspaceDeckEntryMounted(
        isActive: true,
        hasHydratedWorkspaces: true,
        workspaceExists: false,
      ),
      isTrue,
    );
    expect(
      shouldKeepWorkspaceDeckEntryMounted(
        isActive: false,
        hasHydratedWorkspaces: false,
        workspaceExists: false,
      ),
      isTrue,
    );
    expect(
      shouldKeepWorkspaceDeckEntryMounted(
        isActive: false,
        hasHydratedWorkspaces: true,
        workspaceExists: false,
      ),
      isFalse,
    );
    expect(
      shouldKeepWorkspaceDeckEntryMounted(
        isActive: false,
        hasHydratedWorkspaces: true,
        workspaceExists: true,
      ),
      isTrue,
    );
  });

  test(
    'controller preserves pre-hydration entries and prunes deleted ones',
    () {
      final controller = WorkspaceDeckRetentionController();
      final first = workspace('A');
      final second = workspace('B');
      controller.reconcile(
        activeSelection: first,
        hasHydratedWorkspaces: false,
        existingWorktreePaths: const {},
      );
      expect(
        ids(
          controller.reconcile(
            activeSelection: second,
            hasHydratedWorkspaces: false,
            existingWorktreePaths: const {},
          ),
        ),
        const ['B', 'A'],
      );
      expect(
        ids(
          controller.reconcile(
            activeSelection: second,
            hasHydratedWorkspaces: true,
            existingWorktreePaths: const {'/B'},
          ),
        ),
        const ['B'],
      );
    },
  );
}
