// Ports of the upstream test suites for Paseo's two desktop host-service
// modules — `desktop/permissions/desktop-permissions.test.ts` and
// `desktop/updates/desktop-app-updater.test.ts` (plus its
// `test-utils/fake-desktop-app-updater-port.ts` fake) — together with the edge
// cases those suites leave unpinned: every fallback branch of both permission
// readers, JS truthiness on empty error/version strings, the swallowed silent
// failures that are otherwise invisible, and every `formatStatusText` arm.
import 'dart:async';

import 'package:coding_agent_app/desktop/paseo_desktop_services.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Translators
//
// The repo has no localization layer, so both modules take a translator. These
// tables mirror upstream `i18n/resources/en.ts` and `zh-CN.ts` at exactly the
// keys the ported modules read, and `_interpolate` stands in for i18next's
// `{{name}}` substitution.
// ---------------------------------------------------------------------------

const Map<String, String> _en = {
  'desktop.permissions.notifications.allowed':
      'Notifications are allowed by the OS.',
  'desktop.permissions.notifications.denied':
      'Notifications are denied in system settings.',
  'desktop.permissions.notifications.notGranted':
      'Notifications have not been granted yet.',
  'desktop.permissions.notifications.webOnly':
      'Desktop notification status is only available on web runtime.',
  'desktop.permissions.notifications.supported':
      'Desktop notifications are supported.',
  'desktop.permissions.notifications.unsupported':
      'Desktop notifications are not supported on this platform.',
  'desktop.permissions.notifications.apiUnavailable':
      'Web Notification API is unavailable in this environment.',
  'desktop.permissions.notifications.requestsWebOnly':
      'Desktop notification requests are only available on web runtime.',
  'desktop.permissions.notifications.requestUnavailable':
      'Web Notification API requestPermission() is unavailable.',
  'desktop.permissions.notifications.requestFailed':
      'Failed to request notification permission: {{message}}',
  'desktop.permissions.notifications.unexpectedState':
      'Unexpected notification permission state: {{state}}',
  'desktop.permissions.microphone.webOnly':
      'Desktop microphone status is only available on web runtime.',
  'desktop.permissions.microphone.navigatorUnavailable':
      'Navigator is unavailable in this environment.',
  'desktop.permissions.microphone.granted': 'Microphone access is granted.',
  'desktop.permissions.microphone.denied':
      'Microphone access is denied in system settings.',
  'desktop.permissions.microphone.notGranted':
      'Microphone permission has not been granted yet.',
  'desktop.permissions.microphone.unexpectedState':
      'Unexpected microphone permission state: {{state}}',
  'desktop.permissions.microphone.statusApiUnavailable':
      'Microphone status API is unavailable in this runtime. Use Request to '
      'check access.',
  'desktop.permissions.microphone.queryFailed':
      'Failed to query microphone status: {{message}}',
  'desktop.permissions.microphone.captureUnavailable':
      'Microphone capture is unavailable in this environment.',
  'desktop.permissions.microphone.permissionApiUnavailable':
      'Permission status API is unavailable. Use Request to check access.',
  'desktop.permissions.microphone.requestsWebOnly':
      'Desktop microphone requests are only available on web runtime.',
  'desktop.permissions.microphone.captureApiUnavailable':
      'Microphone capture API is unavailable in this environment.',
  'desktop.permissions.microphone.requestDenied':
      'Microphone permission was denied by the user or system.',
  'desktop.permissions.microphone.noDevice': 'No microphone device was found.',
  'desktop.permissions.microphone.requestFailed':
      'Failed to request microphone permission: {{message}}',
  'desktop.updates.status.checking': 'Checking for app updates...',
  'desktop.updates.status.installing': 'Installing app update...',
  'desktop.updates.status.upToDate': 'App is up to date.',
  'desktop.updates.status.upToDateWithLastChecked':
      'Up to date. Last checked at {{time}}.',
  'desktop.updates.status.pending':
      "We'll let you know when the update is ready.",
  'desktop.updates.status.pendingWithLastChecked':
      "We'll let you know when the update is ready. Last checked at {{time}}.",
  'desktop.updates.status.pendingWithVersion':
      'Update found: {{version}}. Downloading...',
  'desktop.updates.status.pendingWithVersionAndLastChecked':
      'Update found: {{version}}. Downloading... Last checked at {{time}}.',
  'desktop.updates.status.availableWithVersion': 'Update ready: {{version}}',
  'desktop.updates.status.availableWithVersionAndLastChecked':
      'Update ready: {{version}}. Last checked at {{time}}.',
  'desktop.updates.status.available': 'An app update is ready to install.',
  'desktop.updates.status.availableWithLastChecked':
      'An app update is ready to install. Last checked at {{time}}.',
  'desktop.updates.status.installed': 'App update installed. Restart required.',
  'desktop.updates.status.failed': 'Failed to update app.',
  'desktop.updates.status.idle': 'Update status has not been checked yet.',
  'desktop.updates.installError': 'Unable to install the desktop app update.',
};

const Map<String, String> _zhCN = {
  'desktop.permissions.notifications.allowed': '系统已允许通知。',
  'desktop.permissions.microphone.notGranted': '麦克风权限尚未授予。',
  'desktop.updates.status.checking': '正在检查 app 更新...',
  'desktop.updates.status.availableWithVersion': '更新已就绪：{{version}}',
};

String _interpolate(String template, Map<String, String> params) {
  var rendered = template;
  params.forEach((name, value) {
    rendered = rendered.replaceAll('{{$name}}', value);
  });
  return rendered;
}

String _t(String key, [Map<String, String> params = const {}]) =>
    _interpolate(_en[key] ?? key, params);

String _tZh(String key, [Map<String, String> params = const {}]) =>
    _interpolate(_zhCN[key] ?? key, params);

// ---------------------------------------------------------------------------
// Permission fixtures
// ---------------------------------------------------------------------------

final DateTime _permissionsCheckedAt = DateTime.utc(2026, 7, 31, 12);

DesktopPermissionEnvironment _env({
  bool isWeb = true,
  DesktopPermissionHost? host,
  NotificationApi? notification,
  WebNavigatorApi? navigator,
  DateTime? now,
}) => DesktopPermissionEnvironment(
  isWeb: isWeb,
  getDesktopHost: () => host,
  getNotification: () => notification,
  getNavigator: () => navigator,
  now: () => now ?? _permissionsCheckedAt,
);

