import 'package:bcrypt/bcrypt.dart';

const daemonPasswordBcryptCost = 12;
final _bcryptHashPattern = RegExp(r'^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$');

bool isDaemonPasswordHash(String value) => _bcryptHashPattern.hasMatch(value);

String hashDaemonPassword(String password) {
  if (password.trim().isEmpty) {
    throw const FormatException('Daemon password must not be empty');
  }
  return BCrypt.hashpw(
    password,
    BCrypt.gensalt(logRounds: daemonPasswordBcryptCost),
  );
}

bool isBearerTokenValid({String? passwordHash, String? token}) {
  if (passwordHash == null) return true;
  if (token == null) return false;
  try {
    return BCrypt.checkpw(token, passwordHash);
  } catch (_) {
    return false;
  }
}

String? extractHttpBearerToken(String? value) {
  if (value == null) return null;
  final parts = value.trim().split(RegExp(r'\s+'));
  if (parts.length != 2 || parts.first != 'Bearer' || parts.last.isEmpty) {
    return null;
  }
  return parts.last;
}

String? extractWsBearerProtocol(String? value) {
  if (value == null) return null;
  for (final candidate in value.split(',')) {
    final protocol = candidate.trim();
    final parts = protocol.split('.');
    if (parts.length >= 3 &&
        (parts[0] == 'paseo' || parts[0] == 'tinyrack') &&
        parts[1] == 'bearer') {
      return protocol;
    }
  }
  return null;
}

String? extractWsBearerToken(String? protocol) {
  if (protocol == null) return null;
  final parts = protocol.split('.');
  if (parts.length < 3 ||
      (parts[0] != 'paseo' && parts[0] != 'tinyrack') ||
      parts[1] != 'bearer') {
    return null;
  }
  return parts.sublist(2).join('.');
}

bool shouldBypassBearerAuth(String method, String path) =>
    method == 'OPTIONS' ||
    path == '/api/health' ||
    path == '/api/files/download' ||
    path == '/mcp/agents';
