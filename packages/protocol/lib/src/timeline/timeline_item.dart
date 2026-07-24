/// Timeline items streamed over `agent.stream` and returned by
/// `agent.timeline.fetch`.
///
/// Items are identified by [id] and upserted: the daemon may re-send an item
/// with the same id and updated content (e.g. streaming assistant text).
library;

import 'tool_call_detail.dart';

enum ToolCallStatus { pending, running, success, error }

enum TurnPhase { started, completed, failed, canceled }

enum PermissionStatus { pending, allowed, denied }

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
      'error' => ErrorItem(id: id, message: (json['message'] as String?) ?? ''),
      _ => ErrorItem(id: id, message: 'unknown item kind: ${json['kind']}'),
    };
  }

  Map<String, Object?> _base() => {'id': id, 'kind': kind};
}

final class UserMessageItem extends TimelineItem {
  const UserMessageItem({required super.id, required this.text});

  final String text;

  @override
  String get kind => 'user_message';

  @override
  Map<String, Object?> toJson() => {..._base(), 'text': text};
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
  Map<String, Object?> toJson() =>
      {..._base(), 'text': text, 'complete': complete};
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
  Map<String, Object?> toJson() =>
      {..._base(), 'text': text, 'complete': complete};
}

final class ToolCallItem extends TimelineItem {
  const ToolCallItem({
    required super.id,
    required this.toolName,
    required this.status,
    required this.detail,
  });

  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;

  @override
  String get kind => 'tool_call';

  @override
  Map<String, Object?> toJson() => {
        ..._base(),
        'toolName': toolName,
        'status': status.name,
        'detail': detail.toJson(),
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

final class ErrorItem extends TimelineItem {
  const ErrorItem({required super.id, required this.message});

  final String message;

  @override
  String get kind => 'error';

  @override
  Map<String, Object?> toJson() => {..._base(), 'message': message};
}
