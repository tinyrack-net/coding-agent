import 'package:agent_protocol/agent_protocol.dart';

import 'native/credential_store.dart';
import 'native/provider_catalog.dart';

/// Reports which native LLM providers have a stored API key, for
/// `provider.list`. Model catalogs are static for the MVP.
class ProviderRegistry {
  ProviderRegistry(this._credentials);

  final CredentialStore _credentials;

  Future<List<ProviderInfo>> list() async {
    final infos = <ProviderInfo>[];
    for (final entry in ProviderCatalog.all) {
      final key = await _credentials.get(entry.id.name);
      final configured = key != null && key.isNotEmpty;
      infos.add(ProviderInfo(
        id: entry.id,
        displayName: entry.displayName,
        configured: configured,
        models: entry.models,
        unavailableReason: configured ? null : 'no API key configured',
      ));
    }
    return infos;
  }
}
