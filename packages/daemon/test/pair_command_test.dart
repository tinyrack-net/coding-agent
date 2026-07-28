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

  test('pairing instructions show QR only with sufficient terminal width', () {
    expect(
      formatPairingInstructions(url: url, qr: qr, columns: 7),
      allOf(contains(qr), contains('\n$url\n')),
    );
    final narrow = formatPairingInstructions(url: url, qr: qr, columns: 6);
    expect(narrow, isNot(contains(qr)));
    expect(narrow, contains('at least 7 columns'));
    expect(
      formatPairingInstructions(url: url, qr: qr, columns: null),
      contains('terminal width could not be detected'),
    );
    expect(
      formatPairingInstructions(url: url, qr: null, columns: 100),
      contains('QR code is unavailable'),
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
