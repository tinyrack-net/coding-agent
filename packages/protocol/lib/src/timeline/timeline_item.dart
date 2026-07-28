/// Timeline items streamed over `agent.stream` and returned by
/// `agent.timeline.fetch`.
///
/// Items are identified by [id] and upserted: the daemon may re-send an item
/// with the same id and updated content (e.g. streaming assistant text).
library;

import '../messages/agent_attachment.dart';
import 'tool_call_detail.dart';

enum ToolCallStatus { pending, running, success, error, canceled }

enum TurnPhase { started, completed, failed, canceled }

enum PermissionStatus { pending, allowed, denied }

enum CompactionStatus { loading, completed }

enum CompactionTrigger { auto, manual }

sealed class TimelineItem {
  const TimelineItem({required this.id});

  final String id;

  String get kind;

  Map<String, Object?> toJson();

  static TimelineItem fromJson(Map<String, Object?> json) {
    final id = json['id'] as String;
    return switch (json['kind'] as String?) {
      'user_message' => UserMessageItem(
        id: id,
        text: (json['text'] as String?) ?? '',
        clientMessageId: json['clientMessageId'] as String?,
        attachments: AgentAttachment.normalizeList(json['attachments']),
      ),
      'assistant_message' => AssistantMessageItem(
        id: id,
        text: (json['text'] as String?) ?? '',
        complete: (json['complete'] as bool?) ?? true,
      ),
      'reasoning' => ReasoningItem(
        id: id,
        text: (json['text'] as String?) ?? '',
        complete: (json['complete'] as bool?) ?? true,
      ),
      'tool_call' => ToolCallItem(
        id: id,
        toolName: (json['toolName'] as String?) ?? '',
        status: ToolCallStatus.values.byName(
          (json['status'] as String?) ?? 'pending',
        ),
        detail: ToolCallDetail.fromJson(
          (json['detail'] as Map<String, Object?>?) ?? const {},
        ),
        errorMessage: json['errorMessage'] as String?,
        metadata:
            (json['metadata'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      'turn' => TurnItem(
        id: id,
        phase: TurnPhase.values.byName((json['phase'] as String?) ?? 'started'),
        errorMessage: json['errorMessage'] as String?,
      ),
      'permission' => PermissionItem(
        id: id,
        permissionId: (json['permissionId'] as String?) ?? '',
        toolName: (json['toolName'] as String?) ?? '',
        status: PermissionStatus.values.byName(
          (json['status'] as String?) ?? 'pending',
        ),
        detail: ToolCallDetail.fromJson(
          (json['detail'] as Map<String, Object?>?) ?? const {},
        ),
      ),
      'todo' => TodoItem(
        id: id,
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => TodoEntry.fromJson(item.cast<String, Object?>()))
            .toList(growable: false),
      ),
      'error' => ErrorItem(id: id, message: (json['message'] as String?) ?? ''),
      'compaction' => CompactionItem(
        id: id,
        status: CompactionStatus.values.byName(
          (json['status'] as String?) ?? 'completed',
        ),
        trigger: json['trigger'] is String
            ? CompactionTrigger.values.byName(json['trigger']! as String)
            : null,
        preTokens: (json['preTokens'] as num?)?.toInt(),
      ),
      _ => ErrorItem(id: id, message: 'unknown item kind: ${json['kind']}'),
    };
  }

  Map<String, Object?> _base() => {'id': id, 'kind': kind};
}

final class UserMessageItem extends TimelineItem {
  const UserMessageItem({
    required super.id,
    required this.text,
    this.clientMessageId,
    this.attachments = const [],
  });

  final String text;
  final String? clientMessageId;
  final List<AgentAttachment> attachments;

  @override
  String get kind => 'user_message';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'text': text,
    if (clientMessageId != null) 'clientMessageId': clientMessageId,
    if (attachments.isNotEmpty)
      'attachments': attachments
          .map((attachment) => attachment.toJson())
          .toList(growable: false),
  };
}

final class AssistantMessageItem extends TimelineItem {
  const AssistantMessageItem({
    required super.id,
    required this.text,
    required this.complete,
  });

  final String text;
  final bool complete;

  @override
  String get kind => 'assistant_message';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'text': text,
    'complete': complete,
  };
}

final class ReasoningItem extends TimelineItem {
  const ReasoningItem({
    required super.id,
    required this.text,
    required this.complete,
  });

  final String text;
  final bool complete;

  @override
  String get kind => 'reasoning';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'text': text,
    'complete': complete,
  };
}

final class ToolCallItem extends TimelineItem {
  const ToolCallItem({
    required super.id,
    required this.toolName,
    required this.status,
    required this.detail,
    this.errorMessage,
    this.metadata = const {},
  });

  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;
  final String? errorMessage;
  final Map<String, Object?> metadata;

  @override
  String get kind => 'tool_call';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'toolName': toolName,
    'status': status.name,
    'detail': detail.toJson(),
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

final class TurnItem extends TimelineItem {
  const TurnItem({required super.id, required this.phase, this.errorMessage});

  final TurnPhase phase;
  final String? errorMessage;

  @override
  String get kind => 'turn';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'phase': phase.name,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

final class PermissionItem extends TimelineItem {
  const PermissionItem({
    required super.id,
    required this.permissionId,
    required this.toolName,
    required this.status,
    required this.detail,
  });

  final String permissionId;
  final String toolName;
  final PermissionStatus status;
  final ToolCallDetail detail;

  @override
  String get kind => 'permission';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'permissionId': permissionId,
    'toolName': toolName,
    'status': status.name,
    'detail': detail.toJson(),
  };
}

final class TodoEntry {
  const TodoEntry({required this.text, required this.completed});

  final String text;
  final bool completed;

  factory TodoEntry.fromJson(Map<String, Object?> json) => TodoEntry(
    text: (json['text'] as String?) ?? '',
    completed: json['completed'] == true,
  );

  Map<String, Object?> toJson() => {'text': text, 'completed': completed};
}

final class TodoItem extends TimelineItem {
  const TodoItem({required super.id, required this.items});

  final List<TodoEntry> items;

  @override
  String get kind => 'todo';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
}

final class ErrorItem extends TimelineItem {
  const ErrorItem({required super.id, required this.message});

  final String message;

  @override
  String get kind => 'error';

  @override
  Map<String, Object?> toJson() => {..._base(), 'message': message};
}

final class CompactionItem extends TimelineItem {
  const CompactionItem({
    required super.id,
    required this.status,
    this.trigger,
    this.preTokens,
  });

  final CompactionStatus status;
  final CompactionTrigger? trigger;
  final int? preTokens;

  @override
  String get kind => 'compaction';

  @override
  Map<String, Object?> toJson() => {
    ..._base(),
    'status': status.name,
    if (trigger != null) 'trigger': trigger!.name,
    if (preTokens != null) 'preTokens': preTokens,
  };
}
