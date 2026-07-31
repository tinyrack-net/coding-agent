// Ports of the upstream test suites for Paseo's desktop daemon-management and
// app-update rules: daemon-management-error, daemon-management-toggle,
// resolve-update-callout and desktop-updates — plus the edge cases those suites
// leave unpinned (JS truthiness on blank versions, arrays passing the `isRecord`
// guard, status/isInstalling disagreement, and the host command wire shapes).
import 'package:agent_protocol/agent_protocol.dart' show ServerHello;
import 'package:coding_agent_app/desktop/paseo_desktop_daemon_rules.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart'
    show DaemonHealth, DaemonStatus;
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Translators
//
// The repo has no localization layer, so the rules take a translator. These
// tables mirror upstream `i18n/resources/en.ts` and `zh-CN.ts` at exactly the
// keys the ported modules read.
// ---------------------------------------------------------------------------

const Map<String, String> _en = {
  'desktop.daemon.management.registrationFailed':
      'Built-in daemon started, but Paseo could not save the localhost '
      'connection. Toggle daemon management off and on again, or add '
      'localhost manually.',
  'desktop.daemon.management.pausedStopFailed':
      'Built-in daemon management was paused, but Paseo could not stop the '
      'daemon.',
  'desktop.daemon.management.updateFailed':
      'Unable to update built-in daemon management.',
  'desktop.updates.callout.installingTitle': 'Installing update',
  'desktop.updates.callout.failedTitle': 'Update failed',
  'desktop.updates.callout.availableTitle': 'Update available',
  'desktop.updates.callout.genericError': 'Something went wrong.',
  'desktop.updates.callout.whatsNew': "What's new",
  'desktop.updates.callout.installingAction': 'Installing...',
  'desktop.updates.callout.installAndRestart': 'Install & restart',
  'desktop.updates.status.installed': 'App update installed. Restart required.',
  'common.actions.retry': 'Retry',
};

const Map<String, String> _zhCN = {
  'desktop.updates.callout.installingTitle': '正在安装更新',
  'desktop.updates.callout.failedTitle': '更新失败',
  'desktop.updates.callout.availableTitle': '有可用更新',
  'desktop.updates.callout.genericError': '出了点问题。',
  'desktop.updates.callout.whatsNew': '更新内容',
  'desktop.updates.callout.installingAction': '正在安装...',
  'desktop.updates.callout.installAndRestart': '安装并重启',
  'common.actions.retry': '重试',
};

String _t(String key) => _en[key] ?? key;
String _tZh(String key) => _zhCN[key] ?? key;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

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

final DaemonStatus _runningManagedStatus = _daemonStatus();
final DaemonStatus _stoppedStatus = _daemonStatus(health: DaemonHealth.stopped);

/// Records the port call order so the persist-before-stop guarantee can be
/// asserted the way the upstream suite does.
final class _RecordingTogglePorts {
  _RecordingTogglePorts({
    Future<bool> Function()? confirm,
    Future<void> Function({required bool manageBuiltInDaemon})? persistSettings,
    Future<DaemonStatus> Function()? startDaemon,
    Future<DaemonStatus> Function()? stopDaemon,
  }) {
    ports = DaemonManagementTogglePorts(
      confirm: () async {
        calls.add('confirm');
        return confirm == null ? true : await confirm();
      },
      persistSettings: ({required bool manageBuiltInDaemon}) async {
        calls.add('persist');
        persisted.add(manageBuiltInDaemon);
        if (persistSettings != null) {
          await persistSettings(manageBuiltInDaemon: manageBuiltInDaemon);
        }
      },
      startDaemon: () async {
        calls.add('start');
        return startDaemon == null
            ? _runningManagedStatus
            : await startDaemon();
      },
      stopDaemon: () async {
        calls.add('stop');
        return stopDaemon == null ? _stoppedStatus : await stopDaemon();
      },
    );
  }

  final List<String> calls = [];
  final List<bool> persisted = [];
  late final DaemonManagementTogglePorts ports;
}

/// Fake desktop host: records every command it is handed and replies from a
/// canned table, so command names and argument shapes are assertable.
final class _FakeDesktopHost implements DesktopHostBridge {
  _FakeDesktopHost({
    this.isWebRuntime = true,
    this.isElectronRuntime = true,
    Map<String, Object?>? replies,
  }) : _replies = replies ?? const {};

  @override
  final bool isWebRuntime;

  @override
  final bool isElectronRuntime;

  final Map<String, Object?> _replies;

  /// Kept as two parallel lists rather than records because `expect`'s deep
  /// equality descends into lists and maps but not into record fields.
  final List<String> commands = [];
  final List<Map<String, Object?>?> arguments = [];

  @override
  Future<Object?> invokeCommand(
    String command, [
    Map<String, Object?>? args,
  ]) async {
    commands.add(command);
    arguments.add(args);
    return _replies[command];
  }
}

