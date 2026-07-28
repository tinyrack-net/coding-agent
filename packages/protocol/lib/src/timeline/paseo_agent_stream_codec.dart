/// Frozen Paseo 0.2.0 `agent_stream` message codec.
library;

import '../messages/agent.dart';
import 'paseo_timeline_codec.dart';
import 'timeline_item.dart';
import 'tool_call_detail.dart';

abstract final class PaseoAgentStreamCodec {
  static Map<String, Object?> encode(
    AgentStreamPayload stream, {
    String? timestamp,
  }) {
    final event = _event(stream.item, stream.provider);
    return {
      'type': 'agent_stream',
      'payload': {
        'agentId': stream.agentId,
        'event': event,
        'timestamp':
            timestamp ??
            stream.timestamp ??
            DateTime.now().toUtc().toIso8601String(),
        'seq': stream.seq,
        'epoch': stream.epoch.toString(),
      },
    };
  }

  static Map<String, Object?> _event(TimelineItem item, String provider) {
    return switch (item) {
      TurnItem(:final phase, :final errorMessage) => switch (phase) {
        TurnPhase.started => {'type': 'turn_started', 'provider': provider},
        TurnPhase.completed => {'type': 'turn_completed', 'provider': provider},
        TurnPhase.failed => {
          'type': 'turn_failed',
          'provider': provider,
          'error': errorMessage ?? 'Agent turn failed',
        },
        TurnPhase.canceled => {
          'type': 'turn_canceled',
          'provider': provider,
          'reason': errorMessage ?? 'canceled',
        },
      },
      PermissionItem(
        :final permissionId,
        :final toolName,
        :final status,
        :final detail,
      ) =>
        switch (status) {
          PermissionStatus.pending => {
            'type': 'permission_requested',
            'provider': provider,
            'request': {
              'id': permissionId,
              'provider': provider,
              'name': toolName,
              'kind': 'tool',
              'detail': detail.toPaseoJson(),
            },
          },
          PermissionStatus.allowed => {
            'type': 'permission_resolved',
            'provider': provider,
            'requestId': permissionId,
            'resolution': {'behavior': 'allow'},
          },
          PermissionStatus.denied => {
            'type': 'permission_resolved',
            'provider': provider,
            'requestId': permissionId,
            'resolution': {'behavior': 'deny'},
          },
        },
      _ => {
        'type': 'timeline',
        'provider': provider,
        'item': PaseoTimelineCodec.encode(item),
      },
    };
  }

  /// Decodes the frozen native `agent_stream` envelope into the app's
  /// provider-neutral stream payload.
  static AgentStreamPayload decode(Map<String, Object?> message) {
    if (message['type'] != 'agent_stream') {
      throw const FormatException('Expected agent_stream');
    }
    final payload = _requiredMap(message, 'payload');
    final agentId = _requiredString(payload, 'agentId');
    final seq = _requiredInt(payload, 'seq');
    final epoch = _requiredEpoch(payload['epoch']);
    final timestamp = _requiredString(payload, 'timestamp');
    final event = _requiredMap(payload, 'event');
    final provider = _requiredString(event, 'provider');
    final eventType = _requiredString(event, 'type');
    final fallbackId = 'stream:$epoch:$seq';
    final item = switch (eventType) {
      'timeline' => PaseoTimelineCodec.decode(
        _requiredMap(event, 'item'),
        fallbackId: fallbackId,
      ),
      'turn_started' => TurnItem(id: 'turn:$agentId', phase: TurnPhase.started),
      'turn_completed' => TurnItem(
        id: 'turn:$agentId',
        phase: TurnPhase.completed,
      ),
      'turn_failed' => TurnItem(
        id: 'turn:$agentId',
        phase: TurnPhase.failed,
        errorMessage: _requiredString(event, 'error'),
      ),
      'turn_canceled' => TurnItem(
        id: 'turn:$agentId',
        phase: TurnPhase.canceled,
        errorMessage: _requiredString(event, 'reason'),
      ),
      'permission_requested' => _decodePermissionRequest(event),
      'permission_resolved' => _decodePermissionResolution(event),
      _ => throw FormatException('Unknown agent stream event: $eventType'),
    };
    return AgentStreamPayload(
      agentId: agentId,
      epoch: epoch,
      seq: seq,
      item: item,
      provider: provider,
      timestamp: timestamp,
    );
  }

  static PermissionItem _decodePermissionRequest(Map<String, Object?> event) {
    final request = _requiredMap(event, 'request');
    final id = _requiredString(request, 'id');
    final detail = _requiredMap(request, 'detail');
    return PermissionItem(
      id: 'perm_$id',
      permissionId: id,
      toolName: _requiredString(request, 'name'),
      status: PermissionStatus.pending,
      detail: ToolCallDetail.fromPaseoJson(detail),
    );
  }

  static PermissionItem _decodePermissionResolution(
    Map<String, Object?> event,
  ) {
    final id = _requiredString(event, 'requestId');
    final behavior = _requiredString(
      _requiredMap(event, 'resolution'),
      'behavior',
    );
    final status = switch (behavior) {
      'allow' => PermissionStatus.allowed,
      'deny' => PermissionStatus.denied,
      _ => throw FormatException(
        'Unknown permission resolution behavior: $behavior',
      ),
    };
    return PermissionItem(
      id: 'perm_$id',
      permissionId: id,
      toolName: '',
      status: status,
      detail: const GenericDetail(input: {}),
    );
  }
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('$key must be an object');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num && value == value.toInt()) return value.toInt();
  throw FormatException('$key must be an integer');
}

int _requiredEpoch(Object? value) {
  if (value is int) return value;
  if (value is num && value == value.toInt()) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const FormatException('epoch must be an integer string');
}
