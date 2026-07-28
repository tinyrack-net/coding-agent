import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeWorkspaceFileLocation', () {
    test('trims paths, normalizes separators, and validates line ranges', () {
      expect(
        normalizeWorkspaceFileLocation(
          const WorkspaceFileLocation(
            path: r' src\main.dart ',
            lineStart: 12,
            lineEnd: 20,
          ),
        ),
        const WorkspaceFileLocation(
          path: 'src/main.dart',
          lineStart: 12,
          lineEnd: 20,
        ),
      );
      expect(
        normalizeWorkspaceFileLocation(
          const WorkspaceFileLocation(
            path: 'src/main.dart',
            lineStart: 12,
            lineEnd: 4,
          ),
        ),
        const WorkspaceFileLocation(path: 'src/main.dart', lineStart: 12),
      );
      expect(
        normalizeWorkspaceFileLocation(
          const WorkspaceFileLocation(path: '   '),
        ),
        isNull,
      );
    });
  });

  group('resolveWorkspaceFilePaths', () {
    test('resolves relative paths without allowing workspace escape', () {
      final result = resolveWorkspaceFilePaths(
        path: 'lib/../test/widget_test.dart',
        workspaceRoot: '/repo/app',
      );
      expect(result?.absolutePath, '/repo/app/test/widget_test.dart');
      expect(result?.relativePath, 'test/widget_test.dart');
      expect(
        resolveWorkspaceFilePaths(
          path: '../outside.dart',
          workspaceRoot: '/repo/app',
        ),
        isNull,
      );
      expect(
        resolveWorkspaceFilePaths(path: '~/file.dart', workspaceRoot: '/repo'),
        isNull,
      );
    });

    test('normalizes absolute Windows paths case-insensitively', () {
      final inside = resolveWorkspaceFilePaths(
        path: r'c:\Repo\App\lib\main.dart',
        workspaceRoot: r'C:\repo\app',
      );
      expect(inside?.absolutePath, 'c:/Repo/App/lib/main.dart');
      expect(inside?.relativePath, 'lib/main.dart');

      final outside = resolveWorkspaceFilePaths(
        path: r'D:\other\main.dart',
        workspaceRoot: r'C:\repo\app',
      );
      expect(outside?.relativePath, isNull);
      expect(outside?.absolutePath, 'D:/other/main.dart');
    });

    test('rejects workspace roots and missing absolute roots', () {
      expect(
        resolveWorkspaceFilePaths(
          path: '/repo/app',
          workspaceRoot: '/repo/app',
        ),
        isNull,
      );
      expect(
        resolveWorkspaceFilePaths(path: 'main.dart', workspaceRoot: 'relative'),
        isNull,
      );
    });
  });

  group('resolveWorkspaceSideFileOpenPlacement', () {
    const left = WorkspacePane(
      id: 'left',
      tabIds: ['source'],
      focusedTabId: 'source',
    );
    const right = WorkspacePane(
      id: 'right',
      tabIds: ['other'],
      focusedTabId: 'other',
    );
    const splitLayout = WorkspacePaneLayout(
      root: WorkspacePaneGroup(
        id: 'root',
        direction: WorkspaceSplitDirection.horizontal,
        children: [left, right],
        sizes: [.5, .5],
      ),
      focusedPaneId: 'left',
    );

    test('keeps an already open file in its source pane', () {
      expect(
        resolveWorkspaceSideFileOpenPlacement(
          layout: splitLayout,
          sourcePaneId: 'left',
          targetAlreadyOpen: true,
        ),
        const WorkspaceSideFileOpenPlacement(
          WorkspaceSideFileOpenPlacementKind.openInSource,
        ),
      );
    });

    test('uses the adjacent right pane when one exists', () {
      expect(
        resolveWorkspaceSideFileOpenPlacement(
          layout: splitLayout,
          sourcePaneId: 'left',
          targetAlreadyOpen: false,
        ),
        const WorkspaceSideFileOpenPlacement(
          WorkspaceSideFileOpenPlacementKind.focusSidePane,
          paneId: 'right',
        ),
      );
    });

    test('requests a right split when the source has no side pane', () {
      const layout = WorkspacePaneLayout(root: left, focusedPaneId: 'left');
      expect(
        resolveWorkspaceSideFileOpenPlacement(
          layout: layout,
          sourcePaneId: 'left',
          targetAlreadyOpen: false,
        ),
        const WorkspaceSideFileOpenPlacement(
          WorkspaceSideFileOpenPlacementKind.splitSidePane,
          paneId: 'left',
        ),
      );
      expect(
        resolveWorkspaceSideFileOpenPlacement(
          layout: layout,
          sourcePaneId: 'missing',
          targetAlreadyOpen: false,
        ).kind,
        WorkspaceSideFileOpenPlacementKind.openInSource,
      );
    });
  });
}
