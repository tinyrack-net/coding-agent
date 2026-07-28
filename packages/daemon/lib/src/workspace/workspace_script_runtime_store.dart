import 'package:agent_protocol/agent_protocol.dart';

final class WorkspaceScriptRuntimeEntry {
  const WorkspaceScriptRuntimeEntry({
    required this.workspaceId,
    required this.scriptName,
    required this.type,
    required this.lifecycle,
    required this.terminalId,
    required this.exitCode,
  });

  final String workspaceId;
  final String scriptName;
  final WorkspaceScriptType type;
  final WorkspaceScriptLifecycle lifecycle;
  final String terminalId;
  final num? exitCode;

  WorkspaceScriptRuntimeEntry copyWith({
    String? workspaceId,
    String? scriptName,
    WorkspaceScriptType? type,
    WorkspaceScriptLifecycle? lifecycle,
    String? terminalId,
    Object? exitCode = _absent,
  }) => WorkspaceScriptRuntimeEntry(
    workspaceId: workspaceId ?? this.workspaceId,
    scriptName: scriptName ?? this.scriptName,
    type: type ?? this.type,
    lifecycle: lifecycle ?? this.lifecycle,
    terminalId: terminalId ?? this.terminalId,
    exitCode: identical(exitCode, _absent) ? this.exitCode : exitCode as num?,
  );
}

final class WorkspaceScriptRuntimeStore {
  final Map<String, WorkspaceScriptRuntimeEntry> _entries = {};
  final Map<String, Set<String>> _scriptsByWorkspace = {};

  WorkspaceScriptRuntimeEntry? get({
    required String workspaceId,
    required String scriptName,
  }) => _entries[_entryKey(workspaceId, scriptName)];

  void set(WorkspaceScriptRuntimeEntry entry) {
    final entryKey = _entryKey(entry.workspaceId, entry.scriptName);
    final previous = _entries[entryKey];
    if (previous != null) {
      _removeFromIndex(previous.workspaceId, previous.scriptName);
    }
    _entries[entryKey] = entry;
    (_scriptsByWorkspace[entry.workspaceId] ??= {}).add(entry.scriptName);
  }

  void remove({required String workspaceId, required String scriptName}) {
    final existing = _entries.remove(_entryKey(workspaceId, scriptName));
    if (existing == null) return;
    _removeFromIndex(existing.workspaceId, existing.scriptName);
  }

  List<WorkspaceScriptRuntimeEntry> listForWorkspace(String workspaceId) => [
    for (final scriptName
        in _scriptsByWorkspace[workspaceId] ?? const <String>{})
      if (_entries[_entryKey(workspaceId, scriptName)] case final entry?) entry,
  ];

  void removeForWorkspace(String workspaceId) {
    for (final entry in listForWorkspace(workspaceId)) {
      _entries.remove(_entryKey(entry.workspaceId, entry.scriptName));
    }
    _scriptsByWorkspace.remove(workspaceId);
  }

  bool isRunning({required String workspaceId, required String scriptName}) =>
      get(workspaceId: workspaceId, scriptName: scriptName)?.lifecycle ==
      WorkspaceScriptLifecycle.running;

  void _removeFromIndex(String workspaceId, String scriptName) {
    final scripts = _scriptsByWorkspace[workspaceId];
    if (scripts == null) return;
    scripts.remove(scriptName);
    if (scripts.isEmpty) _scriptsByWorkspace.remove(workspaceId);
  }

  String _entryKey(String workspaceId, String scriptName) =>
      '$workspaceId::$scriptName';
}

const Object _absent = Object();
