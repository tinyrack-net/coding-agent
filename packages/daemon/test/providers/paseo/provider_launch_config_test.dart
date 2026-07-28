import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/executable_resolver.dart';
import 'package:agent_daemon/src/providers/paseo/provider_launch_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ProviderCommand', () {
    test('round-trips frozen command modes', () {
      for (final json in [
        <String, Object?>{'mode': 'default'},
        <String, Object?>{
          'mode': 'append',
          'args': ['--chrome'],
        },
        <String, Object?>{
          'mode': 'replace',
          'argv': ['docker', 'run', 'claude'],
        },
      ]) {
        expect(ProviderCommand.fromJson(json).toJson(), json);
      }
    });

    test('rejects unknown and empty replacement commands', () {
      expect(
        () => ProviderCommand.fromJson(const {'mode': 'unknown'}),
        throwsFormatException,
      );
      expect(
        () => ProviderCommand.fromJson(const {
          'mode': 'replace',
          'argv': <Object?>[],
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderCommand.fromJson(const {
          'mode': 'append',
          'args': [1],
        }),
        throwsFormatException,
      );
    });

    test('runtime settings round-trip command, env, and tools', () {
      const json = <String, Object?>{
        'command': {
          'mode': 'replace',
          'argv': ['claude'],
        },
        'env': {'HOME': '/custom'},
        'disallowedTools': ['bash'],
      };

      expect(ProviderRuntimeSettings.fromJson(json).toJson(), json);
    });
  });

  group('resolveProviderCommandPrefix', () {
    test('uses the resolved default command in default mode', () async {
      var calls = 0;
      final resolved = await resolveProviderCommandPrefix(null, () async {
        calls++;
        return '/usr/local/bin/claude';
      });

      expect(calls, 1);
      expect(resolved.command, '/usr/local/bin/claude');
      expect(resolved.args, isEmpty);
      expect(resolved.source, ProviderLaunchSource.defaultSource);
    });

    test('appends args without changing the default command', () async {
      final resolved = await resolveProviderCommandPrefix(
        const ProviderCommand.append(['--chrome']),
        () async => '/usr/local/bin/claude',
      );

      expect(resolved.command, '/usr/local/bin/claude');
      expect(resolved.args, ['--chrome']);
      expect(resolved.source, ProviderLaunchSource.append);
    });

    test('replaces command without resolving the default', () async {
      var calls = 0;
      final resolved = await resolveProviderCommandPrefix(
        const ProviderCommand.replace(['docker', 'run', '--rm', 'wrapper']),
        () async {
          calls++;
          return 'claude';
        },
      );

      expect(calls, 0);
      expect(resolved.command, 'docker');
      expect(resolved.args, ['run', '--rm', 'wrapper']);
      expect(resolved.source, ProviderLaunchSource.override);
    });
  });

  group('resolveProviderLaunch', () {
    test('keeps default, append, and replace launch commands', () async {
      final fallback = await resolveProviderLaunch(defaultBinary: 'provider');
      final appended = await resolveProviderLaunch(
        commandConfig: const ProviderCommand.append(['--profile', 'work']),
        defaultBinary: const ProviderLaunchDefault(command: 'provider'),
      );
      final replaced = await resolveProviderLaunch(
        commandConfig: const ProviderCommand.replace(['shim', '--wrapped']),
      );

      expect(fallback.command, 'provider');
      expect(fallback.args, isEmpty);
      expect(appended.command, 'provider');
      expect(appended.args, ['--profile', 'work']);
      expect(replaced.command, 'shim');
      expect(replaced.args, ['--wrapped']);
    });

    test('requires a default and a non-empty replacement argv', () async {
      await expectLater(resolveProviderLaunch(), throwsStateError);
      await expectLater(
        resolveProviderLaunch(commandConfig: const ProviderCommand.replace([])),
        throwsFormatException,
      );
      await expectLater(
        resolveProviderLaunch(defaultBinary: 42),
        throwsArgumentError,
      );
    });
  });

  group('checkProviderLaunchAvailable', () {
    late Directory temporary;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('provider-launch-');
    });

    tearDown(() {
      temporary.deleteSync(recursive: true);
    });

    test('reports a resolved path and missing override', () async {
      final executable = File(p.join(temporary.path, 'provider.cmd'))
        ..writeAsStringSync('@echo version\r\n');
      final resolver = ExecutableResolver(
        environment: {'PATH': temporary.path, 'PATHEXT': '.CMD'},
        isWindows: true,
        probe: (path) async =>
            path.toLowerCase() == executable.path.toLowerCase(),
      );
      final available = await checkProviderLaunchAvailable(
        await resolveProviderLaunch(defaultBinary: 'provider'),
        executableResolver: resolver,
      );
      final missing = await checkProviderLaunchAvailable(
        await resolveProviderLaunch(
          commandConfig: const ProviderCommand.replace(['missing']),
        ),
        executableResolver: resolver,
      );

      expect(available.available, isTrue);
      expect(
        available.resolvedPath?.toLowerCase(),
        executable.path.toLowerCase(),
      );
      expect(missing.available, isFalse);
      expect(missing.resolvedPath, isNull);
    });

    test('uses a custom default path resolver outside override mode', () async {
      var calls = 0;
      final defaultBinary = ProviderLaunchDefault(
        command: 'provider',
        resolvePath: () async {
          calls++;
          return '/resolved/provider';
        },
      );
      final availability = await checkProviderLaunchAvailable(
        await resolveProviderLaunch(defaultBinary: defaultBinary),
        defaultBinary: defaultBinary,
      );

      expect(calls, 1);
      expect(availability.resolvedPath, '/resolved/provider');
    });

    test(
      'resolves a default descriptor without a custom path callback',
      () async {
        final executable = File(p.join(temporary.path, 'provider.cmd'))
          ..writeAsStringSync('@echo version\r\n');
        final resolver = ExecutableResolver(
          environment: {'PATH': temporary.path, 'PATHEXT': '.CMD'},
          isWindows: true,
          probe: (_) async => true,
        );
        const defaultBinary = ProviderLaunchDefault(command: 'provider');

        final availability = await checkProviderLaunchAvailable(
          await resolveProviderLaunch(defaultBinary: defaultBinary),
          defaultBinary: defaultBinary,
          executableResolver: resolver,
        );

        expect(
          availability.resolvedPath?.toLowerCase(),
          executable.path.toLowerCase(),
        );
      },
    );
  });

  group('provider environment', () {
    test('merges runtime and later overlays over the base', () {
      final environment = createProviderEnvironment(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'HOME': '/tmp',
          'REMOVE': 'base',
        },
        runtimeSettings: const ProviderRuntimeSettings(
          environment: {'HOME': '/custom/home', 'FOO': 'bar'},
        ),
        overlays: const [
          {'FOO': 'overlay', 'REMOVE': null},
        ],
      );

      expect(environment, {
        'PATH': '/usr/bin',
        'HOME': '/custom/home',
        'FOO': 'overlay',
      });
    });

    test('strips parent Claude and internal runtime controls', () {
      final environment = createProviderEnvironment(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'CLAUDECODE': '1',
          'CLAUDE_CODE_ENTRYPOINT': 'parent',
          'CLAUDE_CODE_SSE_PORT': '11803',
          'CLAUDE_AGENT_SDK_VERSION': '0.2.71',
          'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING': 'true',
          'PASEO_SUPERVISED': '1',
          'TINYRACK_SUPERVISED': '1',
          'ELECTRON_RUN_AS_NODE': '1',
        },
      );

      expect(environment, {
        'PATH': '/usr/bin',
        'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING': 'true',
      });
    });

    test('spec preserves null removals and optional base', () {
      final spec = createProviderEnvironmentSpec(
        runtimeSettings: const ProviderRuntimeSettings(
          environment: {'RUNTIME': 'yes'},
        ),
      );

      expect(spec.baseEnvironment, isNull);
      expect(spec.environmentOverlay['RUNTIME'], 'yes');
      for (final key in parentClaudeSessionEnvironmentVariables) {
        expect(spec.environmentOverlay, containsPair(key, null));
      }
    });

    test('shell environment is cached', () {
      expect(
        identical(resolveShellEnvironment(), resolveShellEnvironment()),
        isTrue,
      );
    });
  });

  group('settings migration', () {
    test('passes through new overrides and migrates legacy modes', () {
      final migrated = migrateProviderSettings(
        const {
          'zai': {
            'extends': 'claude',
            'label': 'ZAI',
            'command': ['zai'],
            'env': {'ZAI_KEY': 'secret'},
          },
          'claude': {
            'command': {
              'mode': 'replace',
              'argv': ['docker', 'run', 'claude'],
            },
          },
          'codex': {
            'command': {'mode': 'default'},
            'env': {'FOO': 'bar'},
          },
          'opencode': {
            'command': {
              'mode': 'append',
              'args': ['--debug'],
            },
          },
          'pi': {
            'disallowedTools': ['bash'],
          },
          'invalid': 'not-an-object',
        },
        const ['claude', 'codex', 'opencode'],
      );

      expect(migrated, {
        'zai': {
          'extends': 'claude',
          'label': 'ZAI',
          'command': ['zai'],
          'env': {'ZAI_KEY': 'secret'},
        },
        'claude': {
          'command': ['docker', 'run', 'claude'],
        },
        'codex': {
          'env': {'FOO': 'bar'},
        },
        'pi': {
          'disallowedTools': ['bash'],
        },
      });
    });

    test('maps current daemon overrides to runtime settings', () {
      final settings = providerRuntimeSettingsFromOverride(
        const MutableDaemonProviderConfig(
          extra: {
            'command': ['custom-codex', '--stdio'],
            'env': {'CODEX_HOME': '/custom'},
            'disallowedTools': ['bash'],
          },
        ),
      );

      expect(settings?.command?.mode, ProviderCommandMode.replace);
      expect(settings?.command?.argv, ['custom-codex', '--stdio']);
      expect(settings?.environment, {'CODEX_HOME': '/custom'});
      expect(settings?.disallowedTools, ['bash']);
      expect(providerRuntimeSettingsFromOverride(null), isNull);
      expect(
        () => providerRuntimeSettingsFromOverride(
          const MutableDaemonProviderConfig(
            extra: {
              'env': {'BAD': 1},
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('drops malformed legacy entries during migration', () {
      expect(
        migrateProviderSettings(const {
          'bad-command': {
            'command': {'mode': 'unknown'},
          },
          'bad-env': {
            'env': {'BAD': 1},
          },
        }, const []),
        isEmpty,
      );
    });
  });

  test('availability helper catches resolver failures', () async {
    expect(
      await isProviderCommandAvailable(null, () async => throw StateError('x')),
      isFalse,
    );
    expect(
      await isProviderCommandAvailable(
        const ProviderCommand.replace(['provider']),
        () async => throw StateError('must not run'),
        executableResolver: ExecutableResolver(
          environment: const {},
          isWindows: false,
          exists: (_) => true,
          probe: (_) async => true,
        ),
      ),
      isFalse,
    );
    expect(
      await isProviderCommandAvailable(
        const ProviderCommand.defaultMode(),
        () async => '/resolved/provider',
      ),
      isTrue,
    );
  });
}
