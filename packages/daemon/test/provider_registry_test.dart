import 'dart:io';

import 'package:agent_daemon/src/providers/native/anthropic_backend.dart';
import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_daemon/src/providers/native/native_client.dart';
import 'package:agent_daemon/src/providers/native/openai_compatible_backend.dart';
import 'package:agent_daemon/src/providers/native/provider_config_store.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Records construction and hands back canned model lists, so the registry can
/// be exercised without real HTTP.
class FakeBackend implements LlmBackend {
  FakeBackend(this.config);

  final ProviderConfig config;
  static int constructed = 0;
  bool credentialOk = true;
  List<ProviderModel> models = const [
    ProviderModel(id: 'fetched-model', displayName: 'Fetched'),
  ];
  final testedKeys = <String>[];

  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) =>
      const Stream.empty();

  @override
  Future<bool> testCredential(String apiKey) async {
    testedKeys.add(apiKey);
    return credentialOk;
  }

  @override
  Future<List<ProviderModel>> fetchModels(String apiKey) async => models;
}

ProviderConfig _config({
  String displayName = 'Claude',
  ProviderKind kind = ProviderKind.anthropic,
  String baseUrl = 'https://api.anthropic.example/v1',
}) =>
    ProviderConfig(
      id: '',
      displayName: displayName,
      kind: kind,
      baseUrl: baseUrl,
      models: const [ProviderModel(id: 'seed-model', displayName: 'Seed')],
    );

