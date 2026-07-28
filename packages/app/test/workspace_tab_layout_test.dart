import 'package:flutter_test/flutter_test.dart';
import 'package:coding_agent_app/workspace/workspace_tab_layout.dart';

const metrics = WorkspaceTabLayoutMetrics(
  rowHorizontalInset: 0,
  actionsReservedWidth: 120,
  rowPaddingHorizontal: 8,
  tabGap: 4,
  maxTabWidth: 200,
  tabIconWidth: 14,
  tabHorizontalPadding: 12,
  estimatedCharWidth: 7,
  closeButtonWidth: 22,
);

void main() {
  WorkspaceTabLayoutResult layout(
    double width,
    List<int> labels, {
    WorkspaceTabLayoutMetrics resolvedMetrics = metrics,
  }) => computeWorkspaceTabLayout(
    viewportWidth: width,
    tabLabelLengths: labels,
    metrics: resolvedMetrics,
  );

  test('caps equal-width tabs at 200 when there is extra space', () {
    final result = layout(1200, [8, 10, 7]);
    expect(result.requiresHorizontalScrollFallback, isFalse);
    expect(result.items.map((item) => item.width), [200, 200, 200]);
    expect(result.items.every((item) => item.showLabel), isTrue);
  });

  test('shrinks equal-width tabs proportionally to fit', () {
    final result = layout(520, [24, 12, 8]);
    expect(result.requiresHorizontalScrollFallback, isFalse);
    expect(result.items.map((item) => item.width), [125, 125, 125]);
    expect(result.items.every((item) => item.showLabel), isTrue);
  });

  test('uses the exact available split width', () {
    const splitMetrics = WorkspaceTabLayoutMetrics(
      rowHorizontalInset: 0,
      actionsReservedWidth: 44,
      rowPaddingHorizontal: 0,
      tabGap: 0,
      maxTabWidth: 200,
      tabIconWidth: 14,
      tabHorizontalPadding: 12,
      estimatedCharWidth: 7,
      closeButtonWidth: 22,
    );
    final result = layout(743, [8, 8, 8, 8], resolvedMetrics: splitMetrics);
    expect(result.items.map((item) => item.width), [175, 175, 175, 175]);
  });

  test('collapses to icon-only before horizontal scrolling', () {
    final result = layout(388, [14, 14, 14, 14]);
    expect(result.requiresHorizontalScrollFallback, isFalse);
    expect(result.items.map((item) => item.width), [60, 60, 60, 60]);
    expect(result.items.every((item) => !item.showLabel), isTrue);
  });

  test('scrolls only when icon-only tabs cannot fit', () {
    final result = layout(300, [14, 14, 14, 14]);
    expect(result.requiresHorizontalScrollFallback, isTrue);
    expect(result.items.map((item) => item.width), [60, 60, 60, 60]);
    expect(result.items.every((item) => !item.showLabel), isTrue);
  });

  test('returns an empty layout when there are no tabs', () {
    final result = layout(1200, []);
    expect(result.items, isEmpty);
    expect(result.requiresHorizontalScrollFallback, isFalse);
  });
}
