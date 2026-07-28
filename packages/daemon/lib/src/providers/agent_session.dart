/// Abstract provider session: one live provider process/conversation.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'provider_event.dart';

abstract interface class AgentSession {
  /// Normalized event stream; closes after [SessionExited].
  Stream<ProviderEvent> get events;

  /// Send a user prompt, starting (or continuing) a turn.
  Future<void> prompt(String text);

  /// Ask the provider to stop the current turn.
  Future<void> interrupt();

  /// Tear the session down, killing the underlying process if needed.
  Future<void> dispose();
}

/// A provider session that can preserve Paseo's structured prompt block order.
///
/// Text attachments tagged as chat history are sent before the user's text;
/// ordinary context attachments follow the text. Providers without this
/// interface receive the compatibility text rendering from [AgentManager].
abstract interface class StructuredPromptAgentSession implements AgentSession {
  Future<void> promptWithAttachments(
    String text,
    List<AgentAttachment> attachments,
  );
}

abstract interface class ImagePromptAgentSession
    implements StructuredPromptAgentSession {
  Future<void> promptWithImagesAndAttachments(
    String text,
    List<AgentPromptImage> images,
    List<AgentAttachment> attachments,
  );
}

abstract interface class ConfigurableAgentSession implements AgentSession {
  Future<AgentProviderNotice?> setMode(String modeId);
  Future<void> setModel(String? modelId);
  Future<AgentProviderNotice?> setThinkingOption(String? thinkingOptionId);
  Future<void> setFeature(String featureId, Object? value);
}

abstract interface class CommandListingAgentSession implements AgentSession {
  Future<List<AgentSlashCommand>> listCommands();
}

abstract interface class FeatureListingAgentSession implements AgentSession {
  List<AgentFeature> get features;
}

/// A provider session that restored its provider-native history while
/// connecting. The manager rebuilds its local timeline from this authoritative
/// snapshot before accepting the next prompt.
abstract interface class HistoryRestoringAgentSession implements AgentSession {
  List<TimelineItem>? get restoredHistory;
}

final class RestoredProviderSubagent {
  const RestoredProviderSubagent({
    required this.id,
    required this.status,
    required this.timeline,
    this.title,
    this.description,
    this.toolCallId,
    this.cwd,
  });

  final String id;
  final String? title;
  final String? description;
  final ProviderSubagentStatus status;
  final String? toolCallId;
  final String? cwd;
  final List<TimelineItem> timeline;
}

abstract interface class ProviderSubagentRestoringAgentSession
    implements AgentSession {
  List<RestoredProviderSubagent> get restoredProviderSubagents;
}
