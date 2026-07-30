import 'package:coding_agent_app/core/chat_scroll_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps bottom anchoring through subpixel browser zoom rounding', () {
    const maxScrollExtent = 4959.0;

    expect(
      isChatViewportOverscrolledPastBottom(
        pixels: 4959.1708984375,
        maxScrollExtent: maxScrollExtent,
      ),
      isFalse,
    );
    expect(
      isChatViewportOverscrolledPastBottom(
        pixels: 4960.5,
        maxScrollExtent: maxScrollExtent,
      ),
      isFalse,
    );
  });

  test('preserves material overscroll', () {
    const maxScrollExtent = 4959.0;

    expect(
      isChatViewportOverscrolledPastBottom(
        pixels: 4967,
        maxScrollExtent: maxScrollExtent,
      ),
      isTrue,
    );
    expect(
      isChatViewportOverscrolledPastBottom(
        pixels: maxScrollExtent,
        maxScrollExtent: maxScrollExtent,
      ),
      isFalse,
    );
  });
}
