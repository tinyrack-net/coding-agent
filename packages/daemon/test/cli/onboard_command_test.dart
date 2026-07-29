import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/onboard_command.dart';
import 'package:agent_daemon/src/server/pairing_offer.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'non-interactive onboarding starts, waits, pairs, and preserves config',
    () async {
      final home = Directory.systemTemp.createTempSync('onboard-success-');
      addTearDown(() => home.deleteSync(recursive: true));
      final configFile = File(p.join(home.path, 'config.json'));
      configFile.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'custom': {'preserve': true},
          'features': {
            'dictation': {
              'stt': {'provider': 'local'},
            },
            'voiceMode': {
              'tts': {'provider': 'local'},
            },
          },
        }),
      );

      Map<String, Object?>? started;
      var readyCalls = 0;
      var pairingCalls = 0;
      final probeTimeouts = <Duration>[];
      final output = StringBuffer();
      final error = StringBuffer();
      final code = await runOnboardCommand(
        arguments: [
          '--home',
          home.path,
          '--port',
          '7777',
          '--no-mcp',
          '--hostnames',
          'host,.example.test',
          '--timeout',
          '2.25',
        ],
        runtime: OnboardRuntime(
          environment: const {},
          inputIsTerminal: () => false,
          outputIsTerminal: () => false,
          terminalColumns: () => 120,
          promptVoice: () async => fail('non-interactive must not prompt'),
          resolveRunningDaemon: ({required home, required environment}) async =>
              null,
          startDaemon:
              ({
                required home,
                required listen,
                required port,
                required relayEnabled,
                required mcpEnabled,
                required hostnames,
                required environment,
              }) async {
                started = {
                  'home': home,
                  'listen': listen,
                  'port': port,
                  'relayEnabled': relayEnabled,
                  'mcpEnabled': mcpEnabled,
                  'hostnames': hostnames,
                  'environment': environment,
                };
                return OnboardDaemonStartResult(
                  pid: 42,
                  logPath: p.join(home, 'daemon.log'),
                );
              },
          probeReady:
              ({required home, required environment, required timeout}) async {
                probeTimeouts.add(timeout);
                return ++readyCalls >= 2 ? '127.0.0.1:7777' : null;
              },
          createPairingOffer: ({required config, required environment}) async {
            pairingCalls++;
            expect(config.listen, '127.0.0.1:7777');
            return const LocalPairingOffer(
              relayEnabled: true,
              url: 'https://app.tinyrack.dev/#pair',
              qr: 'QR',
            );
          },
          tailLog: (_, {required lines}) async =>
              'Downloading model artifact modelId=stt-small pct=37',
          delay: (_) async {},
          now: () => DateTime.utc(2026, 7, 30),
        ),
        writeOutput: output.write,
        writeError: error.write,
      );

      expect(code, 0);
      expect(error.toString(), isEmpty);
      expect(started, {
        'home': p.normalize(p.absolute(home.path)),
        'listen': null,
        'port': 7777,
        'relayEnabled': true,
        'mcpEnabled': false,
        'hostnames': 'host,.example.test',
        'environment': <String, String>{},
      });
      expect(readyCalls, 2);
      expect(probeTimeouts, everyElement(onboardReadyProbeTimeout));
      expect(pairingCalls, 1);
      expect(output.toString(), contains('Non-interactive terminal'));
      expect(output.toString(), contains('Downloading speech model'));
      expect(output.toString(), contains('Scan to pair:'));
      expect(output.toString(), contains('Tinyrack is ready!'));

      final persisted =
          jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
      expect(persisted['custom'], {'preserve': true});
      final features = persisted['features']! as Map;
      expect((features['dictation'] as Map)['enabled'], isFalse);
      expect((features['dictation'] as Map)['stt'], {'provider': 'local'});
      expect((features['voiceMode'] as Map)['enabled'], isFalse);
      expect((features['voiceMode'] as Map)['tts'], {'provider': 'local'});
    },
  );

  test(
    'saved voice and running daemon skip prompt, start, and pairing',
    () async {
      final home = Directory.systemTemp.createTempSync('onboard-running-');
      addTearDown(() => home.deleteSync(recursive: true));
      File(p.join(home.path, 'config.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'daemon': {
            'relay': {'enabled': false},
          },
          'features': {
            'voiceMode': {'enabled': true},
          },
        }),
      );
      final output = StringBuffer();
      final code = await runOnboardCommand(
        arguments: ['--home', home.path],
        runtime: OnboardRuntime(
          environment: const {},
          inputIsTerminal: () => true,
          outputIsTerminal: () => true,
          promptVoice: () async => fail('saved selection must not prompt'),
          resolveRunningDaemon: ({required home, required environment}) async =>
              const PidLockData(
                pid: 99,
                startedAtMs: 1,
                host: '127.0.0.1',
                port: 6868,
                version: '0.2.0',
                desktopManaged: false,
              ),
          startDaemon:
              ({
                required home,
                required listen,
                required port,
                required relayEnabled,
                required mcpEnabled,
                required hostnames,
                required environment,
              }) async => fail('running daemon must not start'),
          probeReady:
              ({required home, required environment, required timeout}) async =>
                  '127.0.0.1:6868',
          createPairingOffer: ({required config, required environment}) async =>
              fail('disabled relay must not pair'),
          tailLog: (_, {required lines}) async => null,
          delay: (_) async {},
        ),
        writeOutput: output.write,
      );

      expect(code, 0);
      expect(output.toString(), contains('Welcome to Tinyrack'));
      expect(output.toString(), contains('Using saved voice setup'));
      expect(output.toString(), contains('Daemon already running (PID 99)'));
      expect(output.toString(), contains('Relay is disabled'));
      expect(output.toString(), contains('Tinyrack daemon is running.'));
    },
  );

  test('interactive voice prompt supports enable and cancellation', () async {
    Future<(int, String, Map<String, Object?>)> run(bool? answer) async {
      final home = Directory.systemTemp.createTempSync('onboard-prompt-');
      addTearDown(() => home.deleteSync(recursive: true));
      final output = StringBuffer();
      final code = await runOnboardCommand(
        arguments: ['--home', home.path, '--voice', 'ask', '--no-relay'],
        runtime: OnboardRuntime(
          environment: const {},
          inputIsTerminal: () => true,
          outputIsTerminal: () => true,
          promptVoice: () async => answer,
          resolveRunningDaemon: ({required home, required environment}) async =>
              const PidLockData(
                pid: 1,
                startedAtMs: 1,
                host: '127.0.0.1',
                port: 6868,
                version: '0.2.0',
                desktopManaged: false,
              ),
          probeReady:
              ({required home, required environment, required timeout}) async =>
                  '127.0.0.1:6868',
          createPairingOffer: ({required config, required environment}) async =>
              fail('relay disabled'),
          tailLog: (_, {required lines}) async => null,
          delay: (_) async {},
        ),
        writeOutput: output.write,
      );
      final persisted =
          jsonDecode(File(p.join(home.path, 'config.json')).readAsStringSync())
              as Map<String, Object?>;
      return (code, output.toString(), persisted);
    }

    final enabled = await run(true);
    expect(enabled.$1, 0);
    expect(enabled.$2, contains('Voice features enabled'));
    expect(
      (((enabled.$3['features'] as Map)['voiceMode'] as Map)['enabled']),
      isTrue,
    );

    final cancelled = await run(null);
    expect(cancelled.$1, 0);
    expect(cancelled.$2, contains('Onboarding cancelled.'));
    expect(cancelled.$3['features'], isNull);
  });

  test('readiness timeout includes recent daemon logs', () async {
    final home = Directory.systemTemp.createTempSync('onboard-timeout-');
    addTearDown(() => home.deleteSync(recursive: true));
    var now = DateTime.utc(2026, 7, 30);
    final error = StringBuffer();
    final code = await runOnboardCommand(
      arguments: [
        '--home',
        home.path,
        '--voice',
        'disable',
        '--no-relay',
        '--timeout',
        '0.3',
      ],
      runtime: OnboardRuntime(
        environment: const {},
        inputIsTerminal: () => false,
        outputIsTerminal: () => false,
        resolveRunningDaemon: ({required home, required environment}) async =>
            const PidLockData(
              pid: 1,
              startedAtMs: 1,
              host: '127.0.0.1',
              port: 6868,
              version: '0.2.0',
              desktopManaged: false,
            ),
        probeReady:
            ({required home, required environment, required timeout}) async =>
                null,
        tailLog: (_, {required lines}) async => 'daemon still loading',
        delay: (duration) async => now = now.add(duration),
        now: () => now,
      ),
      writeOutput: (_) {},
      writeError: error.write,
    );

    expect(code, 1);
    expect(error.toString(), contains('Timed out after 1s'));
    expect(error.toString(), contains('Recent daemon logs:'));
    expect(error.toString(), contains('daemon still loading'));
  });

  test('help and invalid options fail before touching runtime', () async {
    var output = '';
    expect(
      await runOnboardCommand(
        arguments: const ['--help'],
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, contains('coding-agent onboard'));

    for (final arguments in <List<String>>[
      ['--listen', '127.0.0.1:1', '--port', '1'],
      ['--port', 'bad'],
      ['--timeout', '0'],
      ['--timeout', 'NaN'],
      ['--voice', 'maybe'],
      ['--hostnames'],
      ['--unknown'],
    ]) {
      var error = '';
      expect(
        await runOnboardCommand(
          arguments: arguments,
          writeError: (value) => error += value,
        ),
        64,
        reason: '$arguments',
      );
      expect(error, contains(onboardUsage), reason: '$arguments');
    }
  });

  test('download progress parser uses the latest frozen log shape', () {
    expect(
      parseOnboardDownloadProgress(
        'Downloading model artifact modelId=old pct=5\n'
        'noise\n'
        '{"message":"Downloading model artifact","modelId":"new","pct":87}',
      )?.message,
      'Downloading speech model (new): 87%',
    );
    expect(
      parseOnboardDownloadProgress('Downloading model artifact'),
      isA<OnboardDownloadProgress>()
          .having((value) => value.modelId, 'modelId', isNull)
          .having((value) => value.percentage, 'percentage', isNull),
    );
    expect(parseOnboardDownloadProgress('unrelated'), isNull);
  });
}