DesktopPermissions _permissions({
  bool isWeb = true,
  DesktopPermissionHost? host,
  NotificationApi? notification,
  WebNavigatorApi? navigator,
  DateTime? now,
  DesktopServicesTranslator translator = _t,
}) => DesktopPermissions(
  environment: _env(
    isWeb: isWeb,
    host: host,
    notification: notification,
    navigator: navigator,
    now: now,
  ),
  t: translator,
);

/// A `navigator.permissions` stand-in that resolves with [state].
WebNavigatorApi _navigatorWithQuery(
  String? state, {
  bool withCapture = true,
  List<String>? recordedNames,
}) => WebNavigatorApi(
  queryPermission: (name) async {
    recordedNames?.add(name);
    return PermissionQueryResult(state: state);
  },
  getUserMedia: withCapture ? (_) async => const MediaStreamLike() : null,
);

/// Mirrors upstream's `this`-sensitive `Permissions.query` fake.
///
/// Deviation note: JS throws a `TypeError` when `query` is invoked detached
/// from its owning `Permissions` instance, which is what the upstream test
/// guards against. A Dart tear-off is permanently bound to its receiver, so the
/// binding can never be lost — the assertion below is therefore structurally
/// unfailable, and the test is kept as documentation of that.
final class _BindingSensitivePermissionsApi {
  late final _BindingSensitivePermissionsApi _owner = this;

  Future<PermissionQueryResult?> query(String name) async {
    if (!identical(this, _owner)) {
      throw Exception(
        'Can only call Permissions.query on instances of Permissions',
      );
    }
    return const PermissionQueryResult(state: 'granted');
  }
}

// ---------------------------------------------------------------------------
// Updater fixtures
// ---------------------------------------------------------------------------

DesktopAppUpdateCheckPayload _checkResult({
  bool hasUpdate = false,
  bool readyToInstall = false,
  String? currentVersion,
  String? latestVersion,
  String? body,
  String? date,
  String? errorMessage,
}) => DesktopAppUpdateCheckPayload(
  hasUpdate: hasUpdate,
  readyToInstall: readyToInstall,
  currentVersion: currentVersion,
  latestVersion: latestVersion,
  body: body,
  date: date,
  errorMessage: errorMessage,
);

DesktopAppUpdateInstallResult _installResult({
  bool installed = false,
  String? version,
  String message = 'Update completed.',
}) => DesktopAppUpdateInstallResult(
  installed: installed,
  version: version,
  message: message,
);

typedef _RecordedCheck = ({
  DesktopAppReleaseChannel releaseChannel,
  DesktopAppUpdateCheckIntent intent,
});

sealed class _CheckOutcome {
  const _CheckOutcome();
}

final class _CheckResultOutcome extends _CheckOutcome {
  const _CheckResultOutcome(this.result);
  final DesktopAppUpdateCheckPayload result;
}

final class _CheckErrorOutcome extends _CheckOutcome {
  const _CheckErrorOutcome(this.error);
  final Object error;
}

final class _CheckDeferredOutcome extends _CheckOutcome {
  const _CheckDeferredOutcome(this.completer);
  final Completer<DesktopAppUpdateCheckPayload> completer;
}

/// Port of upstream `createFakeDesktopAppUpdaterPort`.
///
/// Records every call and replays a queued outcome per call, falling back to a
/// benign "no update" / "nothing installed" result once the queue drains — the
/// same contract as upstream, so an unscripted call is never a crash.
final class _FakeUpdaterPort implements DesktopAppUpdaterPort {
  final List<_RecordedCheck> recordedChecks = <_RecordedCheck>[];
  final List<DesktopAppReleaseChannel> recordedInstalls =
      <DesktopAppReleaseChannel>[];

  final List<_CheckOutcome> _checkOutcomes = <_CheckOutcome>[];
  final List<Object> _installOutcomes = <Object>[];

  void nextCheckResult(DesktopAppUpdateCheckPayload result) {
    _checkOutcomes.add(_CheckResultOutcome(result));
  }

  void failNextCheck(Object error) {
    _checkOutcomes.add(_CheckErrorOutcome(error));
  }

  Completer<DesktopAppUpdateCheckPayload> deferNextCheck() {
    final completer = Completer<DesktopAppUpdateCheckPayload>();
    _checkOutcomes.add(_CheckDeferredOutcome(completer));
    return completer;
  }

  void nextInstallResult(DesktopAppUpdateInstallResult result) {
    _installOutcomes.add(result);
  }

  void failNextInstall(Object error) {
    _installOutcomes.add(_CheckErrorOutcome(error));
  }

  @override
  Future<DesktopAppUpdateCheckPayload> checkDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
    required DesktopAppUpdateCheckIntent intent,
  }) {
    recordedChecks.add((releaseChannel: releaseChannel, intent: intent));
    if (_checkOutcomes.isEmpty) return Future.value(_checkResult());
    final outcome = _checkOutcomes.removeAt(0);
    return switch (outcome) {
      _CheckResultOutcome(:final result) => Future.value(result),
      _CheckErrorOutcome(:final error) =>
        Future<DesktopAppUpdateCheckPayload>.error(error),
      _CheckDeferredOutcome(:final completer) => completer.future,
    };
  }

  @override
  Future<DesktopAppUpdateInstallResult> installDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
  }) {
    recordedInstalls.add(releaseChannel);
    if (_installOutcomes.isEmpty) return Future.value(_installResult());
    final outcome = _installOutcomes.removeAt(0);
    if (outcome is _CheckErrorOutcome) {
      return Future<DesktopAppUpdateInstallResult>.error(outcome.error);
    }
    return Future.value(outcome as DesktopAppUpdateInstallResult);
  }
}

final DateTime _defaultNow = DateTime.fromMillisecondsSinceEpoch(1700000000000);
final DateTime _fortyTwo = DateTime.fromMillisecondsSinceEpoch(42);

