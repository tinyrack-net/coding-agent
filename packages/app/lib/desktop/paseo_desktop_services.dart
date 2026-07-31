/// Port of Paseo 0.2.0's two desktop *host-service* modules — the pair that
/// talk to capabilities living outside the app bundle:
///
/// - `desktop/permissions/desktop-permissions.ts` — reads and requests the two
///   OS permissions the desktop shell needs (notifications, microphone),
///   preferring the Electron/Tauri host's own answer and falling back to the
///   browser `Notification` / `navigator.permissions` / `getUserMedia` APIs.
/// - `desktop/updates/desktop-app-updater.ts` — the observable state machine
///   behind the "check for updates" / "install & restart" buttons: which status
///   the settings row is in, which in-flight check is allowed to write it, and
///   how that status renders as a sentence.
///
/// Upstream both modules reach for process-global browser and host objects
/// (`globalThis.Notification`, `navigator`, `getDesktopHost()`, `Date.now()`,
/// the `i18n` singleton). Here every one of those is a narrow injected port, so
/// the whole file is exercisable with no desktop shell, no browser and no
/// wall clock.
///
/// The status enum, the release-channel/intent enums and both result payloads
/// are *reused* from [paseo_desktop_daemon_rules], which ported the sibling
/// `desktop-updates.ts` and `resolve-update-callout.ts` first; this library
/// deliberately declares no parallel copies of them.
library;

import 'paseo_desktop_daemon_rules.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateCheckPayload,
        DesktopAppUpdateInstallResult,
        DesktopAppUpdateStatus,
        daemonManagementErrorMessage,
        daemonManagementErrorName;

// Re-exported because they appear throughout this library's public signatures,
// so a caller wiring up the updater should not need to know which sibling
// module first introduced them.
export 'paseo_desktop_daemon_rules.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateCheckPayload,
        DesktopAppUpdateInstallResult,
        DesktopAppUpdateStatus;

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

/// Translator for the localized strings both modules emit.
///
/// Injected because this repo has no localization layer yet (`i18n/*` is
/// tracked separately); upstream reaches for the `i18n` singleton directly at
/// the same keys.
///
/// Deviation note: this is *not* `ComposerTranslator`. Nearly every string
/// these two modules read interpolates a value (`{{state}}`, `{{message}}`,
/// `{{version}}`, `{{time}}`), which a key-only translator cannot express, so
/// this typedef carries i18next's second `options` argument as a parameter bag.
typedef DesktopServicesTranslator =
    String Function(String key, [Map<String, String> params]);

/// A thrown host failure that carries a DOM-style `name` beside its message.
///
/// Deviation note: upstream's `getErrorName()` reads `.name` off *any* thrown
/// object — the upstream suite literally throws a bare `{ name, message }`
/// object literal to simulate a `getUserMedia` rejection. Dart has no
/// structural property access on `Object`, so the port recognises named
/// failures through this narrow type instead. Anything else falls back to the
/// runtime type name, which is the closest analogue of JS's `Error.prototype
/// .name` (`new Error(...)` is named `"Error"`, a `TypeError` is named
/// `"TypeError"`), and which lets a host that declares its own
/// `NotAllowedError` class be recognised without adopting this type.
final class DesktopHostError implements Exception {
  const DesktopHostError({required this.name, required this.message});

  /// The DOM error name the permission rules branch on, e.g.
  /// `NotAllowedError`, `NotFoundError`.
  final String name;

  /// Human-readable reason, used verbatim in "failed: {{message}}" details.
  final String message;

  @override
  String toString() => '$name: $message';
}

/// Matches the `Exception: ` / `Error: ` prefix Dart's default `toString()`
/// adds but JS's `error.message` does not.
final RegExp _dartThrowablePrefix = RegExp(r'^(Exception|Error):\s*');

/// Best-effort analogue of JS `error.message`.
///
/// Reuses [daemonManagementErrorMessage] (the same question, already answered
/// once in the sibling module) and then strips Dart's `Exception: ` prefix, so
/// a thrown `Exception('network down')` surfaces as `network down` exactly as
/// upstream's `new Error("network down")` does. This prefix-stripping is the
/// convention already used by `core/desktop/desktop_app_update_service.dart`.
String _errorMessage(Object error) => error is DesktopHostError
    ? error.message
    : daemonManagementErrorMessage(
        error,
      ).replaceFirst(_dartThrowablePrefix, '');

/// Best-effort analogue of JS `error.name`; null when there is nothing to
/// branch on, matching upstream's "not an object, or blank name" guard.
String? _errorName(Object error) {
  final name = error is DesktopHostError
      ? error.name
      : daemonManagementErrorName(error);
  return name.isEmpty ? null : name;
}

// ---------------------------------------------------------------------------
// desktop-permissions.ts
// ---------------------------------------------------------------------------

/// Which OS permission a caller is asking about.
enum DesktopPermissionKind { notifications, microphone }

