import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/daemon_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('top-level daemon shortcuts expose command help', () async {
    for (final command in const ['start', 'status', 'restart']) {
      final output = StringBuffer();
      expect(
        await runDaemonCommand(
          arguments: [command, '--help'],
          topLevel: true,
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('coding-agent $command'));
    }

    final nested = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: const ['--help'],
        writeOutput: nested.write,
      ),
      0,
    );
    expect(nested.toString(), contains('coding-agent daemon <'));
  });

  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('daemon-command-test-');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test(
    'start forwards Paseo daemon flags and reports direct human result',
    () async {
      late List<String> arguments;
      late Map<String, String> environment;
      final output = StringBuffer();
      final code = await runDaemonCommand(
        arguments: [
          'start',
          '--home',
          home.path,
          '--port',
          '7777',
          '--no-relay',
          '--relay-use-tls',
          '--no-mcp',
          '--no-inject-mcp',
          '--web-ui',
          '--hostnames',
          'host,.example.com',
        ],
        runtime: DaemonCommandRuntime(
          resolveExe: () async => 'daemon.exe',
          start:
              ({
                required exePath,
                required paths,
                required host,
                required port,
                required additionalArguments,
                required additionalEnvironment,
                required timeout,
              }) async {
                expect(exePath, 'daemon.exe');
                expect(paths.dataDir, p.normalize(p.absolute(home.path)));
                expect(host, '127.0.0.1');
                expect(port, 7777);
                arguments = additionalArguments;
                environment = additionalEnvironment;
                return const ServerHello(
                  daemonVersion: '0.2.0',
                  protocolVersion: paseoWebSocketProtocolVersion,
                  pid: 42,
                );
              },
          environment: const {},
        ),
        writeOutput: output.write,
      );

      expect(code, 0);
      expect(
        arguments,
        containsAll([
          '--no-relay',
          '--relay-use-tls',
          '--no-mcp',
          '--no-inject-mcp',
          '--web-ui',
          '--hostnames',
          'host,.example.com',
        ]),
      );
      expect(environment['TINYRACK_LISTEN'], '127.0.0.1:7777');
      expect(output.toString(), contains('PID 42'));
      expect(output.toString(), contains('Logs:'));
    },
  );

  test('start rejects conflicting listen and port', () async {
    final errors = StringBuffer();
    final code = await runDaemonCommand(
      arguments: [
        'start',
        '--home',
        home.path,
        '--listen',
        '127.0.0.1:1',
        '--port',
        '2',
      ],
      writeError: errors.write,
    );

    expect(code, 1);
    expect(errors.toString(), contains('Cannot use --listen and --port'));
  });

  test(
    'status classifies missing local daemon and emits Paseo JSON shape',
    () async {
      await File(p.join(home.path, 'config.json')).writeAsString(
        jsonEncode({
          'version': 1,
          'daemon': {'listen': '127.0.0.1:0'},
        }),
      );
      final output = StringBuffer();
      final code = await runDaemonCommand(
        arguments: ['status', '--home', home.path, '--json'],
        runtime: const DaemonCommandRuntime(environment: {}),
        writeOutput: output.write,
      );

      expect(code, 0);
      final result = jsonDecode(output.toString()) as Map<String, dynamic>;
      expect(result['localDaemon'], 'stopped');
      expect(result['connectedDaemon'], 'unreachable');
      expect(result['home'], p.normalize(p.absolute(home.path)));
      expect(result['cliVersion'], '0.2.0');
      expect(result['providers'], hasLength(3));
    },
  );

  test('status trusts PID lock endpoint and renders human rows', () async {
    await File(p.join(home.path, 'daemon.pid')).writeAsString(
      jsonEncode({
        'pid': pid,
        'startedAtMs': DateTime.now().millisecondsSinceEpoch,
        'host': '127.0.0.1',
        'port': 0,
        'version': '0.2.0',
        'desktopManaged': true,
      }),
    );
    await File(p.join(home.path, 'server-id')).writeAsString('server-test\n');
    final output = StringBuffer();
    final code = await runDaemonCommand(
      arguments: ['status', '--home', home.path],
      runtime: DaemonCommandRuntime(
        environment: const {},
        resolveRuntimeExecutable: (processId) async {
          expect(processId, pid);
          return 'daemon-runtime.exe';
        },
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(output.toString(), contains('Local Daemon'));
    expect(output.toString(), contains('unresponsive'));
    expect(output.toString(), contains('127.0.0.1:0'));
    expect(output.toString(), contains('server-test'));
    expect(output.toString(), contains('daemon-runtime.exe'));
    expect(output.toString(), contains('Providers'));
  });

  test('runtime toolchain rejects invalid process ids', () async {
    expect(await resolveDaemonRuntimeExecutable(0), isNull);
  });

  test('stop maps lifecycle outcome and force flag', () async {
    await File(p.join(home.path, 'daemon.pid')).writeAsString(
      jsonEncode({
        'pid': pid,
        'startedAtMs': DateTime.now().millisecondsSinceEpoch,
        'host': '127.0.0.2',
        'port': 43210,
        'version': '0.2.0',
        'desktopManaged': true,
      }),
    );
    var stopped = false;
    var forced = false;
    final output = StringBuffer();
    final code = await runDaemonCommand(
      arguments: [
        'stop',
        '--home',
        home.path,
        '--timeout',
        '0.25',
        '--kill-timeout',
        '0.1',
        '--force',
        '--json',
      ],
      runtime: DaemonCommandRuntime(
        stop:
            ({
              required paths,
              required host,
              required port,
              required token,
              required force,
              required exitWait,
            }) async {
              stopped = true;
              forced = force;
              expect(host, '127.0.0.2');
              expect(port, 43210);
              expect(token, 'daemon-secret');
              expect(exitWait, const Duration(milliseconds: 250));
            },
        environment: const {'TINYRACK_PASSWORD': 'daemon-secret'},
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(stopped, isTrue);
    expect(forced, isTrue);
    expect(jsonDecode(output.toString()), containsPair('action', 'stopped'));
  });

  test('restart stops then starts with the same resolved home', () async {
    final calls = <String>[];
    final output = StringBuffer();
    final code = await runDaemonCommand(
      arguments: ['restart', '--home', home.path, '--port', '7788', '--json'],
      runtime: DaemonCommandRuntime(
        resolveExe: () async => 'daemon.exe',
        stop:
            ({
              required paths,
              required host,
              required port,
              required token,
              required force,
              required exitWait,
            }) async {
              calls.add('stop:${paths.dataDir}');
            },
        start:
            ({
              required exePath,
              required paths,
              required host,
              required port,
              required additionalArguments,
              required additionalEnvironment,
              required timeout,
            }) async {
              calls.add('start:${paths.dataDir}:$port');
              return const ServerHello(
                daemonVersion: '0.2.0',
                protocolVersion: paseoWebSocketProtocolVersion,
                pid: 99,
              );
            },
        environment: const {},
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(calls, [
      'stop:${p.normalize(p.absolute(home.path))}',
      'start:${p.normalize(p.absolute(home.path))}:7788',
    ]);
    expect(jsonDecode(output.toString()), containsPair('pid', '99'));
  });

  test('restart retries a timed out stop with force', () async {
    final forces = <bool>[];
    final output = StringBuffer();
    final code = await runDaemonCommand(
      arguments: ['restart', '--home', home.path, '--json'],
      runtime: DaemonCommandRuntime(
        resolveExe: () async => 'daemon.exe',
        stop:
            ({
              required paths,
              required host,
              required port,
              required token,
              required force,
              required exitWait,
            }) async {
              forces.add(force);
              if (!force)
                throw TimeoutException('Timed out waiting for daemon PID');
            },
        start:
            ({
              required exePath,
              required paths,
              required host,
              required port,
              required additionalArguments,
              required additionalEnvironment,
              required timeout,
            }) async => const ServerHello(
              daemonVersion: '0.2.0',
              protocolVersion: paseoWebSocketProtocolVersion,
            ),
        environment: const {},
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(forces, [false, true]);
    expect(output.toString(), contains('"pid": "-"'));
  });

  test('set-password preserves config and stores only a bcrypt hash', () async {
    await File(p.join(home.path, 'config.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'daemon': {
          'listen': '127.0.0.1:0',
          'relay': {'enabled': false},
        },
        'custom': 'preserved',
      }),
    );
    final answers = <String?>['secret', 'secret'];
    final output = StringBuffer();
    final code = await runDaemonCommand(
      arguments: ['set-password', '--home', home.path, '--json'],
      runtime: DaemonCommandRuntime(
        readPassword: (_) async => answers.removeAt(0),
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    final config =
        jsonDecode(await File(p.join(home.path, 'config.json')).readAsString())
            as Map<String, dynamic>;
    expect(config['custom'], 'preserved');
    expect(config['daemon']['relay']['enabled'], isFalse);
    final hash = config['daemon']['auth']['password'] as String;
    expect(hash, startsWith(r'$2'));
    expect(hash, isNot(contains('secret')));
    expect(
      jsonDecode(output.toString()),
      containsPair('action', 'password_set'),
    );
  });

  test('password mismatch and invalid timeout are command errors', () async {
    final errors = StringBuffer();
    final answers = <String?>['one', 'two'];
    expect(
      await runDaemonCommand(
        arguments: ['set-password', '--home', home.path],
        runtime: DaemonCommandRuntime(
          readPassword: (_) async => answers.removeAt(0),
        ),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('Passwords do not match'));

    errors.clear();
    expect(
      await runDaemonCommand(
        arguments: ['stop', '--timeout', 'zero'],
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('Invalid timeout value'));
  });

  test('result actions support frozen shared output modes', () async {
    final statusYaml = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: ['status', '--home', home.path, '--format', 'yaml'],
        runtime: const DaemonCommandRuntime(environment: {}),
        writeOutput: statusYaml.write,
      ),
      0,
    );
    expect(statusYaml.toString(), startsWith('serverId:'));
    expect(statusYaml.toString(), contains('providers:\n'));
    expect(statusYaml.toString(), isNot(contains('key: Server ID')));

    final stopQuiet = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: ['stop', '--home', home.path, '--quiet'],
        runtime: DaemonCommandRuntime(
          stop:
              ({
                required paths,
                required host,
                required port,
                required token,
                required force,
                required exitWait,
              }) async {},
          environment: const {},
        ),
        writeOutput: stopQuiet.write,
      ),
      0,
    );
    expect(stopQuiet.toString(), 'not_running\n');

    final passwordYaml = StringBuffer();
    final answers = <String?>['secret', 'secret'];
    expect(
      await runDaemonCommand(
        arguments: ['set-password', '--home', home.path, '-oyaml'],
        runtime: DaemonCommandRuntime(
          readPassword: (_) async => answers.removeAt(0),
        ),
        writeOutput: passwordYaml.write,
      ),
      0,
    );
    expect(passwordYaml.toString(), startsWith('action: password_set\n'));

    final restartNoHeaders = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: [
          'restart',
          '--home',
          home.path,
          '--no-headers',
          '--no-color',
        ],
        runtime: DaemonCommandRuntime(
          resolveExe: () async => 'daemon.exe',
          stop:
              ({
                required paths,
                required host,
                required port,
                required token,
                required force,
                required exitWait,
              }) async {},
          start:
              ({
                required exePath,
                required paths,
                required host,
                required port,
                required additionalArguments,
                required additionalEnvironment,
                required timeout,
              }) async => const ServerHello(
                daemonVersion: '0.2.0',
                protocolVersion: paseoWebSocketProtocolVersion,
                pid: 77,
              ),
          environment: const {},
        ),
        writeOutput: restartNoHeaders.write,
      ),
      0,
    );
    expect(restartNoHeaders.toString(), isNot(contains('STATUS')));
    expect(restartNoHeaders.toString(), contains('restarted'));
  });

  test('result action errors honor YAML and frozen codes', () async {
    final error = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: ['stop', '--timeout', 'zero', '--format=yaml'],
        writeError: error.write,
      ),
      1,
    );
    expect(error.toString(), startsWith('error:\n  code: INVALID_TIMEOUT\n'));
    expect(
      error.toString(),
      contains('details: timeout must be a positive number of seconds\n'),
    );

    error.clear();
    expect(
      await runDaemonCommand(
        arguments: [
          'restart',
          '--home',
          home.path,
          '--listen',
          '127.0.0.1:1',
          '--port',
          '2',
          '-oyaml',
        ],
        runtime: DaemonCommandRuntime(
          stop:
              ({
                required paths,
                required host,
                required port,
                required token,
                required force,
                required exitWait,
              }) async {},
          environment: const {},
        ),
        writeError: error.write,
      ),
      1,
    );
    expect(error.toString(), contains('code: INVALID_OPTIONS\n'));
  });

  test('daemon parser preserves action-specific output boundaries', () async {
    for (final arguments in const [
      ['start', '--json'],
      ['start', '--quiet'],
      ['pair', '--format', 'yaml'],
      ['status', '--force'],
      ['set-password', '--timeout', '1'],
      ['restart', '--kill-timeout', '1'],
      ['status', '--format'],
      ['status', '--format', 'xml'],
    ]) {
      expect(
        await runDaemonCommand(arguments: arguments, writeError: (_) {}),
        64,
        reason: '$arguments',
      );
    }
  });

  test(
    'human start, stop, and set-password outputs match command contract',
    () async {
      final output = StringBuffer();
      expect(
        await runDaemonCommand(
          arguments: ['start', '--home', home.path],
          runtime: DaemonCommandRuntime(
            resolveExe: () async => 'daemon.exe',
            start:
                ({
                  required exePath,
                  required paths,
                  required host,
                  required port,
                  required additionalArguments,
                  required additionalEnvironment,
                  required timeout,
                }) async => const ServerHello(
                  daemonVersion: '0.2.0',
                  protocolVersion: paseoWebSocketProtocolVersion,
                ),
            environment: const {},
          ),
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('PID unknown'));
      expect(output.toString(), contains('Logs:'));

      output.clear();
      expect(
        await runDaemonCommand(
          arguments: ['stop', '--home', home.path, '--force'],
          runtime: DaemonCommandRuntime(
            stop:
                ({
                  required paths,
                  required host,
                  required port,
                  required token,
                  required force,
                  required exitWait,
                }) async {},
            environment: const {},
          ),
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('Daemon is not running'));

      output.clear();
      final answers = <String?>['secret', 'secret'];
      expect(
        await runDaemonCommand(
          arguments: ['set-password', '--home', home.path],
          runtime: DaemonCommandRuntime(
            readPassword: (_) async => answers.removeAt(0),
          ),
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('coding-agent daemon restart'));
    },
  );

  test(
    'dispatch and option failures use stable exit codes and messages',
    () async {
      final errors = StringBuffer();
      expect(
        await runDaemonCommand(arguments: [], writeError: errors.write),
        64,
      );
      expect(errors.toString(), contains('daemon <start|status'));

      errors.clear();
      expect(
        await runDaemonCommand(
          arguments: ['unknown'],
          writeError: errors.write,
        ),
        64,
      );
      expect(errors.toString(), contains('Unknown daemon command'));

      for (final arguments in [
        ['start', '--home'],
        ['start', '--listen'],
        ['start', '--port', '99999'],
        ['start', '--hostnames'],
        ['start', '--allowed-hosts'],
        ['start', '--wat'],
      ]) {
        errors.clear();
        expect(
          await runDaemonCommand(
            arguments: arguments,
            writeError: errors.write,
          ),
          64,
        );
        expect(errors, isNotEmpty);
      }
    },
  );

  test('pair disabled and launch failures are normalized', () async {
    await File(p.join(home.path, 'config.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'daemon': {
          'listen': '127.0.0.1:0',
          'relay': {'enabled': false},
        },
      }),
    );
    final errors = StringBuffer();
    expect(
      await runDaemonCommand(
        arguments: ['pair', '--home', home.path, '--json'],
        runtime: const DaemonCommandRuntime(environment: {}),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('Relay pairing is disabled'));

    errors.clear();
    expect(
      await runDaemonCommand(
        arguments: ['start', '--home', home.path],
        runtime: DaemonCommandRuntime(resolveExe: () async => null),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('Could not find the daemon executable'));

    errors.clear();
    expect(
      await runDaemonCommand(
        arguments: ['start', '--home', home.path],
        runtime: DaemonCommandRuntime(
          resolveExe: () async => 'daemon.exe',
          start:
              ({
                required exePath,
                required paths,
                required host,
                required port,
                required additionalArguments,
                required additionalEnvironment,
                required timeout,
              }) async => throw DaemonSpawnException('spawn failed'),
        ),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('spawn failed'));
  });
}
