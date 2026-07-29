import 'package:fluent_ui/fluent_ui.dart';

const _darkSyntaxColors = <String, Color>{
  'keyword': Color(0xFFFF7B72),
  'comment': Color(0xFF8B949E),
  'string': Color(0xFFA5D6FF),
  'number': Color(0xFF79C0FF),
  'literal': Color(0xFF79C0FF),
  'function': Color(0xFFD2A8FF),
  'definition': Color(0xFFD2A8FF),
  'class': Color(0xFFFFA657),
  'type': Color(0xFFFF7B72),
  'tag': Color(0xFF7EE787),
  'attribute': Color(0xFF79C0FF),
  'property': Color(0xFF79C0FF),
  'variable': Color(0xFFC9D1D9),
  'operator': Color(0xFF79C0FF),
  'punctuation': Color(0xFFC9D1D9),
  'regexp': Color(0xFFA5D6FF),
  'escape': Color(0xFF79C0FF),
  'meta': Color(0xFF8B949E),
  'heading': Color(0xFF79C0FF),
  'link': Color(0xFFA5D6FF),
};

const _lightSyntaxColors = <String, Color>{
  'keyword': Color(0xFFCF222E),
  'comment': Color(0xFF6E7781),
  'string': Color(0xFF0A3069),
  'number': Color(0xFF0550AE),
  'literal': Color(0xFF0550AE),
  'function': Color(0xFF8250DF),
  'definition': Color(0xFF8250DF),
  'class': Color(0xFF953800),
  'type': Color(0xFFCF222E),
  'tag': Color(0xFF116329),
  'attribute': Color(0xFF0550AE),
  'property': Color(0xFF0550AE),
  'variable': Color(0xFF24292F),
  'operator': Color(0xFF0550AE),
  'punctuation': Color(0xFF24292F),
  'regexp': Color(0xFF0A3069),
  'escape': Color(0xFF0550AE),
  'meta': Color(0xFF6E7781),
  'heading': Color(0xFF0550AE),
  'link': Color(0xFF0A3069),
};

Color syntaxTokenColorFor(
  String? style, {
  required Brightness brightness,
  required Color baseColor,
}) =>
    (brightness == Brightness.dark
        ? _darkSyntaxColors
        : _lightSyntaxColors)[style] ??
    baseColor;