void main() {
  late Directory tempDir;
  late CredentialStore credentials;
  late ProviderConfigStore configs;
  late ProviderRegistry registry;
  late Map<String, FakeBackend> built;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_registry_test_');
    credentials = CredentialStore(dataDir: tempDir.path);
    configs = ProviderConfigStore(dataDir: tempDir.path);
    built = {};
    FakeBackend.constructed = 0;
    registry = ProviderRegistry(
      credentials: credentials,
      configs: configs,
      backendFactory: (config) {
        FakeBackend.constructed++;
        return built[config.id] = FakeBackend(config);
      },
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('list', () {
    test('is empty with no configured providers', () async {
      expect(await registry.list(), isEmpty);
    });

    test('reports unconfigured with the seed model list', () async {
      await registry.upsert(_config());

      final info = (await registry.list()).single;
      expect(info.configured, isFalse);
      expect(info.unavailableReason, 'no API key configured');
      // No key means no fetch, so the seed list is what's shown.
      expect(info.models.single.id, 'seed-model');
      expect(FakeBackend.constructed, 0);
    });

    test('reports configured and fetches models once a key is stored', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-ant-1');

      final info = (await registry.list()).single;
      expect(info.id, stored.id);
      expect(info.configured, isTrue);
      expect(info.unavailableReason, isNull);
      expect(info.models.single.id, 'fetched-model');
    });

    test('carries kind, baseUrl, maxTokens, and headers through', () async {
      await registry.upsert(
        _config().copyWith(maxTokens: 1234, extraHeaders: {'X-A': 'b'}),
      );
      final info = (await registry.list()).single;
      expect(info.kind, ProviderKind.anthropic);
      expect(info.baseUrl, 'https://api.anthropic.example/v1');
      expect(info.maxTokens, 1234);
      expect(info.extraHeaders, {'X-A': 'b'});
    });
  });

  group('upsert', () {
    test('assigns an id on create and stores the key when given', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-1');
      expect(stored.id, isNotEmpty);
      expect(await credentials.get(stored.id), 'sk-1');
    });

    test('a null or empty apiKey leaves the stored key untouched', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-keep');

      await registry.upsert(stored.copyWith(displayName: 'Renamed'));
      expect(await credentials.get(stored.id), 'sk-keep');

      await registry.upsert(stored.copyWith(displayName: 'Again'), apiKey: '');
      expect(await credentials.get(stored.id), 'sk-keep');
    });

    // The cached backend closed over the old baseUrl/headers/maxTokens.
    test('evicts the cached backend so an edit takes effect', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-1');
      await registry.backendFor(stored.id);
      expect(FakeBackend.constructed, 1);

      await registry.upsert(
        stored.copyWith(baseUrl: 'https://changed.example/v1'),
      );
      final backend = await registry.backendFor(stored.id) as FakeBackend;
      expect(FakeBackend.constructed, 2);
      expect(backend.config.baseUrl, 'https://changed.example/v1');
    });
  });

  group('backendFor', () {
    test('caches per provider id', () async {
      final stored = await registry.upsert(_config());
      final first = await registry.backendFor(stored.id);
      final second = await registry.backendFor(stored.id);
      expect(first, same(second));
      expect(FakeBackend.constructed, 1);
    });

    test('throws UnknownProviderException for an unknown id', () async {
      expect(
        () => registry.backendFor('nope'),
        throwsA(isA<UnknownProviderException>()),
      );
    });
  });

  group('delete', () {
    // Otherwise a provider created later could inherit an orphaned key.
    test('removes the config, cached backend, and stored key', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-1');
      await registry.backendFor(stored.id);

      await registry.delete(stored.id);

      expect(await registry.list(), isEmpty);
      expect(await credentials.get(stored.id), isNull);
      expect(
        () => registry.backendFor(stored.id),
        throwsA(isA<UnknownProviderException>()),
      );
    });

    test('throws for an unknown id', () async {
      expect(
        () => registry.delete('nope'),
        throwsA(isA<UnknownProviderException>()),
      );
    });
  });

  group('setKey / clearKey', () {
    test('round-trips configured state', () async {
      final stored = await registry.upsert(_config());
      expect((await registry.list()).single.configured, isFalse);

      await registry.setKey(stored.id, 'sk-2');
      expect((await registry.list()).single.configured, isTrue);

      await registry.clearKey(stored.id);
      expect((await registry.list()).single.configured, isFalse);
    });

    test('both reject an unknown id rather than orphaning a key', () async {
      expect(
        () => registry.setKey('nope', 'sk'),
        throwsA(isA<UnknownProviderException>()),
      );
      expect(
        () => registry.clearKey('nope'),
        throwsA(isA<UnknownProviderException>()),
      );
    });
  });

  group('testKey', () {
    test('uses the stored key when none is supplied', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-stored');
      final result = await registry.testKey(stored.id);
      expect(result.ok, isTrue);
      expect(built[stored.id]!.testedKeys, ['sk-stored']);
    });

    test('prefers an explicitly supplied key', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-stored');
      await registry.testKey(stored.id, apiKey: 'sk-draft');
      expect(built[stored.id]!.testedKeys, ['sk-draft']);
    });

    test('reports a failure reason when the provider rejects the key', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-1');
      (await registry.backendFor(stored.id) as FakeBackend).credentialOk = false;
      final result = await registry.testKey(stored.id);
      expect(result.ok, isFalse);
      expect(result.error, 'API key rejected by provider');
    });

    test('reports no-key rather than calling the provider', () async {
      final stored = await registry.upsert(_config());
      final result = await registry.testKey(stored.id);
      expect(result.ok, isFalse);
      expect(result.error, 'no API key given');
    });
  });

  group('clientFor', () {
    test('returns a NativeClient bound to the resolved config', () async {
      final stored = await registry.upsert(_config(), apiKey: 'sk-1');
      final client = await registry.clientFor(stored.id) as NativeClient;
      expect(client.config.id, stored.id);
      expect(client.backend, same(built[stored.id]));
    });

    test('throws for an unknown id', () async {
      expect(
        () => registry.clientFor('nope'),
        throwsA(isA<UnknownProviderException>()),
      );
    });
  });

  group('defaultBackendFactory', () {
    test('maps each kind to its backend', () {
      expect(
        defaultBackendFactory(_config(kind: ProviderKind.openaiCompatible)),
        isA<OpenAiCompatibleBackend>(),
      );
      expect(
        defaultBackendFactory(_config(kind: ProviderKind.anthropic)),
        isA<AnthropicBackend>(),
      );
    });
  });

  test('UnknownProviderException names the id', () {
    expect(UnknownProviderException('abc').toString(), contains('abc'));
  });
}
