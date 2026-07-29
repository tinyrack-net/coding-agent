import 'package:coding_agent_app/keyboard/keyboard_ime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isImeComposingKeyboardEvent', () {
    test('ignores events while IME composition is active', () {
      expect(
        isImeComposingKeyboardEvent(isComposing: true, keyCode: 13),
        isTrue,
      );
    });

    test('ignores Chromium IME fallback events with keyCode 229', () {
      expect(
        isImeComposingKeyboardEvent(isComposing: false, keyCode: 229),
        isTrue,
      );
    });

    test('keeps regular keyboard events eligible for shortcuts', () {
      expect(
        isImeComposingKeyboardEvent(isComposing: false, keyCode: 13),
        isFalse,
      );
    });
  });

  group('isImeComposingTextEditingValue', () {
    test('maps an active Flutter composing range to the Paseo guard', () {
      expect(
        isImeComposingTextEditingValue(
          const TextEditingValue(
            text: '작성',
            composing: TextRange(start: 0, end: 2),
          ),
        ),
        isTrue,
      );
      expect(
        isImeComposingTextEditingValue(
          const TextEditingValue(text: 'done', composing: TextRange.empty),
        ),
        isFalse,
      );
    });
  });
}
