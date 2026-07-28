/// Paseo-compatible daemon and relay endpoint contracts.
library;

const String currentRelayProtocolVersion = '2';
const String defaultRelayEndpoint = 'relay.tinyrack.dev:443';

enum RelayRole {
  server,
  client;

  String get wireValue => name;
}

final class HostPortParts {
  const HostPortParts({
    required this.host,
    required this.port,
    required this.isIpv6,
  });

  final String host;
  final int port;
  final bool isIpv6;
}

final class ConnectionUriParts extends HostPortParts {
  const ConnectionUriParts({
    required super.host,
    required super.port,
    required super.isIpv6,
    required this.useTls,
    this.password,
  });

  final bool useTls;
  final String? password;
}

String normalizeRelayProtocolVersion(
  Object? value, {
  String fallback = currentRelayProtocolVersion,
}) {
  if (value == null) return fallback;
  final normalized = switch (value) {
    String() => value.trim(),
    num() => value.toString(),
    _ => '',
  };
  if (normalized.isEmpty) return fallback;
  if (normalized == '1' || normalized == '2') return normalized;
  throw const FormatException('Relay version must be "1" or "2"');
}

HostPortParts parseHostPort(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Host is required');
  }

  if (trimmed.startsWith('[')) {
    final match = RegExp(r'^\[([^\]]+)\]:(\d{1,5})$').firstMatch(trimmed);
    if (match == null) {
      throw const FormatException('Invalid host:port (expected [::1]:6767)');
    }
    final host = match.group(1)!.trim();
    if (host.isEmpty) throw const FormatException('Host is required');
    return HostPortParts(
      host: host,
      port: _parsePort(match.group(2)!, 'Invalid host:port'),
      isIpv6: true,
    );
  }

  final match = RegExp(r'^(.+):(\d{1,5})$').firstMatch(trimmed);
  if (match == null) {
    throw const FormatException('Invalid host:port (expected localhost:6767)');
  }
  final host = match.group(1)!.trim();
  if (host.isEmpty) throw const FormatException('Host is required');
  return HostPortParts(
    host: host,
    port: _parsePort(match.group(2)!, 'Invalid host:port'),
    isIpv6: false,
  );
}

String normalizeHostPort(String input) {
  final parts = parseHostPort(input);
  return parts.isIpv6
      ? '[${parts.host}]:${parts.port}'
      : '${parts.host}:${parts.port}';
}

ConnectionUriParts parseConnectionUri(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Connection URI is required');
  }

  late final Uri parsed;
  try {
    parsed = Uri.parse(trimmed);
  } on FormatException {
    throw const FormatException('Invalid connection URI');
  }
  if (parsed.scheme != 'tcp') {
    throw const FormatException('Connection URI protocol must be tcp:');
  }
  if (parsed.host.isEmpty) {
    throw const FormatException('Connection URI host is required');
  }
  if (!parsed.hasPort) {
    throw const FormatException('Connection URI port is required');
  }
  if (parsed.userInfo.isNotEmpty) {
    throw const FormatException('Connection URI userinfo is not supported');
  }

  final isIpv6 = parsed.host.contains(':');
  final password = parsed.queryParameters['password'];
  return ConnectionUriParts(
    host: parsed.host,
    port: _parsePort(parsed.port.toString(), 'Invalid connection URI'),
    isIpv6: isIpv6,
    useTls: parsed.queryParameters['ssl'] == 'true',
    password: password == null || password.isEmpty ? null : password,
  );
}

String serializeConnectionUri(ConnectionUriParts parts) =>
    _createConnectionUri(parts).toString();

String serializeConnectionUriForStorage(ConnectionUriParts parts) {
  final query = <String, String>{
    if (parts.useTls) 'ssl': 'true',
    if (parts.password case final password? when password.isNotEmpty)
      'password': password,
  };
  return _createConnectionUri(parts, queryParameters: query).toString();
}

String normalizeLoopbackToLocalhost(String endpoint) {
  final parts = parseHostPort(endpoint);
  if (parts.host == '127.0.0.1' ||
      (!parts.isIpv6 && parts.host == '0.0.0.0') ||
      (parts.isIpv6 && (parts.host == '::1' || parts.host == '::'))) {
    return 'localhost:${parts.port}';
  }
  return endpoint;
}

String deriveLabelFromEndpoint(String endpoint) {
  try {
    final host = parseHostPort(endpoint).host;
    return host.isEmpty ? 'Unnamed Host' : host;
  } on FormatException {
    return 'Unnamed Host';
  }
}

String buildDaemonWebSocketUrl(String endpoint, {required bool useTls}) {
  final parts = parseHostPort(endpoint);
  return Uri(
    scheme: useTls ? 'wss' : 'ws',
    host: parts.host,
    port: parts.port,
    path: '/ws',
  ).toString();
}

String buildRelayWebSocketUrl({
  required String endpoint,
  required bool useTls,
  required String serverId,
  required RelayRole role,
  String? connectionId,
  Object? version,
}) {
  final parts = parseHostPort(endpoint);
  return Uri(
    scheme: useTls ? 'wss' : 'ws',
    host: parts.host,
    port: parts.port,
    path: '/ws',
    queryParameters: {
      'serverId': serverId,
      'role': role.wireValue,
      'v': normalizeRelayProtocolVersion(version),
      if (connectionId != null && connectionId.isNotEmpty)
        'connectionId': connectionId,
    },
  ).toString();
}

@Deprecated('Migration fallback for connection offers without explicit TLS.')
bool shouldUseTlsForDefaultHostedRelay(String endpoint) {
  try {
    return parseHostPort(endpoint).port == 443;
  } on FormatException {
    return false;
  }
}

String extractHostPortFromWebSocketUrl(String wsUrl) {
  final parsed = Uri.parse(wsUrl);
  if (parsed.scheme != 'ws' && parsed.scheme != 'wss') {
    throw const FormatException('Invalid WebSocket URL protocol');
  }
  if (parsed.path.replaceAll(RegExp(r'/+$'), '') != '/ws') {
    throw const FormatException('Invalid WebSocket URL (expected /ws path)');
  }
  if (parsed.host.isEmpty) {
    throw const FormatException('Invalid WebSocket URL (missing hostname)');
  }
  final port = parsed.hasPort
      ? parsed.port
      : (parsed.scheme == 'wss' ? 443 : 80);
  if (port < 1 || port > 65535) {
    throw const FormatException('Invalid WebSocket URL (invalid port)');
  }
  return parsed.host.contains(':')
      ? '[${parsed.host}]:$port'
      : '${parsed.host}:$port';
}

bool isRelayClientWebSocketUrl(String url) {
  try {
    final parsed = Uri.parse(url);
    return parsed.queryParameters['role'] == 'client' &&
        parsed.queryParameters.containsKey('serverId');
  } on FormatException {
    return false;
  }
}

int _parsePort(String value, String context) {
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException('$context: port must be between 1 and 65535');
  }
  return port;
}

Uri _createConnectionUri(
  ConnectionUriParts parts, {
  Map<String, String>? queryParameters,
}) {
  final query =
      queryParameters ?? <String, String>{if (parts.useTls) 'ssl': 'true'};
  return Uri(
    scheme: 'tcp',
    host: parts.host,
    port: parts.port,
    queryParameters: query.isEmpty ? null : query,
  );
}