/// How a permission currently stands.
///
/// Each value carries its upstream wire spelling because the union members are
/// plain strings upstream and may be persisted or logged.
///
/// Deviation note: [notGranted] is declared in upstream's
/// `DesktopPermissionState` union but no code path ever produces it — the
/// "not granted yet" *messages* are attached to [prompt]. It is kept so the
/// type is a faithful port rather than a silently narrowed one.
enum DesktopPermissionState {
  granted('granted'),
  denied('denied'),
  prompt('prompt'),
  notGranted('not-granted'),
  unavailable('unavailable'),
  unknown('unknown');

  const DesktopPermissionState(this.wireName);

  /// The literal upstream string union member.
  final String wireName;
}

/// One permission's state plus the sentence the settings row shows for it.
final class DesktopPermissionStatus {
  const DesktopPermissionStatus({required this.state, required this.detail});

  final DesktopPermissionState state;

  /// Already-localized explanation. Kept beside the state because several
  /// distinct causes collapse to the same state (three different reasons all
  /// read [DesktopPermissionState.unavailable]).
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is DesktopPermissionStatus &&
      other.state == state &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(state, detail);

  @override
  String toString() =>
      'DesktopPermissionStatus(state: $state, detail: $detail)';
}

/// Both permissions read together, with the moment they were read.
final class DesktopPermissionSnapshot {
  const DesktopPermissionSnapshot({
    required this.checkedAt,
    required this.notifications,
    required this.microphone,
  });

  /// Deviation note: upstream stores `Date.now()` as a raw epoch number. Modelled
  /// as a [DateTime] to match this repo's injected-clock convention
  /// (`DateTime Function()`); the value is still whatever the injected clock
  /// returned, so nothing observable changes.
  final DateTime checkedAt;

  final DesktopPermissionStatus notifications;
  final DesktopPermissionStatus microphone;

  @override
  bool operator ==(Object other) =>
      other is DesktopPermissionSnapshot &&
      other.checkedAt == checkedAt &&
      other.notifications == notifications &&
      other.microphone == microphone;

  @override
  int get hashCode => Object.hash(checkedAt, notifications, microphone);

  @override
  String toString() =>
      'DesktopPermissionSnapshot(checkedAt: $checkedAt, '
      'notifications: $notifications, microphone: $microphone)';
}

/// The desktop host's notification capability probe.
///
/// Deviation note: upstream's `DesktopNotificationBridge` is an interface whose
/// every member is optional, because the host process ships independently of
/// the app bundle and older hosts simply lack the method. Modelled as a nullable
/// function field so "the host is too old to answer" stays representable.
final class DesktopNotificationProbe {
  const DesktopNotificationProbe({this.isSupported});

  /// Upstream `notification.isSupported()`. Null when the host does not expose
  /// it, which upstream detects with `typeof ... === "function"`.
  final Future<bool> Function()? isSupported;
}

/// The slice of the Electron/Tauri host bridge these permission rules touch.
///
/// Deviation note: the sibling [paseo_desktop_daemon_rules] library already
/// narrows a *different* slice of the same upstream `DesktopHostBridge` (the
/// IPC `invoke` surface). Rather than widen that frozen port — or force a
/// permissions caller to implement `invokeCommand` it never uses — the
/// notification slice is its own type. Both correspond to the same upstream
/// interface with all-optional members.
final class DesktopPermissionHost {
  const DesktopPermissionHost({this.notification});

  final DesktopNotificationProbe? notification;
}

/// The browser `Notification` constructor object, as far as these rules use it.
final class NotificationApi {
  const NotificationApi({this.permission, this.requestPermission});

  /// `Notification.permission`: `"granted" | "denied" | "default"`, or an
  /// unrecognised string from a nonconforming runtime. Null models the property
  /// being absent, which upstream detects with `typeof ... === "string"`.
  final String? permission;

  /// `Notification.requestPermission()`. Null when the runtime lacks it.
  final Future<String> Function()? requestPermission;
}

/// The `{ audio: boolean }` constraint bag handed to `getUserMedia`.
///
/// Modelled as a type rather than inlined as a bool so a fake can assert it was
/// called with exactly `{ audio: true }`, as the upstream suite does.
final class MediaCaptureConstraints {
  const MediaCaptureConstraints({required this.audio});

  final bool audio;

  @override
  bool operator ==(Object other) =>
      other is MediaCaptureConstraints && other.audio == audio;

  @override
  int get hashCode => audio.hashCode;

  @override
  String toString() => 'MediaCaptureConstraints(audio: $audio)';
}

/// One track of an acquired [MediaStreamLike].
final class MediaStreamTrackLike {
  const MediaStreamTrackLike({this.stop});

  /// Null models a track object without a `stop` method; upstream skips those
  /// rather than throwing.
  final void Function()? stop;
}

/// The stream `getUserMedia` resolves with. Only used to release it again.
final class MediaStreamLike {
  const MediaStreamLike({this.getTracks});

