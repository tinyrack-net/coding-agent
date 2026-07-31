// Ports of the upstream test suites for Paseo 0.2.0's desktop host-process
// cluster — `desktop-startup.test.ts`, `open-project-routing.test.ts`,
// `pending-open-project-store.test.ts`, `system/arm64-translation.test.ts`,
// `integrations/cli-install/path.test.ts`, `diagnostics/tail-file.test.ts` and
// `features/opener.test.ts` — together with the edge cases those suites leave
// unpinned: the argv-slicing and JS-truthiness arms of the open-project parser,
// every clearing path of the pending store, the memoisation of the ARM64
// detector, every branch of the CLI-install matrix, the `slice(-0)` and
// negative-`lines` quirks of `tailFile`, and the URL-parser deviations of the
// opener allowlist.
//
// Upstream reaches for the real filesystem (`mkdtempSync`, `writeFileSync`) in
// three of these suites. The ported rules take their filesystem access as
// injected ports, so the fakes below stand in for it and additionally let the
// tests assert what was *not* probed — an ordering guarantee the upstream
// suites cannot express.
import 'dart:async';

import 'package:coding_agent_app/desktop/paseo_desktop_startup.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records which filesystem questions the open-project parser asked, so a test
/// can pin that a relative argument never reaches the disk.
final class _FakeOpenProjectPathProbe implements OpenProjectPathProbe {
  _FakeOpenProjectPathProbe({
    this.absolutePaths = const <String>{},
    this.directories = const <String>{},
  });

  /// Convenience for the common case: every path listed is both absolute and
  /// an existing directory.
  factory _FakeOpenProjectPathProbe.withDirectories(
    Set<String> directories, {
    Set<String> extraAbsolutePaths = const <String>{},
  }) => _FakeOpenProjectPathProbe(
    absolutePaths: <String>{...directories, ...extraAbsolutePaths},
    directories: directories,
  );

  final Set<String> absolutePaths;
  final Set<String> directories;

  final List<String> absoluteChecks = <String>[];
  final List<String> directoryChecks = <String>[];

  @override
  bool isAbsolutePath(String candidate) {
    absoluteChecks.add(candidate);
    return absolutePaths.contains(candidate);
  }

  @override
  bool isExistingDirectory(String candidate) {
    directoryChecks.add(candidate);
    return directories.contains(candidate);
  }
}

/// One recorded `execFileSync` invocation.
final class _ExecCall {
  const _ExecCall(this.file, this.args, this.options);

  final String file;
  final List<String> args;
  final ExecFileSyncOptions options;
}

/// Stands in for Node's `execFileSync`, recording every call so the exact
/// command shape upstream pins stays pinned.
final class _FakeExecFileSync {
  _FakeExecFileSync({this.output = '', this.error});

  final String output;
  final Object? error;

  final List<_ExecCall> calls = <_ExecCall>[];

  int get callCount => calls.length;

  String call(String file, List<String> args, ExecFileSyncOptions options) {
    calls.add(_ExecCall(file, args, options));
    final Object? thrown = error;
    if (thrown != null) {
      throw thrown;
    }
    return output;
  }
}

/// Stands in for `readFileSync(path, "utf-8")`, mapping paths to contents and
/// raising [MissingFileError] for anything absent — the contract the port
/// documents.
final class _FakeTextFileReader {
  _FakeTextFileReader({
    this.files = const <String, String>{},
    this.failures = const <String, Object>{},
  });

  final Map<String, String> files;
  final Map<String, Object> failures;

  final List<String> reads = <String>[];

  String call(String filePath) {
    reads.add(filePath);
    final Object? failure = failures[filePath];
    if (failure != null) {
      throw failure;
    }
    final String? content = files[filePath];
    if (content == null) {
      throw MissingFileError(filePath);
    }
    return content;
  }
}

/// Captures the handlers `registerOpenerHandlers` installs, standing in for
/// Electron's `ipcMain`.
final class _FakeDesktopIpcRegistrar implements DesktopIpcRegistrar {
  final List<String> channels = <String>[];
  final Map<String, DesktopIpcHandler> handlers = <String, DesktopIpcHandler>{};

  @override
  void handle(String channel, DesktopIpcHandler handler) {
    channels.add(channel);
    handlers[channel] = handler;
  }
}

/// Stands in for `shell.openExternal`, recording every URL that reached the OS.
final class _FakeExternalUrlLauncher implements ExternalUrlLauncher {
  _FakeExternalUrlLauncher({this.result = true});

  final bool result;
  final List<String> opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}

