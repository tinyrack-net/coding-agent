import 'package:agent_protocol/agent_protocol.dart';

/// The compact terminal shape returned by Paseo's terminal list endpoint.
///
/// Create responses contain additional fields such as cwd and activity. The
/// list cache deliberately retains only these three fields.
final class TerminalListEntry {
  const TerminalListEntry({required this.id, required this.name, this.title});

  final String id;
  final String name;
  final String? title;
}

TerminalListEntry _toTerminalListEntry(PaseoTerminalInfo terminal) {
  final title = terminal.title;
  return TerminalListEntry(
    id: terminal.id,
    name: terminal.name,
    title: title != null && title.isNotEmpty ? title : null,
  );
}

/// Adds or replaces a created terminal without mutating the previous list.
///
/// Replacement stays at the original index, matching the frozen Paseo cache
/// update contract.
List<TerminalListEntry> upsertTerminalListEntry({
  required List<TerminalListEntry> terminals,
  required PaseoTerminalInfo terminal,
}) {
  final createdTerminal = _toTerminalListEntry(terminal);
  final existingIndex = terminals.indexWhere(
    (entry) => entry.id == createdTerminal.id,
  );
  if (existingIndex < 0) {
    return [...terminals, createdTerminal];
  }
  final nextTerminals = [...terminals];
  nextTerminals[existingIndex] = createdTerminal;
  return nextTerminals;
}
