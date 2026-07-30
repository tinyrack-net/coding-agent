import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/pair_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const url = 'https://app.tinyrack.dev/#offer=pairing-offer';
  const qr =
      '\u001b[47m\u001b[30m      \u001b[0m\n'
      '\u001b[47m\u001b[30m ████ \u001b[0m\n'
      '\u001b[47m\u001b[30m      \u001b[0m';

  group('pairing instruction formatting', () {
    test('prints QR and an unmodified link when one spare column exists', () {
      expect(
        formatPairingInstructions(url: url, qr: qr, columns: 7),
        '\n'
        'Scan to pair:\n'
        '$qr\n'
        '\n'
        'Pairing link:\n'
        '$url\n',
      );
    });

    test('suppresses a QR that reaches the terminal edge', () {
      expect(
        formatPairingInstructions(url: url, qr: qr, columns: 6),
        '\n'
        'Scan to pair:\n'
        'QR code not shown. Resize the terminal to at least 7 columns, '
        'then run this command again.\n'
        '\n'
        'Pairing link:\n'
        '$url\n',
      );
    });

    test('suppresses QR when terminal width cannot be detected', () {
      expect(
        formatPairingInstructions(url: url, qr: qr, columns: null),
        '\n'
        'Scan to pair:\n'
        'QR code not shown because terminal width could not be detected.\n'
        '\n'
        'Pairing link:\n'
        '$url\n',
      );
    });

    test('uses the unavailable fallback for null and empty QR output', () {
      const expected =
          '\n'
          'Scan to pair:\n'
          'QR code is unavailable. Use the pairing link below.\n'
          '\n'
          'Pairing link:\n'
          '$url\n';
      expect(
        formatPairingInstructions(url: url, qr: null, columns: 100),
        expected,
      );
      expect(
        formatPairingInstructions(url: url, qr: '', columns: 100),
        expected,
      );
    });

    test('measures the widest visible line after removing ANSI styles', () {
      const unevenQr =
          '\u001b[47m  \u001b[0m\n'
          '\u001b[47m12345678\u001b[0m\n'
          '\u001b[47m    \u001b[0m';

      expect(
        formatPairingInstructions(url: url, qr: unevenQr, columns: 8),
        contains('Resize the terminal to at least 9 columns'),
      );
      expect(
        formatPairingInstructions(url: url, qr: unevenQr, columns: 9),
        contains(unevenQr),
      );
    });
  });

  test('pair command suppresses QR in a narrow terminal', () async {
    final home = Directory.systemTemp.createTempSync('pair-command-narrow-');
    addTearDown(() => home.deleteSync(recursive: true));
    final output = StringBuffer();

    final result = await runPairCommand(
      options: PairCommandOptions(home: home.path),
      environment: const {},
      fetchOffer: (_) async => const DaemonGetPairingOfferResponse(
        requestId: 'r',
        url: url,
        qr: qr,
        relayEnabled: true,
      ),
      writeOutput: output.write,
      terminalColumns: 6,
    );

    expect(result, 0);
    expect(
      output.toString(),
      '\n'
      'Scan to pair:\n'
      'QR code not shown. Resize the terminal to at least 7 columns, '
      'then run this command again.\n'
      '\n'
      'Pairing link:\n'
      '$url\n',
    );
  });

  test('pair command prefers daemon RPC and emits stable JSON', () async {
    final home = Directory.systemTemp.createTempSync('pair-command-');
    addTearDown(() => home.deleteSync(recursive: true));
    final output = StringBuffer();
    var fetchCount = 0;

    final result = await runPairCommand(
      options: PairCommandOptions(home: home.path, json: true),
      environment: const {},
      fetchOffer: (_) async {
        fetchCount += 1;
        return const DaemonGetPairingOfferResponse(
          requestId: 'r',
          url: url,
          qr: qr,
          relayEnabled: true,
        );
      },
      writeOutput: output.write,
    );

    expect(result, 0);
    expect(fetchCount, 1);
    final decoded = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(decoded, {'relayEnabled': true, 'url': url, 'qr': qr});
    expect(File(p.join(home.path, 'server-id')).existsSync(), isFalse);
  });

  test('pair command emits human instructions with a wide terminal', () async {
    final home = Directory.systemTemp.createTempSync('pair-command-');
    addTearDown(() => home.deleteSync(recursive: true));
    final output = StringBuffer();

    final result = await runPairCommand(
      options: PairCommandOptions(home: home.path),
      environment: const {},
      fetchOffer: (_) async => const DaemonGetPairingOfferResponse(
        requestId: 'r',
        url: url,
        qr: qr,
        relayEnabled: true,
      ),
      writeOutput: output.write,
      terminalColumns: 80,
    );

    expect(result, 0);
    expect(output.toString(), contains('Scan to pair:\n$qr'));
    expect(output.toString(), contains('Pairing link:\n$url'));
  });

  test('pair command reports disabled local relay with exit code 1', () async {
    final home = Directory.systemTemp.createTempSync('pair-command-');
    addTearDown(() => home.deleteSync(recursive: true));
    File(p.join(home.path, 'config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'version': 1,
          'daemon': {
            'relay': {'enabled': false},
          },
        }),
      );
    final errors = StringBuffer();

    final result = await runPairCommand(
      options: PairCommandOptions(home: home.path),
      environment: const {},
      fetchOffer: (_) async => null,
      writeError: errors.write,
    );

    expect(result, 1);
    expect(errors.toString(), contains('Relay pairing is disabled'));
    expect(File(p.join(home.path, 'server-id')).existsSync(), isFalse);
  });

  test('pair command falls back to locally generated offer', () async {
    final home = Directory.systemTemp.createTempSync('pair-command-');
    addTearDown(() => home.deleteSync(recursive: true));
    final output = StringBuffer();

    final result = await runPairCommand(
      options: PairCommandOptions(home: home.path, json: true),
      environment: const {'TINYRACK_SERVER_ID': 'srv_cli'},
      fetchOffer: (_) async => null,
      writeOutput: output.write,
    );

    expect(result, 0);
    final decoded = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(decoded['relayEnabled'], isTrue);
    expect(
      parseConnectionOfferFromUrl(decoded['url'] as String)?.serverId,
      'srv_cli',
    );
    expect(decoded['qr'], contains('\u001b[47m\u001b[30m'));
  });
}
