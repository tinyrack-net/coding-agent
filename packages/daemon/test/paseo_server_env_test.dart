import 'dart:io';

import 'package:agent_daemon/src/paseo_server_env.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <Directory>[];

  Directory createTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    temporaryDirectories.add(dir);
    return dir;
  }

  tearDown(() {
    for (final dir in temporaryDirectories) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
    temporaryDirectories.clear();
  });

  // -------------------------------------------------------------------------
  // client-message-id.ts
  // -------------------------------------------------------------------------

  group('normalizeClientMessageId', () {
    test('returns null for missing, empty, and whitespace values', () {
      expect(normalizeClientMessageId(null), isNull);
      expect(normalizeClientMessageId(''), isNull);
      expect(normalizeClientMessageId('   '), isNull);
    });

    test('returns trimmed clientMessageId for non-empty values', () {
      expect(normalizeClientMessageId('client-msg-1'), 'client-msg-1');
      expect(normalizeClientMessageId('  client-msg-2  '), 'client-msg-2');
    });

    test('treats tabs and newlines as whitespace', () {
      expect(normalizeClientMessageId('\t\n\r '), isNull);
      expect(normalizeClientMessageId('\tclient-msg-3\n'), 'client-msg-3');
    });

    test('preserves interior whitespace and non-ascii payloads', () {
      expect(normalizeClientMessageId('  a b  '), 'a b');
      expect(normalizeClientMessageId(' 메시지-1 '), '메시지-1');
    });
  });

  group('resolveClientMessageId', () {
    test('preserves a non-empty clientMessageId', () {
      expect(
        resolveClientMessageId('client-msg-3', () => 'generated-id'),
        'client-msg-3',
      );
    });

    test('falls back to generated id for empty/whitespace/missing values', () {
      expect(
        resolveClientMessageId('', () => 'generated-empty'),
        'generated-empty',
      );
      expect(
        resolveClientMessageId('   ', () => 'generated-space'),
        'generated-space',
      );
      expect(
        resolveClientMessageId(null, () => 'generated-missing'),
        'generated-missing',
      );
    });

    test('returns the trimmed id rather than the raw one', () {
      expect(resolveClientMessageId('  padded  ', () => 'generated'), 'padded');
    });

    test('does not invoke the generator when an id is supplied', () {
      var calls = 0;
      final resolved = resolveClientMessageId('present', () {
        calls += 1;
        return 'generated';
      });
      expect(resolved, 'present');
      expect(calls, 0);
    });

    test('defaults to a unique uuid v4 generator', () {
      final first = resolveClientMessageId(null);
      final second = resolveClientMessageId(null);
      expect(first, isNot(second));
      expect(
        first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // daemon-version.ts
  // -------------------------------------------------------------------------

  group('resolveDaemonVersion', () {
    /// Writes a pubspec and returns a nested directory to start the walk from.
    String seedPackage(Directory root, String pubspec) {
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
      final nested = Directory(p.join(root.path, 'build', 'daemon'))
        ..createSync(recursive: true);
      return nested.path;
    }

    test('resolves the daemon version by walking up to its pubspec', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(root, 'name: agent_daemon\nversion: 9.8.7\n');

      expect(resolveDaemonVersion(start), '9.8.7');
    });

    test('throws when the daemon pubspec cannot be found', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(
        root,
        'name: not_agent_daemon\nversion: 1.2.3\n',
      );

      expect(
        () => resolveDaemonVersion(start),
        throwsA(isA<DaemonVersionResolutionError>()),
      );
    });

    test('throws when the daemon pubspec has no version', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(root, 'name: agent_daemon\n');

      expect(
        () => resolveDaemonVersion(start),
        throwsA(isA<DaemonVersionResolutionError>()),
      );
    });

    test('throws when the daemon pubspec version is blank', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(root, 'name: agent_daemon\nversion: "   "\n');

      expect(
        () => resolveDaemonVersion(start),
        throwsA(isA<DaemonVersionResolutionError>()),
      );
    });

    test('DaemonVersionResolutionError is a PackageVersionResolutionError', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(root, 'name: other\nversion: 1.0.0\n');

      expect(
        () => resolveDaemonVersion(start),
        throwsA(isA<PackageVersionResolutionError>()),
      );
    });

    test('error message names the package and the search origin', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(root, 'name: other\nversion: 1.0.0\n');

      try {
        resolveDaemonVersion(start);
        fail('expected DaemonVersionResolutionError');
      } on PackageVersionResolutionError catch (error) {
        expect(error.packageName, 'agent_daemon');
        expect(error.startDirectory, p.normalize(p.absolute(start)));
        expect(error.message, contains('agent_daemon'));
        expect(error.toString(), contains('DaemonVersionResolutionError'));
      }
    });

    test('skips a non-matching pubspec and keeps walking upward', () {
      final root = createTempDir('tinyrack-daemon-version-');
      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: agent_daemon\nversion: 4.5.6\n');
      final member = Directory(p.join(root.path, 'packages', 'other'))
        ..createSync(recursive: true);
      File(
        p.join(member.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: something_else\nversion: 0.0.1\n');

      expect(resolveDaemonVersion(member.path), '4.5.6');
    });

    test('ignores nested keys that happen to be called name or version', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(
        root,
        'name: agent_daemon\n'
        'dependencies:\n'
        '  name: decoy\n'
        '  version: 0.0.0\n'
        'version: 2.3.4\n',
      );

      expect(resolveDaemonVersion(start), '2.3.4');
    });

    test('strips quotes and inline comments from the version scalar', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(
        root,
        '# leading comment\nname: agent_daemon\nversion: "1.2.3" # pinned\n',
      );

      expect(resolveDaemonVersion(start), '1.2.3');
    });

    test('resolvePackageVersion works for arbitrary package names', () {
      final root = createTempDir('tinyrack-package-version-');
      final start = seedPackage(
        root,
        "name: 'agent_protocol'\nversion: 7.7.7\n",
      );

      expect(
        resolvePackageVersion(
          packageName: 'agent_protocol',
          startDirectory: start,
        ),
        '7.7.7',
      );
      expect(
        () => resolvePackageVersion(
          packageName: 'agent_daemon',
          startDirectory: start,
        ),
        throwsA(isA<PackageVersionResolutionError>()),
      );
    });

    test('resolves this package from the repository checkout', () {
      expect(resolveDaemonVersion(_daemonPackageRoot().path), daemonVersion);
    });

    test('falls back to the bundled version constant when unresolvable', () {
      final root = createTempDir('tinyrack-daemon-version-');
      final start = seedPackage(
        root,
        'name: not_agent_daemon\nversion: 1.2.3\n',
      );

      expect(resolveDaemonVersionWithFallback(start), daemonVersion);
      expect(
        resolveDaemonVersionWithFallback(_daemonPackageRoot().path),
        daemonVersion,
      );
    });
  });

  // -------------------------------------------------------------------------
  // paseo-home.ts
  // -------------------------------------------------------------------------

  group('expandHomeDirectory', () {
    test('expands a bare tilde to the home directory', () {
      expect(
        expandHomeDirectory('~', environment: {'HOME': '/home/tinyrack'}),
        '/home/tinyrack',
      );
    });

    test('expands a tilde prefix using posix and windows separators', () {
      final env = {'HOME': p.join('home', 'tinyrack')};
      expect(
        expandHomeDirectory('~/nested', environment: env),
        p.join('home', 'tinyrack', 'nested'),
      );
      expect(
        expandHomeDirectory(r'~\nested', environment: env),
        p.join('home', 'tinyrack', 'nested'),
      );
    });

    test('prefers USERPROFILE over HOME', () {
      expect(
        expandHomeDirectory(
          '~',
          environment: {'USERPROFILE': 'C:/profile', 'HOME': '/home/ignored'},
        ),
        'C:/profile',
      );
    });

    test('leaves paths without a tilde prefix untouched', () {
      final env = {'HOME': '/home/tinyrack'};
      expect(expandHomeDirectory('/abs/path', environment: env), '/abs/path');
      expect(expandHomeDirectory('rel/path', environment: env), 'rel/path');
      expect(expandHomeDirectory('a~b', environment: env), 'a~b');
    });
  });

  group('resolveTinyrackServerHome', () {
    test('creates the configured TINYRACK_HOME and returns it', () {
      final parent = createTempDir('tinyrack-home-parent-');
      final home = p.join(parent.path, 'home');

      expect(resolveTinyrackServerHome({'TINYRACK_HOME': home}), home);
      expect(Directory(home).existsSync(), isTrue);
    });

    test('is idempotent across repeated calls', () {
      final parent = createTempDir('tinyrack-home-parent-');
      final home = p.join(parent.path, 'home');

      expect(resolveTinyrackServerHome({'TINYRACK_HOME': home}), home);
      expect(resolveTinyrackServerHome({'TINYRACK_HOME': home}), home);
    });

    test('normalizes traversal segments before creating the directory', () {
      final parent = createTempDir('tinyrack-home-parent-');
      final raw = p.join(parent.path, 'a', '..', 'b');

      final resolved = resolveTinyrackServerHome({'TINYRACK_HOME': raw});

      expect(resolved, p.join(parent.path, 'b'));
      expect(Directory(resolved).existsSync(), isTrue);
    });

    test('expands a tilde in TINYRACK_HOME against the environment home', () {
      final parent = createTempDir('tinyrack-home-parent-');

      final resolved = resolveTinyrackServerHome({
        'TINYRACK_HOME': '~/agent-home',
        'HOME': parent.path,
        'USERPROFILE': parent.path,
      });

      expect(resolved, p.join(parent.path, 'agent-home'));
      expect(Directory(resolved).existsSync(), isTrue);
    });

    test('defaults to ~/.tinyrack-agent when TINYRACK_HOME is unset', () {
      final parent = createTempDir('tinyrack-home-parent-');

      final resolved = resolveTinyrackServerHome({
        'HOME': parent.path,
        'USERPROFILE': parent.path,
      });

      expect(resolved, p.join(parent.path, '.tinyrack-agent'));
      expect(Directory(resolved).existsSync(), isTrue);
    });

    test(
      'creates TINYRACK_HOME with private permissions',
      () {
        final parent = createTempDir('tinyrack-home-parent-');
        final home = p.join(parent.path, 'home');

        expect(resolveTinyrackServerHome({'TINYRACK_HOME': home}), home);
        expect(_modeOf(home), privateDirectoryMode);
      },
      skip: Platform.isWindows
          ? 'POSIX modes are not enforced on Windows'
          : null,
    );
  });

  // -------------------------------------------------------------------------
  // paseo-env.ts
  // -------------------------------------------------------------------------

  group('tinyrack env contract', () {
    Map<String, String?> baseEnv() => <String, String?>{
      'ELECTRON_RUN_AS_NODE': '1',
      'ELECTRON_NO_ATTACH_CONSOLE': '1',
      'NODE_ENV': 'development',
      'PATH': '/usr/bin',
      'TINYRACK_AGENT_ID': 'agent-123',
      'TINYRACK_DESKTOP_MANAGED': '1',
      'TINYRACK_NODE_ENV': 'production',
      'TINYRACK_SUPERVISED': '1',
    };

    test('pins the runtime control key set', () {
      expect(runtimeControlEnvKeys, <String>[
        'TINYRACK_NODE_ENV',
        'TINYRACK_DESKTOP_MANAGED',
        'TINYRACK_SUPERVISED',
        'ELECTRON_RUN_AS_NODE',
        'ELECTRON_NO_ATTACH_CONSOLE',
      ]);
    });

    test('internal env preserves pass-through and control vars', () {
      final env = createTinyrackInternalEnv(baseEnv());

      expect(env, {
        'ELECTRON_RUN_AS_NODE': '1',
        'ELECTRON_NO_ATTACH_CONSOLE': '1',
        'NODE_ENV': 'development',
        'PATH': '/usr/bin',
        'TINYRACK_AGENT_ID': 'agent-123',
        'TINYRACK_DESKTOP_MANAGED': '1',
        'TINYRACK_NODE_ENV': 'production',
        'TINYRACK_SUPERVISED': '1',
      });
    });

    test('internal env is a copy, not an alias', () {
      final base = baseEnv();
      final env = createTinyrackInternalEnv(base)..['EXTRA'] = 'value';

      expect(base.containsKey('EXTRA'), isFalse);
      expect(env['EXTRA'], 'value');
    });

    test('internal env keeps explicitly unset entries', () {
      final env = createTinyrackInternalEnv({'PATH': null});

      expect(env.containsKey('PATH'), isTrue);
      expect(env['PATH'], isNull);
    });

    test('external env scrubs runtime control vars after overlays', () {
      final env = createExternalProcessEnv(baseEnv(), [
        {
          'ELECTRON_NO_ATTACH_CONSOLE': '1',
          'ELECTRON_RUN_AS_NODE': '0',
          'EXTRA_VALUE': 'from-overlay',
          'TINYRACK_DESKTOP_MANAGED': '1',
          'TINYRACK_NODE_ENV': 'test',
          'TINYRACK_SUPERVISED': '1',
          'PATH': '/custom/bin',
        },
      ]);

      for (final key in runtimeControlEnvKeys) {
        expect(env.containsKey(key), isFalse, reason: key);
      }
      expect(env['NODE_ENV'], 'development');
      expect(env['TINYRACK_AGENT_ID'], 'agent-123');
      expect(env['PATH'], '/custom/bin');
      expect(env['EXTRA_VALUE'], 'from-overlay');
    });

    test('applies non-control overlays left to right', () {
      final env = createExternalProcessEnv(baseEnv(), [
        {'PATH': '/custom/bin', 'CUSTOM': 'first'},
        {'CUSTOM': 'second'},
      ]);

      expect(env['CUSTOM'], 'second');
      expect(env['NODE_ENV'], 'development');
      expect(env['PATH'], '/custom/bin');
    });

    test('an overlay null value removes the inherited entry', () {
      final env = createExternalProcessEnv(baseEnv(), [
        <String, String?>{'PATH': null},
      ]);

      expect(env.containsKey('PATH'), isFalse);
    });

    test('unset base entries never reach the child environment', () {
      final env = createExternalProcessEnv(<String, String?>{
        'PATH': '/usr/bin',
        'UNSET': null,
      });

      expect(env, {'PATH': '/usr/bin'});
    });

    test('external env works with no overlays at all', () {
      final env = createExternalProcessEnv(baseEnv());

      expect(env['NODE_ENV'], 'development');
      expect(env.containsKey('TINYRACK_NODE_ENV'), isFalse);
    });

    test('command env is not special-cased per command', () {
      final env = createExternalCommandProcessEnv(
        Platform.resolvedExecutable,
        baseEnv(),
        [
          {'ELECTRON_RUN_AS_NODE': '0', 'TINYRACK_NODE_ENV': 'test'},
        ],
      );

      expect(env.containsKey('ELECTRON_RUN_AS_NODE'), isFalse);
      expect(env['NODE_ENV'], 'development');
      expect(env['TINYRACK_AGENT_ID'], 'agent-123');
      expect(env['PATH'], '/usr/bin');
      expect(env.containsKey('ELECTRON_NO_ATTACH_CONSOLE'), isFalse);
      expect(env.containsKey('TINYRACK_DESKTOP_MANAGED'), isFalse);
      expect(env.containsKey('TINYRACK_NODE_ENV'), isFalse);
      expect(env.containsKey('TINYRACK_SUPERVISED'), isFalse);
    });

    test('a non-self command still gets no electron node mode', () {
      final env = createExternalCommandProcessEnv('dart', baseEnv(), [
        {'ELECTRON_RUN_AS_NODE': '1'},
      ]);

      expect(env.containsKey('ELECTRON_RUN_AS_NODE'), isFalse);
    });

    test('self command re-adds electron node mode after scrubbing', () {
      final command = buildSelfExecutableCommand(
        ['script.dart'],
        baseEnv: baseEnv(),
        envOverlay: {'CUSTOM': 'value'},
        executable: '/opt/tinyrack/daemon',
      );

      expect(command.command, '/opt/tinyrack/daemon');
      expect(command.args, ['script.dart']);
      expect(command.env['ELECTRON_RUN_AS_NODE'], '1');
      expect(command.env['CUSTOM'], 'value');
      expect(command.env['NODE_ENV'], 'development');
      expect(command.env.containsKey('ELECTRON_NO_ATTACH_CONSOLE'), isFalse);
      expect(command.env.containsKey('TINYRACK_DESKTOP_MANAGED'), isFalse);
      expect(command.env.containsKey('TINYRACK_NODE_ENV'), isFalse);
      expect(command.env.containsKey('TINYRACK_SUPERVISED'), isFalse);
    });

    test('self command overlay is applied after the electron default', () {
      final command = buildSelfExecutableCommand(
        const [],
        baseEnv: baseEnv(),
        envOverlay: <String, String?>{
          'ELECTRON_RUN_AS_NODE': '0',
          'TINYRACK_NODE_ENV': 'test',
        },
        executable: 'daemon',
      );

      expect(command.env['ELECTRON_RUN_AS_NODE'], '0');
      expect(command.env['TINYRACK_NODE_ENV'], 'test');
    });

    test('self command overlay null values delete keys', () {
      final command = buildSelfExecutableCommand(
        const [],
        baseEnv: baseEnv(),
        envOverlay: <String, String?>{'ELECTRON_RUN_AS_NODE': null},
        executable: 'daemon',
      );

      expect(command.env.containsKey('ELECTRON_RUN_AS_NODE'), isFalse);
    });

    test('self command defaults to the running executable', () {
      final command = buildSelfExecutableCommand(const ['a']);

      expect(command.command, Platform.resolvedExecutable);
      expect(command.env['ELECTRON_RUN_AS_NODE'], '1');
    });

    test('self command exposes unmodifiable args and env', () {
      final command = buildSelfExecutableCommand(
        ['a'],
        baseEnv: baseEnv(),
        executable: 'daemon',
      );

      expect(() => command.args.add('b'), throwsUnsupportedError);
      expect(() => command.env['X'] = 'y', throwsUnsupportedError);
    });

    test('does not use user NODE_ENV as the tinyrack runtime mode', () {
      expect(resolveTinyrackNodeEnv({'NODE_ENV': 'development'}), isNull);
      expect(
        resolveTinyrackNodeEnv({
          'NODE_ENV': 'development',
          'TINYRACK_NODE_ENV': 'production',
        }),
        TinyrackNodeEnv.production,
      );
      expect(
        resolveTinyrackNodeEnv({
          'NODE_ENV': 'test',
          'TINYRACK_NODE_ENV': 'local',
        }),
        isNull,
      );
    });

    test('accepts every documented runtime mode', () {
      expect(
        resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': 'development'}),
        TinyrackNodeEnv.development,
      );
      expect(
        resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': 'test'}),
        TinyrackNodeEnv.test,
      );
    });

    test('rejects blank, cased, and unset runtime modes', () {
      expect(resolveTinyrackNodeEnv(const {}), isNull);
      expect(resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': null}), isNull);
      expect(resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': ''}), isNull);
      expect(resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': ' test '}), isNull);
      expect(
        resolveTinyrackNodeEnv({'TINYRACK_NODE_ENV': 'Production'}),
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  // messages.ts
  // -------------------------------------------------------------------------

  group('serializeAgentStreamEvent', () {
    test('normalizes attention_required with shouldNotify false', () {
      final serialized = serializeAgentStreamEvent({
        'type': 'attention_required',
        'provider': 'codex',
        'reason': 'permission',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'shouldNotify': true,
      });

      expect(serialized, {
        'type': 'attention_required',
        'provider': 'codex',
        'reason': 'permission',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'shouldNotify': false,
      });
    });

    test('keeps a null timestamp on attention_required', () {
      final serialized = serializeAgentStreamEvent({
        'type': 'attention_required',
        'provider': 'claude',
        'reason': 'finished',
      });

      expect(serialized, isNotNull);
      expect(serialized!['timestamp'], isNull);
      expect(serialized['shouldNotify'], isFalse);
    });

    test('drops attention_required with an unknown reason or no provider', () {
      expect(
        serializeAgentStreamEvent({
          'type': 'attention_required',
          'provider': 'codex',
          'reason': 'bored',
        }),
        isNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'attention_required',
          'reason': 'error',
        }),
        isNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'attention_required',
          'provider': 'codex',
          'reason': 'error',
          'timestamp': 12,
        }),
        isNull,
      );
    });

    test('preserves user_message text as-is', () {
      final event = <String, Object?>{
        'type': 'timeline',
        'provider': 'claude',
        'item': {
          'type': 'user_message',
          'text': '<paseo-instructions>\nX\n</paseo-instructions>\n\nHello',
          'messageId': 'm1',
        },
      };

      final serialized = serializeAgentStreamEvent(event);

      expect(serialized, isNotNull);
      final item = serialized!['item']! as Map<String, Object?>;
      expect(
        item['text'],
        '<paseo-instructions>\nX\n</paseo-instructions>\n\nHello',
      );
      expect(item['messageId'], 'm1');
    });

    test('passes canonical tool_call payloads through unchanged', () {
      final event = <String, Object?>{
        'type': 'timeline',
        'provider': 'codex',
        'item': {
          'type': 'tool_call',
          'callId': 'call_1',
          'name': 'shell',
          'status': 'running',
          'detail': {'type': 'shell', 'command': 'pwd'},
          'error': null,
        },
      };

      final serialized = serializeAgentStreamEvent(event);

      expect(serialized, same(event));
      final item = serialized!['item']! as Map<String, Object?>;
      expect(item['status'], 'running');
      expect(item['error'], isNull);
    });

    test('passes unknown-detail tool_call payloads through unchanged', () {
      final event = <String, Object?>{
        'type': 'timeline',
        'provider': 'codex',
        'item': {
          'type': 'tool_call',
          'callId': 'call_unknown',
          'name': 'tinyrack_voice.speak',
          'status': 'completed',
          'detail': {
            'type': 'unknown',
            'input': {'text': 'hello'},
            'output': {'ok': true},
          },
          'error': null,
        },
      };

      final serialized = serializeAgentStreamEvent(event);

      expect(serialized, isNotNull);
      final item = serialized!['item']! as Map<String, Object?>;
      expect(item['detail'], {
        'type': 'unknown',
        'input': {'text': 'hello'},
        'output': {'ok': true},
      });
    });

    test('drops invalid legacy tool_call items', () {
      final serialized = serializeAgentStreamEvent({
        'type': 'timeline',
        'provider': 'codex',
        'item': {
          'type': 'tool_call',
          'callId': 'call_legacy',
          'name': 'shell',
          'status': 'inProgress',
          'detail': {
            'type': 'unknown',
            'input': {'command': 'pwd'},
            'output': null,
          },
        },
      });

      expect(serialized, isNull);
    });

    test('drops tool_call items whose error contradicts their status', () {
      Map<String, Object?> toolCall(String status, Object? error) => {
        'type': 'timeline',
        'provider': 'codex',
        'item': {
          'type': 'tool_call',
          'callId': 'call_x',
          'name': 'shell',
          'status': status,
          'detail': {'type': 'shell', 'command': 'pwd'},
          'error': error,
        },
      };

      expect(serializeAgentStreamEvent(toolCall('failed', null)), isNull);
      expect(serializeAgentStreamEvent(toolCall('running', 'boom')), isNull);
      expect(serializeAgentStreamEvent(toolCall('failed', 'boom')), isNotNull);
    });

    test('drops internal session config drift events', () {
      final events = <Map<String, Object?>>[
        {
          'type': 'mode_changed',
          'provider': 'codex',
          'currentModeId': 'build',
          'availableModes': [
            {'id': 'build', 'label': 'Build'},
          ],
        },
        {
          'type': 'model_changed',
          'provider': 'codex',
          'runtimeInfo': {
            'provider': 'codex',
            'sessionId': 'session-1',
            'model': 'gpt-5.4',
          },
        },
        {
          'type': 'thinking_option_changed',
          'provider': 'codex',
          'thinkingOptionId': 'high',
        },
      ];

      expect(events.map(serializeAgentStreamEvent).toList(), [
        null,
        null,
        null,
      ]);
    });

    test('drops events with a missing, blank, or non-string type', () {
      expect(serializeAgentStreamEvent(const {}), isNull);
      expect(serializeAgentStreamEvent({'type': ''}), isNull);
      expect(serializeAgentStreamEvent({'type': 7}), isNull);
      expect(
        serializeAgentStreamEvent({'type': 'wat', 'provider': 'codex'}),
        isNull,
      );
    });

    test('drops timeline events with a missing provider or item', () {
      expect(
        serializeAgentStreamEvent({
          'type': 'timeline',
          'item': {'type': 'reasoning', 'text': 'hm'},
        }),
        isNull,
      );
      expect(
        serializeAgentStreamEvent({'type': 'timeline', 'provider': 'codex'}),
        isNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'timeline',
          'provider': 'codex',
          'item': {'type': 'nope'},
        }),
        isNull,
      );
    });

    test('passes turn lifecycle events through when well formed', () {
      expect(
        serializeAgentStreamEvent({
          'type': 'turn_started',
          'provider': 'codex',
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'turn_completed',
          'provider': 'codex',
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'turn_failed',
          'provider': 'codex',
          'error': 'boom',
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({'type': 'turn_failed', 'provider': 'codex'}),
        isNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'turn_canceled',
          'provider': 'codex',
          'reason': 'user',
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'turn_canceled',
          'provider': 'codex',
        }),
        isNull,
      );
    });

    test('validates permission events', () {
      expect(
        serializeAgentStreamEvent({
          'type': 'permission_requested',
          'provider': 'codex',
          'request': {
            'id': 'perm-1',
            'provider': 'codex',
            'name': 'shell',
            'kind': 'tool',
            'detail': {'type': 'shell', 'command': 'ls'},
          },
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'permission_resolved',
          'provider': 'codex',
          'requestId': 'perm-1',
          'resolution': {'behavior': 'allow'},
        }),
        isNotNull,
      );
      expect(
        serializeAgentStreamEvent({
          'type': 'permission_resolved',
          'provider': 'codex',
          'requestId': 'perm-1',
          'resolution': {'behavior': 'maybe'},
        }),
        isNull,
      );
    });
  });

  group('serializeAgentSnapshot', () {
    AgentSummary summary({String title = 'Agent title'}) => AgentSummary(
      agentId: 'agent-1',
      title: title,
      cwd: '/tmp/project',
      provider: 'codex',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 0,
    );

    test('projects the agent through the shared snapshot codec', () {
      final payload = serializeAgentSnapshot(summary());

      expect(payload['id'], 'agent-1');
      expect(payload['provider'], 'codex');
      expect(payload['cwd'], '/tmp/project');
      expect(payload['status'], 'idle');
      expect(payload['title'], 'Agent title');
    });

    test('applies an explicit title override', () {
      expect(
        serializeAgentSnapshot(summary(), title: 'Overridden')['title'],
        'Overridden',
      );
    });

    test('an explicit null or blank title override clears the title', () {
      expect(serializeAgentSnapshot(summary(), title: null)['title'], isNull);
      expect(serializeAgentSnapshot(summary(), title: '   ')['title'], isNull);
    });

    test('an untitled agent projects a null title', () {
      expect(serializeAgentSnapshot(summary(title: ''))['title'], isNull);
    });

    test('surfaces pending permissions', () {
      final payload = serializeAgentSnapshot(
        summary(),
        pendingPermissions: const [
          PermissionItem(
            id: 'perm_1',
            permissionId: '1',
            toolName: 'shell',
            status: PermissionStatus.pending,
            detail: GenericDetail(input: {}),
          ),
        ],
      );

      expect(payload['pendingPermissions'], hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // exports.ts
  // -------------------------------------------------------------------------

  group('parseDartExportTargets', () {
    test('extracts single- and double-quoted export targets', () {
      const source = '''
library;

export 'src/a.dart';
export "src/b.dart";
  export 'src/c.dart' show Foo;
import 'src/not_exported.dart';
''';

      expect(parseDartExportTargets(source), [
        'src/a.dart',
        'src/b.dart',
        'src/c.dart',
      ]);
    });

    test('returns an empty list for a library without exports', () {
      expect(parseDartExportTargets('library;\n'), isEmpty);
    });
  });

  group('declaresTopLevelSymbol', () {
    test('matches type, function, and variable declarations', () {
      const source = '''
final class DaemonServerHandle {}
enum Mode { a }
typedef Handler = void Function();
Future<DaemonServerHandle> startDaemonServer({int? port}) async => throw 0;
String resolveTinyrackHome(Map<String, String> env) => '';
const Set<String> knownKeys = {};
''';

      for (final symbol in const [
        'DaemonServerHandle',
        'Mode',
        'Handler',
        'startDaemonServer',
        'resolveTinyrackHome',
        'knownKeys',
      ]) {
        expect(declaresTopLevelSymbol(source, symbol), isTrue, reason: symbol);
      }
    });

    test('does not match indented members or unrelated text', () {
      const source = '''
final class Holder {
  void DaemonClient() {}
  final String connect = 'DaemonClient';
}
''';

      expect(declaresTopLevelSymbol(source, 'DaemonClient'), isFalse);
      expect(declaresTopLevelSymbol(source, 'Missing'), isFalse);
    });
  });

  group('findServerEntrySurfaceViolations', () {
    test('reports nothing when the surface is correct', () {
      expect(
        findServerEntrySurfaceViolations(
          exportedSymbols: serverPublicEntryRequiredSymbols,
        ),
        isEmpty,
      );
    });

    test('reports missing required exports', () {
      final violations = findServerEntrySurfaceViolations(
        exportedSymbols: const {'startDaemonServer'},
      );

      expect(violations, hasLength(2));
      expect(violations.join('\n'), contains('resolveTinyrackHome'));
    });

    test('reports leaked daemon-client symbols', () {
      final violations = findServerEntrySurfaceViolations(
        exportedSymbols: {...serverPublicEntryRequiredSymbols, 'DaemonClient'},
      );

      expect(violations, hasLength(1));
      expect(violations.single, contains('DaemonClient'));
    });

    test('keeps daemon-client APIs out of the real server public entry', () {
      final packageRoot = _daemonPackageRoot();
      final entryPath = p.join(packageRoot.path, 'lib', 'agent_daemon.dart');
      final entrySource = File(entryPath).readAsStringSync();
      final targets = parseDartExportTargets(entrySource);

      expect(targets, isNotEmpty);

      final candidates = <String>{
        ...serverPublicEntryRequiredSymbols,
        ...daemonClientOnlySymbols,
      };
      final exported = <String>{};
      for (final target in targets) {
        final file = File(p.normalize(p.join(packageRoot.path, 'lib', target)));
        expect(file.existsSync(), isTrue, reason: target);
        final source = file.readAsStringSync();
        for (final symbol in candidates) {
          if (declaresTopLevelSymbol(source, symbol)) exported.add(symbol);
        }
      }

      expect(
        findServerEntrySurfaceViolations(exportedSymbols: exported),
        isEmpty,
      );
    });
  });
}

/// Locates the `agent_daemon` package root regardless of the test runner's
/// working directory (package root when run via `dart test`, repository root
/// when run from the workspace).
Directory _daemonPackageRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File(p.join(dir.path, 'lib', 'agent_daemon.dart')).existsSync()) {
      return dir;
    }
    final nested = Directory(p.join(dir.path, 'packages', 'daemon'));
    if (File(p.join(nested.path, 'lib', 'agent_daemon.dart')).existsSync()) {
      return nested;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Unable to locate the agent_daemon package root.');
    }
    dir = parent;
  }
}

int _modeOf(String path) => File(path).statSync().mode & 0x1FF;
