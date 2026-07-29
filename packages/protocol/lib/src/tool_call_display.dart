import 'dart:convert';

import 'path_utils.dart';
import 'timeline/timeline_item.dart';
import 'timeline/tool_call_detail.dart';
import 'tool_name_normalization.dart';

final class ToolCallDisplayInput {
  const ToolCallDisplayInput({
    required this.name,
    required this.status,
    required this.detail,
    this.error,
    this.metadata = const {},
    this.cwd,
  });

  factory ToolCallDisplayInput.fromItem(ToolCallItem item, {String? cwd}) =>
      ToolCallDisplayInput(
        name: item.toolName,
        status: item.status,
        error: item.errorMessage,
        metadata: item.metadata,
        detail: item.detail,
        cwd: cwd,
      );

  final String name;
  final ToolCallStatus status;
  final Object? error;
  final Map<String, Object?> metadata;
  final ToolCallDetail detail;
  final String? cwd;
}

final class ToolCallDisplayModel {
  const ToolCallDisplayModel({
    required this.displayName,
    this.summary,
    this.errorText,
  });

  final String displayName;
  final String? summary;
  final String? errorText;
}

({String? displayName, String? summary}) _canonicalDisplay(
  ToolCallDisplayInput input,
) => switch (input.detail) {
  ShellDetail(:final command) => (displayName: 'Shell', summary: command),
  ReadDetail(:final path) => (
    displayName: 'Read',
    summary: stripCwdPrefix(path, input.cwd),
  ),
  EditDetail(:final path) => (
    displayName: 'Edit',
    summary: stripCwdPrefix(path, input.cwd),
  ),
  WriteDetail(:final path) => (
    displayName: 'Write',
    summary: stripCwdPrefix(path, input.cwd),
  ),
  SearchDetail(:final query) => (displayName: 'Search', summary: query),
  FetchDetail(:final url) => (displayName: 'Fetch', summary: url),
  WorktreeSetupToolDetail(:final branchName) => (
    displayName: 'Worktree Setup',
    summary: branchName,
  ),
  SubAgentDetail(:final subAgentType, :final description) => (
    displayName: _readString(subAgentType) ?? 'Task',
    summary: _readString(description),
  ),
  PlainTextDetail(:final label) => (displayName: null, summary: label),
  PlanDetail() => (displayName: 'Plan', summary: null),
  GenericDetail() => (displayName: null, summary: null),
};

({String? displayName, String? summary}) _overrideDisplay(
  ToolCallDisplayInput input,
) {
  final lowerName = input.name.trim().toLowerCase();
  if (input.detail is GenericDetail && lowerName == 'task') {
    return (
      displayName: 'Task',
      summary: _readString(input.metadata['subAgentActivity']),
    );
  }
  if (input.detail is GenericDetail && lowerName == 'thinking') {
    return (displayName: 'Thinking', summary: null);
  }
  if (lowerName == 'terminal') {
    return (
      displayName: 'Terminal',
      summary: switch (input.detail) {
        PlainTextDetail(:final label) => _readString(label),
        _ => null,
      },
    );
  }
  return (displayName: null, summary: null);
}

ToolCallDisplayModel buildToolCallDisplayModel(ToolCallDisplayInput input) {
  final canonical = _canonicalDisplay(input);
  final override = _overrideDisplay(input);
  final displayName =
      override.displayName ??
      canonical.displayName ??
      humanizeToolCallName(input.name);
  final summary = override.summary ?? canonical.summary;
  final errorText = input.status == ToolCallStatus.error
      ? formatToolCallError(input.error)
      : null;
  return ToolCallDisplayModel(
    displayName: displayName,
    summary: summary != null && summary.isNotEmpty ? summary : null,
    errorText: errorText != null && errorText.isNotEmpty ? errorText : null,
  );
}

String humanizeToolCallName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return name;
  if (isPaseoToolName(trimmed)) {
    final leaf = getPaseoToolLeafName(trimmed);
    if (leaf != null) return humanizeToolCallName(leaf);
  }
  if (RegExp(r'[:./]').hasMatch(trimmed) || trimmed.contains('__')) {
    return trimmed;
  }
  return trimmed
      .replaceAll(RegExp(r'[._-]+'), ' ')
      .split(' ')
      .where((segment) => segment.isNotEmpty)
      .map((segment) => '${segment[0].toUpperCase()}${segment.substring(1)}')
      .join(' ');
}

/// Removes the frozen legacy product prefix only when it came from a
/// `paseo_*` internal tool name. The wire name stays unchanged for
/// conformance while Tinyrack-owned presentation remains brand-safe.
String tinyrackToolCallDisplayName(String toolName, String displayName) {
  final normalized = toolName.trim().toLowerCase();
  if (normalized.startsWith('paseo_') && displayName.startsWith('Paseo ')) {
    return displayName.substring('Paseo '.length);
  }
  return displayName;
}

String? formatToolCallError(Object? error) {
  if (error == null) return null;
  if (error is String) return error;
  if (error is Map && error['content'] is String) {
    return error['content']! as String;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(error);
  } on Object {
    return error.toString();
  }
}

String? _readString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
