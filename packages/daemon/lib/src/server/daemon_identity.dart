import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:tinyrack_relay/tinyrack_relay.dart';

import 'private_files.dart';

const daemonServerIdFileName = 'server-id';
const daemonKeyPairFileName = 'daemon-keypair.json';

typedef DaemonLog = void Function(String message);

final class DaemonKeyPairBundle {
  const DaemonKeyPairBundle({
    required this.keyPair,
    required this.publicKeyB64,
  });

  final RelayKeyPair keyPair;
  final String publicKeyB64;
}

String getOrCreateServerId(
  String tinyrackHome, {
  Map<String, String>? environment,
  DaemonLog? log,
  Random? random,
}) {
  final env = environment ?? Platform.environment;
  final file = File(p.join(tinyrackHome, daemonServerIdFileName));
  final override = env['TINYRACK_SERVER_ID']?.trim();
  if (override != null && override.isNotEmpty) {
    if (!file.existsSync()) {
      try {
        writePrivateFileAtomic(file, '$override\n');
      } on Object catch (error) {
        log?.call('failed to persist TINYRACK_SERVER_ID override: $error');
      }
    } else {
      ensurePrivateFile(file);
    }
    return override;
  }

  if (file.existsSync()) {
    try {
      ensurePrivateFile(file);
      final persisted = file.readAsStringSync().trim();
      if (persisted.isNotEmpty) return persisted;
    } on Object catch (error) {
      log?.call('failed to read server-id file, regenerating: $error');
    }
  }

  final source = random ?? Random.secure();
  final bytes = List<int>.generate(9, (_) => source.nextInt(256));
  final created = 'srv_${base64Url.encode(bytes).replaceAll('=', '')}';
  try {
    writePrivateFileAtomic(file, '$created\n');
  } on Object catch (error) {
    log?.call('failed to persist server id: $error');
  }
  return created;
}

DaemonKeyPairBundle loadOrCreateDaemonKeyPair(
  String tinyrackHome, {
  DaemonLog? log,
}) {
  final file = File(p.join(tinyrackHome, daemonKeyPairFileName));
  if (file.existsSync()) {
    try {
      ensurePrivateFile(file);
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map ||
          decoded['v'] != 2 ||
          decoded['publicKeyB64'] is! String ||
          decoded['secretKeyB64'] is! String) {
        throw const FormatException('Invalid daemon keypair schema');
      }
      final secret = importRelaySecretKey(decoded['secretKeyB64'] as String);
      final persistedPublic = importRelayPublicKey(
        decoded['publicKeyB64'] as String,
      );
      final keyPair = RelayKeyPair.fromSecretKey(secret);
      if (!_constantTimeEquals(persistedPublic, keyPair.publicKey)) {
        throw const FormatException('Daemon public and secret keys mismatch');
      }
      return DaemonKeyPairBundle(
        keyPair: keyPair,
        publicKeyB64: exportRelayPublicKey(keyPair.publicKey),
      );
    } on Object catch (error) {
      log?.call('failed to load daemon keypair, regenerating: $error');
    }
  }

  final keyPair = RelayKeyPair.generate();
  final publicKeyB64 = exportRelayPublicKey(keyPair.publicKey);
  writePrivateFileAtomic(
    file,
    '${const JsonEncoder.withIndent('  ').convert({'v': 2, 'publicKeyB64': publicKeyB64, 'secretKeyB64': exportRelaySecretKey(keyPair.secretKey)})}\n',
  );
  return DaemonKeyPairBundle(keyPair: keyPair, publicKeyB64: publicKeyB64);
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
