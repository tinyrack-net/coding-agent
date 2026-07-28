import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'connection_settings_provider.dart';
import 'daemon_lifecycle_provider.dart';
import 'host_registry_provider.dart';

typedef DaemonClientFactory = DaemonClient Function(ConnectionSettings);

final daemonClientFactoryProvider = Provider<DaemonClientFactory>(
  (ref) =>
      (settings) => DaemonClient(
        uri: settings.uri,
        token: settings.token,
        relayE2ee: settings.daemonPublicKeyB64 == null
            ? null
            : RelayE2eeOptions(
                daemonPublicKeyB64: settings.daemonPublicKeyB64!,
              ),
      ),
);

DaemonClient _buildManagedClient(
  Ref ref,
  ConnectionSettings settings, {
  String? expectedServerId,
}) {
  final client = ref.watch(daemonClientFactoryProvider)(settings);
  final subscription = client.connectionState.listen((state) {
    if (state != DaemonConnectionState.connected) return;
    final info = client.serverInfo;
    if (info == null) return;
    if (expectedServerId != null && info.serverId != expectedServerId) {
      ref
          .read(hostRegistryProvider.notifier)
          .reconcileServerId(
            oldServerId: expectedServerId,
            newServerId: info.serverId,
            label: info.hostname,
          );
      return;
    }
    if (settings.isRelay) return;
    final registry = ref.read(hostRegistryProvider);
    final endpoint = normalizeHostPort('${settings.host}:${settings.port}');
    final alreadyRegistered = registry.hosts.any(
      (host) =>
          host.serverId == info.serverId &&
          host.connections.whereType<DirectTcpHostConnection>().any(
            (connection) =>
                connection.endpoint == endpoint &&
                connection.useTls == settings.useTls &&
                connection.password == settings.token,
          ),
    );
    if (alreadyRegistered) return;
    ref
        .read(hostRegistryProvider.notifier)
        .upsertDirectConnection(
          serverId: info.serverId,
          endpoint: endpoint,
          useTls: settings.useTls,
          password: settings.token,
          label: info.hostname,
        );
  });
  ref.onDispose(subscription.cancel);
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
}

/// One long-lived runtime client per registered Paseo host. Reading this
/// family for every registry entry keeps all host transports alive
/// concurrently; active-host selection no longer destroys inactive clients.
final hostDaemonClientProvider = Provider.autoDispose
    .family<DaemonClient?, String>((ref, serverId) {
      final host = ref.watch(
        hostRegistryProvider.select(
          (registry) => registry.hosts
              .where((candidate) => candidate.serverId == serverId)
              .firstOrNull,
        ),
      );
      if (host == null) return null;
      final settings = connectionSettingsForHost(host);
      if (settings == null) return null;
      return _buildManagedClient(
        ref,
        settings,
        expectedServerId: host.serverId,
      );
    });

/// Eager host-session manager, equivalent to Paseo's `HostSessionManager`.
/// The root app watches this provider so every registered host has a runtime.
final hostRuntimeClientsProvider = Provider<Map<String, DaemonClient>>((ref) {
  final hosts = ref.watch(hostRegistryProvider).hosts;
  final clients = <String, DaemonClient>{};
  for (final host in hosts) {
    final client = ref.watch(hostDaemonClientProvider(host.serverId));
    if (client != null) clients[host.serverId] = client;
  }
  return Map.unmodifiable(clients);
});

/// Compatibility view used by providers that have not yet accepted an
/// explicit server id. It points at the active host runtime while all other
/// host clients remain alive in [hostRuntimeClientsProvider].
final daemonClientProvider = Provider<DaemonClient>((ref) {
  final activeHost = ref.watch(activeHostProvider);
  if (activeHost != null) {
    final active = ref.watch(hostDaemonClientProvider(activeHost.serverId));
    if (active != null) return active;
  }
  final legacy = ref.watch(connectionSettingsProvider);
  return _buildManagedClient(ref, legacy);
});

final hostConnectionStateProvider = StreamProvider.autoDispose
    .family<DaemonConnectionState, String>((ref, serverId) {
      final client = ref.watch(hostDaemonClientProvider(serverId));
      return client?.connectionState ??
          Stream.value(DaemonConnectionState.disconnected);
    });

final connectionStateProvider = StreamProvider<DaemonConnectionState>((ref) {
  final client = ref.watch(daemonClientProvider);
  return client.connectionState;
});

final providerListProvider = FutureProvider<List<ProviderInfo>>((ref) async {
  final client = ref.watch(daemonClientProvider);
  final state = await ref.watch(connectionStateProvider.future);
  if (state != DaemonConnectionState.connected) return const [];
  final payload = await client.request(
    MessageTypes.providerListRequest,
    const {},
  );
  return ProviderListResponse.fromJson(payload).providers;
});

/// Imperative actions for managing per-provider API keys.
class ProviderCredentialActions {
  ProviderCredentialActions(this._ref);

  final Ref _ref;

  DaemonClient get _client => _ref.read(daemonClientProvider);

  Future<void> setKey(ProviderId providerId, String apiKey) async {
    await _client.request(MessageTypes.providerCredentialSetRequest, {
      'providerId': providerId.name,
      'apiKey': apiKey,
    });
    _ref.invalidate(providerListProvider);
  }

  Future<void> clearKey(ProviderId providerId) async {
    await _client.request(MessageTypes.providerCredentialClearRequest, {
      'providerId': providerId.name,
    });
    _ref.invalidate(providerListProvider);
  }

  Future<ProviderCredentialTestResult> testKey(
    ProviderId providerId, {
    String? apiKey,
  }) async {
    final payload = await _client
        .request(MessageTypes.providerCredentialTestRequest, {
          'providerId': providerId.name,
          if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        });
    return ProviderCredentialTestResult.fromJson(payload);
  }
}

final providerCredentialActionsProvider = Provider<ProviderCredentialActions>(
  ProviderCredentialActions.new,
);
