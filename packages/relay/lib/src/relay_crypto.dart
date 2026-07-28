import 'dart:convert';

import 'package:pinenacl/x25519.dart';

import 'relay_base64.dart';

const relayPublicKeyLength = 32;
const relaySecretKeyLength = 32;
const relaySharedKeyLength = 32;
const relayNonceLength = 24;

final class RelayKeyPair {
  RelayKeyPair._({required this.publicKey, required this.secretKey});

  factory RelayKeyPair.generate() {
    final privateKey = PrivateKey.generate();
    return RelayKeyPair._(
      publicKey: Uint8List.fromList(privateKey.publicKey),
      secretKey: Uint8List.fromList(privateKey),
    );
  }

  factory RelayKeyPair.fromSecretKey(Uint8List secretKey) {
    _requireLength(secretKey, relaySecretKeyLength, 'secret key');
    final privateKey = PrivateKey(Uint8List.fromList(secretKey));
    return RelayKeyPair._(
      publicKey: Uint8List.fromList(privateKey.publicKey),
      secretKey: Uint8List.fromList(secretKey),
    );
  }

  final Uint8List publicKey;
  final Uint8List secretKey;
}

String exportRelayPublicKey(Uint8List publicKey) {
  _requireLength(publicKey, relayPublicKeyLength, 'public key');
  return relayBase64Encode(publicKey);
}

Uint8List importRelayPublicKey(String encoded) {
  final Uint8List bytes;
  try {
    bytes = relayBase64Decode(encoded);
  } on FormatException catch (error) {
    throw FormatException('Invalid public key base64', encoded, error.offset);
  }
  _requireLength(bytes, relayPublicKeyLength, 'public key');
  return bytes;
}

String exportRelaySecretKey(Uint8List secretKey) {
  _requireLength(secretKey, relaySecretKeyLength, 'secret key');
  return relayBase64Encode(secretKey);
}

Uint8List importRelaySecretKey(String encoded) {
  final Uint8List bytes;
  try {
    bytes = relayBase64Decode(encoded);
  } on FormatException catch (error) {
    throw FormatException('Invalid secret key base64', encoded, error.offset);
  }
  _requireLength(bytes, relaySecretKeyLength, 'secret key');
  return bytes;
}

Uint8List deriveRelaySharedKey({
  required Uint8List secretKey,
  required Uint8List peerPublicKey,
}) {
  _requireLength(secretKey, relaySecretKeyLength, 'secret key');
  _requireLength(peerPublicKey, relayPublicKeyLength, 'peer public key');
  final box = Box(
    myPrivateKey: PrivateKey(Uint8List.fromList(secretKey)),
    theirPublicKey: PublicKey(Uint8List.fromList(peerPublicKey)),
  );
  return Uint8List.fromList(box.sharedKey);
}

/// Returns Paseo's exact `[nonce (24 bytes)] [ciphertext...]` binary bundle.
Uint8List encryptRelayPayload(
  Uint8List sharedKey,
  Object data, {
  Uint8List? nonce,
}) {
  _requireLength(sharedKey, relaySharedKeyLength, 'shared key');
  if (nonce != null) _requireLength(nonce, relayNonceLength, 'nonce');
  final plaintext = switch (data) {
    String() => Uint8List.fromList(utf8.encode(data)),
    Uint8List() => data,
    List<int>() => Uint8List.fromList(data),
    _ => throw ArgumentError.value(data, 'data', 'Expected text or bytes'),
  };
  final encrypted = Box.decode(
    Uint8List.fromList(sharedKey),
  ).encrypt(plaintext, nonce: nonce);
  return Uint8List.fromList(encrypted);
}

/// Returns text when the plaintext is valid UTF-8, otherwise raw bytes.
Object decryptRelayPayload(Uint8List sharedKey, Uint8List bundle) {
  _requireLength(sharedKey, relaySharedKeyLength, 'shared key');
  if (bundle.length < relayNonceLength) {
    throw const FormatException('Ciphertext bundle too short');
  }
  final plaintext = Box.decode(
    Uint8List.fromList(sharedKey),
  ).decrypt(EncryptedMessage.fromList(Uint8List.fromList(bundle)));
  try {
    return utf8.decode(plaintext, allowMalformed: false);
  } on FormatException {
    return Uint8List.fromList(plaintext);
  }
}

void _requireLength(Uint8List bytes, int expected, String name) {
  if (bytes.length != expected) {
    throw FormatException(
      'Invalid $name length (expected $expected, got ${bytes.length})',
    );
  }
}
