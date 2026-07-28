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
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
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
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  });
}

abstract interface class DraftCommandListingAgentClient implements AgentClient {
  Future<List<AgentSlashCommand>> listCommands(ListCommandsDraftConfig config);
}

abstract interface class DraftFeatureListingAgentClient implements AgentClient {
  Future<List<AgentFeature>> listFeatures(ListCommandsDraftConfig config);
}
