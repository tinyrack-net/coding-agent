import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent_session.dart';
import 'claude_image_output.dart';
import 'paseo_claude_rules.dart'
    show ClaudeConfigDirEnvironment, resolveClaudeConfigDir;

const _projectDirLengthCap = 200;

final class ClaudeHistorySnapshot {
  const ClaudeHistorySnapshot({
    required this.timeline,
    required this.providerSubagents,
  });

  final List<TimelineItem> timeline;
  final List<RestoredProviderSubagent> providerSubagents;
}

Future<List<TimelineItem>?> loadClaudeHistory({
  required String cwd,
  required String sessionId,
  Map<String, String>? environment,
}) async => (await loadClaudeHistorySnapshot(
  cwd: cwd,
  sessionId: sessionId,
  environment: environment,
))?.timeline;

Future<ClaudeHistorySnapshot?> loadClaudeHistorySnapshot({
  required String cwd,
  required String sessionId,
  Map<String, String>? environment,
}) async {
  final configDir = resolveClaudeConfigDir(
    ClaudeConfigDirEnvironment.fromPlatform(environment),
  );
  final historyPath = p.join(
    claudeProjectDir(cwd, configDir: configDir),
    '$sessionId.jsonl',
  );
  final file = File(historyPath);
  if (!await file.exists()) return null;
  try {
    final parentLines = await file.readAsLines();
    final sidechainLines = <String>[];
    final sidechainRoot = Directory(
      p.join(
        p.dirname(historyPath),
        p.basenameWithoutExtension(historyPath),
        'subagents',
      ),
    );
    if (await sidechainRoot.exists()) {
      await for (final entity in sidechainRoot.list(recursive: true)) {
        if (entity is File && p.extension(entity.path) == '.jsonl') {
          sidechainLines.addAll(await entity.readAsLines());
        }
      }
    }
    return ClaudeHistorySnapshot(
      timeline: projectClaudeHistory(parentLines),
      providerSubagents: projectClaudeProviderSubagents(
        parentLines,
        sidechainLines,
      ),
    );
  } on FileSystemException {
    return null;
  }
}

String claudeProjectDir(String cwd, {required String configDir}) {
  var canonical = cwd;
  try {
    canonical = Directory(cwd).resolveSymbolicLinksSync();
  } on FileSystemException {
    canonical = cwd;
  }
  final replaced = canonical.replaceAll(RegExp('[^a-zA-Z0-9]'), '-');
  final encoded = replaced.length <= _projectDirLengthCap
      ? replaced
      : '${replaced.substring(0, _projectDirLengthCap)}-'
            '${_javascriptHashSuffix(canonical)}';
  return p.join(configDir, 'projects', encoded);
}

