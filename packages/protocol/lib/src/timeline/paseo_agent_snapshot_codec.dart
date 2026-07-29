/// Frozen Paseo 0.2.0 `AgentSnapshotPayload` projection.
library;

import '../messages/agent.dart';
import 'timeline_item.dart';

const Object _absentSnapshotField = Object();

abstract final class PaseoAgentSnapshotCodec {
  static AgentSummary decode(Map<String, Object?> json) {
    final id = _requiredString(json, 'id');
    final provider = _requiredString(json, 'provider');
    final cwd = _requiredString(json, 'cwd');
    final createdAt = _requiredDateTime(json, 'createdAt');
    final status = _requiredString(json, 'status');
    final pendingPermissions = json['pendingPermissions'];
    if (pendingPermissions is! List) {
      throw const FormatException('pendingPermissions must be an array');
    }
    final runState = switch (status) {
      'initializing' => AgentRunState.initializing,
      'idle' => AgentRunState.idle,
      'running' =>
        pendingPermissions.isEmpty
            ? AgentRunState.running
            : AgentRunState.awaitingPermission,
      'error' => AgentRunState.error,
      'closed' => AgentRunState.closed,
      _ => throw FormatException('Unknown agent status: $status'),
    };
    final currentModeId = _nullableString(json, 'currentModeId');
    final mode = switch (currentModeId) {
      'plan' => AgentMode.plan,
      'full-access' => AgentMode.fullAccess,
      _ => AgentMode.normal,
    };
    final persistence = _nullableMap(json, 'persistence');
    final runtimeInfo = _nullableMap(json, 'runtimeInfo');
    final labels = json['labels'];
    if (labels is! Map) {
      throw const FormatException('labels must be an object');
    }
    final parsedLabels = <String, String>{};
    for (final entry in labels.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('labels must contain string values');
      }
      parsedLabels[entry.key as String] = entry.value as String;
    }
    return AgentSummary(
      agentId: id,
      title: _nullableString(json, 'title') ?? '',
      cwd: cwd,
      provider: provider,
      providerUnavailable: _optionalBool(json, 'providerUnavailable'),
      model:
          _nullableString(json, 'model') ??
          _nullableString(runtimeInfo ?? const {}, 'model') ??
          '',
      mode: mode,
      runState: runState,
      createdAtMs: createdAt.millisecondsSinceEpoch,
      updatedAt: _nullableString(json, 'updatedAt'),
      sessionId:
          _nullableString(persistence ?? const {}, 'sessionId') ??
          _nullableString(runtimeInfo ?? const {}, 'sessionId'),
      workspaceId: _nullableString(json, 'workspaceId'),
      lastUsage: json['lastUsage'] is Map
          ? AgentUsage.fromJson(
              Map<String, Object?>.from(json['lastUsage'] as Map),
            )
          : null,
      parentAgentId: _managedParentAgentId(json),
      requiresAttention: _optionalBool(json, 'requiresAttention'),
      attentionReason: _attentionReason(json['attentionReason']),
      attentionTimestamp: _nullableString(json, 'attentionTimestamp'),
      archivedAt: _nullableString(json, 'archivedAt'),
      thinkingOptionId:
          _nullableString(json, 'thinkingOptionId') ??
          _nullableString(runtimeInfo ?? const {}, 'thinkingOptionId'),
      currentModeId: currentModeId,
      featureValues: _featureValues(json['features']),
      lastUserMessageAt: _nullableString(json, 'lastUserMessageAt'),
      lastError: _nullableString(json, 'lastError'),
      labels: parsedLabels,
    );
  }

  static Map<String, Object?> encode(
    AgentSummary agent, {
    Iterable<PermissionItem> pendingPermissions = const [],
    Map<String, bool>? capabilities,
    Iterable<Map<String, Object?>>? availableModes,
    Iterable<Map<String, Object?>> features = const [],
    Object? currentModeId = _absentSnapshotField,
    bool providerUnavailable = false,
  }) {
    final latestPermissions = <String, PermissionItem>{
      for (final permission in pendingPermissions)
        permission.permissionId: permission,
    };
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      agent.createdAtMs,
      isUtc: true,
    ).toIso8601String();
    final legacyModeId = switch (agent.mode) {
      AgentMode.plan => 'plan',
      AgentMode.normal => 'normal',
      AgentMode.fullAccess => 'full-access',
    };
    final effectiveModeId = identical(currentModeId, _absentSnapshotField)
        ? (agent.currentModeId ?? legacyModeId)
        : currentModeId as String?;
    final effectiveCapabilities =
        capabilities ??
        const {
          'supportsStreaming': false,
          'supportsSessionPersistence': true,
          'supportsSessionListing': false,
          'supportsDynamicModes': false,
          'supportsMcpServers': false,
          'supportsReasoningStream': false,
          'supportsToolInvocations': true,
          'supportsRewindConversation': false,
          'supportsRewindFiles': false,
          'supportsRewindBoth': false,
        };
    final effectiveModes =
        availableModes ??
        const [
          {'id': 'plan', 'label': 'Plan'},
          {'id': 'normal', 'label': 'Normal'},
          {'id': 'full-access', 'label': 'Full access'},
        ];
    final status = agent.archivedAt != null
        ? 'closed'
        : switch (agent.runState) {
            AgentRunState.initializing => 'initializing',
            AgentRunState.idle => 'idle',
            AgentRunState.running ||
            AgentRunState.awaitingPermission => 'running',
            AgentRunState.error => 'error',
            AgentRunState.closed => 'closed',
          };
    return {
      'id': agent.agentId,
      'provider': agent.provider,
      'cwd': agent.cwd,
      if (agent.workspaceId != null) 'workspaceId': agent.workspaceId,
      'model': agent.model.isEmpty ? null : agent.model,
      'thinkingOptionId': agent.thinkingOptionId,
      'effectiveThinkingOptionId': agent.thinkingOptionId,
      'createdAt': createdAt,
      'updatedAt': agent.updatedAt ?? createdAt,
      'lastUserMessageAt': agent.lastUserMessageAt,
      'status': status,
      'capabilities': effectiveCapabilities,
      'currentModeId': effectiveModeId,
      'availableModes': effectiveModes.toList(growable: false),
      if (features.isNotEmpty) 'features': features.toList(growable: false),
      'pendingPermissions': encodePendingPermissions(
        agent,
        latestPermissions.values,
      ),
      'persistence': agent.sessionId == null
          ? null
          : {'provider': agent.provider, 'sessionId': agent.sessionId},
      'runtimeInfo': {
        'provider': agent.provider,
        'sessionId': agent.sessionId,
        'model': agent.model.isEmpty ? null : agent.model,
        'thinkingOptionId': agent.thinkingOptionId,
        'modeId': effectiveModeId,
      },
      if (agent.lastUsage != null) 'lastUsage': agent.lastUsage!.toJson(),
      if (agent.lastError != null) 'lastError': agent.lastError,
      'title': agent.title.trim().isEmpty ? null : agent.title,
      'labels': agent.labels,
      'requiresAttention': agent.requiresAttention,
      'attentionReason': agent.attentionReason?.name,
      'attentionTimestamp': agent.attentionTimestamp,
      'archivedAt': agent.archivedAt,
      'providerUnavailable': providerUnavailable || agent.providerUnavailable,
    };
  }

  static List<Map<String, Object?>> encodePendingPermissions(
    AgentSummary agent,
    Iterable<PermissionItem> permissions,
  ) {
    final latest = <String, PermissionItem>{
      for (final permission in permissions) permission.permissionId: permission,
    };
    return [
      for (final permission in latest.values)
        if (permission.status == PermissionStatus.pending)
          {
            'id': permission.permissionId,
            'provider': agent.provider,
            'name': permission.toolName,
            'kind': 'tool',
            'detail': permission.detail.toPaseoJson(),
          },
    ];
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$key must be a string or null');
}

