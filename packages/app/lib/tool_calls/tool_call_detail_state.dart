import 'package:agent_protocol/agent_protocol.dart';

bool hasMeaningfulToolCallDetail(ToolCallDetail? detail) => switch (detail) {
  null => false,
  ShellDetail() => true,
  ReadDetail(:final path, :final content) ||
  WriteDetail(
    path: final path,
    contentPreview: final content,
  ) => path.isNotEmpty || (content?.isNotEmpty ?? false),
  EditDetail(:final path, :final diff, :final oldString, :final newString) =>
    path.isNotEmpty ||
        (diff?.isNotEmpty ?? false) ||
        (oldString?.isNotEmpty ?? false) ||
        (newString?.isNotEmpty ?? false),
  SearchDetail(
    :final query,
    :final content,
    :final filePaths,
    :final webResults,
    :final annotations,
  ) =>
    query.trim().isNotEmpty ||
        (content?.isNotEmpty ?? false) ||
        filePaths.isNotEmpty ||
        webResults.isNotEmpty ||
        annotations.isNotEmpty,
  FetchDetail(:final url, :final result, :final codeText) =>
    url.isNotEmpty ||
        (result?.isNotEmpty ?? false) ||
        (codeText?.isNotEmpty ?? false),
  WorktreeSetupToolDetail(:final branchName, :final worktreePath, :final log) =>
    branchName.isNotEmpty || worktreePath.isNotEmpty || log.isNotEmpty,
  SubAgentDetail(:final subAgentType, :final description, :final log) =>
    (subAgentType?.isNotEmpty ?? false) ||
        (description?.isNotEmpty ?? false) ||
        log.isNotEmpty,
  PlainTextDetail(:final label, :final text) =>
    (label?.isNotEmpty ?? false) || (text?.isNotEmpty ?? false),
  PlanDetail(:final text) => text.trim().isNotEmpty,
  GenericDetail(:final input, :final output) =>
    _hasMeaningfulUnknownValue(input) || _hasMeaningfulUnknownValue(output),
};

bool isPendingToolCallDetail({
  required ToolCallDetail? detail,
  required ToolCallStatus status,
  required Object? error,
}) =>
    (status == ToolCallStatus.pending || status == ToolCallStatus.running) &&
    error == null &&
    !hasMeaningfulToolCallDetail(detail);

bool _hasMeaningfulUnknownValue(Object? value) {
  if (value == null) return false;
  if (value is String) return value.trim().isNotEmpty;
  if (value is num || value is bool) return true;
  if (value is Iterable) return value.any(_hasMeaningfulUnknownValue);
  if (value is Map) {
    return value.values.any(_hasMeaningfulUnknownValue);
  }
  return true;
}
