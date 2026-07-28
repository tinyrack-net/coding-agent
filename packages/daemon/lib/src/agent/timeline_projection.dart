import 'package:agent_protocol/agent_protocol.dart';

import 'timeline_store.dart';

enum TimelineProjectionKind {
  assistantMerge('assistant_merge'),
  reasoningMerge('reasoning_merge'),
  toolLifecycle('tool_lifecycle');

  const TimelineProjectionKind(this.wire);
  final String wire;
}

final class TimelineSeqRange {
  const TimelineSeqRange({required this.startSeq, required this.endSeq});

  final int startSeq;
  final int endSeq;

  Map<String, Object?> toJson() => {'startSeq': startSeq, 'endSeq': endSeq};
}

final class TimelineProjectionEntry {
  const TimelineProjectionEntry({
    required this.item,
    required this.timestamp,
    required this.seqStart,
    required this.seqEnd,
    required this.sourceSeqRanges,
    required this.collapsed,
  });

  final TimelineItem item;
  final String timestamp;
  final int seqStart;
  final int seqEnd;
  final List<TimelineSeqRange> sourceSeqRanges;
  final List<TimelineProjectionKind> collapsed;
}

final class ProjectedTimelinePage {
  const ProjectedTimelinePage({
    required this.entries,
    required this.startSeq,
    required this.endSeq,
    required this.hasOlder,
    required this.hasNewer,
  });

  final List<TimelineProjectionEntry> entries;
  final int? startSeq;
  final int? endSeq;
  final bool hasOlder;
  final bool hasNewer;
}

final class ProjectedItemSelection {
  const ProjectedItemSelection({
    required this.items,
    required this.totalProjected,
    required this.shownProjected,
  });

  final List<TimelineItem> items;
  final int totalProjected;
  final int shownProjected;
}

List<TimelineProjectionEntry> projectTimelineRows(
  List<TimelineRow> rows, {
  required bool projected,
}) {
  final canonical = [
    for (final row in rows)
      TimelineProjectionEntry(
        item: row.item,
        timestamp: row.timestamp,
        seqStart: row.seq,
        seqEnd: row.seq,
        sourceSeqRanges: [TimelineSeqRange(startSeq: row.seq, endSeq: row.seq)],
        collapsed: const [],
      ),
  ];
  if (!projected) return canonical;
  return _mergeReasoning(_mergeAssistant(_collapseTools(canonical)));
}

ProjectedItemSelection selectTimelineItemsByProjectedLimit({
  required List<TimelineItem> items,
  required String direction,
  required int limit,
}) {
  if (!const {'tail', 'before', 'after'}.contains(direction)) {
    throw ArgumentError.value(direction, 'direction');
  }
  if (limit < 0) throw RangeError.range(limit, 0, null, 'limit');
  final rows = [
    for (var index = 0; index < items.length; index++)
      TimelineRow(seq: index + 1, timestamp: '', item: items[index]),
  ];
  final projected = projectTimelineRows(rows, projected: true);
  final selected = _expandOverlaps(
    projected,
    _selectProjectedLimit(projected, direction: direction, limit: limit),
  );
  final minSeq = selected.map((entry) => entry.seqStart).minOrNull;
  final maxSeq = selected.map((entry) => entry.seqEnd).maxOrNull;
  return ProjectedItemSelection(
    items: minSeq == null || maxSeq == null
        ? const []
        : [
            for (final row in rows)
              if (row.seq >= minSeq && row.seq <= maxSeq) row.item,
          ],
    totalProjected: projected.length,
    shownProjected: selected.length,
  );
}

List<TimelineProjectionEntry> _collapseTools(
  List<TimelineProjectionEntry> entries,
) {
  final output = <TimelineProjectionEntry>[];
  final indexByCallId = <String, int>{};
  for (final entry in entries) {
    final item = entry.item;
    if (item is! ToolCallItem) {
      output.add(entry);
      continue;
    }
    final existingIndex = indexByCallId[item.id];
    if (existingIndex == null) {
      indexByCallId[item.id] = output.length;
      output.add(entry);
      continue;
    }
    final existing = output[existingIndex];
    if (existing.item is! ToolCallItem) {
      output.add(entry);
      continue;
    }
    final previous = existing.item as ToolCallItem;
    final detail =
        previous.detail is GenericDetail && item.detail is! GenericDetail
        ? item.detail
        : item.detail is GenericDetail && previous.detail is! GenericDetail
        ? previous.detail
        : item.detail;
    output[existingIndex] = TimelineProjectionEntry(
      item: ToolCallItem(
        id: item.id,
        toolName: item.toolName,
        status: item.status,
        detail: detail,
        errorMessage: item.status == ToolCallStatus.error
            ? item.errorMessage
            : null,
        metadata: {...previous.metadata, ...item.metadata},
      ),
      timestamp: entry.timestamp,
      seqStart: existing.seqStart,
      seqEnd: existing.seqEnd > entry.seqEnd ? existing.seqEnd : entry.seqEnd,
      sourceSeqRanges: _mergeRanges(
        existing.sourceSeqRanges,
        entry.sourceSeqRanges,
      ),
      collapsed: _withKind(
        existing.collapsed,
        TimelineProjectionKind.toolLifecycle,
      ),
    );
  }
  return output;
}

