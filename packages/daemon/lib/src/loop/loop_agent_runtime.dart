import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_manager.dart';
import '../agent/create_agent_mode.dart';
import '../workspace/workspace_registry.dart';
import '../workspace/workspace_v2_service.dart';
import 'loop_service.dart';

final class LoopAgentRuntime {
  const LoopAgentRuntime(
    this.manager,
    this.workspaces, {
    required this.resolveCreateMode,
  });

  final AgentManager manager;
  final WorkspaceV2Service workspaces;
  final AgentCreateModeResolver resolveCreateMode;

  Future<LoopWorkspacePlacement> resolveWorkspace(
    String cwd,
    String prompt,
  ) async {
    final normalized = p.normalize(p.absolute(cwd));
    for (final workspace in await workspaces.listActiveAutomationWorkspaces()) {
      if (p.equals(p.normalize(p.absolute(workspace.cwd)), normalized)) {
        return _placement(workspace);
      }
    }
    final workspace = await workspaces.createAutomationWorkspace(
      DirectoryWorkspaceCreateSource(path: normalized),
      firstAgentContext: {'prompt': prompt},
    );
    return _placement(workspace);
  }

  Future<LoopAgentSession> createSession(LoopAgentSpec spec) async {
    final resolvedModeId = await resolveCreateMode(
      AgentCreateModeRequest(
        cwd: spec.cwd,
        targetProvider: spec.provider,
        requestedMode: spec.modeId,
        parent: null,
        unattended: true,
      ),
    );
    final agent = await manager.createAgent(
      cwd: spec.cwd,
      provider: spec.provider,
      model: spec.model ?? '',
      mode: _mode(resolvedModeId),
      modeId: resolvedModeId,
      title: spec.title,
      workspaceId: spec.workspace.workspaceId,
      projectPath: spec.workspace.projectPath,
      branch: spec.workspace.branch,
      isWorktree: spec.workspace.isWorktree,
      internal: true,
    );
    return _ManagerLoopAgentSession(
      manager: manager,
      agentId: agent.agentId,
      onLog: spec.onLog,
    );
  }
}

LoopWorkspacePlacement _placement(PersistedWorkspaceRecord workspace) =>
    LoopWorkspacePlacement(
      cwd: workspace.cwd,
      workspaceId: workspace.workspaceId,
      projectPath: workspace.mainRepoRoot,
      branch: workspace.branch,
      isWorktree: workspace.isPaseoOwnedWorktree,
    );

AgentMode _mode(String? modeId) => switch (modeId) {
  'plan' => AgentMode.plan,
  'full-access' || 'fullAccess' => AgentMode.fullAccess,
  _ => AgentMode.normal,
};

final class _ManagerLoopAgentSession implements LoopAgentSession {
  _ManagerLoopAgentSession({
    required this.manager,
    required this.agentId,
    required this.onLog,
  }) {
    _unsubscribe = manager.subscribeStream(_handleStream, agentId: agentId);
  }

  final AgentManager manager;
  @override
  final String agentId;
  final void Function(String text, {bool error}) onLog;
  late final void Function() _unsubscribe;
  bool _disposed = false;

  @override
  Future<String> run(String prompt) async {
    final outcome = await manager.runAndWait(agentId, prompt);
    return outcome.output ?? '';
  }

  @override
  Future<void> cancel() async {
    if (_disposed) return;
    await manager.cancelAgentRun(agentId);
  }

  @override
  Future<void> dispose({required bool archive}) async {
    if (_disposed) return;
    _disposed = true;
    _unsubscribe();
    if (archive) {
      await manager.archive(agentId);
    } else {
      await manager.delete(agentId);
    }
  }

  void _handleStream(AgentStreamPayload payload) {
    final item = payload.item;
    final rendered = renderLoopTimelineActivity(item);
    if (rendered == null) return;
    onLog(rendered, error: item is ErrorItem);
  }
}

String? renderLoopTimelineActivity(TimelineItem item) {
  final rendered = switch (item) {
    UserMessageItem(:final text) => '[User] ${text.trim()}',
    AssistantMessageItem(:final text) => text.trim(),
    ReasoningItem(:final text) => '[Thought] ${text.trim()}',
    ToolCallItem() => _renderToolCall(item),
    TodoItem(:final items) => [
      '[Tasks]',
      for (final entry in items)
        '- [${entry.completed ? 'x' : ' '}] ${entry.text}',
    ].join('\n'),
    ErrorItem(:final message) => '[Error] $message',
    CompactionItem() => '[Compacted]',
    PermissionItem() || TurnItem() => null,
  };
  return rendered?.trim().isEmpty == true ? null : rendered;
}

String _renderToolCall(ToolCallItem item) {
  final (displayName, rawSummary) = _toolDisplay(item);
  final input = item.detail is GenericDetail
      ? (item.detail as GenericDetail).input
      : null;
  final inputJson = input != null ? _truncate(jsonEncode(input), 400) : null;
  final summary = _nonEmpty(rawSummary);
  final main = isLikelyExternalToolName(item.toolName) && inputJson != null
      ? '[$displayName] $inputJson'
      : summary == null
      ? '[$displayName]'
      : '[$displayName] ${_summary(summary)}';
  if (item.detail case SubAgentDetail(:final log) when log.trim().isNotEmpty) {
    return '$main\n${log.trim()}';
  }
  return main;
}

(String, String?) _toolDisplay(ToolCallItem item) {
  final canonical = switch (item.detail) {
    ShellDetail(:final command) => ('Shell', command),
    ReadDetail(:final path) => ('Read', path),
    EditDetail(:final path) => ('Edit', path),
    WriteDetail(:final path) => ('Write', path),
    SearchDetail(:final query) => ('Search', query),
    FetchDetail(:final url) => ('Fetch', url),
    WorktreeSetupToolDetail(:final branchName) => (
      'Worktree Setup',
      branchName,
    ),
    SubAgentDetail(:final subAgentType, :final description) => (
      _readString(subAgentType) ?? 'Task',
      _readString(description),
    ),
    PlainTextDetail(:final label) => (_humanizeToolName(item.toolName), label),
    PlanDetail() => ('Plan', null),
    GenericDetail() => (_humanizeToolName(item.toolName), null),
  };
  final lowerName = item.toolName.trim().toLowerCase();
  if (item.detail is GenericDetail && lowerName == 'task') {
    return (
      'Task',
      item.metadata['subAgentActivity'] is String
          ? _readString(item.metadata['subAgentActivity']! as String)
          : null,
    );
  }
  if (item.detail is GenericDetail && lowerName == 'thinking') {
    return ('Thinking', null);
  }
  if (lowerName == 'terminal') {
    return (
      'Terminal',
      item.detail is PlainTextDetail
          ? _readString((item.detail as PlainTextDetail).label)
          : null,
    );
  }
  return canonical;
}

String _humanizeToolName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return name;
  if (isPaseoToolName(trimmed)) {
    final leaf = getPaseoToolLeafName(trimmed);
    if (leaf != null) return _humanizeToolName(leaf);
  }
  if (RegExp(r'[:./]').hasMatch(trimmed) || trimmed.contains('__')) {
    return trimmed;
  }
  return trimmed
      .replaceAll(RegExp(r'[._-]+'), ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _summary(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return _truncate(normalized, 200, ellipsisInsideLimit: true);
}

String _truncate(String value, int limit, {bool ellipsisInsideLimit = false}) {
  if (value.length <= limit) return value;
  final length = ellipsisInsideLimit ? limit - 3 : limit;
  return '${value.substring(0, length)}...';
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String? _readString(String? value) =>
    value == null || value.isEmpty ? null : value;
