import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const hostRegistryStorageKey = '@tinyrack:daemon-registry';
const activeHostStorageKey = '@tinyrack:active-host';

final class HostRegistryState {
  const HostRegistryState({
    this.hosts = const [],
    this.activeServerId,
    this.loaded = false,
  });

  final List<HostProfile> hosts;
  final String? activeServerId;
  final bool loaded;

  HostProfile? get activeHost {
    final active = activeServerId;
    if (active != null) {
      for (final host in hosts) {
        if (host.serverId == active) return host;
      }
    }
    return hosts.firstOrNull;
  }

  HostRegistryState copyWith({
    List<HostProfile>? hosts,
    String? activeServerId,
    bool clearActiveServerId = false,
    bool? loaded,
  }) {
    return HostRegistryState(
      hosts: hosts ?? this.hosts,
      activeServerId: clearActiveServerId
          ? null
          : activeServerId ?? this.activeServerId,
      loaded: loaded ?? this.loaded,
    );
  }
}

class HostRegistryNotifier extends Notifier<HostRegistryState> {
  @override
  HostRegistryState build() {
    Future.microtask(_load);
    return const HostRegistryState();
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(hostRegistryStorageKey);
      final hosts = <HostProfile>[];
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            final profile = normalizeStoredHostProfile(entry);
            if (profile != null) hosts.add(profile);
          }
        }
      }
      final storedActive = preferences.getString(activeHostStorageKey);
      final active = hosts.any((host) => host.serverId == storedActive)
          ? storedActive
          : hosts.firstOrNull?.serverId;
      if (!ref.mounted) return;
      state = HostRegistryState(
        hosts: List.unmodifiable(hosts),
        activeServerId: active,
        loaded: true,
      );
    } on Object {
      if (!ref.mounted) return;
      state = const HostRegistryState(loaded: true);
    }
  }

  Future<HostProfile> upsertConnection({
    required String serverId,
    String? label,
    required HostConnection connection,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now().toUtc()).toIso8601String();
    final next = upsertHostConnectionInProfiles(
      profiles: state.hosts,
      serverId: serverId,
      label: label,
      connection: connection,
      now: timestamp,
    );
    final active = state.activeServerId ?? serverId.trim();
    state = HostRegistryState(
      hosts: List.unmodifiable(next),
      activeServerId: active,
      loaded: true,
    );
    await _persist();
    return next.firstWhere((host) => host.serverId == serverId.trim());
  }

  Future<HostProfile> upsertDirectConnection({
    required String serverId,
    required String endpoint,
    bool useTls = false,
    String? password,
    String? label,
    DateTime? now,
  }) {
    final normalized = normalizeHostPort(endpoint);
    final normalizedPassword = password?.trim();
    return upsertConnection(
      serverId: serverId,
      label: label,
      connection: DirectTcpHostConnection(
        id: 'direct:$normalized',
        endpoint: normalized,
        useTls: useTls,
        password: normalizedPassword == null || normalizedPassword.isEmpty
            ? null
            : normalizedPassword,
      ),
      now: now,
    );
  }

  Future<HostProfile> upsertConnectionOffer(
    ConnectionOffer offer, {
    String? label,
    DateTime? now,
  }) {
    // COMPAT(oldRelayOfferTls): Paseo 0.2.0 infers TLS from port 443 when the
    // old offer shape omits the flag.
    final useTls =
        offer.relay.useTls ?? parseHostPort(offer.relay.endpoint).port == 443;
    final endpoint = normalizeHostPort(offer.relay.endpoint);
    return upsertConnection(
      serverId: offer.serverId,
      label: label,
      connection: RelayHostConnection(
        id: useTls ? 'relay:wss:$endpoint' : 'relay:$endpoint',
        relayEndpoint: endpoint,
        useTls: useTls,
        daemonPublicKeyB64: offer.daemonPublicKeyB64,
      ),
      now: now,
    );
  }

  Future<void> selectHost(String serverId) async {
    if (!state.hosts.any((host) => host.serverId == serverId)) {
      throw ArgumentError.value(serverId, 'serverId', 'Unknown host');
    }
    state = state.copyWith(activeServerId: serverId, loaded: true);
    await _persist();
  }

  Future<void> renameHost(String serverId, String label) async {
    final normalized = label.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(label, 'label', 'Label is required');
    }
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final next = state.hosts
        .map(
          (host) => host.serverId == serverId
              ? host.copyWith(label: normalized, updatedAt: timestamp)
              : host,
        )
        .toList(growable: false);
    state = state.copyWith(hosts: List.unmodifiable(next), loaded: true);
    await _persist();
  }

  /// Re-keys a provisional/discovered host when the connected daemon reports
  /// its authoritative server id. Existing connections on both records are
  /// retained, matching Paseo host-runtime reconciliation.
  Future<void> reconcileServerId({
    required String oldServerId,
    required String newServerId,
    String? label,
    DateTime? now,
  }) async {
    final oldId = oldServerId.trim();
    final newId = newServerId.trim();
    if (oldId.isEmpty || newId.isEmpty) {
      throw ArgumentError('Server ids must not be empty');
    }
    if (oldId == newId) return;
    HostProfile? oldHost;
    HostProfile? existing;
    for (final host in state.hosts) {
      if (host.serverId == oldId) oldHost = host;
      if (host.serverId == newId) existing = host;
    }
    if (oldHost == null) return;
    final source = oldHost;
    final connections = <HostConnection>[
      if (existing != null) ...existing.connections,
    ];
    for (final connection in source.connections) {
      if (!connections.any(
        (candidate) => hostConnectionEquals(candidate, connection),
      )) {
        connections.add(connection);
      }
    }
    final timestamp = (now ?? DateTime.now().toUtc()).toIso8601String();
    final preferred =
        existing?.preferredConnectionId ??
        (connections.any(
              (connection) => connection.id == source.preferredConnectionId,
            )
            ? source.preferredConnectionId
            : connections.first.id);
    final reconciled = HostProfile(
      serverId: newId,
      label: normalizeHostLabel(
        label ?? existing?.label ?? source.label,
        newId,
      ),
      connections: List.unmodifiable(connections),
      preferredConnectionId: preferred,
      createdAt: existing?.createdAt ?? source.createdAt,
      updatedAt: timestamp,
    );
    final next = <HostProfile>[
      for (final host in state.hosts)
        if (host.serverId != oldId && host.serverId != newId) host,
      reconciled,
    ];
    state = HostRegistryState(
      hosts: List.unmodifiable(next),
      activeServerId: state.activeServerId == oldId
          ? newId
          : state.activeServerId,
      loaded: true,
    );
    await _persist();
  }

  Future<void> removeConnection(String serverId, String connectionId) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final next = <HostProfile>[];
    for (final host in state.hosts) {
      if (host.serverId != serverId) {
        next.add(host);
        continue;
      }
      final remaining = host.connections
          .where((connection) => connection.id != connectionId)
          .toList(growable: false);
      if (remaining.isEmpty) continue;
      next.add(
        host.copyWith(
          connections: remaining,
          preferredConnectionId: host.preferredConnectionId == connectionId
              ? remaining.first.id
              : host.preferredConnectionId,
          updatedAt: timestamp,
        ),
      );
    }
    final active = next.any((host) => host.serverId == state.activeServerId)
        ? state.activeServerId
        : next.firstOrNull?.serverId;
    state = HostRegistryState(
      hosts: List.unmodifiable(next),
      activeServerId: active,
      loaded: true,
    );
    await _persist();
  }

  Future<void> removeHost(String serverId) async {
    final next = state.hosts
        .where((host) => host.serverId != serverId)
        .toList(growable: false);
    final active = state.activeServerId == serverId
        ? next.firstOrNull?.serverId
        : state.activeServerId;
    state = HostRegistryState(
      hosts: List.unmodifiable(next),
      activeServerId: active,
      loaded: true,
    );
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        hostRegistryStorageKey,
        jsonEncode(state.hosts.map((host) => host.toJson()).toList()),
      );
      final active = state.activeServerId;
      if (active == null) {
        await preferences.remove(activeHostStorageKey);
      } else {
        await preferences.setString(activeHostStorageKey, active);
      }
    } on Object {
      // Runtime state remains usable if platform persistence is unavailable.
    }
  }
}

final hostRegistryProvider =
    NotifierProvider<HostRegistryNotifier, HostRegistryState>(
      HostRegistryNotifier.new,
    );

final activeHostProvider = Provider<HostProfile?>(
  (ref) => ref.watch(hostRegistryProvider).activeHost,
);

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
