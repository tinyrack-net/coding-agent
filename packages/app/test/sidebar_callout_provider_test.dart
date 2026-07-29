import 'dart:async';

import 'package:coding_agent_app/state/sidebar_callout_provider.dart';
import 'package:coding_agent_app/state/sidebar_callout_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage implements SidebarCalloutStorage {
  final loadResult = Completer<String?>();
  final saved = <String>[];

  @override
  Future<String?> load() => loadResult.future;

  @override
  Future<void> save(String value) async => saved.add(value);
}

void main() {
  test(
    'provider hydrates, persists dismissals, and invokes callbacks',
    () async {
      final storage = _FakeStorage();
      final container = ProviderContainer(
        overrides: [sidebarCalloutStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        activeSidebarCalloutProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      var dismissed = 0;

      container
          .read(sidebarCalloutProvider.notifier)
          .show(
            SidebarCalloutOptions(
              id: 'update',
              dismissalKey: 'update:1',
              title: 'Update available',
              onDismiss: () => dismissed++,
            ),
          );
      expect(container.read(activeSidebarCalloutProvider), isNull);

      storage.loadResult.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(activeSidebarCalloutProvider)?.options.title,
        'Update available',
      );

      container.read(sidebarCalloutProvider.notifier).dismiss('update');
      await Future<void>.delayed(Duration.zero);
      expect(container.read(activeSidebarCalloutProvider), isNull);
      expect(storage.saved, ['["update:1"]']);
      expect(dismissed, 1);
    },
  );

  test(
    'registration cleanup is token safe and clear keeps dismissals',
    () async {
      final storage = _FakeStorage();
      storage.loadResult.complete('["kept"]');
      final container = ProviderContainer(
        overrides: [sidebarCalloutStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      container.listen(
        sidebarCalloutProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);
      final notifier = container.read(sidebarCalloutProvider.notifier);

      final unregisterOld = notifier.show(
        const SidebarCalloutOptions(id: 'same', title: 'Old'),
      );
      notifier.show(
        const SidebarCalloutOptions(id: 'same', title: 'Replacement'),
      );
      unregisterOld();
      expect(
        container.read(activeSidebarCalloutProvider)?.options.title,
        'Replacement',
      );

      notifier.clear();
      expect(container.read(sidebarCalloutProvider).callouts, isEmpty);
      expect(container.read(sidebarCalloutProvider).dismissedKeys, {'kept'});
    },
  );
}