List<TimelineItem> projectClaudeHistory(
  Iterable<String> lines, {
  bool includeSidechains = false,
}) {
  final timeline = <TimelineItem>[];
  final tools = <String, ({String name, Map<String, Object?> input})>{};
  var fallbackSequence = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    Map<String, Object?>? entry;
    try {
      entry = _record(jsonDecode(trimmed));
    } on FormatException {
      continue;
    }
    if (entry == null ||
        (!includeSidechains && entry['isSidechain'] == true) ||
        entry['isCompactSummary'] == true ||
        _isSyntheticHistoryUserEntry(entry)) {
      continue;
    }
    if (entry['type'] == 'system' && entry['subtype'] == 'compact_boundary') {
      final metadata = _record(entry['compactMetadata']);
      timeline.add(
        CompactionItem(
          id:
              entry['uuid'] as String? ??
              'claude-compaction-${fallbackSequence++}',
          status: CompactionStatus.completed,
          trigger: metadata?['trigger'] == 'manual'
              ? CompactionTrigger.manual
              : CompactionTrigger.auto,
          preTokens: (metadata?['preTokens'] as num?)?.toInt(),
        ),
      );
      continue;
    }
    final message = _record(entry['message']);
    final content = message?['content'];
    if ((entry['type'] == 'user' || entry['type'] == 'assistant') &&
        _isClaudeTranscriptNoiseContent(content)) {
      continue;
    }
    final entryId =
        entry['uuid'] as String? ?? 'claude-history-${fallbackSequence++}';
    if (entry['type'] == 'user') {
      final blocks = content is List ? content : const <Object?>[];
      for (final value in blocks) {
        final block = _record(value);
        if (block?['type'] != 'tool_result') continue;
        final toolUseId = block?['tool_use_id'];
        if (toolUseId is! String || toolUseId.isEmpty) continue;
        final tool = tools[toolUseId];
        final failed = block?['is_error'] == true;
        final resultContent = splitClaudeToolResultContent(block?['content']);
        final output = _contentText(resultContent.textContent);
        timeline.add(
          ToolCallItem(
            id: toolUseId,
            toolName: tool?.name ?? 'tool',
            status: failed ? ToolCallStatus.error : ToolCallStatus.success,
            detail: GenericDetail(
              input: tool?.input ?? const {},
              output: output,
              errorMessage: failed ? output : null,
            ),
          ),
        );
        for (
          var index = 0;
          index < resultContent.imageMarkdown.length;
          index++
        ) {
          timeline.add(
            AssistantMessageItem(
              id: '$toolUseId-image-$index',
              text: resultContent.imageMarkdown[index],
              complete: true,
            ),
          );
        }
      }
      final text = extractClaudeUserMessageText(content);
      if (text != null) {
        timeline.add(UserMessageItem(id: entryId, text: text));
      }
      continue;
    }
    if (entry['type'] != 'assistant') continue;
    if (content is String) {
      final text = content.trim();
      if (text.isNotEmpty) {
        timeline.add(
          AssistantMessageItem(id: entryId, text: text, complete: true),
        );
      }
      continue;
    }
    if (content is! List) continue;
    var blockIndex = 0;
    for (final value in content) {
      final block = _record(value);
      if (block == null) continue;
      final blockId =
          block['id'] as String? ?? '$entryId-block-${blockIndex++}';
      switch (block['type']) {
        case 'text':
          final text = (block['text'] as String?)?.trim();
          if (text != null && text.isNotEmpty) {
            timeline.add(
              AssistantMessageItem(id: blockId, text: text, complete: true),
            );
          }
        case 'thinking':
          final text = (block['thinking'] as String?)?.trim();
          if (text != null && text.isNotEmpty) {
            timeline.add(
              ReasoningItem(id: blockId, text: text, complete: true),
            );
          }
        case 'tool_use':
          final name = block['name'] as String? ?? 'tool';
          final input = _record(block['input']) ?? const {};
          tools[blockId] = (name: name, input: input);
          timeline.add(
            ToolCallItem(
              id: blockId,
              toolName: name,
              status: ToolCallStatus.running,
              detail: GenericDetail(input: input),
            ),
          );
      }
    }
  }
  return timeline;
}

List<RestoredProviderSubagent> projectClaudeProviderSubagents(
  Iterable<String> parentLines,
  Iterable<String> externalSidechainLines,
) {
  final parentEntries = _historyRecords(
    parentLines,
  ).where((entry) => entry['isSidechain'] != true).toList();
  final sidechainEntries =
      [
        ..._historyRecords(parentLines),
        ..._historyRecords(externalSidechainLines),
      ].where(
        (entry) => entry['isSidechain'] == true && entry['agentId'] is String,
      );
  final toolCalls =
      <String, ({String? name, String? type, String? description})>{};
  final results = <String, ({String toolCallId, bool failed})>{};
  for (final entry in parentEntries) {
    final content = _record(entry['message'])?['content'];
    if (content is! List) continue;
    for (final value in content) {
      final block = _record(value);
      if (block?['type'] == 'tool_use' &&
          (block?['name'] == 'Task' || block?['name'] == 'Agent') &&
          block?['id'] is String) {
        final input = _record(block?['input']);
        toolCalls[block!['id'] as String] = (
          name: _nonEmpty(input?['name']),
          type: _nonEmpty(input?['subagent_type']),
          description: _nonEmpty(input?['description']),
        );
      }
      if (block?['type'] != 'tool_result' || block?['tool_use_id'] is! String) {
        continue;
      }
      final match = RegExp(
        r'agentId:\s*([\w-]+)',
      ).firstMatch(jsonEncode(block?['content']));
      if (match?.group(1) case final agentId?) {
        results[agentId] = (
          toolCallId: block!['tool_use_id'] as String,
          failed: block['is_error'] == true,
        );
      }
    }
  }
  final grouped = <String, List<Map<String, Object?>>>{};
  for (final entry in sidechainEntries) {
    final agentId = entry['agentId']! as String;
    (grouped[agentId] ??= []).add(entry);
  }
  return [
    for (final group in grouped.entries)
      _restoreClaudeSubagent(
        group.key,
        group.value,
        result: results[group.key],
        toolCalls: toolCalls,
      ),
  ];
}

