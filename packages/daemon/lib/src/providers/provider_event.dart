/// Normalized events emitted by provider sessions ([AgentSession]).
///
/// The agent manager consumes these and turns them into timeline items and
/// run-state transitions, so higher layers never see provider-specific wire
/// formats.
library;

import 'package:agent_protocol/agent_protocol.dart';

enum PermissionDecision { allow, deny }

/// Callback handed out with [PermissionRequested]; completing it answers the
/// provider's pending permission prompt.
typedef PermissionRespond =
    Future<void> Function(
      PermissionDecision decision, {
      String? message,
      String? selectedActionId,
      Map<String, Object?>? updatedInput,
      List<Map<String, Object?>>? updatedPermissions,
      bool? interrupt,
    });

sealed class ProviderEvent {
  const ProviderEvent();
}

/// Provider-native session established (e.g. Claude `system/init`).
final class SessionStarted extends ProviderEvent {
  const SessionStarted({required this.sessionId});

  final String sessionId;
}

final class AssistantTextDelta extends ProviderEvent {
  const AssistantTextDelta({required this.itemId, required this.text});

  final String itemId;
  final String text;
}

final class ReasoningDelta extends ProviderEvent {
  const ReasoningDelta({required this.itemId, required this.text});

  final String itemId;
  final String text;
}

/// Full text snapshot for an assistant text block; replaces accumulated deltas.
final class AssistantMessageComplete extends ProviderEvent {
  const AssistantMessageComplete({
    required this.itemId,
    required this.fullText,
  });

  final String itemId;
  final String fullText;
}

/// Full text snapshot for a reasoning (thinking) block.
final class ReasoningComplete extends ProviderEvent {
  const ReasoningComplete({required this.itemId, required this.fullText});

  final String itemId;
  final String fullText;
}

final class ToolCallStarted extends ProviderEvent {
  const ToolCallStarted({
    required this.itemId,
    required this.toolName,
    required this.status,
    required this.detail,
    this.errorMessage,
    this.metadata = const {},
  });

  final String itemId;
  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;
  final String? errorMessage;
  final Map<String, Object?> metadata;
}

final class ToolCallUpdated extends ProviderEvent {
  const ToolCallUpdated({
    required this.itemId,
    required this.toolName,
    required this.status,
    required this.detail,
    this.errorMessage,
    this.metadata = const {},
  });

  final String itemId;
  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;
  final String? errorMessage;
  final Map<String, Object?> metadata;
}

final class PermissionRequested extends ProviderEvent {
  const PermissionRequested({
    required this.permissionId,
    required this.toolName,
    required this.detail,
    required this.respond,
  });

  final String permissionId;
  final String toolName;
  final ToolCallDetail detail;
  final PermissionRespond respond;
}

final class UsageUpdated extends ProviderEvent {
  const UsageUpdated({required this.usage});

  final AgentUsage usage;
}

final class CompactionUpdated extends ProviderEvent {
  const CompactionUpdated({
    required this.itemId,
    required this.status,
    this.trigger,
    this.preTokens,
  });

  final String itemId;
  final CompactionStatus status;
  final CompactionTrigger? trigger;
  final int? preTokens;
}

final class ProviderSubagentUpserted extends ProviderEvent {
  const ProviderSubagentUpserted({
    required this.subagentId,
    required this.status,
    this.title,
    this.description,
    this.toolCallId,
    this.cwd,
  });

  final String subagentId;
  final String? title;
  final String? description;
  final ProviderSubagentStatus status;
  final String? toolCallId;
  final String? cwd;
}

final class ProviderSubagentTimelineChanged extends ProviderEvent {
  const ProviderSubagentTimelineChanged({
    required this.subagentId,
    required this.item,
    this.timestamp,
  });

  final String subagentId;
  final TimelineItem item;
  final String? timestamp;
}

final class ProviderSubagentRemoved extends ProviderEvent {
  const ProviderSubagentRemoved({required this.subagentId});
  final String subagentId;
}

final class TurnCompleted extends ProviderEvent {
  const TurnCompleted();
}

final class TurnFailed extends ProviderEvent {
  const TurnFailed({required this.error});

  final String error;
}

/// The underlying provider process exited (cleanly or not).
final class SessionExited extends ProviderEvent {
  const SessionExited({this.exitCode});

  final int? exitCode;
}