  /// Null models a stream object without `getTracks`; upstream then releases
  /// nothing instead of throwing.
  final List<MediaStreamTrackLike> Function()? getTracks;
}

/// The result of `navigator.permissions.query({ name })`.
final class PermissionQueryResult {
  const PermissionQueryResult({this.state});

  /// `"granted" | "denied" | "prompt"`, or anything else from a nonconforming
  /// runtime. Null when the runtime resolved with an object that has no state.
  final String? state;
}

/// The slice of `navigator` these rules touch.
///
/// Deviation note: upstream separately guards `navigator.permissions` existing
/// and `navigator.permissions.query` being callable, and likewise for
/// `navigator.mediaDevices` / `getUserMedia`. Nullable function fields collapse
/// those two guards into one, which is unobservable: both upstream guards feed
/// the same single branch.
final class WebNavigatorApi {
  const WebNavigatorApi({this.queryPermission, this.getUserMedia});

  /// `navigator.permissions.query({ name })`. Resolving with null models a
  /// runtime that fulfils with a non-object, which upstream reads through
  /// `result?.state`.
  final Future<PermissionQueryResult?> Function(String name)? queryPermission;

  /// `navigator.mediaDevices.getUserMedia(constraints)`. Resolving with null
  /// models a runtime that fulfils with a falsy value, which upstream tolerates.
  final Future<MediaStreamLike?> Function(MediaCaptureConstraints constraints)?
  getUserMedia;
}

/// Everything [DesktopPermissions] reads from the outside world.
///
/// The getters are functions rather than values because upstream re-reads the
/// globals on every call: a host bridge or a `navigator` can appear after the
/// module is constructed.
final class DesktopPermissionEnvironment {
  const DesktopPermissionEnvironment({
    required this.isWeb,
    required this.getDesktopHost,
    required this.getNotification,
    required this.getNavigator,
    required this.now,
  });

  /// Upstream `isWeb` — the runtime has a DOM. Every read and request is gated
  /// on it, because the browser APIs below simply do not exist on native.
  final bool isWeb;

  final DesktopPermissionHost? Function() getDesktopHost;
  final NotificationApi? Function() getNotification;
  final WebNavigatorApi? Function() getNavigator;

  /// Injected clock for [DesktopPermissionSnapshot.checkedAt]; upstream calls
  /// `Date.now()` inline.
  final DateTime Function() now;
}

/// Reads and requests the desktop app's OS permissions.
///
/// Upstream is `createDesktopPermissions(env)` returning an object of three
/// closures; the methods here are those closures:
/// `shouldShowDesktopPermissionSection` → [shouldShowSection],
/// `getDesktopPermissionSnapshot` → [readSnapshot],
/// `requestDesktopPermission` → [request].
///
/// Every path resolves — nothing here ever throws — because the settings row
/// must always have something to render, and "we could not find out" is itself
/// a displayable answer ([DesktopPermissionState.unknown]).
final class DesktopPermissions {
  const DesktopPermissions({required this.environment, required this.t});

  final DesktopPermissionEnvironment environment;
  final DesktopServicesTranslator t;

  /// Whether the settings screen shows its permissions section at all.
  ///
  /// Both conditions matter: a plain browser tab is web but has no host bridge
  /// to grant anything, and a native build has no browser permission APIs.
  bool shouldShowSection() =>
      environment.isWeb && environment.getDesktopHost() != null;

  /// Reads both permissions concurrently and stamps the result.
  ///
  /// Concurrent (not sequential) to match upstream's `Promise.all`; neither
  /// read can fail, so there is no rejection ordering to preserve.
  Future<DesktopPermissionSnapshot> readSnapshot() async {
    final results = await Future.wait<DesktopPermissionStatus>(
      <Future<DesktopPermissionStatus>>[
        _notificationStatus(),
        _microphoneStatus(),
      ],
    );

    return DesktopPermissionSnapshot(
      checkedAt: environment.now(),
      notifications: results[0],
      microphone: results[1],
    );
  }

  /// Prompts the user for [kind] and reports where that left the permission.
  Future<DesktopPermissionStatus> request(DesktopPermissionKind kind) async {
    if (kind == DesktopPermissionKind.notifications) {
      return _requestNotification();
    }
    return _requestMicrophone();
  }

  // -- notifications --------------------------------------------------------

