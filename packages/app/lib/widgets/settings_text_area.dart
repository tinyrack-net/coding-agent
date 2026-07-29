import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

/// Frozen Paseo settings textarea: a multiline input without its own chrome.
class SettingsTextArea extends StatelessWidget {
  const SettingsTextArea({
    super.key,
    required this.accessibilityLabel,
    required this.controller,
    this.onChanged,
    this.placeholder,
    this.style,
  });

  final String accessibilityLabel;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String? placeholder;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return Semantics(
      textField: true,
      label: accessibilityLabel,
      child: SizedBox(
        height: 96,
        child: TextBox(
          controller: controller,
          onChanged: onChanged,
          placeholder: placeholder,
          placeholderStyle: TextStyle(
            color: palette.foregroundMuted,
            fontSize: 14,
          ),
          style: TextStyle(
            color: palette.foreground,
            fontSize: 14,
          ).merge(style),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          expands: true,
          minLines: null,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          decoration: const WidgetStatePropertyAll(
            BoxDecoration(color: Colors.transparent),
          ),
          foregroundDecoration: const WidgetStatePropertyAll(
            BoxDecoration(color: Colors.transparent),
          ),
        ),
      ),
    );
  }
}

/// Settings-style surface wrapper used by project and host text settings.
class SettingsTextAreaCard extends StatelessWidget {
  const SettingsTextAreaCard({
    super.key,
    required this.accessibilityLabel,
    required this.controller,
    this.onChanged,
    this.placeholder,
    this.style,
    this.inputKey,
  });

  final String accessibilityLabel;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String? placeholder;
  final TextStyle? style;
  final Key? inputKey;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: palette.surface1,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SettingsTextArea(
        key: inputKey,
        accessibilityLabel: accessibilityLabel,
        controller: controller,
        onChanged: onChanged,
        placeholder: placeholder,
        style: style,
      ),
    );
  }
}
