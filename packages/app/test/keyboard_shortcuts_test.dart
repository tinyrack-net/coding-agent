import 'package:coding_agent_app/keyboard/keyboard_shortcuts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats platform shortcut keys', () {
    expect(
      formatShortcutKeys(['mod', 'shift', 'K'], isMac: false),
      'Ctrl+Shift+K',
    );
    expect(formatShortcutKeys(['mod', 'alt', 'T'], isMac: true), '⌘⌥T');
  });

  test('searches action, note, key combination and section', () {
    expect(
      filterKeyboardShortcutHelp(
        'command center',
        isMac: false,
      ).values.expand((rows) => rows).single.id,
      'toggle-command-center',
    );
    expect(
      filterKeyboardShortcutHelp(
        'text field',
        isMac: false,
      ).values.expand((rows) => rows).single.id,
      'show-shortcuts',
    );
    expect(
      filterKeyboardShortcutHelp(
        'ctrl+k',
        isMac: false,
      ).values.expand((rows) => rows).map((row) => row.id),
      contains('toggle-command-center'),
    );
    expect(
      filterKeyboardShortcutHelp(
        'panels',
        isMac: false,
      ).values.expand((rows) => rows).map((row) => row.section).toSet(),
      {KeyboardShortcutSection.panels},
    );
  });

  test('supports platform modifier aliases', () {
    expect(filterKeyboardShortcutHelp('command', isMac: true), isNotEmpty);
    expect(filterKeyboardShortcutHelp('control', isMac: false), isNotEmpty);
  });

  test('search includes customized shortcut values', () {
    final rows = filterKeyboardShortcutHelp(
      'ctrl+j',
      isMac: false,
      overrideValues: const {'toggle-command-center': 'Ctrl+J'},
    ).values.expand((items) => items);

    expect(rows.single.id, 'toggle-command-center');
  });
}
