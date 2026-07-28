import 'package:coding_agent_app/workspace/workspace_mounted_tab_set.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('includes a newly active tab in the same derivation', () {
    expect(
      deriveMountedTabLru(
        activeTabId: 'second',
        availableTabIds: {'first', 'second'},
        cap: 3,
        previousLru: const ['first'],
      ),
      const ['second', 'first'],
    );
  });

  test('preserves the cap while adding the active tab', () {
    final second = deriveMountedTabLru(
      activeTabId: 'second',
      availableTabIds: {'first', 'second', 'third'},
      cap: 2,
      previousLru: const ['first'],
    );
    expect(second, const ['second', 'first']);
    expect(
      deriveMountedTabLru(
        activeTabId: 'third',
        availableTabIds: {'first', 'second', 'third'},
        cap: 2,
        previousLru: second,
      ),
      const ['third', 'second'],
    );
  });

  test('keeps retained panels mounted beyond the normal cap', () {
    var lru = const ['modified'];
    for (final active in const ['second', 'third', 'fourth']) {
      lru = deriveMountedTabLru(
        activeTabId: active,
        availableTabIds: {'modified', 'second', 'third', 'fourth'},
        retainedTabIds: {'modified'},
        cap: 2,
        previousLru: lru,
      );
    }
    expect(lru, const ['fourth', 'modified']);
  });

  test('drops unavailable and duplicate previous entries', () {
    expect(
      deriveMountedTabLru(
        activeTabId: 'active',
        availableTabIds: {'active', 'recent'},
        cap: 3,
        previousLru: const ['missing', 'recent', 'recent'],
      ),
      const ['active', 'recent'],
    );
  });

  test('treats a non-positive cap as one', () {
    expect(
      deriveMountedTabLru(
        activeTabId: 'active',
        availableTabIds: {'active', 'previous'},
        cap: 0,
        previousLru: const ['previous'],
      ),
      const ['active'],
    );
  });
}
