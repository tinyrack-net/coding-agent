/// Provider-owned child agent descriptors and independently paged timelines.
library;

import '../timeline/timeline_item.dart';

enum ProviderSubagentStatus { running, completed, failed, canceled }

enum ProviderSubagentTimelineDirection { tail, before, after }

final class ProviderSubagentTimelineCursor {
  const ProviderSubagentTimelineCursor({
    required this.epoch,
    required this.seq,
  });

  final String epoch;
  final int seq;

  static ProviderSubagentTimelineCursor fromJson(Map<String, Object?> json) {
    final epoch = json['epoch'];
    final seq = json['seq'];
    if (epoch is! String || epoch.isEmpty) {
      throw const FormatException('cursor epoch must be a non-empty string');
    }
    if (seq is! num || seq < 0 || seq.toInt() != seq) {
      throw const FormatException('cursor seq must be a non-negative integer');
    }
    return ProviderSubagentTimelineCursor(epoch: epoch, seq: seq.toInt());
  }

  Map<String, Object?> toJson() => {'epoch': epoch, 'seq': seq};
}

final class ProviderSubagentTimelineWindow {
  const ProviderSubagentTimelineWindow({
    required this.minSeq,
    required this.maxSeq,
    required this.nextSeq,
  });

  final int minSeq;
  final int maxSeq;
  final int nextSeq;

  static ProviderSubagentTimelineWindow fromJson(Map<String, Object?> json) =>
      ProviderSubagentTimelineWindow(
        minSeq: (json['minSeq'] as num).toInt(),
        maxSeq: (json['maxSeq'] as num).toInt(),
        nextSeq: (json['nextSeq'] as num).toInt(),
      );

  Map<String, Object?> toJson() => {
    'minSeq': minSeq,
    'maxSeq': maxSeq,
    'nextSeq': nextSeq,
  };
}

final class ProviderSubagentDescriptor {
  const ProviderSubagentDescriptor({
    required this.id,
    required this.parentAgentId,
    required this.provider,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.description,
    this.toolCallId,
    this.cwd,
  });

  final String id;
  final String parentAgentId;
  final String provider;
  final String? title;
  final String? description;
  final ProviderSubagentStatus status;
  final String createdAt;
  final String updatedAt;
  final String? toolCallId;
  final String? cwd;

  static ProviderSubagentDescriptor fromJson(Map<String, Object?> json) =>
      ProviderSubagentDescriptor(
        id: json['id'] as String,
        parentAgentId: json['parentAgentId'] as String,
        provider: json['provider'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        status: ProviderSubagentStatus.values.byName(json['status'] as String),
        createdAt: json['createdAt'] as String,
        updatedAt: json['updatedAt'] as String,
        toolCallId: json['toolCallId'] as String?,
        cwd: json['cwd'] as String?,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'parentAgentId': parentAgentId,
    'provider': provider,
    'title': title,
    'description': description,
    'status': status.name,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'toolCallId': toolCallId,
    if (cwd != null) 'cwd': cwd,
  };
}

final class ProviderSubagentTimelineRow {
  const ProviderSubagentTimelineRow({
    required this.item,
    required this.timestamp,
    required this.seq,
  });

  final TimelineItem item;
  final String timestamp;
  final int seq;

  static ProviderSubagentTimelineRow fromJson(Map<String, Object?> json) =>
      ProviderSubagentTimelineRow(
        item: TimelineItem.fromJson(
          (json['item'] as Map).cast<String, Object?>(),
        ),
        timestamp: json['timestamp'] as String,
        seq: (json['seq'] as num).toInt(),
      );

  Map<String, Object?> toJson() => {
    'item': item.toJson(),
    'timestamp': timestamp,
    'seq': seq,
  };
}

/// Paseo-compatible response payload for
/// `agent.provider_subagents.timeline.get.request`.
final class ProviderSubagentTimelineResponse {
  const ProviderSubagentTimelineResponse({
    required this.parentAgentId,
    required this.subagentId,
    required this.provider,
    required this.direction,
    required this.epoch,
    required this.reset,
    required this.staleCursor,
    required this.gap,
    required this.window,
    required this.hasOlder,
    required this.hasNewer,
    required this.rows,
    this.error,
  });

