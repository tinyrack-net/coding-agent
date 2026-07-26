import 'dart:io';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_daemon/src/providers/native/native_client.dart';
import 'package:agent_daemon/src/providers/native/native_session.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

class StubBackend implements LlmBackend {
  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) =>
      const Stream.empty();

  @override
  Future<bool> testCredential(String apiKey) async => true;

  @override
  Future<List<ProviderModel>> fetchModels(String apiKey) async => const [];
}

const _config = ProviderConfig(
  id: 'p-claude',
  displayName: 'Claude (work)',
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.example/v1',
);

void main() {
  late Directory tempDir;
  late CredentialStore credentials;
  late NativeClient client;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('native_client_test_');
    credentials = CredentialStore(dataDir: tempDir.path);
    client = NativeClient(
      config: _config,
      backend: StubBackend(),
      credentials: credentials,
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('createSession resolves the key by provider id', () async {
    await credentials.set(_config.id, 'sk-ant-1');

    final session = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-opus-4-8',
      mode: AgentMode.normal,
    );

    expect(session, isA<NativeSession>());
    await session.dispose();
  });

  test('throws a named StateError when no key is stored', () async {
    // The display name (not the opaque id) is what a user can act on.
    await expectLater(
      client.createSession(
        cwd: tempDir.path,
        model: 'claude-opus-4-8',
        mode: AgentMode.normal,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Claude (work)'),
        ),
      ),
    );
  });

  test('an empty stored key is treated as unconfigured', () async {
    await credentials.set(_config.id, '');

    await expectLater(
      client.createSession(
        cwd: tempDir.path,
        model: 'claude-opus-4-8',
        mode: AgentMode.normal,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('replays persisted user/assistant history into the session', () async {
    await credentials.set(_config.id, 'sk-ant-1');

    final session = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-opus-4-8',
      mode: AgentMode.plan,
      initialHistory: const [
        UserMessageItem(id: 'u1', text: 'hello'),
        AssistantMessageItem(id: 'a1', text: 'hi there', complete: true),
      ],
    );

    expect(session, isA<NativeSession>());
    await session.dispose();
  });
}
