import 'dart:async';

import 'package:coding_agent_app/layout/desktop_sidebar_layout.dart';
import 'package:coding_agent_app/state/sidebar_width_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage implements SidebarWidthStorage {
  final loaded = Completer<double?>();
  final saved = <double>[];

  @override
  Future<double?> load() => loaded.future;

  @override
  Future<void> save(double width) async => saved.add(width);
}

void main() {
  test('hydrates persisted width and clamps committed values', () async {
    final storage = _FakeStorage();
    final container = ProviderContainer(
      overrides: [sidebarWidthStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      sidebarWidthProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    expect(container.read(sidebarWidthProvider), defaultSidebarWidth);

    storage.loaded.complete(512);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sidebarWidthProvider), 512);

    container.read(sidebarWidthProvider.notifier).setWidth(900);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sidebarWidthProvider), maxSidebarWidth);
    expect(storage.saved, [maxSidebarWidth]);

    container.read(sidebarWidthProvider.notifier).setWidth(double.nan);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sidebarWidthProvider), minSidebarWidth);
    expect(storage.saved.last, minSidebarWidth);
  });

  test('user resize wins over late storage hydration', () async {
    final storage = _FakeStorage();
    final container = ProviderContainer(
      overrides: [sidebarWidthStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    container.listen(sidebarWidthProvider, (_, _) {}, fireImmediately: true);

    container.read(sidebarWidthProvider.notifier).setWidth(420);
    storage.loaded.complete(560);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sidebarWidthProvider), 420);
  });
}
