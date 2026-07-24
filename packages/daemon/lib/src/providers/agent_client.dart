/// Abstract provider client: factory for [AgentSession]s.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'agent_session.dart';

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
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  });
}
