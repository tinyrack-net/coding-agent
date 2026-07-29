/// Frozen Paseo 0.2.0 agent prompt and wait-for-finish contracts.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent_attachment.dart';

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
