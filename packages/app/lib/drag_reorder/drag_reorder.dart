/// Port of Paseo 0.2.0's `components/drag-reorder/drag-reducer.ts`,
/// `components/drag-reorder/reorder-items.ts`, and
/// `components/drag-reorder/pointer-activation.ts`.
///
/// These three modules are the pure decision layer behind every reorderable
/// list in the app (sidebar projects, workspace tabs, ...). Together they
/// answer three questions the drag UI must not answer ad hoc:
///
/// * *What is currently being dragged?* — [dragStateReducer] holds the active
///   key together with a **snapshot** of the list taken at drag start, so the
///   overlay keeps rendering a stable list even if the underlying data
///   refetches mid-gesture.
/// * *What does dropping mean?* — [reorderItemsOnDragEnd] resolves the drop
///   into a brand-new list, or into `null` when the gesture was a no-op, so
///   callers can skip persisting an unchanged order.
/// * *When does a press become a drag?* — [getDragActivationConstraints]
///   decides how much intent a pointer must show before the gesture is
///   claimed, which is what keeps a scroll from being mistaken for a drag.
///
/// Upstream leans on `@dnd-kit` for the last two (`arrayMove`, sensor
/// activation constraints). Flutter has no dnd-kit, so the ordering math is
/// reimplemented here to dnd-kit's exact semantics and the constraints are
/// ported as plain data for a Flutter gesture recognizer to consume.
library;

// ---------------------------------------------------------------------------
// drag-reducer.ts
// ---------------------------------------------------------------------------

/// The in-flight drag: which item is active, and the list as it looked when
/// the drag began.
///
/// Both fields move together — there is never an active id without a
/// snapshot, or vice versa — which is why the reducer only ever produces the
/// two shapes below rather than patching one field at a time.
final class DragState<T> {
  const DragState({required this.activeId, required this.dragItems});

  /// Key of the item under the pointer's grab, or null when idle.
  final String? activeId;

  /// List contents captured at drag start, or null when idle.
  final List<T>? dragItems;

  @override
  bool operator ==(Object other) =>
      other is DragState<T> &&
      other.activeId == activeId &&
      _listEquals(other.dragItems, dragItems);

  @override
  int get hashCode => Object.hash(
    activeId,
    dragItems == null ? null : Object.hashAll(dragItems!),
  );

  @override
  String toString() => 'DragState(activeId: $activeId, dragItems: $dragItems)';
}

/// TypeScript's discriminated union `{ type: "start" | "clear" }` becomes a
/// sealed hierarchy so the reducer's `switch` stays exhaustive at compile
/// time, exactly as the union made it exhaustive upstream.
sealed class DragAction<T> {
  const DragAction();
}

/// Begins tracking [id], snapshotting [data] as the list to render for the
/// duration of the gesture.
final class DragStartAction<T> extends DragAction<T> {
  const DragStartAction({required this.id, required this.data});

  final String id;
  final List<T> data;
}

/// Ends any in-flight drag, whether it was dropped, cancelled, or aborted.
final class DragClearAction<T> extends DragAction<T> {
  const DragClearAction();
}

/// The idle state a reorderable list starts in.
DragState<T> dragStateInitial<T>() =>
    DragState<T>(activeId: null, dragItems: null);

/// Applies [action] to [state].
///
/// A `start` always replaces whatever was in flight rather than being ignored
/// as a conflicting gesture: the pointer layer guarantees at most one active
/// drag, so a second start means the previous one was already abandoned and
/// its stale snapshot must not survive.
DragState<T> dragStateReducer<T>(DragState<T> state, DragAction<T> action) =>
    switch (action) {
      DragStartAction<T>(:final id, :final data) => DragState(
        activeId: id,
        dragItems: data,
      ),
      DragClearAction<T>() => DragState<T>(activeId: null, dragItems: null),
    };

// ---------------------------------------------------------------------------
// reorder-items.ts
// ---------------------------------------------------------------------------

/// Resolves a completed drag into the reordered list, or null when nothing
/// should change.
///
/// Returning null (rather than an equal list) is load-bearing: callers use it
/// to skip a persist/round-trip. The gesture is a no-op when there is no drop
/// target, when the item was dropped on itself, or when either key is absent
/// from [items] — the last case guards against a list that changed underneath
/// a long gesture.
///
/// [keyExtractor] receives the index alongside the item, mirroring upstream's
/// `(item, index) => string`, so lists keyed by position still work.
///
/// Note on [overId]: upstream's guard is the truthiness test `!overId`, which
/// rejects the empty string as well as null/undefined. That is preserved here
/// — an empty key means "no target", not "a target named ''".
List<T>? reorderItemsOnDragEnd<T>({
  required List<T> items,
  required String activeId,
  required String? overId,
  required String Function(T item, int index) keyExtractor,
}) {
  if (overId == null || overId.isEmpty || activeId == overId) return null;

  final oldIndex = _indexOfKey(items, activeId, keyExtractor);
  final newIndex = _indexOfKey(items, overId, keyExtractor);

  if (oldIndex < 0 || newIndex < 0 || oldIndex == newIndex) return null;

  return _arrayMove(items, oldIndex, newIndex);
}