  /// Maps a raw `Notification.permission` / `requestPermission()` string.
  ///
  /// `"default"` (never asked) maps to [DesktopPermissionState.prompt]; any
  /// other spelling is reported verbatim rather than guessed at, so a runtime
  /// quirk shows up in a bug report instead of being silently normalised.
  DesktopPermissionStatus _mapNotificationPermission(String permission) {
    if (permission == 'granted') {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.granted,
        detail: t('desktop.permissions.notifications.allowed'),
      );
    }
    if (permission == 'denied') {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.denied,
        detail: t('desktop.permissions.notifications.denied'),
      );
    }
    if (permission == 'default') {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.prompt,
        detail: t('desktop.permissions.notifications.notGranted'),
      );
    }
    return DesktopPermissionStatus(
      state: DesktopPermissionState.unknown,
      detail: t('desktop.permissions.notifications.unexpectedState', {
        'state': permission,
      }),
    );
  }

  Future<DesktopPermissionStatus> _notificationStatus() async {
    if (!environment.isWeb) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.notifications.webOnly'),
      );
    }

    // The host's own answer wins when it has one: it knows about OS-level
    // settings the renderer's Notification API cannot see.
    final isSupported = environment.getDesktopHost()?.notification?.isSupported;
    if (isSupported != null) {
      try {
        final supported = await isSupported();
        return DesktopPermissionStatus(
          state: supported
              ? DesktopPermissionState.granted
              : DesktopPermissionState.unavailable,
          detail: supported
              ? t('desktop.permissions.notifications.supported')
              : t('desktop.permissions.notifications.unsupported'),
        );
      } catch (_) {
        // Fall through to the web API check, exactly as upstream does: a host
        // that errors is no worse than a host that is absent.
      }
    }

    final notification = environment.getNotification();
    final permission = notification?.permission;
    if (permission != null) {
      return _mapNotificationPermission(permission);
    }

    return DesktopPermissionStatus(
      state: DesktopPermissionState.unavailable,
      detail: t('desktop.permissions.notifications.apiUnavailable'),
    );
  }

  Future<DesktopPermissionStatus> _requestNotification() async {
    if (!environment.isWeb) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.notifications.requestsWebOnly'),
      );
    }

    // Note the host bridge is deliberately not consulted here: only the browser
    // can raise the OS prompt, and `isSupported()` is a capability probe, not a
    // request.
    final requestPermission = environment.getNotification()?.requestPermission;
    if (requestPermission != null) {
      try {
        return _mapNotificationPermission(await requestPermission());
      } catch (error) {
        return DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: t('desktop.permissions.notifications.requestFailed', {
            'message': _errorMessage(error),
          }),
        );
      }
    }

    return DesktopPermissionStatus(
      state: DesktopPermissionState.unavailable,
      detail: t('desktop.permissions.notifications.requestUnavailable'),
    );
  }

  // -- microphone -----------------------------------------------------------

  /// Whether a `Permissions.query` rejection means "this runtime cannot answer"
  /// rather than "the query failed".
  ///
  /// Electron's renderer has historically thrown either of these two messages
  /// when `query` is called detached from its owning `Permissions` instance, and
  /// the user-facing advice differs: unavailable status is normal, a genuine
  /// query failure is worth showing.
  static bool _isQueryRuntimeUnsupported(Object error) {
    final message = _errorMessage(error);
    return message.contains(
          'Can only call Permissions.query on instances of Permissions',
        ) ||
        message.contains('Illegal invocation');
  }

  Future<DesktopPermissionStatus> _microphoneStatus() async {
    if (!environment.isWeb) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.microphone.webOnly'),
      );
    }

    final webNavigator = environment.getNavigator();
    if (webNavigator == null) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.microphone.navigatorUnavailable'),
      );
    }

    final queryPermission = webNavigator.queryPermission;
    if (queryPermission != null) {
      try {
        final result = await queryPermission('microphone');
        final state = result?.state;
        if (state == 'granted') {
          return DesktopPermissionStatus(
            state: DesktopPermissionState.granted,
            detail: t('desktop.permissions.microphone.granted'),
          );
        }
        if (state == 'denied') {
          return DesktopPermissionStatus(
            state: DesktopPermissionState.denied,
            detail: t('desktop.permissions.microphone.denied'),
          );
        }
        if (state == 'prompt') {
          return DesktopPermissionStatus(
            state: DesktopPermissionState.prompt,
            detail: t('desktop.permissions.microphone.notGranted'),
          );
        }
        return DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: t('desktop.permissions.microphone.unexpectedState', {
            'state': state ?? 'unknown',
          }),
        );
      } catch (error) {
        if (_isQueryRuntimeUnsupported(error)) {
          return DesktopPermissionStatus(
            state: DesktopPermissionState.unknown,
            detail: t('desktop.permissions.microphone.statusApiUnavailable'),
          );
        }
        return DesktopPermissionStatus(
          state: DesktopPermissionState.unknown,
          detail: t('desktop.permissions.microphone.queryFailed', {
            'message': _errorMessage(error),
          }),
        );
      }
    }

    // No status API. Distinguish "we cannot even ask" (no capture at all) from
    // "we can ask, we just cannot poll" — only the latter leaves the Request
    // button useful.
    if (webNavigator.getUserMedia == null) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.microphone.captureUnavailable'),
      );
    }

    return DesktopPermissionStatus(
      state: DesktopPermissionState.unknown,
      detail: t('desktop.permissions.microphone.permissionApiUnavailable'),
    );
  }

  Future<DesktopPermissionStatus> _requestMicrophone() async {
    if (!environment.isWeb) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.microphone.requestsWebOnly'),
      );
    }

    final getUserMedia = environment.getNavigator()?.getUserMedia;
    if (getUserMedia == null) {
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unavailable,
        detail: t('desktop.permissions.microphone.captureApiUnavailable'),
      );
    }

    try {
      // Acquiring a stream *is* the prompt; it is released immediately because
      // this is a permission check, not a recording session. A live mic track
      // would keep the OS recording indicator on.
      final stream = await getUserMedia(
        const MediaCaptureConstraints(audio: true),
      );
      final tracks =
          stream?.getTracks?.call() ?? const <MediaStreamTrackLike>[];
      for (final track in tracks) {
        track.stop?.call();
      }
      // Re-read rather than assume granted: the user may have picked "allow
      // once", and the status API is the authority on what that means.
      return _microphoneStatus();
    } catch (error) {
      final errorName = _errorName(error);
      if (errorName == 'NotAllowedError' ||
          errorName == 'PermissionDeniedError') {
        return DesktopPermissionStatus(
          state: DesktopPermissionState.denied,
          detail: t('desktop.permissions.microphone.requestDenied'),
        );
      }
      if (errorName == 'NotFoundError' || errorName == 'DevicesNotFoundError') {
        return DesktopPermissionStatus(
          state: DesktopPermissionState.unavailable,
          detail: t('desktop.permissions.microphone.noDevice'),
        );
      }
      return DesktopPermissionStatus(
        state: DesktopPermissionState.unknown,
        detail: t('desktop.permissions.microphone.requestFailed', {
          'message': _errorMessage(error),
        }),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// desktop-app-updater.ts
// ---------------------------------------------------------------------------

/// Upstream `PENDING_RECHECK_MS`.
///
/// How often the settings screen re-polls while the status is
/// [DesktopAppUpdateStatus.pending] — an update was found but the host is still
/// downloading it, and nothing else will tell us when that finishes.
///
/// Deviation note: upstream exports a bare millisecond number because it feeds
/// `setInterval`; a [Duration] is the Dart analogue. Not used inside this
/// library — the timer lives in the caller, per the "never start a real Timer
/// in logic" rule.
const Duration desktopAppUpdatePendingRecheckInterval = Duration(seconds: 10);

/// What the settings screen renders from, rebuilt on every state change.
final class DesktopAppUpdaterSnapshot {
  const DesktopAppUpdaterSnapshot({
    required this.status,
    required this.availableUpdate,
    required this.errorMessage,
    required this.installMessage,
    required this.lastCheckedAt,
    required this.isChecking,
    required this.isInstalling,
  });

  final DesktopAppUpdateStatus status;

  /// The last check that found something. Cleared on `up-to-date`, on a check
  /// error, and once an install completes.
  final DesktopAppUpdateCheckPayload? availableUpdate;

  final String? errorMessage;

  /// The host's own confirmation sentence after a successful install, preferred
  /// over the generic "installed" string because it may name a required restart.
  final String? installMessage;

  /// Deviation note: upstream keeps `Date.now()` as a raw epoch number; modelled
  /// as [DateTime] to match this repo's injected-clock convention. Only set by
  /// *manual* checks and by installs — an automatic background check must not
  /// make the row claim the user just checked.
  final DateTime? lastCheckedAt;

  /// Derived: a non-silent check is in flight.
  final bool isChecking;

  /// Derived: `status == installing` *or* the sticky install flag. The two
  /// differ only in the window where a check has overwritten the status while
  /// an install is still running.
  final bool isInstalling;

  @override
  bool operator ==(Object other) =>
      other is DesktopAppUpdaterSnapshot &&
      other.status == status &&
      other.availableUpdate == availableUpdate &&
      other.errorMessage == errorMessage &&
      other.installMessage == installMessage &&
      other.lastCheckedAt == lastCheckedAt &&
      other.isChecking == isChecking &&
      other.isInstalling == isInstalling;

  @override
  int get hashCode => Object.hash(
    status,
    availableUpdate,
    errorMessage,
    installMessage,
    lastCheckedAt,
    isChecking,
    isInstalling,
  );

  @override
  String toString() =>
      'DesktopAppUpdaterSnapshot(status: $status, '
      'availableUpdate: $availableUpdate, errorMessage: $errorMessage, '
      'installMessage: $installMessage, lastCheckedAt: $lastCheckedAt, '
      'isChecking: $isChecking, isInstalling: $isInstalling)';
}

/// The two host commands the updater drives.
///
/// A port rather than a direct dependency on `DesktopUpdatesGateway` so the
/// state machine can be exercised against deferred futures and thrown errors
/// with no desktop host present.
abstract interface class DesktopAppUpdaterPort {
  Future<DesktopAppUpdateCheckPayload> checkDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
    required DesktopAppUpdateCheckIntent intent,
  });

  Future<DesktopAppUpdateInstallResult> installDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
  });
}

