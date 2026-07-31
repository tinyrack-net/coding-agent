// Ports of the upstream test suites for Paseo's platform-boundary rules:
// panel-instance-attributes, install-crypto-polyfills, pick-directory,
// electron/idle, and desktop-diagnostic-report — plus the edge cases those
// suites leave unpinned (empty log tails, blank status fields, a host that
// already provides crypto, non-numeric IPC payloads, unsubscribe semantics).
import 'dart:async';
import 'dart:typed_data';

import 'package:coding_agent_app/core/paseo_platform_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// panels/panel-instance-attributes.ts
// ---------------------------------------------------------------------------

const PanelInstanceIdentity _identity = PanelInstanceIdentity(
  serverId: 'server',
  workspaceId: 'workspace',
  tabId: 'observed',
);

// ---------------------------------------------------------------------------
// polyfills/install-crypto-polyfills.ts
// ---------------------------------------------------------------------------

final Uint8List _testBytes = Uint8List.fromList([
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
  0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
]);

/// Mirrors upstream's `recordingFillFromBytes`: writes fixed bytes and counts
/// how many times the source was consulted.
final class _RecordingFill {
  _RecordingFill(this.bytes);

  final Uint8List bytes;
  int calls = 0;

  Uint8List? fill(Uint8List? array) {
    calls += 1;
    if (array != null) {
      array.setRange(0, array.length, bytes);
    }
    return array;
  }
}

// ---------------------------------------------------------------------------
// diagnostics/desktop-diagnostic-report.ts
// ---------------------------------------------------------------------------

DesktopDaemonStatus _status() => const DesktopDaemonStatus(
  serverId: 'server-1',
  status: DesktopDaemonState.running,
  listen: '127.0.0.1:6767',
  hostname: 'host',
  pid: 4242,
  home: '/paseo/home',
  version: '1.2.3',
  desktopManaged: true,
  error: null,
);

DesktopDiagnosticSources _makeSources() => DesktopDiagnosticSources(
  getStatus: () async => _status(),
  getDaemonLogs: () async => const DesktopDaemonLogs(
    logPath: '/paseo/home/daemon.log',
    contents: 'daemon line one\ndaemon line two',
  ),
  getAppLogs: () async => const DesktopAppLogs(
    logPath: '/logs/Paseo/main.log',
    contents: '[login-shell-env] start\n[login-shell-env] failed',
  ),
);

