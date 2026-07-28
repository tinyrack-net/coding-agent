import 'package:agent_protocol/agent_protocol.dart';

/// Projects Codex `thread/read` turns into the provider-neutral timeline.
///
/// The native thread is authoritative on resume. Unknown future item types are
/// skipped, while known tool types retain their complete raw payload in a
/// generic detail until a richer renderer is available.
final class CodexPersistedSubagentRoute {
  const CodexPersistedSubagentRoute({
    required this.childThreadId,
    required this.toolCall,
  });

  final String childThreadId;
  final ToolCallItem toolCall;
}

final class CodexThreadHistoryProjection {
  const CodexThreadHistoryProjection({
    required this.timeline,
    required this.subagentRoutes,
  });

  final List<TimelineItem> timeline;
  final List<CodexPersistedSubagentRoute> subagentRoutes;
}

List<TimelineItem> projectCodexThreadHistory(
  Object? response, {
  required String cwd,
}) => projectCodexThreadHistoryWithSubagents(response, cwd: cwd).timeline;

CodexThreadHistoryProjection projectCodexThreadHistoryWithSubagents(
  Object? response, {
  required String cwd,
}) {
  final root = _record(response);
  if (root == null) {
    throw const FormatException('Codex thread/read response must be an object');
  }
  final threadValue = root['thread'];
  final thread = threadValue == null
      ? const <String, Object?>{}
      : _record(threadValue);
  if (thread == null) {
    throw const FormatException('Codex thread/read thread must be an object');
  }
  final turnsValue = thread['turns'];
  final turns = turnsValue == null ? const <Object?>[] : turnsValue;
  if (turns is! List) {
    throw const FormatException('Codex thread/read turns must be an array');
  }

  final result = <TimelineItem>[];
  final subagentIndexByThreadId = <String, int>{};
  var fallbackId = 0;
  for (final turnValue in turns) {
    final turn = _record(turnValue);
    if (turn == null) {
      throw const FormatException('Codex thread/read turn must be an object');
    }
    final itemsValue = turn['items'];
    final items = itemsValue == null ? const <Object?>[] : itemsValue;
    if (items is! List) {
      throw const FormatException(
        'Codex thread/read turn items must be an array',
      );
    }
    for (final itemValue in items) {
      final item = _record(itemValue);
      if (item == null) {
        continue;
      }
      fallbackId += 1;
      final projected = _projectItem(item, cwd: cwd, fallbackId: fallbackId);
      if (projected != null) {
        final activity = _subagentActivity(item);
        if (activity != null) {
          final existingIndex = subagentIndexByThreadId[activity.threadId];
          final existing = existingIndex == null ? null : result[existingIndex];
          if (existingIndex != null &&
              existing is ToolCallItem &&
              existing.detail is SubAgentDetail) {
            final existingDetail = existing.detail as SubAgentDetail;
            final projectedDetail =
                projected is ToolCallItem && projected.detail is SubAgentDetail
                ? projected.detail as SubAgentDetail
                : null;
            result[existingIndex] = ToolCallItem(
              id: existing.id,
              toolName: existing.toolName,
              status: activity.interrupted
                  ? ToolCallStatus.canceled
                  : ToolCallStatus.success,
              detail: SubAgentDetail(
                subAgentType:
                    projectedDetail?.subAgentType ??
                    existingDetail.subAgentType,
                description: existingDetail.description,
                childSessionId: activity.threadId,
                log: existingDetail.log,
                actions: existingDetail.actions,
              ),
            );
            continue;
          }
        }
        result.add(projected);
        if (projected is ToolCallItem && projected.detail is SubAgentDetail) {
          for (final threadId in _historicalSubagentThreadIds(item)) {
            subagentIndexByThreadId[threadId] = result.length - 1;
          }
        }
      }
    }
  }
  return CodexThreadHistoryProjection(
    timeline: result,
    subagentRoutes: [
      for (final entry in subagentIndexByThreadId.entries)
        if (result[entry.value] case final ToolCallItem toolCall)
          CodexPersistedSubagentRoute(
            childThreadId: entry.key,
            toolCall: toolCall,
          ),
    ],
  );
}

