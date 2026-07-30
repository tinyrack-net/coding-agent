import 'dart:convert';

import 'package:coding_agent_app/state/changes_preferences_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'missing storage migrates legacy wrap-lines into frozen defaults',
    () async {
      final storage = _MemoryStorage({
        ChangesPreferencesNotifier.legacyWrapLinesKey: 'true',
      });
      final container = ProviderContainer(
        overrides: [
          changesPreferencesStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      final preferences = await container.read(
        changesPreferencesProvider.future,
      );

      expect(preferences.layout, ChangesLayout.unified);
      expect(preferences.viewMode, ChangesViewMode.flat);
      expect(preferences.wrapLines, isTrue);
      expect(preferences.hideWhitespace, isFalse);
      expect(preferences.commitsCollapsed, isTrue);
      expect(storage.values[ChangesPreferencesNotifier.storageKey], isNotNull);
    },
  );

  test('stored partial and invalid values merge with defaults', () async {
    final storage = _MemoryStorage({
      ChangesPreferencesNotifier.storageKey: jsonEncode({
        'layout': 'split',
        'viewMode': 'invalid',
        'hideWhitespace': true,
        'commitsCollapsed': 'invalid',
      }),
    });
    final container = ProviderContainer(
      overrides: [changesPreferencesStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    final preferences = await container.read(changesPreferencesProvider.future);

    expect(preferences.layout, ChangesLayout.split);
    expect(preferences.viewMode, ChangesViewMode.flat);
    expect(preferences.wrapLines, isFalse);
    expect(preferences.hideWhitespace, isTrue);
    expect(preferences.commitsCollapsed, isTrue);
  });

  test('updates optimistically and persists the complete shape', () async {
    final storage = _MemoryStorage();
    final container = ProviderContainer(
      overrides: [changesPreferencesStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(changesPreferencesProvider.future);

    await container
        .read(changesPreferencesProvider.notifier)
        .updatePreferences(
          layout: ChangesLayout.split,
          viewMode: ChangesViewMode.tree,
          hideWhitespace: true,
        );

    final current = container.read(changesPreferencesProvider).requireValue;
    expect(current.layout, ChangesLayout.split);
    expect(current.viewMode, ChangesViewMode.tree);
    expect(current.hideWhitespace, isTrue);
    expect(jsonDecode(storage.values[ChangesPreferencesNotifier.storageKey]!), {
      'layout': 'split',
      'viewMode': 'tree',
      'wrapLines': false,
      'hideWhitespace': true,
      'commitsCollapsed': true,
    });
  });
}

final class _MemoryStorage implements ChangesPreferencesStorage {
  _MemoryStorage([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
