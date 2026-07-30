import 'package:coding_agent_app/mobile_panels/compact_explorer_sidebar_host_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _previous = CompactExplorerSidebarHostModel(
  serverId: 'server-1',
  workspaceId: 'workspace-a',
  persistenceKey: 'server-1:workspace-a',
  workspaceRoot: '/repo/a',
  isGit: true,
);

void main() {
  test('retains root and git state while the same workspace reloads', () {
    final result = resolveCompactExplorerSidebarHostModel(
      previous: _previous,
      selection: const CompactExplorerSelection(
        serverId: 'server-1',
        workspaceId: 'workspace-a',
      ),
      workspace: null,
      isGit: false,
    );

    expect(result, _previous);
  });

  test('does not leak retained state into another workspace owner', () {
    final result = resolveCompactExplorerSidebarHostModel(
      previous: _previous,
      selection: const CompactExplorerSelection(
        serverId: 'server-1',
        workspaceId: 'workspace-b',
      ),
      workspace: null,
      isGit: false,
    );

    expect(
      result,
      const CompactExplorerSidebarHostModel(
        serverId: 'server-1',
        workspaceId: 'workspace-b',
        persistenceKey: 'server-1:workspace-b',
        workspaceRoot: '',
        isGit: false,
      ),
    );
  });

  test('does not retain an owner without an active selection', () {
    final result = resolveCompactExplorerSidebarHostModel(
      previous: _previous,
      selection: null,
      workspace: null,
      isGit: false,
    );

    expect(result, isNull);
  });

  test('uses current workspace directory and git state when available', () {
    final result = resolveCompactExplorerSidebarHostModel(
      previous: null,
      selection: const CompactExplorerSelection(
        serverId: 'server-1',
        workspaceId: 'workspace-a',
      ),
      workspace: const CompactExplorerWorkspaceSnapshot(
        workspaceDirectory: '/repo/current',
      ),
      isGit: true,
    );

    expect(
      result,
      const CompactExplorerSidebarHostModel(
        serverId: 'server-1',
        workspaceId: 'workspace-a',
        persistenceKey: 'server-1:workspace-a',
        workspaceRoot: '/repo/current',
        isGit: true,
      ),
    );
  });

  test('normalizes identities and rejects empty selections', () {
    final normalized = resolveCompactExplorerSidebarHostModel(
      previous: null,
      selection: const CompactExplorerSelection(
        serverId: ' server-1 ',
        workspaceId: ' workspace-a ',
      ),
      workspace: const CompactExplorerWorkspaceSnapshot(
        workspaceDirectory: ' /repo/current ',
      ),
      isGit: true,
    );
    expect(normalized?.serverId, 'server-1');
    expect(normalized?.workspaceId, 'workspace-a');
    expect(normalized?.workspaceRoot, '/repo/current');
    expect(normalized?.persistenceKey, 'server-1:workspace-a');

    expect(
      resolveCompactExplorerSidebarHostModel(
        previous: _previous,
        selection: const CompactExplorerSelection(
          serverId: ' ',
          workspaceId: 'workspace-a',
        ),
        workspace: null,
        isGit: false,
      ),
      isNull,
    );
  });
}
