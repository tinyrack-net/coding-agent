/// Agent lifecycle messages and stream payloads.
library;

import '../timeline/timeline_item.dart';

enum AgentRunState { initializing, idle, running, awaitingPermission, error }

enum AgentMode { plan, normal, fullAccess }

final class AgentSummary {
  const AgentSummary({
    required this.agentId,
    required this.title,
    required this.cwd,
    required this.provider,
    required this.model,
    required this.mode,
    required this.runState,
    required this.createdAtMs,
    this.sessionId,
  });

  final String agentId;
  final String title;
  final String cwd;
  final String provider;
  final String model;
  final AgentMode mode;
  final AgentRunState runState;
  final int createdAtMs;

  /// Provider-native session id, once known (used for resume).
  final String? sessionId;

  AgentSummary copyWith({
    String? title,
    AgentMode? mode,
    AgentRunState? runState,
    String? sessionId,
  }) =>
      AgentSummary(
        agentId: agentId,
        title: title ?? this.title,
        cwd: cwd,
        provider: provider,
        model: model,
        mode: mode ?? this.mode,
        runState: runState ?? this.runState,
        createdAtMs: createdAtMs,
        sessionId: sessionId ?? this.sessionId,
      );

  static AgentSummary fromJson(Map<String, Object?> json) => AgentSummary(
        agentId: json['agentId'] as String,
        title: (json['title'] as String?) ?? '',
        cwd: (json['cwd'] as String?) ?? '',
        provider: (json['provider'] as String?) ?? 'claude',
        model: (json['model'] as String?) ?? '',
        mode: AgentMode.values.byName((json['mode'] as String?) ?? 'normal'),
        runState: AgentRunState.values
            .byName((json['runState'] as String?) ?? 'idle'),
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
        sessionId: json['sessionId'] as String?,
      );

  Map<String, Object?> toJson() => {
        'agentId': agentId,
        'title': title,
        'cwd': cwd,
        'provider': provider,
        'model': model,
        'mode': mode.name,
        'runState': runState.name,
        'createdAtMs': createdAtMs,
        if (sessionId != null) 'sessionId': sessionId,
      };
}

/// Payload of the `agent.stream` broadcast event.
final class AgentStreamPayload {
  const AgentStreamPayload({
    required this.agentId,
    required this.epoch,
    required this.seq,
    required this.item,
  });

  final String agentId;

  /// Bumped when the timeline is rebuilt (e.g. resume); stale-epoch clients
  /// must refetch.
  final int epoch;

  /// Monotonic within an epoch. An item re-sent with a higher seq replaces the
  /// previous version with the same item id.
  final int seq;

  final TimelineItem item;

  static AgentStreamPayload fromJson(Map<String, Object?> json) =>
      AgentStreamPayload(
        agentId: json['agentId'] as String,
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        item: TimelineItem.fromJson(json['item'] as Map<String, Object?>),
      );

  Map<String, Object?> toJson() => {
        'agentId': agentId,
        'epoch': epoch,
        'seq': seq,
        'item': item.toJson(),
      };
}

/// Payload of the `agent.state` broadcast event.
final class AgentStatePayload {
  const AgentStatePayload({required this.agent});

  final AgentSummary agent;

  static AgentStatePayload fromJson(Map<String, Object?> json) =>
      AgentStatePayload(
        agent: AgentSummary.fromJson(json['agent'] as Map<String, Object?>),
      );

  Map<String, Object?> toJson() => {'agent': agent.toJson()};
}

/// Response of `agent.timeline.fetch.request`
/// (request payload: `{agentId, epoch?, afterSeq?}`).
final class TimelineFetchResponse {
  const TimelineFetchResponse({
    required this.epoch,
    required this.lastSeq,
    required this.items,
  });

  final int epoch;
  final int lastSeq;
  final List<TimelineItem> items;

  static TimelineFetchResponse fromJson(Map<String, Object?> json) =>
      TimelineFetchResponse(
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
        lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
        items: ((json['items'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(TimelineItem.fromJson)
            .toList(),
      );

  Map<String, Object?> toJson() => {
        'epoch': epoch,
        'lastSeq': lastSeq,
        'items': items.map((i) => i.toJson()).toList(),
      };
}

/// Response of `agent.conversation.clear.request`. [cleared] is the number
/// of agents whose timeline + session was wiped (0 if no agent matched).
final class AgentConversationClearResponse {
  const AgentConversationClearResponse({required this.cleared});

  final int cleared;

  static AgentConversationClearResponse fromJson(Map<String, Object?> json) =>
      AgentConversationClearResponse(
        cleared: (json['cleared'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {'cleared': cleared};
}
