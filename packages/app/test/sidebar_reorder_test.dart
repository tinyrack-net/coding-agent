import 'package:coding_agent_app/sidebar/sidebar_reorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hasVisibleOrderChanged', () {
    test('returns false when visible order is unchanged', () {
      expect(
        hasVisibleOrderChanged(
          currentOrder: const ['a', 'b', 'c', 'd'],
          reorderedVisibleKeys: const ['a', 'b', 'c'],
        ),
        isFalse,
      );
    });

    test('returns true for reordered or missing visible items', () {
      expect(
        hasVisibleOrderChanged(
          currentOrder: const ['a', 'b', 'c', 'd'],
          reorderedVisibleKeys: const ['b', 'a', 'c'],
        ),
        isTrue,
      );
      expect(
        hasVisibleOrderChanged(
          currentOrder: const ['a', 'b'],
          reorderedVisibleKeys: const ['a', 'c'],
        ),
        isTrue,
      );
    });
  });

  group('mergeWithRemainder', () {
    test('appends hidden stored keys after reordered visible keys', () {
      expect(
        mergeWithRemainder(
          currentOrder: const ['a', 'x', 'b', 'y'],
          reorderedVisibleKeys: const ['b', 'a'],
        ),
        ['b', 'a', 'x', 'y'],
      );
    });

    test('preserves all current keys for an empty visible list', () {
      expect(
        mergeWithRemainder(
          currentOrder: const ['stale', 'hidden'],
          reorderedVisibleKeys: const [],
        ),
        ['stale', 'hidden'],
      );
    });
  });

  test('stored ordering only permutes slots occupied by known keys', () {
    expect(
      applyStoredOrdering(
        items: const ['new', 'a', 'hidden', 'b'],
        storedOrder: const ['b', 'a', 'stale'],
        getKey: (item) => item,
      ),
      ['new', 'b', 'hidden', 'a'],
    );
  });

  test('missing project keys append while missing workspace keys prepend', () {
    expect(
      appendMissingOrderKeys(
        currentOrder: const ['a'],
        visibleKeys: const ['a', 'b'],
      ),
      ['a', 'b'],
    );
    expect(
      prependMissingOrderKeys(
        currentOrder: const ['a'],
        visibleKeys: const ['a', 'b'],
      ),
      ['b', 'a'],
    );
  });

  test('reorderAt follows Flutter new-index semantics', () {
    expect(reorderAt(const ['a', 'b', 'c'], 0, 3), ['b', 'c', 'a']);
    expect(reorderAt(const ['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
    expect(reorderAt(const ['a', 'b', 'c'], 1, 2), ['a', 'b', 'c']);
  });
}
