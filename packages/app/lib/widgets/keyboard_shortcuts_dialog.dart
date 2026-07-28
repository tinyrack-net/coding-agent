import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';

import '../keyboard/keyboard_shortcuts.dart';
import '../keyboard/shortcut_engine.dart';
import 'shortcut_badge.dart';

class KeyboardShortcutsDialog extends StatefulWidget {
  const KeyboardShortcutsDialog({
    super.key,
    required this.isMac,
    required this.onClose,
    this.overrides = const {},
  });

  final bool isMac;
  final VoidCallback onClose;
  final Map<String, String> overrides;

  @override
  State<KeyboardShortcutsDialog> createState() =>
      _KeyboardShortcutsDialogState();
}

class _KeyboardShortcutsDialogState extends State<KeyboardShortcutsDialog> {
  final _searchController = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String? _overrideFor(KeyboardShortcutHelpRow row) {
    for (final binding in defaultShortcutBindings) {
      if (binding.helpId != row.id) continue;
      if (binding.when?.mac case final mac? when mac != widget.isMac) {
        continue;
      }
      if (binding.when?.desktop case final desktop? when desktop != !kIsWeb) {
        continue;
      }
      return widget.overrides[binding.id];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final overrideValues = <String, String>{};
    for (final row in keyboardShortcutHelpRows) {
      final value = _overrideFor(row);
      if (value != null) overrideValues[row.id] = value;
    }
    final sections = filterKeyboardShortcutHelp(
      _query,
      isMac: widget.isMac,
      overrideValues: overrideValues,
    );
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
      title: Row(
        children: [
          const Expanded(child: Text('Keyboard shortcuts')),
          IconButton(
            icon: const Icon(FluentIcons.chrome_close, size: 14),
            onPressed: widget.onClose,
          ),
        ],
      ),
      content: Column(
        children: [
          TextBox(
            key: const ValueKey('keyboard-shortcuts-search'),
            controller: _searchController,
            autofocus: true,
            placeholder: 'Search shortcuts',
            prefix: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(FluentIcons.search, size: 16),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: sections.isEmpty
                ? const Center(child: Text('No results'))
                : ListView(
                    children: [
                      for (final section in sections.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                          child: Text(
                            section.key.title,
                            style: FluentTheme.of(context).typography.subtitle,
                          ),
                        ),
                        for (final row in section.value)
                          Padding(
                            key: ValueKey('shortcut-${row.id}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 7,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(row.label),
                                      if (row.note != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: Text(
                                            row.note!,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: FluentTheme.of(context)
                                                  .resources
                                                  .textFillColorSecondary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                if (_overrideFor(row) case final value?)
                                  ShortcutValueBadge(value: value)
                                else
                                  ShortcutBadge(
                                    keys: row.keys,
                                    isMac: widget.isMac,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
