import 'dart:math' as math;

final class CodeInsets {
  const CodeInsets({
    required this.padding,
    required this.extraRight,
    required this.extraBottom,
  });

  final double padding;
  final double extraRight;
  final double extraBottom;
}

double lineNumberGutterWidth(int maxLineNumber, double fontSize) {
  final digits = math.max(2, maxLineNumber.toString().length);
  final digitWidth = (fontSize * .62).ceil();
  return (digits * digitWidth + 12).toDouble();
}

CodeInsets getCodeInsets({double? spacing3, double? spacing4}) {
  final resolvedSpacing3 = spacing3 ?? 12;
  final resolvedSpacing4 = spacing4 ?? 16;
  return CodeInsets(
    padding: spacing3 ?? spacing4 ?? 12,
    extraRight: resolvedSpacing4,
    extraBottom: resolvedSpacing3,
  );
}

final paseoCodeInsets = getCodeInsets(spacing3: 12, spacing4: 16);
