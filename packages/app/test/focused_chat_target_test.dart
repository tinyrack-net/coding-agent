import 'package:coding_agent_app/composer/focused_chat_target.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorktreeTabLayout layout({
    required List<WorktreeTab> tabs,
    required String focusedTabId,
  }) => WorktreeTabLayout(
    tabs: tabs,
    activeTabId: focusedTabId,
    paneLayout: WorkspacePaneLayout.single(
      paneId: 'pane',
      tabIds: tabs.map((tab) => tab.tabId).toList(),
      focusedTabId: focusedTabId,
    ),
  );

  test('resolves the focused agent to its server-scoped draft', () {
    final target = resolveFocusedChatTarget(
      serverId: 'host-1',
      layout: layout(
        tabs: const [
          WorktreeTab(
            tabId: 'agent-tab',
            kind: WorktreeTabKind.agent,
            agentId: 'agent-1',
          ),
        ],
        focusedTabId: 'agent-tab',
      ),
    );

    expect(target?.tabId, 'agent-tab');
    expect(target?.draftKey, 'agent:host-1:agent-1');
  });

  test('resolves a draft tab by draft id and rejects non-chat tabs', () {
    final draft = resolveFocusedChatTarget(
      serverId: 'host-1',
      layout: layout(
        tabs: const [
          WorktreeTab(tabId: 'draft-1', kind: WorktreeTabKind.draft),
        ],
        focusedTabId: 'draft-1',
      ),
    );
    final file = resolveFocusedChatTarget(
      serverId: 'host-1',
      layout: layout(
        tabs: const [
          WorktreeTab(
            tabId: 'file-1',
            kind: WorktreeTabKind.file,
            filePath: 'README.md',
          ),
        ],
        focusedTabId: 'file-1',
      ),
    );

    expect(draft?.draftKey, 'draft:host-1:draft-1');
    expect(file, isNull);
  });

  test('uses the focused pane instead of the legacy active tab', () {
    const agent = WorktreeTab(
      tabId: 'agent-tab',
      kind: WorktreeTabKind.agent,
      agentId: 'agent-1',
    );
    const diff = WorktreeTab(tabId: 'diff-tab', kind: WorktreeTabKind.diff);
    final target = resolveFocusedChatTarget(
      serverId: 'host',
      layout: WorktreeTabLayout(
        tabs: const [agent, diff],
        activeTabId: 'agent-tab',
        paneLayout: const WorkspacePaneLayout(
          root: WorkspacePane(
            id: 'pane',
            tabIds: ['agent-tab', 'diff-tab'],
            focusedTabId: 'diff-tab',
          ),
          focusedPaneId: 'pane',
        ),
      ),
    );

    expect(target, isNull);
  });
}
