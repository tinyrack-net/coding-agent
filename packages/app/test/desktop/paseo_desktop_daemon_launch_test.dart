// Ports of the upstream Paseo 0.2.0 test suites for the desktop daemon launch
// and quit cluster: runtime-paths, node-entrypoint-launcher,
// node-entrypoint-runner, quit-lifecycle, cli/passthrough and cli/external —
// plus the edge cases those suites leave unpinned (JS falsy guards on empty
// strings, prefix-matched launch switches, null exit codes, malformed
// package.json while walking up, deadline signals that are already aborted,
// and repeated updater-handoff evidence).
import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart' show ServerHello;
import 'package:coding_agent_app/desktop/paseo_desktop_daemon_launch.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart'
    show DaemonHealth, DaemonStatus;
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// In-memory `node:fs`. [unreadable] paths exist but throw on read, which is
/// the case upstream swallows inside its `try` block.
final class _FakeFileSystem implements DaemonLaunchFileSystem {
  _FakeFileSystem({
    Set<String> present = const {},
    Map<String, String> contents = const {},
    Set<String> unreadable = const {},
  }) : _present = {...present, ...contents.keys, ...unreadable},
       _contents = contents,
       _unreadable = unreadable;

  final Set<String> _present;
  final Map<String, String> _contents;
  final Set<String> _unreadable;

  final List<String> probed = [];

  @override
  bool exists(String path) {
    probed.add(path);
    return _present.contains(path);
  }

  @override
  String readAsString(String path) {
    if (_unreadable.contains(path)) {
      throw StateError('EACCES: $path');
    }
    final value = _contents[path];
    if (value == null) throw StateError('ENOENT: $path');
    return value;
  }
}

final class _FakeModuleResolver implements NodeModuleResolver {
  _FakeModuleResolver(this._resolved);

  final Map<String, String> _resolved;
  final List<String> requested = [];

  @override
  String resolve(String specifier) {
    requested.add(specifier);
    final value = _resolved[specifier];
    if (value == null) {
      throw StateError('MODULE_NOT_FOUND: $specifier');
    }
    return value;
  }
}

final class _RecordedWarning {
  const _RecordedWarning(this.scope, this.message, this.details);

  final String scope;
  final String message;
  final Map<String, Object?> details;
}

final class _FakeLogger implements DesktopDaemonLaunchLogger {
  final List<_RecordedWarning> warnings = [];

  @override
  void warn(String scope, String message, Map<String, Object?> details) {
    warnings.add(_RecordedWarning(scope, message, details));
  }
}

final class _FakeProcessRunner implements ExternalCliProcessRunner {
  _FakeProcessRunner(this._results);

  final List<ExternalCliResult> _results;
  final List<ExternalCliSpawnRequest> requests = [];

  @override
  Future<ExternalCliResult> spawn(ExternalCliSpawnRequest request) async {
    requests.add(request);
    return _results.removeAt(0);
  }
}

final class _FakeRunnerHost implements NodeEntrypointRunnerHost {
  _FakeRunnerHost(this._argv, {Map<String, String> env = const {}})
    : env = Map.of(env);

  List<String> _argv;

  /// Stands in for `process.env`; the runner must never touch it.
  final Map<String, String> env;

  final List<String> importedUrls = [];
  List<String> argvAtImport = const [];

  @override
  List<String> get argv => _argv;

  @override
  set argv(List<String> value) => _argv = value;

  @override
  Future<void> importModule(String moduleUrl) async {
    importedUrls.add(moduleUrl);
    argvAtImport = List.of(_argv);
  }
}

final class _FakePassthroughLoader implements PassthroughCliModuleLoader {
  _FakePassthroughLoader({required this.entrypoint, this.runCli});

  final String entrypoint;
  final PassthroughCliRunner? runCli;
  int resolveCount = 0;
  final List<String> loaded = [];

  @override
  String resolveEntrypoint() {
    resolveCount++;
    return entrypoint;
  }

