import 'dart:io';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late CredentialStore credentials;
  late ProviderRegistry registry;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_registry_test_');
    credentials = CredentialStore(dataDir: tempDir.path);
    registry = ProviderRegistry(credentials);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('all three providers unconfigured when no keys are stored', () async {
    final list = await registry.list();

    expect(list, hasLength(3));
    expect(list.map((p) => p.id), containsAll(ProviderId.values));
    for (final info in list) {
      expect(info.configured, isFalse);
      expect(info.unavailableReason, 'no API key configured');
      expect(info.models, isNotEmpty);
    }
  });

  test('provider reports configured once a key is stored', () async {
    await credentials.set(ProviderId.openai.name, 'sk-test-123');

    final list = await registry.list();
    final openai = list.firstWhere((p) => p.id == ProviderId.openai);
    expect(openai.configured, isTrue);
    expect(openai.unavailableReason, isNull);
    expect(openai.models.map((m) => m.id), contains('gpt-5.4-codex'));

    final deepseek = list.firstWhere((p) => p.id == ProviderId.deepseek);
    expect(deepseek.configured, isFalse);
  });

  test('clearing a key reverts to unconfigured', () async {
    await credentials.set(ProviderId.openrouter.name, 'sk-or-test');
    expect(
      (await registry.list())
          .firstWhere((p) => p.id == ProviderId.openrouter)
          .configured,
      isTrue,
    );

    await credentials.clear(ProviderId.openrouter.name);
    expect(
      (await registry.list())
          .firstWhere((p) => p.id == ProviderId.openrouter)
          .configured,
      isFalse,
    );
  });
}
