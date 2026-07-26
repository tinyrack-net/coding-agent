/// Owns the set of configured providers and resolves each one to a backend.
///
/// Backends are built lazily and cached per provider id, then evicted on
/// upsert/delete — so adding or editing a provider takes effect without a
/// daemon restart.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'agent_client.dart';
import 'native/anthropic_backend.dart';
import 'native/credential_store.dart';
import 'native/llm_backend.dart';
import 'native/native_client.dart';
import 'native/openai_compatible_backend.dart';
import 'native/provider_config_store.dart';

/// Injection seam for tests, which must not construct real HTTP clients.
typedef LlmBackendFactory = LlmBackend Function(ProviderConfig config);

LlmBackend defaultBackendFactory(ProviderConfig config) => switch (config.kind) {
      ProviderKind.openaiCompatible => OpenAiCompatibleBackend(config: config),
      ProviderKind.anthropic => AnthropicBackend(config: config),
    };

/// Thrown when a provider id doesn't resolve — surfaced as an RPC error by the
/// server, and as a session-start failure by the agent manager.
class UnknownProviderException implements Exception {
  UnknownProviderException(this.providerId);
  final String providerId;
  @override
  String toString() => 'unknown provider "$providerId"';
}

class ProviderRegistry {
  ProviderRegistry({
    required CredentialStore credentials,
    required ProviderConfigStore configs,
    LlmBackendFactory backendFactory = defaultBackendFactory,
  })  : _credentials = credentials,
        _configs = configs,
        _backendFactory = backendFactory;

  final CredentialStore _credentials;
  final ProviderConfigStore _configs;
  final LlmBackendFactory _backendFactory;
  final Map<String, LlmBackend> _backends = {};

  /// Reports every configured provider, with a live model list where a key is
  /// stored (falling back to the config's seed models).
  Future<List<ProviderInfo>> list() async {
    final infos = <ProviderInfo>[];
    for (final config in await _configs.list()) {
      final key = await _credentials.get(config.id);
      final configured = key != null && key.isNotEmpty;
      var models = config.models;
      if (configured) {
        models = await _backendFor(config).fetchModels(key);
      }
      infos.add(ProviderInfo(
        id: config.id,
        displayName: config.displayName,
        kind: config.kind,
        baseUrl: config.baseUrl,
        configured: configured,
        models: models,
        unavailableReason: configured ? null : 'no API key configured',
        maxTokens: config.maxTokens,
        extraHeaders: config.extraHeaders,
      ));
    }
    return infos;
  }

  Future<ProviderConfig> configFor(String providerId) async {
    final config = await _configs.get(providerId);
    if (config == null) throw UnknownProviderException(providerId);
    return config;
  }

  Future<LlmBackend> backendFor(String providerId) async =>
      _backendFor(await configFor(providerId));

  LlmBackend _backendFor(ProviderConfig config) =>
      _backends.putIfAbsent(config.id, () => _backendFactory(config));

  /// Creates or updates a provider. An empty [ProviderConfig.id] creates.
  /// A non-null, non-empty [apiKey] is stored; null leaves the existing key
  /// alone (so an edit doesn't require re-typing the secret).
  Future<ProviderConfig> upsert(ProviderConfig config, {String? apiKey}) async {
    final stored = await _configs.upsert(config);
    // The cached backend closed over the old baseUrl/headers/maxTokens.
    _backends.remove(stored.id);
    if (apiKey != null && apiKey.isNotEmpty) {
      await _credentials.set(stored.id, apiKey);
    }
    return stored;
  }

  /// Removes the provider, its cached backend, and its stored key. Clearing
  /// the key matters: otherwise a provider recreated later could inherit an
  /// orphaned credential.
  Future<void> delete(String providerId) async {
    final removed = await _configs.delete(providerId);
    if (!removed) throw UnknownProviderException(providerId);
    _backends.remove(providerId);
    await _credentials.clear(providerId);
  }

  Future<void> setKey(String providerId, String apiKey) async {
    await configFor(providerId); // 404 rather than orphaning a credential
    await _credentials.set(providerId, apiKey);
  }

  Future<void> clearKey(String providerId) async {
    await configFor(providerId);
    await _credentials.clear(providerId);
  }

  /// Tests [apiKey] (or the stored one) against the provider's API.
  Future<ProviderCredentialTestResult> testKey(
    String providerId, {
    String? apiKey,
  }) async {
    final config = await configFor(providerId);
    final key = (apiKey != null && apiKey.isNotEmpty)
        ? apiKey
        : await _credentials.get(providerId);
    if (key == null || key.isEmpty) {
      return const ProviderCredentialTestResult(
        ok: false,
        error: 'no API key given',
      );
    }
    final ok = await _backendFor(config).testCredential(key);
    return ProviderCredentialTestResult(
      ok: ok,
      error: ok ? null : 'API key rejected by provider',
    );
  }

  /// Resolves a provider id to the client that starts its sessions. Passed to
  /// [AgentManager] as its `resolveClient` so a newly added provider is usable
  /// immediately, and a deleted one fails at session start rather than being
  /// silently missing from a map built at boot.
  Future<AgentClient> clientFor(String providerId) async {
    final config = await configFor(providerId);
    return NativeClient(
      config: config,
      backend: _backendFor(config),
      credentials: _credentials,
    );
  }
}
