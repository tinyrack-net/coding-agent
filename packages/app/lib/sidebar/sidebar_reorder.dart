List<String> mergeWithRemainder({
  required List<String> currentOrder,
  required List<String> reorderedVisibleKeys,
}) {
  final reordered = reorderedVisibleKeys.toSet();
  return [
    ...reorderedVisibleKeys,
    for (final key in currentOrder)
      if (!reordered.contains(key)) key,
  ];
}

bool hasVisibleOrderChanged({
  required List<String> currentOrder,
  required List<String> reorderedVisibleKeys,
}) {
  final visible = reorderedVisibleKeys.toSet();
  final currentVisible = [
    for (final key in currentOrder)
      if (visible.contains(key)) key,
  ];
  if (currentVisible.length != reorderedVisibleKeys.length) return true;
  for (var index = 0; index < reorderedVisibleKeys.length; index += 1) {
    if (currentVisible[index] != reorderedVisibleKeys[index]) return true;
  }
  return false;
}

List<T> applyStoredOrdering<T>({
  required List<T> items,
  required List<String> storedOrder,
  required String Function(T item) getKey,
}) {
  if (items.length <= 1 || storedOrder.isEmpty) return items;

  final itemByKey = {for (final item in items) getKey(item): item};
  final seen = <String>{};
  final prunedOrder = [
    for (final key in storedOrder)
      if (itemByKey.containsKey(key) && seen.add(key)) key,
  ];
  if (prunedOrder.isEmpty) return items;

  final orderedKeys = prunedOrder.toSet();
  var orderedIndex = 0;
  return [
    for (final item in items)
      if (!orderedKeys.contains(getKey(item)))
        item
      else
        itemByKey[prunedOrder[orderedIndex++]] ?? item,
  ];
}

List<String> appendMissingOrderKeys({
  required List<String> currentOrder,
  required List<String> visibleKeys,
}) {
  if (visibleKeys.isEmpty) return currentOrder;
  final existing = currentOrder.toSet();
  final missing = [
    for (final key in visibleKeys)
      if (!existing.contains(key)) key,
  ];
  return missing.isEmpty ? currentOrder : [...currentOrder, ...missing];
}

List<String> prependMissingOrderKeys({
  required List<String> currentOrder,
  required List<String> visibleKeys,
}) {
  if (visibleKeys.isEmpty) return currentOrder;
  final existing = currentOrder.toSet();
  final missing = [
    for (final key in visibleKeys)
      if (!existing.contains(key)) key,
  ];
  return missing.isEmpty ? currentOrder : [...missing, ...currentOrder];
}

List<T> reorderAt<T>(List<T> items, int oldIndex, int newIndex) {
  if (oldIndex < 0 ||
      oldIndex >= items.length ||
      newIndex < 0 ||
      newIndex > items.length) {
    return items;
  }
  final adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
  if (adjustedIndex == oldIndex) return items;
  final reordered = [...items];
  final item = reordered.removeAt(oldIndex);
  reordered.insert(adjustedIndex, item);
  return reordered;
}
