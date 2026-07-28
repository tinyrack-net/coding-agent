import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../providers/agent_session.dart';

final class ProviderSubagentTimelineSnapshot {
  const ProviderSubagentTimelineSnapshot({
    required this.descriptor,
    required this.epoch,
    required this.rows,
  });

  final ProviderSubagentDescriptor descriptor;
  final String epoch;
  final List<ProviderSubagentTimelineRow> rows;
}

final class ProviderSubagentTimelinePage {
  const ProviderSubagentTimelinePage({
    required this.descriptor,
    required this.direction,
    required this.epoch,
    required this.reset,
    required this.staleCursor,
    required this.gap,
    required this.window,
    required this.hasOlder,
    required this.hasNewer,
    required this.rows,
  });

  final ProviderSubagentDescriptor descriptor;
  final ProviderSubagentTimelineDirection direction;
  final String epoch;
  final bool reset;
  final bool staleCursor;
  final bool gap;
  final ProviderSubagentTimelineWindow window;
  final bool hasOlder;
  final bool hasNewer;
  final List<ProviderSubagentTimelineRow> rows;
}

final class _ProviderSubagentRecord {
  _ProviderSubagentRecord({
    required this.descriptor,
    required this.epoch,
    List<ProviderSubagentTimelineRow> rows = const [],
  }) : rows = List.of(rows),
       nextSeq = 1;

  ProviderSubagentDescriptor descriptor;
  final String epoch;
  final List<ProviderSubagentTimelineRow> rows;
  int nextSeq;
}

/// In-memory replica source for Paseo's provider-managed subagent protocol.
///
/// Provider sessions are authoritative. A resumed provider repopulates this
/// store from native history before the next user turn.
final class ProviderSubagentStore {
  ProviderSubagentStore({this.onUpdate});

  final void Function(ProviderSubagentUpdate update)? onUpdate;
  final _uuid = const Uuid();
  final Map<String, Map<String, _ProviderSubagentRecord>> _byParent = {};

  List<ProviderSubagentDescriptor> list(String parentAgentId) =>
      (_byParent[parentAgentId]?.values ?? const Iterable.empty())
          .map((record) => record.descriptor)
          .toList()
        ..sort((left, right) => left.createdAt.compareTo(right.createdAt));

  ProviderSubagentDescriptor? get(String parentAgentId, String subagentId) =>
      _byParent[parentAgentId]?[subagentId]?.descriptor;

  ProviderSubagentTimelineSnapshot? timeline(
    String parentAgentId,
    String subagentId,
  ) {
    final record = _byParent[parentAgentId]?[subagentId];
    return record == null
        ? null
        : ProviderSubagentTimelineSnapshot(
            descriptor: record.descriptor,
            epoch: record.epoch,
            rows: List.unmodifiable(record.rows),
          );
  }

  ProviderSubagentTimelinePage? fetchTimeline(
    String parentAgentId,
    String subagentId, {
    ProviderSubagentTimelineDirection direction =
        ProviderSubagentTimelineDirection.tail,
    ProviderSubagentTimelineCursor? cursor,
    int limit = 200,
  }) {
    final record = _byParent[parentAgentId]?[subagentId];
    if (record == null) return null;
    final boundedLimit = limit < 0 ? 0 : limit;
    final rows = record.rows;
    final minSeq = rows.isEmpty ? 0 : rows.first.seq;
    final maxSeq = rows.isEmpty ? 0 : rows.last.seq;
    final window = ProviderSubagentTimelineWindow(
      minSeq: minSeq,
      maxSeq: maxSeq,
      nextSeq: record.nextSeq,
    );

    ProviderSubagentTimelinePage page({
      required List<ProviderSubagentTimelineRow> selected,
      bool reset = false,
      bool staleCursor = false,
      bool gap = false,
      required bool hasOlder,
      required bool hasNewer,
    }) => ProviderSubagentTimelinePage(
      descriptor: record.descriptor,
      direction: direction,
      epoch: record.epoch,
      reset: reset,
      staleCursor: staleCursor,
      gap: gap,
      window: window,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      rows: List.unmodifiable(selected),
    );

    List<ProviderSubagentTimelineRow> tail() =>
        boundedLimit == 0 || boundedLimit >= rows.length
        ? List.of(rows)
        : rows.sublist(rows.length - boundedLimit);

    if (cursor != null && cursor.epoch != record.epoch) {
      final selected = tail();
      return page(
        selected: selected,
        reset: true,
        staleCursor: true,
        hasOlder: selected.isNotEmpty && selected.first.seq > minSeq,
        hasNewer: false,
      );
    }
    if (direction == ProviderSubagentTimelineDirection.after &&
        cursor != null &&
        rows.isNotEmpty &&
        cursor.seq < minSeq - 1) {
      final selected = tail();
      return page(
        selected: selected,
        reset: true,
        gap: true,
        hasOlder: selected.isNotEmpty && selected.first.seq > minSeq,
        hasNewer: false,
      );
    }
    if (rows.isEmpty) {
      return page(selected: const [], hasOlder: false, hasNewer: false);
    }

    switch (direction) {
      case ProviderSubagentTimelineDirection.tail:
        final selected = tail();
        return page(
          selected: selected,
          hasOlder: selected.first.seq > minSeq,
          hasNewer: false,
        );
      case ProviderSubagentTimelineDirection.after:
        final baseSeq = cursor?.seq ?? 0;
        final start = rows.indexWhere((row) => row.seq > baseSeq);
        if (start < 0) {
          return page(
            selected: const [],
            hasOlder: baseSeq >= minSeq,
            hasNewer: false,
          );
        }
        final end = boundedLimit == 0
            ? rows.length
            : (start + boundedLimit).clamp(0, rows.length);
        final selected = rows.sublist(start, end);
        return page(
          selected: selected,
          hasOlder: selected.first.seq > minSeq,
          hasNewer: selected.last.seq < maxSeq,
        );
      case ProviderSubagentTimelineDirection.before:
        final beforeSeq = cursor?.seq ?? record.nextSeq;
        final firstAtOrAfter = rows.indexWhere((row) => row.seq >= beforeSeq);
        final end = firstAtOrAfter < 0 ? rows.length : firstAtOrAfter;
        final start = boundedLimit == 0
            ? 0
            : (end - boundedLimit).clamp(0, end);
        final selected = rows.sublist(start, end);
        return page(
          selected: selected,
          hasOlder: selected.isNotEmpty && selected.first.seq > minSeq,
          hasNewer: firstAtOrAfter >= 0,
        );
    }
  }

