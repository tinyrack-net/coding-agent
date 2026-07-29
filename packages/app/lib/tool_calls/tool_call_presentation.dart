import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import 'extract_tool_call_file_path.dart';
import 'tool_call_detail_state.dart';

typedef ToolCallIconResolver =
    IconData Function(String toolName, ToolCallDetail? detail);

final class ToolCallPresentation {
  const ToolCallPresentation({
    required this.displayName,
    required this.icon,
    required this.isLoadingDetails,
    required this.hasDetails,
    required this.canOpenDetails,
    required this.openFilePath,
    required this.isPlan,
    this.summary,
    this.errorText,
  });

  final String displayName;
  final String? summary;
  final String? errorText;
  final IconData icon;
  final bool isLoadingDetails;
  final bool hasDetails;
  final bool canOpenDetails;
  final String? openFilePath;
  final bool isPlan;
}

ToolCallPresentation buildToolCallPresentation({
  required String toolName,
  required ToolCallStatus status,
  required Object? error,
  required ToolCallDetail? detail,
  required ToolCallIconResolver resolveIcon,
  String? cwd,
  Map<String, Object?> metadata = const {},
}) {
  final detailForDisplay = detail ?? const GenericDetail(input: {});
  final display = buildToolCallDisplayModel(
    ToolCallDisplayInput(
      name: toolName,
      status: status,
      error: error,
      detail: detailForDisplay,
      metadata: metadata,
      cwd: cwd,
    ),
  );
  final isLoadingDetails = isPendingToolCallDetail(
    detail: detail,
    status: status,
    error: error,
  );
  final hasDetails = _isTruthy(error) || hasMeaningfulToolCallDetail(detail);
  return ToolCallPresentation(
    displayName: tinyrackToolCallDisplayName(toolName, display.displayName),
    summary: display.summary,
    errorText: display.errorText,
    icon: resolveIcon(toolName, detail),
    isLoadingDetails: isLoadingDetails,
    hasDetails: hasDetails,
    canOpenDetails: hasDetails || isLoadingDetails,
    openFilePath: extractToolCallFilePath(detail),
    isPlan: detail is PlanDetail,
  );
}

IconData resolveToolCallIcon(String toolName, ToolCallDetail? detail) =>
    switch (detail) {
      ShellDetail() => FluentIcons.command_prompt,
      ReadDetail() => FluentIcons.open_file,
      EditDetail() => FluentIcons.edit,
      WriteDetail() => FluentIcons.save,
      SearchDetail() => FluentIcons.search,
      FetchDetail() => FluentIcons.link,
      SubAgentDetail() => FluentIcons.branch_fork,
      WorktreeSetupToolDetail() => FluentIcons.branch_fork2,
      PlainTextDetail() => FluentIcons.info,
      PlanDetail() => FluentIcons.processing,
      GenericDetail() || null => FluentIcons.build,
    };

bool _isTruthy(Object? value) {
  if (value == null || value == false || value == 0 || value == '') {
    return false;
  }
  return true;
}
