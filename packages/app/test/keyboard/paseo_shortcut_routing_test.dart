import 'package:coding_agent_app/keyboard/paseo_shortcut_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canToggleFileExplorerShortcut', () {
    void toggleFileExplorer() {}

    test('allows the shortcut on selected-agent routes', () {
      expect(
        canToggleFileExplorerShortcut(
          selectedAgentId: 'server-1:agent-1',
          pathname: '/h/server-1/workspace/workspace-1?open=agent%3Aagent-1',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isTrue,
      );
    });

    test('allows the shortcut on workspace routes', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname: '/h/server-1/workspace/workspace-1',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isTrue,
      );
    });

    test('allows the shortcut on workspace routes with intent query', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname:
              '/h/server-1/workspace/workspace-1?open=terminal%3Aterminal-1',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isTrue,
      );
    });

    test('allows the shortcut on workspace draft-intent routes', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname: '/h/server-1/workspace/workspace-1?open=draft%3Adraft_123',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isTrue,
      );
    });

    test('allows the shortcut on host agent routes', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname: '/h/server-1/agent/agent-1',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isTrue,
      );
    });

    test('blocks the shortcut when no toggle handler exists', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname: '/h/server-1/workspace/workspace-1?open=draft%3Adraft_123',
        ),
        isFalse,
      );
    });

    test('blocks the shortcut outside agent routes', () {
      expect(
        canToggleFileExplorerShortcut(
          pathname: '/h/server-1/settings',
          toggleFileExplorer: toggleFileExplorer,
        ),
        isFalse,
      );
    });
  });

  group('getNextActiveIndex', () {
    test('returns -1 when itemCount is 0', () {
      expect(
        getNextActiveIndex(
          currentIndex: 0,
          itemCount: 0,
          key: ComboboxArrowKey.down,
        ),
        -1,
      );
    });

    test('starts at 0 on ArrowDown when no active item', () {
      expect(
        getNextActiveIndex(
          currentIndex: -1,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        0,
      );
    });

    test('starts at last on ArrowUp when no active item', () {
      expect(
        getNextActiveIndex(
          currentIndex: -1,
          itemCount: 3,
          key: ComboboxArrowKey.up,
        ),
        2,
      );
    });

    test('wraps around on ArrowDown and ArrowUp', () {
      expect(
        getNextActiveIndex(
          currentIndex: 2,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        0,
      );
      expect(
        getNextActiveIndex(
          currentIndex: 0,
          itemCount: 3,
          key: ComboboxArrowKey.up,
        ),
        2,
      );
    });

    test('normalizes an out-of-range index against the current count', () {
      expect(
        getNextActiveIndex(
          currentIndex: 7,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        2,
      );
      expect(
        getNextActiveIndex(
          currentIndex: 7,
          itemCount: 3,
          key: ComboboxArrowKey.up,
        ),
        0,
      );
    });
  });
}