final class _UpdaterHarness {
  _UpdaterHarness({DateTime? now})
    : port = _FakeUpdaterPort(),
      reportedInstallErrors = <DesktopAppUpdaterErrorReport>[],
      silentFailures = <({String logLabel, String message})>[] {
    updater = DesktopAppUpdater(
      port: port,
      now: () => now ?? _defaultNow,
      t: _t,
      reportInstallError: reportedInstallErrors.add,
      reportSilentCheckFailure: (logLabel, message) =>
          silentFailures.add((logLabel: logLabel, message: message)),
    );
  }

  final _FakeUpdaterPort port;
  final List<DesktopAppUpdaterErrorReport> reportedInstallErrors;
  final List<({String logLabel, String message})> silentFailures;
  late final DesktopAppUpdater updater;
}

const DesktopAppUpdateCheckRequest _manualStable = DesktopAppUpdateCheckRequest(
  releaseChannel: DesktopAppReleaseChannel.stable,
);

const DesktopAppUpdateCheckRequest _silentAutomaticStable =
    DesktopAppUpdateCheckRequest(
      releaseChannel: DesktopAppReleaseChannel.stable,
      intent: DesktopAppUpdateCheckIntent.automatic,
      silent: true,
    );

String _formatVersion(String? version) => version == null || version.isEmpty
    ? '—'
    : 'v${version.replaceFirst(RegExp('^v', caseSensitive: false), '')}';

String _formatLastCheckedAt(DateTime timestamp) =>
    'time-${timestamp.millisecondsSinceEpoch}';

String _statusText({
  required DesktopAppUpdateStatus status,
  DesktopAppUpdateCheckPayload? availableUpdate,
  String? installMessage,
  DateTime? lastCheckedAt,
  DesktopServicesTranslator translator = _t,
}) => formatDesktopAppUpdateStatusText(
  status: status,
  availableUpdate: availableUpdate,
  installMessage: installMessage,
  lastCheckedAt: lastCheckedAt,
  formatVersion: _formatVersion,
  formatLastCheckedAt: _formatLastCheckedAt,
  t: translator,
);

