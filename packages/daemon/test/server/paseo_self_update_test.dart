import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/server/paseo_self_update.dart';
import 'package:agent_daemon/src/utils/paseo_process_utils.dart'
    show ExecCommandException;
import 'package:agent_protocol/agent_protocol.dart'
    show
        BranchOffCreateAgentWorktreeTarget,
        DaemonUpdatePhase,
        DaemonUpdateProgress,
        DaemonUpdateRequest,
        DaemonUpdateResponse;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// POSIX-shaped fixtures so path comparison is deterministic on every host: a
// path with no drive letter, namespace prefix or UNC prefix is always compared
// with the POSIX rules, whatever platform the suite runs on.
const String _globalRoot = '/global/pub-cache';
const String _cliPackagePath =
    '$_globalRoot/hosted/pub.dev/agent_daemon-0.1.15';
const String _globalPackagesRoot = '$_globalRoot/global_packages/agent_daemon';
const String _sourceDaemonPackageRoot = '/repo/packages/daemon';

GlobalCliInstall _install(
  String version, {
  bool linked = false,
  String? packagePath = _cliPackagePath,
  String? globalRootPath = _globalRoot,
}) => GlobalCliInstall(
  version: version,
  packagePath: packagePath,
  globalRootPath: globalRootPath,
  isLinked: linked,
);