/// Registers the opener against fresh fakes and returns the installed handler.
({
  DesktopIpcHandler handler,
  _FakeDesktopIpcRegistrar registrar,
  _FakeExternalUrlLauncher launcher,
})
_registerOpener({bool launcherResult = true}) {
  final registrar = _FakeDesktopIpcRegistrar();
  final launcher = _FakeExternalUrlLauncher(result: launcherResult);
  registerOpenerHandlers(registrar: registrar, launcher: launcher);
  final DesktopIpcHandler? handler = registrar.handlers[openerOpenUrlChannel];
  if (handler == null) {
    fail('open URL handler was not registered');
  }
  return (handler: handler, registrar: registrar, launcher: launcher);
}

void main() {
  // -------------------------------------------------------------------------
  // desktop-startup.ts
  // -------------------------------------------------------------------------
  group('runDesktopStartup', () {
    /// Mirrors upstream's `calls` array: every port appends its own name, so a
    /// single list assertion pins both *which* effects ran and their order.
    ({DesktopStartupPorts ports, List<String> calls}) buildPorts({
      required bool hasPendingGuiLaunchRequest,
      required bool cliPassthroughHandled,
      bool withSkills = false,
    }) {
      final calls = <String>[];
      return (
        calls: calls,
        ports: DesktopStartupPorts(
          hasPendingGuiLaunchRequest: hasPendingGuiLaunchRequest,
          runCliPassthroughIfRequested: () async {
            calls.add('cli');
            return cliPassthroughHandled;
          },
          inheritLoginShellEnv: () => calls.add('env'),
          bootstrapGui: () async => calls.add('gui'),
          autoUpdateInstalledSkills: withSkills
              ? () => calls.add('skills')
              : null,
        ),
      );
    }

    test(
      'runs CLI passthrough before GUI login-shell env inheritance',
      () async {
        final built = buildPorts(
          hasPendingGuiLaunchRequest: false,
          cliPassthroughHandled: true,
        );

        await runDesktopStartup(built.ports);

        expect(built.calls, <String>['cli']);
      },
    );

    test('keeps login-shell env inheritance on normal GUI startup', () async {
      final built = buildPorts(
        hasPendingGuiLaunchRequest: false,
        cliPassthroughHandled: false,
      );

      await runDesktopStartup(built.ports);

      expect(built.calls, <String>['cli', 'env', 'gui']);
    });

    test('starts skills auto-update after GUI startup', () async {
      final built = buildPorts(
        hasPendingGuiLaunchRequest: false,
        cliPassthroughHandled: false,
        withSkills: true,
      );

      await runDesktopStartup(built.ports);

      expect(built.calls, <String>['cli', 'env', 'gui', 'skills']);
    });

    test(
      'does not route open-project launches through CLI passthrough',
      () async {
        final built = buildPorts(
          hasPendingGuiLaunchRequest: true,
          cliPassthroughHandled: true,
        );

        await runDesktopStartup(built.ports);

        expect(built.calls, <String>['env', 'gui']);
        expect(built.calls, isNot(contains('cli')));
      },
    );

    // --- edge cases the upstream suite leaves unpinned ---

    test('still starts skills auto-update on a pending GUI launch', () async {
      final built = buildPorts(
        hasPendingGuiLaunchRequest: true,
        cliPassthroughHandled: true,
        withSkills: true,
      );

      await runDesktopStartup(built.ports);

      expect(built.calls, <String>['env', 'gui', 'skills']);
    });

    test('omitting the skills port simply skips that step', () async {
      final built = buildPorts(
        hasPendingGuiLaunchRequest: false,
        cliPassthroughHandled: false,
      );

      await runDesktopStartup(built.ports);

      expect(built.calls, isNot(contains('skills')));
    });

    test(
      'waits for GUI bootstrap to finish before auto-updating skills',
      () async {
        final calls = <String>[];
        final bootstrapCompleter = Completer<void>();

        final Future<void> startup = runDesktopStartup(
          DesktopStartupPorts(
            hasPendingGuiLaunchRequest: false,
            runCliPassthroughIfRequested: () async => false,
            inheritLoginShellEnv: () => calls.add('env'),
            bootstrapGui: () async {
              calls.add('gui:start');
              await bootstrapCompleter.future;
              calls.add('gui:done');
            },
            autoUpdateInstalledSkills: () => calls.add('skills'),
          ),
        );

        // The startup future is parked inside bootstrapGui, so nothing after it
        // may have run yet.
        await pumpEventQueue();
        expect(calls, <String>['env', 'gui:start']);

        bootstrapCompleter.complete();
        await startup;

        expect(calls, <String>['env', 'gui:start', 'gui:done', 'skills']);
      },
    );

    test(
      'propagates a CLI passthrough failure without booting the GUI',
      () async {
        final calls = <String>[];

        await expectLater(
          runDesktopStartup(
            DesktopStartupPorts(
              hasPendingGuiLaunchRequest: false,
              runCliPassthroughIfRequested: () async =>
                  throw StateError('cli exploded'),
              inheritLoginShellEnv: () => calls.add('env'),
              bootstrapGui: () async => calls.add('gui'),
              autoUpdateInstalledSkills: () => calls.add('skills'),
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(calls, isEmpty);
      },
    );

    test('does not auto-update skills when GUI bootstrap fails', () async {
      final calls = <String>[];

      await expectLater(
        runDesktopStartup(
          DesktopStartupPorts(
            hasPendingGuiLaunchRequest: false,
            runCliPassthroughIfRequested: () async => false,
            inheritLoginShellEnv: () => calls.add('env'),
            bootstrapGui: () async => throw StateError('no display'),
            autoUpdateInstalledSkills: () => calls.add('skills'),
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(calls, <String>['env']);
    });
  });

  // -------------------------------------------------------------------------
  // open-project-routing.ts
  // -------------------------------------------------------------------------
  group('parseOpenProjectPathFromArgv', () {
    const String executable = '/Applications/Paseo.app/Contents/MacOS/Paseo';
    const String projectPath = '/tmp/paseo-open-project-abc123';

    test('returns a bare absolute path argument', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, projectPath],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test(
      'finds a bare absolute path even when Chromium noise args appear first',
      () {
        final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
          projectPath,
        });

        expect(
          parseOpenProjectPathFromArgv(
            argv: <String>[
              executable,
              '--allow-file-access-from-files',
              '--no-sandbox',
              projectPath,
            ],
            isDefaultApp: false,
            probe: probe,
          ),
          projectPath,
        );
      },
    );

    test('does not treat flags as project paths', () {
      const String flagLikeDirectory = '$projectPath/--version';
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
        flagLikeDirectory,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, '--version', flagLikeDirectory],
          isDefaultApp: false,
          probe: probe,
        ),
        flagLikeDirectory,
      );

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, '--version'],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
    });

    test('returns the path from an explicit --open-project flag for backward '
        'compatibility', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, openProjectFlag, projectPath],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('drops two argv entries when running as the default app', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      // Unpackaged argv is [electron, appPath, ...userArgs]; the project path
      // sitting at index 1 is the app path, not a user argument.
      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>['/usr/bin/electron', projectPath],
          isDefaultApp: true,
          probe: probe,
        ),
        isNull,
      );

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>['/usr/bin/electron', '/repo/app', projectPath],
          isDefaultApp: true,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('returns null for an argv shorter than the slice offset', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: const <String>[],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
      expect(
        parseOpenProjectPathFromArgv(
          argv: const <String>['/usr/bin/electron'],
          isDefaultApp: true,
          probe: probe,
        ),
        isNull,
      );
      expect(probe.absoluteChecks, isEmpty);
    });

    test('drops the macOS process-serial-number argument', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, '-psn_0_1234567', projectPath],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
      expect(probe.absoluteChecks, isNot(contains('-psn_0_1234567')));
    });

    test('drops ignored arguments by prefix, not by exact match', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[
            executable,
            '--no-sandbox-and-then-some',
            openProjectFlag,
            projectPath,
          ],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('never probes the disk for a relative argument', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, 'relative/dir'],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
      expect(probe.absoluteChecks, <String>['relative/dir']);
      expect(probe.directoryChecks, isEmpty);
    });

    test('skips an absolute path that is not an existing directory', () {
      final probe = _FakeOpenProjectPathProbe(
        absolutePaths: <String>{'/tmp/not-a-dir.txt', projectPath},
        directories: <String>{projectPath},
      );

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, '/tmp/not-a-dir.txt', projectPath],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('returns the first matching positional path', () {
      const String second = '/tmp/paseo-open-project-second';
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
        second,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, projectPath, second],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('falls through to the flag when the positional match is empty', () {
      // Unreachable against a real filesystem, but upstream guards the
      // positional result with JS truthiness rather than a null check, so an
      // empty match resumes at the flag branch instead of ending the search.
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        '',
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, '', openProjectFlag, projectPath],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('returns null when --open-project is the last argument', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, openProjectFlag],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
    });

    test('returns null for an empty --open-project value', () {
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, openProjectFlag, ''],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
      // The positional scan reaches the empty argument first (it does not start
      // with `-`), but rejects it as non-absolute, so the disk is never touched
      // for it and the flag branch then discards it on truthiness.
      expect(probe.absoluteChecks, contains(''));
      expect(probe.directoryChecks, isNot(contains('')));
    });

    test('returns null when the --open-project value is not a directory', () {
      final probe = _FakeOpenProjectPathProbe(
        absolutePaths: <String>{'/tmp/not-a-dir.txt'},
        directories: const <String>{},
      );

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, openProjectFlag, '/tmp/not-a-dir.txt'],
          isDefaultApp: false,
          probe: probe,
        ),
        isNull,
      );
    });

    test('uses the first --open-project occurrence', () {
      const String second = '/tmp/paseo-open-project-second';
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
        second,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[
            executable,
            openProjectFlag,
            projectPath,
            openProjectFlag,
            second,
          ],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });

    test('prefers a positional path over a later --open-project flag', () {
      const String flagged = '/tmp/paseo-open-project-flagged';
      final probe = _FakeOpenProjectPathProbe.withDirectories(<String>{
        projectPath,
        flagged,
      });

      expect(
        parseOpenProjectPathFromArgv(
          argv: <String>[executable, projectPath, openProjectFlag, flagged],
          isDefaultApp: false,
          probe: probe,
        ),
        projectPath,
      );
    });
  });

  // -------------------------------------------------------------------------
  // pending-open-project-store.ts
  // -------------------------------------------------------------------------
  group('PendingOpenProjectStore', () {
    test('stores pending paths per window and consumes them independently', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.set(202, '/tmp/project-b');

      expect(store.take(101), '/tmp/project-a');
      expect(store.take(202), '/tmp/project-b');
    });

    test('clears a pending path after it is consumed', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');

      expect(store.take(101), '/tmp/project-a');
      expect(store.take(101), isNull);
    });

    test('ignores empty and whitespace-only paths', () {
      final store = PendingOpenProjectStore();

      store.set(101, '   ');

      expect(store.take(101), isNull);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('a null path clears a previously parked one', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.set(101, null);

      expect(store.take(101), isNull);
    });

    test('an empty or whitespace-only path clears a previously parked one', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.set(101, '');
      expect(store.take(101), isNull);

      store.set(202, '/tmp/project-b');
      store.set(202, '\n\t ');
      expect(store.take(202), isNull);
    });

    test('stores a non-blank path trimmed', () {
      final store = PendingOpenProjectStore();

      store.set(101, '  /tmp/project-a\n');

      expect(store.take(101), '/tmp/project-a');
    });

    test('overwrites a previously parked path', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.set(101, '/tmp/project-b');

      expect(store.take(101), '/tmp/project-b');
    });

    test('taking an unknown window id returns null', () {
      expect(PendingOpenProjectStore().take(999), isNull);
    });

    test('delete drops a parked path without reading it', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.delete(101);

      expect(store.take(101), isNull);
    });

    test('deleting an unknown window id is a no-op', () {
      final store = PendingOpenProjectStore();

      store.set(101, '/tmp/project-a');
      store.delete(999);

      expect(store.take(101), '/tmp/project-a');
    });
  });

  // -------------------------------------------------------------------------
  // system/arm64-translation.ts
  // -------------------------------------------------------------------------
  group('detectRunningUnderARM64Translation', () {
    test('returns false outside macOS without probing sysctl', () {
      final exec = _FakeExecFileSync();

      expect(
        detectRunningUnderARM64Translation(
          platform: DesktopHostPlatform.linux,
          hostReportedTranslation: true,
          execFileSync: exec.call,
        ),
        isFalse,
      );
      expect(exec.callCount, 0);
    });

    test('trusts the host when it reports ARM64 translation', () {
      final exec = _FakeExecFileSync();

      expect(
        detectRunningUnderARM64Translation(
          platform: DesktopHostPlatform.darwin,
          hostReportedTranslation: true,
          execFileSync: exec.call,
        ),
        isTrue,
      );
      expect(exec.callCount, 0);
    });

    test('falls back to sysctl when the host does not report translation', () {
      final exec = _FakeExecFileSync(output: '1\n');

      expect(
        detectRunningUnderARM64Translation(
          platform: DesktopHostPlatform.darwin,
          hostReportedTranslation: false,
          execFileSync: exec.call,
        ),
        isTrue,
      );
      expect(exec.callCount, 1);
      expect(exec.calls.single.file, 'sysctl');
      expect(exec.calls.single.args, <String>['-in', 'sysctl.proc_translated']);
      expect(
        exec.calls.single.options,
        const ExecFileSyncOptions(encoding: 'utf-8', timeoutMs: 1000),
      );
    });

    test('treats missing sysctl support as not translated', () {
      final exec = _FakeExecFileSync(error: StateError('unknown oid'));

      expect(
        detectRunningUnderARM64Translation(
          platform: DesktopHostPlatform.darwin,
          execFileSync: exec.call,
        ),
        isFalse,
      );
      expect(exec.callCount, 1);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('probes sysctl when the host has no opinion at all', () {
      final exec = _FakeExecFileSync(output: '1');

      expect(
        detectRunningUnderARM64Translation(
          platform: DesktopHostPlatform.darwin,
          execFileSync: exec.call,
        ),
        isTrue,
      );
      expect(exec.callCount, 1);
    });

    test('reads only an exact trimmed "1" as translated', () {
      for (final (String output, bool expected) in <(String, bool)>[
        ('1', true),
        ('1\n', true),
        ('  1  \r\n', true),
        ('0', false),
        ('0\n', false),
        ('', false),
        ('   ', false),
        ('1x', false),
        ('11', false),
      ]) {
        final exec = _FakeExecFileSync(output: output);
        expect(
          detectRunningUnderARM64Translation(
            platform: DesktopHostPlatform.darwin,
            execFileSync: exec.call,
          ),
          expected,
          reason: 'sysctl output ${output.replaceAll('\n', r'\n')}',
        );
      }
    });

    test('returns false on Windows and unrecognised platforms', () {
      for (final DesktopHostPlatform platform in <DesktopHostPlatform>[
        DesktopHostPlatform.windows,
        DesktopHostPlatform.other,
      ]) {
        final exec = _FakeExecFileSync(output: '1');
        expect(
          detectRunningUnderARM64Translation(
            platform: platform,
            hostReportedTranslation: true,
            execFileSync: exec.call,
          ),
          isFalse,
        );
        expect(exec.callCount, 0);
      }
    });
  });

  group('Arm64TranslationDetector', () {
    test('probes sysctl at most once', () {
      final exec = _FakeExecFileSync(output: '1\n');
      final detector = Arm64TranslationDetector(
        platform: DesktopHostPlatform.darwin,
        execFileSync: exec.call,
      );

      expect(detector.isRunningUnderARM64Translation(), isTrue);
      expect(detector.isRunningUnderARM64Translation(), isTrue);

      expect(exec.callCount, 1);
    });

    test('caches a negative answer too', () {
      final exec = _FakeExecFileSync(output: '0\n');
      final detector = Arm64TranslationDetector(
        platform: DesktopHostPlatform.darwin,
        execFileSync: exec.call,
      );

      expect(detector.isRunningUnderARM64Translation(), isFalse);
      expect(detector.isRunningUnderARM64Translation(), isFalse);

      expect(exec.callCount, 1);
    });

    test('never probes on a non-macOS host', () {
      final exec = _FakeExecFileSync(output: '1\n');
      final detector = Arm64TranslationDetector(
        platform: DesktopHostPlatform.windows,
        execFileSync: exec.call,
      );

      expect(detector.isRunningUnderARM64Translation(), isFalse);
      expect(detector.isRunningUnderARM64Translation(), isFalse);

      expect(exec.callCount, 0);
    });

    test('keeps a host-reported answer without probing', () {
      final exec = _FakeExecFileSync();
      final detector = Arm64TranslationDetector(
        platform: DesktopHostPlatform.darwin,
        hostReportedTranslation: true,
        execFileSync: exec.call,
      );

      expect(detector.isRunningUnderARM64Translation(), isTrue);
      expect(detector.isRunningUnderARM64Translation(), isTrue);

      expect(exec.callCount, 0);
    });
  });

  group('DesktopHostPlatform', () {
    test('maps Node platform strings, folding the rest into other', () {
      expect(
        DesktopHostPlatform.fromNodeName('darwin'),
        DesktopHostPlatform.darwin,
      );
      expect(
        DesktopHostPlatform.fromNodeName('linux'),
        DesktopHostPlatform.linux,
      );
      expect(
        DesktopHostPlatform.fromNodeName('win32'),
        DesktopHostPlatform.windows,
      );
      expect(
        DesktopHostPlatform.fromNodeName('freebsd'),
        DesktopHostPlatform.other,
      );
      expect(DesktopHostPlatform.fromNodeName(''), DesktopHostPlatform.other);
    });

    test('round-trips the platforms both rules branch on', () {
      for (final DesktopHostPlatform platform in <DesktopHostPlatform>[
        DesktopHostPlatform.darwin,
        DesktopHostPlatform.linux,
        DesktopHostPlatform.windows,
      ]) {
        expect(DesktopHostPlatform.fromNodeName(platform.nodeName), platform);
      }
    });
  });

  // -------------------------------------------------------------------------
  // integrations/cli-install/path.ts
  // -------------------------------------------------------------------------
  group('resolveCliInstallSourcePath', () {
    test('uses the bundled shim for packaged macOS installs', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.darwin,
          isPackaged: true,
          executablePath: '/Applications/Paseo.app/Contents/MacOS/Paseo',
          shimPath: '/Applications/Paseo.app/Contents/Resources/bin/paseo',
        ),
        '/Applications/Paseo.app/Contents/Resources/bin/paseo',
      );
    });

    test('prefers the original AppImage path on linux', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.linux,
          isPackaged: true,
          executablePath: '/tmp/.mount_paseo123/paseo',
          shimPath: '/tmp/.mount_paseo123/resources/bin/paseo',
          appImagePath: '/home/user/Applications/Paseo.AppImage',
        ),
        '/home/user/Applications/Paseo.AppImage',
      );
    });

    test('falls back to the shim on windows and in development', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.windows,
          isPackaged: true,
          executablePath:
              r'C:\Users\user\AppData\Local\Programs\Paseo\Paseo.exe',
          shimPath:
              r'C:\Users\user\AppData\Local\Programs\Paseo\resources\bin\paseo.cmd',
        ),
        r'C:\Users\user\AppData\Local\Programs\Paseo\resources\bin\paseo.cmd',
      );

      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.linux,
          isPackaged: false,
          executablePath: '/opt/Paseo/paseo',
          shimPath: '/opt/Paseo/resources/bin/paseo',
        ),
        '/opt/Paseo/resources/bin/paseo',
      );
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test(
      'uses the running executable for a packaged non-AppImage linux install',
      () {
        expect(
          resolveCliInstallSourcePath(
            platform: DesktopHostPlatform.linux,
            isPackaged: true,
            executablePath: '/opt/Paseo/paseo',
            shimPath: '/opt/Paseo/resources/bin/paseo',
          ),
          '/opt/Paseo/paseo',
        );
      },
    );

    test('treats a blank APPIMAGE value as absent', () {
      for (final String appImagePath in <String>['', '   ', '\n\t']) {
        expect(
          resolveCliInstallSourcePath(
            platform: DesktopHostPlatform.linux,
            isPackaged: true,
            executablePath: '/opt/Paseo/paseo',
            shimPath: '/opt/Paseo/resources/bin/paseo',
            appImagePath: appImagePath,
          ),
          '/opt/Paseo/paseo',
        );
      }
    });

    test('returns the AppImage path trimmed', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.linux,
          isPackaged: true,
          executablePath: '/tmp/.mount_paseo123/paseo',
          shimPath: '/tmp/.mount_paseo123/resources/bin/paseo',
          appImagePath: '  /home/user/Paseo.AppImage\n',
        ),
        '/home/user/Paseo.AppImage',
      );
    });

    test('takes the windows branch before the packaging check', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.windows,
          isPackaged: false,
          executablePath: r'C:\repo\node_modules\electron\dist\electron.exe',
          shimPath: r'C:\repo\resources\bin\paseo.cmd',
          appImagePath: '/home/user/Paseo.AppImage',
        ),
        r'C:\repo\resources\bin\paseo.cmd',
      );
    });

    test('ignores an AppImage path on macOS', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.darwin,
          isPackaged: true,
          executablePath: '/Applications/Paseo.app/Contents/MacOS/Paseo',
          shimPath: '/Applications/Paseo.app/Contents/Resources/bin/paseo',
          appImagePath: '/home/user/Paseo.AppImage',
        ),
        '/Applications/Paseo.app/Contents/Resources/bin/paseo',
      );
    });

    test('uses the executable for a packaged unrecognised platform', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.other,
          isPackaged: true,
          executablePath: '/usr/local/paseo/paseo',
          shimPath: '/usr/local/paseo/resources/bin/paseo',
          appImagePath: '/home/user/Paseo.AppImage',
        ),
        '/usr/local/paseo/paseo',
      );
    });

    test('uses the shim for an unpackaged unrecognised platform', () {
      expect(
        resolveCliInstallSourcePath(
          platform: DesktopHostPlatform.other,
          isPackaged: false,
          executablePath: '/usr/local/paseo/paseo',
          shimPath: '/usr/local/paseo/resources/bin/paseo',
        ),
        '/usr/local/paseo/resources/bin/paseo',
      );
    });
  });

  // -------------------------------------------------------------------------
  // diagnostics/tail-file.ts
  // -------------------------------------------------------------------------
  group('tailFile', () {
    const String logPath = '/tmp/paseo-tail-file/main.log';
    const String directoryPath = '/tmp/paseo-tail-file';

    test('returns the requested tail lines', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\ntwo\nthree\n'},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, lines: 2),
        'two\nthree',
      );
    });

    test('keeps missing files empty', () {
      final reader = _FakeTextFileReader();

      expect(
        tailFile(
          '/tmp/paseo-tail-file/missing.log',
          readTextFile: reader.call,
          lines: 2,
        ),
        '',
      );
      expect(
        tailFile(
          '/tmp/paseo-tail-file/missing.log',
          readTextFile: reader.call,
          lines: 2,
          throwOnReadError: true,
        ),
        '',
      );
    });

    test('can propagate read failures', () {
      // Upstream reads a directory, which Node rejects with EISDIR — any error
      // that is not "file missing".
      final reader = _FakeTextFileReader(
        failures: <String, Object>{
          directoryPath: const FileSystemException('EISDIR'),
        },
      );

      expect(
        () => tailFile(
          directoryPath,
          readTextFile: reader.call,
          lines: 2,
          throwOnReadError: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(tailFile(directoryPath, readTextFile: reader.call, lines: 2), '');
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('defaults to the last 50 lines', () {
      final String content = <String>[
        for (int index = 1; index <= 60; index += 1) 'line$index',
      ].join('\n');
      final reader = _FakeTextFileReader(
        files: <String, String>{logPath: content},
      );

      final List<String> tail = tailFile(
        logPath,
        readTextFile: reader.call,
      ).split('\n');

      expect(tail, hasLength(50));
      expect(tail.first, 'line11');
      expect(tail.last, 'line60');
    });

    test('returns every line when fewer exist than requested', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\ntwo\n'},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, lines: 10),
        'one\ntwo',
      );
    });

    test('returns the whole file for a zero line count', () {
      // JS `slice(-0)` is `slice(0)`, because `-0 === 0`. Preserved, not fixed.
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\ntwo\nthree\n'},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, lines: 0),
        'one\ntwo\nthree',
      );
    });

    test('drops lines from the front for a negative line count', () {
      // JS `slice(--2)` is `slice(2)` — a positive start offset.
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\ntwo\nthree\n'},
      );

      expect(tailFile(logPath, readTextFile: reader.call, lines: -2), 'three');
      expect(tailFile(logPath, readTextFile: reader.call, lines: -9), '');
    });

    test('drops empty lines but keeps whitespace-only ones', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\n\n  \n\ntwo\n'},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, lines: 10),
        'one\n  \ntwo',
      );
    });

    test('leaves carriage returns attached on CRLF logs', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: 'one\r\ntwo\r\n'},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, lines: 2),
        'one\r\ntwo\r',
      );
    });

    test('returns empty for a file with no content lines', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: '\n\n\n'},
      );

      expect(tailFile(logPath, readTextFile: reader.call, lines: 5), '');
    });

    test('returns empty for an empty file', () {
      final reader = _FakeTextFileReader(
        files: const <String, String>{logPath: ''},
      );

      expect(tailFile(logPath, readTextFile: reader.call, lines: 5), '');
    });

    test('swallows a missing file even when told to propagate', () {
      final reader = _FakeTextFileReader(
        failures: <String, Object>{logPath: const MissingFileError(logPath)},
      );

      expect(
        tailFile(logPath, readTextFile: reader.call, throwOnReadError: true),
        '',
      );
    });

    test('MissingFileError names itself and its path', () {
      const error = MissingFileError('/tmp/nope.log');

      expect(error.name, 'MissingFileError');
      expect(error.path, '/tmp/nope.log');
      expect(error.toString(), 'MissingFileError: /tmp/nope.log');
    });
  });

  // -------------------------------------------------------------------------
  // features/opener.ts
  // -------------------------------------------------------------------------
  group('desktop opener', () {
    test('allows only http and https external URLs', () {
      expect(isAllowedExternalUrl('https://example.com/path'), isTrue);
      expect(isAllowedExternalUrl('http://localhost:8081'), isTrue);
      expect(isAllowedExternalUrl('file:///etc/passwd'), isFalse);
      expect(isAllowedExternalUrl('javascript:alert(1)'), isFalse);
      expect(isAllowedExternalUrl('paseo://settings'), isFalse);
      expect(isAllowedExternalUrl('/relative/path'), isFalse);
      expect(isAllowedExternalUrl(null), isFalse);
    });

    test('opens allowed URLs through the external URL launcher', () async {
      final opener = _registerOpener();

      await opener.handler(const <String, Object?>{}, 'https://example.com');

      expect(opener.launcher.opened, <String>['https://example.com']);
    });

    test('rejects blocked URLs before invoking the launcher', () async {
      final opener = _registerOpener();

      await expectLater(
        opener.handler(const <String, Object?>{}, 'file:///etc/passwd'),
        throwsA(
          isA<UnsupportedExternalUrlError>().having(
            (UnsupportedExternalUrlError error) => error.message,
            'message',
            'Unsupported external URL',
          ),
        ),
      );

      expect(opener.launcher.opened, isEmpty);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('registers exactly one handler, on the frozen channel', () {
      final opener = _registerOpener();

      expect(opener.registrar.channels, <String>['paseo:opener:openUrl']);
      expect(openerOpenUrlChannel, 'paseo:opener:openUrl');
    });

    test('ignores the IPC event argument', () async {
      final opener = _registerOpener();

      await opener.handler(null, 'https://example.com/a');
      await opener.handler(Object(), 'https://example.com/b');

      expect(opener.launcher.opened, <String>[
        'https://example.com/a',
        'https://example.com/b',
      ]);
    });

    test('rejects every non-string payload', () {
      for (final Object? value in <Object?>[
        null,
        1,
        true,
        <String>['https://example.com'],
        <String, Object?>{'url': 'https://example.com'},
        Uri.parse('https://example.com'),
      ]) {
        expect(isAllowedExternalUrl(value), isFalse, reason: '$value');
      }
    });

    test('normalises scheme case like the upstream URL parser', () {
      expect(isAllowedExternalUrl('HTTPS://Example.COM'), isTrue);
      expect(isAllowedExternalUrl('HtTp://example.com'), isTrue);
    });

    test('rejects allowed schemes without a host', () {
      // `new URL("http://")` throws upstream; the host check reproduces that.
      expect(isAllowedExternalUrl('http://'), isFalse);
      expect(isAllowedExternalUrl('https://'), isFalse);
      expect(isAllowedExternalUrl(''), isFalse);
    });

    test('rejects scheme-relative forms the WHATWG parser would repair', () {
      // Documented deviation: `new URL()` normalises both of these to an
      // authority form and would allow them. Rejecting is the safe direction.
      expect(isAllowedExternalUrl('http:example.com'), isFalse);
      expect(isAllowedExternalUrl('https:/foo'), isFalse);
    });

    test('rejects URLs containing whitespace', () {
      // Documented deviation: Dart's `Uri` percent-encodes an embedded space
      // into the host instead of rejecting it, so whitespace is refused up
      // front.
      expect(isAllowedExternalUrl('http://exa mple.com'), isFalse);
      expect(isAllowedExternalUrl(' https://example.com'), isFalse);
      expect(isAllowedExternalUrl('https://example.com\n'), isFalse);
      expect(isAllowedExternalUrl('https://example.com/a\tb'), isFalse);
    });

    test('rejects unparseable URLs', () {
      expect(isAllowedExternalUrl('http://[invalid'), isFalse);
    });

    test('surfaces a failed OS open as a rejected invoke', () async {
      final opener = _registerOpener(launcherResult: false);

      await expectLater(
        opener.handler(const <String, Object?>{}, 'https://example.com'),
        throwsA(
          isA<ExternalUrlOpenFailure>()
              .having(
                (ExternalUrlOpenFailure error) => error.url,
                'url',
                'https://example.com',
              )
              .having(
                (ExternalUrlOpenFailure error) => error.message,
                'message',
                'Failed to open external URL',
              ),
        ),
      );

      expect(opener.launcher.opened, <String>['https://example.com']);
    });

    test('resolves without a payload on success', () async {
      final opener = _registerOpener();

      expect(
        await opener.handler(const <String, Object?>{}, 'https://example.com'),
        isNull,
      );
    });

    test('opener errors name themselves', () {
      const unsupported = UnsupportedExternalUrlError();
      expect(unsupported.name, 'UnsupportedExternalUrlError');
      expect(
        unsupported.toString(),
        'UnsupportedExternalUrlError: Unsupported external URL',
      );

      const failure = ExternalUrlOpenFailure('https://example.com');
      expect(failure.name, 'ExternalUrlOpenFailure');
      expect(
        failure.toString(),
        'ExternalUrlOpenFailure: Failed to open external URL: '
        'https://example.com',
      );
    });

    test('exposes the allowed scheme set', () {
      expect(allowedExternalUrlSchemes, <String>{'http', 'https'});
    });
  });

  group('ExecFileSyncOptions', () {
    test('compares by value so a call shape can be asserted', () {
      const a = ExecFileSyncOptions(encoding: 'utf-8', timeoutMs: 1000);
      const b = ExecFileSyncOptions(encoding: 'utf-8', timeoutMs: 1000);
      const c = ExecFileSyncOptions(encoding: 'utf-8', timeoutMs: 2000);
      const d = ExecFileSyncOptions(encoding: 'latin1', timeoutMs: 1000);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d));
      expect(
        a.toString(),
        'ExecFileSyncOptions(encoding: utf-8, timeoutMs: 1000)',
      );
    });
  });
}

/// Stands in for a non-missing filesystem failure (upstream's `EISDIR`).
///
/// Declared locally rather than imported from `dart:io` so the test stays as
/// host-free as the library under test.
final class FileSystemException implements Exception {
  const FileSystemException(this.code);

  final String code;

  @override
  String toString() => 'FileSystemException: $code';
}
