const paseoWebSocketProtocolVersion = 1;

enum WebSocketClientType {
  mobile,
  browser,
  cli,
  mcp;

  static WebSocketClientType fromWire(Object? value) {
    if (value is! String) {
      throw const FormatException('clientType is required');
    }
    try {
      return values.byName(value);
    } catch (_) {
      throw FormatException('Unknown clientType: $value');
    }
  }
}

class WebSocketHello {
  const WebSocketHello({
    required this.clientId,
    required this.clientType,
    required this.protocolVersion,
    this.appVersion,
    this.capabilities = const {},
  });

  final String clientId;
  final WebSocketClientType clientType;
  final int protocolVersion;
  final String? appVersion;
  final Map<String, Object?> capabilities;

  static WebSocketHello fromJson(Map<String, Object?> json) {
    if (json['type'] != 'hello') {
      throw const FormatException('Expected hello message');
    }
    final clientId = json['clientId'];
    final protocolVersion = json['protocolVersion'];
    final capabilities = json['capabilities'];
    if (clientId is! String || clientId.trim().isEmpty) {
      throw const FormatException('clientId is required');
    }
    if (protocolVersion is! num || protocolVersion.toInt() != protocolVersion) {
      throw const FormatException('protocolVersion must be an integer');
    }
    if (capabilities != null && capabilities is! Map<String, Object?>) {
      throw const FormatException('capabilities must be an object');
    }
    return WebSocketHello(
      clientId: clientId.trim(),
      clientType: WebSocketClientType.fromWire(json['clientType']),
      protocolVersion: protocolVersion.toInt(),
      appVersion: json['appVersion'] as String?,
      capabilities: Map.unmodifiable(
        capabilities as Map<String, Object?>? ?? const {},
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'hello',
    'clientId': clientId,
    'clientType': clientType.name,
    'protocolVersion': protocolVersion,
    if (appVersion != null) 'appVersion': appVersion,
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
  };
}

class ServerInfoStatus {
  const ServerInfoStatus({
    required this.serverId,
    required this.hostname,
    required this.version,
    required this.desktopManaged,
    this.capabilities = const {},
    this.features = const {},
  });

  final String serverId;
  final String? hostname;
  final String? version;
  final bool desktopManaged;
  final Map<String, Object?> capabilities;
  final Map<String, bool> features;

  static ServerInfoStatus fromJson(Map<String, Object?> json) {
    if (json['status'] != 'server_info') {
      throw const FormatException('Expected server_info status');
    }
    final serverId = json['serverId'];
    if (serverId is! String || serverId.trim().isEmpty) {
      throw const FormatException('serverId is required');
    }
    return ServerInfoStatus(
      serverId: serverId.trim(),
      hostname: _trimmedString(json['hostname']),
      version: _trimmedString(json['version']),
      desktopManaged: json['desktopManaged'] == true,
      capabilities: Map.unmodifiable(
        json['capabilities'] as Map<String, Object?>? ?? const {},
      ),
      features: Map.unmodifiable(
        (json['features'] as Map<String, Object?>? ?? const {}).map(
          (key, value) => MapEntry(key, value == true),
        ),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'status': 'server_info',
    'serverId': serverId,
    'hostname': hostname,
    'version': version,
    'desktopManaged': desktopManaged,
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
    'features': features,
  };
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
