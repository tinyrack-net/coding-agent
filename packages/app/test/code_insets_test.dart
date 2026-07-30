import 'package:coding_agent_app/widgets/code_insets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line-number gutter follows Paseo digit and font metrics', () {
    expect(lineNumberGutterWidth(0, 12), 28);
    expect(lineNumberGutterWidth(99, 12), 28);
    expect(lineNumberGutterWidth(100, 12), 36);
    expect(lineNumberGutterWidth(1234, 20), 64);
  });

  test('code insets preserve Paseo spacing fallbacks', () {
    expect(
      getCodeInsets(spacing3: 10, spacing4: 14),
      isA<CodeInsets>()
          .having((value) => value.padding, 'padding', 10)
          .having((value) => value.extraRight, 'right', 14)
          .having((value) => value.extraBottom, 'bottom', 10),
    );
    expect(getCodeInsets().padding, 12);
  });
}
