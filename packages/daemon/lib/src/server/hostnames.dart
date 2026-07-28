import 'dart:io';

/// Paseo's Vite-style hostname configuration: `true`, a string list, or null.
typedef HostnamesConfig = Object?;

bool isHostnameAllowed(String? hostHeader, HostnamesConfig hostnames) {
  final hostname = _parseHostnameFromHostHeader(hostHeader);
  if (hostname == null) return false;
  if (hostnames == true) return true;
  if (_isDefaultAllowedHostname(hostname)) return true;

  if (hostnames is List) {
    for (final pattern in hostnames.whereType<String>()) {
      if (_matchesHostnamePattern(hostname, pattern)) return true;
    }
  }
  return false;
}

HostnamesConfig mergeHostnames(Iterable<HostnamesConfig> values) {
  final merged = <String>[];
  for (final value in values) {
    if (value == true) return true;
    if (value is! List) continue;
    merged.addAll(value.whereType<String>());
  }
  return List<String>.unmodifiable({
    for (final value in merged.map((value) => value.trim()))
      if (value.isNotEmpty) value,
  });
}

HostnamesConfig parseHostnamesEnv(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (trimmed.toLowerCase() == 'true') return true;
  return List<String>.unmodifiable(
    trimmed
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty),
  );
}

HostnamesConfig parsePersistedHostnames(Object? value, String path) {
  if (value == null || value == true) return value;
  if (value is List && value.every((item) => item is String)) {
    return List<String>.unmodifiable(value.cast<String>());
  }
  throw FormatException('$path must be true or a string array');
}

String? _parseHostnameFromHostHeader(String? hostHeader) {
  final trimmed = hostHeader?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('[')) {
    final end = trimmed.indexOf(']');
    if (end == -1) return null;
    return _normalizeHostname(trimmed.substring(1, end));
  }
  final colon = trimmed.indexOf(':');
  return _normalizeHostname(
    colon == -1 ? trimmed : trimmed.substring(0, colon),
  );
}

String? _normalizeHostname(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

bool _matchesHostnamePattern(String hostname, String pattern) {
  final normalized = _normalizeHostname(pattern);
  if (normalized == null) return false;
  if (normalized.startsWith('.')) {
    final base = normalized.substring(1);
    if (base.isEmpty) return false;
    return hostname == base || hostname.endsWith('.$base');
  }
  return hostname == normalized;
}

bool _isDefaultAllowedHostname(String hostname) =>
    hostname == 'localhost' ||
    hostname.endsWith('.localhost') ||
    InternetAddress.tryParse(hostname) != null;
