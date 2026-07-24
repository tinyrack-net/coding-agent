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
typedef PermissionRespond = Future<void> Function(
  PermissionDecision decision, {
  String? message,
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
  const AssistantMessageComplete({required this.itemId, required this.fullText});

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
  });

  final String itemId;
  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;
}

final class ToolCallUpdated extends ProviderEvent {
  const ToolCallUpdated({
    required this.itemId,
    required this.toolName,
    required this.status,
    required this.detail,
  });

  final String itemId;
  final String toolName;
  final ToolCallStatus status;
  final ToolCallDetail detail;
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