/// A failed install, handed to the app's error reporter.
///
/// Carries all three pieces because they go to different places: [error] to the
/// crash reporter, [message] to a toast, [logLabel] to the console.
final class DesktopAppUpdaterErrorReport {
  const DesktopAppUpdaterErrorReport({
    required this.error,
    required this.message,
    required this.logLabel,
  });

  final Object error;

  /// Already-localized, user-facing.
  final String message;

  /// Fixed English prefix for the log line; never shown to the user.
  final String logLabel;

  @override
  bool operator ==(Object other) =>
      other is DesktopAppUpdaterErrorReport &&
      other.error == error &&
      other.message == message &&
      other.logLabel == logLabel;

  @override
  int get hashCode => Object.hash(error, message, logLabel);

  @override
  String toString() =>
      'DesktopAppUpdaterErrorReport(error: $error, message: $message, '
      'logLabel: $logLabel)';
}

/// Arguments to [DesktopAppUpdater.checkForUpdates].
///
/// Upstream's inline optional object; a type here so the whole bag can be
/// absent, which upstream treats as "do nothing" (the hook binds the method
/// straight to a press handler that may pass an event instead).
final class DesktopAppUpdateCheckRequest {
  const DesktopAppUpdateCheckRequest({
    required this.releaseChannel,
    this.intent = DesktopAppUpdateCheckIntent.manual,
    this.silent = false,
  });

