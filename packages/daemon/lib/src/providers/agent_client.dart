/// Abstract provider client: factory for [AgentSession]s.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'agent_session.dart';

final class ListImportableSessionsOptions {
  const ListImportableSessionsOptions({this.limit, this.cwd});

  final int? limit;
  final String? cwd;
}

final class ImportableProviderSession {
  const ImportableProviderSession({
    required this.providerHandleId,
    required this.cwd,
    required this.title,
    required this.firstPromptPreview,
    required this.lastPromptPreview,
    required this.lastActivityAt,
  });

  final String providerHandleId;
  final String cwd;
  final String? title;
  final String? firstPromptPreview;
  final String? lastPromptPreview;
  final DateTime lastActivityAt;
}

final class ResolveAgentDefaultModeInput {
  const ResolveAgentDefaultModeInput({
    required this.provider,
    required this.cwd,
    required this.model,
    this.environment = const {},
  });

  final String provider;
  final String cwd;
  final String model;
  final Map<String, String> environment;
}

/// Optional capability for providers whose safe default depends on the
/// installed binary or launch environment.
abstract interface class DefaultModeResolvingAgentClient {
  Future<String?> resolveDefaultModeId(ResolveAgentDefaultModeInput input);
}

/// Optional capability advertised only by providers that can enumerate native
/// sessions which may be imported.
abstract interface class ImportableAgentClient {
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]);
}

abstract interface class AgentClient {
  /// Create a new provider session. Pass [sessionId] to resume a previous
  /// provider-native conversation. [initialHistory] is the agent's persisted
  /// timeline so far — CLI-backed providers ignore it (they resume via
  /// [sessionId] instead); native providers replay it into their own message
  /// history (see `historyFromTimeline`).
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  });
}

/// Optional provider boundary for a session-specific environment overlay.
///
/// Paseo's `create_agent_request.env` is per agent, not a daemon-global
/// provider setting. Keeping this as a capability avoids breaking lightweight
/// test/provider implementations that do not launch subprocesses.
abstract interface class EnvironmentAgentClient implements AgentClient {
  Future<AgentSession> createSessionWithEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, String> environment = const {},
  });
}

/// Provider client that accepts the persisted MCP server portion of an agent
/// session configuration.
abstract interface class McpAgentClient implements AgentClient {
  Future<AgentSession> createSessionWithMcp({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  });
}

abstract interface class EnvironmentMcpAgentClient
    implements McpAgentClient, EnvironmentAgentClient {
  Future<AgentSession> createSessionWithMcpAndEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
    Map<String, String> environment = const {},
  });
}

abstract interface class DraftCommandListingAgentClient implements AgentClient {
  Future<List<AgentSlashCommand>> listCommands(ListCommandsDraftConfig config);
}

abstract interface class DraftFeatureListingAgentClient implements AgentClient {
  Future<List<AgentFeature>> listFeatures(ListCommandsDraftConfig config);
}