List<TimelineProjectionEntry> _mergeAssistant(
  List<TimelineProjectionEntry> entries,
) {
  final output = <TimelineProjectionEntry>[];
  for (final entry in entries) {
    final previous = output.lastOrNull;
    if (previous == null ||
        previous.item is! AssistantMessageItem ||
        entry.item is! AssistantMessageItem ||
        previous.seqEnd + 1 != entry.seqStart ||
        (entry.item as AssistantMessageItem).id !=
            (previous.item as AssistantMessageItem).id) {
      output.add(entry);
      continue;
    }
    final previousItem = previous.item as AssistantMessageItem;
    final incoming = entry.item as AssistantMessageItem;
    output[output.length - 1] = TimelineProjectionEntry(
      item: AssistantMessageItem(
        id: previousItem.id,
        text: '${previousItem.text}${incoming.text}',
        complete: incoming.complete,
      ),
      timestamp: entry.timestamp,
      seqStart: previous.seqStart,
      seqEnd: entry.seqEnd,
      sourceSeqRanges: _mergeRanges(
        previous.sourceSeqRanges,
        entry.sourceSeqRanges,
      ),
      collapsed: _withKinds(
        previous.collapsed,
        entry.collapsed,
        TimelineProjectionKind.assistantMerge,
      ),
    );
  }
  return output;
}

List<TimelineProjectionEntry> _mergeReasoning(
  List<TimelineProjectionEntry> entries,
) {
  final output = <TimelineProjectionEntry>[];
  for (final entry in entries) {
    final previous = output.lastOrNull;
    if (previous == null ||
        previous.item is! ReasoningItem ||
        entry.item is! ReasoningItem ||
        previous.seqEnd + 1 != entry.seqStart) {
      output.add(entry);
      continue;
    }
    final previousItem = previous.item as ReasoningItem;
    final incoming = entry.item as ReasoningItem;
    output[output.length - 1] = TimelineProjectionEntry(
      item: ReasoningItem(
        id: previousItem.id,
        text: '${previousItem.text}${incoming.text}',
        complete: incoming.complete,
      ),
      timestamp: entry.timestamp,
      seqStart: previous.seqStart,
      seqEnd: entry.seqEnd,
      sourceSeqRanges: _mergeRanges(
        previous.sourceSeqRanges,
        entry.sourceSeqRanges,
      ),
      collapsed: _withKinds(
        previous.collapsed,
        entry.collapsed,
        TimelineProjectionKind.reasoningMerge,
      ),
    );
  }
  return output;
}

ProjectedTimelinePage selectProjectedTimelinePage({
  required List<TimelineRow> rows,
  required String direction,
  required int limit,
  int? cursorSeq,
  int? boundMinSeq,
  int? boundMaxSeq,
}) {
  final projected = projectTimelineRows(rows, projected: true);
  final minSeq = boundMinSeq ?? rows.firstOrNull?.seq;
  final maxSeq = boundMaxSeq ?? rows.lastOrNull?.seq;
  if (minSeq == null || maxSeq == null) {
    return const ProjectedTimelinePage(
      entries: [],
      startSeq: null,
      endSeq: null,
      hasOlder: false,
      hasNewer: false,
    );
  }
  if (direction == 'tail') {
    final selected = _selectProjectedLimit(
      projected,
      direction: direction,
      limit: limit,
    );
    final expanded = _expandOverlaps(projected, selected);
    final start = expanded.map((entry) => entry.seqStart).minOrNull;
    final end = expanded.map((entry) => entry.seqEnd).maxOrNull;
    return ProjectedTimelinePage(
      entries: expanded,
      startSeq: start,
      endSeq: end,
      hasOlder: start != null && start > minSeq,
      hasNewer: false,
    );
  }
  if (direction == 'after') {
    final requestedStart = (cursorSeq ?? minSeq - 1) + 1;
    final start = requestedStart < minSeq ? minSeq : requestedStart;
    final eligible =
        <({TimelineProjectionEntry entry, int index, int seq})>[
          for (var index = 0; index < projected.length; index++)
            if (_firstSourceSeqInRange(projected[index], start, maxSeq)
                case final seq?)
              (entry: projected[index], index: index, seq: seq),
        ]..sort(
          (left, right) => left.seq.compareTo(right.seq) != 0
              ? left.seq.compareTo(right.seq)
              : left.index.compareTo(right.index),
        );
    final candidates = limit == 0 ? eligible : eligible.take(limit).toList();
    final selected =
        (candidates..sort((left, right) => left.index.compareTo(right.index)))
            .map((candidate) => candidate.entry)
            .toList();
    if (selected.isEmpty) {
      return ProjectedTimelinePage(
        entries: const [],
        startSeq: null,
        endSeq: null,
        hasOlder: start > minSeq,
        hasNewer: start <= maxSeq,
      );
    }
    final end = _contiguousEnd(rows, selected, start, maxSeq);
    return ProjectedTimelinePage(
      entries: selected,
      startSeq: end == null ? null : start,
      endSeq: end,
      hasOlder: start > minSeq,
      hasNewer: end != null && end < maxSeq,
    );
  }

  final end = ((cursorSeq ?? maxSeq + 1) - 1).clamp(minSeq, maxSeq);
  final start = limit == 0
      ? minSeq
      : ((cursorSeq ?? maxSeq + 1) - limit).clamp(minSeq, maxSeq);
  if (start > end) {
    return ProjectedTimelinePage(
      entries: const [],
      startSeq: null,
      endSeq: null,
      hasOlder: start > minSeq,
      hasNewer: end < maxSeq,
    );
  }
  final selected = projected
      .where((entry) => entry.seqStart <= end && entry.seqEnd >= start)
      .toList();
  return ProjectedTimelinePage(
    entries: selected,
    startSeq: start,
    endSeq: end,
    hasOlder: start > minSeq,
    hasNewer: end < maxSeq,
  );
}

