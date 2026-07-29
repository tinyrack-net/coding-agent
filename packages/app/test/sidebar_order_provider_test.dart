import 'dart:convert';

import 'package:coding_agent_app/state/sidebar_order_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> hydrate(ProviderContainer container) async {
  final subscription = container.listen(sidebarOrderProvider, (_, _) {});
  addTearDown(subscription.close);
  for (var index = 0; index < 100; index += 1) {
    if (container.read(sidebarOrderProvider).hydrated) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('sidebar order store did not hydrate');
}

void main() {
  test('migrates legacy per-host order into global project scopes', () {
    final migrated = migrateSidebarOrderState({
      'projectOrderByServerId': {
        'host-a': ['project-a'],
        'host-b': ['project-a'],
      },
      'workspaceOrderByServerAndProject': {
        'host-a::project-a': ['main', 'feature'],
        'host-b::project-a': ['main'],
      },
    });

    expect(migrated.projectOrder, ['project-a']);
    expect(migrated.workspaceOrderByProject, {
      'project-a': ['host-a:main', 'host-a:feature', 'host-b:main'],
    });
  });

  test(
    'normalizes, persists, and hydrates project and workspace order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      addTearDown(first.dispose);
      await hydrate(first);

      await first.read(sidebarOrderProvider.notifier).setProjectOrder([
        ' project-b ',
        '',
        'project-b',
        'project-a',
      ]);
      await first.read(sidebarOrderProvider.notifier).setWorkspaceOrder(
        'project-a',
        [' b ', 'a', 'b'],
      );

      expect(first.read(sidebarOrderProvider).projectOrder, [
        'project-b',
        'project-a',
      ]);
      expect(first.read(sidebarOrderProvider).workspaceOrder('project-a'), [
        'b',
        'a',
      ]);
      final stored =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  sidebarOrderStorageKey,
                )!,
              )
              as Map<String, Object?>;
      expect(stored['version'], 1);

      final second = ProviderContainer();
      addTearDown(second.dispose);
      await hydrate(second);
      expect(second.read(sidebarOrderProvider).projectOrder, [
        'project-b',
        'project-a',
      ]);
      expect(second.read(sidebarOrderProvider).workspaceOrder('project-a'), [
        'b',
        'a',
      ]);
    },
  );

  test(
    'malformed persisted state falls back to an empty hydrated store',
    () async {
      SharedPreferences.setMockInitialValues({
        sidebarOrderStorageKey: '{not-json',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await hydrate(container);

      final state = container.read(sidebarOrderProvider);
      expect(state.hydrated, isTrue);
      expect(state.projectOrder, isEmpty);
      expect(state.workspaceOrderByProject, isEmpty);
    },
  );

  test('reconciles newly visible projects and workspaces atomically', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await hydrate(container);
    final notifier = container.read(sidebarOrderProvider.notifier);
    await notifier.setProjectOrder(['project-a']);
    await notifier.setWorkspaceOrder('project-a', ['host:main']);

    await notifier.reconcileVisibleOrder(
      projectOrder: ['project-a', 'project-b'],
      workspaceOrders: {
        'project-a': ['host:feature', 'host:main'],
      },
    );

    final state = container.read(sidebarOrderProvider);
    expect(state.projectOrder, ['project-a', 'project-b']);
    expect(state.workspaceOrder('project-a'), [
      'host:feature',
      'host:main',
    ]);
  });
}
