import 'package:coding_agent_app/core/diff_scroll.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skips anchoring when the header is fully visible', () {
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 120,
          headerHeight: 44,
          viewportOffset: 80,
          viewportHeight: 400,
        ),
      ),
      isFalse,
    );
  });

  test('skips anchoring when the header is partially visible', () {
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 60,
          headerHeight: 44,
          viewportOffset: 80,
          viewportHeight: 300,
        ),
      ),
      isFalse,
    );
  });

  test('anchors when the header is above or below the viewport', () {
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 200,
          headerHeight: 44,
          viewportOffset: 500,
          viewportHeight: 300,
        ),
      ),
      isTrue,
    );
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 600,
          headerHeight: 44,
          viewportOffset: 100,
          viewportHeight: 300,
        ),
      ),
      isTrue,
    );
  });

  test('anchors when viewport metrics are unavailable', () {
    for (final input in [
      const AnchorVisibilityInput(
        headerOffset: 0,
        headerHeight: 44,
        viewportOffset: 0,
        viewportHeight: 0,
      ),
      AnchorVisibilityInput(
        headerOffset: double.nan,
        headerHeight: 44,
        viewportOffset: 0,
        viewportHeight: 300,
      ),
      AnchorVisibilityInput(
        headerOffset: 0,
        headerHeight: double.infinity,
        viewportOffset: 0,
        viewportHeight: 300,
      ),
    ]) {
      expect(shouldAnchorHeaderBeforeCollapse(input), isTrue);
    }
  });

  test('clamps negative threshold and header height', () {
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 100,
          headerHeight: 20,
          viewportOffset: 100,
          viewportHeight: 100,
          edgeThreshold: -10,
        ),
      ),
      isFalse,
    );
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 100,
          headerHeight: -20,
          viewportOffset: 100,
          viewportHeight: 100,
        ),
      ),
      isTrue,
    );
  });

  test('treats exact threshold contact as outside the viewport', () {
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 50,
          headerHeight: 32,
          viewportOffset: 80,
          viewportHeight: 100,
        ),
      ),
      isFalse,
    );
    expect(
      shouldAnchorHeaderBeforeCollapse(
        const AnchorVisibilityInput(
          headerOffset: 50,
          headerHeight: 31,
          viewportOffset: 80,
          viewportHeight: 100,
        ),
      ),
      isTrue,
    );
  });
}
