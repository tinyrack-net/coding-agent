import 'package:fluent_ui/fluent_ui.dart';

import '../keyboard/keyboard_shortcuts.dart';

class ShortcutBadge extends StatelessWidget {
  const ShortcutBadge({super.key, required this.keys, required this.isMac});

  final List<String> keys;
  final bool isMac;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
        border: Border.all(
          color: FluentTheme.of(context).resources.cardStrokeColorDefault,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        formatShortcutKeys(keys, isMac: isMac),
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

class ShortcutValueBadge extends StatelessWidget {
  const ShortcutValueBadge({super.key, required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
        border: Border.all(
          color: FluentTheme.of(context).resources.cardStrokeColorDefault,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(value, style: const TextStyle(fontSize: 11)),
    );
  }
}
