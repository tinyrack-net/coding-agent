import 'dart:async';

import 'package:coding_agent_app/state/explorer_checkout_context.dart';
import 'package:coding_agent_app/state/explorer_tab_memory_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStorage implements ExplorerTabMemoryStorage {
  _MemoryStorage({this.loadCompleter});

  final Completer<ExplorerTabMemoryState?>? loadCompleter;
  ExplorerTabMemoryState? saved;

  @override
  Future<ExplorerTabMemoryState?> load() =>
      loadCompleter?.future ?? Future.value();

  @override
  Future<void> save(ExplorerTabMemoryState state) async {
    saved = state;
  }
}

void main() {
  group('Paseo explorer checkout key', () {
    test('trims both identities and rejects incomplete ownership', () {
      expect(
        buildExplorerCheckoutKey(' server-1 ', ' /repo '),
        'server-1::/repo',
      );
      expect(buildExplorerCheckoutKey(' ', '/repo'), isNull);
      expect(buildExplorerCheckoutKey('server-1', ' '), isNull);
    });
  });

  group('Paseo explorer tab resolution', () {
    test('defaults git checkouts to changes', () {
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-1',
          cwd: '/repo',
          isGit: true,
          explorerTabByCheckout: const {},
        ),
        WorkspaceExplorerTab.changes,
      );
    });

    test('defaults non-git checkouts to files', () {
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-1',
          cwd: '/directory',
          isGit: false,
          explorerTabByCheckout: const {},
        ),
        WorkspaceExplorerTab.files,
      );
    });

    test('restores a checkout-specific tab without leaking to another cwd', () {
      const tabs = {
        'server-1::/repo-a': WorkspaceExplorerTab.files,
        'server-1::/repo-b': WorkspaceExplorerTab.pullRequest,
      };
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-1',
          cwd: '/repo-a',
          isGit: true,
          explorerTabByCheckout: tabs,
        ),
        WorkspaceExplorerTab.files,
      );
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-1',
          cwd: '/repo-b',
          isGit: true,
          explorerTabByCheckout: tabs,
        ),
        WorkspaceExplorerTab.pullRequest,
      );
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-2',
          cwd: '/repo-a',
          isGit: true,
          explorerTabByCheckout: tabs,
        ),
        WorkspaceExplorerTab.changes,
      );
    });

    test('coerces stored changes but not PR intent for non-git checkouts', () {
      expect(
        resolveExplorerTabForCheckout(
          serverId: 'server-1',
          cwd: '/directory',
          isGit: false,
          explorerTabByCheckout: const {
            'server-1::/directory': WorkspaceExplorerTab.changes,
          },
        ),
        WorkspaceExplorerTab.files,
      );
      expect(
        coerceExplorerTabForCheckout(
          WorkspaceExplorerTab.pullRequest,
          isGit: false,
        ),
        WorkspaceExplorerTab.pullRequest,
      );
    });
  });

  test(
    'notifier stores the coerced tab under the canonical checkout key',
    () async {
      final storage = _MemoryStorage();
      final container = ProviderContainer(
        overrides: [
          explorerTabMemoryStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      container.read(explorerTabMemoryProvider);
      container
          .read(explorerTabMemoryProvider.notifier)
          .setForCheckout(
            checkout: const ExplorerCheckoutContext(
              serverId: ' server-1 ',
              cwd: ' /directory ',
              isGit: false,
            ),
            tab: WorkspaceExplorerTab.changes,
          );
      await Future<void>.delayed(Duration.zero);

      expect(container.read(explorerTabMemoryProvider).byCheckout, const {
        'server-1::/directory': WorkspaceExplorerTab.files,
      });
      expect(storage.saved?.activeTab, WorkspaceExplorerTab.files);
      expect(storage.saved?.byCheckout, const {
        'server-1::/directory': WorkspaceExplorerTab.files,
      });
    },
  );

  test('late hydration cannot overwrite a user tab selection', () async {
    final load = Completer<ExplorerTabMemoryState?>();
    final storage = _MemoryStorage(loadCompleter: load);
    final container = ProviderContainer(
      overrides: [explorerTabMemoryStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    container.read(explorerTabMemoryProvider);
    await Future<void>.delayed(Duration.zero);
    container
        .read(explorerTabMemoryProvider.notifier)
        .setForCheckout(
          checkout: const ExplorerCheckoutContext(
            serverId: 'server-1',
            cwd: '/repo',
            isGit: true,
          ),
          tab: WorkspaceExplorerTab.files,
        );
    load.complete(
      const ExplorerTabMemoryState(
        byCheckout: {'server-1::/repo': WorkspaceExplorerTab.pullRequest},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(explorerTabMemoryProvider).byCheckout['server-1::/repo'],
      WorkspaceExplorerTab.files,
    );
  });
}
