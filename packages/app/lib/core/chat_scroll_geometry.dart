const double chatBottomOverscrollTolerance = 2;

/// Browser zoom can make the scroll offset fractional while the extent remains
/// integer-valued. Treat that subpixel mismatch as the visual bottom, but do
/// not consume a material overscroll gesture by snapping it back.
bool isChatViewportOverscrolledPastBottom({
  required double pixels,
  required double maxScrollExtent,
}) {
  final distanceFromBottom = maxScrollExtent - pixels;
  return distanceFromBottom < -chatBottomOverscrollTolerance;
}
