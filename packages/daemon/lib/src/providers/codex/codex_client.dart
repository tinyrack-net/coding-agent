/// [AgentClient] backed by the OpenAI Codex CLI (`codex app-server`).
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_client.dart';
import '../agent_session.dart';
import '../exe_resolver.dart';
import 'codex_session.dart';

class CodexClient implements AgentClient {
  CodexClient({ExeResolver? resolver, String? exePath})
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
    final exePath = _exePath ??= await _resolver.resolve('codex');
    if (exePath == null) {
      throw StateError('codex CLI not found on PATH');
    }
    return CodexSession.spawn(
      exePath: exePath,
      cwd: cwd,
      model: model,
      mode: mode,
      sessionId: sessionId,
    );
  }
}
