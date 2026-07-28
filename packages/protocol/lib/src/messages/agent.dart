/// Agent lifecycle messages and stream payloads.
library;

import '../timeline/timeline_item.dart';

const Object _absentAgentField = Object();

enum AgentRunState {
  initializing,
  idle,
  running,
  awaitingPermission,
  error,
  closed,
}

enum AgentMode { plan, normal, fullAccess }

enum AgentAttentionReason { finished, error, permission }

final class AgentUsage {
  const AgentUsage({
    this.inputTokens,
    this.cachedInputTokens,
    this.outputTokens,
    this.totalCostUsd,
    this.contextWindowMaxTokens,
    this.contextWindowUsedTokens,
  });

  final int? inputTokens;
  final int? cachedInputTokens;
  final int? outputTokens;
  final double? totalCostUsd;
  final int? contextWindowMaxTokens;
  final int? contextWindowUsedTokens;

  static AgentUsage fromJson(Map<String, Object?> json) => AgentUsage(
    inputTokens: (json['inputTokens'] as num?)?.toInt(),
    cachedInputTokens: (json['cachedInputTokens'] as num?)?.toInt(),
    outputTokens: (json['outputTokens'] as num?)?.toInt(),
    totalCostUsd: (json['totalCostUsd'] as num?)?.toDouble(),
    contextWindowMaxTokens: (json['contextWindowMaxTokens'] as num?)?.toInt(),
    contextWindowUsedTokens: (json['contextWindowUsedTokens'] as num?)?.toInt(),
  );

  Map<String, Object?> toJson() => {
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (cachedInputTokens != null) 'cachedInputTokens': cachedInputTokens,
    if (outputTokens != null) 'outputTokens': outputTokens,
    if (totalCostUsd != null) 'totalCostUsd': totalCostUsd,
    if (contextWindowMaxTokens != null)
      'contextWindowMaxTokens': contextWindowMaxTokens,
    if (contextWindowUsedTokens != null)
      'contextWindowUsedTokens': contextWindowUsedTokens,
  };
}

final class AgentSummary {
  const AgentSummary({
    required this.agentId,
    required this.title,
    required this.cwd,
    required this.provider,
    this.providerUnavailable = false,
    required this.model,
    required this.mode,
    required this.runState,
    required this.createdAtMs,
    this.updatedAt,
    this.sessionId,
    this.workspaceId,
    this.projectPath,
    this.branch,
    this.isWorktree = false,
    this.lastUsage,
    this.parentAgentId,
    this.requiresAttention = false,
    this.attentionReason,
    this.attentionTimestamp,
    this.archivedAt,
    this.thinkingOptionId,
    this.currentModeId,
    this.featureValues = const {},
    this.lastUserMessageAt,
    this.lastError,
    this.labels = const {},
  });

  final String agentId;
  final String title;
  final String cwd;
  final String provider;
  final bool providerUnavailable;
  final String model;
  final AgentMode mode;
  final AgentRunState runState;
  final int createdAtMs;
  final String? updatedAt;

  /// Provider-native session id, once known (used for resume).
  final String? sessionId;

  /// Stable Paseo workspace identity that owns this agent. Workspace status
  /// aggregation is identity-based and must not fall back to matching [cwd].
  final String? workspaceId;

  /// Main checkout path of the project this agent's `cwd` belongs to, if
  /// known. Set when the agent was created against a registered project.
  final String? projectPath;

  /// Branch checked out at [cwd], if known.
  final String? branch;

  /// True when [cwd] is an isolated git worktree (rather than the project's
  /// main checkout).
  final bool isWorktree;
  final AgentUsage? lastUsage;
  final String? parentAgentId;
  final bool requiresAttention;
  final AgentAttentionReason? attentionReason;
  final String? attentionTimestamp;
  final String? archivedAt;
  final String? thinkingOptionId;
  final String? currentModeId;
  final Map<String, Object?> featureValues;
  final String? lastUserMessageAt;
  final String? lastError;
  final Map<String, String> labels;

  AgentSummary copyWith({
    String? title,
    Object? workspaceId = _absentAgentField,
    Object? model = _absentAgentField,
    AgentMode? mode,
    AgentRunState? runState,
    String? updatedAt,
    String? sessionId,
    AgentUsage? lastUsage,
    String? parentAgentId,
    bool clearParentAgentId = false,
    bool? requiresAttention,
    AgentAttentionReason? attentionReason,
    String? attentionTimestamp,
    bool clearAttention = false,
    Object? archivedAt = _absentAgentField,
    Object? thinkingOptionId = _absentAgentField,
    Object? currentModeId = _absentAgentField,
    Map<String, Object?>? featureValues,
    Object? lastUserMessageAt = _absentAgentField,
    Object? lastError = _absentAgentField,
    Map<String, String>? labels,
    bool? providerUnavailable,
  }) => AgentSummary(
    agentId: agentId,
    title: title ?? this.title,
    cwd: cwd,
    provider: provider,
    providerUnavailable: providerUnavailable ?? this.providerUnavailable,
    model: identical(model, _absentAgentField)
        ? this.model
        : (model as String? ?? ''),
    mode: mode ?? this.mode,
    runState: runState ?? this.runState,
    createdAtMs: createdAtMs,
    updatedAt: updatedAt ?? this.updatedAt,
    sessionId: sessionId ?? this.sessionId,
    workspaceId: identical(workspaceId, _absentAgentField)
        ? this.workspaceId
        : workspaceId as String?,
    projectPath: projectPath,
    branch: branch,
    isWorktree: isWorktree,
    lastUsage: lastUsage ?? this.lastUsage,
    parentAgentId: clearParentAgentId
        ? null
        : (parentAgentId ?? this.parentAgentId),
    requiresAttention: requiresAttention ?? this.requiresAttention,
    attentionReason: clearAttention
        ? null
        : (attentionReason ?? this.attentionReason),
    attentionTimestamp: clearAttention
        ? null
        : (attentionTimestamp ?? this.attentionTimestamp),
    archivedAt: identical(archivedAt, _absentAgentField)
        ? this.archivedAt
        : archivedAt as String?,
    thinkingOptionId: identical(thinkingOptionId, _absentAgentField)
        ? this.thinkingOptionId
        : thinkingOptionId as String?,
    currentModeId: identical(currentModeId, _absentAgentField)
        ? this.currentModeId
        : currentModeId as String?,
    featureValues: featureValues ?? this.featureValues,
    lastUserMessageAt: identical(lastUserMessageAt, _absentAgentField)
        ? this.lastUserMessageAt
        : lastUserMessageAt as String?,
    lastError: identical(lastError, _absentAgentField)
        ? this.lastError
        : lastError as String?,
    labels: labels ?? this.labels,
  );