int _indexOfKey<T>(
  List<T> items,
  String key,
  String Function(T item, int index) keyExtractor,
) {
  for (var index = 0; index < items.length; index += 1) {
    if (keyExtractor(items[index], index) == key) return index;
  }
  return -1;
}

/// Faithful reimplementation of `@dnd-kit/sortable`'s `arrayMove`.
///
/// The element is removed first and then inserted at [to], so moving an item
/// downward lands it *after* the items it passed — the behavior a user reads
/// off the drop indicator. A negative [to] counts back from the end, and
/// dnd-kit resolves that offset against the length *before* the removal, so
/// this does too.
List<T> _arrayMove<T>(List<T> items, int from, int to) {
  final insertAt = to < 0 ? items.length + to : to;
  final moved = [...items];
  final item = moved.removeAt(from);
  moved.insert(insertAt, item);
  return moved;
}

// ---------------------------------------------------------------------------
// pointer-activation.ts
// ---------------------------------------------------------------------------

/// How much intent a pointer must show before a press is claimed as a drag.
///
/// Upstream's union `{ distance } | { delay, tolerance }` becomes a sealed
/// hierarchy; the two variants are genuinely different activation strategies,
/// not one shape with optional fields.
sealed class PointerActivationConstraint {
  const PointerActivationConstraint();
}

/// Activate once the pointer has travelled [distance] logical pixels.
final class DistanceActivationConstraint extends PointerActivationConstraint {
  const DistanceActivationConstraint({required this.distance});

  final double distance;

  @override
  bool operator ==(Object other) =>
      other is DistanceActivationConstraint && other.distance == distance;

  @override
  int get hashCode => distance.hashCode;

  @override
  String toString() => 'DistanceActivationConstraint(distance: $distance)';
}

/// Activate after holding still for [delayMs], abandoning the drag if the
/// pointer strays more than [tolerance] logical pixels during the hold.
final class DelayActivationConstraint extends PointerActivationConstraint {
  const DelayActivationConstraint({
    required this.delayMs,
    required this.tolerance,
  });

  /// Hold duration in milliseconds. Kept as a raw millisecond count (rather
  /// than a [Duration]) to match the repo's other ports of upstream `*Ms`
  /// numbers and to keep the config a plain value object.
  final int delayMs;

  final double tolerance;

  @override
  bool operator ==(Object other) =>
      other is DelayActivationConstraint &&
      other.delayMs == delayMs &&
      other.tolerance == tolerance;

  @override
  int get hashCode => Object.hash(delayMs, tolerance);

  @override
  String toString() =>
      'DelayActivationConstraint(delayMs: $delayMs, tolerance: $tolerance)';
}

/// Tunable thresholds supplied by the caller (theme/platform constants
/// upstream), kept out of this module so the rule stays testable.
final class DragActivationConfig {
  const DragActivationConfig({
    required this.movementDistance,
    required this.touchHoldDelayMs,
    required this.touchHoldTolerance,
  });

  final double movementDistance;
  final int touchHoldDelayMs;
  final double touchHoldTolerance;
}

/// The per-input-device constraints for one reorderable list.
final class DragActivationConstraints {
  const DragActivationConstraints({required this.mouse, required this.touch});

  final PointerActivationConstraint mouse;
  final PointerActivationConstraint touch;
}

/// Chooses activation constraints for a list.
///
/// Mouse always activates on movement: a cursor cannot scroll a row by
/// dragging it, so there is nothing to disambiguate.
///
/// Touch depends on whether the row has a dedicated drag handle. With a
/// handle, the row itself is scrollable, so a touch drag must be a
/// press-and-hold — movement alone would steal every scroll. Without a
/// handle, the whole row is the drag affordance and movement is unambiguous
/// enough to activate immediately, matching the mouse rule.
DragActivationConstraints getDragActivationConstraints(
  bool useDragHandle,
  DragActivationConfig config,
) {
  final movement = DistanceActivationConstraint(
    distance: config.movementDistance,
  );
  return DragActivationConstraints(
    mouse: movement,
    touch: useDragHandle
        ? DelayActivationConstraint(
            delayMs: config.touchHoldDelayMs,
            tolerance: config.touchHoldTolerance,
          )
        : movement,
  );
}

// ---------------------------------------------------------------------------

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
