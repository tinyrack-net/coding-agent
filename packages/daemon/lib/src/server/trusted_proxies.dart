import 'dart:io';

import 'package:shelf/shelf.dart';

typedef TrustedProxiesConfig = Object;

const TrustedProxiesConfig defaultTrustedProxies = <String>['loopback'];

TrustedProxiesConfig parseTrustedProxiesEnv(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return defaultTrustedProxies;
  switch (trimmed.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return const <String>[];
  }
  return _validateProxyList(
    trimmed
        .split(',')
        .map((proxy) => proxy.trim())
        .where((proxy) => proxy.isNotEmpty)
        .toList(growable: false),
    'TINYRACK_TRUSTED_PROXIES',
  );
}

TrustedProxiesConfig parsePersistedTrustedProxies(Object? value) {
  if (value == null) return defaultTrustedProxies;
  if (value == true) return true;
  if (value is List && value.every((item) => item is String)) {
    return _validateProxyList(
      value.cast<String>().toList(growable: false),
      'daemon.trustedProxies',
    );
  }
  throw const FormatException(
    'daemon.trustedProxies must be true or a string array',
  );
}

bool isTrustedProxy(
  InternetAddress address,
  TrustedProxiesConfig trustedProxies,
) {
  if (trustedProxies == true) return true;
  for (final entry in (trustedProxies as List<String>)) {
    for (final range in _expandProxyEntry(entry)) {
      if (_matchesRange(address, range)) return true;
    }
  }
  return false;
}

String effectiveRequestScheme(
  Request request,
  TrustedProxiesConfig trustedProxies,
) {
  final connectionInfo =
      request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
  if (connectionInfo == null ||
      !isTrustedProxy(connectionInfo.remoteAddress, trustedProxies)) {
    return request.requestedUri.scheme.isEmpty
        ? 'http'
        : request.requestedUri.scheme.toLowerCase();
  }
  final forwarded = request.headers['x-forwarded-proto']
      ?.split(',')
      .first
      .trim()
      .toLowerCase();
  return forwarded == null || forwarded.isEmpty
      ? (request.requestedUri.scheme.isEmpty
            ? 'http'
            : request.requestedUri.scheme.toLowerCase())
      : forwarded;
}

List<String> _validateProxyList(List<String> values, String path) {
  final normalized = <String>[];
  for (final raw in values) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) continue;
    try {
      _expandProxyEntry(value);
    } on FormatException {
      throw FormatException('Invalid $path entry: $raw');
    }
    normalized.add(value);
  }
  return List.unmodifiable(normalized);
}

List<_AddressRange> _expandProxyEntry(String entry) {
  return switch (entry.toLowerCase()) {
    'loopback' => [
      _AddressRange.parse('127.0.0.0/8'),
      _AddressRange.parse('::1/128'),
    ],
    'linklocal' => [
      _AddressRange.parse('169.254.0.0/16'),
      _AddressRange.parse('fe80::/10'),
    ],
    'uniquelocal' => [
      _AddressRange.parse('10.0.0.0/8'),
      _AddressRange.parse('172.16.0.0/12'),
      _AddressRange.parse('192.168.0.0/16'),
      _AddressRange.parse('fc00::/7'),
    ],
    _ => [_AddressRange.parse(entry)],
  };
}

bool _matchesRange(InternetAddress address, _AddressRange range) {
  final bytes = address.rawAddress;
  if (bytes.length != range.bytes.length) return false;
  var remaining = range.prefix;
  for (var index = 0; index < bytes.length; index++) {
    if (remaining <= 0) return true;
    final bits = remaining >= 8 ? 8 : remaining;
    final mask = (0xff << (8 - bits)) & 0xff;
    if ((bytes[index] & mask) != (range.bytes[index] & mask)) return false;
    remaining -= bits;
  }
  return true;
}

class _AddressRange {
  const _AddressRange(this.bytes, this.prefix);

  factory _AddressRange.parse(String value) {
    final parts = value.split('/');
    if (parts.length > 2) throw const FormatException();
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) throw const FormatException();
    final maxPrefix = address.rawAddress.length * 8;
    final prefix = parts.length == 1 ? maxPrefix : int.tryParse(parts.last);
    if (prefix == null || prefix < 0 || prefix > maxPrefix) {
      throw const FormatException();
    }
    return _AddressRange(address.rawAddress, prefix);
  }

  final List<int> bytes;
  final int prefix;
}