void main() {
  // -------------------------------------------------------------------------
  // npm-global-cli.ts -> dart pub global
  // -------------------------------------------------------------------------

  group('PubGlobalTinyrackCli', () {
    test('inspects the global install with dart pub global list', () async {
      final calls = <_CommandCall>[];
      final cli = PubGlobalTinyrackCli(
        runCommand: _recordingRunner(
          calls,
          const GlobalCliCommandResult(
            exitCode: 0,
            stdout: 'coverage 1.15.1\nagent_daemon 0.1.15\n',
            stderr: '',
          ),
        ),
        environment: const {'PUB_CACHE': _globalRoot},
        isWindows: false,
      );

      await expectLater(
        cli.inspect(),
        completion(
          GlobalCliInstall(
            version: '0.1.15',
            packagePath: p.join(
              _globalRoot,
              'hosted',
              'pub.dev',
              'agent_daemon-0.1.15',
            ),
            globalRootPath: _globalRoot,
            isLinked: false,
          ),
        ),
      );
      expect(calls, hasLength(1));
      expect(calls.single.command, 'dart');
      expect(calls.single.arguments, ['pub', 'global', 'list']);
      expect(calls.single.timeout, const Duration(seconds: 10));
      expect(calls.single.maxBuffer, 10 * 1024 * 1024);
    });

    test('runs the global activate command for the latest cli', () async {
      final calls = <_CommandCall>[];
      final cli = PubGlobalTinyrackCli(
        runCommand: _recordingRunner(
          calls,
          const GlobalCliCommandResult(
            exitCode: 0,
            stdout: 'Activated agent_daemon 0.1.96.',
            stderr: '',
          ),
        ),
      );

      await expectLater(
        cli.installLatest(),
        completion(
          const GlobalCliCommandResult(
            exitCode: 0,
            stdout: 'Activated agent_daemon 0.1.96.',
            stderr: '',
          ),
        ),
      );
      expect(calls.single.command, 'dart');
      expect(calls.single.arguments, [
        'pub',
        'global',
        'activate',
        'agent_daemon',
      ]);
      expect(calls.single.timeout, const Duration(minutes: 5));
      expect(calls.single.maxBuffer, 10 * 1024 * 1024);
    });

    test('reports a missing toolchain when the probe exits without output', () {
      final cli = PubGlobalTinyrackCli(
        runCommand: _constantRunner(
          const GlobalCliCommandResult(
            exitCode: 127,
            stdout: '',
            stderr: 'dart: command not found',
          ),
        ),
      );

      expect(
        cli.inspect(),
        throwsA(
          isA<GlobalCliInspectionException>().having(
            (error) => error.message,
            'message',
            'dart: command not found',
          ),
        ),
      );
    });

    test('falls back to a generic message when the probe says nothing', () {
      final cli = PubGlobalTinyrackCli(
        runCommand: _constantRunner(
          const GlobalCliCommandResult(exitCode: 9, stdout: '', stderr: '   '),
        ),
      );

      expect(
        cli.inspect(),
        throwsA(
          isA<GlobalCliInspectionException>().having(
            (error) => error.message,
            'message',
            'dart is not available on this host',
          ),
        ),
      );
    });

    test('reports a missing global cli when the package is not listed', () {
      final cli = PubGlobalTinyrackCli(
        runCommand: _constantRunner(
          const GlobalCliCommandResult(
            exitCode: 0,
            stdout: 'coverage 1.15.1\npana 0.23.14\n',
            stderr: '',
          ),
        ),
      );

      expect(
        cli.inspect(),
        throwsA(
          isA<GlobalCliInspectionException>().having(
            (error) => error.message,
            'message',
            'agent_daemon is not installed with dart pub global on this host',
          ),
        ),
      );
    });

    test('still parses output when the probe exits non-zero', () async {
      final cli = PubGlobalTinyrackCli(
        runCommand: _constantRunner(
          const GlobalCliCommandResult(
            exitCode: 1,
            stdout: 'agent_daemon 0.1.15\n',
            stderr: 'some unrelated warning',
          ),
        ),
        environment: const {'PUB_CACHE': _globalRoot},
        isWindows: false,
      );

      final install = await cli.inspect();
      expect(install.version, '0.1.15');
      expect(install.isLinked, isFalse);
    });

    test('honours an alternate package and toolchain name', () async {
      final calls = <_CommandCall>[];
      final cli = PubGlobalTinyrackCli(
        runCommand: _recordingRunner(
          calls,
          const GlobalCliCommandResult(exitCode: 0, stdout: '', stderr: ''),
        ),
        packageName: 'tinyrack_relay',
        toolchainExecutable: 'flutter',
      );

      await cli.installLatest();
      expect(calls.single.command, 'flutter');
      expect(calls.single.arguments, [
        'pub',
        'global',
        'activate',
        'tinyrack_relay',
      ]);
    });
  });

  group('parsePubGlobalCliInstall', () {
    test(
      'derives the package path from the pub cache for a hosted activation',
      () {
        final install = parsePubGlobalCliInstall(
          'agent_daemon 0.2.0\n',
          packageName: 'agent_daemon',
          pubCacheRoot: _globalRoot,
        );

        expect(install, isNotNull);
        expect(install!.version, '0.2.0');
        expect(
          install.packagePath,
          p.join(_globalRoot, 'hosted', 'pub.dev', 'agent_daemon-0.2.0'),
        );
        expect(install.globalRootPath, _globalRoot);
        expect(install.isLinked, isFalse);
      },
    );

    test('treats a path activation as linked and keeps the reported path', () {
      final install = parsePubGlobalCliInstall(
        'agent_daemon 0.2.0 at path "$_sourceDaemonPackageRoot"\n',
        packageName: 'agent_daemon',
        pubCacheRoot: _globalRoot,
      );

      expect(install!.isLinked, isTrue);
      expect(install.packagePath, _sourceDaemonPackageRoot);
    });

    test('leaves the package path null when the pub cache is unresolvable', () {
      final install = parsePubGlobalCliInstall(
        'agent_daemon 0.2.0\n',
        packageName: 'agent_daemon',
      );

      expect(install!.packagePath, isNull);
      expect(install.globalRootPath, isNull);
    });

    test('returns null when the package is absent', () {
      expect(
        parsePubGlobalCliInstall(
          'coverage 1.15.1\n',
          packageName: 'agent_daemon',
        ),
        isNull,
      );
      expect(parsePubGlobalCliInstall('', packageName: 'agent_daemon'), isNull);
    });

    test('skips blank and unparseable lines instead of failing the read', () {
      final install = parsePubGlobalCliInstall(
        '\n   \nNo packages currently activated.\nagent_daemon 0.2.0\n',
        packageName: 'agent_daemon',
      );

      expect(install, isNotNull);
      expect(install!.version, '0.2.0');
    });

    test('does not match a package whose name merely shares a prefix', () {
      expect(
        parsePubGlobalCliInstall(
          'agent_daemon_extras 1.0.0\n',
          packageName: 'agent_daemon',
        ),
        isNull,
      );
    });

    test('keeps a git activation unlinked because it has no quoted path', () {
      final install = parsePubGlobalCliInstall(
        'agent_daemon 0.2.0 from Git repository\n',
        packageName: 'agent_daemon',
      );

      expect(install!.isLinked, isFalse);
      expect(install.packagePath, isNull);
    });
  });

  group('resolvePubCacheRoot', () {
    test('prefers an explicit PUB_CACHE', () {
      expect(
        resolvePubCacheRoot(
          environment: const {'PUB_CACHE': '/custom/cache', 'HOME': '/home/me'},
          isWindows: false,
        ),
        '/custom/cache',
      );
    });

    test('ignores a blank PUB_CACHE', () {
      expect(
        resolvePubCacheRoot(
          environment: const {'PUB_CACHE': '  ', 'HOME': '/home/me'},
          isWindows: false,
        ),
        p.join('/home/me', '.pub-cache'),
      );
    });

    test('uses LOCALAPPDATA on Windows and HOME elsewhere', () {
      expect(
        resolvePubCacheRoot(
          environment: const {'LOCALAPPDATA': r'C:\Users\me\AppData\Local'},
          isWindows: true,
        ),
        p.join(r'C:\Users\me\AppData\Local', 'Pub', 'Cache'),
      );
      expect(
        resolvePubCacheRoot(
          environment: const {'HOME': '/home/me'},
          isWindows: false,
        ),
        p.join('/home/me', '.pub-cache'),
      );
    });

    test('returns null when no anchor is available', () {
      expect(
        resolvePubCacheRoot(environment: const {}, isWindows: true),
        isNull,
      );
      expect(
        resolvePubCacheRoot(environment: const {}, isWindows: false),
        isNull,
      );
    });
  });

  group('globalCliResultFromFailure', () {
    test('maps an exec failure onto its exit code and streams', () {
      final result = globalCliResultFromFailure(
        const ExecCommandException(
          command: 'dart',
          arguments: ['pub', 'global', 'activate', 'agent_daemon'],
          exitCode: 66,
          stdout: 'partial',
          stderr: 'boom',
        ),
      );

      expect(result.exitCode, 66);
      expect(result.stdout, 'partial');
      expect(result.stderr, 'boom');
    });

    test('substitutes exit code 1 when the child never reported one', () {
      final result = globalCliResultFromFailure(
        const ExecCommandException(
          command: 'dart',
          arguments: [],
          exitCode: null,
          stdout: '',
          stderr: 'spawn failed',
        ),
      );

      expect(result.exitCode, 1);
    });

    test('falls back to the error message when stderr is blank', () {
      final result = globalCliResultFromFailure(
        const ExecCommandException(
          command: 'dart',
          arguments: [],
          exitCode: 3,
          stdout: '',
          stderr: '',
          reason: 'output exceeded maxBuffer',
        ),
      );

      expect(result.stderr, contains('output exceeded maxBuffer'));
    });

    test('reports an arbitrary throw as exit code 1 with no output', () {
      final result = globalCliResultFromFailure(StateError('unexpected'));

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, 'unexpected');
    });
  });

  // -------------------------------------------------------------------------
  // install-origin.ts
  // -------------------------------------------------------------------------

  group('validateDaemonInstallOrigin', () {
    String? validate({
      GlobalCliInstall? install,
      String? daemonVersion = '0.1.15',
      String? currentRoot = _cliPackagePath,
    }) => validateDaemonInstallOrigin(
      install: install ?? _install('0.1.15'),
      daemonVersion: daemonVersion,
      probe: _FakeInstallOriginProbe(currentRoot),
    );

    test('accepts a daemon running from the global package directory', () {
      expect(validate(), isNull);
    });

    test('accepts a daemon anywhere under the global install root', () {
      expect(validate(currentRoot: _globalPackagesRoot), isNull);
    });

    test('refuses a path activation', () {
      expect(
        validate(install: _install('0.1.15', linked: true)),
        'The global agent_daemon install is a path activation; '
        'self-update only supports normal global installs.',
      );
    });

    test('refuses a version disagreement', () {
      expect(
        validate(daemonVersion: '0.1.96'),
        'This daemon is not running from the global agent_daemon install '
        '(the global install has 0.1.15, daemon is 0.1.96).',
      );
    });

    test('skips the version check for a null daemon version', () {
      expect(validate(daemonVersion: null), isNull);
    });

    test('skips the version check for a blank daemon version', () {
      // JS truthiness: upstream's `if (daemonVersion && ...)` also skips on "".
      expect(validate(daemonVersion: ''), isNull);
    });

    test('refuses when the daemon package root cannot be located', () {
      expect(
        validate(currentRoot: null),
        'Unable to verify that this daemon is running from a global install.',
      );
    });

    test('refuses a daemon running from a source checkout', () {
      expect(
        validate(currentRoot: _sourceDaemonPackageRoot),
        'This daemon is not running from the global agent_daemon install.',
      );
    });

    test('refuses when the install reports no usable roots at all', () {
      expect(
        validate(
          install: _install('0.1.15', packagePath: null, globalRootPath: null),
        ),
        'This daemon is not running from the global agent_daemon install.',
      );
    });

    test('matches on the global root alone when no package path is known', () {
      expect(
        validate(
          install: _install('0.1.15', packagePath: null),
          currentRoot: _globalPackagesRoot,
        ),
        isNull,
      );
    });

    test('checks the path activation before the version disagreement', () {
      // Both rules fire; upstream's order means the link message wins.
      expect(
        validate(
          install: _install('0.1.15', linked: true),
          daemonVersion: '9.9.9',
        ),
        startsWith('The global agent_daemon install is a path activation'),
      );
    });
  });

  group('isRealpathInsideRoot', () {
    test('accepts the root itself and any descendant', () {
      expect(isRealpathInsideRoot('/a/b', '/a/b'), isTrue);
      expect(isRealpathInsideRoot('/a/b', '/a/b/c/d'), isTrue);
    });

    test('rejects siblings, parents and prefix look-alikes', () {
      expect(isRealpathInsideRoot('/a/b', '/a/c'), isFalse);
      expect(isRealpathInsideRoot('/a/b', '/a'), isFalse);
      expect(isRealpathInsideRoot('/a/b', '/a/bc'), isFalse);
    });

    test('ignores trailing separators and dot segments', () {
      expect(isRealpathInsideRoot('/a/b/', '/a/b/c'), isTrue);
      expect(isRealpathInsideRoot('/a/b', '/a/./b/c'), isTrue);
      expect(isRealpathInsideRoot('/a/b', '/a/b/c/../d'), isTrue);
      expect(isRealpathInsideRoot('/a/b', '/a/b/../c'), isFalse);
    });

    test('case-folds only when comparing as Windows', () {
      expect(
        isRealpathInsideRoot(r'C:\Global\Cache', r'c:\global\cache\hosted'),
        isTrue,
      );
      expect(isRealpathInsideRoot('/Global/Cache', '/global/cache'), isFalse);
    });

    test('normalizes separators inside a Windows comparison', () {
      expect(
        isRealpathInsideRoot(r'C:\Global\Cache', 'C:/Global/Cache/hosted'),
        isTrue,
      );
    });

    test('strips the Windows namespace prefix from either side', () {
      expect(
        isRealpathInsideRoot(r'\\?\C:\Global\Cache', r'C:\Global\Cache\hosted'),
        isTrue,
      );
      expect(
        isRealpathInsideRoot(r'C:\Global\Cache', r'\\?\C:\Global\Cache\hosted'),
        isTrue,
      );
    });

    test('handles UNC roots', () {
      expect(
        isRealpathInsideRoot(r'\\server\share', r'\\server\share\pub'),
        isTrue,
      );
      expect(
        isRealpathInsideRoot(r'\\server\share', r'\\server\other\pub'),
        isFalse,
      );
    });

    test('rejects rather than throwing on mixed absolute/relative input', () {
      expect(isRealpathInsideRoot('/a/b', 'relative/path'), isFalse);
    });

    test(
      'compares real filesystem paths through their resolved form',
      () async {
        final temp = Directory.systemTemp.createTempSync('paseo_self_update_');
        addTearDown(() {
          try {
            temp.deleteSync(recursive: true);
          } on Object {
            // Best effort; Windows sometimes holds the handle briefly.
          }
        });

        final root = Directory(p.join(temp.path, 'root'))..createSync();
        final nested = Directory(p.join(root.path, 'nested'))..createSync();

        expect(isRealpathInsideRoot(root.path, nested.path), isTrue);
        expect(isRealpathInsideRoot(nested.path, root.path), isFalse);
      },
    );
  });

  group('FilesystemDaemonInstallOriginProbe', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('paseo_self_update_probe_');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on Object {
        // Best effort.
      }
    });

    test('walks upward to the pubspec that names the daemon package', () {
      final packageRoot = Directory(p.join(temp.path, 'agent_daemon'))
        ..createSync();
      File(
        p.join(packageRoot.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: agent_daemon\nversion: 0.2.0\n');
      final deep = Directory(p.join(packageRoot.path, 'lib', 'src'))
        ..createSync(recursive: true);

      final probe = FilesystemDaemonInstallOriginProbe(
        startDirectory: deep.path,
      );

      expect(
        probe.resolveCurrentDaemonPackageRoot(),
        p.normalize(p.absolute(packageRoot.path)),
      );
    });

    test('skips a pubspec that names a different package', () {
      final workspaceRoot = Directory(p.join(temp.path, 'workspace'))
        ..createSync();
      File(
        p.join(workspaceRoot.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: agent_daemon\n');
      final member = Directory(p.join(workspaceRoot.path, 'packages', 'other'))
        ..createSync(recursive: true);
      File(
        p.join(member.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: something_else\n');

      final probe = FilesystemDaemonInstallOriginProbe(
        startDirectory: member.path,
      );

      expect(
        probe.resolveCurrentDaemonPackageRoot(),
        p.normalize(p.absolute(workspaceRoot.path)),
      );
    });

    test('ignores an indented name key belonging to a nested block', () {
      final packageRoot = Directory(p.join(temp.path, 'nested_name'))
        ..createSync();
      File(
        p.join(packageRoot.path, 'pubspec.yaml'),
      ).writeAsStringSync('dependencies:\n  name: agent_daemon\n');

      final probe = FilesystemDaemonInstallOriginProbe(
        startDirectory: packageRoot.path,
      );

      expect(probe.resolveCurrentDaemonPackageRoot(), isNull);
    });

    test('accepts a quoted name with a trailing comment', () {
      final packageRoot = Directory(p.join(temp.path, 'quoted'))..createSync();
      File(
        p.join(packageRoot.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: "agent_daemon" # the daemon\n');

      final probe = FilesystemDaemonInstallOriginProbe(
        startDirectory: packageRoot.path,
      );

      expect(
        probe.resolveCurrentDaemonPackageRoot(),
        p.normalize(p.absolute(packageRoot.path)),
      );
    });

    test('returns null when no pubspec names the package', () {
      final probe = FilesystemDaemonInstallOriginProbe(
        packageName: 'definitely_not_a_real_package_name',
        startDirectory: temp.path,
      );

      expect(probe.resolveCurrentDaemonPackageRoot(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // daemon-self-updater.ts
  // -------------------------------------------------------------------------

  group('DaemonSelfUpdater', () {
    test('refuses a desktop-managed daemon without touching the cli', () async {
      final cli = _FakeGlobalCli(inspections: []);
      final run = await _runUpdate(cli: cli, desktopManaged: true);

      expect(
        run.result,
        const DaemonSelfUpdateResult(
          success: false,
          error: desktopManagedSelfUpdateError,
          newVersion: null,
        ),
      );
      expect(run.phases, isEmpty);
      expect(cli.calls, isEmpty);
      expect(run.logger.errors, isEmpty);
    });

    test('updates a daemon running from the global cli install', () async {
      final cli = _FakeGlobalCli(
        inspections: [_install('0.1.15'), _install('0.1.96')],
      );
      final run = await _runUpdate(cli: cli);

      expect(
        run.result,
        const DaemonSelfUpdateResult(
          success: true,
          error: null,
          newVersion: '0.1.96',
        ),
      );
      expect(run.phases, [
        DaemonUpdatePhase.starting,
        DaemonUpdatePhase.downloading,
        DaemonUpdatePhase.installing,
        DaemonUpdatePhase.complete,
      ]);
      expect(cli.calls, ['inspect', 'installLatest', 'inspect']);
    });

    test('does not install when the global cli is missing', () async {
      final cli = _FakeGlobalCli(
        inspections: [
          const GlobalCliInspectionException(
            'agent_daemon is not installed with dart pub global on this host',
          ),
        ],
      );
      final run = await _runUpdate(cli: cli);

      expect(run.result.success, isFalse);
      expect(
        run.result.error,
        'agent_daemon is not installed with dart pub global on this host',
      );
      expect(run.phases, [DaemonUpdatePhase.starting]);
      expect(cli.calls, ['inspect']);
      expect(
        run.logger.errors.single.message,
        'Daemon self-update failed with exception',
      );
    });

    test('does not update when the daemon version does not match', () async {
      final cli = _FakeGlobalCli(inspections: [_install('0.1.15')]);
      final run = await _runUpdate(cli: cli, daemonVersion: '0.1.96');

      expect(run.result.success, isFalse);
      expect(
        run.result.error,
        'This daemon is not running from the global agent_daemon install '
        '(the global install has 0.1.15, daemon is 0.1.96).',
      );
      expect(run.result.newVersion, isNull);
      expect(cli.calls, ['inspect']);
    });

    test('does not update a daemon outside the global package tree', () async {
      final cli = _FakeGlobalCli(inspections: [_install('0.1.15')]);
      final run = await _runUpdate(
        cli: cli,
        currentDaemonPackageRoot: _sourceDaemonPackageRoot,
      );

      expect(
        run.result,
        const DaemonSelfUpdateResult(
          success: false,
          error:
              'This daemon is not running from the global agent_daemon install.',
          newVersion: null,
        ),
      );
      expect(cli.calls, ['inspect']);
    });

    test('does not update path-activated installs', () async {
      final cli = _FakeGlobalCli(
        inspections: [_install('0.1.15', linked: true)],
      );
      final run = await _runUpdate(cli: cli);

      expect(run.result.success, isFalse);
      expect(
        run.result.error,
        'The global agent_daemon install is a path activation; '
        'self-update only supports normal global installs.',
      );
      expect(cli.calls, ['inspect']);
    });

    test('reports the installer stderr when the install fails', () async {
      final cli = _FakeGlobalCli(
        inspections: [_install('0.1.15')],
        installResult: const GlobalCliCommandResult(
          exitCode: 65,
          stdout: 'Resolving dependencies...',
          stderr: '  Could not find a file named "pubspec.yaml".  ',
        ),
      );
      final run = await _runUpdate(cli: cli);

      expect(run.result.success, isFalse);
      expect(run.result.error, 'Could not find a file named "pubspec.yaml".');
      expect(run.result.newVersion, isNull);
      // The completion phase is never reported for a failed install.
      expect(run.phases, [
        DaemonUpdatePhase.starting,
        DaemonUpdatePhase.downloading,
        DaemonUpdatePhase.installing,
      ]);
      expect(cli.calls, ['inspect', 'installLatest']);
      expect(run.logger.errors.single.message, 'Daemon self-update failed');
      expect(run.logger.errors.single.context['exitCode'], 65);
    });

    test(
      'falls back to stdout when the failing install wrote no stderr',
      () async {
        final cli = _FakeGlobalCli(
          inspections: [_install('0.1.15')],
          installResult: const GlobalCliCommandResult(
            exitCode: 1,
            stdout: '  version solving failed  ',
            stderr: '   ',
          ),
        );
        final run = await _runUpdate(cli: cli);

        expect(run.result.error, 'version solving failed');
      },
    );

    test('falls back to the exit code when the install said nothing', () async {
      final cli = _FakeGlobalCli(
        inspections: [_install('0.1.15')],
        installResult: const GlobalCliCommandResult(
          exitCode: 7,
          stdout: '',
          stderr: '',
        ),
      );
      final run = await _runUpdate(cli: cli);

      expect(run.result.error, 'The global install command exited with code 7');
    });

    test('succeeds with a null version when the re-probe fails', () async {
      final cli = _FakeGlobalCli(
        inspections: [
          _install('0.1.15'),
          const GlobalCliInspectionException('cache is locked'),
        ],
      );
      final run = await _runUpdate(cli: cli);

      expect(
        run.result,
        const DaemonSelfUpdateResult(
          success: true,
          error: null,
          newVersion: null,
        ),
      );
      expect(run.phases.last, DaemonUpdatePhase.complete);
      expect(run.logger.errors, isEmpty);
      expect(
        run.logger.warnings.single.message,
        'Unable to read updated global install version',
      );
    });

    test('rejects concurrent update requests', () async {
      final cli = _FakeGlobalCli(
        inspections: [_install('0.1.15'), _install('0.1.96')],
      )..gateInstall();
      final logger = _RecordingLogger();
      final updater = DaemonSelfUpdater(
        DaemonSelfUpdateRuntime(
          cli: cli,
          installOrigin: const _FakeInstallOriginProbe(_cliPackagePath),
        ),
      );

      DaemonSelfUpdateInput input() => DaemonSelfUpdateInput(
        daemonVersion: '0.1.15',
        desktopManaged: false,
        onProgress: (_) {},
        logger: logger,
      );

      final firstUpdate = updater.update(input());
      await cli.installStarted;
      expect(updater.isInProgress, isTrue);

      // Deviation: an `async` Dart function can never throw synchronously, so
      // the rejection is observed on the future — which is also how upstream's
      // async method rejects.
      await expectLater(
        updater.update(input()),
        throwsA(isA<DaemonSelfUpdateInProgressException>()),
      );

      cli.completeInstall(
        const GlobalCliCommandResult(
          exitCode: 0,
          stdout: 'updated',
          stderr: '',
        ),
      );
      final result = await firstUpdate;

      expect(result.success, isTrue);
      expect(cli.calls, ['inspect', 'installLatest', 'inspect']);
      expect(updater.isInProgress, isFalse);
    });

    test('releases the fence after a failed attempt', () async {
      final cli = _FakeGlobalCli(
        inspections: [
          const GlobalCliInspectionException('probe exploded'),
          _install('0.1.15'),
          _install('0.1.96'),
        ],
      );
      final probe = const _FakeInstallOriginProbe(_cliPackagePath);
      final updater = DaemonSelfUpdater(
        DaemonSelfUpdateRuntime(cli: cli, installOrigin: probe),
      );
      final logger = _RecordingLogger();

      DaemonSelfUpdateInput input() => DaemonSelfUpdateInput(
        daemonVersion: '0.1.15',
        desktopManaged: false,
        onProgress: (_) {},
        logger: logger,
      );

      expect((await updater.update(input())).success, isFalse);
      expect(updater.isInProgress, isFalse);
      expect((await updater.update(input())).newVersion, '0.1.96');
    });

    test('turns an unexpected throw into a failed result', () async {
      final cli = _FakeGlobalCli(inspections: [StateError('disk on fire')]);
      final run = await _runUpdate(cli: cli);

      expect(
        run.result,
        const DaemonSelfUpdateResult(
          success: false,
          error: 'disk on fire',
          newVersion: null,
        ),
      );
      expect(
        run.logger.errors.single.message,
        'Daemon self-update failed with exception',
      );
    });
  });

  // -------------------------------------------------------------------------
  // daemon-self-update-session-controller.ts
  // -------------------------------------------------------------------------

  group('DaemonSelfUpdateSessionController', () {
    test('returns null synchronously for another subsystem\'s message', () {
      final harness = _ControllerHarness(
        updater: _FakeUpdater((_) => throw StateError('update should not run')),
      );

      final result = harness.controller.dispatch(const {
        'type': 'daemon.get_status.request',
        'requestId': 'status-1',
      });

      expect(result, isNull);
      expect(harness.emitted, isEmpty);
      expect(harness.restartIntents, isEmpty);
    });

    test('emits progress, response and a restart intent on success', () async {
      final harness = _ControllerHarness(
        updater: _FakeUpdater((input) async {
          input.onProgress(DaemonUpdatePhase.starting);
          input.onProgress(DaemonUpdatePhase.installing);
          return const DaemonSelfUpdateResult(
            success: true,
            error: null,
            newVersion: '0.1.96',
          );
        }),
      );

      await harness.controller.dispatch(_updateRequest);

      expect(harness.updater.lastInput?.daemonVersion, '0.1.15');
      expect(harness.updater.lastInput?.desktopManaged, isFalse);
      expect(harness.emitted, [
        {
          'type': DaemonUpdateProgress.type,
          'payload': {'requestId': 'update-1', 'phase': 'starting'},
        },
        {
          'type': DaemonUpdateProgress.type,
          'payload': {'requestId': 'update-1', 'phase': 'installing'},
        },
        {
          'type': DaemonUpdateResponse.type,
          'payload': {
            'requestId': 'update-1',
            'success': true,
            'error': null,
            'previousVersion': '0.1.15',
            'newVersion': '0.1.96',
          },
        },
      ]);
      expect(harness.restartIntents, [
        const DaemonSelfUpdateRestartIntent(
          clientId: 'client-1',
          requestId: 'update-1',
          reason: 'daemon_update',
        ),
      ]);
    });

    test('emits a failed response without a restart intent', () async {
      final harness = _ControllerHarness(
        desktopManaged: true,
        updater: _FakeUpdater(
          (_) async => const DaemonSelfUpdateResult(
            success: false,
            error: 'not a global install',
            newVersion: null,
          ),
        ),
      );

      await harness.controller.dispatch(_updateRequest);

      expect(harness.updater.lastInput?.desktopManaged, isTrue);
      expect(harness.emitted, [
        {
          'type': DaemonUpdateResponse.type,
          'payload': {
            'requestId': 'update-1',
            'success': false,
            'error': 'not a global install',
            'previousVersion': '0.1.15',
            'newVersion': null,
          },
        },
      ]);
      expect(harness.restartIntents, isEmpty);
    });

    test('maps a concurrent update onto rpc_error', () async {
      final harness = _ControllerHarness(
        updater: _FakeUpdater(
          (_) async => throw const DaemonSelfUpdateInProgressException(),
        ),
      );

      await harness.controller.dispatch(_updateRequest);

      expect(harness.emitted, [
        {
          'type': 'rpc_error',
          'payload': {
            'requestId': 'update-1',
            'requestType': DaemonUpdateRequest.type,
            'error': 'An update is already in progress',
            'code': 'already_updating',
          },
        },
      ]);
      expect(harness.restartIntents, isEmpty);
      expect(harness.logger.errors, isEmpty);
    });

    test('turns an unexpected throw into a failed response', () async {
      final harness = _ControllerHarness(
        updater: _FakeUpdater((_) async => throw StateError('kaboom')),
      );

      await harness.controller.dispatch(_updateRequest);

      expect(harness.emitted, [
        {
          'type': DaemonUpdateResponse.type,
          'payload': {
            'requestId': 'update-1',
            'success': false,
            'error': 'kaboom',
            'previousVersion': '0.1.15',
            'newVersion': null,
          },
        },
      ]);
      expect(harness.restartIntents, isEmpty);
      expect(
        harness.logger.errors.single.message,
        'Daemon update failed with exception',
      );
    });

    test('correlates on an empty id when requestId is absent', () async {
      final harness = _ControllerHarness(
        updater: _FakeUpdater((input) async {
          input.onProgress(DaemonUpdatePhase.starting);
          return const DaemonSelfUpdateResult(
            success: false,
            error: 'nope',
            newVersion: null,
          );
        }),
      );

      await harness.controller.dispatch(const {
        'type': DaemonUpdateRequest.type,
      });

      expect(
        harness.emitted.map((message) {
          return (message['payload']! as Map)['requestId'];
        }),
        ['', ''],
      );
    });

    test(
      'reports a null previousVersion when the daemon version is unknown',
      () async {
        final harness = _ControllerHarness(
          daemonVersion: null,
          updater: _FakeUpdater(
            (_) async => const DaemonSelfUpdateResult(
              success: true,
              error: null,
              newVersion: '0.2.0',
            ),
          ),
        );

        await harness.controller.dispatch(_updateRequest);

        expect(harness.updater.lastInput?.daemonVersion, isNull);
        final payload =
            harness.emitted.single['payload']! as Map<String, Object?>;
        expect(payload['previousVersion'], isNull);
        expect(payload['newVersion'], '0.2.0');
      },
    );

    test('recognises exactly the self-update message types', () {
      expect(
        isDaemonSelfUpdateMessage(const {'type': DaemonUpdateRequest.type}),
        isTrue,
      );
      expect(isDaemonSelfUpdateMessage(const {'type': 'ping'}), isFalse);
      expect(isDaemonSelfUpdateMessage(const {}), isFalse);
      expect(daemonSelfUpdateMessageTypes, {'daemon.update.request'});
    });
  });

  // -------------------------------------------------------------------------
  // hub/execution-controller.ts
  // -------------------------------------------------------------------------

  group('HubExecutionController', () {
    test(
      'cleanup fences in-flight creates before the dead session replies',
      () async {
        final agents = _FakeHubExecutionAgents()..gateCreate();
        final messages = <Map<String, Object?>>[];
        final controller = HubExecutionController(
          agents: agents,
          send: messages.add,
          pathContext: p.posix,
        );

        final create = controller.createAgent(_createRequest());
        await agents.creationStarted;

        final cleanup = controller.cleanup();
        agents.finishCreate(
          const OwnedAgentSnapshot(
            executionId: 'execution-shutdown',
            agent: {'id': 'agent-shutdown', 'status': 'running'},
          ),
        );
        await Future.wait([create, cleanup]);

        expect(messages, isEmpty);
        expect(agents.unsubscribeCount, 1);
      },
    );

    test('answers a successful create with the agent snapshot', () async {
      final agents = _FakeHubExecutionAgents(
        result: const OwnedAgentSnapshot(
          executionId: 'execution-1',
          agent: {'id': 'agent-1', 'status': 'running'},
        ),
      );
      final messages = <Map<String, Object?>>[];
      final controller = HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      await controller.createAgent(
        _createRequest(
          worktree: const BranchOffCreateAgentWorktreeTarget(
            newBranch: 'feature/hub',
            base: 'main',
          ),
          workspaceId: 'workspace-1',
          model: 'gpt-5',
          autoArchive: true,
        ),
      );

      expect(messages, [
        {
          'type': 'hub.execution.agent.create.response',
          'payload': {
            'requestId': 'shutdown-create',
            'executionId': 'execution-shutdown',
            'agentId': 'agent-1',
            'agent': {'id': 'agent-1', 'status': 'running'},
            'success': true,
            'error': null,
          },
        },
      ]);
      final input = agents.inputs.single;
      expect(input.executionId, 'execution-shutdown');
      expect(input.provider, 'codex');
      expect(input.workspaceId, 'workspace-1');
      expect(input.model, 'gpt-5');
      expect(input.autoArchive, isTrue);
      expect(input.worktree, isA<BranchOffCreateAgentWorktreeTarget>());
    });

    test('rejects blank required fields with upstream messages', () async {
      final cases = <({HubExecutionAgentCreateRequest request, String error})>[
        (
          request: _createRequest(executionId: '   '),
          error: 'Hub agent executionId cannot be blank',
        ),
        (
          request: _createRequest(prompt: ''),
          error: 'Hub agent prompt cannot be blank',
        ),
        (
          request: _createRequest(cwd: '\t'),
          error: 'Hub agent cwd cannot be blank',
        ),
      ];

      for (final entry in cases) {
        final agents = _FakeHubExecutionAgents();
        final messages = <Map<String, Object?>>[];
        final controller = HubExecutionController(
          agents: agents,
          send: messages.add,
          pathContext: p.posix,
        );

        await controller.createAgent(entry.request);

        final payload = messages.single['payload']! as Map<String, Object?>;
        expect(payload['success'], isFalse);
        expect(payload['error'], entry.error);
        expect(payload['agentId'], isNull);
        expect(payload['agent'], isNull);
        expect(agents.inputs, isEmpty);
      }
    });

    test('requires an absolute cwd under both path flavors', () async {
      for (final context in [p.posix, p.windows]) {
        final agents = _FakeHubExecutionAgents();
        final messages = <Map<String, Object?>>[];
        final controller = HubExecutionController(
          agents: agents,
          send: messages.add,
          pathContext: context,
        );

        await controller.createAgent(_createRequest(cwd: 'relative/dir'));

        final payload = messages.single['payload']! as Map<String, Object?>;
        expect(payload['error'], 'Hub agent cwd must be absolute');
        expect(agents.inputs, isEmpty);
      }
    });

    test('reports a create failure with the underlying message', () async {
      final agents = _FakeHubExecutionAgents(error: StateError('no capacity'));
      final messages = <Map<String, Object?>>[];
      final controller = HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      await controller.createAgent(_createRequest());

      final payload = messages.single['payload']! as Map<String, Object?>;
      expect(payload['success'], isFalse);
      expect(payload['error'], 'no capacity');
    });

    test('ignores creates requested after cleanup', () async {
      final agents = _FakeHubExecutionAgents(
        result: const OwnedAgentSnapshot(
          executionId: 'execution-1',
          agent: {'id': 'agent-1'},
        ),
      );
      final messages = <Map<String, Object?>>[];
      final controller = HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      await controller.cleanup();
      await controller.createAgent(_createRequest());

      expect(controller.isClosed, isTrue);
      expect(agents.inputs, isEmpty);
      expect(messages, isEmpty);
    });

    test('cleanup is idempotent and reuses one future', () async {
      final agents = _FakeHubExecutionAgents();
      final controller = HubExecutionController(
        agents: agents,
        send: (_) {},
        pathContext: p.posix,
      );

      final first = controller.cleanup();
      final second = controller.cleanup();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect(agents.unsubscribeCount, 1);
    });

    test('cleanup completes even when an in-flight create fails', () async {
      final agents = _FakeHubExecutionAgents()..gateCreate();
      final messages = <Map<String, Object?>>[];
      final controller = HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      final create = controller.createAgent(_createRequest());
      await agents.creationStarted;
      final cleanup = controller.cleanup();
      agents.failCreate(StateError('exploded'));

      await expectLater(Future.wait([create, cleanup]), completes);
      expect(messages, isEmpty);
    });

    test('forwards owned update and stream events', () {
      final agents = _FakeHubExecutionAgents();
      final messages = <Map<String, Object?>>[];
      HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      agents.emit(
        const OwnedAgentUpdateEvent(
          executionId: 'execution-1',
          agent: {'id': 'agent-1', 'status': 'idle'},
        ),
      );
      agents.emit(
        const OwnedAgentStreamEvent(
          executionId: 'execution-1',
          agentId: 'agent-1',
          event: {'type': 'message_delta'},
        ),
      );

      expect(messages, [
        {
          'type': 'hub.execution.agent.update',
          'payload': {
            'executionId': 'execution-1',
            'agentId': 'agent-1',
            'agent': {'id': 'agent-1', 'status': 'idle'},
          },
        },
        {
          'type': 'hub.execution.agent.stream',
          'payload': {
            'executionId': 'execution-1',
            'agentId': 'agent-1',
            'event': {'type': 'message_delta'},
          },
        },
      ]);
    });

    test('drops owned events once the session is closed', () async {
      final agents = _FakeHubExecutionAgents();
      final messages = <Map<String, Object?>>[];
      final controller = HubExecutionController(
        agents: agents,
        send: messages.add,
        pathContext: p.posix,
      );

      await controller.cleanup();
      agents.emit(
        const OwnedAgentUpdateEvent(
          executionId: 'execution-1',
          agent: {'id': 'agent-1'},
        ),
      );

      expect(messages, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const Map<String, Object?> _updateRequest = {
  'type': DaemonUpdateRequest.type,
  'requestId': 'update-1',
};

HubExecutionAgentCreateRequest _createRequest({
  String requestId = 'shutdown-create',
  String executionId = 'execution-shutdown',
  String provider = 'codex',
  String cwd = '/tmp/tinyrack',
  String prompt = 'sleep 30',
  String? workspaceId,
  String? model,
  bool? autoArchive,
  BranchOffCreateAgentWorktreeTarget? worktree,
}) => HubExecutionAgentCreateRequest(
  requestId: requestId,
  executionId: executionId,
  provider: provider,
  cwd: cwd,
  prompt: prompt,
  workspaceId: workspaceId,
  model: model,
  autoArchive: autoArchive,
  worktree: worktree,
);

final class _CommandCall {
  const _CommandCall({
    required this.command,
    required this.arguments,
    required this.timeout,
    required this.maxBuffer,
  });

  final String command;
  final List<String> arguments;
  final Duration? timeout;
  final int? maxBuffer;
}

GlobalCliCommandRunner _recordingRunner(
  List<_CommandCall> calls,
  GlobalCliCommandResult result,
) {
  return (command, arguments, {timeout, maxBuffer}) async {
    calls.add(
      _CommandCall(
        command: command,
        arguments: arguments,
        timeout: timeout,
        maxBuffer: maxBuffer,
      ),
    );
    return result;
  };
}

GlobalCliCommandRunner _constantRunner(GlobalCliCommandResult result) =>
    (command, arguments, {timeout, maxBuffer}) async => result;

final class _FakeInstallOriginProbe implements DaemonInstallOriginProbe {
  const _FakeInstallOriginProbe(this.root);

  final String? root;

  @override
  String? resolveCurrentDaemonPackageRoot() => root;
}

/// Records structured log calls so tests can assert on the summary message,
/// which is the only part upstream pins.
final class _RecordingLogger implements DaemonSelfUpdateLogger {
  final List<({Map<String, Object?> context, String? message})> errors = [];
  final List<({Map<String, Object?> context, String? message})> warnings = [];

  @override
  void error(Map<String, Object?> context, [String? message]) =>
      errors.add((context: context, message: message));

  @override
  void warn(Map<String, Object?> context, [String? message]) =>
      warnings.add((context: context, message: message));
}

/// Scripted [GlobalCliDistribution]: each `inspect()` consumes the next queued
/// outcome, and a queued non-install value is thrown instead of returned.
final class _FakeGlobalCli implements GlobalCliDistribution {
  _FakeGlobalCli({required List<Object> inspections, this.installResult})
    : _inspections = List<Object>.of(inspections);

  final List<Object> _inspections;
  final GlobalCliCommandResult? installResult;
  final List<String> calls = [];

  Completer<GlobalCliCommandResult>? _installGate;
  final Completer<void> _installStarted = Completer<void>();

  /// Completes once `installLatest()` has been entered.
  Future<void> get installStarted => _installStarted.future;

  /// Makes `installLatest()` block until [completeInstall] is called.
  void gateInstall() => _installGate = Completer<GlobalCliCommandResult>();

  void completeInstall(GlobalCliCommandResult result) =>
      _installGate!.complete(result);

  @override
  Future<GlobalCliInstall> inspect() async {
    calls.add('inspect');
    if (_inspections.isEmpty) {
      throw StateError('Unexpected global install inspection');
    }
    final next = _inspections.removeAt(0);
    if (next is GlobalCliInstall) return next;
    throw next;
  }

  @override
  Future<GlobalCliCommandResult> installLatest() {
    calls.add('installLatest');
    if (!_installStarted.isCompleted) _installStarted.complete();
    final gate = _installGate;
    if (gate != null) return gate.future;
    return Future<GlobalCliCommandResult>.value(
      installResult ??
          const GlobalCliCommandResult(
            exitCode: 0,
            stdout: 'Activated agent_daemon 0.1.96.',
            stderr: '',
          ),
    );
  }
}

typedef _UpdateRun = ({
  DaemonSelfUpdateResult result,
  _RecordingLogger logger,
  List<DaemonUpdatePhase> phases,
});

Future<_UpdateRun> _runUpdate({
  required _FakeGlobalCli cli,
  String? daemonVersion = '0.1.15',
  bool desktopManaged = false,
  String? currentDaemonPackageRoot = _cliPackagePath,
}) async {
  final logger = _RecordingLogger();
  final phases = <DaemonUpdatePhase>[];
  final updater = DaemonSelfUpdater(
    DaemonSelfUpdateRuntime(
      cli: cli,
      installOrigin: _FakeInstallOriginProbe(currentDaemonPackageRoot),
    ),
  );
  final result = await updater.update(
    DaemonSelfUpdateInput(
      daemonVersion: daemonVersion,
      desktopManaged: desktopManaged,
      onProgress: phases.add,
      logger: logger,
    ),
  );
  return (result: result, logger: logger, phases: phases);
}

final class _FakeUpdater implements DaemonSelfUpdatePerformer {
  _FakeUpdater(this._handler);

  final Future<DaemonSelfUpdateResult> Function(DaemonSelfUpdateInput input)
  _handler;

  DaemonSelfUpdateInput? lastInput;

  @override
  Future<DaemonSelfUpdateResult> update(DaemonSelfUpdateInput input) {
    lastInput = input;
    return _handler(input);
  }
}

final class _ControllerHarness {
  _ControllerHarness({
    required this.updater,
    String? daemonVersion = '0.1.15',
    bool desktopManaged = false,
  }) {
    controller = DaemonSelfUpdateSessionController(
      clientId: 'client-1',
      daemonVersion: daemonVersion,
      desktopManaged: desktopManaged,
      emit: emitted.add,
      emitLifecycleIntent: restartIntents.add,
      logger: logger,
      updater: updater,
    );
  }

  final _FakeUpdater updater;
  final _RecordingLogger logger = _RecordingLogger();
  final List<Map<String, Object?>> emitted = [];
  final List<DaemonSelfUpdateRestartIntent> restartIntents = [];

  late final DaemonSelfUpdateSessionController controller;
}

final class _FakeHubExecutionAgents implements HubExecutionAgents {
  _FakeHubExecutionAgents({this.result, this.error});

  final OwnedAgentSnapshot? result;
  final Object? error;

  final List<HubExecutionAgentCreateInput> inputs = [];
  final Completer<void> _createObserved = Completer<void>();
  Completer<OwnedAgentSnapshot>? _createGate;
  void Function(OwnedAgentEvent event)? _listener;
  int unsubscribeCount = 0;

  /// Completes once `create()` has been entered.
  Future<void> get creationStarted => _createObserved.future;

  /// Makes `create()` block until [finishCreate] or [failCreate].
  void gateCreate() => _createGate = Completer<OwnedAgentSnapshot>();

  void finishCreate(OwnedAgentSnapshot snapshot) =>
      _createGate!.complete(snapshot);

  void failCreate(Object failure) => _createGate!.completeError(failure);

  /// Pushes an event through the controller's subscription.
  void emit(OwnedAgentEvent event) => _listener?.call(event);

  @override
  Future<OwnedAgentSnapshot> create(HubExecutionAgentCreateInput input) {
    inputs.add(input);
    if (!_createObserved.isCompleted) _createObserved.complete();
    final gate = _createGate;
    if (gate != null) return gate.future;
    if (error != null) return Future<OwnedAgentSnapshot>.error(error!);
    return Future<OwnedAgentSnapshot>.value(result!);
  }

  @override
  void Function() subscribe(void Function(OwnedAgentEvent event) listener) {
    _listener = listener;
    return () {
      unsubscribeCount++;
      _listener = null;
    };
  }

  @override
  Future<void> invalidateAuthority() async {}
}
