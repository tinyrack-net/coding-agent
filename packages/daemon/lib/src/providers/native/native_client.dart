/// [AgentClient] backed by a direct LLM API call instead of a CLI subprocess.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_client.dart';
import '../agent_session.dart';
import 'credential_store.dart';
import 'llm_backend.dart';
import 'native_session.dart';
import 'timeline_history.dart';

class NativeClient implements AgentClient {
  NativeClient({
    required this.providerId,
    required this.backend,
    required this.credentials,
  });

  final ProviderId providerId;
  final LlmBackend backend;
  final CredentialStore credentials;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    final apiKey = await credentials.get(providerId.name);
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('no API key configured for ${providerId.name}');
    }
    return NativeSession(
      backend: backend,
      model: model,
      cwd: cwd,
      mode: mode,
      apiKey: apiKey,
      initialMessages: historyFromTimeline(initialHistory),
    );
  }
}