  @override
  Future<PassthroughCliRunner?> loadRunCli(String entrypoint) async {
    loaded.add(entrypoint);
    return runCli;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const NodeEntrypointSpec _cliEntrypoint = NodeEntrypointSpec(
  entryPath: '/tmp/paseo-cli.js',
  execArgv: ['--import', 'tsx'],
);

const String _macExecPath = '/Applications/Paseo.app/Contents/MacOS/Paseo';
const String _macHelperPath =
    '/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app'
    '/Contents/MacOS/Paseo Helper';
const String _macResourcesPath = '/Applications/Paseo.app/Contents/Resources';
const String _packagedRunnerPath =
    '$_macResourcesPath/app.asar.unpacked/dist/daemon/node-entrypoint-runner.js';

DesktopDaemonRuntimePaths _runtimePaths({
  bool isPackaged = true,
  DesktopLaunchPlatform platform = DesktopLaunchPlatform.darwin,
  String execPath = _macExecPath,
  String resourcesPath = _macResourcesPath,
  DaemonLaunchFileSystem? fileSystem,
  NodeModuleResolver? moduleResolver,
  DesktopPathOps paths = DesktopPathOps.posix,
}) => DesktopDaemonRuntimePaths(
  fileSystem: fileSystem ?? _FakeFileSystem(present: {_macHelperPath}),
  isPackaged: isPackaged,
  platform: platform,
  execPath: execPath,
  resourcesPath: resourcesPath,
  moduleResolver: moduleResolver,
  paths: paths,
);

DaemonStatus _daemonStatus({
  DaemonHealth health = DaemonHealth.running,
  bool? desktopManaged = true,
}) => DaemonStatus(
  health: health,
  hello: desktopManaged == null
      ? null
      : ServerHello(
          daemonVersion: '1.0.0',
          protocolVersion: 2,
          pid: 123,
          desktopManaged: desktopManaged,
        ),
);

Matcher _launchFailure(Object messageMatcher) => throwsA(
  isA<DesktopDaemonLaunchException>().having(
    (error) => error.message,
    'message',
    messageMatcher,
  ),
);

/// Upstream's suites flush with `setImmediate`; the Dart equivalent is a pump
/// of the microtask/event queue.
Future<void> _flush() => pumpEventQueue();

void main() {
  // -------------------------------------------------------------------------
  // package-paths.ts — path primitives
  // -------------------------------------------------------------------------

  group('DesktopPathOps', () {
    test('joins POSIX segments onto an absolute base', () {
      expect(DesktopPathOps.posix.join(['/a', 'b', 'c.js']), '/a/b/c.js');
    });

    test('collapses duplicated separators and drops empty segments', () {
      expect(DesktopPathOps.posix.join(['/a/', '', '/b/', 'c']), '/a/b/c');
      expect(DesktopPathOps.posix.join(const []), '.');
      expect(DesktopPathOps.posix.join(['', '']), '.');
    });

    test(
      'joins Windows segments with backslashes and accepts both slashes',
      () {
        expect(
          DesktopPathOps.windows.join([r'C:\app', 'resources/x', 'y.js']),
          r'C:\app\resources\x\y.js',
        );
      },
    );

    test('dirname walks POSIX paths up to the root fixpoint', () {
      expect(DesktopPathOps.posix.dirname('/a/b/c.js'), '/a/b');
      expect(DesktopPathOps.posix.dirname('/a'), '/');
      expect(DesktopPathOps.posix.dirname('/'), '/');
      expect(DesktopPathOps.posix.dirname('a'), '.');
      expect(DesktopPathOps.posix.dirname(''), '.');
      expect(DesktopPathOps.posix.dirname('/a/b/'), '/a');
    });

    test('dirname treats a Windows drive root as its own parent', () {
      expect(DesktopPathOps.windows.dirname(r'C:\a\b'), r'C:\a');
      expect(DesktopPathOps.windows.dirname(r'C:\a'), r'C:\');
      expect(DesktopPathOps.windows.dirname(r'C:\'), r'C:\');
      expect(DesktopPathOps.windows.dirname('C:'), 'C:');
    });

    test('basename strips trailing separators', () {
      expect(DesktopPathOps.posix.basename('/a/b/Paseo'), 'Paseo');
      expect(DesktopPathOps.posix.basename('/a/b/'), 'b');
      expect(DesktopPathOps.posix.basename('/'), '');
      expect(DesktopPathOps.windows.basename(r'C:\a\Paseo.exe'), 'Paseo.exe');
    });

    test('fileUri mirrors pathToFileURL for both flavours', () {
      expect(
        DesktopPathOps.posix.fileUri('/tmp/paseo-cli.js'),
        'file:///tmp/paseo-cli.js',
      );
      expect(
        DesktopPathOps.windows.fileUri(r'C:\tmp\paseo-cli.js'),
        'file:///C:/tmp/paseo-cli.js',
      );
    });
  });

  group('assertDaemonLaunchPathExists', () {
    test('returns the path when it exists', () {
      final fileSystem = _FakeFileSystem(present: {'/a/b.js'});

      expect(
        assertDaemonLaunchPathExists(
          label: 'Bundled daemon runner',
          filePath: '/a/b.js',
          fileSystem: fileSystem,
        ),
        '/a/b.js',
      );
    });

    test('names the missing asset and its expected location', () {
      expect(
        () => assertDaemonLaunchPathExists(
          label: 'Bundled daemon runner',
          filePath: '/a/b.js',
          fileSystem: _FakeFileSystem(),
        ),
        _launchFailure('Bundled daemon runner is missing at /a/b.js'),
      );
    });
  });

  group('findNodePackageRootFromResolvedPath', () {
    test('walks up to the package.json whose name matches', () {
      final fileSystem = _FakeFileSystem(
        contents: {
          '/repo/node_modules/@getpaseo/server/dist/package.json':
              '{"name":"something-else"}',
          '/repo/node_modules/@getpaseo/server/package.json':
              '{"name":"@getpaseo/server"}',
        },
      );

      expect(
        findNodePackageRootFromResolvedPath(
          resolvedPath: '/repo/node_modules/@getpaseo/server/dist/index.js',
          packageName: '@getpaseo/server',
          fileSystem: fileSystem,
        ),
        const NodePackageInfo(root: '/repo/node_modules/@getpaseo/server'),
      );
    });

    test('skips malformed, unreadable and non-object package metadata', () {
      final fileSystem = _FakeFileSystem(
        contents: {
          '/repo/a/b/package.json': '{not json',
          '/repo/a/package.json': '[1,2,3]',
          '/repo/package.json': '{"name":"@getpaseo/server"}',
        },
        unreadable: {'/repo/a/b/c/package.json'},
      );

      expect(
        findNodePackageRootFromResolvedPath(
          resolvedPath: '/repo/a/b/c/index.js',
          packageName: '@getpaseo/server',
          fileSystem: fileSystem,
        ).root,
        '/repo',
      );
    });

    test('throws once the walk reaches the root without a match', () {
      expect(
        () => findNodePackageRootFromResolvedPath(
          resolvedPath: '/repo/a/index.js',
          packageName: '@getpaseo/server',
          fileSystem: _FakeFileSystem(),
        ),
        _launchFailure('Unable to resolve @getpaseo/server package root'),
      );
    });

    test('terminates on a Windows drive without probing a relative path', () {
      final fileSystem = _FakeFileSystem();

      expect(
        () => findNodePackageRootFromResolvedPath(
          resolvedPath: r'C:\repo\a\index.js',
          packageName: '@getpaseo/server',
          fileSystem: fileSystem,
          paths: DesktopPathOps.windows,
        ),
        _launchFailure('Unable to resolve @getpaseo/server package root'),
      );
      expect(fileSystem.probed, isNot(contains('./package.json')));
      expect(fileSystem.probed.last, r'C:\package.json');
    });
  });

  // -------------------------------------------------------------------------
  // node-entrypoint-launcher.ts
  // -------------------------------------------------------------------------

  group('createNodeEntrypointInvocation', () {
    test('uses the packaged runner when the desktop app is packaged', () {
      expect(
        createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath:
              '$_macResourcesPath/app.asar/dist/daemon/node-entrypoint-runner.js',
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const ['ls', '--json'],
          baseEnv: const {'PATH': '/usr/bin'},
        ),
        const NodeEntrypointInvocation(
          command: _macExecPath,
          args: [
            '--disable-warning=DEP0040',
            '$_macResourcesPath/app.asar/dist/daemon/node-entrypoint-runner.js',
            'node-script',
            '/tmp/paseo-cli.js',
            'ls',
            '--json',
          ],
          env: {
            'PATH': '/usr/bin',
            'ELECTRON_RUN_AS_NODE': '1',
            'PASEO_NODE_ENV': 'production',
          },
        ),
      );
    });

    test('uses the entrypoint directly in development', () {
      expect(
        createNodeEntrypointInvocation(
          execPath: '/opt/homebrew/bin/electron',
          isPackaged: false,
          packagedRunnerPath: null,
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const ['ls'],
          baseEnv: const {'PATH': '/usr/bin'},
        ),
        const NodeEntrypointInvocation(
          command: '/opt/homebrew/bin/electron',
          args: ['--import', 'tsx', '/tmp/paseo-cli.js', 'ls'],
          env: {'PATH': '/usr/bin', 'ELECTRON_RUN_AS_NODE': '1'},
        ),
      );
    });

    test(
      'forces packaged launches to production even when NODE_ENV is inherited '
      'as development',
      () {
        expect(
          createNodeEntrypointInvocation(
            execPath: _macExecPath,
            isPackaged: true,
            packagedRunnerPath: _packagedRunnerPath,
            entrypoint: _cliEntrypoint,
            argvMode: NodeEntrypointArgvMode.nodeScript,
            args: const [],
            baseEnv: const {'PATH': '/usr/bin', 'NODE_ENV': 'development'},
          ).env,
          const {
            'PATH': '/usr/bin',
            'NODE_ENV': 'development',
            'ELECTRON_RUN_AS_NODE': '1',
            'PASEO_NODE_ENV': 'production',
          },
        );
      },
    );

    test('keeps node-style argv for packaged script entrypoints', () {
      expect(
        createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath: _packagedRunnerPath,
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const ['--dev'],
          baseEnv: const {'PATH': '/usr/bin'},
        ).args,
        [
          '--disable-warning=DEP0040',
          _packagedRunnerPath,
          'node-script',
          '/tmp/paseo-cli.js',
          '--dev',
        ],
      );
    });

    test('passes the bare argv mode through to the runner', () {
      expect(
        createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath: _packagedRunnerPath,
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.bare,
          args: const ['status'],
          baseEnv: const {},
        ).args,
        [
          '--disable-warning=DEP0040',
          _packagedRunnerPath,
          'bare',
          '/tmp/paseo-cli.js',
          'status',
        ],
      );
    });

    test('drops execArgv for packaged launches', () {
      expect(
        createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath: _packagedRunnerPath,
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const [],
          baseEnv: const {},
        ).args,
        isNot(contains('--import')),
      );
    });

    test('requires a runner path for packaged launches', () {
      expect(
        () => createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath: null,
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const [],
          baseEnv: const {},
        ),
        _launchFailure(
          'Packaged node entrypoint runner is required for desktop launches.',
        ),
      );
    });

    test('treats an empty runner path as missing, matching the JS guard', () {
      expect(
        () => createNodeEntrypointInvocation(
          execPath: _macExecPath,
          isPackaged: true,
          packagedRunnerPath: '',
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const [],
          baseEnv: const {},
        ),
        _launchFailure(
          'Packaged node entrypoint runner is required for desktop launches.',
        ),
      );
    });

    test('an unpackaged launch never stamps PASEO_NODE_ENV', () {
      expect(createElectronNodeEnv(const {'PATH': '/usr/bin'}), const {
        'PATH': '/usr/bin',
        'ELECTRON_RUN_AS_NODE': '1',
      });
      expect(createElectronNodeEnv(const {}, isPackaged: true), const {
        'ELECTRON_RUN_AS_NODE': '1',
        'PASEO_NODE_ENV': 'production',
      });
    });

    test('argv mode wire spellings round-trip', () {
      expect(NodeEntrypointArgvMode.bare.wireName, 'bare');
      expect(NodeEntrypointArgvMode.nodeScript.wireName, 'node-script');
      expect(
        NodeEntrypointArgvMode.fromWireName('node-script'),
        NodeEntrypointArgvMode.nodeScript,
      );
      expect(NodeEntrypointArgvMode.fromWireName('nodeScript'), isNull);
      expect(NodeEntrypointArgvMode.fromWireName(null), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // runtime-paths.ts
  // -------------------------------------------------------------------------

  group('runtime-paths', () {
    test(
      'uses the macOS Helper executable for packaged daemon node launches',
      () {
        expect(_runtimePaths().resolveNodeExecPath(), _macHelperPath);
      },
    );

    test('falls back to the app binary when the Helper is not on disk', () {
      expect(
        _runtimePaths(fileSystem: _FakeFileSystem()).resolveNodeExecPath(),
        _macExecPath,
      );
    });

    test('never rewrites the exec path for an unpackaged launch', () {
      expect(
        _runtimePaths(isPackaged: false).resolveNodeExecPath(),
        _macExecPath,
      );
    });

    test('never rewrites the exec path off macOS', () {
      expect(
        _runtimePaths(
          platform: DesktopLaunchPlatform.win32,
          execPath: r'C:\Program Files\Paseo\Paseo.exe',
          fileSystem: _FakeFileSystem(),
        ).resolveNodeExecPath(),
        r'C:\Program Files\Paseo\Paseo.exe',
      );
    });

    test('falls back when the exec path is not inside an app bundle', () {
      expect(
        _runtimePaths(execPath: '/usr/local/bin/paseo').resolveNodeExecPath(),
        '/usr/local/bin/paseo',
      );
    });

    test('derives the Helper name from the app binary name', () {
      const execPath =
          '/Applications/Paseo Nightly.app/Contents/MacOS/'
          'Paseo Nightly';
      const helperPath =
          '/Applications/Paseo Nightly.app/Contents/Frameworks/'
          'Paseo Nightly Helper.app/Contents/MacOS/Paseo Nightly Helper';

      expect(
        _runtimePaths(
          execPath: execPath,
          fileSystem: _FakeFileSystem(present: {helperPath}),
        ).resolveNodeExecPath(),
        helperPath,
      );
    });

    test('locates the packaged asar and the unpacked runner', () {
      final paths = _runtimePaths();

      expect(paths.resolvePackagedAsarPath(), '$_macResourcesPath/app.asar');
      expect(
        paths.resolvePackagedNodeEntrypointRunnerPath(),
        _packagedRunnerPath,
      );
    });

    test('resolves the bundled daemon runner for a packaged build', () {
      const bundled =
          '$_macResourcesPath/app.asar/node_modules/@getpaseo/'
          'server/dist/scripts/supervisor-entrypoint.js';

      expect(
        _runtimePaths(
          fileSystem: _FakeFileSystem(present: {bundled}),
        ).resolveDaemonRunnerEntrypoint(),
        const NodeEntrypointSpec(entryPath: bundled, execArgv: []),
      );
    });

    test('fails loudly when the bundled daemon runner is absent', () {
      expect(
        () => _runtimePaths(
          fileSystem: _FakeFileSystem(),
        ).resolveDaemonRunnerEntrypoint(),
        _launchFailure(startsWith('Bundled daemon runner is missing at ')),
      );
    });

    test('prefers a built dist runner in development', () {
      const root = '/repo/packages/server';
      const dist = '$root/dist/scripts/supervisor-entrypoint.js';

      expect(
        _runtimePaths(
          isPackaged: false,
          fileSystem: _FakeFileSystem(
            present: {dist},
            contents: {'$root/package.json': '{"name":"@getpaseo/server"}'},
          ),
          moduleResolver: _FakeModuleResolver({
            '@getpaseo/server': '$root/dist/index.js',
          }),
        ).resolveDaemonRunnerEntrypoint(),
        const NodeEntrypointSpec(entryPath: dist, execArgv: []),
      );
    });

    test('falls back to the TS source with the tsx loader', () {
      const root = '/repo/packages/server';
      const source = '$root/scripts/supervisor-entrypoint.ts';

      expect(
        _runtimePaths(
          isPackaged: false,
          fileSystem: _FakeFileSystem(
            present: {source},
            contents: {'$root/package.json': '{"name":"@getpaseo/server"}'},
          ),
          moduleResolver: _FakeModuleResolver({
            '@getpaseo/server': '$root/dist/index.js',
          }),
        ).resolveDaemonRunnerEntrypoint(),
        const NodeEntrypointSpec(
          entryPath: source,
          execArgv: ['--import', 'tsx'],
        ),
      );
    });

    test('fails when neither the dist runner nor the source exists', () {
      const root = '/repo/packages/server';

      expect(
        () => _runtimePaths(
          isPackaged: false,
          fileSystem: _FakeFileSystem(
            contents: {'$root/package.json': '{"name":"@getpaseo/server"}'},
          ),
          moduleResolver: _FakeModuleResolver({
            '@getpaseo/server': '$root/dist/index.js',
          }),
        ).resolveDaemonRunnerEntrypoint(),
        _launchFailure(startsWith('Daemon runner source is missing at ')),
      );
    });

    test('an unpackaged resolve without a module resolver is a wiring bug', () {
      expect(
        () => _runtimePaths(
          isPackaged: false,
          fileSystem: _FakeFileSystem(),
        ).resolveDaemonRunnerEntrypoint(),
        _launchFailure(contains('NodeModuleResolver is required')),
      );
    });

    test(
      'binds the Helper exec path and asserted runner into an invocation',
      () {
        final invocation =
            _runtimePaths(
              fileSystem: _FakeFileSystem(
                present: {_macHelperPath, _packagedRunnerPath},
              ),
            ).createNodeEntrypointInvocation(
              entrypoint: _cliEntrypoint,
              argvMode: NodeEntrypointArgvMode.nodeScript,
              args: const ['daemon', 'status'],
              baseEnv: const {'PATH': '/usr/bin'},
            );

        expect(
          invocation,
          const NodeEntrypointInvocation(
            command: _macHelperPath,
            args: [
              '--disable-warning=DEP0040',
              _packagedRunnerPath,
              'node-script',
              '/tmp/paseo-cli.js',
              'daemon',
              'status',
            ],
            env: {
              'PATH': '/usr/bin',
              'ELECTRON_RUN_AS_NODE': '1',
              'PASEO_NODE_ENV': 'production',
            },
          ),
        );
      },
    );

    test('a packaged invocation fails when the bundled runner is missing', () {
      expect(
        () => _runtimePaths().createNodeEntrypointInvocation(
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const [],
          baseEnv: const {},
        ),
        _launchFailure(
          'Bundled node entrypoint runner is missing at $_packagedRunnerPath',
        ),
      );
    });

    test('an unpackaged invocation needs no runner and keeps execArgv', () {
      expect(
        _runtimePaths(
          isPackaged: false,
          execPath: '/opt/homebrew/bin/electron',
          fileSystem: _FakeFileSystem(),
        ).createNodeEntrypointInvocation(
          entrypoint: _cliEntrypoint,
          argvMode: NodeEntrypointArgvMode.nodeScript,
          args: const ['ls'],
          baseEnv: const {},
        ),
        const NodeEntrypointInvocation(
          command: '/opt/homebrew/bin/electron',
          args: ['--import', 'tsx', '/tmp/paseo-cli.js', 'ls'],
          env: {'ELECTRON_RUN_AS_NODE': '1'},
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // node-entrypoint-runner.ts
  // -------------------------------------------------------------------------

  group('node-entrypoint-runner', () {
    test(
      'preserves Electron node-mode env before loading the target entrypoint',
      () async {
        final host = _FakeRunnerHost(
          const [
            'Paseo',
            'runner',
            'node-script',
            '/tmp/fixture.mjs',
            'daemon',
            'start',
          ],
          env: const {
            'ELECTRON_RUN_AS_NODE': '1',
            'ELECTRON_NO_ATTACH_CONSOLE': '1',
          },
        );

        await runNodeEntrypointRunner(host: host);

        expect(host.argvAtImport, [
          'Paseo',
          '/tmp/fixture.mjs',
          'daemon',
          'start',
        ]);
        expect(host.importedUrls, ['file:///tmp/fixture.mjs']);
        expect(host.env, const {
          'ELECTRON_RUN_AS_NODE': '1',
          'ELECTRON_NO_ATTACH_CONSOLE': '1',
        });
      },
    );

    test('bare mode hides the entrypoint path from argv', () {
      expect(
        planNodeEntrypointRunner(const [
          'Paseo',
          'runner',
          'bare',
          '/tmp/cli.js',
          'status',
          '--json',
        ]).argv,
        ['Paseo', 'status', '--json'],
      );
    });

    test('node-script mode keeps the entrypoint path at argv[1]', () {
      final plan = planNodeEntrypointRunner(const [
        'Paseo',
        'runner',
        'node-script',
        '/tmp/cli.js',
        'status',
      ]);

      expect(plan.argvMode, NodeEntrypointArgvMode.nodeScript);
      expect(plan.entryPath, '/tmp/cli.js');
      expect(plan.argv, ['Paseo', '/tmp/cli.js', 'status']);
    });

    test('an entrypoint with no trailing args still rewrites argv', () {
      expect(
        planNodeEntrypointRunner(const [
          'Paseo',
          'runner',
          'node-script',
          '/tmp/cli.js',
        ]).argv,
        ['Paseo', '/tmp/cli.js'],
      );
      expect(
        planNodeEntrypointRunner(const [
          'Paseo',
          'runner',
          'bare',
          '/tmp/cli.js',
        ]).argv,
        ['Paseo'],
      );
    });

    test('a missing argv mode is reported as <missing>', () {
      expect(
        () => planNodeEntrypointRunner(const ['Paseo', 'runner']),
        _launchFailure('Unsupported node entrypoint argv mode: <missing>'),
      );
      expect(
        () => planNodeEntrypointRunner(const []),
        _launchFailure('Unsupported node entrypoint argv mode: <missing>'),
      );
    });

    test('an unknown argv mode is echoed verbatim', () {
      expect(
        () => planNodeEntrypointRunner(const [
          'Paseo',
          'runner',
          'esm',
          '/tmp/cli.js',
        ]),
        _launchFailure('Unsupported node entrypoint argv mode: esm'),
      );
    });

    test('an empty argv mode is echoed as empty, not as <missing>', () {
      expect(
        () => planNodeEntrypointRunner(const [
          'Paseo',
          'runner',
          '',
          '/tmp/cli.js',
        ]),
        _launchFailure('Unsupported node entrypoint argv mode: '),
      );
    });

    test('a missing or blank entrypoint path is rejected', () {
      expect(
        () => planNodeEntrypointRunner(const ['Paseo', 'runner', 'bare']),
        _launchFailure('Missing node entrypoint path.'),
      );
      expect(
        () => planNodeEntrypointRunner(const ['Paseo', 'runner', 'bare', '']),
        _launchFailure('Missing node entrypoint path.'),
      );
    });

    test('a failing plan never touches argv or imports anything', () async {
      final host = _FakeRunnerHost(const ['Paseo', 'runner', 'esm', '/x.js']);

      await expectLater(
        runNodeEntrypointRunner(host: host),
        _launchFailure(startsWith('Unsupported node entrypoint argv mode')),
      );
      expect(host.argv, const ['Paseo', 'runner', 'esm', '/x.js']);
      expect(host.importedUrls, isEmpty);
    });

    test('the runner converts Windows entry paths to file URLs', () async {
      final host = _FakeRunnerHost(const [
        'Paseo.exe',
        'runner',
        'node-script',
        r'C:\tmp\cli.js',
      ]);

      await runNodeEntrypointRunner(host: host, paths: DesktopPathOps.windows);

      expect(host.importedUrls, ['file:///C:/tmp/cli.js']);
    });

    test('failures are formatted as a single newline-terminated write', () {
      expect(
        formatNodeEntrypointRunnerFailure(
          const DesktopDaemonLaunchException('Missing node entrypoint path.'),
        ),
        'Missing node entrypoint path.\n',
      );
      expect(formatNodeEntrypointRunnerFailure('boom'), 'boom\n');
      expect(
        formatNodeEntrypointRunnerFailure(
          const DesktopDaemonLaunchException('boom'),
          StackTrace.fromString('#0 frame'),
        ),
        'boom\n#0 frame\n',
      );
      expect(nodeEntrypointRunnerFailureExitCode, 1);
    });
  });

  // -------------------------------------------------------------------------
  // cli/passthrough.ts
  // -------------------------------------------------------------------------

  group('passthrough CLI', () {
    test('returns null when no CLI args are provided', () {
      expect(
        parsePassthroughCliArgs(
          argv: const [_macExecPath],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
    });

    test('ignores macOS GUI launch arguments', () {
      expect(
        parsePassthroughCliArgs(
          argv: const [_macExecPath, '-psn_0_12345'],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
    });

    test('ignores --no-sandbox injected by Linux wrapper', () {
      expect(
        parsePassthroughCliArgs(
          argv: const ['/usr/bin/Paseo', '--no-sandbox', 'status'],
          isDefaultApp: false,
          forceCli: false,
        ),
        ['status'],
      );
    });

    test('returns null when only --no-sandbox is present', () {
      expect(
        parsePassthroughCliArgs(
          argv: const ['/usr/bin/Paseo', '--no-sandbox'],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
    });

    test('ignores Electron remote debugging switches', () {
      expect(
        parsePassthroughCliArgs(
          argv: const ['/usr/bin/Paseo', '--remote-debugging-port=9233'],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
    });

    test('preserves CLI flags for direct app invocations', () {
      expect(
        parsePassthroughCliArgs(
          argv: const [_macExecPath, '--version'],
          isDefaultApp: false,
          forceCli: false,
        ),
        ['--version'],
      );
    });

    test('passes --open-project through as a normal CLI arg', () {
      expect(
        parsePassthroughCliArgs(
          argv: const [_macExecPath, '--open-project', '/tmp/project'],
          isDefaultApp: false,
          forceCli: false,
        ),
        ['--open-project', '/tmp/project'],
      );
    });

    test('forces CLI mode for shim launches even without args', () {
      expect(
        parsePassthroughCliArgs(
          argv: const [_macExecPath],
          isDefaultApp: false,
          forceCli: true,
        ),
        isEmpty,
      );
    });

    test('skips the project path argument for an unpackaged Electron run', () {
      expect(
        parsePassthroughCliArgs(
          argv: const ['electron', '.', 'daemon', 'status'],
          isDefaultApp: true,
          forceCli: false,
        ),
        ['daemon', 'status'],
      );
    });

    test('tolerates an argv shorter than the start index', () {
      expect(
        parsePassthroughCliArgs(
          argv: const ['electron'],
          isDefaultApp: true,
          forceCli: false,
        ),
        isNull,
      );
      expect(
        parsePassthroughCliArgs(
          argv: const [],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
    });

    test('the ignore list is prefix-matched, not exact', () {
      // Documents the upstream looseness rather than endorsing it: a switch
      // that merely starts with an ignored prefix is dropped too.
      expect(
        parsePassthroughCliArgs(
          argv: const ['/usr/bin/Paseo', '--no-sandboxing', '-psn_1_2'],
          isDefaultApp: false,
          forceCli: false,
        ),
        isNull,
      );
      expect(ignoredPassthroughArgPrefixes, [
        '-psn_',
        '--no-sandbox',
        '--remote-debugging-port=',
      ]);
    });

    test('parses terminal args for direct app CLI passthrough', () {
      expect(
        parsePassthroughCliArgsFromArgv(
          argv: const [_macExecPath, 'daemon', 'set-password'],
          environment: const PassthroughCliLaunchEnvironment(
            isDefaultApp: false,
          ),
        ),
        ['daemon', 'set-password'],
      );
    });

    test('PASEO_DESKTOP_CLI forces CLI mode only on an exact "1"', () {
      expect(
        parsePassthroughCliArgsFromArgv(
          argv: const [_macExecPath],
          environment: const PassthroughCliLaunchEnvironment(
            isDefaultApp: false,
            environment: {'PASEO_DESKTOP_CLI': '1'},
          ),
        ),
        isEmpty,
      );
      expect(
        parsePassthroughCliArgsFromArgv(
          argv: const [_macExecPath],
          environment: const PassthroughCliLaunchEnvironment(
            isDefaultApp: false,
            environment: {'PASEO_DESKTOP_CLI': 'true'},
          ),
        ),
        isNull,
      );
      expect(paseoDesktopCliEnvVar, 'PASEO_DESKTOP_CLI');
    });

    test('runs passthrough CLI through the programmatic entrypoint', () async {
      final calls = <List<String>>[];
      Future<int> runCli(List<String> argv) async {
        calls.add(argv);
        return 7;
      }

      await expectLater(
        runPassthroughCli(const ['daemon', 'set-password'], runCli: runCli),
        completion(7),
      );
      expect(calls, [
        ['daemon', 'set-password'],
      ]);
    });

    test(
      'loads runCli from the resolved entrypoint when not injected',
      () async {
        final loader = _FakePassthroughLoader(
          entrypoint: '/repo/packages/cli/dist/run.js',
          runCli: (argv) async => 3,
        );

        await expectLater(
          runPassthroughCli(const ['status'], loader: loader),
          completion(3),
        );
        expect(loader.resolveCount, 1);
        expect(loader.loaded, ['/repo/packages/cli/dist/run.js']);
      },
    );

    test('an injected runCli short-circuits the loader entirely', () async {
      final loader = _FakePassthroughLoader(entrypoint: '/unused.js');

      await expectLater(
        runPassthroughCli(
          const ['status'],
          runCli: (argv) async => 0,
          loader: loader,
        ),
        completion(0),
      );
      expect(loader.resolveCount, 0);
    });

    test('names the entrypoint when it does not export runCli', () async {
      final loader = _FakePassthroughLoader(
        entrypoint: '/repo/packages/cli/dist/run.js',
      );

      await expectLater(
        runPassthroughCli(const ['status'], loader: loader),
        _launchFailure(
          'Passthrough CLI entrypoint did not export runCli: '
          '/repo/packages/cli/dist/run.js',
        ),
      );
    });

    test('omitting both runCli and the loader is a wiring bug', () async {
      await expectLater(
        runPassthroughCli(const ['status']),
        _launchFailure(contains('requires either runCli')),
      );
    });
  });

  // -------------------------------------------------------------------------
  // cli/external.ts
  // -------------------------------------------------------------------------

  group('external CLI', () {
    const invocationEntrypoint = NodeEntrypointSpec(
      entryPath: 'cli.js',
      execArgv: [],
    );
    const stubInvocation = NodeEntrypointInvocation(
      command: 'node',
      args: ['runner.js', 'node-script', 'cli.js'],
      env: {'PASEO_NODE_ENV': 'production'},
    );
    const baseEnv = {'PATH': '/usr/bin'};

    late List<Map<String, Object?>> invocationCalls;
    late _FakeLogger logger;

    ExternalCliCommands commands(List<ExternalCliResult> results) {
      invocationCalls = [];
      logger = _FakeLogger();
      return ExternalCliCommands(
        resolveEntrypoint: () => invocationEntrypoint,
        createInvocation:
            ({
              required NodeEntrypointSpec entrypoint,
              required NodeEntrypointArgvMode argvMode,
              required List<String> args,
              required Map<String, String> baseEnv,
            }) {
              invocationCalls.add({
                'entrypoint': entrypoint,
                'argvMode': argvMode,
                'args': args,
                'baseEnv': baseEnv,
              });
              return stubInvocation;
            },
        processRunner: _FakeProcessRunner(results),
        logger: logger,
        baseEnv: baseEnv,
      );
    }

    test('runs text commands through an isolated CLI process', () async {
      final cli = commands([
        const ExternalCliResult(
          stdout: 'daemon running\n',
          stderr: '',
          exitCode: 0,
        ),
      ]);

      await expectLater(
        cli.runTextCommand(const ['daemon', 'status']),
        completion('daemon running'),
      );

      expect(invocationCalls, [
        {
          'entrypoint': invocationEntrypoint,
          'argvMode': NodeEntrypointArgvMode.nodeScript,
          'args': const ['daemon', 'status'],
          'baseEnv': baseEnv,
        },
      ]);
      expect((cli.processRunner as _FakeProcessRunner).requests, const [
        ExternalCliSpawnRequest(
          command: 'node',
          args: ['runner.js', 'node-script', 'cli.js'],
          env: {'PASEO_NODE_ENV': 'production'},
          envMode: 'internal',
          stdio: ['ignore', 'pipe', 'pipe'],
        ),
      ]);
      expect(logger.warnings, isEmpty);
    });

    test('parses JSON output from an isolated CLI process', () async {
      final cli = commands([
        const ExternalCliResult(
          stdout: '{"localDaemon":"running"}\n',
          stderr: '',
          exitCode: 0,
        ),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['daemon', 'status', '--json']),
        completion({'localDaemon': 'running'}),
      );
    });

    test('only the trailing whitespace is stripped from text output', () async {
      final cli = commands([
        const ExternalCliResult(
          stdout: '  indented\n\n',
          stderr: '',
          exitCode: 0,
        ),
      ]);

      await expectLater(
        cli.runTextCommand(const ['x']),
        completion('  indented'),
      );
    });

    test(
      'a failing text command surfaces stderr and logs a breadcrumb',
      () async {
        final cli = commands([
          const ExternalCliResult(
            stdout: 'partial\n',
            stderr: '  boom  \n',
            exitCode: 2,
          ),
        ]);

        await expectLater(
          cli.runTextCommand(const ['daemon', 'status']),
          _launchFailure('boom'),
        );
        expect(logger.warnings.single.scope, ExternalCliCommands.logScope);
        expect(logger.warnings.single.message, 'CLI text command failed');
        expect(logger.warnings.single.details, {
          'args': const ['daemon', 'status'],
          'exitCode': 2,
          'stdout': 'partial',
          'stderr': 'boom',
        });
      },
    );

    test('a silent failure reports the exit code and a stdout slice', () async {
      final cli = commands([
        ExternalCliResult(stdout: 'x' * 300, stderr: '', exitCode: 3),
      ]);

      await expectLater(
        cli.runTextCommand(const ['x']),
        _launchFailure(
          'CLI command failed with exit code 3\nstdout: ${'x' * 200}',
        ),
      );
    });

    test('a failure with neither stderr nor stdout reports only the code', () {
      expect(
        externalCliFailureMessage(exitCode: 9, stdout: '', stderr: ''),
        'CLI command failed with exit code 9',
      );
    });

    test('a signal-killed child reports a null exit code', () {
      expect(
        externalCliFailureMessage(exitCode: null, stdout: '', stderr: ''),
        'CLI command failed with exit code null',
      );
    });

    test('a failing JSON command logs the resolved command too', () async {
      final cli = commands([
        const ExternalCliResult(stdout: '', stderr: 'nope', exitCode: 1),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['daemon', 'status', '--json']),
        _launchFailure('nope'),
      );
      expect(logger.warnings.single.message, 'CLI JSON command failed');
      expect(logger.warnings.single.details['command'], 'node');
    });

    test('empty JSON output is rejected before parsing', () async {
      final cli = commands([
        const ExternalCliResult(stdout: '   \n', stderr: '', exitCode: 0),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['x']),
        _launchFailure('CLI command did not produce JSON output.'),
      );
      expect(logger.warnings.single.message, 'CLI command produced no output');
    });

    test('output with no JSON opener is rejected and echoed', () async {
      final cli = commands([
        const ExternalCliResult(
          stdout: 'not json at all',
          stderr: '',
          exitCode: 0,
        ),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['x']),
        _launchFailure(
          'CLI command output contained no JSON. Output: not json at all',
        ),
      );
      expect(
        logger.warnings.single.message,
        'CLI command output contained no JSON',
      );
    });

    test('a banner before the payload is discarded', () async {
      final cli = commands([
        const ExternalCliResult(
          stdout: 'warning: stale cache\n{"ok":true}\n',
          stderr: '',
          exitCode: 0,
        ),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['x']),
        completion({'ok': true}),
      );
    });

    test('an array payload is accepted as the JSON opener', () async {
      final cli = commands([
        const ExternalCliResult(stdout: '[1,2]', stderr: '', exitCode: 0),
      ]);

      await expectLater(cli.runJsonCommand(const ['x']), completion([1, 2]));
    });

    test('invalid JSON keeps the stable prefix and the cause', () async {
      final cli = commands([
        const ExternalCliResult(stdout: '{oops}', stderr: '', exitCode: 0),
      ]);

      await expectLater(
        cli.runJsonCommand(const ['x']),
        throwsA(
          isA<DesktopDaemonLaunchException>()
              .having(
                (error) => error.message,
                'message',
                startsWith('CLI command returned invalid JSON: '),
              )
              .having((error) => error.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('logged stdout and stderr are clamped to 500 characters', () async {
      final cli = commands([
        ExternalCliResult(stdout: 'a' * 900, stderr: 'b' * 900, exitCode: 4),
      ]);

      await expectLater(cli.runTextCommand(const ['x']), throwsA(anything));
      expect((logger.warnings.single.details['stdout']! as String).length, 500);
      expect((logger.warnings.single.details['stderr']! as String).length, 500);
    });
  });

  // -------------------------------------------------------------------------
  // quit-lifecycle.ts — daemon stop decision
  // -------------------------------------------------------------------------

  group('quit-lifecycle daemon stop', () {
    const keepRunning = DesktopSettings();
    const stopOnQuit = DesktopSettings(keepRunningAfterQuit: false);

    test('only stops when keepRunningAfterQuit is explicitly disabled', () {
      expect(shouldStopDesktopManagedDaemonOnQuit(stopOnQuit), isTrue);
      expect(shouldStopDesktopManagedDaemonOnQuit(keepRunning), isFalse);
    });

    test('reuses the daemon status predicate from the management rules', () {
      expect(isDesktopManagedDaemonRunning(_daemonStatus()), isTrue);
      expect(
        isDesktopManagedDaemonRunning(_daemonStatus(desktopManaged: false)),
        isFalse,
      );
      expect(
        isDesktopManagedDaemonRunning(_daemonStatus(desktopManaged: null)),
        isFalse,
      );
      expect(
        isDesktopManagedDaemonRunning(
          _daemonStatus(health: DaemonHealth.stopped),
        ),
        isFalse,
      );
      expect(isDesktopManagedDaemonRunning(null), isFalse);
    });

    test(
      'short-circuits without inspecting the daemon when keep-running is on',
      () async {
        final events = <String>[];

        final stopped = await stopDesktopManagedDaemonOnQuitIfNeeded(
          StopOnQuitPorts(
            readSettings: () async => keepRunning,
            isDesktopManagedDaemonRunning: () {
              events.add('inspect');
              return true;
            },
            stopDaemon: () async => events.add('stop'),
            showShutdownFeedback: () => events.add('feedback'),
          ),
        );

        expect(stopped, isFalse);
        expect(events, isEmpty);
      },
    );

    test('does not stop a manually started daemon on quit', () async {
      final events = <String>[];

      final stopped = await stopDesktopManagedDaemonOnQuitIfNeeded(
        StopOnQuitPorts(
          readSettings: () async => stopOnQuit,
          isDesktopManagedDaemonRunning: () => false,
          stopDaemon: () async => events.add('stop'),
          showShutdownFeedback: () => events.add('feedback'),
        ),
      );

      expect(stopped, isFalse);
      expect(events, isEmpty);
    });

    test('shows feedback then stops a desktop-managed daemon', () async {
      final events = <String>[];

      final stopped = await stopDesktopManagedDaemonOnQuitIfNeeded(
        StopOnQuitPorts(
          readSettings: () async => stopOnQuit,
          isDesktopManagedDaemonRunning: () => true,
          stopDaemon: () async => events.add('stop'),
          showShutdownFeedback: () => events.add('feedback'),
        ),
      );

      expect(stopped, isTrue);
      expect(events, ['feedback', 'stop']);
    });
  });

  // -------------------------------------------------------------------------
  // quit-lifecycle.ts — exit sequencing
  // -------------------------------------------------------------------------

  group('quit-lifecycle exit sequencing', () {
    test('a fresh deadline controller aborts once and stays aborted', () {
      final controller = QuitDeadlineController();

      expect(controller.isAborted, isFalse);
      controller.abort();
      controller.abort();
      expect(controller.isAborted, isTrue);
      expect(controller.onAbort, completes);
    });

    test('revalidates updates after daemon shutdown before exiting', () async {
      final stopDecision = Completer<bool>();
      final updateDecision = Completer<bool>();
      final events = <String>[];

      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: (code) => events.add('exit:$code'),
          closeTransportSessions: () => events.add('close-transports'),
          stopDesktopManagedDaemonIfNeeded: () => stopDecision.future,
          installAppUpdateOnQuit: (_) => updateDecision.future,
          createUpdateDeadlineSignal: QuitDeadlineController.new,
          onStopError: (_) => events.add('stop-error'),
          onUpdateError: (_) => events.add('update-error'),
        ),
      );

      quitLifecycle.handleBeforeQuit(
        preventDefault: () => events.add('prevent-default'),
      );

      expect(events, ['close-transports', 'prevent-default']);

      events.add('daemon-stopped');
      stopDecision.complete(false);
      await _flush();

      expect(events, ['close-transports', 'prevent-default', 'daemon-stopped']);

      events.add('update-checked');
      updateDecision.complete(false);
      await _flush();

      expect(events, [
        'close-transports',
        'prevent-default',
        'daemon-stopped',
        'update-checked',
        'exit:0',
      ]);

      quitLifecycle.handleBeforeQuit(
        preventDefault: () => events.add('second-prevent-default'),
      );

      expect(events.last, 'close-transports');
      expect(events, isNot(contains('second-prevent-default')));
    });

    test(
      'lets the updater own process exit when a validated update is installing',
      () async {
        final exits = <int>[];
        final quitLifecycle = createQuitLifecycle(
          QuitLifecyclePorts(
            exitApp: exits.add,
            closeTransportSessions: () {},
            stopDesktopManagedDaemonIfNeeded: () async => false,
            installAppUpdateOnQuit: (_) async => true,
            createUpdateDeadlineSignal: QuitDeadlineController.new,
            onStopError: (_) {},
            onUpdateError: (_) {},
          ),
        );

        quitLifecycle.handleBeforeQuit(preventDefault: () {});
        await _flush();
        quitLifecycle.handleBeforeQuitForUpdate();
        await _flush();

        expect(exits, isEmpty);
      },
    );

    test('recognizes a repeated quit as updater handoff', () async {
      final exits = <int>[];
      var preventedQuitCount = 0;
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: exits.add,
          closeTransportSessions: () {},
          stopDesktopManagedDaemonIfNeeded: () async => false,
          installAppUpdateOnQuit: (_) async => true,
          createUpdateDeadlineSignal: QuitDeadlineController.new,
          onStopError: (_) {},
          onUpdateError: (_) {},
        ),
      );

      quitLifecycle.handleBeforeQuit(
        preventDefault: () => preventedQuitCount++,
      );
      await _flush();
      quitLifecycle.handleBeforeQuit(
        preventDefault: () => preventedQuitCount++,
      );
      await _flush();

      expect(preventedQuitCount, 1);
      expect(exits, isEmpty);
    });

    test('repeated handoff evidence is idempotent', () async {
      final exits = <int>[];
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: exits.add,
          closeTransportSessions: () {},
          stopDesktopManagedDaemonIfNeeded: () async => false,
          installAppUpdateOnQuit: (_) async => true,
          createUpdateDeadlineSignal: QuitDeadlineController.new,
          onStopError: (_) {},
          onUpdateError: (_) {},
        ),
      );

      quitLifecycle.handleBeforeQuit(preventDefault: () {});
      await _flush();
      quitLifecycle.handleBeforeQuit(preventDefault: () {});
      quitLifecycle.handleBeforeQuitForUpdate();
      quitLifecycle.handleBeforeQuitForUpdate();
      await _flush();

      expect(exits, isEmpty);
    });

    test(
      'exits when the updater does not take ownership before its deadline',
      () async {
        final revalidationDeadline = QuitDeadlineController();
        final handoffDeadline = QuitDeadlineController();
        var deadlineCount = 0;
        final exits = <int>[];
        final quitLifecycle = createQuitLifecycle(
          QuitLifecyclePorts(
            exitApp: exits.add,
            closeTransportSessions: () {},
            stopDesktopManagedDaemonIfNeeded: () async => false,
            installAppUpdateOnQuit: (_) async => true,
            createUpdateDeadlineSignal: () =>
                deadlineCount++ == 0 ? revalidationDeadline : handoffDeadline,
            onStopError: (_) {},
            onUpdateError: (_) {},
          ),
        );

        quitLifecycle.handleBeforeQuit(preventDefault: () {});
        await _flush();
        handoffDeadline.abort();
        await _flush();

        expect(exits, [0]);
        expect(deadlineCount, 2);
      },
    );

    test('does not intercept a quit started by a manual update', () {
      final events = <String>[];
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: (code) => events.add('exit:$code'),
          closeTransportSessions: () => events.add('close-transports'),
          stopDesktopManagedDaemonIfNeeded: () async {
            events.add('stop-daemon');
            return false;
          },
          installAppUpdateOnQuit: (_) async {
            events.add('revalidate-update');
            return false;
          },
          createUpdateDeadlineSignal: QuitDeadlineController.new,
          onStopError: (_) => events.add('stop-error'),
          onUpdateError: (_) => events.add('update-error'),
        ),
      );

      quitLifecycle.handleBeforeQuitForUpdate();
      quitLifecycle.handleBeforeQuit(
        preventDefault: () => events.add('prevent-default'),
      );

      expect(events, ['close-transports']);
    });

    test('exits when update revalidation reaches its deadline', () async {
      final deadline = QuitDeadlineController();
      final updateDecision = Completer<bool>();
      final exits = <int>[];
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: exits.add,
          closeTransportSessions: () {},
          stopDesktopManagedDaemonIfNeeded: () async => false,
          installAppUpdateOnQuit: (_) => updateDecision.future,
          createUpdateDeadlineSignal: () => deadline,
          onStopError: (_) {},
          onUpdateError: (_) {},
        ),
      );

      quitLifecycle.handleBeforeQuit(preventDefault: () {});
      await _flush();
      deadline.abort();
      await _flush();

      expect(exits, [0]);

      updateDecision.complete(true);
      await _flush();
      expect(exits, [0]);
    });

    test('an already-aborted deadline exits without waiting', () async {
      final deadline = QuitDeadlineController()..abort();
      final exits = <int>[];
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: exits.add,
          closeTransportSessions: () {},
          stopDesktopManagedDaemonIfNeeded: () async => false,
          installAppUpdateOnQuit: (_) => Completer<bool>().future,
          createUpdateDeadlineSignal: () => deadline,
          onStopError: (_) {},
          onUpdateError: (_) {},
        ),
      );

      quitLifecycle.handleBeforeQuit(preventDefault: () {});
      await _flush();

      expect(exits, [0]);
    });

    test(
      'a failing daemon stop is reported but never blocks the quit',
      () async {
        final events = <String>[];
        final quitLifecycle = createQuitLifecycle(
          QuitLifecyclePorts(
            exitApp: (code) => events.add('exit:$code'),
            closeTransportSessions: () {},
            stopDesktopManagedDaemonIfNeeded: () async =>
                throw StateError('stop failed'),
            installAppUpdateOnQuit: (_) async => false,
            createUpdateDeadlineSignal: QuitDeadlineController.new,
            onStopError: (error) => events.add('stop-error:$error'),
            onUpdateError: (_) => events.add('update-error'),
          ),
        );

        quitLifecycle.handleBeforeQuit(preventDefault: () {});
        await _flush();

        expect(events, ['stop-error:Bad state: stop failed', 'exit:0']);
      },
    );

    test(
      'a failing update check is reported and treated as no update',
      () async {
        final events = <String>[];
        final quitLifecycle = createQuitLifecycle(
          QuitLifecyclePorts(
            exitApp: (code) => events.add('exit:$code'),
            closeTransportSessions: () {},
            stopDesktopManagedDaemonIfNeeded: () async => false,
            installAppUpdateOnQuit: (_) async =>
                throw StateError('update failed'),
            createUpdateDeadlineSignal: QuitDeadlineController.new,
            onStopError: (_) => events.add('stop-error'),
            onUpdateError: (error) => events.add('update-error:$error'),
          ),
        );

        quitLifecycle.handleBeforeQuit(preventDefault: () {});
        await _flush();

        expect(events, ['update-error:Bad state: update failed', 'exit:0']);
      },
    );

    test('the update deadline signal is handed to the installer', () async {
      final deadline = QuitDeadlineController();
      final seen = <QuitDeadlineSignal>[];
      final quitLifecycle = createQuitLifecycle(
        QuitLifecyclePorts(
          exitApp: (_) {},
          closeTransportSessions: () {},
          stopDesktopManagedDaemonIfNeeded: () async => false,
          installAppUpdateOnQuit: (signal) async {
            seen.add(signal);
            return false;
          },
          createUpdateDeadlineSignal: () => deadline,
          onStopError: (_) {},
          onUpdateError: (_) {},
        ),
      );

      quitLifecycle.handleBeforeQuit(preventDefault: () {});
      await _flush();

      expect(seen, [same(deadline)]);
    });
  });
}
