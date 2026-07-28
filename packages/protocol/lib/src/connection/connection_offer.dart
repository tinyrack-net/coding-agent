import 'dart:convert';

final class ConnectionOfferRelay {
  const ConnectionOfferRelay({required this.endpoint, this.useTls});

  final String endpoint;
  final bool? useTls;

  factory ConnectionOfferRelay.fromJson(Map<String, Object?> json) {
    final endpoint = json['endpoint'];
    if (endpoint is! String || endpoint.isEmpty) {
      throw const FormatException('relay.endpoint must be a non-empty string');
    }
    final useTls = json['useTls'];
    if (useTls != null && useTls is! bool) {
      throw const FormatException('relay.useTls must be a boolean');
    }
    return ConnectionOfferRelay(endpoint: endpoint, useTls: useTls as bool?);
  }

  Map<String, Object?> toJson() => {
    'endpoint': endpoint,
    if (useTls != null) 'useTls': useTls,
  };
}

/// Relay-only v2 QR pairing offer.
final class ConnectionOffer {
  const ConnectionOffer({
    required this.serverId,
    required this.daemonPublicKeyB64,
    required this.relay,
  });

  static const int version = 2;

  final String serverId;
  final String daemonPublicKeyB64;
  final ConnectionOfferRelay relay;

  factory ConnectionOffer.fromJson(Map<String, Object?> json) {
    if (json['v'] != version) {
      throw const FormatException('Connection offer version must be 2');
    }
    final serverId = json['serverId'];
    if (serverId is! String || serverId.isEmpty) {
      throw const FormatException('serverId must be a non-empty string');
    }
    final publicKey = json['daemonPublicKeyB64'];
    if (publicKey is! String || publicKey.isEmpty) {
      throw const FormatException(
        'daemonPublicKeyB64 must be a non-empty string',
      );
    }
    final relay = json['relay'];
    if (relay is! Map) {
      throw const FormatException('relay must be an object');
    }
    return ConnectionOffer(
      serverId: serverId,
      daemonPublicKeyB64: publicKey,
      relay: ConnectionOfferRelay.fromJson(relay.cast<String, Object?>()),
    );
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'serverId': serverId,
    'daemonPublicKeyB64': daemonPublicKeyB64,
    'relay': relay.toJson(),
  };
}

/// Encodes a v2 offer in Paseo's fragment-only pairing URL format.
String encodeConnectionOfferToFragmentUrl(
  ConnectionOffer offer,
  String appBaseUrl,
) {
  final json = jsonEncode(offer.toJson());
  final encoded = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  final base = appBaseUrl.endsWith('/')
      ? appBaseUrl.substring(0, appBaseUrl.length - 1)
      : appBaseUrl;
  return '$base/#offer=$encoded';
}

Object? decodeOfferFragmentPayload(String encoded) {
  try {
    final normalized = base64Url.normalize(encoded);
    final json = utf8.decode(
      base64Url.decode(normalized),
      allowMalformed: false,
    );
    return jsonDecode(json);
  } on Object catch (error) {
    throw FormatException('Invalid connection offer payload', error);
  }
}

ConnectionOffer? parseConnectionOfferFromUrl(String input) {
  const prefix = '#offer=';
  final trimmed = input.trim();
  final fragmentIndex = trimmed.indexOf(prefix);
  if (fragmentIndex < 0) return null;
  final encoded = trimmed.substring(fragmentIndex + prefix.length).trim();
  if (encoded.isEmpty) return null;
  final payload = decodeOfferFragmentPayload(encoded);
  if (payload is! Map) {
    throw const FormatException('Connection offer payload must be an object');
  }
  return ConnectionOffer.fromJson(payload.cast<String, Object?>());
}
