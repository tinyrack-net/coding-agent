import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../keyboard/keyboard_shortcuts.dart';
import '../keyboard/shortcut_engine.dart';
import '../keyboard/shortcut_flutter_adapter.dart';
import '../state/keyboard_shortcut_overrides_provider.dart';
import '../widgets/shortcut_badge.dart';

class KeyboardShortcutsSettingsSection extends ConsumerStatefulWidget {
  const KeyboardShortcutsSettingsSection({super.key});

  @override
  ConsumerState<KeyboardShortcutsSettingsSection> createState() =>
      _KeyboardShortcutsSettingsSectionState();
}

class _KeyboardShortcutsSettingsSectionState
    extends ConsumerState<KeyboardShortcutsSettingsSection> {
  final _captureFocusNode = FocusNode(debugLabel: 'shortcut-capture');
  String? _capturingBindingId;
  List<String> _capturedCombos = const [];
  String? _heldModifiers;

  bool get _isMac =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void dispose() {
    _captureFocusNode.dispose();
    super.dispose();
  }

  ShortcutBinding? _bindingFor(KeyboardShortcutHelpRow row) {
    for (final binding in defaultShortcutBindings) {
      if (binding.helpId != row.id) continue;
      if (binding.when?.mac case final mac? when mac != _isMac) continue;
      if (binding.when?.desktop case final desktop? when desktop != !kIsWeb) {
        continue;
      }
      return binding;
    }
    return null;
  }

  List<(KeyboardShortcutHelpRow, ShortcutBinding)> _rowsFor(
    KeyboardShortcutSection section,
  ) => [
    for (final row in keyboardShortcutHelpRows)
      if (row.section == section)
        if (_bindingFor(row) case final binding?) (row, binding),
  ];

  void _startCapture(ShortcutBinding binding) {
    setState(() {
      _capturingBindingId = binding.id;
      _capturedCombos = const [];
      _heldModifiers = null;
    });
    _captureFocusNode.requestFocus();
  }

  void _cancelCapture() {
    setState(() {
      _capturingBindingId = null;
      _capturedCombos = const [];
      _heldModifiers = null;
    });
  }

  Future<void> _saveCapture() async {
    final bindingId = _capturingBindingId;
    if (bindingId == null || _capturedCombos.isEmpty) return;
    final chord = _capturedCombos.join(' ');
    await ref
        .read(keyboardShortcutOverridesProvider.notifier)
        .setOverride(bindingId, chord);
    if (mounted) _cancelCapture();
  }

  KeyEventResult _onCaptureKey(FocusNode node, KeyEvent event) {
    if (_capturingBindingId == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      setState(() => _heldModifiers = heldShortcutModifiers());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelCapture();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _capturedCombos.isNotEmpty) {
      setState(
        () => _capturedCombos = _capturedCombos.sublist(
          0,
          _capturedCombos.length - 1,
        ),
      );
      return KeyEventResult.handled;
    }
    final combo = shortcutComboStringFromKeyEvent(event);
    setState(() {
      _heldModifiers = heldShortcutModifiers();
      if (combo != null && event is! KeyRepeatEvent) {
        _capturedCombos = [..._capturedCombos, combo];
      }
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final overrides = ref.watch(keyboardShortcutOverridesProvider);
    return Focus(
      focusNode: _captureFocusNode,
      onKeyEvent: _onCaptureKey,
      child: ScaffoldPage.scrollable(
        key: const ValueKey('keyboard-shortcuts-settings'),
        header: const PageHeader(title: Text('Keyboard shortcuts')),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Customize keyboard shortcuts. Shortcuts can contain '
                  'multiple key combinations.',
                ),
              ),
              if (overrides.isNotEmpty)
                Button(
                  key: const ValueKey('shortcut-reset-all'),
                  onPressed: () => ref
                      .read(keyboardShortcutOverridesProvider.notifier)
                      .resetAll(),
                  child: const Text('Reset all'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          for (final section in KeyboardShortcutSection.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(
                section.title,
                style: FluentTheme.of(context).typography.subtitle,
              ),
            ),
            for (final entry in _rowsFor(section))
              _ShortcutSettingsRow(
                row: entry.$1,
                binding: entry.$2,
                isMac: _isMac,
                overrideValue: overrides[entry.$2.id],
                capturing: _capturingBindingId == entry.$2.id,
                capturedCombos: _capturedCombos,
                heldModifiers: _heldModifiers,
                onEdit: () => _startCapture(entry.$2),
                onReset: overrides.containsKey(entry.$2.id)
                    ? () => ref
                          .read(keyboardShortcutOverridesProvider.notifier)
                          .removeOverride(entry.$2.id)
                    : null,
                onDone: _capturedCombos.isEmpty ? null : _saveCapture,
                onCancel: _cancelCapture,
              ),
          ],
        ],
      ),
    );
  }
}

class _ShortcutSettingsRow extends StatelessWidget {
  const _ShortcutSettingsRow({
    required this.row,
    required this.binding,
    required this.isMac,
    required this.overrideValue,
    required this.capturing,
    required this.capturedCombos,
    required this.heldModifiers,
    required this.onEdit,
    required this.onReset,
    required this.onDone,
    required this.onCancel,
  });

  final KeyboardShortcutHelpRow row;
  final ShortcutBinding binding;
  final bool isMac;
  final String? overrideValue;
  final bool capturing;
  final List<String> capturedCombos;
  final String? heldModifiers;
  final VoidCallback onEdit;
  final VoidCallback? onReset;
  final VoidCallback? onDone;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('shortcut-setting-${row.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.label),
                    if (row.note != null)
                      Text(
                        row.note!,
                        style: TextStyle(
                          fontSize: 12,
                          color: FluentTheme.of(
                            context,
                          ).resources.textFillColorSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (overrideValue == null)
                ShortcutBadge(keys: row.keys, isMac: isMac)
              else
                ShortcutValueBadge(value: overrideValue!),
              const SizedBox(width: 6),
              if (onReset != null)
                IconButton(
                  key: ValueKey('shortcut-reset-${row.id}'),
                  icon: const Icon(FluentIcons.reset, size: 14),
                  onPressed: onReset,
                ),
              IconButton(
                key: ValueKey('shortcut-edit-${row.id}'),
                icon: const Icon(FluentIcons.edit, size: 14),
                onPressed: onEdit,
              ),
            ],
          ),
          if (capturing) ...[
            const Divider(),
            Text(
              capturedCombos.isEmpty
                  ? heldModifiers ?? 'Press a key combination'
                  : [...capturedCombos, ?heldModifiers].join('  '),
              key: const ValueKey('shortcut-capture-preview'),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Button(onPressed: onCancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('shortcut-capture-done'),
                  onPressed: onDone,
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
