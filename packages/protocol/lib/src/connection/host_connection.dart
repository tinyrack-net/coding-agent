import 'daemon_endpoints.dart';

sealed class HostConnection {
  const HostConnection({required this.id});

  final String id;
  String get wireType;

  factory HostConnection.fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      DirectTcpHostConnection.type => DirectTcpHostConnection.fromJson(json),
      DirectSocketHostConnection.typeValue =>
        DirectSocketHostConnection.fromJson(json),
      DirectPipeHostConnection.typeValue => DirectPipeHostConnection.fromJson(
        json,
      ),
      RelayHostConnection.typeValue => RelayHostConnection.fromJson(json),
      _ => throw const FormatException('Unknown host connection type'),
    };
  }

  Map<String, Object?> toJson();
}

final class DirectTcpHostConnection extends HostConnection {
  const DirectTcpHostConnection({
    required super.id,
    required this.endpoint,
    this.useTls = false,
    this.password,
  });

  static const type = 'directTcp';

  @override
  String get wireType => type;

  final String endpoint;
  final bool useTls;
  final String? password;

  factory DirectTcpHostConnection.fromJson(Map<String, Object?> json) {
    final id = _requiredString(json, 'id');
    if (json['type'] != type) {
      throw const FormatException('type must be directTcp');
    }
    final endpoint = _requiredString(json, 'endpoint');
    final useTls = json['useTls'];
    if (useTls != null && useTls is! bool) {
      throw const FormatException('useTls must be a boolean');
    }
    final password = json['password'];
    if (password != null && password is! String) {
      throw const FormatException('password must be a string');
    }
    return DirectTcpHostConnection(
      id: id,
      endpoint: endpoint,
      useTls: (useTls as bool?) ?? false,
      password: password as String?,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': wireType,
    'endpoint': endpoint,
    'useTls': useTls,
    if (password != null) 'password': password,
  };
}

final class DirectSocketHostConnection extends HostConnection {
  const DirectSocketHostConnection({required super.id, required this.path});

  static const typeValue = 'directSocket';

  @override
  String get wireType => typeValue;

  final String path;

  factory DirectSocketHostConnection.fromJson(Map<String, Object?> json) {
    if (json['type'] != typeValue) {
      throw const FormatException('type must be directSocket');
    }
    return DirectSocketHostConnection(
      id: _requiredString(json, 'id'),
      path: _requiredString(json, 'path'),
    );
  }

  @override
  Map<String, Object?> toJson() => {'id': id, 'type': wireType, 'path': path};
}

final class DirectPipeHostConnection extends HostConnection {
  const DirectPipeHostConnection({required super.id, required this.path});

  static const typeValue = 'directPipe';

  @override
  String get wireType => typeValue;

  final String path;

  factory DirectPipeHostConnection.fromJson(Map<String, Object?> json) {
    if (json['type'] != typeValue) {
      throw const FormatException('type must be directPipe');
    }
    return DirectPipeHostConnection(
      id: _requiredString(json, 'id'),
      path: _requiredString(json, 'path'),
    );
  }

  @override
  Map<String, Object?> toJson() => {'id': id, 'type': wireType, 'path': path};
}

final class RelayHostConnection extends HostConnection {
  const RelayHostConnection({
    required super.id,
    required this.relayEndpoint,
    required this.daemonPublicKeyB64,
    this.useTls,
  });

  static const typeValue = 'relay';

  @override
  String get wireType => typeValue;

  final String relayEndpoint;
  final bool? useTls;
  final String daemonPublicKeyB64;

