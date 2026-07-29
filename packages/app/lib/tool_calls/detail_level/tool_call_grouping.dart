import 'package:agent_protocol/agent_protocol.dart';

final class ToolCallDescriptor {
  const ToolCallDescriptor({
    required this.detail,
    required this.name,
    required this.status,
    required this.error,
    this.metadata = const {},
  });

  final ToolCallDetail detail;
  final String name;
  final ToolCallStatus status;
  final Object? error;
  final Map<String, Object?> metadata;
}

final class ToolCallRun {
  const ToolCallRun({
    required this.id,
    required this.calls,
    required this.latest,
    required this.isSealed,
  });

  final String id;
  final List<ToolCallItem> calls;
  final ToolCallItem latest;
  final bool isSealed;
}

final class GroupedToolCallHistory<TGroup> {
  const GroupedToolCallHistory({
    required this.tail,
    required this.groupsByHostId,
    required this.pendingCalls,
  });

  final List<TimelineItem> tail;
  final Map<String, TGroup> groupsByHostId;
  final List<ToolCallItem> pendingCalls;
}

final class GroupedToolCalls<TGroup> {
  const GroupedToolCalls({
    required this.tail,
    required this.head,
    required this.groupsByHostId,
    required this.historyGroupUpdatesByHostId,
  });

  final List<TimelineItem> tail;
  final List<TimelineItem> head;
  final Map<String, TGroup> groupsByHostId;
  final Map<String, TGroup> historyGroupUpdatesByHostId;
}

ToolCallDescriptor describeToolCall(ToolCallItem item) => ToolCallDescriptor(
  detail: item.detail,
  name: item.toolName,
  status: item.status,
  error: item.errorMessage,
  metadata: item.metadata,
);

bool isGroupableToolCall(TimelineItem item) =>
    item is ToolCallItem &&
    item.detail is! PlanDetail &&
    item.toolName.trim().toLowerCase() != 'speak';

ToolCallRun _createRun(List<ToolCallItem> calls, bool isSealed) {
  if (calls.isEmpty) {
    throw StateError('Cannot group an empty tool call run');
  }
  return ToolCallRun(
    id: calls.first.id,
    calls: List.unmodifiable(calls),
    latest: calls.last,
    isSealed: isSealed,
  );
}

ToolCallItem _createHost(ToolCallRun run) {
  if (run.calls.length == 1) return run.latest;
  final latest = run.latest;
  return ToolCallItem(
    id: run.id,
    toolName: latest.toolName,
    status: latest.status,
    detail: latest.detail,
    errorMessage: latest.errorMessage,
    metadata: latest.metadata,
  );
}

bool _isRunning(ToolCallItem call) =>
    call.status == ToolCallStatus.pending ||
    call.status == ToolCallStatus.running;

void _appendRun<TGroup>({
  required List<ToolCallItem> calls,
  required bool isSealed,
  required List<TimelineItem> output,
  required Map<String, TGroup> groups,
  required TGroup Function(ToolCallRun run) buildGroup,
}) {
  if (calls.isEmpty) return;
  final run = _createRun(calls, isSealed);
  final host = _createHost(run);
  output.add(host);
  groups[host.id] = buildGroup(run);
}

GroupedToolCallHistory<TGroup> prepareGroupedToolCallHistory<TGroup>({
  required List<TimelineItem> tail,
  required TGroup Function(ToolCallRun run) buildGroup,
}) {
  final output = <TimelineItem>[];
  final groups = <String, TGroup>{};
  var pending = <ToolCallItem>[];

  for (final item in tail) {
    if (isGroupableToolCall(item)) {
      pending.add(item as ToolCallItem);
      continue;
    }
    _appendRun(
      calls: pending,
      isSealed: true,
      output: output,
      groups: groups,
      buildGroup: buildGroup,
    );
    pending = [];
    output.add(item);
  }

  _appendRun(
    calls: pending,
    isSealed: true,
    output: output,
    groups: groups,
    buildGroup: buildGroup,
  );

  return GroupedToolCallHistory(
    tail: groups.isNotEmpty ? List.unmodifiable(output) : tail,
    groupsByHostId: groups.isEmpty ? const {} : Map.unmodifiable(groups),
    pendingCalls: List.unmodifiable(pending),
  );
}

GroupedToolCalls<TGroup> groupLiveToolCalls<TGroup>({
  required GroupedToolCallHistory<TGroup> history,
  required List<TimelineItem> head,
  required bool isTurnActive,
  required TGroup Function(ToolCallRun run) buildGroup,
}) {
  final projectedHead = <TimelineItem>[];
  final liveGroups = <String, TGroup>{};
  var pending = List<ToolCallItem>.of(history.pendingCalls);
  var hostInHistory = pending.isNotEmpty;
  var pendingIncludesHead = false;

  void flush(bool isSealed) {
    if (pending.isEmpty) return;
    final run = _createRun(pending, isSealed);
    if (!hostInHistory) projectedHead.add(_createHost(run));
    if (!hostInHistory || pendingIncludesHead || !isSealed) {
      liveGroups[run.id] = buildGroup(run);
    }
    pending = [];
    hostInHistory = false;
    pendingIncludesHead = false;
  }

  for (final item in head) {
    if (isGroupableToolCall(item)) {
      pending.add(item as ToolCallItem);
      pendingIncludesHead = true;
      continue;
    }
    flush(true);
    projectedHead.add(item);
  }

  final trailingRunIsActive = isTurnActive || pending.any(_isRunning);
  flush(!trailingRunIsActive);

  if (liveGroups.isEmpty) {
    return GroupedToolCalls(
      tail: history.tail,
      head: head,
      groupsByHostId: history.groupsByHostId,
      historyGroupUpdatesByHostId: const {},
    );
  }
  if (history.groupsByHostId.isEmpty) {
    return GroupedToolCalls(
      tail: history.tail,
      head: List.unmodifiable(projectedHead),
      groupsByHostId: Map.unmodifiable(liveGroups),
      historyGroupUpdatesByHostId: const {},
    );
  }

  final groups = Map<String, TGroup>.of(history.groupsByHostId);
  final historyUpdates = <String, TGroup>{};
  for (final entry in liveGroups.entries) {
    groups[entry.key] = entry.value;
    if (history.groupsByHostId.containsKey(entry.key)) {
      historyUpdates[entry.key] = entry.value;
    }
  }
  return GroupedToolCalls(
    tail: history.tail,
    head: List.unmodifiable(projectedHead),
    groupsByHostId: Map.unmodifiable(groups),
    historyGroupUpdatesByHostId: historyUpdates.isEmpty
        ? const {}
        : Map.unmodifiable(historyUpdates),
  );
}
