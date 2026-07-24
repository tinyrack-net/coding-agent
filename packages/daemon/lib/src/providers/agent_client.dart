/// Abstract provider client: factory for [AgentSession]s.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'agent_session.dart';

abstract interface class AgentClient {
  /// Create a new provider session. Pass [sessionId] to resume a previous
  /// provider-native conversation.
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
  });
}
