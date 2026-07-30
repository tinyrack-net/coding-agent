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
    Iterable<String> matchingIds(String query, {required bool isMac}) =>
        filterKeyboardShortcutHelp(
          query,
          isMac: isMac,
        ).values.expand((rows) => rows).map((row) => row.id);

    expect(matchingIds('command+n', isMac: true), contains('new-workspace'));
    expect(matchingIds('cmd n', isMac: true), contains('new-workspace'));
    expect(
      matchingIds('option shift [', isMac: true),
      contains('workspace-tab-prev'),
    );
    expect(
      matchingIds('control+k', isMac: false),
      contains('toggle-command-center'),
    );
    expect(
      matchingIds('command+n', isMac: true),
      isNot(contains('toggle-command-center')),
    );
    expect(
      matchingIds('control+k', isMac: false),
      isNot(contains('new-workspace')),
    );
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
