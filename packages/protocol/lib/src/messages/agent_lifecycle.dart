/// Frozen Paseo 0.2.0 lifecycle and resume messages.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent.dart';

final class AgentPersistenceHandle {
  const AgentPersistenceHandle({
    required this.provider,
    required this.sessionId,
    this.nativeHandle,
    this.metadata,
  });

  final String provider;
  final String sessionId;
  final String? nativeHandle;
  final Map<String, Object?>? metadata;

  factory AgentPersistenceHandle.fromJson(Map<String, Object?> json) {
    return AgentPersistenceHandle(
      provider: _requiredString(json, 'provider'),
      sessionId: _requiredString(json, 'sessionId'),
      nativeHandle: _optionalString(json, 'nativeHandle'),
      metadata: _optionalMap(json, 'metadata'),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'sessionId': sessionId,
    if (nativeHandle != null) 'nativeHandle': nativeHandle,
    if (metadata != null) 'metadata': metadata,
  };
}

/// Partial session settings accepted by `resume_agent_request.overrides`.
///
/// [hasTitle] preserves the distinction between an omitted title and an
/// explicit `null`, which is significant to the Paseo schema.
final class AgentSessionConfigOverrides {
  const AgentSessionConfigOverrides({
    this.provider,
    this.cwd,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.featureValues,
    this.title,
    this.hasTitle = false,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.webSearch,
    this.extra,
    this.systemPrompt,
    this.mcpServers,
  });

  final String? provider;
  final String? cwd;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final Map<String, Object?>? featureValues;
  final String? title;
  final bool hasTitle;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final bool? webSearch;
  final Map<String, Object?>? extra;
  final String? systemPrompt;
  final Map<String, Object?>? mcpServers;

  factory AgentSessionConfigOverrides.fromJson(Map<String, Object?> json) =>
      AgentSessionConfigOverrides(
        provider: _optionalString(json, 'provider'),
        cwd: _optionalString(json, 'cwd'),
        modeId: _optionalString(json, 'modeId'),
        model: _optionalString(json, 'model'),
        thinkingOptionId: _optionalString(json, 'thinkingOptionId'),
        featureValues: _optionalMap(json, 'featureValues'),
        title: _optionalString(json, 'title'),
        hasTitle: json.containsKey('title'),
        approvalPolicy: _optionalString(json, 'approvalPolicy'),
        sandboxMode: _optionalString(json, 'sandboxMode'),
        networkAccess: _optionalBool(json, 'networkAccess'),
        webSearch: _optionalBool(json, 'webSearch'),
        extra: _optionalMap(json, 'extra'),
        systemPrompt: _optionalString(json, 'systemPrompt'),
        mcpServers: _optionalMap(json, 'mcpServers'),
      );

  Map<String, Object?> toJson() => {
    if (provider != null) 'provider': provider,
    if (cwd != null) 'cwd': cwd,
    if (modeId != null) 'modeId': modeId,
    if (model != null) 'model': model,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
    if (featureValues != null) 'featureValues': featureValues,
    if (hasTitle) 'title': title,
    if (approvalPolicy != null) 'approvalPolicy': approvalPolicy,
    if (sandboxMode != null) 'sandboxMode': sandboxMode,
    if (networkAccess != null) 'networkAccess': networkAccess,
    if (webSearch != null) 'webSearch': webSearch,
    if (extra != null) 'extra': extra,
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    if (mcpServers != null) 'mcpServers': mcpServers,
  };
}

final class ResumeAgentRequest {
  const ResumeAgentRequest({
    required this.handle,
    required this.requestId,
    this.overrides,
  });

  static const type = 'resume_agent_request';

  /// Null is valid for the legacy request shape; the daemon then resolves the
  /// persisted handle from the caller's agent record.
  final AgentPersistenceHandle? handle;
  final AgentSessionConfigOverrides? overrides;
  final String requestId;