  final DesktopAppReleaseChannel releaseChannel;

  /// Forwarded to the host verbatim and, separately, decides whether this check
  /// refreshes the "last checked" stamp. Independent of [silent].
  final DesktopAppUpdateCheckIntent intent;

  /// A silent check never moves the status to `checking` and never surfaces a
  /// transport failure; it only ever *upgrades* what the user sees.
  final bool silent;
}

/// The observable state machine behind the desktop update settings row.
///
/// Upstream is `createDesktopAppUpdater(deps)` returning a closure object; this
/// is the same machine with the closures as methods.
///
/// Two invariants are worth naming, because both are load-bearing and both are
/// easy to break:
///
/// 1. **Only the newest request may write.** Every check takes a monotonically
///    increasing request version and, on resolution, writes state only if it is
///    still the newest. A slow check that started first must not clobber the
///    result of a fast check that started later.
/// 2. **Silent checks never make things worse.** A background poll may promote
///    `idle` to `available`, but a transport failure during one is logged and
///    dropped rather than shown — the user did not ask, so the failure is noise.
///    The single exception is a check that both failed *and* found an update:
///    that is a broken download the user needs to know about.
final class DesktopAppUpdater {
  DesktopAppUpdater({
    required this.port,
    required this.now,
    required this.t,
    this.reportInstallError,
    this.reportSilentCheckFailure,
  });

  final DesktopAppUpdaterPort port;

  /// Injected clock; upstream calls `Date.now()`.
  final DateTime Function() now;

  final DesktopServicesTranslator t;

  /// Optional sink for install failures. Absent upstream too — the hook wires
  /// it, the machine works without it.
  final void Function(DesktopAppUpdaterErrorReport report)? reportInstallError;

  /// Where the two `console.warn` calls for dropped silent failures go.
  ///
  /// Deviation note: upstream logs to the console directly. Injected here so a
  /// swallowed failure is still assertable, since it is otherwise invisible by
  /// design. Called with upstream's literal label and the failure text.
  final void Function(String logLabel, String message)?
  reportSilentCheckFailure;

  final _UpdaterState _state = _UpdaterState();
  final Set<void Function()> _listeners = <void Function()>{};
  DesktopAppUpdaterSnapshot _cachedSnapshot = _buildSnapshot(_UpdaterState());

  /// The current snapshot. Cached and only rebuilt on a state change, so a
  /// caller can compare identity to skip a re-render.
  DesktopAppUpdaterSnapshot getSnapshot() => _cachedSnapshot;

  /// Registers [listener]; the returned callback removes it and is safe to call
  /// more than once.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  static DesktopAppUpdaterSnapshot _buildSnapshot(_UpdaterState state) =>
      DesktopAppUpdaterSnapshot(
        status: state.status,
        availableUpdate: state.availableUpdate,
        errorMessage: state.errorMessage,
        installMessage: state.installMessage,
        lastCheckedAt: state.lastCheckedAt,
        isChecking: state.status == DesktopAppUpdateStatus.checking,
        isInstalling:
            state.status == DesktopAppUpdateStatus.installing ||
            state.isInstalling,
      );

  /// Applies [mutate] to the live state, rebuilds the snapshot, then notifies.
  ///
  /// Deviation note: upstream replaces the state object (`commit({ ...state,
  /// ... })`) and iterates the live listener `Set`. Dart cannot mutate a set
  /// while iterating it, so listeners are notified over a copy; a listener that
  /// unsubscribes during a notification therefore still receives that one
  /// notification, which is also what the JS `Set` iterator does.
  void _commit(void Function(_UpdaterState draft) mutate) {
    mutate(_state);
    _cachedSnapshot = _buildSnapshot(_state);
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }

