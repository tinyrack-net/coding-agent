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
      if (client == null) {
        return Stream.value(DaemonConnectionState.disconnected);
      }
      return (() async* {
        // A connected client may have completed its handshake before the
        // provider subscribed (for example while the host registry hydrates),
        // so replay that terminal state. For a newly-created disconnected or
        // connecting client, wait for the real stream instead: emitting the
        // current snapshot would prematurely resolve consumers of
        // `connectionStateProvider.future` and prevent their connected fetch.
        if (client.currentState == DaemonConnectionState.connected) {
          yield client.currentState;
        }
        yield* client.connectionState;
      })();
    });

/// The registry identity of the daemon process owned by this desktop app.
///
/// A loopback transport is not sufficient evidence: users may register
/// multiple standalone daemons on localhost. Pairing is therefore exposed only
/// after the lifecycle supervisor confirms its managed daemon is running and a
/// connected runtime reports the same authoritative server id with
/// `desktopManaged`.
final desktopManagedDaemonServerIdProvider = Provider<String?>((ref) {
  final lifecycle = ref.watch(daemonLifecycleProvider);
  if (lifecycle.isLoading || lifecycle.hasError) return null;
  final status = lifecycle.value;
  if (status == null ||
      !status.isRunning ||
      status.hello?.desktopManaged != true) {
    return null;
  }

  String? resolved;
  for (final host in ref.watch(hostRegistryProvider).hosts) {
    final connection = ref.watch(hostConnectionStateProvider(host.serverId));
    if (connection.value != DaemonConnectionState.connected) continue;
    final info = ref.watch(hostDaemonClientProvider(host.serverId))?.serverInfo;
    if (info == null ||
        !info.desktopManaged ||
        info.serverId != host.serverId) {
      continue;
    }
    // More than one claimed desktop-owned daemon is ambiguous. Do not offer
    // pairing until the runtime registry reconciles to one identity.
    if (resolved != null && resolved != host.serverId) return null;
    resolved = host.serverId;
  }
  return resolved;
});

final connectionStateProvider = StreamProvider<DaemonConnectionState>((ref) {
  final client = ref.watch(daemonClientProvider);
  return (() async* {
    if (client.currentState == DaemonConnectionState.connected) {
      yield client.currentState;
    }
    yield* client.connectionState;
  })();
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
