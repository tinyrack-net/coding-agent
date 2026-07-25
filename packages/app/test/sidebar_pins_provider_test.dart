import 'dart:convert';

import 'package:coding_agent_app/state/sidebar_pins_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer makeContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('build() starts empty', () async {
    final container = makeContainer();
    expect(container.read(sidebarPinsProvider), isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('togglePin() pins an unpinned agent and persists it', () async {
    final container = makeContainer();

    await container.read(sidebarPinsProvider.notifier).togglePin('a1');

    expect(container.read(sidebarPinsProvider), {'a1'});
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('sidebar.pinnedAgentIds')!),
      ['a1'],
    );
  });

  test('togglePin() unpins an already-pinned agent', () async {
    final container = makeContainer();
    await container.read(sidebarPinsProvider.notifier).togglePin('a1');

    await container.read(sidebarPinsProvider.notifier).togglePin('a1');

    expect(container.read(sidebarPinsProvider), isEmpty);
  });

  test('isPinned() reflects current state', () async {
    final container = makeContainer();
    final notifier = container.read(sidebarPinsProvider.notifier);
    await notifier.togglePin('a1');

    expect(notifier.isPinned('a1'), isTrue);
    expect(notifier.isPinned('a2'), isFalse);
  });

  test('a fresh notifier loads persisted pins', () async {
    SharedPreferences.setMockInitialValues({
      'sidebar.pinnedAgentIds': jsonEncode(['a1', 'a2']),
    });
    final container = makeContainer();
    container.read(sidebarPinsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(container.read(sidebarPinsProvider), {'a1', 'a2'});
  });
}