  /// Whether a check result should be treated as a failure.
  ///
  /// Deviation note: upstream's guard is `if (result.errorMessage)`, i.e. JS
  /// truthiness, so an empty-string error message means "no error". Reproduced
  /// rather than a plain null check.
  static bool _hasError(DesktopAppUpdateCheckPayload result) {
    final message = result.errorMessage;
    return message != null && message.isNotEmpty;
  }

  /// Asks the host whether an update exists and folds the answer into state.
  ///
  /// Returns the raw host result when there was one — including results this
  /// call decided not to write to state — and null when the check threw or was
  /// skipped, mirroring upstream's return shape exactly.
  Future<DesktopAppUpdateCheckPayload?> checkForUpdates([
    DesktopAppUpdateCheckRequest? options,
  ]) async {
    if (options == null) return null;

    final releaseChannel = options.releaseChannel;
    final intent = options.intent;
    final silent = options.silent;

    // A background poll must not queue up behind, or interfere with, a check
    // the user is actively watching.
    if (silent && _state.status == DesktopAppUpdateStatus.checking) {
      return null;
    }

    final requestVersion = _state.requestVersion + 1;
    _commit((draft) {
      draft.requestVersion = requestVersion;
      if (!silent) {
        draft.status = DesktopAppUpdateStatus.checking;
        draft.errorMessage = null;
      }
    });

    try {
      final result = await port.checkDesktopAppUpdate(
        releaseChannel: releaseChannel,
        intent: intent,
      );
      if (requestVersion != _state.requestVersion) {
        return result;
      }

      final nextLastCheckedAt = intent == DesktopAppUpdateCheckIntent.manual
          ? now()
          : _state.lastCheckedAt;

      if (_hasError(result)) {
        // A silent failure with no update behind it is pure noise; a silent
        // failure *with* an update means a download is broken and must surface.
        if (silent && !result.hasUpdate) {
          reportSilentCheckFailure?.call(
            _silentCheckFailureLabel,
            result.errorMessage!,
          );
          return result;
        }

        _commit((draft) {
          draft.status = DesktopAppUpdateStatus.error;
          draft.availableUpdate = null;
          draft.errorMessage = result.errorMessage;
          draft.installMessage = null;
          draft.lastCheckedAt = nextLastCheckedAt;
        });
        return result;
      }

      final DesktopAppUpdateStatus nextStatus;
      final DesktopAppUpdateCheckPayload? nextAvailable;
      if (result.readyToInstall) {
        // Downloaded and verified — the install button can act immediately.
        nextStatus = DesktopAppUpdateStatus.available;
        nextAvailable = result;
      } else if (result.hasUpdate) {
        // Found but still preparing; the caller re-polls on
        // [desktopAppUpdatePendingRecheckInterval].
        nextStatus = DesktopAppUpdateStatus.pending;
        nextAvailable = result;
      } else {
        nextStatus = DesktopAppUpdateStatus.upToDate;
        nextAvailable = null;
      }

      _commit((draft) {
        draft.status = nextStatus;
        draft.availableUpdate = nextAvailable;
        draft.errorMessage = null;
        draft.installMessage = null;
        draft.lastCheckedAt = nextLastCheckedAt;
      });

      return result;
    } catch (error) {
      if (requestVersion != _state.requestVersion) {
        return null;
      }

      final message = _errorMessage(error);
      if (silent) {
        reportSilentCheckFailure?.call(_silentCheckFailureLabel, message);
      } else {
        _commit((draft) {
          draft.status = DesktopAppUpdateStatus.error;
          draft.errorMessage = message;
          draft.lastCheckedAt = intent == DesktopAppUpdateCheckIntent.manual
              ? now()
              : _state.lastCheckedAt;
        });
      }
      return null;
    }
  }

  /// Runs the host's install command.
  ///
  /// Unlike [checkForUpdates] this has no request-version guard: installing is
  /// a user-initiated, one-at-a-time action, and upstream relies on the button
  /// being disabled rather than on a race check. Returns null on failure.
  Future<DesktopAppUpdateInstallResult?> installUpdate({
    required DesktopAppReleaseChannel releaseChannel,
  }) async {
    _commit((draft) {
      draft.status = DesktopAppUpdateStatus.installing;
      draft.errorMessage = null;
      draft.isInstalling = true;
    });

    try {
      final result = await port.installDesktopAppUpdate(
        releaseChannel: releaseChannel,
      );
      final nextLastCheckedAt = now();
      _commit((draft) {
        // "Nothing to install" is not a failure — the app is simply current.
        draft.status = result.installed
            ? DesktopAppUpdateStatus.installed
            : DesktopAppUpdateStatus.upToDate;
        draft.availableUpdate = null;
        draft.installMessage = result.message;
        draft.lastCheckedAt = nextLastCheckedAt;
        draft.isInstalling = false;
      });
      return result;
    } catch (error) {
      final message = _errorMessage(error);
      reportInstallError?.call(
        DesktopAppUpdaterErrorReport(
          error: error,
          message: t('desktop.updates.installError'),
          logLabel: _installFailureLabel,
        ),
      );
      _commit((draft) {
        draft.status = DesktopAppUpdateStatus.error;
        draft.errorMessage = message;
        draft.isInstalling = false;
      });
      return null;
    }
  }

