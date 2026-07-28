import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  const secretKeyB64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
  const publicKeyB64 = 'j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8=';
  const peerPublicKeyB64 = 'NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ=';
  const sharedKeyB64 = 'Qpth9dluNyaN/FEUhJ1ZnJzqv/22jB9SzQSZrzD1s3c=';
  const nonceB64 = 'ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7';
  const bundleB64 =
      'ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7'
      'n3TCMpQNwXrrEYx2F92ayLXiGLHbIVzNm5EuJxNI0f4lMw==';

  test('matches a libsodium/TweetNaCl Curve25519 shared-key vector', () {
    final pair = RelayKeyPair.fromSecretKey(base64.decode(secretKeyB64));
    expect(exportRelayPublicKey(pair.publicKey), publicKeyB64);
    expect(
      base64.encode(
        deriveRelaySharedKey(
          secretKey: pair.secretKey,
          peerPublicKey: importRelayPublicKey(peerPublicKeyB64),
        ),
      ),
      sharedKeyB64,
    );
  });

  test('matches the Paseo nonce+ciphertext XSalsa20-Poly1305 vector', () {
    final sharedKey = base64.decode(sharedKeyB64);
    final encrypted = encryptRelayPayload(
      sharedKey,
      'Paseo relay parity',
      nonce: base64.decode(nonceB64),
    );
    expect(base64.encode(encrypted), bundleB64);
    expect(
      decryptRelayPayload(sharedKey, base64.decode(bundleB64)),
      'Paseo relay parity',
    );
  });

  test('preserves plaintext bytes that are not valid UTF-8', () {
    final sharedKey = Uint8List(32);
    final encrypted = encryptRelayPayload(
      sharedKey,
      Uint8List.fromList([0xff, 0xfe, 0xfd]),
      nonce: Uint8List(24),
    );
    expect(
      decryptRelayPayload(sharedKey, encrypted),
      orderedEquals([0xff, 0xfe, 0xfd]),
    );
  });

  test('generates valid keys and validates key and bundle boundaries', () {
    final pair = RelayKeyPair.generate();
    expect(pair.publicKey, hasLength(relayPublicKeyLength));
    expect(pair.secretKey, hasLength(relaySecretKeyLength));
    expect(
      importRelaySecretKey(exportRelaySecretKey(pair.secretKey)),
      pair.secretKey,
    );

    for (final action in <void Function()>[
      () => importRelayPublicKey('bad'),
      () => importRelayPublicKey(base64.encode([1, 2])),
      () => exportRelayPublicKey(Uint8List(2)),
      () => importRelaySecretKey('bad'),
      () => importRelaySecretKey(base64.encode([1, 2])),
      () => exportRelaySecretKey(Uint8List(2)),
      () => deriveRelaySharedKey(
        secretKey: Uint8List(2),
        peerPublicKey: Uint8List(32),
      ),
      () => deriveRelaySharedKey(
        secretKey: Uint8List(32),
        peerPublicKey: Uint8List(2),
      ),
      () => encryptRelayPayload(Uint8List(2), 'x'),
      () => encryptRelayPayload(Uint8List(32), 'x', nonce: Uint8List(2)),
      () => encryptRelayPayload(Uint8List(32), Object()),
      () => decryptRelayPayload(Uint8List(2), Uint8List(24)),
      () => decryptRelayPayload(Uint8List(32), Uint8List(23)),
    ]) {
      expect(action, throwsA(anything));
    }
  });
}