void main() {
  // -------------------------------------------------------------------------
  // desktop-permissions.ts — section visibility
  // -------------------------------------------------------------------------

  group('desktop permissions — section visibility', () {
    test('shows section only in desktop web runtime', () {
      expect(
        _permissions(
          isWeb: false,
          host: const DesktopPermissionHost(),
        ).shouldShowSection(),
        isFalse,
      );
      expect(_permissions(host: null).shouldShowSection(), isFalse);
      expect(
        _permissions(host: const DesktopPermissionHost()).shouldShowSection(),
        isTrue,
      );
    });

    test('a host with no notification bridge still shows the section', () {
      expect(
        _permissions(
          host: const DesktopPermissionHost(notification: null),
        ).shouldShowSection(),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop-permissions.ts — notification status
  // -------------------------------------------------------------------------

  group('desktop permissions — notification status', () {
    test('reads notification and microphone status', () async {
      final snapshot = await _permissions(
        notification: const NotificationApi(permission: 'default'),
        navigator: _navigatorWithQuery('granted'),
      ).readSnapshot();

      expect(snapshot.notifications.state, DesktopPermissionState.prompt);
      expect(snapshot.microphone.state, DesktopPermissionState.granted);
      expect(snapshot.checkedAt, _permissionsCheckedAt);
    });

    test('prefers the host support probe over the browser API', () async {
      final snapshot = await _permissions(
        host: DesktopPermissionHost(
          notification: DesktopNotificationProbe(isSupported: () async => true),
        ),
        notification: const NotificationApi(permission: 'denied'),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.granted,
          detail: _t('desktop.permissions.notifications.supported'),
        ),
      );
    });

    test('maps an unsupporting host to unavailable', () async {
      final snapshot = await _permissions(
        host: DesktopPermissionHost(
          notification: DesktopNotificationProbe(
            isSupported: () async => false,
          ),
        ),
        notification: const NotificationApi(permission: 'granted'),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.notifications.unsupported'),
        ),
      );
    });

    test('falls back to the browser API when the host probe throws', () async {
      final snapshot = await _permissions(
        host: DesktopPermissionHost(
          notification: DesktopNotificationProbe(
            isSupported: () async => throw Exception('bridge gone'),
          ),
        ),
        notification: const NotificationApi(permission: 'granted'),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.granted,
          detail: _t('desktop.permissions.notifications.allowed'),
        ),
      );
    });

    test(
      'reports the API as unavailable when the host probe throws and there is '
      'no browser API',
      () async {
        final snapshot = await _permissions(
          host: DesktopPermissionHost(
            notification: DesktopNotificationProbe(
              isSupported: () async => throw Exception('bridge gone'),
            ),
          ),
        ).readSnapshot();

        expect(
          snapshot.notifications,
          DesktopPermissionStatus(
            state: DesktopPermissionState.unavailable,
            detail: _t('desktop.permissions.notifications.apiUnavailable'),
          ),
        );
      },
    );

    test('reads browser Notification permission when available', () async {
      final snapshot = await _permissions(
        notification: const NotificationApi(permission: 'denied'),
        navigator: const WebNavigatorApi(),
      ).readSnapshot();

      expect(snapshot.notifications.state, DesktopPermissionState.denied);
      expect(
        snapshot.notifications.detail,
        _t('desktop.permissions.notifications.denied'),
      );
    });

    test('reports an unrecognised permission string verbatim', () async {
      final snapshot = await _permissions(
        notification: const NotificationApi(permission: 'sideways'),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Unexpected notification permission state: sideways',
        ),
      );
    });

    test('reports an absent Notification API', () async {
      final snapshot = await _permissions(
        notification: const NotificationApi(),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.notifications.apiUnavailable'),
        ),
      );
    });

    test('reports both permissions as web-only off the web runtime', () async {
      final snapshot = await _permissions(
        isWeb: false,
        host: DesktopPermissionHost(
          notification: DesktopNotificationProbe(isSupported: () async => true),
        ),
        notification: const NotificationApi(permission: 'granted'),
        navigator: _navigatorWithQuery('granted'),
      ).readSnapshot();

      expect(
        snapshot.notifications,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.notifications.webOnly'),
        ),
      );
      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.microphone.webOnly'),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop-permissions.ts — microphone status
  // -------------------------------------------------------------------------

  group('desktop permissions — microphone status', () {
    test('queries microphone permission with the correct binding', () async {
      final api = _BindingSensitivePermissionsApi();
      final snapshot = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: api.query,
          getUserMedia: (_) async => const MediaStreamLike(),
        ),
      ).readSnapshot();

      expect(snapshot.microphone.state, DesktopPermissionState.granted);
    });

    test('asks the permissions API about the microphone by name', () async {
      final names = <String>[];
      await _permissions(
        navigator: _navigatorWithQuery('granted', recordedNames: names),
      ).readSnapshot();

      expect(names, <String>['microphone']);
    });

    test(
      'returns a fallback message when the runtime blocks Permissions.query',
      () async {
        final snapshot = await _permissions(
          navigator: WebNavigatorApi(
            queryPermission: (_) async => throw Exception(
              'Can only call Permissions.query on instances of Permissions',
            ),
            getUserMedia: (_) async => const MediaStreamLike(),
          ),
        ).readSnapshot();

        expect(snapshot.microphone.state, DesktopPermissionState.unknown);
        expect(
          snapshot.microphone.detail,
          contains('Microphone status API is unavailable in this runtime.'),
        );
      },
    );

    test('treats an Illegal invocation the same way', () async {
      final snapshot = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async => throw Exception('Illegal invocation'),
        ),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: _t('desktop.permissions.microphone.statusApiUnavailable'),
        ),
      );
    });

    test('surfaces any other query failure with its message', () async {
      final snapshot = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async => throw Exception('offline'),
        ),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        const DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Failed to query microphone status: offline',
        ),
      );
    });

    test('maps a denied query result', () async {
      final snapshot = await _permissions(
        navigator: _navigatorWithQuery('denied'),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.denied,
          detail: _t('desktop.permissions.microphone.denied'),
        ),
      );
    });

    test('maps a prompt query result', () async {
      final snapshot = await _permissions(
        navigator: _navigatorWithQuery('prompt'),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.prompt,
          detail: _t('desktop.permissions.microphone.notGranted'),
        ),
      );
    });

    test('reports an unrecognised query state verbatim', () async {
      final snapshot = await _permissions(
        navigator: _navigatorWithQuery('sideways'),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        const DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Unexpected microphone permission state: sideways',
        ),
      );
    });

    test('labels a stateless query result as unknown', () async {
      final snapshot = await _permissions(
        navigator: _navigatorWithQuery(null),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        const DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Unexpected microphone permission state: unknown',
        ),
      );
    });

    test('reports an absent navigator', () async {
      final snapshot = await _permissions().readSnapshot();

      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.microphone.navigatorUnavailable'),
        ),
      );
    });

    test(
      'says the permission API is unavailable when only capture exists',
      () async {
        final snapshot = await _permissions(
          navigator: WebNavigatorApi(
            getUserMedia: (_) async => const MediaStreamLike(),
          ),
        ).readSnapshot();

        expect(
          snapshot.microphone,
          DesktopPermissionStatus(
            state: DesktopPermissionState.unknown,
            detail: _t(
              'desktop.permissions.microphone.permissionApiUnavailable',
            ),
          ),
        );
      },
    );

    test('says capture is unavailable when neither API exists', () async {
      final snapshot = await _permissions(
        navigator: const WebNavigatorApi(),
      ).readSnapshot();

      expect(
        snapshot.microphone,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.microphone.captureUnavailable'),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop-permissions.ts — requests
  // -------------------------------------------------------------------------

  group('desktop permissions — notification requests', () {
    test('requests notification permission via the browser API', () async {
      var calls = 0;
      final result = await _permissions(
        notification: NotificationApi(
          permission: 'default',
          requestPermission: () async {
            calls += 1;
            return 'granted';
          },
        ),
      ).request(DesktopPermissionKind.notifications);

      expect(result.state, DesktopPermissionState.granted);
      expect(calls, 1);
    });

    test('maps a declined request to denied', () async {
      final result = await _permissions(
        notification: NotificationApi(requestPermission: () async => 'denied'),
      ).request(DesktopPermissionKind.notifications);

      expect(result.state, DesktopPermissionState.denied);
    });

    test('maps a dismissed request back to prompt', () async {
      final result = await _permissions(
        notification: NotificationApi(requestPermission: () async => 'default'),
      ).request(DesktopPermissionKind.notifications);

      expect(result.state, DesktopPermissionState.prompt);
    });

    test('refuses notification requests off the web runtime', () async {
      final result = await _permissions(
        isWeb: false,
        notification: NotificationApi(requestPermission: () async => 'granted'),
      ).request(DesktopPermissionKind.notifications);

      expect(
        result,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.notifications.requestsWebOnly'),
        ),
      );
    });

    test('reports a missing requestPermission()', () async {
      final result = await _permissions(
        notification: const NotificationApi(permission: 'default'),
      ).request(DesktopPermissionKind.notifications);

      expect(
        result,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.notifications.requestUnavailable'),
        ),
      );
    });

    test('reports a failed notification request with its message', () async {
      final result = await _permissions(
        notification: NotificationApi(
          requestPermission: () async => throw Exception('nope'),
        ),
      ).request(DesktopPermissionKind.notifications);

      expect(
        result,
        const DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Failed to request notification permission: nope',
        ),
      );
    });
  });

  group('desktop permissions — microphone requests', () {
    test('requests microphone permission and stops acquired tracks', () async {
      var stops = 0;
      final constraints = <MediaCaptureConstraints>[];
      final result = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async =>
              const PermissionQueryResult(state: 'granted'),
          getUserMedia: (input) async {
            constraints.add(input);
            return MediaStreamLike(
              getTracks: () => <MediaStreamTrackLike>[
                MediaStreamTrackLike(stop: () => stops += 1),
              ],
            );
          },
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(result.state, DesktopPermissionState.granted);
      expect(constraints, <MediaCaptureConstraints>[
        const MediaCaptureConstraints(audio: true),
      ]);
      expect(stops, 1);
    });

    test('maps microphone request denial to denied status', () async {
      final result = await _permissions(
        navigator: WebNavigatorApi(
          getUserMedia: (_) async => throw const DesktopHostError(
            name: 'NotAllowedError',
            message: 'denied',
          ),
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(
        result,
        DesktopPermissionStatus(
          state: DesktopPermissionState.denied,
          detail: _t('desktop.permissions.microphone.requestDenied'),
        ),
      );
    });

    test('maps the legacy PermissionDeniedError name too', () async {
      final result = await _permissions(
        navigator: WebNavigatorApi(
          getUserMedia: (_) async => throw const DesktopHostError(
            name: 'PermissionDeniedError',
            message: 'denied',
          ),
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(result.state, DesktopPermissionState.denied);
    });

    test('maps a missing device to unavailable', () async {
      for (final name in <String>['NotFoundError', 'DevicesNotFoundError']) {
        final result = await _permissions(
          navigator: WebNavigatorApi(
            getUserMedia: (_) async =>
                throw DesktopHostError(name: name, message: 'no mic'),
          ),
        ).request(DesktopPermissionKind.microphone);

        expect(
          result,
          DesktopPermissionStatus(
            state: DesktopPermissionState.unavailable,
            detail: _t('desktop.permissions.microphone.noDevice'),
          ),
          reason: name,
        );
      }
    });

    test('reports any other capture failure with its message', () async {
      final result = await _permissions(
        navigator: WebNavigatorApi(
          getUserMedia: (_) async => throw Exception('device busy'),
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(
        result,
        const DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: 'Failed to request microphone permission: device busy',
        ),
      );
    });

    test('tolerates a null stream and a stream without tracks', () async {
      final nullStream = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async =>
              const PermissionQueryResult(state: 'granted'),
          getUserMedia: (_) async => null,
        ),
      ).request(DesktopPermissionKind.microphone);
      expect(nullStream.state, DesktopPermissionState.granted);

      final trackless = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async =>
              const PermissionQueryResult(state: 'granted'),
          getUserMedia: (_) async => const MediaStreamLike(),
        ),
      ).request(DesktopPermissionKind.microphone);
      expect(trackless.state, DesktopPermissionState.granted);
    });

    test('skips a track that cannot be stopped', () async {
      final result = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async =>
              const PermissionQueryResult(state: 'prompt'),
          getUserMedia: (_) async => MediaStreamLike(
            getTracks: () => <MediaStreamTrackLike>[
              const MediaStreamTrackLike(),
            ],
          ),
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(result.state, DesktopPermissionState.prompt);
    });

    test('refuses microphone requests off the web runtime', () async {
      final result = await _permissions(
        isWeb: false,
        navigator: WebNavigatorApi(
          getUserMedia: (_) async => const MediaStreamLike(),
        ),
      ).request(DesktopPermissionKind.microphone);

      expect(
        result,
        DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: _t('desktop.permissions.microphone.requestsWebOnly'),
        ),
      );
    });

    test('reports a missing capture API for both absence shapes', () async {
      final noNavigator = await _permissions().request(
        DesktopPermissionKind.microphone,
      );
      final noCapture = await _permissions(
        navigator: WebNavigatorApi(
          queryPermission: (_) async =>
              const PermissionQueryResult(state: 'granted'),
        ),
      ).request(DesktopPermissionKind.microphone);

      final expected = DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: _t('desktop.permissions.microphone.captureApiUnavailable'),
      );
      expect(noNavigator, expected);
      expect(noCapture, expected);
    });
  });

  group('desktop permissions — localization and clock', () {
    test('uses the active app language for local status details', () async {
      final snapshot = await _permissions(
        notification: const NotificationApi(permission: 'granted'),
        navigator: _navigatorWithQuery('prompt'),
        translator: _tZh,
      ).readSnapshot();

      expect(snapshot.notifications.detail, '系统已允许通知。');
      expect(snapshot.microphone.detail, '麦克风权限尚未授予。');
    });

    test('stamps the snapshot from the injected clock', () async {
      final stamped = DateTime.utc(1999, 12, 31, 23, 59);
      final snapshot = await _permissions(now: stamped).readSnapshot();

      expect(snapshot.checkedAt, stamped);
    });
  });

  // -------------------------------------------------------------------------
  // desktop-app-updater.ts — check
  // -------------------------------------------------------------------------

  group('desktop app updater — check', () {
    test(
      'forwards manual intent and the requested channel to the port',
      () async {
        final harness = _UpdaterHarness();
        harness.port.nextCheckResult(_checkResult());

        await harness.updater.checkForUpdates(
          const DesktopAppUpdateCheckRequest(
            releaseChannel: DesktopAppReleaseChannel.beta,
          ),
        );

        expect(harness.port.recordedChecks, <_RecordedCheck>[
          (
            releaseChannel: DesktopAppReleaseChannel.beta,
            intent: DesktopAppUpdateCheckIntent.manual,
          ),
        ]);
      },
    );

    test(
      'forwards automatic intent independently from silent UI state',
      () async {
        final harness = _UpdaterHarness();
        harness.port.nextCheckResult(_checkResult());

        await harness.updater.checkForUpdates(_silentAutomaticStable);

        expect(harness.port.recordedChecks, <_RecordedCheck>[
          (
            releaseChannel: DesktopAppReleaseChannel.stable,
            intent: DesktopAppUpdateCheckIntent.automatic,
          ),
        ]);
      },
    );

    test('does nothing at all when called without a request', () async {
      final harness = _UpdaterHarness();

      expect(await harness.updater.checkForUpdates(), isNull);
      expect(harness.port.recordedChecks, isEmpty);
      expect(harness.updater.getSnapshot().status, DesktopAppUpdateStatus.idle);
    });

    test(
      'does not add manual last-checked feedback for automatic checks',
      () async {
        final harness = _UpdaterHarness(now: _fortyTwo);
        harness.port.nextCheckResult(_checkResult(hasUpdate: true));

        await harness.updater.checkForUpdates(_silentAutomaticStable);

        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.pending,
        );
        expect(harness.updater.getSnapshot().lastCheckedAt, isNull);
      },
    );

    test(
      'a non-silent automatic check also leaves last-checked alone',
      () async {
        final harness = _UpdaterHarness(now: _fortyTwo);
        harness.port.nextCheckResult(_checkResult(hasUpdate: true));

        await harness.updater.checkForUpdates(
          const DesktopAppUpdateCheckRequest(
            releaseChannel: DesktopAppReleaseChannel.stable,
            intent: DesktopAppUpdateCheckIntent.automatic,
          ),
        );

        expect(harness.updater.getSnapshot().lastCheckedAt, isNull);
      },
    );

    test("moves to 'checking' during a non-silent check", () async {
      final harness = _UpdaterHarness();
      final deferred = harness.port.deferNextCheck();

      final pending = harness.updater.checkForUpdates(_manualStable);
      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.checking,
      );
      expect(harness.updater.getSnapshot().isChecking, isTrue);

      deferred.complete(_checkResult());
      await pending;
      expect(harness.updater.getSnapshot().isChecking, isFalse);
    });

    test('stays on the current status during a silent check', () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, readyToInstall: true),
      );
      await harness.updater.checkForUpdates(_manualStable);
      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.available,
      );

      final deferred = harness.port.deferNextCheck();
      final pending = harness.updater.checkForUpdates(_silentAutomaticStable);
      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.available,
      );

      deferred.complete(_checkResult(hasUpdate: true, readyToInstall: true));
      await pending;
    });

    test(
      "reports 'available' when the check resolves with a downloaded update",
      () async {
        final harness = _UpdaterHarness(now: _fortyTwo);
        harness.port.nextCheckResult(
          _checkResult(
            hasUpdate: true,
            readyToInstall: true,
            latestVersion: '1.2.3',
          ),
        );

        await harness.updater.checkForUpdates(_manualStable);

        final snapshot = harness.updater.getSnapshot();
        expect(snapshot.status, DesktopAppUpdateStatus.available);
        expect(snapshot.availableUpdate?.latestVersion, '1.2.3');
        expect(snapshot.lastCheckedAt, _fortyTwo);
      },
    );

    test('reports the found update while it is still preparing', () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, latestVersion: '1.2.3'),
      );

      await harness.updater.checkForUpdates(_manualStable);

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.pending);
      expect(snapshot.availableUpdate?.latestVersion, '1.2.3');
      expect(snapshot.availableUpdate?.readyToInstall, isFalse);
    });

    test(
      "reports 'up-to-date' when the check resolves with no update",
      () async {
        final harness = _UpdaterHarness();
        harness.port.nextCheckResult(_checkResult());

        await harness.updater.checkForUpdates(_manualStable);

        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.upToDate,
        );
      },
    );

    test('clears a previously found update once the app is current', () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(
          hasUpdate: true,
          readyToInstall: true,
          latestVersion: '1.2.3',
        ),
      );
      await harness.updater.checkForUpdates(_manualStable);

      harness.port.nextCheckResult(_checkResult());
      await harness.updater.checkForUpdates(_manualStable);

      expect(harness.updater.getSnapshot().availableUpdate, isNull);
    });

    test("reports 'error' when a non-silent check throws", () async {
      final harness = _UpdaterHarness();
      harness.port.failNextCheck(Exception('network down'));

      await harness.updater.checkForUpdates(_manualStable);

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.error);
      expect(snapshot.errorMessage, 'network down');
    });

    test('reports service-returned check errors', () async {
      final harness = _UpdaterHarness(now: _fortyTwo);
      harness.port.nextCheckResult(
        _checkResult(errorMessage: 'sha512 checksum mismatch'),
      );

      await harness.updater.checkForUpdates(_manualStable);

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.error);
      expect(snapshot.errorMessage, 'sha512 checksum mismatch');
      expect(snapshot.lastCheckedAt, _fortyTwo);
    });

    test('treats an empty errorMessage as no error at all', () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, readyToInstall: true, errorMessage: ''),
      );

      await harness.updater.checkForUpdates(_manualStable);

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.available);
      expect(snapshot.errorMessage, isNull);
    });

    test('keeps no-update silent check errors quiet', () async {
      final harness = _UpdaterHarness(now: _fortyTwo);
      harness.port.nextCheckResult(
        _checkResult(
          hasUpdate: true,
          readyToInstall: true,
          latestVersion: '1.2.3',
        ),
      );
      await harness.updater.checkForUpdates(_manualStable);

      harness.port.nextCheckResult(_checkResult(errorMessage: 'network down'));
      final result = await harness.updater.checkForUpdates(
        _silentAutomaticStable,
      );

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.available);
      expect(snapshot.errorMessage, isNull);
      expect(snapshot.lastCheckedAt, _fortyTwo);
      // The host result still comes back to the caller; only the state is left
      // untouched.
      expect(result?.errorMessage, 'network down');
      expect(harness.silentFailures, <({String logLabel, String message})>[
        (
          logLabel: '[DesktopUpdater] Silent update check failed',
          message: 'network down',
        ),
      ]);
    });

    test(
      'shows silent update preparation errors when an update is involved',
      () async {
        final harness = _UpdaterHarness();
        harness.port.nextCheckResult(
          _checkResult(
            hasUpdate: true,
            latestVersion: '1.2.3',
            errorMessage: 'sha512 checksum mismatch',
          ),
        );

        await harness.updater.checkForUpdates(_silentAutomaticStable);

        final snapshot = harness.updater.getSnapshot();
        expect(snapshot.status, DesktopAppUpdateStatus.error);
        expect(snapshot.errorMessage, 'sha512 checksum mismatch');
        expect(snapshot.lastCheckedAt, isNull);
        expect(harness.silentFailures, isEmpty);
      },
    );

    test(
      'does not let a silent check supersede an in-flight manual check',
      () async {
        final harness = _UpdaterHarness();
        final deferred = harness.port.deferNextCheck();

        final manualCheck = harness.updater.checkForUpdates(_manualStable);
        harness.port.nextCheckResult(
          _checkResult(errorMessage: 'network down'),
        );
        await harness.updater.checkForUpdates(_silentAutomaticStable);

        deferred.complete(_checkResult());
        await manualCheck;

        expect(harness.port.recordedChecks, <_RecordedCheck>[
          (
            releaseChannel: DesktopAppReleaseChannel.stable,
            intent: DesktopAppUpdateCheckIntent.manual,
          ),
        ]);
        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.upToDate,
        );
      },
    );

    test(
      'does not let an older silent check supersede a newer silent check',
      () async {
        final harness = _UpdaterHarness();
        final olderCheck = harness.port.deferNextCheck();
        final olderPending = harness.updater.checkForUpdates(
          _silentAutomaticStable,
        );
        final newerCheck = harness.port.deferNextCheck();
        final newerPending = harness.updater.checkForUpdates(
          _silentAutomaticStable,
        );

        newerCheck.complete(
          _checkResult(
            hasUpdate: true,
            readyToInstall: true,
            latestVersion: '2.0.0',
          ),
        );
        await newerPending;
        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.available,
        );
        expect(
          harness.updater.getSnapshot().availableUpdate?.latestVersion,
          '2.0.0',
        );

        olderCheck.complete(_checkResult());
        await olderPending;

        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.available,
        );
        expect(
          harness.updater.getSnapshot().availableUpdate?.latestVersion,
          '2.0.0',
        );
      },
    );

    test(
      'lets a newer silent check win after an older one resolves first',
      () async {
        final harness = _UpdaterHarness();
        final olderCheck = harness.port.deferNextCheck();
        final olderPending = harness.updater.checkForUpdates(
          _silentAutomaticStable,
        );
        final newerCheck = harness.port.deferNextCheck();
        final newerPending = harness.updater.checkForUpdates(
          _silentAutomaticStable,
        );

        olderCheck.complete(_checkResult());
        await olderPending;
        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.idle,
        );

        newerCheck.complete(
          _checkResult(
            hasUpdate: true,
            readyToInstall: true,
            latestVersion: '2.0.0',
          ),
        );
        await newerPending;

        expect(
          harness.updater.getSnapshot().status,
          DesktopAppUpdateStatus.available,
        );
        expect(
          harness.updater.getSnapshot().availableUpdate?.latestVersion,
          '2.0.0',
        );
      },
    );

    test("does not move to 'error' when a silent check throws", () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, readyToInstall: true),
      );
      await harness.updater.checkForUpdates(_manualStable);
      final statusBeforeSilent = harness.updater.getSnapshot().status;

      harness.port.failNextCheck(Exception('boom'));
      final result = await harness.updater.checkForUpdates(
        _silentAutomaticStable,
      );

      expect(harness.updater.getSnapshot().status, statusBeforeSilent);
      expect(result, isNull);
      expect(harness.silentFailures, <({String logLabel, String message})>[
        (
          logLabel: '[DesktopUpdater] Silent update check failed',
          message: 'boom',
        ),
      ]);
    });

    test('ignores the older result when a newer check supersedes it', () async {
      final harness = _UpdaterHarness();
      final firstDeferred = harness.port.deferNextCheck();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, readyToInstall: true),
      );

      final firstPending = harness.updater.checkForUpdates(_manualStable);
      final secondPending = harness.updater.checkForUpdates(_manualStable);
      await secondPending;
      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.available,
      );

      firstDeferred.complete(_checkResult());
      // The superseded call still hands its host result back to its own caller.
      expect((await firstPending)?.hasUpdate, isFalse);

      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.available,
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop-app-updater.ts — install
  // -------------------------------------------------------------------------

  group('desktop app updater — install', () {
    test('forwards the requested release channel to the port', () async {
      final harness = _UpdaterHarness();
      harness.port.nextInstallResult(_installResult(installed: true));

      await harness.updater.installUpdate(
        releaseChannel: DesktopAppReleaseChannel.beta,
      );

      expect(harness.port.recordedInstalls, <DesktopAppReleaseChannel>[
        DesktopAppReleaseChannel.beta,
      ]);
    });

    test("moves to 'installed' when the install reports success", () async {
      final harness = _UpdaterHarness(now: _fortyTwo);
      harness.port.nextInstallResult(
        _installResult(installed: true, message: 'Restart to finish'),
      );

      await harness.updater.installUpdate(
        releaseChannel: DesktopAppReleaseChannel.stable,
      );

      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.installed);
      expect(snapshot.installMessage, 'Restart to finish');
      expect(snapshot.isInstalling, isFalse);
      expect(snapshot.lastCheckedAt, _fortyTwo);
      expect(snapshot.availableUpdate, isNull);
    });

    test("moves to 'up-to-date' when there was nothing to install", () async {
      final harness = _UpdaterHarness();
      harness.port.nextInstallResult(_installResult());

      await harness.updater.installUpdate(
        releaseChannel: DesktopAppReleaseChannel.stable,
      );

      expect(
        harness.updater.getSnapshot().status,
        DesktopAppUpdateStatus.upToDate,
      );
    });

    test("marks the install in flight and clears the previous error", () async {
      final harness = _UpdaterHarness();
      harness.port.failNextCheck(Exception('network down'));
      await harness.updater.checkForUpdates(_manualStable);
      expect(harness.updater.getSnapshot().errorMessage, 'network down');

      harness.port.nextInstallResult(_installResult(installed: true));
      // `installUpdate` commits the in-flight state synchronously, before it
      // ever awaits the port — this is what disables the button immediately.
      final pending = harness.updater.installUpdate(
        releaseChannel: DesktopAppReleaseChannel.stable,
      );

      final inFlight = harness.updater.getSnapshot();
      expect(inFlight.status, DesktopAppUpdateStatus.installing);
      expect(inFlight.isInstalling, isTrue);
      expect(inFlight.errorMessage, isNull);

      await pending;
    });

    test("reports the install error and moves to 'error'", () async {
      final harness = _UpdaterHarness();
      final error = Exception('install failed');
      harness.port.failNextInstall(error);

      final result = await harness.updater.installUpdate(
        releaseChannel: DesktopAppReleaseChannel.stable,
      );

      expect(result, isNull);
      final snapshot = harness.updater.getSnapshot();
      expect(snapshot.status, DesktopAppUpdateStatus.error);
      expect(snapshot.errorMessage, 'install failed');
      expect(snapshot.isInstalling, isFalse);
      expect(harness.reportedInstallErrors, <DesktopAppUpdaterErrorReport>[
        DesktopAppUpdaterErrorReport(
          error: error,
          message: 'Unable to install the desktop app update.',
          logLabel: '[DesktopUpdater] Failed to install app update',
        ),
      ]);
    });

    test(
      'keeps the previous install message when the install throws',
      () async {
        final harness = _UpdaterHarness();
        harness.port.nextInstallResult(
          _installResult(installed: true, message: 'Restart to finish'),
        );
        await harness.updater.installUpdate(
          releaseChannel: DesktopAppReleaseChannel.stable,
        );

        harness.port.failNextInstall(Exception('install failed'));
        await harness.updater.installUpdate(
          releaseChannel: DesktopAppReleaseChannel.stable,
        );

        expect(
          harness.updater.getSnapshot().installMessage,
          'Restart to finish',
        );
      },
    );

    test('works without an install error sink', () async {
      final port = _FakeUpdaterPort()..failNextInstall(Exception('boom'));
      final updater = DesktopAppUpdater(
        port: port,
        now: () => _defaultNow,
        t: _t,
      );

      expect(
        await updater.installUpdate(
          releaseChannel: DesktopAppReleaseChannel.stable,
        ),
        isNull,
      );
      expect(updater.getSnapshot().status, DesktopAppUpdateStatus.error);
    });

    test('works without a silent failure sink', () async {
      final port = _FakeUpdaterPort()..failNextCheck(Exception('boom'));
      final updater = DesktopAppUpdater(
        port: port,
        now: () => _defaultNow,
        t: _t,
      );

      expect(await updater.checkForUpdates(_silentAutomaticStable), isNull);
      expect(updater.getSnapshot().status, DesktopAppUpdateStatus.idle);
    });
  });

  // -------------------------------------------------------------------------
  // desktop-app-updater.ts — subscribe
  // -------------------------------------------------------------------------

  group('desktop app updater — subscribe', () {
    test('notifies subscribers when the status changes', () async {
      final harness = _UpdaterHarness();
      harness.port.nextCheckResult(
        _checkResult(hasUpdate: true, readyToInstall: true),
      );

      final notifications = <DesktopAppUpdateStatus>[];
      final unsubscribe = harness.updater.subscribe(() {
        notifications.add(harness.updater.getSnapshot().status);
      });

      await harness.updater.checkForUpdates(_manualStable);
      unsubscribe();

      expect(notifications, <DesktopAppUpdateStatus>[
        DesktopAppUpdateStatus.checking,
        DesktopAppUpdateStatus.available,
      ]);
    });

    test(
      'stops notifying after unsubscribe, and unsubscribing twice is safe',
      () async {
        final harness = _UpdaterHarness();
        var calls = 0;
        final unsubscribe = harness.updater.subscribe(() => calls += 1);
        unsubscribe();
        unsubscribe();

        harness.port.nextCheckResult(_checkResult());
        await harness.updater.checkForUpdates(_manualStable);

        expect(calls, 0);
      },
    );

    test('notifies every subscriber', () async {
      final harness = _UpdaterHarness();
      var first = 0;
      var second = 0;
      harness.updater.subscribe(() => first += 1);
      harness.updater.subscribe(() => second += 1);

      harness.port.nextCheckResult(_checkResult());
      await harness.updater.checkForUpdates(_manualStable);

      expect(first, 2);
      expect(second, 2);
    });

    test('returns the same cached snapshot until state changes', () async {
      final harness = _UpdaterHarness();
      final before = harness.updater.getSnapshot();

      expect(identical(harness.updater.getSnapshot(), before), isTrue);

      harness.port.nextCheckResult(_checkResult());
      await harness.updater.checkForUpdates(_manualStable);

      expect(identical(harness.updater.getSnapshot(), before), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // desktop-app-updater.ts — formatStatusText
  // -------------------------------------------------------------------------

  group('formatDesktopAppUpdateStatusText', () {
    test('shows when an up-to-date check completed', () {
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.upToDate,
          lastCheckedAt: _fortyTwo,
        ),
        'Up to date. Last checked at time-42.',
      );
    });

    test('falls back to the plain up-to-date wording', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.upToDate),
        'App is up to date.',
      );
    });

    test("uses the latest version in the 'available' message", () {
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.available,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
        ),
        'Update ready: v1.2.3',
      );
    });

    test('shows the found version while an update is pending', () {
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.pending,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
          lastCheckedAt: _fortyTwo,
        ),
        'Update found: v1.2.3. Downloading... Last checked at time-42.',
      );
    });

    test('shows a pending update without a version', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.pending),
        "We'll let you know when the update is ready.",
      );
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.pending,
          lastCheckedAt: _fortyTwo,
        ),
        "We'll let you know when the update is ready. Last checked at time-42.",
      );
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.pending,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
        ),
        'Update found: v1.2.3. Downloading...',
      );
    });

    test('keeps manual check feedback visible when an update is available', () {
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.available,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
          lastCheckedAt: _fortyTwo,
        ),
        'Update ready: v1.2.3. Last checked at time-42.',
      );
    });

    test('falls back to a generic available message with no version', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.available),
        'An app update is ready to install.',
      );
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.available,
          lastCheckedAt: _fortyTwo,
        ),
        'An app update is ready to install. Last checked at time-42.',
      );
    });

    test('treats an empty version string as no version at all', () {
      // Upstream guards with JS truthiness, so "" is not a version.
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.available,
          availableUpdate: _checkResult(latestVersion: ''),
        ),
        'An app update is ready to install.',
      );
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.pending,
          availableUpdate: _checkResult(latestVersion: ''),
        ),
        "We'll let you know when the update is ready.",
      );
    });

    test("uses the install message in the 'installed' state", () {
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.installed,
          installMessage: 'Restart now',
        ),
        'Restart now',
      );
    });

    test('falls back to the generic installed wording', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.installed),
        'App update installed. Restart required.',
      );
    });

    test('renders the transient and terminal statuses', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.checking),
        'Checking for app updates...',
      );
      expect(
        _statusText(status: DesktopAppUpdateStatus.installing),
        'Installing app update...',
      );
      expect(
        _statusText(status: DesktopAppUpdateStatus.error),
        'Failed to update app.',
      );
      expect(
        _statusText(status: DesktopAppUpdateStatus.idle),
        'Update status has not been checked yet.',
      );
    });

    test('ignores the version and last-checked stamp in terminal states', () {
      // `error` deliberately shows no detail here; the reason lives in the
      // snapshot's errorMessage instead.
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.error,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
          lastCheckedAt: _fortyTwo,
        ),
        'Failed to update app.',
      );
    });

    test('uses the active app language for local status wrappers', () {
      expect(
        _statusText(status: DesktopAppUpdateStatus.checking, translator: _tZh),
        '正在检查 app 更新...',
      );
      expect(
        _statusText(
          status: DesktopAppUpdateStatus.available,
          availableUpdate: _checkResult(latestVersion: '1.2.3'),
          translator: _tZh,
        ),
        '更新已就绪：v1.2.3',
      );
    });
  });
}
