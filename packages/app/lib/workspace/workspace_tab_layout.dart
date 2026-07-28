import 'dart:math' as math;

/// Frozen Paseo 0.2.0 workspace-tab sizing inputs.
class WorkspaceTabLayoutMetrics {
  const WorkspaceTabLayoutMetrics({
    required this.rowHorizontalInset,
    required this.actionsReservedWidth,
    required this.rowPaddingHorizontal,
    required this.tabGap,
    required this.maxTabWidth,
    required this.tabIconWidth,
    required this.tabHorizontalPadding,
    required this.estimatedCharWidth,
    required this.closeButtonWidth,
  });

  final double rowHorizontalInset;
  final double actionsReservedWidth;
  final double rowPaddingHorizontal;
  final double tabGap;
  final double maxTabWidth;
  final double tabIconWidth;
  final double tabHorizontalPadding;
  final double estimatedCharWidth;
  final double closeButtonWidth;
}

class WorkspaceTabLayoutItem {
  const WorkspaceTabLayoutItem({
    required this.width,
    required this.showLabel,
    required this.labelCharCap,
  });

  final double width;
  final bool showLabel;
  final int labelCharCap;
}

class WorkspaceTabLayoutResult {
  const WorkspaceTabLayoutResult({
    required this.items,
    required this.requiresHorizontalScrollFallback,
  });

  final List<WorkspaceTabLayoutItem> items;
  final bool requiresHorizontalScrollFallback;
}

/// Exact port of Paseo 0.2.0 `computeWorkspaceTabLayout`.
WorkspaceTabLayoutResult computeWorkspaceTabLayout({
  required double viewportWidth,
  required List<int> tabLabelLengths,
  required WorkspaceTabLayoutMetrics metrics,
}) {
  final tabCount = tabLabelLengths.length;
  if (tabCount == 0) {
    return const WorkspaceTabLayoutResult(
      items: [],
      requiresHorizontalScrollFallback: false,
    );
  }

  final availableWidth = math.max(
    0.0,
    viewportWidth -
        metrics.rowHorizontalInset * 2 -
        metrics.actionsReservedWidth,
  );
  final rowOverhead =
      metrics.rowPaddingHorizontal * 2 +
      math.max(tabCount - 1, 0) * metrics.tabGap;
  final availableTabsWidth = math.max(0.0, availableWidth - rowOverhead);
  final iconOnlyTabWidth =
      metrics.tabIconWidth +
      metrics.tabHorizontalPadding * 2 +
      metrics.closeButtonWidth;
  final requiresHorizontalScrollFallback =
      availableTabsWidth < iconOnlyTabWidth * tabCount;
  final resolvedWidth = requiresHorizontalScrollFallback
      ? iconOnlyTabWidth
      : (availableTabsWidth / tabCount).clamp(
          iconOnlyTabWidth,
          metrics.maxTabWidth,
        );
  final roundedWidth = resolvedWidth
      .clamp(iconOnlyTabWidth, metrics.maxTabWidth)
      .roundToDouble();

  return WorkspaceTabLayoutResult(
    items: List.generate(tabCount, (_) {
      final rawCharCap =
          ((roundedWidth - iconOnlyTabWidth) / metrics.estimatedCharWidth)
              .floor();
      final labelCharCap = math.max(0, rawCharCap);
      return WorkspaceTabLayoutItem(
        width: roundedWidth,
        showLabel: labelCharCap > 0,
        labelCharCap: labelCharCap,
      );
    }, growable: false),
    requiresHorizontalScrollFallback: requiresHorizontalScrollFallback,
  );
}
