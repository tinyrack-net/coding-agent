import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

String _encode(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

void main() {
  const payload = {
    'v': 2,
    'serverId': 'server-123',
    'daemonPublicKeyB64': 'pubkey',
    'relay': {'endpoint': 'relay.tinyrack.dev:443'},
  };

  test('decodes base64url JSON payloads', () {
    expect(decodeOfferFragmentPayload(_encode(payload)), payload);
  });

  test('parses QR-style connection offers', () {
    final offer = parseConnectionOfferFromUrl(
      'https://app.tinyrack.dev/#offer=${_encode(payload)}',
    );
    expect(offer, isNotNull);
    expect(offer!.serverId, 'server-123');
    expect(offer.daemonPublicKeyB64, 'pubkey');
    expect(offer.relay.endpoint, 'relay.tinyrack.dev:443');
    expect(offer.relay.useTls, isNull);
    expect(offer.toJson(), payload);
  });

  test('encodes v2 offers as unpadded fragment URLs', () {
    final offer = ConnectionOffer.fromJson(payload);
    final url = encodeConnectionOfferToFragmentUrl(
      offer,
      'https://app.tinyrack.dev/',
    );

    expect(url, startsWith('https://app.tinyrack.dev/#offer='));
    expect(url.split('#offer=').last, isNot(contains('=')));
    expect(parseConnectionOfferFromUrl(url)?.toJson(), payload);
  });

  test('keeps supported fields and ignores future relay fields', () {
    final offer = parseConnectionOfferFromUrl(
      'https://app.tinyrack.dev/#offer=${_encode({
        ...payload,
        'relay': {'endpoint': 'relay.example.com:443', 'useTls': true, 'extra': 'future'},
      })}',
    );
    expect(offer!.relay.endpoint, 'relay.example.com:443');
    expect(offer.relay.useTls, isTrue);
    expect(offer.relay.toJson().containsKey('extra'), isFalse);
  });

  test('returns null without an offer fragment', () {
    expect(
      parseConnectionOfferFromUrl('https://app.tinyrack.dev/pair'),
      isNull,
    );
    expect(
      parseConnectionOfferFromUrl('https://app.tinyrack.dev/#offer='),
      isNull,
    );
  });

  test('rejects malformed and unsupported offers', () {
    expect(
      () => parseConnectionOfferFromUrl(
        'https://app.tinyrack.dev/#offer=${_encode({...payload, 'v': 1})}',
      ),
      throwsFormatException,
    );
    expect(() => decodeOfferFragmentPayload('%%%'), throwsFormatException);
    expect(
      () => parseConnectionOfferFromUrl(
        'https://app.tinyrack.dev/#offer=${_encode(['not', 'an', 'object'])}',
      ),
      throwsFormatException,
    );
  });
}