  /// Upstream's literal `console.warn` prefix for dropped silent failures.
  static const String _silentCheckFailureLabel =
      '[DesktopUpdater] Silent update check failed';

  /// Upstream's literal `logLabel` for a failed install.
  static const String _installFailureLabel =
      '[DesktopUpdater] Failed to install app update';
}

/// Mutable internal state; deliberately not exported, because every field but
/// [requestVersion] is already visible through [DesktopAppUpdaterSnapshot] and
/// the two derived flags there must stay the single source of truth.
final class _UpdaterState {
  DesktopAppUpdateStatus status = DesktopAppUpdateStatus.idle;
  DesktopAppUpdateCheckPayload? availableUpdate;
  String? errorMessage;
  String? installMessage;
  DateTime? lastCheckedAt;

  /// Sticky across a status change, so an install that is overtaken by a check
  /// still keeps the install button disabled.
  bool isInstalling = false;

  /// Monotonic sequence number; only the newest check may write state.
  int requestVersion = 0;
}

/// Renders an updater status as the sentence the settings row shows.
///
/// Upstream `formatStatusText`; renamed because a bare `formatStatusText` at
/// library top level would be far too generic for a shared Dart library.
///
/// Kept as a free function rather than a method on [DesktopAppUpdaterSnapshot]
/// because it takes two host-supplied formatters — the version renderer and the
/// timestamp renderer — that belong to the presentation layer, not the machine.
///
/// The version and last-checked fragments are separate translation keys rather
/// than concatenation, so a language can order or drop them freely.
String formatDesktopAppUpdateStatusText({
  required DesktopAppUpdateStatus status,
  required DesktopAppUpdateCheckPayload? availableUpdate,
  required String? installMessage,
  required DateTime? lastCheckedAt,
  required String Function(String? version) formatVersion,
  required String Function(DateTime timestamp) formatLastCheckedAt,
  required DesktopServicesTranslator t,
}) {
  if (status == DesktopAppUpdateStatus.checking) {
    return t('desktop.updates.status.checking');
  }

  if (status == DesktopAppUpdateStatus.installing) {
    return t('desktop.updates.status.installing');
  }

  if (status == DesktopAppUpdateStatus.upToDate) {
    if (lastCheckedAt != null) {
      return t('desktop.updates.status.upToDateWithLastChecked', {
        'time': formatLastCheckedAt(lastCheckedAt),
      });
    }
    return t('desktop.updates.status.upToDate');
  }

  // Deviation note: upstream guards on `availableUpdate?.latestVersion` — JS
  // truthiness — so a host that reports an empty version string falls through to
  // the version-less wording rather than rendering an empty name.
  final latestVersion = availableUpdate?.latestVersion;
  final hasVersion = latestVersion != null && latestVersion.isNotEmpty;

  if (status == DesktopAppUpdateStatus.pending) {
    if (hasVersion) {
      if (lastCheckedAt != null) {
        return t('desktop.updates.status.pendingWithVersionAndLastChecked', {
          'version': formatVersion(latestVersion),
          'time': formatLastCheckedAt(lastCheckedAt),
        });
      }
      return t('desktop.updates.status.pendingWithVersion', {
        'version': formatVersion(latestVersion),
      });
    }

    if (lastCheckedAt != null) {
      return t('desktop.updates.status.pendingWithLastChecked', {
        'time': formatLastCheckedAt(lastCheckedAt),
      });
    }
    return t('desktop.updates.status.pending');
  }

  if (status == DesktopAppUpdateStatus.available) {
    if (hasVersion) {
      if (lastCheckedAt != null) {
        return t('desktop.updates.status.availableWithVersionAndLastChecked', {
          'version': formatVersion(latestVersion),
          'time': formatLastCheckedAt(lastCheckedAt),
        });
      }
      return t('desktop.updates.status.availableWithVersion', {
        'version': formatVersion(latestVersion),
      });
    }

    if (lastCheckedAt != null) {
      return t('desktop.updates.status.availableWithLastChecked', {
        'time': formatLastCheckedAt(lastCheckedAt),
      });
    }
    return t('desktop.updates.status.available');
  }

  if (status == DesktopAppUpdateStatus.installed) {
    // The host's own sentence wins because it may name a required restart.
    return installMessage ?? t('desktop.updates.status.installed');
  }

  if (status == DesktopAppUpdateStatus.error) {
    // Deliberately generic: the specific reason lives in
    // [DesktopAppUpdaterSnapshot.errorMessage], shown separately.
    return t('desktop.updates.status.failed');
  }

  return t('desktop.updates.status.idle');
}
