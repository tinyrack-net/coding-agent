enum RelayConnectionRole {
  server('server'),
  client('client');

  const RelayConnectionRole(this.wireValue);
  final String wireValue;

  static RelayConnectionRole parse(String value) => switch (value) {
    'server' => server,
    'client' => client,
    _ => throw FormatException('Unknown relay connection role: $value'),
  };
}

final class RelaySessionAttachment {
  const RelaySessionAttachment({
    required this.serverId,
    required this.role,
    required this.createdAt,
    this.version,
    this.connectionId,
  });

  final String serverId;
  final RelayConnectionRole role;
  final int createdAt;
  final String? version;
  final String? connectionId;

  factory RelaySessionAttachment.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version != null && version != '1' && version != '2') {
      throw FormatException('Unknown relay protocol version: $version');
    }
    return RelaySessionAttachment(
      serverId: json['serverId']! as String,
      role: RelayConnectionRole.parse(json['role']! as String),
      version: version as String?,
      connectionId: json['connectionId'] as String?,
      createdAt: (json['createdAt']! as num).toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'role': role.wireValue,
    if (version != null) 'version': version,
    if (connectionId != null) 'connectionId': connectionId,
    'createdAt': createdAt,
  };
}
