import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_daemon/src/server/daemon_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('daemon-identity-');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  test('creates and reloads a short stable server id', () {
    final created = getOrCreateServerId(
      home.path,
      environment: const {},
      random: Random(42),
    );
    final reloaded = getOrCreateServerId(home.path, environment: const {});

    expect(created, matches(RegExp(r'^srv_[A-Za-z0-9_-]{12}$')));
    expect(reloaded, created);
    expect(
      File(p.join(home.path, daemonServerIdFileName)).readAsStringSync(),
      '$created\n',
    );
  });

  test('uses and persists TINYRACK_SERVER_ID when identity is missing', () {
    final id = getOrCreateServerId(
      home.path,
      environment: const {'TINYRACK_SERVER_ID': ' srv_override '},
    );

    expect(id, 'srv_override');
    expect(
      File(p.join(home.path, daemonServerIdFileName)).readAsStringSync(),
      'srv_override\n',
    );
  });

  test(
    'environment identity does not overwrite an existing persisted file',
    () {
      final file = File(p.join(home.path, daemonServerIdFileName))
        ..writeAsStringSync('srv_saved\n');

      expect(
        getOrCreateServerId(
          home.path,
          environment: const {'TINYRACK_SERVER_ID': 'srv_runtime'},
        ),
        'srv_runtime',
      );
      expect(file.readAsStringSync(), 'srv_saved\n');
    },
  );

  test('creates and reloads a validated daemon keypair', () {
    final created = loadOrCreateDaemonKeyPair(home.path);
    final reloaded = loadOrCreateDaemonKeyPair(home.path);

    expect(reloaded.publicKeyB64, created.publicKeyB64);
    expect(reloaded.keyPair.secretKey, created.keyPair.secretKey);
    expect(
      importRelayPublicKey(reloaded.publicKeyB64),
      reloaded.keyPair.publicKey,
    );
    final stored =
        jsonDecode(
              File(p.join(home.path, daemonKeyPairFileName)).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(stored['v'], 2);
    expect(stored['publicKeyB64'], created.publicKeyB64);
  });

  test('regenerates malformed and mismatched daemon keypairs', () {
    final file = File(p.join(home.path, daemonKeyPairFileName))
      ..writeAsStringSync('{broken');
    final warnings = <String>[];
    final afterMalformed = loadOrCreateDaemonKeyPair(
      home.path,
      log: warnings.add,
    );
    expect(warnings, hasLength(1));

    final other = RelayKeyPair.generate();
    file.writeAsStringSync(
      jsonEncode({
        'v': 2,
        'publicKeyB64': exportRelayPublicKey(other.publicKey),
        'secretKeyB64': exportRelaySecretKey(afterMalformed.keyPair.secretKey),
      }),
    );
    final afterMismatch = loadOrCreateDaemonKeyPair(
      home.path,
      log: warnings.add,
    );

    expect(warnings, hasLength(2));
    expect(afterMismatch.publicKeyB64, isNot(afterMalformed.publicKeyB64));
  });
}
