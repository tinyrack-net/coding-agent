/// Frozen Paseo 0.2.0 agent prompt and wait-for-finish contracts.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent_attachment.dart';

enum AgentPermissionBehavior { allow, deny }

/// Frozen Paseo 0.2.0 permission response discriminated union.
final class AgentPermissionResponse {
  const AgentPermissionResponse.allow({
    this.selectedActionId,
    this.updatedInput,
    this.updatedPermissions,
  }) : behavior = AgentPermissionBehavior.allow,
       message = null,
       interrupt = null;

  const AgentPermissionResponse.deny({
    this.selectedActionId,
    this.message,
    this.interrupt,
  }) : behavior = AgentPermissionBehavior.deny,
       updatedInput = null,
       updatedPermissions = null;

  final AgentPermissionBehavior behavior;
  final String? selectedActionId;
  final Map<String, Object?>? updatedInput;
  final List<Map<String, Object?>>? updatedPermissions;
  final String? message;
  final bool? interrupt;

  factory AgentPermissionResponse.fromJson(Map<String, Object?> json) {
    final selectedActionId = _optionalString(json, 'selectedActionId');
    return switch (json['behavior']) {
      'allow' => AgentPermissionResponse.allow(
        selectedActionId: selectedActionId,
        updatedInput: _optionalObject(json, 'updatedInput'),
        updatedPermissions: _optionalObjectList(json, 'updatedPermissions'),
      ),
      'deny' => AgentPermissionResponse.deny(
        selectedActionId: selectedActionId,
        message: _optionalString(json, 'message'),
        interrupt: _optionalBool(json, 'interrupt'),
      ),
      _ => throw const FormatException(
        'permission behavior must be allow or deny',
      ),
    };
  }

  Map<String, Object?> toJson() => switch (behavior) {
    AgentPermissionBehavior.allow => {
      'behavior': 'allow',
      if (selectedActionId != null) 'selectedActionId': selectedActionId,
      if (updatedInput != null) 'updatedInput': updatedInput,
      if (updatedPermissions != null) 'updatedPermissions': updatedPermissions,
    },
    AgentPermissionBehavior.deny => {
      'behavior': 'deny',
      if (selectedActionId != null) 'selectedActionId': selectedActionId,
      if (message != null) 'message': message,
      if (interrupt != null) 'interrupt': interrupt,
    },
  };
}

/// Fire-and-forget client message used to resolve a pending permission.
final class AgentPermissionResponseMessage {
  const AgentPermissionResponseMessage({
    required this.agentId,
    required this.requestId,
    required this.response,
  });

  static const type = 'agent_permission_response';

  final String agentId;
  final String requestId;
  final AgentPermissionResponse response;

  factory AgentPermissionResponseMessage.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected agent_permission_response');
    }
    final response = json['response'];
    if (response is! Map) {
      throw const FormatException('response must be an object');
    }
    return AgentPermissionResponseMessage(
      agentId: _requiredString(json, 'agentId'),
      requestId: _requiredString(json, 'requestId'),
      response: AgentPermissionResponse.fromJson(
        Map<String, Object?>.from(response),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    'requestId': requestId,
    'response': response.toJson(),
  };
}

final class SendAgentMessageRequest {
  const SendAgentMessageRequest({
    required this.requestId,
    required this.agentId,
    required this.text,
    this.messageId,
    this.images = const [],
    this.attachments = const [],
  });

  static const type = 'send_agent_message_request';

  final String requestId;
  final String agentId;
  final String text;
  final String? messageId;
  final List<AgentPromptImage> images;
  final List<AgentAttachment> attachments;

  factory SendAgentMessageRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected send_agent_message_request');
    }
    final requestId = _requiredString(json, 'requestId');
    final agentId = _requiredString(json, 'agentId');
    final text = json['text'];
    final messageId = json['messageId'];
    if (text is! String || (messageId != null && messageId is! String)) {
      throw const FormatException('Invalid send_agent_message_request');
    }
    final rawImages = json['images'];
    if (rawImages != null && rawImages is! List) {
      throw const FormatException('images must be an array');
    }
    final images = <AgentPromptImage>[];
    for (final rawImage in rawImages is List ? rawImages : const []) {
      final image = AgentPromptImage.tryFromJson(rawImage);
      if (image == null) throw const FormatException('Invalid prompt image');
      images.add(image);
    }
    return SendAgentMessageRequest(
      requestId: requestId,
      agentId: agentId,
      text: text,
      messageId: messageId as String?,
      images: List.unmodifiable(images),
      attachments: List.unmodifiable(
        AgentAttachment.normalizeList(json['attachments']),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'agentId': agentId,
    'text': text,
    if (messageId != null) 'messageId': messageId,
    if (images.isNotEmpty)
      'images': [for (final image in images) image.toJson()],
    if (attachments.isNotEmpty)
      'attachments': [
        for (final attachment in attachments) attachment.toJson(),
      ],
  };
}