  factory RelayHostConnection.fromJson(Map<String, Object?> json) {
    if (json['type'] != typeValue) {
      throw const FormatException('type must be relay');
    }
    final useTls = json['useTls'];
    if (useTls != null && useTls is! bool) {
      throw const FormatException('useTls must be a boolean');
    }
    return RelayHostConnection(
      id: _requiredString(json, 'id'),
      relayEndpoint: _requiredString(json, 'relayEndpoint'),
      daemonPublicKeyB64: _requiredString(json, 'daemonPublicKeyB64'),
      useTls: useTls as bool?,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'type': wireType,
    'relayEndpoint': relayEndpoint,
    if (useTls != null) 'useTls': useTls,
    'daemonPublicKeyB64': daemonPublicKeyB64,
  };
}

final class HostProfile {
  const HostProfile({
    required this.serverId,
    required this.label,
    required this.connections,
    required this.preferredConnectionId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String serverId;
  final String label;
  final List<HostConnection> connections;
  final String? preferredConnectionId;
  final String createdAt;
  final String updatedAt;

  factory HostProfile.fromJson(Map<String, Object?> json) {
    final rawConnections = json['connections'];
    if (rawConnections is! List) {
      throw const FormatException('connections must be an array');
    }
    final connections = rawConnections
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException('connection must be an object');
          }
          return HostConnection.fromJson(entry.cast<String, Object?>());
        })
        .toList(growable: false);
    if (connections.isEmpty) {
      throw const FormatException('connections must not be empty');
    }
    final preferred = json['preferredConnectionId'];
    if (preferred != null && preferred is! String) {
      throw const FormatException(
        'preferredConnectionId must be a string or null',
      );
    }
    return HostProfile(
      serverId: _requiredString(json, 'serverId'),
      label: _requiredString(json, 'label'),
      connections: connections,
      preferredConnectionId: preferred as String?,
      createdAt: _requiredString(json, 'createdAt'),
      updatedAt: _requiredString(json, 'updatedAt'),
    );
  }

  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'label': label,
    'lifecycle': const <String, Object?>{},
    'connections': connections.map((entry) => entry.toJson()).toList(),
    'preferredConnectionId': preferredConnectionId,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  HostProfile copyWith({
    String? serverId,
    String? label,
    List<HostConnection>? connections,
    String? preferredConnectionId,
    bool clearPreferredConnectionId = false,
    String? createdAt,
    String? updatedAt,
  }) {
    return HostProfile(
      serverId: serverId ?? this.serverId,
      label: label ?? this.label,
      connections: connections ?? this.connections,
      preferredConnectionId: clearPreferredConnectionId
          ? null
          : preferredConnectionId ?? this.preferredConnectionId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

String normalizeHostLabel(String? value, String serverId) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? serverId : trimmed;
}

List<T> orderHostsLocalFirst<T extends HostProfile>(
  List<T> hosts,
  String? localServerId,
) {
  if (localServerId == null) return hosts;
  final index = hosts.indexWhere((host) => host.serverId == localServerId);
  if (index <= 0) return hosts;
  return [hosts[index], ...hosts.take(index), ...hosts.skip(index + 1)];
}

String? resolveActiveHostServerId({
  required String? selectedServerId,
  required String? localServerId,
  required List<HostProfile> hosts,
  required List<HostProfile> orderedHosts,
}) {
  String? connected(String? serverId) =>
      serverId != null && hosts.any((host) => host.serverId == serverId)
      ? serverId
      : null;
  return connected(selectedServerId) ??
      connected(localServerId) ??
      (orderedHosts.isEmpty ? null : orderedHosts.first.serverId);
}

HostProfile? normalizeStoredHostProfile(Object? entry, {String? now}) {
  if (entry is! Map) return null;
  final json = entry.cast<Object?, Object?>();
  final serverId = json['serverId'];
  if (serverId is! String || serverId.trim().isEmpty) return null;
  final connections = <HostConnection>[];
  final rawConnections = json['connections'];
  if (rawConnections is List) {
    for (final raw in rawConnections) {
      final normalized = _normalizeStoredConnection(raw);
      if (normalized != null) connections.add(normalized);
    }
  }
  if (connections.isEmpty) return null;
  final preferred = json['preferredConnectionId'];
  final preferredId =
      preferred is String &&
          connections.any((connection) => connection.id == preferred)
      ? preferred
      : connections.first.id;
  final timestamp = now ?? DateTime.now().toUtc().toIso8601String();
  return HostProfile(
    serverId: serverId.trim(),
    label: normalizeHostLabel(
      json['label'] is String ? json['label']! as String : null,
      serverId.trim(),
    ),
    connections: connections,
    preferredConnectionId: preferredId,
    createdAt: json['createdAt'] is String
        ? json['createdAt']! as String
        : timestamp,
    updatedAt: json['updatedAt'] is String
        ? json['updatedAt']! as String
        : timestamp,
  );
}

bool hostHasConnection(HostProfile host, HostConnection connection) => host
    .connections
    .any((existing) => hostConnectionEquals(existing, connection));

bool registryHasConnection(
  List<HostProfile> hosts,
  HostConnection connection,
) => hosts.any((host) => hostHasConnection(host, connection));

HostConnection? connectionFromListen(String listen) {
  final normalized = listen.trim();
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('pipe://')) {
    final path = normalized.substring('pipe://'.length).trim();
    return path.isEmpty
        ? null
        : DirectPipeHostConnection(id: 'pipe:$path', path: path);
  }
  if (normalized.startsWith('unix://')) {
    final path = normalized.substring('unix://'.length).trim();
    return path.isEmpty
        ? null
        : DirectSocketHostConnection(id: 'socket:$path', path: path);
  }
  if (normalized.startsWith(r'\\.\pipe\')) {
    return DirectPipeHostConnection(id: 'pipe:$normalized', path: normalized);
  }
  if (normalized.startsWith('/')) {
    return DirectSocketHostConnection(
      id: 'socket:$normalized',
      path: normalized,
    );
  }
  try {
    final endpoint = normalizeLoopbackToLocalhost(
      normalizeHostPort(normalized),
    );
    return DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint);
  } on FormatException {
    return null;
  }
}

List<HostProfile> upsertHostConnectionInProfiles({
  required List<HostProfile> profiles,
  required String serverId,
  String? label,
  required HostConnection connection,
  required String now,
}) {
  final normalizedServerId = serverId.trim();
  if (normalizedServerId.isEmpty) {
    throw const FormatException('serverId is required');
  }
  final indexes = <int>[];
  for (var index = 0; index < profiles.length; index++) {
    final profile = profiles[index];
    if (profile.serverId == normalizedServerId ||
        profile.connections.any(
          (existing) => hostConnectionEquals(existing, connection),
        )) {
      indexes.add(index);
    }
  }
  if (indexes.isEmpty) {
    return [
      ...profiles,
      HostProfile(
        serverId: normalizedServerId,
        label: normalizeHostLabel(label, normalizedServerId),
        connections: [connection],
        preferredConnectionId: connection.id,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  final matches = indexes.map((index) => profiles[index]).toList();
  final previous = matches.firstWhere(
    (profile) => profile.serverId == normalizedServerId,
    orElse: () => matches.first,
  );
  final connections = <HostConnection>[];
  for (final candidate in [
    ...matches.expand((profile) => profile.connections),
    connection,
  ]) {
    if (!connections.any(
      (existing) => hostConnectionEquals(existing, candidate),
    )) {
      connections.add(candidate);
    }
  }
  final preferred =
      previous.preferredConnectionId != null &&
          connections.any((entry) => entry.id == previous.preferredConnectionId)
      ? previous.preferredConnectionId
      : connection.id;
  final createdAt = matches
      .map((profile) => profile.createdAt)
      .reduce((left, right) => left.compareTo(right) <= 0 ? left : right);
  final nextProfile = HostProfile(
    serverId: normalizedServerId,
    label: previous.label == previous.serverId
        ? normalizeHostLabel(label, normalizedServerId)
        : previous.label,
    connections: connections,
    preferredConnectionId: preferred,
    createdAt: createdAt,
    updatedAt: now,
  );
  final firstIndex = indexes.first;
  final matching = indexes.toSet();
  final next = <HostProfile>[];
  for (var index = 0; index < profiles.length; index++) {
    if (index == firstIndex) next.add(nextProfile);
    if (!matching.contains(index)) next.add(profiles[index]);
  }
  return next;
}

bool hostConnectionEquals(HostConnection left, HostConnection right) {
  if (left.wireType != right.wireType || left.id != right.id) return false;
  return switch ((left, right)) {
    (DirectTcpHostConnection l, DirectTcpHostConnection r) =>
      l.endpoint == r.endpoint &&
          l.useTls == r.useTls &&
          l.password == r.password,
    (DirectSocketHostConnection l, DirectSocketHostConnection r) =>
      l.path == r.path,
    (DirectPipeHostConnection l, DirectPipeHostConnection r) =>
      l.path == r.path,
    (RelayHostConnection l, RelayHostConnection r) =>
      l.relayEndpoint == r.relayEndpoint &&
          l.useTls == r.useTls &&
          l.daemonPublicKeyB64 == r.daemonPublicKeyB64,
    _ => false,
  };
}

HostConnection? _normalizeStoredConnection(Object? entry) {
  if (entry is! Map) return null;
  final json = entry.cast<Object?, Object?>();
  final type = json['type'];
  try {
    if (type == DirectTcpHostConnection.type) {
      final rawEndpoint = json['endpoint'];
      if (rawEndpoint is! String) return null;
      final endpoint = normalizeLoopbackToLocalhost(
        normalizeHostPort(rawEndpoint),
      );
      final useTls = json['useTls'];
      final password = json['password'];
      if (useTls != null && useTls is! bool) return null;
      if (password != null && password is! String) return null;
      return DirectTcpHostConnection(
        id: 'direct:$endpoint',
        endpoint: endpoint,
        useTls: useTls as bool? ?? false,
        password: password as String?,
      );
    }
    if (type == DirectSocketHostConnection.typeValue) {
      final path = json['path'];
      if (path is! String || path.trim().isEmpty) return null;
      return DirectSocketHostConnection(
        id: 'socket:${path.trim()}',
        path: path.trim(),
      );
    }
    if (type == DirectPipeHostConnection.typeValue) {
      final path = json['path'];
      if (path is! String || path.trim().isEmpty) return null;
      return DirectPipeHostConnection(
        id: 'pipe:${path.trim()}',
        path: path.trim(),
      );
    }
    if (type == RelayHostConnection.typeValue) {
      final rawEndpoint = json['relayEndpoint'];
      final key = json['daemonPublicKeyB64'];
      final useTls = json['useTls'];
      if (rawEndpoint is! String ||
          key is! String ||
          key.trim().isEmpty ||
          (useTls != null && useTls is! bool)) {
        return null;
      }
      final endpoint = normalizeHostPort(rawEndpoint);
      return RelayHostConnection(
        id: useTls == true ? 'relay:wss:$endpoint' : 'relay:$endpoint',
        relayEndpoint: endpoint,
        useTls: useTls as bool?,
        daemonPublicKeyB64: key.trim(),
      );
    }
  } on FormatException {
    return null;
  }
  return null;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}