  void replace(
    String parentAgentId,
    String provider,
    List<RestoredProviderSubagent> restored,
  ) {
    _byParent.remove(parentAgentId);
    for (final child in restored) {
      upsert(
        parentAgentId: parentAgentId,
        provider: provider,
        subagentId: child.id,
        title: child.title,
        description: child.description,
        status: child.status,
        toolCallId: child.toolCallId,
        cwd: child.cwd,
      );
      for (final item in child.timeline) {
        appendTimeline(
          parentAgentId: parentAgentId,
          provider: provider,
          subagentId: child.id,
          item: item,
        );
      }
    }
  }

  void clear(String parentAgentId) {
    final removed = _byParent.remove(parentAgentId);
    if (removed == null) return;
    for (final id in removed.keys) {
      onUpdate?.call(
        ProviderSubagentRemove(parentAgentId: parentAgentId, subagentId: id),
      );
    }
  }

  ProviderSubagentDescriptor upsert({
    required String parentAgentId,
    required String provider,
    required String subagentId,
    required ProviderSubagentStatus status,
    String? title,
    String? description,
    String? toolCallId,
    String? cwd,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final parent = _byParent.putIfAbsent(parentAgentId, () => {});
    final existing = parent[subagentId];
    final descriptor = ProviderSubagentDescriptor(
      id: subagentId,
      parentAgentId: parentAgentId,
      provider: provider,
      title: title ?? existing?.descriptor.title,
      description: description ?? existing?.descriptor.description,
      status: status,
      createdAt: existing?.descriptor.createdAt ?? now,
      updatedAt: now,
      toolCallId: toolCallId ?? existing?.descriptor.toolCallId,
      cwd: cwd ?? existing?.descriptor.cwd,
    );
    if (existing == null) {
      parent[subagentId] = _ProviderSubagentRecord(
        descriptor: descriptor,
        epoch: _uuid.v4(),
      );
    } else {
      existing.descriptor = descriptor;
    }
    onUpdate?.call(ProviderSubagentUpsert(subagent: descriptor));
    return descriptor;
  }

  ProviderSubagentTimelineUpdate appendTimeline({
    required String parentAgentId,
    required String provider,
    required String subagentId,
    required TimelineItem item,
    String? timestamp,
  }) {
    final record = _byParent[parentAgentId]?[subagentId];
    if (record == null) {
      throw StateError('provider subagent $subagentId is not registered');
    }
    final seq = record.nextSeq;
    record.nextSeq += 1;
    final resolvedTimestamp =
        timestamp ?? DateTime.now().toUtc().toIso8601String();
    final row = ProviderSubagentTimelineRow(
      item: item,
      timestamp: resolvedTimestamp,
      seq: seq,
    );
    record.rows.add(row);
    final update = ProviderSubagentTimelineUpdate(
      parentAgentId: parentAgentId,
      subagentId: subagentId,
      provider: provider,
      item: item,
      timestamp: resolvedTimestamp,
      seq: seq,
      epoch: record.epoch,
    );
    onUpdate?.call(update);
    return update;
  }
}
