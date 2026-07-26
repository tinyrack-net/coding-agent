import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'connection_settings_provider.dart';
import 'daemon_lifecycle_provider.dart';

/// The client is recreated (old one disposed) whenever settings change.
///
/// On desktop with a loopback host, connecting waits for the lifecycle
/// provider's ensureRunning to resolve (success OR error — on spawn error the
/// client still connects so its reconnect loop keeps trying while the UI
/// shows the spawn error). Mobile/remote behavior is unchanged.
final daemonClientProvider = Provider<DaemonClient>((ref) {
  final settings = ref.watch(connectionSettingsProvider);
  final client = DaemonClient(uri: settings.uri, token: settings.token);
  ref.onDispose(client.dispose);
  if (ref.watch(desktopShellProvider)) {
    final lifecycle = ref.watch(daemonLifecycleProvider);
    final gated = isLoopbackHost(settings.host);
    if (!gated || !lifecycle.isLoading) client.connect();
    // While gated + loading: this provider rebuilds (and connects) once the
    // lifecycle provider resolves.
  } else {
    client.connect();
  }
  return client;
});

final connectionStateProvider = StreamProvider<DaemonConnectionState>((ref) {
  final client = ref.watch(daemonClientProvider);
  return client.connectionState;
});

final providerListProvider = FutureProvider<List<ProviderInfo>>((ref) async {
  final client = ref.watch(daemonClientProvider);
  final state = await ref.watch(connectionStateProvider.future);
  if (state != DaemonConnectionState.connected) return const [];
  final payload =
      await client.request(MessageTypes.providerListRequest, const {});
  return ProviderListResponse.fromJson(payload).providers;
});

/// Imperative actions for managing providers and their API keys.
class ProviderActions {
  ProviderActions(this._ref);

  final Ref _ref;

  DaemonClient get _client => _ref.read(daemonClientProvider);

  /// Creates (empty [ProviderConfig.id]) or updates a provider. A null or
  /// empty [apiKey] leaves any stored key untouched, so editing a provider
  /// doesn't require re-typing the secret.
  Future<ProviderConfig> upsert(
    ProviderConfig config, {
    String? apiKey,
  }) async {
    final payload = await _client.request(MessageTypes.providerUpsertRequest, {
      'config': config.toJson(),
      if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
    });
    _ref.invalidate(providerListProvider);
    return ProviderUpsertResponse.fromJson(payload).config;
  }

  Future<void> delete(String providerId) async {
    await _client.request(MessageTypes.providerDeleteRequest, {
      'providerId': providerId,
    });
    _ref.invalidate(providerListProvider);
  }

  Future<void> setKey(String providerId, String apiKey) async {
    await _client.request(MessageTypes.providerCredentialSetRequest, {
      'providerId': providerId,
      'apiKey': apiKey,
    });
    _ref.invalidate(providerListProvider);
  }

  Future<void> clearKey(String providerId) async {
    await _client.request(MessageTypes.providerCredentialClearRequest, {
      'providerId': providerId,
    });
    _ref.invalidate(providerListProvider);
  }

  Future<ProviderCredentialTestResult> testKey(
    String providerId, {
    String? apiKey,
  }) async {
    final payload = await _client.request(
      MessageTypes.providerCredentialTestRequest,
      {
        'providerId': providerId,
        if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
      },
    );
    return ProviderCredentialTestResult.fromJson(payload);
  }
}

final providerActionsProvider =
    Provider<ProviderActions>(ProviderActions.new);
