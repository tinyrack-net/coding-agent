import 'package:agent_protocol/agent_protocol.dart';

import 'tool_call_grouping.dart';

final _directSearchToolSuffix = RegExp(
  r'(?:^|[_.:/])(?:web_search|llm_context)$',
);

final class ToolCallOverviewSummary {
  const ToolCallOverviewSummary({
    required this.editedFileCount,
    required this.commandCount,
    required this.readFileCount,
    required this.searchCount,
    required this.otherToolCount,
    required this.tinyrackCallCount,
  });

  final int editedFileCount;
  final int commandCount;
  final int readFileCount;
  final int searchCount;
  final int otherToolCount;
  final int tinyrackCallCount;
}

final class ToolCallOverviewGroup {
  const ToolCallOverviewGroup({
    required this.run,
    required this.summary,
    required this.isLoading,
  });

  final ToolCallRun run;
  final ToolCallOverviewSummary summary;
  final bool isLoading;
}

bool _isTinyrackCall(String name, String normalizedName) =>
    isPaseoToolName(name) || normalizedName.startsWith('paseo_');

ToolCallOverviewGroup buildToolCallOverviewGroup(ToolCallRun run) {
  final editedFiles = <String>{};
  final readFiles = <String>{};
  var isLoading = false;
  var commandCount = 0;
  var searchCount = 0;
  var otherToolCount = 0;
  var tinyrackCallCount = 0;

  for (final call in run.calls) {
    final descriptor = describeToolCall(call);
    final normalizedName = descriptor.name.trim().toLowerCase();
    isLoading =
        isLoading ||
        descriptor.status == ToolCallStatus.pending ||
        descriptor.status == ToolCallStatus.running;
    if (_isTinyrackCall(descriptor.name, normalizedName)) {
      tinyrackCallCount += 1;
    } else {
      switch (descriptor.detail) {
        case EditDetail(:final path) || WriteDetail(path: final path):
          editedFiles.add(path);
        case ShellDetail():
          commandCount += 1;
        case ReadDetail(:final path):
          readFiles.add(path);
        case SearchDetail():
          searchCount += 1;
        default:
          if (_directSearchToolSuffix.hasMatch(normalizedName)) {
            searchCount += 1;
          } else {
            otherToolCount += 1;
          }
      }
    }
  }

  return ToolCallOverviewGroup(
    run: run,
    isLoading: isLoading,
    summary: ToolCallOverviewSummary(
      editedFileCount: editedFiles.length,
      commandCount: commandCount,
      readFileCount: readFiles.length,
      searchCount: searchCount,
      otherToolCount: otherToolCount,
      tinyrackCallCount: tinyrackCallCount,
    ),
  );
}

String formatToolCallOverviewSummary(ToolCallOverviewSummary summary) {
  final parts = <String>[
    if (summary.editedFileCount > 0)
      'edited ${summary.editedFileCount} '
          '${summary.editedFileCount == 1 ? 'file' : 'files'}',
    if (summary.commandCount > 0)
      'ran ${summary.commandCount} '
          '${summary.commandCount == 1 ? 'command' : 'commands'}',
    if (summary.readFileCount > 0)
      'read ${summary.readFileCount} '
          '${summary.readFileCount == 1 ? 'file' : 'files'}',
    if (summary.searchCount > 0)
      'searched ${summary.searchCount} '
          '${summary.searchCount == 1 ? 'time' : 'times'}',
    if (summary.otherToolCount > 0)
      'used ${summary.otherToolCount} other '
          '${summary.otherToolCount == 1 ? 'tool' : 'tools'}',
    if (summary.tinyrackCallCount > 0)
      'called Tinyrack ${summary.tinyrackCallCount} '
          '${summary.tinyrackCallCount == 1 ? 'time' : 'times'}',
  ];
  if (parts.isEmpty) return '';
  final joined = switch (parts.length) {
    1 => parts.first,
    2 => '${parts.first} and ${parts.last}',
    _ => '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}',
  };
  return '${joined[0].toUpperCase()}${joined.substring(1)}';
}
