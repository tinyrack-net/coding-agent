import 'package:agent_protocol/agent_protocol.dart';

final class WorkspaceTerminalSnapshots {
  WorkspaceTerminalSnapshots(this._snapshotByTerminalId);

  final Map<String, TerminalState> _snapshotByTerminalId;

  TerminalState? get(String terminalId) => _snapshotByTerminalId[terminalId];

  void set(String terminalId, TerminalState state) {
    _snapshotByTerminalId[terminalId] = state;
  }

  void clear(String terminalId) {
    _snapshotByTerminalId.remove(terminalId);
  }

  void prune(Iterable<String> terminalIds) {
    final retained = terminalIds.toSet();
    _snapshotByTerminalId.removeWhere(
      (terminalId, _) => !retained.contains(terminalId),
    );
  }
}

final class WorkspaceTerminalSession {
  const WorkspaceTerminalSession({
    required this.scopeKey,
    required this.snapshots,
  });

  final String scopeKey;
  final WorkspaceTerminalSnapshots snapshots;
}

final class _WorkspaceTerminalSessionRecord {
  const _WorkspaceTerminalSessionRecord({required this.session});
  final WorkspaceTerminalSession session;
}

final Map<String, _WorkspaceTerminalSessionRecord> _sessionsByScopeKey = {};
final Map<String, int> _refCountByScopeKey = {};

WorkspaceTerminalSession getWorkspaceTerminalSession(String scopeKey) {
  final existing = _sessionsByScopeKey[scopeKey];
  if (existing != null) return existing.session;

  final session = WorkspaceTerminalSession(
    scopeKey: scopeKey,
    snapshots: WorkspaceTerminalSnapshots({}),
  );
  _sessionsByScopeKey[scopeKey] = _WorkspaceTerminalSessionRecord(
    session: session,
  );
  return session;
}

void retainWorkspaceTerminalSession(String scopeKey) {
  _refCountByScopeKey[scopeKey] = (_refCountByScopeKey[scopeKey] ?? 0) + 1;
}

void releaseWorkspaceTerminalSession(String scopeKey) {
  final current = _refCountByScopeKey[scopeKey] ?? 0;
  if (current > 1) {
    _refCountByScopeKey[scopeKey] = current - 1;
    return;
  }
  _refCountByScopeKey.remove(scopeKey);
  _sessionsByScopeKey.remove(scopeKey);
}