TimelineItem? _projectItem(
  Map<String, Object?> item, {
  required String cwd,
  required int fallbackId,
}) {
  final type = _normalizeType(item['type']);
  final id =
      _nonEmpty(item['id']) ??
      _nonEmpty(item['itemId']) ??
      'codex-history-$fallbackId';
  switch (type) {
    case 'userMessage':
      return UserMessageItem(id: id, text: _userText(item['content']));
    case 'agentMessage':
      return AssistantMessageItem(
        id: id,
        text: item['text'] is String ? item['text']! as String : '',
        complete: true,
      );
    case 'reasoning':
      final summary = _stringList(item['summary']).join('\n');
      final content = _stringList(item['content']).join('\n');
      final text = summary.isNotEmpty ? summary : content;
      return text.isEmpty
          ? null
          : ReasoningItem(id: id, text: text, complete: true);
    case 'contextCompaction':
      return CompactionItem(id: id, status: CompactionStatus.completed);
    case 'commandExecution':
      final command = _command(item['command']);
      final itemCwd = _nonEmpty(item['cwd']);
      final displayCommand = itemCwd == null || itemCwd == cwd
          ? command
          : 'cd $itemCwd && $command';
      return ToolCallItem(
        id: id,
        toolName: 'shell',
        status: _toolStatus(item),
        detail: ShellDetail(
          command: displayCommand,
          output: _firstString(item, ['aggregatedOutput', 'output']),
          exitCode: (item['exitCode'] as num?)?.toInt(),
        ),
      );
    case 'fileChange':
      return ToolCallItem(
        id: id,
        toolName: 'apply_patch',
        status: _toolStatus(item),
        detail: EditDetail(
          path: _firstString(item, ['path', 'file_path']) ?? '',
          diff: _firstString(item, [
            'diff',
            'patch',
            'unified_diff',
            'unifiedDiff',
          ]),
        ),
      );
    case 'plan':
      return ToolCallItem(
        id: id,
        toolName: 'plan',
        status: ToolCallStatus.success,
        detail: GenericDetail(
          input: {'text': item['text'] is String ? item['text'] : ''},
        ),
      );
    case 'mcpToolCall':
    case 'webSearch':
      return ToolCallItem(
        id: id,
        toolName: switch (type) {
          'mcpToolCall' => 'mcp',
          'webSearch' => 'web_search',
          _ => type!,
        },
        status: _toolStatus(item),
        detail: GenericDetail(input: Map<String, Object?>.from(item)),
      );
    case 'collabAgentToolCall':
      return ToolCallItem(
        id: id,
        toolName: 'Sub-agent',
        status: _collabStatus(item),
        detail: SubAgentDetail(
          subAgentType: 'Sub-agent',
          description: _nonEmpty(item['prompt']),
          childSessionId: _firstHistoricalSubagentThreadId(item),
        ),
      );
    case 'subAgentActivity':
      final activity = _subagentActivity(item);
      if (activity == null) {
        return null;
      }
      final display = _subagentDisplayName(item['agentPath']);
      return ToolCallItem(
        id: id,
        toolName: 'Sub-agent',
        status: activity.interrupted
            ? ToolCallStatus.canceled
            : ToolCallStatus.running,
        detail: SubAgentDetail(
          subAgentType: display.$1,
          description: display.$2,
          childSessionId: activity.threadId,
        ),
      );
    case 'imageView':
    case 'imageGeneration':
      final path = _firstString(item, ['path', 'savedPath', 'saved_path']);
      final url = _firstString(item, ['url']);
      final source = path ?? url;
      return source == null
          ? null
          : AssistantMessageItem(id: id, text: '![]($source)', complete: true);
    default:
      return null;
  }
}

ToolCallStatus _toolStatus(Map<String, Object?> item) {
  final status = item['status'];
  if (status == 'failed' || status == 'error') {
    return ToolCallStatus.error;
  }
  if (status == 'running' || status == 'inProgress') {
    return ToolCallStatus.running;
  }
  return ToolCallStatus.success;
}

ToolCallStatus _collabStatus(Map<String, Object?> item) {
  final states = _record(item['agentsStates']);
  if (item['status'] == 'failed' ||
      states?.values.any((state) => _record(state)?['status'] == 'failed') ==
          true) {
    return ToolCallStatus.error;
  }
  return ToolCallStatus.running;
}

({String threadId, bool interrupted})? _subagentActivity(
  Map<String, Object?> item,
) {
  if (_normalizeType(item['type']) != 'subAgentActivity') {
    return null;
  }
  final threadId = _nonEmpty(item['agentThreadId']);
  final kind = item['kind'];
  if (threadId == null ||
      (kind != 'started' && kind != 'interacted' && kind != 'interrupted')) {
    return null;
  }
  return (threadId: threadId, interrupted: kind == 'interrupted');
}

List<String> _historicalSubagentThreadIds(Map<String, Object?> item) {
  final activity = _subagentActivity(item);
  if (activity != null) {
    return [activity.threadId];
  }
  if (_normalizeType(item['type']) != 'collabAgentToolCall') {
    return const [];
  }
  final ids = item['receiverThreadIds'];
  return ids is List
      ? ids.whereType<String>().where((id) => id.isNotEmpty).toList()
      : const [];
}

String? _firstHistoricalSubagentThreadId(Map<String, Object?> item) {
  final ids = _historicalSubagentThreadIds(item);
  return ids.isEmpty ? null : ids.first;
}

(String, String) _subagentDisplayName(Object? rawPath) {
  var path = rawPath is String ? rawPath : '';
  if (path == '/root') {
    path = '';
  } else if (path.startsWith('/root/')) {
    path = path.substring('/root/'.length);
  } else if (path.contains('/') || path.contains(r'\')) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    path = path.substring((slash > backslash ? slash : backslash) + 1);
  }
  final name = path
      .split('/')
      .map((part) => part.replaceAll(RegExp('[_-]+'), ' ').trim())
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' / ');
  return (name.isEmpty ? 'Sub-agent' : name, path);
}

String _userText(Object? content) {
  if (content is! List) {
    return '';
  }
  return [
    for (final value in content)
      if (_record(value) case final record?)
        if (record['type'] == 'text' && record['text'] is String)
          record['text']! as String,
  ].join('\n');
}

String _command(Object? value) {
  if (value is String) {
    return value.trim();
  }
  if (value is List) {
    return value
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' ');
  }
  return '';
}

String? _normalizeType(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return switch (value) {
    'UserMessage' => 'userMessage',
    'AgentMessage' => 'agentMessage',
    'Reasoning' => 'reasoning',
    'Plan' => 'plan',
    'CommandExecution' => 'commandExecution',
    'FileChange' => 'fileChange',
    'McpToolCall' => 'mcpToolCall',
    'WebSearch' => 'webSearch',
    'CollabAgentToolCall' => 'collabAgentToolCall',
    'SubAgentActivity' => 'subAgentActivity',
    'ImageView' => 'imageView',
    'ImageGeneration' => 'imageGeneration',
    'context_compaction' => 'contextCompaction',
    _ => value,
  };
}

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

String? _firstString(Map<String, Object?> record, List<String> keys) {
  for (final key in keys) {
    if (record[key] is String) {
      return record[key]! as String;
    }
  }
  return null;
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

Map<String, Object?>? _record(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      return null;
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}
