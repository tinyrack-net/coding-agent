final class AnchorVisibilityInput {
  const AnchorVisibilityInput({
    required this.headerOffset,
    required this.headerHeight,
    required this.viewportOffset,
    required this.viewportHeight,
    this.edgeThreshold = 1,
  });

  final double headerOffset;
  final double headerHeight;
  final double viewportOffset;
  final double viewportHeight;
  final double edgeThreshold;
}

bool shouldAnchorHeaderBeforeCollapse(AnchorVisibilityInput input) {
  if (!input.headerOffset.isFinite ||
      !input.headerHeight.isFinite ||
      !input.viewportOffset.isFinite ||
      !input.viewportHeight.isFinite ||
      input.viewportHeight <= 0) {
    return true;
  }

  final threshold = input.edgeThreshold < 0 ? 0.0 : input.edgeThreshold;
  final headerHeight = input.headerHeight < 0 ? 0.0 : input.headerHeight;
  final headerStart = input.headerOffset;
  final headerEnd = input.headerOffset + headerHeight;
  final viewportStart = input.viewportOffset + threshold;
  final viewportEnd = input.viewportOffset + input.viewportHeight - threshold;
  final headerVisible = headerEnd > viewportStart && headerStart < viewportEnd;
  return !headerVisible;
}