final class SendAgentMessageResponse {
  const SendAgentMessageResponse({
    required this.requestId,
    required this.agentId,
    required this.accepted,
    required this.error,
  });

  static const type = 'send_agent_message_response';

  final String requestId;
  final String agentId;
  final bool accepted;
  final String? error;

  factory SendAgentMessageResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected send_agent_message_response');
    }
    final payload = _requiredMap(json, 'payload');
    final accepted = payload['accepted'];
    final error = payload['error'];
    if (accepted is! bool || (error != null && error is! String)) {
      throw const FormatException('Invalid send_agent_message_response');
    }
    return SendAgentMessageResponse(
      requestId: _requiredString(payload, 'requestId'),
      agentId: _requiredString(payload, 'agentId'),
      accepted: accepted,
      error: error as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'agentId': agentId,
      'accepted': accepted,
      'error': error,
    },
  };
}

final class WaitForFinishRequest {
  const WaitForFinishRequest({
    required this.requestId,
    required this.agentId,
    this.timeoutMs,
  });

  static const type = 'wait_for_finish_request';

  final String requestId;
  final String agentId;
  final int? timeoutMs;

  factory WaitForFinishRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected wait_for_finish_request');
    }
    final timeout = json['timeoutMs'];
    if (timeout != null &&
        (timeout is! num || timeout.toInt() != timeout || timeout <= 0)) {
      throw const FormatException('timeoutMs must be a positive integer');
    }
    return WaitForFinishRequest(
      requestId: _requiredString(json, 'requestId'),
      agentId: _requiredString(json, 'agentId'),
      timeoutMs: (timeout as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'agentId': agentId,
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
  };
}

enum WaitForFinishStatus { idle, error, permission, timeout }

final class WaitForFinishResponse {
  const WaitForFinishResponse({
    required this.requestId,
    required this.status,
    required this.finalAgent,
    required this.error,
    required this.lastMessage,
  });

  static const type = 'wait_for_finish_response';

  final String requestId;
  final WaitForFinishStatus status;
  final Map<String, Object?>? finalAgent;
  final String? error;
  final String? lastMessage;

  factory WaitForFinishResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected wait_for_finish_response');
    }
    final payload = _requiredMap(json, 'payload');
    final rawStatus = payload['status'];
    final rawFinal = payload['final'];
    final error = payload['error'];
    final lastMessage = payload['lastMessage'];
    final status = WaitForFinishStatus.values
        .where((value) => value.name == rawStatus)
        .firstOrNull;
    if (status == null ||
        (rawFinal != null && rawFinal is! Map) ||
        (error != null && error is! String) ||
        (lastMessage != null && lastMessage is! String)) {
      throw const FormatException('Invalid wait_for_finish_response');
    }
    final finalAgent = rawFinal == null
        ? null
        : Map<String, Object?>.from(rawFinal as Map);
    if (finalAgent != null) PaseoAgentSnapshotCodec.decode(finalAgent);
    return WaitForFinishResponse(
      requestId: _requiredString(payload, 'requestId'),
      status: status,
      finalAgent: finalAgent,
      error: error as String?,
      lastMessage: lastMessage as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'status': status.name,
      'final': finalAgent,
      'error': error,
      'lastMessage': lastMessage,
    },
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

Map<String, Object?>? _optionalObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map || value.keys.any((entry) => entry is! String)) {
    throw FormatException('$key must be an object');
  }
  return Map<String, Object?>.unmodifiable(Map<String, Object?>.from(value));
}

List<Map<String, Object?>>? _optionalObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! List) throw FormatException('$key must be an array');
  return List<Map<String, Object?>>.unmodifiable([
    for (final entry in value)
      if (entry is Map && entry.keys.every((key) => key is String))
        Map<String, Object?>.unmodifiable(Map<String, Object?>.from(entry))
      else
        throw FormatException('$key entries must be objects'),
  ]);
}
