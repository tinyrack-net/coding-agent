/// [AgentClient] backed by the Claude Code CLI.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_client.dart';
import '../agent_session.dart';
import '../exe_resolver.dart';
import 'claude_session.dart';

class ClaudeClient implements AgentClient {
  ClaudeClient({ExeResolver? resolver, String? exePath})
      : _resolver = resolver ?? ExeResolver(),
        _exePath = exePath;

  final ExeResolver _resolver;
  String? _exePath;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
  }) async {
    final exePath = _exePath ??= await _resolver.resolve('claude');
    if (exePath == null) {
      throw StateError('claude CLI not found on PATH');
    }
    return ClaudeSession.spawn(
      exePath: exePath,
      cwd: cwd,
      model: model,
      mode: mode,
      sessionId: sessionId,
    );
  }
}
