import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('pairing request matches the frozen top-level request shape', () {
    const request = DaemonGetPairingOfferRequest(requestId: 'request-1');
    expect(request.toJson(), {
      'type': 'daemon.get_pairing_offer.request',
      'requestId': 'request-1',
    });
    expect(
      DaemonGetPairingOfferRequest.fromJson(request.toJson()).requestId,
      'request-1',
    );
  });

  test('pairing response round-trips URL, QR, and relay state', () {
    const response = DaemonGetPairingOfferResponse(
      requestId: 'request-1',
      url: 'https://app.tinyrack.dev/#offer=data',
      qr: 'qr',
      relayEnabled: true,
    );
    expect(
      DaemonGetPairingOfferResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
    expect(
      const DaemonGetPairingOfferResponse(
        requestId: 'request-2',
        url: '',
        relayEnabled: false,
      ).toJson(),
      {
        'type': 'daemon.get_pairing_offer.response',
        'payload': {'requestId': 'request-2', 'url': '', 'relayEnabled': false},
      },
    );
  });

  test('pairing messages reject malformed boundaries', () {
    expect(
      () => DaemonGetPairingOfferRequest.fromJson(const {
        'type': 'wrong',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => DaemonGetPairingOfferRequest.fromJson(const {
        'type': DaemonGetPairingOfferRequest.type,
        'requestId': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => DaemonGetPairingOfferResponse.fromJson(const {
        'type': DaemonGetPairingOfferResponse.type,
        'payload': {'requestId': 'r', 'url': '', 'relayEnabled': 'yes'},
      }),
      throwsFormatException,
    );
  });
}