void main() {
  group('panel instance attributes', () {
    test('keeps runtime attributes isolated by workspace and tab', () {
      final store = PanelInstanceAttributeStore();
      const first = PanelInstanceIdentity(
        serverId: 'server',
        workspaceId: 'one',
        tabId: 'tab',
      );
      const second = PanelInstanceIdentity(
        serverId: 'server',
        workspaceId: 'two',
        tabId: 'tab',
      );

      store.write(first, const PanelInstanceAttributes(modified: true));

      expect(store.read(first), const PanelInstanceAttributes(modified: true));
      expect(store.read(second), PanelInstanceAttributes.unmodified);

      store.write(first, const PanelInstanceAttributes(modified: false));
      expect(store.read(first), PanelInstanceAttributes.unmodified);
    });

    test('keeps runtime attributes isolated by server', () {
      final store = PanelInstanceAttributeStore();
      const first = PanelInstanceIdentity(
        serverId: 'alpha',
        workspaceId: 'w',
        tabId: 'tab',
      );
      const second = PanelInstanceIdentity(
        serverId: 'beta',
        workspaceId: 'w',
        tabId: 'tab',
      );

      store.write(first, const PanelInstanceAttributes(modified: true));

      expect(store.read(first).modified, isTrue);
      expect(store.read(second).modified, isFalse);
    });

    test('notifies subscribers only when attributes change', () {
      final store = PanelInstanceAttributeStore();
      var notifications = 0;
      final unsubscribe = store.subscribe(_identity, () => notifications += 1);

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      store.write(_identity, const PanelInstanceAttributes(modified: true));
      store.write(_identity, const PanelInstanceAttributes(modified: false));

      expect(notifications, 2);
      unsubscribe();
    });

    test('builds the map key from all three identity axes', () {
      expect(
        buildPanelInstanceKey(
          const PanelInstanceIdentity(
            serverId: 'srv',
            workspaceId: 'ws',
            tabId: 'tab',
          ),
        ),
        'srv:ws:tab',
      );
    });

    test('reads the shared default for a panel that never published', () {
      final store = PanelInstanceAttributeStore();

      expect(store.read(_identity), PanelInstanceAttributes.unmodified);
      expect(store.read(_identity).modified, isFalse);
      expect(store.read(_identity).suspendPendingSave, isNull);
      expect(store.revision, 0);
    });

    test('bumps the revision only for accepted writes', () {
      final store = PanelInstanceAttributeStore();

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      expect(store.revision, 1);

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      expect(store.revision, 1);

      store.write(_identity, PanelInstanceAttributes.unmodified);
      expect(store.revision, 2);
    });

    test('treats a swapped suspendPendingSave as a change', () {
      final store = PanelInstanceAttributeStore();
      var notifications = 0;
      store.subscribe(_identity, () => notifications += 1);
      void Function() first() => () {};
      void Function() second() => () {};

      store.write(
        _identity,
        PanelInstanceAttributes(modified: true, suspendPendingSave: first),
      );
      store.write(
        _identity,
        PanelInstanceAttributes(modified: true, suspendPendingSave: second),
      );
      // Republishing the identical callback is a no-op, exactly as republishing
      // an identical `modified` flag is.
      store.write(
        _identity,
        PanelInstanceAttributes(modified: true, suspendPendingSave: second),
      );

      expect(notifications, 2);
      expect(store.read(_identity).suspendPendingSave, same(second));
    });

    test(
      'still notifies when an unmodified write carries a new suspend callback',
      () {
        // The no-op check compares against the *stored* entry, which is absent
        // for an unmodified panel, so its suspendPendingSave reads as null and
        // the incoming callback counts as a difference.
        final store = PanelInstanceAttributeStore();
        var notifications = 0;
        store.subscribe(_identity, () => notifications += 1);

        store.write(
          _identity,
          PanelInstanceAttributes(suspendPendingSave: () => () {}),
        );

        expect(notifications, 1);
        expect(store.revision, 1);
        // Nothing was stored, because the panel is not modified.
        expect(store.read(_identity), PanelInstanceAttributes.unmodified);
      },
    );

    test('stops notifying after unsubscribe', () {
      final store = PanelInstanceAttributeStore();
      var notifications = 0;
      final unsubscribe = store.subscribe(_identity, () => notifications += 1);

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      unsubscribe();
      store.write(_identity, PanelInstanceAttributes.unmodified);

      expect(notifications, 1);
    });

    test('leaves subscribers of other panels untouched', () {
      final store = PanelInstanceAttributeStore();
      var otherNotifications = 0;
      store.subscribe(
        const PanelInstanceIdentity(
          serverId: 'server',
          workspaceId: 'workspace',
          tabId: 'other',
        ),
        () => otherNotifications += 1,
      );

      store.write(_identity, const PanelInstanceAttributes(modified: true));

      expect(otherNotifications, 0);
    });

    test('notifies store-wide subscribers for every panel', () {
      final store = PanelInstanceAttributeStore();
      var notifications = 0;
      final unsubscribe = store.subscribeAll(() => notifications += 1);

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      store.write(
        const PanelInstanceIdentity(
          serverId: 'server',
          workspaceId: 'workspace',
          tabId: 'other',
        ),
        const PanelInstanceAttributes(modified: true),
      );

      expect(notifications, 2);
      unsubscribe();
      store.write(_identity, PanelInstanceAttributes.unmodified);
      expect(notifications, 2);
    });

    test('survives a listener unsubscribing during a notification', () {
      final store = PanelInstanceAttributeStore();
      var notifications = 0;
      late void Function() unsubscribe;
      unsubscribe = store.subscribe(_identity, () {
        notifications += 1;
        unsubscribe();
      });

      store.write(_identity, const PanelInstanceAttributes(modified: true));
      store.write(_identity, PanelInstanceAttributes.unmodified);

      expect(notifications, 1);
    });

    test('selects the modified tab ids in the order given', () {
      final store = PanelInstanceAttributeStore();
      for (final tabId in ['b', 'd']) {
        store.write(
          PanelInstanceIdentity(
            serverId: 'server',
            workspaceId: 'workspace',
            tabId: tabId,
          ),
          const PanelInstanceAttributes(modified: true),
        );
      }

      final modified = store.modifiedTabIds(
        serverId: 'server',
        workspaceId: 'workspace',
        tabIds: ['a', 'b', 'c', 'd'],
      );

      expect(modified.toList(), ['b', 'd']);
    });

    test('scopes modified tab ids to the requested workspace', () {
      final store = PanelInstanceAttributeStore();
      store.write(
        const PanelInstanceIdentity(
          serverId: 'server',
          workspaceId: 'other',
          tabId: 'tab',
        ),
        const PanelInstanceAttributes(modified: true),
      );

      expect(
        store.modifiedTabIds(
          serverId: 'server',
          workspaceId: 'workspace',
          tabIds: ['tab'],
        ),
        isEmpty,
      );
    });

    test('publish clears the panel when its disposer runs', () {
      final store = PanelInstanceAttributeStore();

      final dispose = store.publish(
        _identity,
        const PanelInstanceAttributes(modified: true),
      );
      expect(store.read(_identity).modified, isTrue);

      dispose();
      expect(store.read(_identity), PanelInstanceAttributes.unmodified);
    });
  });

  group('installCryptoPolyfills', () {
    test('derives randomUUID from the host getRandomValues when available', () {
      final native = _RecordingFill(_testBytes);
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        CryptoPolyfillTarget(getRandomValues: native.fill),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );

      expect(installed.randomUuid(), '00112233-4455-4677-8899-aabbccddeeff');
      expect(native.calls, 1);
      expect(expo.calls, 0);
    });

    test('falls back to the injected expo source when the host has none', () {
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        const CryptoPolyfillTarget(),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );

      expect(installed.randomUuid(), '00112233-4455-4677-8899-aabbccddeeff');
      expect(expo.calls, 1);
    });

    test('installs getRandomValues that delegates to the expo source', () {
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        const CryptoPolyfillTarget(),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );

      final buf = Uint8List(16);
      installed.getRandomValues(buf);

      expect(buf, _testBytes);
      expect(expo.calls, 1);
    });

    test('keeps the host getRandomValues rather than wrapping it', () {
      final native = _RecordingFill(_testBytes);
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        CryptoPolyfillTarget(getRandomValues: native.fill),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );
      installed.getRandomValues(Uint8List(16));

      expect(native.calls, 1);
      expect(expo.calls, 0);
    });

    test('keeps a randomUUID the host already provides', () {
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        CryptoPolyfillTarget(randomUuid: () => 'host-supplied'),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );

      expect(installed.randomUuid(), 'host-supplied');
      expect(expo.calls, 0);
    });

    test('passes a null buffer through without consulting a source', () {
      final expo = _RecordingFill(_testBytes);

      final installed = installCryptoPolyfills(
        const CryptoPolyfillTarget(),
        CryptoPolyfillSources(expoGetRandomValues: expo.fill),
      );

      expect(installed.getRandomValues(null), isNull);
      expect(expo.calls, 0);
    });

    test('reports a source that hands back no bytes', () {
      final installed = installCryptoPolyfills(
        const CryptoPolyfillTarget(),
        CryptoPolyfillSources(expoGetRandomValues: (_) => null),
      );

      expect(installed.randomUuid, throwsA(isA<StateError>()));
    });
  });

  group('formatUuidV4FromBytes', () {
    test('forces the version and variant nibbles on all-zero entropy', () {
      expect(
        formatUuidV4FromBytes(Uint8List(16)),
        '00000000-0000-4000-8000-000000000000',
      );
    });

    test('forces the version and variant nibbles on all-ones entropy', () {
      expect(
        formatUuidV4FromBytes(Uint8List.fromList(List.filled(16, 0xff))),
        'ffffffff-ffff-4fff-bfff-ffffffffffff',
      );
    });

    test('leaves the caller entropy untouched', () {
      final bytes = Uint8List.fromList(List.filled(16, 0x11));
      formatUuidV4FromBytes(bytes);

      expect(bytes.every((byte) => byte == 0x11), isTrue);
    });

    test('rejects a buffer that is not sixteen bytes', () {
      expect(
        () => formatUuidV4FromBytes(Uint8List(15)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('polyfill text codecs', () {
    test('encodes and decodes UTF-8 round trip', () {
      final encoded = polyfillTextEncode('hello');

      expect(encoded, [104, 101, 108, 108, 111]);
      expect(polyfillTextDecode(encoded), 'hello');
    });

    test('encodes the empty string by default', () {
      expect(polyfillTextEncode(), isEmpty);
    });

    test('decodes a missing buffer to the empty string', () {
      expect(polyfillTextDecode(), '');
      expect(polyfillTextDecode(null), '');
    });

    test('encodes multi-byte code points', () {
      expect(polyfillTextEncode('é'), [0xc3, 0xa9]);
      expect(polyfillTextDecode(polyfillTextEncode('한글')), '한글');
    });

    test('substitutes malformed sequences instead of throwing', () {
      expect(polyfillTextDecode(Uint8List.fromList([0xff])), '\u{FFFD}');
      expect(
        polyfillTextDecode(Uint8List.fromList([0x61, 0xff, 0x62])),
        'a\u{FFFD}b',
      );
    });
  });

  group('pickDirectory', () {
    test('opens a single-directory picker and returns the selection', () async {
      final recordedOptions = <DesktopDialogOpenOptions>[];
      final dialog = DesktopDialogBridge(
        open: (options) async {
          recordedOptions.add(options);
          return '/repo/project';
        },
      );

      expect(await pickDirectory(dialog), '/repo/project');
      expect(recordedOptions, [
        const DesktopDialogOpenOptions(
          directory: true,
          multiple: false,
          createDirectory: true,
        ),
      ]);
    });

    test('returns null when the picker is cancelled', () async {
      final dialog = DesktopDialogBridge(open: (_) async => null);

      expect(await pickDirectory(dialog), isNull);
    });

    test('returns an empty selection verbatim', () async {
      final dialog = DesktopDialogBridge(open: (_) async => '');

      expect(await pickDirectory(dialog), '');
    });

    test('throws when no dialog bridge is injected', () async {
      await expectLater(
        pickDirectory(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Desktop dialog open() is unavailable in this environment.',
          ),
        ),
      );
    });

    test('throws when the bridge cannot open dialogs', () async {
      await expectLater(
        pickDirectory(const DesktopDialogBridge()),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when the host ignores multiple: false', () async {
      final dialog = DesktopDialogBridge(open: (_) async => ['/a', '/b']);

      await expectLater(
        pickDirectory(dialog),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Unexpected directory picker response.',
          ),
        ),
      );
    });

    test('propagates a rejection from the host dialog', () async {
      final dialog = DesktopDialogBridge(
        open: (_) async => throw StateError('dialog exploded'),
      );

      await expectLater(pickDirectory(dialog), throwsA(isA<StateError>()));
    });
  });

  group('readDesktopSystemIdleTimeMs', () {
    test(
      'returns the millisecond value reported by the idle command',
      () async {
        final invokedCommands = <String>[];

        final idleTimeMs = await readDesktopSystemIdleTimeMs((command) async {
          invokedCommands.add(command);
          return 4200;
        });

        expect(idleTimeMs, 4200);
        expect(invokedCommands, ['desktop_get_system_idle_time']);
      },
    );

    test('returns zero when the desktop IPC returns zero', () async {
      expect(await readDesktopSystemIdleTimeMs((_) async => 0), 0);
    });

    test('preserves a fractional millisecond reading', () async {
      expect(await readDesktopSystemIdleTimeMs((_) async => 12.5), 12.5);
    });

    test('returns null when the desktop IPC rejects', () async {
      expect(
        await readDesktopSystemIdleTimeMs(
          (_) async => throw StateError('ipc failed'),
        ),
        isNull,
      );
    });

    test('returns null when the desktop IPC throws synchronously', () async {
      expect(
        await readDesktopSystemIdleTimeMs((_) => throw StateError('no bridge')),
        isNull,
      );
    });

    test('returns null when the desktop IPC returns null', () async {
      expect(await readDesktopSystemIdleTimeMs((_) async => null), isNull);
    });

    test('returns null when the desktop IPC returns NaN', () async {
      expect(
        await readDesktopSystemIdleTimeMs((_) async => double.nan),
        isNull,
      );
    });

    test('returns null when the desktop IPC returns infinity', () async {
      expect(
        await readDesktopSystemIdleTimeMs((_) async => double.infinity),
        isNull,
      );
    });

    test(
      'returns null when the desktop IPC returns a negative value',
      () async {
        expect(await readDesktopSystemIdleTimeMs((_) async => -1), isNull);
      },
    );

    test('returns null for a non-numeric payload', () async {
      expect(await readDesktopSystemIdleTimeMs((_) async => '4200'), isNull);
      expect(await readDesktopSystemIdleTimeMs((_) async => true), isNull);
      expect(
        await readDesktopSystemIdleTimeMs((_) async => {'idleTimeMs': 1}),
        isNull,
      );
    });

    test('reports an invalid reading to the warning sink', () async {
      final warnings = <(String, Object?)>[];

      await readDesktopSystemIdleTimeMs(
        (_) async => -1,
        onWarn: (message, detail) => warnings.add((message, detail)),
      );

      expect(warnings, [('[DesktopIdle] Invalid system idle time', -1)]);
    });

    test('reports a failed read to the warning sink', () async {
      final warnings = <String>[];

      await readDesktopSystemIdleTimeMs(
        (_) async => throw StateError('ipc failed'),
        onWarn: (message, _) => warnings.add(message),
      );

      expect(warnings, ['[DesktopIdle] Failed to read system idle time']);
    });

    test('stays silent on a valid reading', () async {
      var warned = false;

      await readDesktopSystemIdleTimeMs(
        (_) async => 10,
        onWarn: (_, _) => warned = true,
      );

      expect(warned, isFalse);
    });
  });

  group('desktop diagnostic report', () {
    test('starts desktop diagnostic requests together', () async {
      final calls = <String>[];
      final appLogGate = Completer<void>();
      final base = _makeSources();
      final sources = DesktopDiagnosticSources(
        getStatus: () async {
          calls.add('status');
          return base.getStatus();
        },
        getDaemonLogs: () async {
          calls.add('daemonLogs');
          return base.getDaemonLogs();
        },
        getAppLogs: () async {
          calls.add('appLogs');
          await appLogGate.future;
          return base.getAppLogs();
        },
      );

      final resultFuture = collectDesktopDiagnosticSections(sources);

      expect(calls, ['status', 'daemonLogs', 'appLogs']);
      appLogGate.complete();
      expect((await resultFuture).status, DesktopDiagnosticStatus.done);
    });

    test('includes the desktop app log after the daemon log', () async {
      final result = await collectDesktopDiagnosticSections(_makeSources());
      final report = result.sections.join('\n\n');

      expect(result.status, DesktopDiagnosticStatus.done);
      expect(report, contains('  Log path: /paseo/home/daemon.log'));
      expect(report, contains('  App log path: /logs/Paseo/main.log'));
      expect(
        report,
        contains(
          'Desktop daemon log tail\n  daemon line one\n  daemon line two',
        ),
      );
      expect(
        report,
        contains(
          'Desktop app log tail\n'
          '  [login-shell-env] start\n'
          '  [login-shell-env] failed',
        ),
      );
      expect(
        report.indexOf('Desktop app log tail'),
        greaterThan(report.indexOf('Desktop daemon log tail')),
      );
    });

    test('renders the full desktop status section', () async {
      final result = await collectDesktopDiagnosticSections(_makeSources());

      expect(
        result.sections.first,
        [
          'Desktop',
          '  Daemon status: running',
          '  Desktop managed: true',
          '  Daemon PID: 4242',
          '  Daemon version: 1.2.3',
          '  Daemon home: /paseo/home',
          '  Log path: /paseo/home/daemon.log',
          '  App log path: /logs/Paseo/main.log',
          '  Error: none',
        ].join('\n'),
      );
      expect(result.sections, hasLength(3));
    });

    test('keeps daemon diagnostics when the app log fails', () async {
      final base = _makeSources();
      final sources = DesktopDiagnosticSources(
        getStatus: base.getStatus,
        getDaemonLogs: base.getDaemonLogs,
        getAppLogs: () async => throw StateError('app log unavailable'),
      );

      final result = await collectDesktopDiagnosticSections(sources);
      final report = result.sections.join('\n\n');

      expect(result.status, DesktopDiagnosticStatus.failed);
      expect(
        report,
        contains(
          'Desktop daemon log tail\n  daemon line one\n  daemon line two',
        ),
      );
      expect(
        report,
        contains('Desktop app log tail\n  Error: app log unavailable'),
      );
      // The daemon section still renders, with the app log path degraded.
      expect(report, contains('  App log path: unavailable'));
    });

    test('keeps the app log when the daemon status fails', () async {
      final base = _makeSources();
      final sources = DesktopDiagnosticSources(
        getStatus: () async => throw StateError('daemon unreachable'),
        getDaemonLogs: base.getDaemonLogs,
        getAppLogs: base.getAppLogs,
      );

      final result = await collectDesktopDiagnosticSections(sources);
      final report = result.sections.join('\n\n');

      expect(result.status, DesktopDiagnosticStatus.failed);
      expect(result.sections, hasLength(2));
      expect(result.sections.first, 'Desktop\n  Error: daemon unreachable');
      expect(
        report,
        contains(
          'Desktop app log tail\n'
          '  [login-shell-env] start\n'
          '  [login-shell-env] failed',
        ),
      );
      // The daemon log tail is lost with its sibling, since the pair is
      // collected as one unit upstream.
      expect(report, isNot(contains('Desktop daemon log tail')));
    });

    test('degrades both halves when every source fails', () async {
      final sources = DesktopDiagnosticSources(
        getStatus: () async => throw StateError('daemon unreachable'),
        getDaemonLogs: () async => throw StateError('daemon logs unreadable'),
        getAppLogs: () async => throw StateError('app log unavailable'),
      );

      final result = await collectDesktopDiagnosticSections(sources);

      expect(result.status, DesktopDiagnosticStatus.failed);
      expect(result.sections, [
        'Desktop\n  Error: daemon unreachable',
        'Desktop app log tail\n  Error: app log unavailable',
      ]);
    });

    test('falls back to a placeholder for empty log tails', () async {
      final base = _makeSources();
      final sources = DesktopDiagnosticSources(
        getStatus: base.getStatus,
        getDaemonLogs: () async =>
            const DesktopDaemonLogs(logPath: '/d.log', contents: ''),
        getAppLogs: () async =>
            const DesktopAppLogs(logPath: '/a.log', contents: ''),
      );

      final result = await collectDesktopDiagnosticSections(sources);

      expect(result.status, DesktopDiagnosticStatus.done);
      expect(
        result.sections[1],
        'Desktop daemon log tail\n  No log lines found',
      );
      expect(result.sections[2], 'Desktop app log tail\n  No log lines found');
    });

    test('drops blank lines while indenting a log tail', () async {
      final base = _makeSources();
      final sources = DesktopDiagnosticSources(
        getStatus: base.getStatus,
        getDaemonLogs: () async => const DesktopDaemonLogs(
          logPath: '/d.log',
          contents: 'first\n\nsecond\n',
        ),
        getAppLogs: base.getAppLogs,
      );

      final result = await collectDesktopDiagnosticSections(sources);

      expect(result.sections[1], 'Desktop daemon log tail\n  first\n  second');
    });

    test('substitutes placeholders for blank status fields', () async {
      final sources = DesktopDiagnosticSources(
        getStatus: () async => const DesktopDaemonStatus(
          serverId: '',
          status: DesktopDaemonState.errored,
          home: '',
          desktopManaged: false,
          pid: null,
          version: null,
          error: 'spawn ENOENT',
        ),
        getDaemonLogs: () async =>
            const DesktopDaemonLogs(logPath: '', contents: 'line'),
        getAppLogs: () async =>
            const DesktopAppLogs(logPath: '', contents: 'line'),
      );

      final result = await collectDesktopDiagnosticSections(sources);

      expect(
        result.sections.first,
        [
          'Desktop',
          '  Daemon status: errored',
          '  Desktop managed: false',
          '  Daemon PID: none',
          '  Daemon version: unknown',
          '  Daemon home: unknown',
          '  Log path: unknown',
          '  App log path: unavailable',
          '  Error: spawn ENOENT',
        ].join('\n'),
      );
    });
  });

  group('describeDiagnosticError', () {
    test('unwraps the bare message from common Dart throwables', () {
      expect(describeDiagnosticError(StateError('boom')), 'boom');
      expect(describeDiagnosticError(Exception('boom')), 'boom');
      expect(
        describeDiagnosticError(const FormatException('bad json')),
        'bad json',
      );
      expect(describeDiagnosticError(ArgumentError('bad arg')), 'bad arg');
    });

    test('stringifies anything else', () {
      expect(describeDiagnosticError('plain'), 'plain');
      expect(describeDiagnosticError(42), '42');
      expect(describeDiagnosticError(null), 'null');
    });
  });
}
