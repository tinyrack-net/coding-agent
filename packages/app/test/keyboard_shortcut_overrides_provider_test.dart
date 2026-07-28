import 'dart:convert';

import 'package:coding_agent_app/state/keyboard_shortcut_overrides_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('loads stored string overrides and ignores non-string values', () async {
    SharedPreferences.setMockInitialValues({
      KeyboardShortcutOverridesNotifier.storageKey: jsonEncode({
        'binding': 'Ctrl+J',
        'invalid': 42,
      }),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(keyboardShortcutOverridesProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(keyboardShortcutOverridesProvider), {
      'binding': 'Ctrl+J',
    });
  });

  test('set, remove, and reset apply optimistically and persist', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(keyboardShortcutOverridesProvider.notifier);

    await notifier.setOverride('binding', 'Ctrl+J Ctrl+C');
    expect(container.read(keyboardShortcutOverridesProvider), {
      'binding': 'Ctrl+J Ctrl+C',
    });
    var preferences = await SharedPreferences.getInstance();
    expect(
      jsonDecode(
        preferences.getString(KeyboardShortcutOverridesNotifier.storageKey)!,
      ),
      {'binding': 'Ctrl+J Ctrl+C'},
    );

    await notifier.removeOverride('missing');
    await notifier.removeOverride('binding');
    expect(container.read(keyboardShortcutOverridesProvider), isEmpty);

    await notifier.setOverride('another', 'Alt+T');
    await notifier.resetAll();
    preferences = await SharedPreferences.getInstance();
    expect(container.read(keyboardShortcutOverridesProvider), isEmpty);
    expect(
      preferences.getString(KeyboardShortcutOverridesNotifier.storageKey),
      isNull,
    );
  });

  test('corrupt storage falls back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      KeyboardShortcutOverridesNotifier.storageKey: '{not-json',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(keyboardShortcutOverridesProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(keyboardShortcutOverridesProvider), isEmpty);
  });

  test('effective bindings reflect a stored override', () async {
    SharedPreferences.setMockInitialValues({
      KeyboardShortcutOverridesNotifier.storageKey: jsonEncode({
        'command-center-toggle-ctrl-k-non-mac': 'Ctrl+J',
      }),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(keyboardShortcutOverridesProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final binding = container
        .read(effectiveKeyboardShortcutBindingsProvider)
        .firstWhere(
          (item) => item.id == 'command-center-toggle-ctrl-k-non-mac',
        );
    expect(binding.combo, 'Ctrl+J');
  });
}
