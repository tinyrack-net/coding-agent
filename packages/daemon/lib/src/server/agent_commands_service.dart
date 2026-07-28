import 'package:agent_protocol/agent_protocol.dart';

import '../agent/agent_manager.dart';

final class AgentCommandsService {
  const AgentCommandsService(this.manager);

  final AgentManager manager;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != ListCommandsRequest.type) return null;
    final request = ListCommandsRequest.fromJson(message);
    try {
      return ListCommandsResponse(
        agentId: request.agentId,
        commands: await manager.listCommands(
          agentId: request.agentId,
          draftConfig: request.draftConfig,
        ),
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return ListCommandsResponse(
        agentId: request.agentId,
        commands: const [],
        requestId: request.requestId,
        error: _errorMessage(error),
      ).toJson();
    }
  }
}

String _errorMessage(Object error) => switch (error) {
  StateError(message: final message) => message,
  UnsupportedError(message: final message) => message ?? '$error',
  _ => '$error',
};