Map<String, Object?>? _nullableMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$key must be an object or null');
}

DateTime _requiredDateTime(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key must be an ISO timestamp');
  return parsed;
}

bool _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return false;
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

AgentAttentionReason? _attentionReason(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('attentionReason must be a string or null');
  }
  try {
    return AgentAttentionReason.values.byName(value);
  } on ArgumentError {
    throw FormatException('Unknown attention reason: $value');
  }
}

String? _managedParentAgentId(Map<String, Object?> json) {
  final direct = _nullableString(json, 'parentAgentId');
  if (direct != null) return direct;
  final managedBy = _nullableMap(json, 'managedBy');
  if (managedBy == null) return null;
  return _nullableString(managedBy, 'parentAgentId') ??
      _nullableString(managedBy, 'agentId');
}

Map<String, Object?> _featureValues(Object? value) {
  if (value == null) return const {};
  if (value is! List) {
    throw const FormatException('features must be an array');
  }
  final result = <String, Object?>{};
  for (final raw in value) {
    if (raw is! Map) throw const FormatException('feature must be an object');
    final feature = Map<String, Object?>.from(raw);
    final id = _requiredString(feature, 'id');
    if (feature.containsKey('value')) result[id] = feature['value'];
  }
  return Map.unmodifiable(result);
}
