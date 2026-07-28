enum KeyboardShortcutSection {
  navigation('Navigation'),
  tabsPanes('Tabs & Panes'),
  projects('Projects'),
  panels('Panels'),
  agentInput('Agent Input');

  const KeyboardShortcutSection(this.title);
  final String title;
}

final class KeyboardShortcutHelpRow {
  const KeyboardShortcutHelpRow({
    required this.id,
    required this.section,
    required this.label,
    required this.keys,
    this.note,
  });

  final String id;
  final KeyboardShortcutSection section;
  final String label;
  final List<String> keys;
  final String? note;
}

const keyboardShortcutHelpRows = <KeyboardShortcutHelpRow>[
  KeyboardShortcutHelpRow(
    id: 'workspace-jump-index',
    section: KeyboardShortcutSection.navigation,
    label: 'Jump to workspace',
    keys: ['mod', '1-9'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-tab-jump-index',
    section: KeyboardShortcutSection.navigation,
    label: 'Jump to tab',
    keys: ['alt', '1-9'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-prev',
    section: KeyboardShortcutSection.navigation,
    label: 'Previous workspace',
    keys: ['mod', '['],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-next',
    section: KeyboardShortcutSection.navigation,
    label: 'Next workspace',
    keys: ['mod', ']'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-tab-prev',
    section: KeyboardShortcutSection.navigation,
    label: 'Previous tab',
    keys: ['alt', 'shift', '['],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-tab-next',
    section: KeyboardShortcutSection.navigation,
    label: 'Next tab',
    keys: ['alt', 'shift', ']'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-tab-new',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'New tab',
    keys: ['mod', 'T'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-tab-close-current',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Close current tab',
    keys: ['ctrl', 'W'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-split-right',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Split pane right',
    keys: ['mod', r'\'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-split-down',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Split pane down',
    keys: ['mod', 'shift', r'\'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-focus-left',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Focus pane left',
    keys: ['mod', 'shift', 'Left'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-focus-right',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Focus pane right',
    keys: ['mod', 'shift', 'Right'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-focus-up',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Focus pane up',
    keys: ['mod', 'shift', 'Up'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-focus-down',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Focus pane down',
    keys: ['mod', 'shift', 'Down'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-move-tab-left',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Move tab left',
    keys: ['mod', 'shift', 'alt', 'Left'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-move-tab-right',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Move tab right',
    keys: ['mod', 'shift', 'alt', 'Right'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-move-tab-up',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Move tab up',
    keys: ['mod', 'shift', 'alt', 'Up'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-move-tab-down',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Move tab down',
    keys: ['mod', 'shift', 'alt', 'Down'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-pane-close',
    section: KeyboardShortcutSection.tabsPanes,
    label: 'Close pane',
    keys: ['mod', 'shift', 'W'],
  ),
  KeyboardShortcutHelpRow(
    id: 'new-agent',
    section: KeyboardShortcutSection.projects,
    label: 'Open project',
    keys: ['mod', 'O'],
  ),
  KeyboardShortcutHelpRow(
    id: 'new-workspace',
    section: KeyboardShortcutSection.projects,
    label: 'New workspace',
    keys: ['mod', 'N'],
  ),
  KeyboardShortcutHelpRow(
    id: 'archive-workspace',
    section: KeyboardShortcutSection.projects,
    label: 'Archive workspace',
    keys: ['mod', 'shift', 'Backspace'],
  ),
  KeyboardShortcutHelpRow(
    id: 'pin-workspace',
    section: KeyboardShortcutSection.projects,
    label: 'Pin workspace',
    keys: ['mod', 'shift', 'P'],
  ),
  KeyboardShortcutHelpRow(
    id: 'workspace-terminal-new',
    section: KeyboardShortcutSection.panels,
    label: 'New terminal',
    keys: ['mod', 'shift', 'T'],
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-command-center',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle command center',
    keys: ['mod', 'K'],
  ),
  KeyboardShortcutHelpRow(
    id: 'show-shortcuts',
    section: KeyboardShortcutSection.panels,
    label: 'Show keyboard shortcuts',
    keys: ['?'],
    note: 'Available when focus is not in a text field or terminal.',
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-left-sidebar',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle left sidebar',
    keys: ['mod', 'B'],
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-right-sidebar',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle right sidebar',
    keys: ['mod', 'E'],
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-both-sidebars',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle both sidebars',
    keys: ['mod', '.'],
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-settings',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle settings',
    keys: ['mod', ','],
  ),
  KeyboardShortcutHelpRow(
    id: 'toggle-focus',
    section: KeyboardShortcutSection.panels,
    label: 'Toggle focus mode',
    keys: ['mod', 'shift', 'F'],
  ),
  KeyboardShortcutHelpRow(
    id: 'cycle-theme',
    section: KeyboardShortcutSection.panels,
    label: 'Cycle theme',
    keys: ['mod', 'alt', 'T'],
  ),
  KeyboardShortcutHelpRow(
    id: 'focus-message-input',
    section: KeyboardShortcutSection.agentInput,
    label: 'Focus message input',
    keys: ['mod', 'L'],
  ),
  KeyboardShortcutHelpRow(
    id: 'cycle-agent-mode',
    section: KeyboardShortcutSection.agentInput,
    label: 'Cycle agent mode',
    keys: ['shift', 'Tab'],
  ),
  KeyboardShortcutHelpRow(
    id: 'voice-toggle',
    section: KeyboardShortcutSection.agentInput,
    label: 'Toggle voice mode',
    keys: ['mod', 'shift', 'D'],
  ),
  KeyboardShortcutHelpRow(
    id: 'dictation-toggle',
    section: KeyboardShortcutSection.agentInput,
    label: 'Start/stop dictation',
    keys: ['mod', 'D'],
  ),
  KeyboardShortcutHelpRow(
    id: 'agent-interrupt',
    section: KeyboardShortcutSection.agentInput,
    label: 'Interrupt agent',
    keys: ['Esc'],
  ),
  KeyboardShortcutHelpRow(
    id: 'voice-mute-toggle',
    section: KeyboardShortcutSection.agentInput,
    label: 'Mute/unmute voice mode',
    keys: ['Space'],
  ),
];

Map<KeyboardShortcutSection, List<KeyboardShortcutHelpRow>>
filterKeyboardShortcutHelp(
  String query, {
  required bool isMac,
  Map<String, String> overrideValues = const {},
}) {
  final normalized = query.trim().toLowerCase();
  final aliases = isMac
      ? const ['command', 'cmd', 'option', 'alt']
      : const ['ctrl', 'control', 'win', 'windows'];
  final result = <KeyboardShortcutSection, List<KeyboardShortcutHelpRow>>{};
  for (final section in KeyboardShortcutSection.values) {
    final sectionMatches = section.title.toLowerCase().contains(normalized);
    final rows = keyboardShortcutHelpRows.where((row) {
      if (row.section != section) return false;
      if (normalized.isEmpty || sectionMatches) return true;
      final keys = formatShortcutKeys(row.keys, isMac: isMac);
      final haystack = [
        row.label,
        row.note ?? '',
        row.keys.join(' '),
        row.keys.join('+'),
        keys,
        overrideValues[row.id] ?? '',
        ...aliases,
      ].join(' ').toLowerCase();
      return haystack.contains(normalized);
    }).toList();
    if (rows.isNotEmpty) result[section] = rows;
  }
  return result;
}

String formatShortcutKeys(List<String> keys, {required bool isMac}) {
  return keys
      .map((key) {
        return switch (key) {
          'mod' => isMac ? '⌘' : 'Ctrl',
          'ctrl' => 'Ctrl',
          'alt' => isMac ? '⌥' : 'Alt',
          'shift' => isMac ? '⇧' : 'Shift',
          'Left' => '←',
          'Right' => '→',
          'Up' => '↑',
          'Down' => '↓',
          'Backspace' => '⌫',
          'Esc' => 'Esc',
          _ => key,
        };
      })
      .join(isMac ? '' : '+');
}
