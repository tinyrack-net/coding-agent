// Port of Paseo's `components/drag-reorder/drag-reducer.test.ts`,
// `components/drag-reorder/reorder-items.test.ts`, and
// `components/drag-reorder/pointer-activation.test.ts`.
import 'package:coding_agent_app/drag_reorder/drag_reorder.dart';
import 'package:flutter_test/flutter_test.dart';

const _items = ['alpha', 'beta', 'gamma'];

String _byValue(String item, int index) => item;

const _config = DragActivationConfig(
  movementDistance: 6,
  touchHoldDelayMs: 180,
  touchHoldTolerance: 8,
);

void main() {
  group('dragStateReducer', () {
    test('starts tracking the active item with a snapshot of the data', () {
      final next = dragStateReducer(
        dragStateInitial<String>(),
        const DragStartAction(id: 'alpha', data: ['alpha', 'beta']),
      );

      expect(
        next,
        const DragState<String>(
          activeId: 'alpha',
          dragItems: ['alpha', 'beta'],
        ),
      );
    });

    test('clears the active item and the snapshot', () {
      final next = dragStateReducer(
        const DragState<String>(
          activeId: 'alpha',
          dragItems: ['alpha', 'beta'],
        ),
        const DragClearAction<String>(),
      );

      expect(next.activeId, isNull);
      expect(next.dragItems, isNull);
    });

    test('replaces an in-flight drag when a new one starts', () {
      final next = dragStateReducer(
        const DragState<String>(
          activeId: 'alpha',
          dragItems: ['alpha', 'beta'],
        ),
        const DragStartAction(id: 'beta', data: ['beta', 'gamma']),
      );

      expect(
        next,
        const DragState<String>(activeId: 'beta', dragItems: ['beta', 'gamma']),
      );
    });

    // Extra: the idle state is what a freshly mounted list renders from.
    test('starts idle with no active item and no snapshot', () {
      final initial = dragStateInitial<String>();

      expect(initial.activeId, isNull);
      expect(initial.dragItems, isNull);
    });

    // Extra: clearing an already-idle state must not resurrect anything.
    test('clearing while idle stays idle', () {
      final next = dragStateReducer(
        dragStateInitial<String>(),
        const DragClearAction<String>(),
      );

      expect(next, dragStateInitial<String>());
    });

    // Extra: the reducer never mutates the state it was handed, so the
    // overlay can keep rendering the previous snapshot during a transition.
    test('leaves the previous state untouched', () {
      const previous = DragState<String>(
        activeId: 'alpha',
        dragItems: ['alpha', 'beta'],
      );

      dragStateReducer(previous, const DragClearAction<String>());

      expect(previous.activeId, 'alpha');
      expect(previous.dragItems, ['alpha', 'beta']);
    });
  });

  group('reorderItemsOnDragEnd', () {
    test('moves the active item to the over position', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'alpha',
          overId: 'gamma',
          keyExtractor: _byValue,
        ),
        ['beta', 'gamma', 'alpha'],
      );
    });

    test('is a no-op when the drop target is missing', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'alpha',
          overId: null,
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });

    test('is a no-op when the active and over items are the same', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'beta',
          overId: 'beta',
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });

    test('is a no-op when the active id is not in the list', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'delta',
          overId: 'beta',
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });

    test('is a no-op when the over id is not in the list', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'alpha',
          overId: 'delta',
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });

    // Extra: upstream's guard is a JS truthiness check, so an empty key is
    // "no drop target" rather than a key that happens to be empty.
    test('is a no-op when the drop target key is empty', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'alpha',
          overId: '',
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });

    // Extra: dragging upward inserts before the target rather than after.
    test('moves the active item up to the over position', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'gamma',
          overId: 'alpha',
          keyExtractor: _byValue,
        ),
        ['gamma', 'alpha', 'beta'],
      );
    });

    // Extra: an adjacent swap is the most common gesture and must not
    // overshoot by one.
    test('swaps neighbours when dropped on the next item', () {
      expect(
        reorderItemsOnDragEnd(
          items: _items,
          activeId: 'alpha',
          overId: 'beta',
          keyExtractor: _byValue,
        ),
        ['beta', 'alpha', 'gamma'],
      );
    });

    // Extra: the input list is a snapshot the caller keeps rendering, so it
    // must survive the reorder unchanged.
    test('returns a new list without mutating the input', () {
      final source = [..._items];

      final result = reorderItemsOnDragEnd(
        items: source,
        activeId: 'alpha',
        overId: 'gamma',
        keyExtractor: _byValue,
      );

      expect(source, ['alpha', 'beta', 'gamma']);
      expect(identical(result, source), isFalse);
    });

    // Extra: the index argument of the key extractor is honoured, which is
    // what index-keyed lists rely on.
    test('resolves keys through the index-aware key extractor', () {
      expect(
        reorderItemsOnDragEnd(
          items: const [10, 20, 30],
          activeId: '0',
          overId: '2',
          keyExtractor: (item, index) => '$index',
        ),
        [20, 30, 10],
      );
    });

    // Extra: nothing can be reordered in a list with no drop targets.
    test('is a no-op on an empty list', () {
      expect(
        reorderItemsOnDragEnd(
          items: const <String>[],
          activeId: 'alpha',
          overId: 'beta',
          keyExtractor: _byValue,
        ),
        isNull,
      );
    });
  });

  group('getDragActivationConstraints', () {
    test('starts mouse drags after deliberate pointer movement', () {
      expect(
        getDragActivationConstraints(true, _config).mouse,
        const DistanceActivationConstraint(distance: 6),
      );
    });

    test('requires a short hold before starting touch drags', () {
      expect(
        getDragActivationConstraints(true, _config).touch,
        const DelayActivationConstraint(delayMs: 180, tolerance: 8),
      );
    });

    test('starts ordinary touch rows after deliberate movement', () {
      expect(
        getDragActivationConstraints(false, _config).touch,
        const DistanceActivationConstraint(distance: 6),
      );
    });

    // Extra: the drag handle only ever changes the touch rule; a mouse never
    // has to wait for a hold.
    test(
      'uses the movement rule for the mouse regardless of a drag handle',
      () {
        expect(
          getDragActivationConstraints(false, _config).mouse,
          const DistanceActivationConstraint(distance: 6),
        );
      },
    );

    // Extra: without a handle both pointers share one rule, which is what
    // makes a handle-less row feel identical on both inputs.
    test('shares one movement rule across pointers without a drag handle', () {
      final constraints = getDragActivationConstraints(false, _config);

      expect(constraints.touch, constraints.mouse);
    });
  });
}