  final String parentAgentId;
  final String subagentId;
  final String? provider;
  final ProviderSubagentTimelineDirection direction;
  final String epoch;
  final bool reset;
  final bool staleCursor;
  final bool gap;
  final ProviderSubagentTimelineWindow window;
  final bool hasOlder;
  final bool hasNewer;
  final List<ProviderSubagentTimelineRow> rows;
  final String? error;

  static ProviderSubagentTimelineResponse fromJson(Map<String, Object?> json) =>
      ProviderSubagentTimelineResponse(
        parentAgentId: json['parentAgentId'] as String,
        subagentId: json['subagentId'] as String,
        provider: json['provider'] as String?,
        direction: ProviderSubagentTimelineDirection.values.byName(
          json['direction'] as String,
        ),
        epoch: json['epoch'] as String,
        reset: json['reset'] as bool,
        staleCursor: json['staleCursor'] as bool,
        gap: json['gap'] as bool,
        window: ProviderSubagentTimelineWindow.fromJson(
          (json['window'] as Map).cast<String, Object?>(),
        ),
        hasOlder: json['hasOlder'] as bool,
        hasNewer: json['hasNewer'] as bool,
        rows: [
          for (final row in json['rows'] as List)
            ProviderSubagentTimelineRow.fromJson(
              (row as Map).cast<String, Object?>(),
            ),
        ],
        error: json['error'] as String?,
      );

  Map<String, Object?> toJson() => {
    'parentAgentId': parentAgentId,
    'subagentId': subagentId,
    'provider': provider,
    'direction': direction.name,
    'epoch': epoch,
    'reset': reset,
    'staleCursor': staleCursor,
    'gap': gap,
    'window': window.toJson(),
    'hasOlder': hasOlder,
    'hasNewer': hasNewer,
    'rows': rows.map((row) => row.toJson()).toList(),
    'error': error,
  };
}

sealed class ProviderSubagentUpdate {
  const ProviderSubagentUpdate();

  String get kind;
  Map<String, Object?> toJson();

  static ProviderSubagentUpdate fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'upsert' => ProviderSubagentUpsert(
          subagent: ProviderSubagentDescriptor.fromJson(
            (json['subagent'] as Map).cast<String, Object?>(),
          ),
        ),
        'timeline' => ProviderSubagentTimelineUpdate(
          parentAgentId: json['parentAgentId'] as String,
          subagentId: json['subagentId'] as String,
          provider: json['provider'] as String,
          item: TimelineItem.fromJson(
            (json['item'] as Map).cast<String, Object?>(),
          ),
          timestamp: json['timestamp'] as String,
          seq: (json['seq'] as num).toInt(),
          epoch: json['epoch'] as String,
        ),
        'remove' => ProviderSubagentRemove(
          parentAgentId: json['parentAgentId'] as String,
          subagentId: json['subagentId'] as String,
        ),
        _ => throw FormatException(
          'unknown provider subagent update kind: ${json['kind']}',
        ),
      };
}

final class ProviderSubagentUpsert extends ProviderSubagentUpdate {
  const ProviderSubagentUpsert({required this.subagent});
  final ProviderSubagentDescriptor subagent;
  @override
  String get kind => 'upsert';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'subagent': subagent.toJson(),
  };
}

final class ProviderSubagentTimelineUpdate extends ProviderSubagentUpdate {
  const ProviderSubagentTimelineUpdate({
    required this.parentAgentId,
    required this.subagentId,
    required this.provider,
    required this.item,
    required this.timestamp,
    required this.seq,
    required this.epoch,
  });
  final String parentAgentId;
  final String subagentId;
  final String provider;
  final TimelineItem item;
  final String timestamp;
  final int seq;
  final String epoch;
  @override
  String get kind => 'timeline';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'parentAgentId': parentAgentId,
    'subagentId': subagentId,
    'provider': provider,
    'item': item.toJson(),
    'timestamp': timestamp,
    'seq': seq,
    'epoch': epoch,
  };
}

final class ProviderSubagentRemove extends ProviderSubagentUpdate {
  const ProviderSubagentRemove({
    required this.parentAgentId,
    required this.subagentId,
  });
  final String parentAgentId;
  final String subagentId;
  @override
  String get kind => 'remove';
  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'parentAgentId': parentAgentId,
    'subagentId': subagentId,
  };
}
