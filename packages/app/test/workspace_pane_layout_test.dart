import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pane tab focus changes without taking over pane focus', () {
    const layout = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'root',
        direction: WorkspaceSplitDirection.horizontal,
        children: [
          WorkspacePane(
            id: 'left',
            tabIds: ['one', 'two'],
            focusedTabId: 'two',
          ),
          WorkspacePane(id: 'right', tabIds: ['three']),
        ],
        sizes: [.5, .5],
      ),
      focusedPaneId: 'right',
    );

    final next = focusWorkspacePaneTab(
      layout: layout,
      paneId: 'left',
      tabId: 'one',
    );
    expect(findWorkspacePane(next.root, 'left')!.focusedTabId, 'one');
    expect(next.focusedPaneId, 'right');
    expect(
      focusWorkspacePaneTab(layout: next, paneId: 'left', tabId: 'missing'),
      same(next),
    );
  });

  WorkspacePaneLayout initial() => WorkspacePaneLayout.single(
    paneId: 'root',
    tabIds: const ['a', 'b'],
    focusedTabId: 'a',
  );

  test('split creates and focuses a sibling pane in the requested axis', () {
    final split = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'group',
      newTabId: 'c',
    )!;

    expect(split.focusedPaneId, 'right');
    expect(collectWorkspacePanes(split.root), hasLength(2));
    final group = split.root as WorkspacePaneGroup;
    expect(group.direction, WorkspaceSplitDirection.horizontal);
    expect(group.sizes, const [.5, .5]);
    expect(findWorkspacePane(group, 'right')!.tabIds, const ['c']);
  });

  test(
    'same-axis split flattens into the existing group and halves weight',
    () {
      final first = splitWorkspacePane(
        layout: initial(),
        targetPaneId: 'root',
        direction: WorkspaceSplitDirection.horizontal,
        newPaneId: 'middle',
        newGroupId: 'group',
        newTabId: 'c',
      )!;
      final second = splitWorkspacePane(
        layout: first,
        targetPaneId: 'root',
        direction: WorkspaceSplitDirection.horizontal,
        newPaneId: 'new-middle',
        newGroupId: 'unused',
        newTabId: 'd',
      )!;
      final group = second.root as WorkspacePaneGroup;

      expect(group.id, 'group');
      expect(group.children.map((child) => (child as WorkspacePane).id), [
        'root',
        'new-middle',
        'middle',
      ]);
      expect(group.sizes, const [.25, .25, .5]);
    },
  );

  test('pane and group wire models round-trip and reject unknown nodes', () {
    final pane =
        WorkspacePaneNode.fromJson({
              'type': 'pane',
              'id': 'pane',
              'tabIds': ['tab'],
              'focusedTabId': 'tab',
            })
            as WorkspacePane;
    expect(pane.id, 'pane');
    expect(pane.toJson(), containsPair('focusedTabId', 'tab'));

    final group =
        WorkspacePaneNode.fromJson({
              'type': 'group',
              'id': 'group',
              'direction': 'vertical',
              'children': [pane.toJson()],
              'sizes': [1],
            })
            as WorkspacePaneGroup;
    expect(group.direction, WorkspaceSplitDirection.vertical);
    expect(group.toJson()['children'], hasLength(1));
    expect(
      () => WorkspacePaneNode.fromJson({'type': 'unknown'}),
      throwsFormatException,
    );
  });

  test('directional navigation uses normalized nested split geometry', () {
    final right = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'horizontal',
      newTabId: 'c',
    )!;
    final bottomRight = splitWorkspacePane(
      layout: right,
      targetPaneId: 'right',
      direction: WorkspaceSplitDirection.vertical,
      newPaneId: 'bottom-right',
      newGroupId: 'vertical',
      newTabId: 'd',
    )!;

    expect(
      findAdjacentWorkspacePane(
        bottomRight.root,
        'root',
        WorkspacePaneDirection.right,
      ),
      'bottom-right',
    );
    expect(
      findAdjacentWorkspacePane(
        bottomRight.root,
        'right',
        WorkspacePaneDirection.down,
      ),
      'bottom-right',
    );
    expect(
      findAdjacentWorkspacePane(
        bottomRight.root,
        'bottom-right',
        WorkspacePaneDirection.left,
      ),
      'root',
    );
    expect(
      findAdjacentWorkspacePane(
        bottomRight.root,
        'root',
        WorkspacePaneDirection.left,
      ),
      isNull,
    );
  });

  test('moving the last tab collapses its source pane', () {
    final split = splitWorkspacePane(
      layout: WorkspacePaneLayout.single(paneId: 'left', tabIds: const ['a']),
      targetPaneId: 'left',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'group',
      newTabId: 'b',
    )!;

    final moved = moveWorkspaceTabToPane(
      layout: split,
      tabId: 'a',
      targetPaneId: 'right',
    );

    expect(collectWorkspacePanes(moved.root), hasLength(1));
    expect(moved.focusedPaneId, 'right');
    expect(findWorkspacePane(moved.root, 'right')!.tabIds, const ['b', 'a']);
  });

  test('invalid pane operations are stable no-ops', () {
    final layout = initial();
    expect(removeWorkspacePane(layout, 'root'), isNull);
    expect(removeWorkspacePane(layout, 'missing'), isNull);
    expect(
      splitWorkspacePane(
        layout: layout,
        targetPaneId: 'missing',
        direction: WorkspaceSplitDirection.horizontal,
        newPaneId: 'new',
        newGroupId: 'group',
        newTabId: 'tab',
      ),
      isNull,
    );
    expect(
      moveWorkspaceTabToPane(
        layout: layout,
        tabId: 'missing',
        targetPaneId: 'root',
      ),
      same(layout),
    );
    expect(
      moveWorkspaceTabToPane(layout: layout, tabId: 'a', targetPaneId: 'root'),
      same(layout),
    );
    expect(findWorkspacePane(layout.root, 'missing'), isNull);
    expect(findWorkspacePaneContainingTab(layout.root, 'missing'), isNull);
    expect(
      findAdjacentWorkspacePane(
        layout.root,
        'missing',
        WorkspacePaneDirection.left,
      ),
      isNull,
    );
    expect(
      findAdjacentWorkspacePane(layout.root, 'root', WorkspacePaneDirection.up),
      isNull,
    );
  });

  test('malformed persisted group sizes use stable equal-size fallbacks', () {
    const panes = [
      WorkspacePane(id: 'left', tabIds: ['a']),
      WorkspacePane(id: 'middle', tabIds: ['b']),
      WorkspacePane(id: 'right', tabIds: ['c']),
    ];
    const missingSizes = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'group',
        direction: WorkspaceSplitDirection.horizontal,
        children: panes,
        sizes: [],
      ),
      focusedPaneId: 'left',
    );
    final split = splitWorkspacePane(
      layout: missingSizes,
      targetPaneId: 'left',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'new',
      newGroupId: 'unused',
      newTabId: 'd',
    )!;
    expect((split.root as WorkspacePaneGroup).sizes, const [
      1 / 6,
      1 / 6,
      1 / 3,
      1 / 3,
    ]);
    expect(
      findAdjacentWorkspacePane(
        missingSizes.root,
        'left',
        WorkspacePaneDirection.right,
      ),
      'middle',
    );

    const zeroSizes = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'zero-group',
        direction: WorkspaceSplitDirection.horizontal,
        children: panes,
        sizes: [0, 0, 0],
      ),
      focusedPaneId: 'middle',
    );
    final removed = removeWorkspacePane(zeroSizes, 'middle')!;
    expect((removed.root as WorkspacePaneGroup).sizes, const [.5, .5]);
    expect(
      findAdjacentWorkspacePane(
        zeroSizes.root,
        'left',
        WorkspacePaneDirection.right,
      ),
      'middle',
    );
  });

  test('remove unwraps groups and normalizes persisted JSON', () {
    final split = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.vertical,
      newPaneId: 'bottom',
      newGroupId: 'group',
      newTabId: 'c',
    )!;
    final removed = removeWorkspacePane(split, 'bottom')!;
    final restored = WorkspacePaneLayout.fromJson(removed.toJson());

    expect(restored.root, isA<WorkspacePane>());
    expect(restored.focusedPaneId, 'root');
    expect((restored.root as WorkspacePane).tabIds, const ['a', 'b']);
  });

  test('remove from a three-pane group preserves and normalizes siblings', () {
    final two = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'middle',
      newGroupId: 'group',
      newTabId: 'c',
    )!;
    final three = splitWorkspacePane(
      layout: two,
      targetPaneId: 'middle',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'unused',
      newTabId: 'd',
    )!;
    final removed = removeWorkspacePane(three, 'middle')!;
    final group = removed.root as WorkspacePaneGroup;

    expect(group.children, hasLength(2));
    expect(group.sizes.reduce((left, right) => left + right), closeTo(1, 1e-9));
    expect(group.sizes, const [2 / 3, 1 / 3]);
    expect(removed.focusedPaneId, 'right');
  });

  test('reconcile removes stale ids and assigns new ids to focused pane', () {
    final reconciled = reconcileWorkspacePaneLayout(
      layout: initial(),
      tabIds: const ['b', 'new'],
      preferredTabId: 'new',
    );

    final pane = findWorkspacePane(reconciled.root, 'root')!;
    expect(pane.tabIds, const ['b', 'new']);
    expect(pane.focusedTabId, 'new');
  });

  test('split refuses a fifth tree level', () {
    var layout = WorkspacePaneLayout.single(
      paneId: 'pane-0',
      tabIds: const ['tab-0'],
    );
    for (var index = 1; index < WorkspacePaneLayout.maxTreeDepth; index++) {
      layout = splitWorkspacePane(
        layout: layout,
        targetPaneId: 'pane-${index - 1}',
        direction: index.isOdd
            ? WorkspaceSplitDirection.horizontal
            : WorkspaceSplitDirection.vertical,
        newPaneId: 'pane-$index',
        newGroupId: 'group-$index',
        newTabId: 'tab-$index',
      )!;
    }
    expect(
      splitWorkspacePane(
        layout: layout,
        targetPaneId: 'pane-${WorkspacePaneLayout.maxTreeDepth - 1}',
        direction: WorkspaceSplitDirection.vertical,
        newPaneId: 'too-deep',
        newGroupId: 'too-deep-group',
        newTabId: 'too-deep-tab',
      ),
      isNull,
    );
  });

  test('normalized sizes preserve weight while enforcing ten percent', () {
    expect(clampNormalizedWorkspaceSizes(const []), isEmpty);
    expect(clampNormalizedWorkspaceSizes(const [4]), const [1]);
    expect(
      clampNormalizedWorkspaceSizes(const [double.nan, -1, 0]),
      everyElement(closeTo(1 / 3, 0.000001)),
    );

    final clamped = clampNormalizedWorkspaceSizes(const [.01, .19, .8]);
    expect(clamped[0], closeTo(.1, 0.000001));
    expect(clamped[1], closeTo(.1727272727, 0.000001));
    expect(clamped[2], closeTo(.7272727273, 0.000001));
    expect(clamped.reduce((left, right) => left + right), closeTo(1, 1e-9));
    expect(
      clampNormalizedWorkspaceSizes(List.filled(11, 1)),
      everyElement(closeTo(1 / 11, 1e-9)),
    );
  });

  test('resize handles preserve pair weight and clamp adjacent panes', () {
    final resized = computeWorkspaceResizeHandleSizes(
      sizes: const [.3, .2, .5],
      index: 0,
      deltaRatio: .1,
    );
    expect(resized[0], closeTo(.4, 1e-9));
    expect(resized[1], closeTo(.1, 1e-9));
    expect(resized[2], closeTo(.5, 1e-9));
    final maxed = computeWorkspaceResizeHandleSizes(
      sizes: const [.3, .2, .5],
      index: 0,
      deltaRatio: 1,
    );
    expect(maxed[0], closeTo(.4, 1e-9));
    expect(maxed[1], closeTo(.1, 1e-9));
    expect(maxed[2], closeTo(.5, 1e-9));
    expect(
      computeWorkspaceResizeHandleSizes(
        sizes: const [.04, .06, .9],
        index: 0,
        deltaRatio: -.5,
      ),
      const [.05, .05, .9],
    );
    expect(
      computeWorkspaceResizeHandleSizes(
        sizes: const [.5, .5],
        index: 2,
        deltaRatio: .2,
      ),
      const [.5, .5],
    );
  });

  test('resize updates only the addressed group and normalizes sizes', () {
    final split = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'group',
      newTabId: 'c',
    )!;
    final resized = resizeWorkspaceSplit(
      layout: split,
      groupId: 'group',
      sizes: const [.8, .2],
    );

    expect((resized.root as WorkspacePaneGroup).sizes, const [.8, .2]);
    expect(resized.focusedPaneId, split.focusedPaneId);
    expect(
      resizeWorkspaceSplit(
        layout: resized,
        groupId: 'missing',
        sizes: const [.2, .8],
      ).root,
      isA<WorkspacePaneGroup>(),
    );
  });

  test('tab reorder accepts each valid id once then retains omissions', () {
    final reordered = reorderWorkspacePaneTabs(
      layout: initial(),
      paneId: 'root',
      tabIds: const ['b', 'b', 'missing'],
    )!;
    final pane = reordered.root as WorkspacePane;

    expect(pane.tabIds, const ['b', 'a']);
    expect(pane.focusedTabId, 'a');
    expect(reordered.focusedPaneId, 'root');
    expect(
      reorderWorkspacePaneTabs(
        layout: initial(),
        paneId: 'missing',
        tabIds: const ['a'],
      ),
      isNull,
    );
    final empty = WorkspacePaneLayout.single(paneId: 'empty', tabIds: const []);
    expect(
      (reorderWorkspacePaneTabs(
                layout: empty,
                paneId: 'empty',
                tabIds: const ['missing'],
              )!.root
              as WorkspacePane)
          .focusedTabId,
      isNull,
    );
  });

  test('drop preview matches same-pane and cross-pane insertion rules', () {
    final before = computeWorkspaceTabDropPreview(
      activePaneId: 'left',
      activeTabId: 'a',
      overPaneId: 'right',
      overTabId: 'c',
      targetTabIds: const ['c', 'd'],
      activeCenterX: 20,
      overCenterX: 30,
      overWidth: 40,
    )!;
    expect(before.insertionIndex, 0);
    expect(before.indicatorIndex, 0);

    final afterSamePane = computeWorkspaceTabDropPreview(
      activePaneId: 'root',
      activeTabId: 'a',
      overPaneId: 'root',
      overTabId: 'c',
      targetTabIds: const ['a', 'b', 'c'],
      activeCenterX: 40,
      overCenterX: 30,
      overWidth: 40,
    )!;
    expect(afterSamePane.insertionIndex, 2);
    expect(afterSamePane.indicatorIndex, 3);
    expect(
      computeWorkspaceTabDropPreview(
        activePaneId: 'root',
        activeTabId: 'missing',
        overPaneId: 'root',
        overTabId: 'c',
        targetTabIds: const ['a', 'b', 'c'],
        activeCenterX: 40,
        overCenterX: 30,
        overWidth: 40,
      ),
      isNull,
    );
  });

  test('split drop position uses center, edge, then nearest-edge rules', () {
    WorkspaceSplitDropPosition resolve(double x, double y) =>
        resolveWorkspaceSplitDropPosition(width: 100, height: 80, x: x, y: y);

    expect(resolve(50, 40), WorkspaceSplitDropPosition.center);
    expect(resolve(10, 40), WorkspaceSplitDropPosition.left);
    expect(resolve(90, 40), WorkspaceSplitDropPosition.right);
    expect(resolve(50, 8), WorkspaceSplitDropPosition.top);
    expect(resolve(50, 72), WorkspaceSplitDropPosition.bottom);
    expect(resolve(20, 20), WorkspaceSplitDropPosition.left);
    expect(resolve(80, 20), WorkspaceSplitDropPosition.right);
    expect(resolve(50, 20), WorkspaceSplitDropPosition.top);
  });

  test('edge split detaches the tab and inserts before or after target', () {
    final samePane = splitWorkspaceTabAtPosition(
      layout: initial(),
      tabId: 'a',
      targetPaneId: 'root',
      position: WorkspaceSplitDropPosition.left,
      newPaneId: 'left',
      newGroupId: 'group',
    )!;
    final sameGroup = samePane.root as WorkspacePaneGroup;
    expect(sameGroup.direction, WorkspaceSplitDirection.horizontal);
    expect(sameGroup.children.map((node) => (node as WorkspacePane).id), [
      'left',
      'root',
    ]);
    expect(findWorkspacePane(sameGroup, 'left')!.tabIds, ['a']);
    expect(findWorkspacePane(sameGroup, 'root')!.tabIds, ['b']);

    final horizontal = splitWorkspacePane(
      layout: WorkspacePaneLayout.single(paneId: 'source', tabIds: const ['a']),
      targetPaneId: 'source',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'target',
      newGroupId: 'horizontal',
      newTabId: 'b',
    )!;
    final crossPane = splitWorkspaceTabAtPosition(
      layout: horizontal,
      tabId: 'a',
      targetPaneId: 'target',
      position: WorkspaceSplitDropPosition.bottom,
      newPaneId: 'bottom',
      newGroupId: 'vertical',
    )!;
    final crossGroup = crossPane.root as WorkspacePaneGroup;
    expect(crossGroup.direction, WorkspaceSplitDirection.vertical);
    expect(crossGroup.children.map((node) => (node as WorkspacePane).id), [
      'target',
      'bottom',
    ]);
    expect(crossPane.focusedPaneId, 'bottom');
  });

  test('edge split flattens same-axis parents and rejects invalid input', () {
    final horizontal = splitWorkspacePane(
      layout: initial(),
      targetPaneId: 'root',
      direction: WorkspaceSplitDirection.horizontal,
      newPaneId: 'right',
      newGroupId: 'horizontal',
      newTabId: 'c',
    )!;
    final split = splitWorkspaceTabAtPosition(
      layout: horizontal,
      tabId: 'a',
      targetPaneId: 'right',
      position: WorkspaceSplitDropPosition.left,
      newPaneId: 'middle',
      newGroupId: 'unused',
    )!;
    final group = split.root as WorkspacePaneGroup;
    expect(group.children, hasLength(3));
    expect(group.children.map((node) => (node as WorkspacePane).id), [
      'root',
      'middle',
      'right',
    ]);
    expect(group.sizes.reduce((left, right) => left + right), closeTo(1, 1e-9));
    expect(
      splitWorkspaceTabAtPosition(
        layout: initial(),
        tabId: 'a',
        targetPaneId: 'root',
        position: WorkspaceSplitDropPosition.center,
        newPaneId: 'new',
        newGroupId: 'group',
      ),
      isNull,
    );
    expect(
      splitWorkspaceTabAtPosition(
        layout: initial(),
        tabId: 'missing',
        targetPaneId: 'root',
        position: WorkspaceSplitDropPosition.right,
        newPaneId: 'new',
        newGroupId: 'group',
      ),
      isNull,
    );
  });

  test('edge split refuses a result beyond maximum tree depth', () {
    var layout = WorkspacePaneLayout.single(
      paneId: 'pane-0',
      tabIds: const ['tab-0'],
    );
    for (var index = 1; index < WorkspacePaneLayout.maxTreeDepth; index++) {
      layout = splitWorkspacePane(
        layout: layout,
        targetPaneId: 'pane-${index - 1}',
        direction: index.isOdd
            ? WorkspaceSplitDirection.horizontal
            : WorkspaceSplitDirection.vertical,
        newPaneId: 'pane-$index',
        newGroupId: 'group-$index',
        newTabId: 'tab-$index',
      )!;
    }

    expect(
      splitWorkspaceTabAtPosition(
        layout: layout,
        tabId: 'tab-${WorkspacePaneLayout.maxTreeDepth - 1}',
        targetPaneId: 'pane-${WorkspacePaneLayout.maxTreeDepth - 1}',
        position: WorkspaceSplitDropPosition.top,
        newPaneId: 'too-deep',
        newGroupId: 'too-deep-group',
      ),
      isNull,
    );
  });
}
