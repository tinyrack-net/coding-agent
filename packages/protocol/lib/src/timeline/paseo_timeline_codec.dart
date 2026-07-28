/// Frozen Paseo 0.2.0 timeline wire codec.
///
/// The app and daemon use stable local item ids for upsert and persistence.
/// Paseo timeline items deliberately do not carry that storage identity (tool
/// calls use `callId`; other rows are identified by their enclosing sequence).
/// This codec keeps those concerns separate.
library;

import 'timeline_item.dart';
import 'tool_call_detail.dart';

abstract final class PaseoTimelineCodec {
  /// Encodes a canonical Paseo `AgentTimelineItem`.
  ///
  /// Turn and permission items are stream events in Paseo, not timeline rows,
  /// and therefore cannot be encoded by this item codec.
  static Map<String, Object?> encode(TimelineItem item) {
    return switch (item) {
      UserMessageItem(:final id, :final text, :final clientMessageId) => {
        'type': 'user_message',
        'text': text,
        'messageId': id,
        if (clientMessageId != null) 'clientMessageId': clientMessageId,
      },
      AssistantMessageItem(:final id, :final text) => {
        'type': 'assistant_message',
        'text': text,
        'messageId': id,
      },
      ReasoningItem(:final text) => {'type': 'reasoning', 'text': text},
      ToolCallItem(
        :final id,
        :final toolName,
        :final status,
        :final detail,
        :final errorMessage,
        :final metadata,
      ) =>
        {
          'type': 'tool_call',
          'callId': id,
          'name': toolName,
          'detail': detail.toPaseoJson(),
          if (metadata.isNotEmpty) 'metadata': metadata,
          'status': _encodeToolStatus(status),
          'error': status == ToolCallStatus.error
              ? (errorMessage ?? 'Tool call failed')
              : null,
        },
      TodoItem(:final items) => {
        'type': 'todo',
        'items': items.map((item) => item.toJson()).toList(growable: false),
      },
      ErrorItem(:final message) => {'type': 'error', 'message': message},
      CompactionItem(:final status, :final trigger, :final preTokens) => {
        'type': 'compaction',
        'status': status.name,
        if (trigger != null) 'trigger': trigger.name,
        if (preTokens != null) 'preTokens': preTokens,
      },
      TurnItem() => throw const FormatException(
        'turn lifecycle belongs in a Paseo agent_stream event',
      ),
      PermissionItem() => throw const FormatException(
        'permission lifecycle belongs in a Paseo agent_stream event',
      ),
    };
  }

  /// Decodes a canonical Paseo `AgentTimelineItem`.
  ///
  /// [fallbackId] is the enclosing timeline row identity (normally its
  /// sequence/cursor). Tool calls authoritatively use their `callId`.
  static TimelineItem decode(
    Map<String, Object?> json, {
    required String fallbackId,
  }) {
    final type = _requiredString(json, 'type');
    return switch (type) {
      'user_message' => UserMessageItem(
        id: (json['messageId'] as String?) ?? fallbackId,
        text: _requiredString(json, 'text'),
        clientMessageId: json['clientMessageId'] as String?,
      ),
      'assistant_message' => AssistantMessageItem(
        id: (json['messageId'] as String?) ?? fallbackId,
        text: _requiredString(json, 'text'),
        complete: true,
      ),
      'reasoning' => ReasoningItem(
        id: fallbackId,
        text: _requiredString(json, 'text'),
        complete: true,
      ),
      'tool_call' => _decodeToolCall(json),
      'todo' => TodoItem(
        id: fallbackId,
        items: _requiredMapList(
          json,
          'items',
        ).map(TodoEntry.fromJson).toList(growable: false),
      ),
      'error' => ErrorItem(
        id: fallbackId,
        message: _requiredString(json, 'message'),
      ),
      'compaction' => CompactionItem(
        id: fallbackId,
        status: _compactionStatus(json['status']),
        trigger: _compactionTrigger(json['trigger']),
        preTokens: _optionalInt(json, 'preTokens'),
      ),
      _ => throw FormatException('Unknown Paseo timeline item type: $type'),
    };
  }

  static ToolCallItem _decodeToolCall(Map<String, Object?> json) {
    final status = _decodeToolStatus(json['status']);
    final error = json['error'];
    if (status == ToolCallStatus.error && error == null) {
      throw const FormatException('failed tool calls require a non-null error');
    }
    if (status != ToolCallStatus.error && error != null) {
      throw const FormatException('non-failed tool calls require a null error');
    }
    final rawDetail = json['detail'];
    if (rawDetail is! Map) {
      throw const FormatException('detail must be an object');
    }
    final rawMetadata = json['metadata'];
    if (rawMetadata != null && rawMetadata is! Map) {
      throw const FormatException('metadata must be an object');
    }
    return ToolCallItem(
      id: _requiredString(json, 'callId'),
      toolName: _requiredString(json, 'name'),
      status: status,
      detail: ToolCallDetail.fromPaseoJson(rawDetail.cast<String, Object?>()),
      errorMessage: error == null
          ? null
          : error is String
          ? error
          : error.toString(),
      metadata: rawMetadata == null
          ? const <String, Object?>{}
          : (rawMetadata as Map).cast<String, Object?>(),
    );
  }
}

/// Explicit adapter for the pre-parity `kind`/`toolName` local wire shape.
///
/// Keep uses of this adapter at old persistence/RPC boundaries so removal is
/// searchable once the v2 cutover is complete.
abstract final class LegacyTimelineCodec {
  static Map<String, Object?> encode(TimelineItem item) => item.toJson();

  static TimelineItem decode(Map<String, Object?> json) =>
      TimelineItem.fromJson(json);
}

String _encodeToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => 'running',
  ToolCallStatus.success => 'completed',
  ToolCallStatus.error => 'failed',
  ToolCallStatus.canceled => 'canceled',
};

ToolCallStatus _decodeToolStatus(Object? value) => switch (value) {
  'running' => ToolCallStatus.running,
  'completed' => ToolCallStatus.success,
  'failed' => ToolCallStatus.error,
  'canceled' => ToolCallStatus.canceled,
  _ => throw FormatException('Unknown Paseo tool call status: $value'),
};

CompactionStatus _compactionStatus(Object? value) => switch (value) {
  'loading' => CompactionStatus.loading,
  'completed' => CompactionStatus.completed,
  _ => throw FormatException('Unknown Paseo compaction status: $value'),
};

CompactionTrigger? _compactionTrigger(Object? value) => switch (value) {
  null => null,
  'auto' => CompactionTrigger.auto,
  'manual' => CompactionTrigger.manual,
  _ => throw FormatException('Unknown Paseo compaction trigger: $value'),
};

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value == value.toInt()) return value.toInt();
  throw FormatException('$key must be an integer');
}

List<Map<String, Object?>> _requiredMapList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return value
      .map((entry) {
        if (entry is! Map) {
          throw FormatException('$key entries must be objects');
        }
        return entry.cast<String, Object?>();
      })
      .toList(growable: false);
}
