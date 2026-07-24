import 'package:agent_protocol/agent_protocol.dart';

import 'native/credential_store.dart';
import 'native/provider_catalog.dart';

import 'native/llm_backend.dart';

/// Reports which native LLM providers have a stored API key, for
/// `provider.list`. When an API key is present, fetches available models
/// dynamically from the provider API (with static catalog fallback).
class ProviderRegistry {
  ProviderRegistry(this._credentials, [this._backends = const {}]);

  final CredentialStore _credentials;
  final Map<ProviderId, LlmBackend> _backends;

  Future<List<ProviderInfo>> list() async {
    final infos = <ProviderInfo>[];
    for (final entry in ProviderCatalog.all) {
      final key = await _credentials.get(entry.id.name);
      final configured = key != null && key.isNotEmpty;
      List<ProviderModel> models = entry.models;
      if (configured) {
        final backend = _backends[entry.id];
        if (backend != null) {
          models = await backend.fetchModels(key);
        }
      }
      infos.add(ProviderInfo(
        id: entry.id,
        displayName: entry.displayName,
        configured: configured,
        models: models,
        unavailableReason: configured ? null : 'no API key configured',
      ));
    }
    return infos;
  }
}
