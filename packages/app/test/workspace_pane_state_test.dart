import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:coding_agent_app/workspace/workspace_pane_state.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = WorkspaceTab(
  tabId: 'agent_a1',
  target: WorkspaceAgentTabTarget(agentId: 'a1'),
  createdAt: 1,
);
const _file = WorkspaceTab(
  tabId: 'file_lib/main.dart',
  target: WorkspaceFileTabTarget(path: 'lib/main.dart'),
  createdAt: 2,
);

void main() {
  test('orders tabs by pane and prefers the requested target', () {
    const pane = WorkspacePane(
      id: 'pane',
      tabIds: ['file_lib/main.dart', 'agent_a1'],
      focusedTabId: 'agent_a1',
    );
    const layout = WorkspacePaneLayout(root: pane, focusedPaneId: 'pane');

    final state = deriveWorkspacePaneState(
      layout: layout,
      tabs: const [_agent, _file],
      preferredTarget: const WorkspaceFileTabTarget(path: 'lib/main.dart'),
    );

    expect(state.tabs.map((tab) => tab.descriptor.tabId), [
      'file_lib/main.dart',
      'agent_a1',
    ]);
    expect(state.focusedTabId, 'agent_a1');
    expect(state.activeTabId, 'file_lib/main.dart');
    expect(state.activeTab?.descriptor.kind, 'file');
  });

  test(
    'falls back from invalid preferred and focused ids to the first tab',
    () {
      final state = deriveWorkspacePaneState(
        tabs: const [_agent, _file],
        focusedTabId: 'missing',
        preferredTarget: const WorkspaceAgentTabTarget(agentId: 'missing'),
      );
      expect(state.pane, isNull);
      expect(state.activeTabId, 'agent_a1');
      expect(state.focusedTabId, 'missing');
    },
  );

  test('normalizes and deduplicates malformed tab entries', () {
    final state = deriveWorkspacePaneState(
      tabs: const [
        WorkspaceTab(
          tabId: ' duplicate ',
          target: WorkspaceAgentTabTarget(agentId: ' a1 '),
          createdAt: 1,
        ),
        WorkspaceTab(
          tabId: 'duplicate',
          target: WorkspaceAgentTabTarget(agentId: 'a2'),
          createdAt: 2,
        ),
        WorkspaceTab(
          tabId: 'invalid',
          target: WorkspaceAgentTabTarget(agentId: ' '),
          createdAt: 3,
        ),
      ],
    );
    expect(state.tabs, hasLength(1));
    expect(state.tabs.single.descriptor.tabId, 'duplicate');
    expect(
      (state.tabs.single.descriptor.target as WorkspaceAgentTabTarget).agentId,
      'a1',
    );
  });

  test('explicit pane takes precedence and descriptors preserve targets', () {
    const explicit = WorkspacePane(
      id: 'explicit',
      tabIds: ['agent_a1'],
      focusedTabId: 'agent_a1',
    );
    const layout = WorkspacePaneLayout(
      root: WorkspacePane(id: 'other', tabIds: ['file_lib/main.dart']),
      focusedPaneId: 'other',
    );
    final descriptors = getWorkspacePaneDescriptors(
      layout: layout,
      pane: explicit,
      paneId: 'other',
      tabs: const [_agent, _file],
    );
    expect(descriptors, hasLength(1));
    expect(descriptors.single.target, isA<WorkspaceAgentTabTarget>());
  });

  test('side placement reuses target identity before splitting', () {
    const left = WorkspacePane(
      id: 'left',
      tabIds: ['agent_a1'],
      focusedTabId: 'agent_a1',
    );
    const right = WorkspacePane(id: 'right', tabIds: []);
    const layout = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'root',
        direction: WorkspaceSplitDirection.horizontal,
        children: [left, right],
        sizes: [.5, .5],
      ),
      focusedPaneId: 'left',
    );

    expect(
      resolveWorkspaceSideTargetPlacement(
        layout: layout,
        sourcePaneId: 'left',
        tabs: const [_agent],
        target: const WorkspaceAgentTabTarget(agentId: 'a1'),
      ).kind,
      WorkspaceSideFileOpenPlacementKind.openInSource,
    );
    expect(
      resolveWorkspaceSideTargetPlacement(
        layout: layout,
        sourcePaneId: 'left',
        tabs: const [_agent],
        target: const WorkspaceFileTabTarget(path: 'lib/main.dart'),
      ),
      const WorkspaceSideFileOpenPlacement(
        WorkspaceSideFileOpenPlacementKind.focusSidePane,
        paneId: 'right',
      ),
    );
  });
}
