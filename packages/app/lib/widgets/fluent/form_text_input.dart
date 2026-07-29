import 'package:fluent_ui/fluent_ui.dart';

import '../../core/theme.dart';
import 'select_field.dart';

/// Paseo's field-sized text input chrome.
///
/// The frozen client uses the same 32/44 logical-pixel geometry as
/// [PaseoSelectFieldTrigger], including the 1.4 text line height and adaptive
/// horizontal padding.
class PaseoFormTextInput extends StatelessWidget {
  const PaseoFormTextInput({
    super.key,
    required this.controller,
    this.placeholder,
    this.semanticsLabel,
    this.size = PaseoFieldControlSize.md,
    this.maxLines = 1,
    this.multilineHeight,
    this.style,
    this.keyboardType,
    this.enabled = true,
    this.readOnly = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final String? semanticsLabel;
  final PaseoFieldControlSize size;
  final int maxLines;
  final double? multilineHeight;
  final TextStyle? style;
  final TextInputType? keyboardType;
  final bool enabled;
  final bool readOnly;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final medium = size == PaseoFieldControlSize.md;
    final fontSize = medium ? 16.0 : 14.0;
    final lineHeight = fontSize * 1.4;
    final controlHeight = medium ? 44.0 : 32.0;
    final horizontalPadding = medium ? 16.0 : 12.0;
    final verticalPadding = (controlHeight - lineHeight) / 2;
    final radius = medium ? 8.0 : 6.0;
    final height = maxLines > 1 ? multilineHeight ?? 96.0 : controlHeight;

    final decoration = WidgetStateProperty.resolveWith<BoxDecoration>((states) {
      final disabled = states.contains(WidgetState.disabled);
      final focused = states.contains(WidgetState.focused);
      final hovered = states.contains(WidgetState.hovered);
      return BoxDecoration(
        color: palette.surface2,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused || hovered ? palette.borderAccent : Colors.transparent,
        ),
        boxShadow: focused && !disabled
            ? [BoxShadow(color: palette.accent, blurRadius: 0, spreadRadius: 1)]
            : null,
      );
    });

    return Semantics(
      label: semanticsLabel,
      textField: true,
      enabled: enabled,
      readOnly: readOnly,
      child: Opacity(
        opacity: enabled ? 1 : .5,
        child: SizedBox(
          height: height,
          child: TextBox(
            controller: controller,
            placeholder: placeholder,
            maxLines: maxLines,
            keyboardType: keyboardType,
            enabled: enabled,
            readOnly: readOnly,
            textAlignVertical: maxLines > 1
                ? TextAlignVertical.top
                : TextAlignVertical.center,
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              verticalPadding,
              horizontalPadding,
              verticalPadding,
            ),
            decoration: decoration,
            foregroundDecoration: WidgetStateProperty.all(
              const BoxDecoration(),
            ),
            style: TextStyle(
              color: palette.foreground,
              fontSize: fontSize,
              height: 1.4,
            ).merge(style),
            placeholderStyle: TextStyle(
              color: palette.foregroundMuted,
              fontSize: fontSize,
              height: 1.4,
            ).merge(style),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

/// Non-interactive field chrome used by Paseo for immutable form values.
class PaseoReadOnlyField extends StatelessWidget {
  const PaseoReadOnlyField({
    super.key,
    required this.value,
    this.size = PaseoFieldControlSize.md,
  });

  final String value;
  final PaseoFieldControlSize size;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final medium = size == PaseoFieldControlSize.md;
    return Container(
      height: medium ? 44 : 32,
      padding: EdgeInsets.symmetric(horizontal: medium ? 16 : 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: context.tokens.outlineVariant),
        borderRadius: BorderRadius.circular(medium ? 8 : 6),
      ),
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: palette.foreground,
          fontSize: medium ? 16 : 14,
          height: 1.4,
        ),
      ),
    );
  }
}