/// Sentinel for "this optional test input was not overridden", so an explicit
/// null stays distinguishable from the default.
const Object _unsetAvailableUpdate = Object();

void main() {
  // -------------------------------------------------------------------------
  // daemon-management-error.ts
  // -------------------------------------------------------------------------
  group('getDaemonManagementErrorPresentation', () {
    test('refreshes status when the daemon started but localhost registration '
        'failed', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: const DaemonConnectionRegistrationError(
          'Desktop daemon did not return a listen address.',
        ),
        isManagingDaemon: false,
        t: _t,
      );

      expect(
        presentation,
        DaemonManagementErrorPresentation(
          message: _en['desktop.daemon.management.registrationFailed']!,
          refreshStatus: true,
        ),
      );
    });

    test('does not refresh status for daemon stop failures', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: StateError('stop failed'),
        isManagingDaemon: true,
        t: _t,
      );

      expect(
        presentation,
        DaemonManagementErrorPresentation(
          message: _en['desktop.daemon.management.pausedStopFailed']!,
          refreshStatus: false,
        ),
      );
    });

    test('uses the pre-mutation daemon management state for operation '
        'failures', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: DaemonManagementOperationError(StateError('stop failed'), true),
        isManagingDaemon: false,
        t: _t,
      );

      expect(
        presentation,
        DaemonManagementErrorPresentation(
          message: _en['desktop.daemon.management.pausedStopFailed']!,
          refreshStatus: false,
        ),
      );
    });

    test('does not refresh status for generic update failures', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: StateError('settings failed'),
        isManagingDaemon: false,
        t: _t,
      );

      expect(
        presentation,
        DaemonManagementErrorPresentation(
          message: _en['desktop.daemon.management.updateFailed']!,
          refreshStatus: false,
        ),
      );
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('a captured false management flag overrides a live true one', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: DaemonManagementOperationError(
          StateError('settings failed'),
          false,
        ),
        isManagingDaemon: true,
        t: _t,
      );

      expect(
        presentation.message,
        _en['desktop.daemon.management.updateFailed'],
      );
      expect(presentation.refreshStatus, isFalse);
    });

    test('registration failures win over the management flag once '
        'unwrapped', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: DaemonManagementOperationError(
          const DaemonConnectionRegistrationError('no listen address'),
          true,
        ),
        isManagingDaemon: false,
        t: _t,
      );

      expect(
        presentation,
        DaemonManagementErrorPresentation(
          message: _en['desktop.daemon.management.registrationFailed']!,
          refreshStatus: true,
        ),
      );
    });

    test('a bare registration failure still refreshes while managing', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: const DaemonConnectionRegistrationError('no listen address'),
        isManagingDaemon: true,
        t: _t,
      );

      expect(presentation.refreshStatus, isTrue);
    });

    test('unwraps exactly one operation-error level', () {
      // The inner wrapper is not a registration error, so the OUTER captured
      // flag decides — the inner `false` is never consulted.
      final presentation = getDaemonManagementErrorPresentation(
        error: DaemonManagementOperationError(
          DaemonManagementOperationError(
            const DaemonConnectionRegistrationError('no listen address'),
            false,
          ),
          true,
        ),
        isManagingDaemon: false,
        t: _t,
      );

      expect(
        presentation.message,
        _en['desktop.daemon.management.pausedStopFailed'],
      );
      expect(presentation.refreshStatus, isFalse);
    });

    test('handles a thrown non-error object', () {
      final presentation = getDaemonManagementErrorPresentation(
        error: 'stop failed',
        isManagingDaemon: true,
        t: _t,
      );

      expect(
        presentation.message,
        _en['desktop.daemon.management.pausedStopFailed'],
      );
    });

    test('operation errors adopt the wrapped error identity', () {
      const inner = DaemonConnectionRegistrationError('no listen address');
      final wrapper = DaemonManagementOperationError(inner, true);

      expect(wrapper.originalError, same(inner));
      expect(wrapper.cause, same(inner));
      expect(wrapper.message, 'no listen address');
      expect(wrapper.name, 'DaemonConnectionRegistrationError');
      expect(
        wrapper.toString(),
        'DaemonConnectionRegistrationError: no listen address',
      );
    });

    test('presentation equality is by value', () {
      const a = DaemonManagementErrorPresentation(
        message: 'x',
        refreshStatus: true,
      );
      const b = DaemonManagementErrorPresentation(
        message: 'x',
        refreshStatus: true,
      );
      const c = DaemonManagementErrorPresentation(
        message: 'x',
        refreshStatus: false,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  // -------------------------------------------------------------------------
  // daemon-management-toggle.ts
  // -------------------------------------------------------------------------
  group('executeDaemonManagementToggle', () {
    group('enable path (currentlyManaging: false)', () {
      test('persists the new setting then starts the daemon', () async {
        final recorder = _RecordingTogglePorts();

        final result = await executeDaemonManagementToggle(
          currentlyManaging: false,
          daemonStatus: null,
          ports: recorder.ports,
        );

        expect(result, DaemonManagementToggleEnabled(_runningManagedStatus));
        expect(recorder.calls, ['persist', 'start']);
      });

      test('persists manageBuiltInDaemon: true', () async {
        final recorder = _RecordingTogglePorts();

        await executeDaemonManagementToggle(
          currentlyManaging: false,
          daemonStatus: null,
          ports: recorder.ports,
        );

        expect(recorder.persisted, [true]);
      });

      test(
        'never asks for confirmation and ignores the daemon status',
        () async {
          final recorder = _RecordingTogglePorts(confirm: () async => false);

          final result = await executeDaemonManagementToggle(
            currentlyManaging: false,
            daemonStatus: _runningManagedStatus,
            ports: recorder.ports,
          );

          expect(recorder.calls, ['persist', 'start']);
          expect(result, isA<DaemonManagementToggleEnabled>());
        },
      );

      test('surfaces the freshly started status', () async {
        final started = _daemonStatus();
        final recorder = _RecordingTogglePorts(
          startDaemon: () async => started,
        );

        final result = await executeDaemonManagementToggle(
          currentlyManaging: false,
          daemonStatus: null,
          ports: recorder.ports,
        );

        expect(
          (result as DaemonManagementToggleEnabled).newStatus,
          same(started),
        );
      });

      test('a failing persist aborts before the daemon is started', () async {
        final recorder = _RecordingTogglePorts(
          persistSettings: ({required bool manageBuiltInDaemon}) async =>
              throw StateError('settings failed'),
        );

        await expectLater(
          executeDaemonManagementToggle(
            currentlyManaging: false,
            daemonStatus: null,
            ports: recorder.ports,
          ),
          throwsA(isA<StateError>()),
        );
        expect(recorder.calls, ['persist']);
      });
    });

    group('disable path (currentlyManaging: true)', () {
      test('returns cancelled without changing settings when confirmation is '
          'rejected', () async {
        final recorder = _RecordingTogglePorts(confirm: () async => false);

        final result = await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _runningManagedStatus,
          ports: recorder.ports,
        );

        expect(result, const DaemonManagementToggleCancelled());
        expect(recorder.persisted, isEmpty);
        expect(recorder.calls, ['confirm']);
      });

      test('persists settings BEFORE stopping the daemon', () async {
        final recorder = _RecordingTogglePorts();

        await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _runningManagedStatus,
          ports: recorder.ports,
        );

        expect(recorder.calls, ['confirm', 'persist', 'stop']);
      });

      test('persists manageBuiltInDaemon: false when disabling', () async {
        final recorder = _RecordingTogglePorts();

        await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _runningManagedStatus,
          ports: recorder.ports,
        );

        expect(recorder.persisted, [false]);
      });

      test('stops the daemon when it is running and desktop-managed', () async {
        final recorder = _RecordingTogglePorts();

        final result = await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _runningManagedStatus,
          ports: recorder.ports,
        );

        expect(recorder.calls, contains('stop'));
        expect(result, DaemonManagementToggleDisabled(_stoppedStatus));
      });

      test(
        'skips stop when daemon is running but not desktop-managed',
        () async {
          final recorder = _RecordingTogglePorts();

          final result = await executeDaemonManagementToggle(
            currentlyManaging: true,
            daemonStatus: _daemonStatus(desktopManaged: false),
            ports: recorder.ports,
          );

          expect(recorder.calls, isNot(contains('stop')));
          expect(result, const DaemonManagementToggleDisabled(null));
        },
      );

      test(
        'skips stop when daemon is stopped (regardless of desktopManaged)',
        () async {
          final recorder = _RecordingTogglePorts();

          final result = await executeDaemonManagementToggle(
            currentlyManaging: true,
            daemonStatus: _stoppedStatus,
            ports: recorder.ports,
          );

          expect(recorder.calls, isNot(contains('stop')));
          expect(result, const DaemonManagementToggleDisabled(null));
        },
      );

      test('skips stop when daemonStatus is null', () async {
        final recorder = _RecordingTogglePorts();

        final result = await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: null,
          ports: recorder.ports,
        );

        expect(recorder.calls, isNot(contains('stop')));
        expect(result, const DaemonManagementToggleDisabled(null));
      });

      // --- edge cases the upstream suite leaves unpinned ---

      test('skips stop when a running daemon has no handshake to read '
          'desktopManaged from', () async {
        final recorder = _RecordingTogglePorts();

        final result = await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _daemonStatus(desktopManaged: null),
          ports: recorder.ports,
        );

        expect(recorder.calls, isNot(contains('stop')));
        expect(result, const DaemonManagementToggleDisabled(null));
      });

      test('still persists the setting when the stop itself fails', () async {
        final recorder = _RecordingTogglePorts(
          stopDaemon: () async => throw StateError('stop failed'),
        );

        await expectLater(
          executeDaemonManagementToggle(
            currentlyManaging: true,
            daemonStatus: _runningManagedStatus,
            ports: recorder.ports,
          ),
          throwsA(isA<StateError>()),
        );
        expect(recorder.persisted, [false]);
        expect(recorder.calls, ['confirm', 'persist', 'stop']);
      });

      test('surfaces the post-stop status', () async {
        final stopped = _daemonStatus(health: DaemonHealth.stopped);
        final recorder = _RecordingTogglePorts(stopDaemon: () async => stopped);

        final result = await executeDaemonManagementToggle(
          currentlyManaging: true,
          daemonStatus: _runningManagedStatus,
          ports: recorder.ports,
        );

        expect(
          (result as DaemonManagementToggleDisabled).newStatus,
          same(stopped),
        );
      });
    });
  });

  // -------------------------------------------------------------------------
  // resolve-update-callout.ts
  // -------------------------------------------------------------------------
  group('resolveUpdateCalloutDescriptor', () {
    DesktopAppUpdateCheckPayload payload(String? latestVersion) =>
        DesktopAppUpdateCheckPayload(
          hasUpdate: true,
          readyToInstall: true,
          currentVersion: '1.0.0',
          latestVersion: latestVersion,
          body: null,
          date: null,
          errorMessage: null,
        );

    ResolveUpdateCalloutInput input({
      bool isDesktopApp = true,
      DesktopAppUpdateStatus status = DesktopAppUpdateStatus.available,
      bool isInstalling = false,
      Object? availableUpdate = _unsetAvailableUpdate,
      String? errorMessage,
    }) => ResolveUpdateCalloutInput(
      isDesktopApp: isDesktopApp,
      status: status,
      isInstalling: isInstalling,
      availableUpdate: identical(availableUpdate, _unsetAvailableUpdate)
          ? payload('1.2.3')
          : availableUpdate as DesktopAppUpdateCheckPayload?,
      errorMessage: errorMessage,
    );

    test('returns null when not running as a desktop app', () {
      expect(
        resolveUpdateCalloutDescriptor(input(isDesktopApp: false), t: _t),
        isNull,
      );
    });

    test(
      'returns null for idle / checking / up-to-date / pending statuses',
      () {
        for (final status in const [
          DesktopAppUpdateStatus.idle,
          DesktopAppUpdateStatus.checking,
          DesktopAppUpdateStatus.upToDate,
          DesktopAppUpdateStatus.pending,
        ]) {
          expect(
            resolveUpdateCalloutDescriptor(input(status: status), t: _t),
            isNull,
            reason: 'status $status must not raise a callout',
          );
        }
      },
    );

    test('builds an update-available descriptor with changelog + install '
        'actions', () {
      final descriptor = resolveUpdateCalloutDescriptor(input(), t: _t)!;

      expect(descriptor.id, 'desktop-update');
      expect(descriptor.priority, 200);
      expect(descriptor.testId, 'update-callout');
      expect(descriptor.title, 'Update available');
      expect(descriptor.variant, SidebarCalloutVariant.defaultVariant);
      expect(descriptor.showGiftIcon, isTrue);
      expect(descriptor.body, const UpdateCalloutAvailableBody('v1.2.3'));
      expect(descriptor.actions, [
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.changelog,
          label: "What's new",
        ),
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.install,
          label: 'Install & restart',
          variant: SidebarCalloutActionVariant.primary,
          disabled: false,
        ),
      ]);
      expect(descriptor.dismissalKey, 'desktop-update:available:1.2.3');
    });

    test('normalizes a leading v in the latest version', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(availableUpdate: payload('v2.0.0')),
        t: _t,
      );

      expect(descriptor?.body, const UpdateCalloutAvailableBody('v2.0.0'));
    });

    test('omits the version label when no latest version is known', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(availableUpdate: payload(null)),
        t: _t,
      );

      expect(descriptor?.body, const UpdateCalloutAvailableBody(null));
      expect(descriptor?.dismissalKey, 'desktop-update:available:unknown');
    });

    test('disables the install action and labels it Installing... while '
        'installing', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(status: DesktopAppUpdateStatus.installing, isInstalling: true),
        t: _t,
      )!;

      expect(descriptor.title, 'Installing update');
      expect(descriptor.body, const UpdateCalloutInstallingBody());
      expect(descriptor.showGiftIcon, isFalse);
      expect(descriptor.variant, SidebarCalloutVariant.defaultVariant);
      expect(descriptor.actions, [
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.changelog,
          label: "What's new",
        ),
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.install,
          label: 'Installing...',
          variant: SidebarCalloutActionVariant.primary,
          disabled: true,
        ),
      ]);
      expect(descriptor.dismissalKey, 'desktop-update:installing:1.2.3');
    });

    test('shows a retry action and surfaces the error message on error', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(
          status: DesktopAppUpdateStatus.error,
          errorMessage: 'Download failed',
          availableUpdate: null,
        ),
        t: _t,
      )!;

      expect(descriptor.title, 'Update failed');
      expect(descriptor.body, const UpdateCalloutErrorBody('Download failed'));
      expect(descriptor.variant, SidebarCalloutVariant.error);
      expect(descriptor.showGiftIcon, isFalse);
      expect(descriptor.actions, [
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.changelog,
          label: "What's new",
        ),
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.retry,
          label: 'Retry',
          variant: SidebarCalloutActionVariant.primary,
        ),
      ]);
      expect(descriptor.dismissalKey, 'desktop-update:error:unknown');
    });

    test('falls back to a generic error message when none is provided', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(status: DesktopAppUpdateStatus.error, availableUpdate: null),
        t: _t,
      );

      expect(
        descriptor?.body,
        const UpdateCalloutErrorBody('Something went wrong.'),
      );
    });

    test('encodes status and version into the dismissal key', () {
      expect(
        resolveUpdateCalloutDescriptor(
          input(availableUpdate: payload('1.2.4')),
          t: _t,
        )?.dismissalKey,
        'desktop-update:available:1.2.4',
      );
    });

    test('uses the active app language for local callout chrome', () {
      final descriptor = resolveUpdateCalloutDescriptor(input(), t: _tZh)!;

      expect(descriptor.title, '有可用更新');
      expect(descriptor.actions, [
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.changelog,
          label: '更新内容',
        ),
        const UpdateCalloutActionDescriptor(
          role: UpdateCalloutActionRole.install,
          label: '安装并重启',
          variant: SidebarCalloutActionVariant.primary,
          disabled: false,
        ),
      ]);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('returns null for the terminal installed status', () {
      expect(
        resolveUpdateCalloutDescriptor(
          input(status: DesktopAppUpdateStatus.installed),
          t: _t,
        ),
        isNull,
      );
    });

    test('an install started from the available status keeps the available '
        'dismissal key', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(status: DesktopAppUpdateStatus.available, isInstalling: true),
        t: _t,
      )!;

      expect(descriptor.title, 'Installing update');
      expect(descriptor.body, const UpdateCalloutInstallingBody());
      expect(descriptor.showGiftIcon, isFalse);
      expect(descriptor.dismissalKey, 'desktop-update:available:1.2.3');
      expect(descriptor.actions.last.disabled, isTrue);
    });

    test('installing while errored shows installing chrome but a retry '
        'action', () {
      // Upstream checks `isInstalling` first for the title/body but branches on
      // `isError` for the actions, so the two disagree by construction.
      final descriptor = resolveUpdateCalloutDescriptor(
        input(
          status: DesktopAppUpdateStatus.error,
          isInstalling: true,
          errorMessage: 'Download failed',
        ),
        t: _t,
      )!;

      expect(descriptor.title, 'Installing update');
      expect(descriptor.body, const UpdateCalloutInstallingBody());
      expect(descriptor.variant, SidebarCalloutVariant.error);
      expect(descriptor.showGiftIcon, isFalse);
      expect(descriptor.actions.last.role, UpdateCalloutActionRole.retry);
      expect(descriptor.actions.last.disabled, isNull);
    });

    test('a blank latest version is treated as no version at all', () {
      // JS falsiness: "" fails the guard in formatVersionLabel but survives the
      // nullish coalesce in the dismissal key.
      final descriptor = resolveUpdateCalloutDescriptor(
        input(availableUpdate: payload('')),
        t: _t,
      )!;

      expect(descriptor.body, const UpdateCalloutAvailableBody(null));
      expect(descriptor.dismissalKey, 'desktop-update:available:');
    });

    test('normalizes an upper-case V prefix', () {
      expect(formatUpdateCalloutVersionLabel('V2.0.0'), 'v2.0.0');
      expect(formatUpdateCalloutVersionLabel(null), isNull);
      expect(formatUpdateCalloutVersionLabel(''), isNull);
      expect(formatUpdateCalloutVersionLabel('2.0.0'), 'v2.0.0');
    });

    test('ignores an error message while an update is merely available', () {
      final descriptor = resolveUpdateCalloutDescriptor(
        input(errorMessage: 'stale failure'),
        t: _t,
      )!;

      expect(descriptor.body, const UpdateCalloutAvailableBody('v1.2.3'));
      expect(descriptor.variant, SidebarCalloutVariant.defaultVariant);
    });

    test('the resolved action list is not mutable by the caller', () {
      final descriptor = resolveUpdateCalloutDescriptor(input(), t: _t)!;

      expect(
        () => descriptor.actions.add(
          const UpdateCalloutActionDescriptor(
            role: UpdateCalloutActionRole.retry,
            label: 'nope',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('the optional action fields stay absent on the changelog action', () {
      final descriptor = resolveUpdateCalloutDescriptor(input(), t: _t)!;

      expect(descriptor.actions.first.variant, isNull);
      expect(descriptor.actions.first.disabled, isNull);
    });

    test('status wire names match the upstream string union', () {
      expect(DesktopAppUpdateStatus.values.map((status) => status.wireName), [
        'idle',
        'checking',
        'pending',
        'up-to-date',
        'available',
        'installing',
        'installed',
        'error',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // desktop-updates.ts — pure helpers
  // -------------------------------------------------------------------------
  group('desktop-updates helpers', () {
    test('normalizes versions for app-daemon comparisons', () {
      expect(normalizeVersionForComparison(' v0.1.15 '), '0.1.15');
      expect(normalizeVersionForComparison('0.1.15'), '0.1.15');
      expect(normalizeVersionForComparison(null), isNull);
    });

    test('detects version mismatch after normalization', () {
      expect(isVersionMismatch('v0.1.15', '0.1.15'), isFalse);
      expect(isVersionMismatch('0.1.15', '0.1.16'), isTrue);
      expect(isVersionMismatch('0.1.15', null), isFalse);
    });

    test('formats display versions with v prefix and unavailable fallback', () {
      expect(formatVersionWithPrefix('0.2.0'), 'v0.2.0');
      expect(formatVersionWithPrefix('v0.2.0'), 'v0.2.0');
      expect(formatVersionWithPrefix(null), '—');
    });

    test('parses valid local daemon version result', () {
      expect(
        parseLocalDaemonVersionResult({'version': '0.1.15', 'error': null}),
        const LocalDaemonVersionResult(version: '0.1.15', error: null),
      );
    });

    test('parses local daemon version error result', () {
      expect(
        parseLocalDaemonVersionResult({
          'version': null,
          'error': 'paseo command not found in PATH',
        }),
        const LocalDaemonVersionResult(
          version: null,
          error: 'paseo command not found in PATH',
        ),
      );
    });

    test('parses unexpected local daemon version result', () {
      const unexpected = LocalDaemonVersionResult(
        version: null,
        error: 'Unexpected response from version check.',
      );

      expect(parseLocalDaemonVersionResult(null), unexpected);
      expect(parseLocalDaemonVersionResult('not an object'), unexpected);
    });

    test('trims whitespace in parsed version', () {
      expect(
        parseLocalDaemonVersionResult({'version': ' 0.1.15 ', 'error': null}),
        const LocalDaemonVersionResult(version: '0.1.15', error: null),
      );
    });

    test('builds copyable daemon update diagnostics', () {
      final diagnostics = buildDaemonUpdateDiagnostics(
        const LocalDaemonUpdateResult(
          exitCode: 1,
          stdout: 'stdout text',
          stderr: 'stderr text',
        ),
      );

      expect(diagnostics, contains('Exit code: 1'));
      expect(diagnostics, contains('STDOUT:\nstdout text'));
      expect(diagnostics, contains('STDERR:\nstderr text'));
    });

    test('parses runtime info defensively', () {
      expect(
        parseDesktopRuntimeInfo({
          'appVersion': ' 0.1.64 ',
          'runningUnderARM64Translation': true,
        }),
        const DesktopRuntimeInfo(
          appVersion: '0.1.64',
          runningUnderARM64Translation: true,
        ),
      );
      expect(
        parseDesktopRuntimeInfo(null),
        const DesktopRuntimeInfo(
          appVersion: null,
          runningUnderARM64Translation: false,
        ),
      );
    });

    test('builds the direct Apple Silicon DMG URL from a version', () {
      expect(
        buildMacAppleSiliconDownloadUrl('v0.1.64'),
        'https://github.com/getpaseo/paseo/releases/download/v0.1.64/'
        'Paseo-0.1.64-arm64.dmg',
      );
      expect(buildMacAppleSiliconDownloadUrl(null), isNull);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('normalization strips an upper-case v and rejects blank input', () {
      expect(normalizeVersionForComparison('V1.0.0'), '1.0.0');
      expect(normalizeVersionForComparison('   '), isNull);
      expect(normalizeVersionForComparison(''), isNull);
      expect(normalizeVersionForComparison('vv1.0.0'), 'v1.0.0');
    });

    test('mismatch stays false when either side is blank', () {
      expect(isVersionMismatch('', '1.0.0'), isFalse);
      expect(isVersionMismatch('   ', '1.0.0'), isFalse);
      expect(isVersionMismatch(null, null), isFalse);
      expect(isVersionMismatch('V1.0.0', '1.0.0'), isFalse);
    });

    test(
      'the display prefix check is case sensitive, unlike normalization',
      () {
        // Frozen upstream quirk: `startsWith("v")` misses an upper-case prefix.
        expect(formatVersionWithPrefix('V0.2.0'), 'vV0.2.0');
        expect(formatVersionWithPrefix('  0.2.0  '), 'v0.2.0');
        expect(formatVersionWithPrefix('   '), '—');
        expect(formatVersionWithPrefix(''), '—');
      },
    );

    test(
      'the Apple Silicon URL rejects blank versions and drops the prefix',
      () {
        expect(buildMacAppleSiliconDownloadUrl('   '), isNull);
        expect(buildMacAppleSiliconDownloadUrl(''), isNull);
        expect(
          buildMacAppleSiliconDownloadUrl(' V1.2.3 '),
          'https://github.com/getpaseo/paseo/releases/download/v1.2.3/'
          'Paseo-1.2.3-arm64.dmg',
        );
      },
    );

    test('an array payload passes the JS isRecord guard', () {
      // `typeof [] === "object"` upstream, so an array is a record whose every
      // field is missing rather than an "unexpected response".
      expect(
        parseLocalDaemonVersionResult(const <Object?>[]),
        const LocalDaemonVersionResult(version: null, error: null),
      );
      expect(
        parseDesktopRuntimeInfo(const <Object?>[]),
        const DesktopRuntimeInfo(
          appVersion: null,
          runningUnderARM64Translation: false,
        ),
      );
    });

    test('non-string version fields are dropped', () {
      expect(
        parseLocalDaemonVersionResult({'version': 42, 'error': false}),
        const LocalDaemonVersionResult(version: null, error: null),
      );
      expect(
        parseLocalDaemonVersionResult({'version': '   ', 'error': ''}),
        const LocalDaemonVersionResult(version: null, error: null),
      );
    });

    test('runtime translation flag requires a strict true', () {
      expect(
        parseDesktopRuntimeInfo({
          'runningUnderARM64Translation': 'true',
        }).runningUnderARM64Translation,
        isFalse,
      );
      expect(
        parseDesktopRuntimeInfo({
          'runningUnderARM64Translation': 1,
        }).runningUnderARM64Translation,
        isFalse,
      );
      expect(
        parseDesktopRuntimeInfo(const <String, Object?>{}).appVersion,
        isNull,
      );
    });

    test('check payloads coerce every field defensively', () {
      expect(
        parseDesktopAppUpdateCheckResult(const {
          'hasUpdate': 'yes',
          'readyToInstall': true,
          'currentVersion': ' 1.0.0 ',
          'latestVersion': 2,
          'body': '',
          'date': '2026-01-01',
        }),
        const DesktopAppUpdateCheckPayload(
          hasUpdate: false,
          readyToInstall: true,
          currentVersion: '1.0.0',
          latestVersion: null,
          body: null,
          date: '2026-01-01',
          errorMessage: null,
        ),
      );
    });

    test('a non-object check reply throws', () {
      expect(
        () => parseDesktopAppUpdateCheckResult(null),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Unexpected response while checking desktop updates.'),
          ),
        ),
      );
      expect(
        () => parseDesktopAppUpdateCheckResult('nope'),
        throwsA(isA<Exception>()),
      );
    });

    test('install replies fall back to the localized installed message', () {
      final result = parseDesktopAppUpdateInstallResult(const {
        'installed': true,
        'version': '1.2.3',
      }, t: _t);

      expect(result.installed, isTrue);
      expect(result.version, '1.2.3');
      expect(result.message, 'App update installed. Restart required.');
    });

    test('install replies keep a host-supplied message', () {
      final result = parseDesktopAppUpdateInstallResult(const {
        'installed': false,
        'version': null,
        'message': ' staged  ',
      }, t: _t);

      expect(result.installed, isFalse);
      expect(result.version, isNull);
      expect(result.message, 'staged');
    });

    test('a non-object install reply throws', () {
      expect(
        () => parseDesktopAppUpdateInstallResult(null, t: _t),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Unexpected response while installing desktop update.'),
          ),
        ),
      );
    });

    test('daemon update replies default to a failing exit code', () {
      expect(
        parseLocalDaemonUpdateResult(const <String, Object?>{}),
        const LocalDaemonUpdateResult(exitCode: 1, stdout: '', stderr: ''),
      );
      expect(
        parseLocalDaemonUpdateResult(const {
          'exitCode': double.nan,
          'stdout': 42,
          'stderr': null,
        }),
        const LocalDaemonUpdateResult(exitCode: 1, stdout: '', stderr: ''),
      );
      expect(
        parseLocalDaemonUpdateResult(const {
          'exitCode': double.infinity,
        }).exitCode,
        1,
      );
      expect(
        parseLocalDaemonUpdateResult(const {
          'exitCode': 0,
          'stdout': 'ok',
          'stderr': '',
        }),
        const LocalDaemonUpdateResult(exitCode: 0, stdout: 'ok', stderr: ''),
      );
    });

    test('a non-object daemon update reply throws', () {
      expect(
        () => parseLocalDaemonUpdateResult(null),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Unexpected response while updating local daemon.'),
          ),
        ),
      );
    });

    test('diagnostics spell empty streams and render integral exit codes the '
        'way JS does', () {
      expect(
        buildDaemonUpdateDiagnostics(
          const LocalDaemonUpdateResult(exitCode: 2.0, stdout: '', stderr: ''),
        ),
        'Exit code: 2\n\nSTDOUT:\n(empty)\n\nSTDERR:\n(empty)',
      );
      expect(
        buildDaemonUpdateDiagnostics(
          const LocalDaemonUpdateResult(
            exitCode: 1.5,
            stdout: 'a',
            stderr: 'b',
          ),
        ),
        'Exit code: 1.5\n\nSTDOUT:\na\n\nSTDERR:\nb',
      );
    });

    test('value types compare by value', () {
      expect(
        const DesktopRuntimeInfo(
          appVersion: '1',
          runningUnderARM64Translation: true,
        ).hashCode,
        const DesktopRuntimeInfo(
          appVersion: '1',
          runningUnderARM64Translation: true,
        ).hashCode,
      );
      expect(
        const LocalDaemonUpdateResult(exitCode: 0, stdout: '', stderr: ''),
        isNot(
          const LocalDaemonUpdateResult(exitCode: 1, stdout: '', stderr: ''),
        ),
      );
      expect(
        const LocalDaemonVersionResult(version: 'a', error: null).hashCode,
        const LocalDaemonVersionResult(version: 'a', error: null).hashCode,
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop-updates.ts — host gateway
  // -------------------------------------------------------------------------
  group('DesktopUpdatesGateway', () {
    test('shows the update section only in an Electron web runtime', () {
      bool shows({required bool web, required bool electron}) =>
          DesktopUpdatesGateway(
            _FakeDesktopHost(isWebRuntime: web, isElectronRuntime: electron),
          ).shouldShowDesktopUpdateSection();

      expect(shows(web: true, electron: true), isTrue);
      expect(shows(web: true, electron: false), isFalse);
      expect(shows(web: false, electron: true), isFalse);
      expect(shows(web: false, electron: false), isFalse);
    });

    test('reads the local daemon version over its command', () async {
      final host = _FakeDesktopHost(
        replies: {
          'get_local_daemon_version': {'version': ' 0.1.15 ', 'error': null},
        },
      );

      final result = await DesktopUpdatesGateway(host).getLocalDaemonVersion();

      expect(result.version, '0.1.15');
      expect(host.commands, ['get_local_daemon_version']);
      expect(host.arguments, [null]);
    });

    test('reads the runtime info over its command', () async {
      final host = _FakeDesktopHost(
        replies: {
          'desktop_get_runtime_info': {
            'appVersion': '0.1.64',
            'runningUnderARM64Translation': true,
          },
        },
      );

      final result = await DesktopUpdatesGateway(host).getDesktopRuntimeInfo();

      expect(result.appVersion, '0.1.64');
      expect(result.runningUnderARM64Translation, isTrue);
      expect(host.commands, ['desktop_get_runtime_info']);
      expect(host.arguments, [null]);
    });

    test('forwards the release channel and intent when checking', () async {
      final host = _FakeDesktopHost(
        replies: {
          'check_app_update': {'hasUpdate': true, 'latestVersion': '1.2.3'},
        },
      );

      final result = await DesktopUpdatesGateway(host).checkDesktopAppUpdate(
        releaseChannel: DesktopAppReleaseChannel.beta,
        intent: DesktopAppUpdateCheckIntent.manual,
      );

      expect(result.hasUpdate, isTrue);
      expect(result.latestVersion, '1.2.3');
      expect(host.commands, ['check_app_update']);
      expect(host.arguments, [
        {'releaseChannel': 'beta', 'intent': 'manual'},
      ]);
    });

    test('forwards only the release channel when installing', () async {
      final host = _FakeDesktopHost(
        replies: {
          'install_app_update': {'installed': true, 'version': '1.2.3'},
        },
      );

      final result = await DesktopUpdatesGateway(host).installDesktopAppUpdate(
        releaseChannel: DesktopAppReleaseChannel.stable,
        t: _t,
      );

      expect(result.installed, isTrue);
      expect(result.message, 'App update installed. Restart required.');
      expect(host.commands, ['install_app_update']);
      expect(host.arguments, [
        {'releaseChannel': 'stable'},
      ]);
    });

    test('runs the local daemon update over its command', () async {
      final host = _FakeDesktopHost(
        replies: {
          'run_local_daemon_update': {
            'exitCode': 0,
            'stdout': 'done',
            'stderr': '',
          },
        },
      );

      final result = await DesktopUpdatesGateway(host).runLocalDaemonUpdate();

      expect(
        result,
        const LocalDaemonUpdateResult(exitCode: 0, stdout: 'done', stderr: ''),
      );
      expect(host.commands, ['run_local_daemon_update']);
      expect(host.arguments, [null]);
    });

    test('propagates a malformed check reply as a throw', () async {
      final host = _FakeDesktopHost(
        replies: const {'check_app_update': 'nope'},
      );

      await expectLater(
        DesktopUpdatesGateway(host).checkDesktopAppUpdate(
          releaseChannel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