RestoredProviderSubagent _restoreClaudeSubagent(
  String agentId,
  List<Map<String, Object?>> entries, {
  required ({String toolCallId, bool failed})? result,
  required Map<String, ({String? name, String? type, String? description})>
  toolCalls,
}) {
  final id = result?.toolCallId ?? agentId;
  final tool = result == null ? null : toolCalls[result.toolCallId];
  return RestoredProviderSubagent(
    id: id,
    title: tool?.name ?? tool?.type ?? 'Claude subagent',
    description: tool?.description,
    status: result?.failed == true
        ? ProviderSubagentStatus.failed
        : ProviderSubagentStatus.completed,
    toolCallId: result?.toolCallId,
    timeline: projectClaudeHistory(
      entries.map(jsonEncode),
      includeSidechains: true,
    ),
  );
}

List<Map<String, Object?>> _historyRecords(Iterable<String> lines) {
  final entries = <Map<String, Object?>>[];
  for (final line in lines) {
    try {
      final entry = _record(jsonDecode(line));
      if (entry != null) entries.add(entry);
    } on FormatException {
      // Claude history can contain a corrupt row without invalidating the file.
    }
  }
  return entries;
}

String? _nonEmpty(Object? value) {
  final text = value is String ? value.trim() : '';
  return text.isEmpty ? null : text;
}

String? extractClaudeUserMessageText(Object? content) {
  if (content is String) {
    final command = RegExp(
      r'<command-name>([^<]+)</command-name>(?:\s*<command-args>([\s\S]*?)</command-args>)?',
    ).firstMatch(content);
    if (command != null) {
      final name = command.group(1)?.trim() ?? '';
      final args = command.group(2)?.trim() ?? '';
      return [name, args].where((value) => value.isNotEmpty).join(' ');
    }
    final text = content.trim();
    return text.isEmpty || _isClaudeTranscriptNoiseText(text) ? null : text;
  }
  if (content is! List) return null;
  final parts = <String>[];
  for (final value in content) {
    final block = _record(value);
    if (block?['type'] != 'text') continue;
    final text = (block?['text'] as String?)?.trim();
    if (text != null &&
        text.isNotEmpty &&
        !_isClaudeTranscriptNoiseText(text)) {
      parts.add(text);
    }
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

bool _isSyntheticHistoryUserEntry(Map<String, Object?> entry) {
  if (entry['type'] != 'user') return false;
  final synthetic =
      entry['isSynthetic'] == true ||
      entry['isMeta'] == true ||
      entry['toolUseResult'] != null;
  if (!synthetic) return false;
  final content = _record(entry['message'])?['content'];
  return content is! List ||
      !content.any((value) => _record(value)?['type'] == 'tool_result');
}

bool _isClaudeTranscriptNoiseContent(Object? content) {
  final parts = <String>[];
  if (content is String) {
    if (content.trim().isNotEmpty) parts.add(content.trim());
  } else if (content is List) {
    for (final value in content) {
      final block = _record(value);
      final text = block?['text'] ?? block?['input'];
      if (text is String && text.trim().isNotEmpty) parts.add(text.trim());
    }
  }
  return parts.isNotEmpty && parts.every(_isClaudeTranscriptNoiseText);
}

bool _isClaudeTranscriptNoiseText(String value) {
  final normalized = value.trim();
  return RegExp(
        r'^\[Request interrupted by user(?:[^\]]*)\]$',
      ).hasMatch(normalized) ||
      normalized == 'No response requested.' ||
      RegExp(
        r'^\s*<local-command-stdout>[\s\S]*</local-command-stdout>\s*$',
      ).hasMatch(normalized);
}

String? _contentText(Object? content) {
  if (content is String) return content;
  return extractClaudeUserMessageText(content);
}

Map<String, Object?>? _record(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _javascriptHashSuffix(String input) {
  var hash = 0;
  for (final codeUnit in input.codeUnits) {
    hash = ((hash << 5) - hash + codeUnit) & 0xffffffff;
  }
  if (hash >= 0x80000000) hash -= 0x100000000;
  return hash.abs().toRadixString(36);
}
