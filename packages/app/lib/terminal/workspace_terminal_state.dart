import 'package:agent_protocol/agent_protocol.dart';

import 'terminal_list.dart';

const terminalsQueryStaleTime = Duration(seconds: 5);

typedef TerminalsQueryKey = ({
  String namespace,
  String serverId,
  String? workspaceDirectory,
  String? workspaceId,
});

TerminalsQueryKey buildTerminalsQueryKey(
  String serverId,
  String? workspaceDirectory, [
  String? workspaceId,
]) => (
  namespace: 'terminals',
  serverId: serverId,
  workspaceDirectory: workspaceDirectory,
  workspaceId: workspaceId,
);

bool canCreateWorkspaceTerminal({
  required bool isRouteFocused,
  required Object? client,
  required bool isConnected,
  required String? workspaceDirectory,
}) =>
    isRouteFocused &&
    client != null &&
    isConnected &&
    workspaceDirectory != null &&
    workspaceDirectory.isNotEmpty;

/// Removes pending script terminals once they are live or a fresher list has
/// proved they did not survive. Returns the original map when unchanged.
Map<String, int> reconcilePendingScriptTerminals({
  required List<String> liveTerminalIds,
  required int dataUpdatedAt,
  required Map<String, int> pendingTerminalIds,
}) {
  if (pendingTerminalIds.isEmpty) return pendingTerminalIds;
  final liveIds = liveTerminalIds.toSet();
  var changed = false;
  final nextTerminalIds = <String, int>{};
  for (final MapEntry(:key, :value) in pendingTerminalIds.entries) {
    if (liveIds.contains(key) || dataUpdatedAt > value) {
      changed = true;
      continue;
    }
    nextTerminalIds[key] = value;
  }
  return changed ? nextTerminalIds : pendingTerminalIds;
}

List<String> collectKnownTerminalIds({
  required List<String> liveTerminalIds,
  required Map<String, int> pendingScriptTerminalIds,
}) => {
  ...liveTerminalIds,
  ...pendingScriptTerminalIds.keys,
}.toList(growable: false);

final class WorkspaceScriptTerminal {
  const WorkspaceScriptTerminal({this.terminalId});

  final String? terminalId;
}

Set<String> collectScriptTerminalIds({
  required Map<String, int> pendingScriptTerminalIds,
  required List<WorkspaceScriptTerminal> scripts,
}) {
  final terminalIds = pendingScriptTerminalIds.keys.toSet();
  for (final script in scripts) {
    final terminalId = script.terminalId;
    if (terminalId != null && terminalId.isNotEmpty) {
      terminalIds.add(terminalId);
    }
  }
  return terminalIds;
}

List<String> collectStandaloneTerminalIds({
  required List<TerminalListEntry> terminals,
  required Set<String> scriptTerminalIds,
}) => [
  for (final terminal in terminals)
    if (!scriptTerminalIds.contains(terminal.id)) terminal.id,
];

final class ListTerminalsPayload {
  const ListTerminalsPayload({
    required this.terminals,
    required this.requestId,
    this.cwd,
  });

  final String? cwd;
  final List<TerminalListEntry> terminals;
  final String requestId;

  ListTerminalsPayload copyWith({
    String? cwd,
    List<TerminalListEntry>? terminals,
    String? requestId,
  }) => ListTerminalsPayload(
    cwd: cwd ?? this.cwd,
    terminals: terminals ?? this.terminals,
    requestId: requestId ?? this.requestId,
  );
}

ListTerminalsPayload? removeTerminalFromPayload(
  String terminalId,
  ListTerminalsPayload? current,
) {
  if (current == null) return null;
  return current.copyWith(
    terminals: [
      for (final terminal in current.terminals)
        if (terminal.id != terminalId) terminal,
    ],
  );
}

ListTerminalsPayload upsertCreatedTerminalPayload({
  required ListTerminalsPayload? current,
  required PaseoTerminalInfo terminal,
  required String? workspaceDirectory,
}) {
  final cwd = current?.cwd ?? workspaceDirectory;
  return ListTerminalsPayload(
    cwd: cwd != null && cwd.isNotEmpty ? cwd : null,
    terminals: upsertTerminalListEntry(
      terminals: current?.terminals ?? const [],
      terminal: terminal,
    ),
    requestId: current?.requestId ?? 'terminal-create-${terminal.id}',
  );
}