  static AgentSummary fromJson(Map<String, Object?> json) => AgentSummary(
    agentId: json['agentId'] as String,
    title: (json['title'] as String?) ?? '',
    cwd: (json['cwd'] as String?) ?? '',
    provider: (json['provider'] as String?) ?? 'claude',
    providerUnavailable: (json['providerUnavailable'] as bool?) ?? false,
    model: (json['model'] as String?) ?? '',
    mode: AgentMode.values.byName((json['mode'] as String?) ?? 'normal'),
    runState: AgentRunState.values.byName(
      (json['runState'] as String?) ?? 'idle',
    ),
    createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
    updatedAt: json['updatedAt'] as String?,
    sessionId: json['sessionId'] as String?,
    workspaceId: json['workspaceId'] as String?,
    projectPath: json['projectPath'] as String?,
    branch: json['branch'] as String?,
    isWorktree: (json['isWorktree'] as bool?) ?? false,
    lastUsage: json['lastUsage'] is Map<String, Object?>
        ? AgentUsage.fromJson(json['lastUsage']! as Map<String, Object?>)
        : null,
    parentAgentId: json['parentAgentId'] as String?,
    requiresAttention: (json['requiresAttention'] as bool?) ?? false,
    attentionReason: json['attentionReason'] == null
        ? null
        : AgentAttentionReason.values.byName(json['attentionReason'] as String),
    attentionTimestamp: json['attentionTimestamp'] as String?,
    archivedAt: json['archivedAt'] as String?,
    thinkingOptionId: json['thinkingOptionId'] as String?,
    currentModeId: json['currentModeId'] as String?,
    featureValues: json['featureValues'] is Map<String, Object?>
        ? Map<String, Object?>.unmodifiable(
            json['featureValues']! as Map<String, Object?>,
          )
        : const {},
    lastUserMessageAt: json['lastUserMessageAt'] as String?,
    lastError: json['lastError'] as String?,
    labels: json['labels'] is Map
        ? Map<String, String>.unmodifiable(
            Map<String, String>.from(json['labels']! as Map),
          )
        : const {},
  );

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'title': title,
    'cwd': cwd,
    'provider': provider,
    if (providerUnavailable) 'providerUnavailable': true,
    'model': model,
    'mode': mode.name,
    'runState': runState.name,
    'createdAtMs': createdAtMs,
    if (updatedAt != null) 'updatedAt': updatedAt,
    if (sessionId != null) 'sessionId': sessionId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (projectPath != null) 'projectPath': projectPath,
    if (branch != null) 'branch': branch,
    if (isWorktree) 'isWorktree': isWorktree,
    if (lastUsage != null) 'lastUsage': lastUsage!.toJson(),
    if (parentAgentId != null) 'parentAgentId': parentAgentId,
    'requiresAttention': requiresAttention,
    'attentionReason': attentionReason?.name,
    'attentionTimestamp': attentionTimestamp,
    if (archivedAt != null) 'archivedAt': archivedAt,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
    if (currentModeId != null) 'currentModeId': currentModeId,
    if (featureValues.isNotEmpty) 'featureValues': featureValues,
    'lastUserMessageAt': lastUserMessageAt,
    if (lastError != null) 'lastError': lastError,
    'labels': labels,
  };
}

/// Payload of the `agent.stream` broadcast event.
final class AgentStreamPayload {
  const AgentStreamPayload({
    required this.agentId,
    required this.epoch,
    required this.seq,
    required this.item,
    this.provider = 'codex',
    this.timestamp,
  });

  final String agentId;

  /// Bumped when the timeline is rebuilt (e.g. resume); stale-epoch clients
  /// must refetch.
  final int epoch;

  /// Monotonic within an epoch. An item re-sent with a higher seq replaces the
  /// previous version with the same item id.
  final int seq;

  final TimelineItem item;
  final String provider;
  final String? timestamp;

  static AgentStreamPayload fromJson(Map<String, Object?> json) =>
      AgentStreamPayload(
        agentId: json['agentId'] as String,
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        item: TimelineItem.fromJson(json['item'] as Map<String, Object?>),
        provider: (json['provider'] as String?) ?? 'codex',
        timestamp: json['timestamp'] as String?,
      );

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'epoch': epoch,
    'seq': seq,
    'item': item.toJson(),
    if (provider != 'codex') 'provider': provider,
    if (timestamp != null) 'timestamp': timestamp,
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