  factory ResumeAgentRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final rawHandle = json['handle'];
    if (rawHandle != null && rawHandle is! Map) {
      throw const FormatException('handle must be an object or null');
    }
    final rawOverrides = json['overrides'];
    if (rawOverrides != null && rawOverrides is! Map) {
      throw const FormatException('overrides must be an object');
    }
    return ResumeAgentRequest(
      handle: rawHandle == null
          ? null
          : AgentPersistenceHandle.fromJson(
              Map<String, Object?>.from(rawHandle as Map),
            ),
      overrides: rawOverrides == null
          ? null
          : AgentSessionConfigOverrides.fromJson(
              Map<String, Object?>.from(rawOverrides as Map),
            ),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'handle': handle?.toJson(),
    if (overrides != null) 'overrides': overrides!.toJson(),
    'requestId': requestId,
  };
}

/// A successful response to [ResumeAgentRequest] is sent on Paseo's generic
/// `status` channel rather than a request-specific response envelope.
final class AgentResumedStatus {
  const AgentResumedStatus({
    required this.agentId,
    required this.agent,
    required this.requestId,
    this.timelineSize,
  });

  static const type = 'status';
  static const status = 'agent_resumed';

  final String agentId;
  final AgentSummary agent;
  final String requestId;
  final num? timelineSize;

  factory AgentResumedStatus.fromJson(Map<String, Object?> json) {
    final payload = _statusPayload(json, status);
    final rawTimelineSize = payload['timelineSize'];
    if (rawTimelineSize != null && rawTimelineSize is! num) {
      throw const FormatException('timelineSize must be a number');
    }
    final rawAgent = payload['agent'];
    if (rawAgent is! Map) {
      throw const FormatException('agent must be an object');
    }
    return AgentResumedStatus(
      agentId: _requiredString(payload, 'agentId'),
      agent: PaseoAgentSnapshotCodec.decode(
        Map<String, Object?>.from(rawAgent),
      ),
      requestId: _requiredString(payload, 'requestId'),
      timelineSize: rawTimelineSize as num?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'status': status,
      'agentId': agentId,
      'agent': PaseoAgentSnapshotCodec.encode(agent),
      'requestId': requestId,
      if (timelineSize != null) 'timelineSize': timelineSize,
    },
  };
}

final class RestartServerRequest {
  const RestartServerRequest({required this.requestId, this.reason});

  static const type = 'restart_server_request';
  final String? reason;
  final String requestId;

  factory RestartServerRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return RestartServerRequest(
      reason: _optionalString(json, 'reason'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    if (reason != null) 'reason': reason,
    'requestId': requestId,
  };
}

final class ShutdownServerRequest {
  const ShutdownServerRequest({required this.requestId});

  static const type = 'shutdown_server_request';
  final String requestId;

  factory ShutdownServerRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ShutdownServerRequest(requestId: _requiredString(json, 'requestId'));
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class RestartRequestedStatus {
  const RestartRequestedStatus({
    required this.clientId,
    required this.requestId,
    this.reason,
  });

  static const type = 'status';
  static const status = 'restart_requested';
  final String clientId;
  final String? reason;
  final String requestId;

  factory RestartRequestedStatus.fromJson(Map<String, Object?> json) {
    final payload = _statusPayload(json, status);
    return RestartRequestedStatus(
      clientId: _requiredString(payload, 'clientId'),
      reason: _optionalString(payload, 'reason'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'status': status,
      'clientId': clientId,
      if (reason != null) 'reason': reason,
      'requestId': requestId,
    },
  };
}

final class ShutdownRequestedStatus {
  const ShutdownRequestedStatus({
    required this.clientId,
    required this.requestId,
  });

  static const type = 'status';
  static const status = 'shutdown_requested';
  final String clientId;
  final String requestId;

  factory ShutdownRequestedStatus.fromJson(Map<String, Object?> json) {
    final payload = _statusPayload(json, status);
    return ShutdownRequestedStatus(
      clientId: _requiredString(payload, 'clientId'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'status': status, 'clientId': clientId, 'requestId': requestId},
  };
}

Map<String, Object?> _statusPayload(
  Map<String, Object?> json,
  String expectedStatus,
) {
  if (json['type'] != 'status') throw const FormatException('Expected status');
  final raw = json['payload'];
  if (raw is! Map)
    throw const FormatException('status payload must be an object');
  final payload = Map<String, Object?>.from(raw);
  if (payload['status'] != expectedStatus) {
    throw FormatException('Expected $expectedStatus status');
  }
  return payload;
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) throw FormatException('Expected $expected');
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}
