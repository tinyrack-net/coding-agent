final class DaemonGetPairingOfferRequest {
  const DaemonGetPairingOfferRequest({required this.requestId});

  static const type = 'daemon.get_pairing_offer.request';
  final String requestId;

  factory DaemonGetPairingOfferRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected daemon pairing offer request');
    }
    final requestId = json['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    return DaemonGetPairingOfferRequest(requestId: requestId);
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class DaemonGetPairingOfferResponse {
  const DaemonGetPairingOfferResponse({
    required this.requestId,
    required this.url,
    required this.relayEnabled,
    this.qr,
  });

  static const type = 'daemon.get_pairing_offer.response';
  final String requestId;
  final String url;
  final String? qr;
  final bool relayEnabled;

  factory DaemonGetPairingOfferResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected daemon pairing offer response');
    }
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const FormatException('payload must be an object');
    }
    final requestId = payload['requestId'];
    final url = payload['url'];
    final qr = payload['qr'];
    final relayEnabled = payload['relayEnabled'];
    if (requestId is! String ||
        url is! String ||
        (qr != null && qr is! String) ||
        relayEnabled is! bool) {
      throw const FormatException('Invalid daemon pairing offer response');
    }
    return DaemonGetPairingOfferResponse(
      requestId: requestId,
      url: url,
      qr: qr as String?,
      relayEnabled: relayEnabled,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'url': url,
      if (qr != null) 'qr': qr,
      'relayEnabled': relayEnabled,
    },
  };
}