int? _firstSourceSeqInRange(
  TimelineProjectionEntry entry,
  int startSeq,
  int endSeq,
) {
  for (final range in entry.sourceSeqRanges) {
    final first = range.startSeq > startSeq ? range.startSeq : startSeq;
    final last = range.endSeq < endSeq ? range.endSeq : endSeq;
    if (first <= last) return first;
  }
  return null;
}

List<TimelineProjectionEntry> _selectProjectedLimit(
  List<TimelineProjectionEntry> entries, {
  required String direction,
  required int limit,
}) {
  if (limit == 0 || limit >= entries.length) return List.of(entries);
  return direction == 'after'
      ? entries.take(limit).toList()
      : entries.skip(entries.length - limit).toList();
}

List<TimelineProjectionEntry> _expandOverlaps(
  List<TimelineProjectionEntry> all,
  List<TimelineProjectionEntry> selected,
) {
  if (selected.isEmpty) return const [];
  var minSeq = selected.map((entry) => entry.seqStart).minOrNull!;
  var maxSeq = selected.map((entry) => entry.seqEnd).maxOrNull!;
  var expanded = selected;
  for (var iteration = 0; iteration <= all.length; iteration++) {
    final overlapping = all
        .where((entry) => entry.seqStart <= maxSeq && entry.seqEnd >= minSeq)
        .toList();
    final nextMin = overlapping.map((entry) => entry.seqStart).minOrNull!;
    final nextMax = overlapping.map((entry) => entry.seqEnd).maxOrNull!;
    if (overlapping.length == expanded.length &&
        nextMin == minSeq &&
        nextMax == maxSeq) {
      return overlapping;
    }
    expanded = overlapping;
    minSeq = nextMin;
    maxSeq = nextMax;
  }
  return expanded;
}

int? _contiguousEnd(
  List<TimelineRow> rows,
  List<TimelineProjectionEntry> selected,
  int start,
  int max,
) {
  final ranges = selected.expand((entry) => entry.sourceSeqRanges).toList()
    ..sort((left, right) => left.startSeq.compareTo(right.startSeq));
  var end = start - 1;
  for (final row in rows) {
    if (row.seq < start) continue;
    if (row.seq > max || row.seq != end + 1) break;
    final covered = ranges.any(
      (range) => row.seq >= range.startSeq && row.seq <= range.endSeq,
    );
    if (!covered) break;
    end = row.seq;
  }
  return end >= start ? end : null;
}

List<TimelineSeqRange> _mergeRanges(
  List<TimelineSeqRange> existing,
  List<TimelineSeqRange> incoming,
) {
  final sequences = <int>{
    for (final range in [...existing, ...incoming])
      for (var seq = range.startSeq; seq <= range.endSeq; seq++) seq,
  }.toList()..sort();
  final ranges = <TimelineSeqRange>[];
  for (final seq in sequences) {
    final last = ranges.lastOrNull;
    if (last != null && seq <= last.endSeq + 1) {
      ranges[ranges.length - 1] = TimelineSeqRange(
        startSeq: last.startSeq,
        endSeq: seq > last.endSeq ? seq : last.endSeq,
      );
    } else {
      ranges.add(TimelineSeqRange(startSeq: seq, endSeq: seq));
    }
  }
  return ranges;
}

List<TimelineProjectionKind> _withKind(
  List<TimelineProjectionKind> existing,
  TimelineProjectionKind kind,
) => existing.contains(kind) ? existing : [...existing, kind];

List<TimelineProjectionKind> _withKinds(
  List<TimelineProjectionKind> first,
  List<TimelineProjectionKind> second,
  TimelineProjectionKind kind,
) => {...first, ...second, kind}.toList();

extension _IterableIntBounds on Iterable<int> {
  int? get minOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    var value = iterator.current;
    while (iterator.moveNext()) {
      if (iterator.current < value) value = iterator.current;
    }
    return value;
  }

  int? get maxOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    var value = iterator.current;
    while (iterator.moveNext()) {
      if (iterator.current > value) value = iterator.current;
    }
    return value;
  }
}
