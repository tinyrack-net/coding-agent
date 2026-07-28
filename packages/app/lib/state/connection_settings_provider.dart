import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'host_registry_provider.dart';

/// Where the app connects to the daemon (persisted, editable in settings).
class ConnectionSettings {
  const ConnectionSettings({
    this.host = '127.0.0.1',
    this.port = 6868,
    this.token,
    this.useTls = false,
    this.relayServerId,
    this.daemonPublicKeyB64,
  });

  final String host;
  final int port;
  final String? token;
  final bool useTls;
  final String? relayServerId;
  final String? daemonPublicKeyB64;

  bool get isRelay => relayServerId != null;

  Uri get uri => isRelay
      ? Uri.parse(
          buildRelayWebSocketUrl(
            endpoint: normalizeHostPort('$host:$port'),
            useTls: useTls,
            serverId: relayServerId!,
            role: RelayRole.client,
          ),
        )
      : Uri(scheme: useTls ? 'wss' : 'ws', host: host, port: port);

  @override
  bool operator ==(Object other) =>
      other is ConnectionSettings &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      other.useTls == useTls &&
      other.relayServerId == relayServerId &&
      other.daemonPublicKeyB64 == daemonPublicKeyB64;

  @override
  int get hashCode =>
      Object.hash(host, port, token, useTls, relayServerId, daemonPublicKeyB64);
}

/// Loads persisted settings on startup and saves edits from the settings UI.
class ConnectionSettingsNotifier extends Notifier<ConnectionSettings> {
  static const _hostKey = 'daemon.host';
  static const _portKey = 'daemon.port';
  static const _tokenKey = 'daemon.token';

  @override
  ConnectionSettings build() {
    Future.microtask(_load);
    return const ConnectionSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_hostKey);
      final port = prefs.getInt(_portKey);
      final token = prefs.getString(_tokenKey);
      if (host == null && port == null && token == null) return;
      state = ConnectionSettings(
        host: host ?? state.host,
        port: port ?? state.port,
        token: token == null || token.isEmpty ? null : token,
      );
    } catch (_) {
      // Keep defaults when the platform store is unavailable.
    }
  }

  Future<void> save({
    required String host,
    required int port,
    String? token,
  }) async {
    final normalizedToken = token == null || token.isEmpty ? null : token;
    state = ConnectionSettings(host: host, port: port, token: normalizedToken);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostKey, host);
      await prefs.setInt(_portKey, port);
      if (normalizedToken == null) {
        await prefs.remove(_tokenKey);
      } else {
        await prefs.setString(_tokenKey, normalizedToken);
      }
    } catch (_) {
      // Settings still apply for this session even if persistence fails.
    }
  }

  /// Restores defaults and clears any persisted host/port/token. The
  /// `daemonClientProvider` rebuilds from the new state, which kicks a
  /// reconnect — call from a destructive flow that has already confirmed
  /// with the user.
  Future<void> reset() async {
    state = const ConnectionSettings();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_hostKey);
      await prefs.remove(_portKey);
      await prefs.remove(_tokenKey);
    } catch (_) {
      // State is already reset for this session even if persistence fails.
    }
  }
}

final connectionSettingsProvider =
    NotifierProvider<ConnectionSettingsNotifier, ConnectionSettings>(
      ConnectionSettingsNotifier.new,
    );

/// Resolves the preferred usable WebSocket transport for one Paseo host.
///
/// Pipe and Unix-socket transports remain registered but are skipped until
/// the Flutter transport layer supports them.
ConnectionSettings? connectionSettingsForHost(HostProfile host) {
  final ordered = <HostConnection>[
    if (host.preferredConnectionId case final preferred?)
      ...host.connections.where((connection) => connection.id == preferred),
    ...host.connections.where(
      (connection) => connection.id != host.preferredConnectionId,
    ),
  ];
  for (final connection in ordered) {
    switch (connection) {
      case RelayHostConnection():
        final endpoint = parseHostPort(connection.relayEndpoint);
        return ConnectionSettings(
          host: endpoint.host,
          port: endpoint.port,
          useTls: connection.useTls ?? endpoint.port == 443,
          relayServerId: host.serverId,
          daemonPublicKeyB64: connection.daemonPublicKeyB64,
        );
      case DirectTcpHostConnection():
        final endpoint = parseHostPort(connection.endpoint);
        return ConnectionSettings(
          host: endpoint.host,
          port: endpoint.port,
          token: connection.password,
          useTls: connection.useTls,
        );
      case DirectSocketHostConnection() || DirectPipeHostConnection():
        continue;
    }
  }
  return null;
}

/// Temporary v1 compatibility view over the Paseo host registry. Once the
/// registry has an active direct connection it is authoritative; otherwise the
/// old editable settings remain the bootstrap target.
final effectiveConnectionSettingsProvider = Provider<ConnectionSettings>((ref) {
  final legacy = ref.watch(connectionSettingsProvider);
  final activeHost = ref.watch(activeHostProvider);
  return activeHost == null
      ? legacy
      : connectionSettingsForHost(activeHost) ?? legacy;
});
