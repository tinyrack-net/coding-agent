/// Port of Paseo 0.2.0's desktop daemon-management and app-update rules. Each
/// upstream module is a frozen, host-agnostic decision rule that a settings
/// screen or callout source asks a which-value question of:
///
/// - `desktop/daemon/daemon-management-error.ts` — which message the built-in
///   daemon settings row shows after a management operation failed, and whether
///   that failure means the daemon status on screen is now stale.
/// - `desktop/daemon/daemon-management-toggle.ts` — the ordered effects behind
///   the "manage built-in daemon" switch: confirm, persist, then (only when it
///   would actually do something) stop the daemon.
/// - `desktop/updates/resolve-update-callout.ts` — whether the sidebar shows an
///   app-update callout, and what it says.
/// - `desktop/updates/desktop-updates.ts` — the typed boundary over the desktop
///   host's update/daemon-version IPC commands, plus the version string
///   normalisation the settings screen compares and renders with.
///
/// Everything here is pure or takes its side effects as injected ports, so the
/// whole file is exercisable without an Electron/Tauri host. Nothing in the
/// upstream cluster reads a clock, so no clock port is needed.
library;

import 'package:daemon_lifecycle/daemon_lifecycle.dart'
    show DaemonHealth, DaemonStatus;

import '../composer/composer_input_labels.dart' show ComposerTranslator;
import '../core/desktop/desktop_app_update_service.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateInstallResult;
import '../state/sidebar_callout_state.dart'
    show SidebarCalloutActionVariant, SidebarCalloutVariant;

// Re-exported because they appear in this library's public signatures, so a
// caller should not need to know which existing module they were reused from.
export '../core/desktop/desktop_app_update_service.dart'
    show
        DesktopAppReleaseChannel,
        DesktopAppUpdateCheckIntent,
        DesktopAppUpdateInstallResult;
export '../state/sidebar_callout_state.dart'
    show SidebarCalloutActionVariant, SidebarCalloutVariant;

// ---------------------------------------------------------------------------
// Host port
//
// Upstream reaches straight for `invokeDesktopCommand()` (`desktop/electron/
// invoke.ts`) and the `isWeb`/`isElectronRuntime()` module constants. Both are
// process-global in the browser bundle; here they are a narrow injected port so
// the rules stay testable with no desktop shell present.
// ---------------------------------------------------------------------------

/// The slice of the Electron/Tauri host these rules actually touch.
///
/// Implementations own the "no host in this environment" failure that upstream
/// raises inside `invokeDesktopCommand`; the rules below only care about the
/// decoded reply.
abstract interface class DesktopHostBridge {
  /// Upstream `isWeb` — the JS runtime has a DOM. Always true inside the
  /// Electron renderer, false on mobile.
  bool get isWebRuntime;

  /// Upstream `isElectronRuntime()` — a desktop host bridge is installed.
  bool get isElectronRuntime;

  /// Upstream `invokeDesktopCommand<unknown>(command, args)`. The reply is
  /// deliberately untyped: every parser below re-validates it, because the host
  /// process ships independently of the app bundle.
  Future<Object?> invokeCommand(String command, [Map<String, Object?>? args]);
}

// ---------------------------------------------------------------------------
// Shared JS-semantics helpers
// ---------------------------------------------------------------------------

/// Reproduces upstream's `isRecord()` (`typeof value === "object" && value !==
/// null`) followed by a property read.
///
/// Deviation note: that JS predicate is *also* true for arrays, so an array
/// payload upstream parses as a record whose every field is `undefined` rather
/// than as a malformed response. Dart has no single type covering both, so a
/// list is mapped to an empty field bag to keep the observable outcome
/// identical. `null` and primitives are not records, exactly as upstream.
Map<Object?, Object?>? _asRecord(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is List<Object?>) return const <Object?, Object?>{};
  return null;
}

/// Upstream `toStringOrNull` from `desktop-updates.ts`: non-strings and
/// blank-after-trim strings become null, everything else is returned *trimmed*.
///
/// Note this is not the same helper as the identically named one in
/// `desktop-daemon.ts`, which returns the untrimmed original.
String? _toStringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Upstream `toStringOrEmpty`: anything that is not a string becomes `""`.
String _toStringOrEmpty(Object? value) => value is String ? value : '';

/// Upstream `toNumberOr(defaultValue, value)` — guarded by `Number.isFinite`,
/// so NaN and the infinities fall back too.
///
/// Deviation note: the field stays a [num] rather than an `int` because JS has
/// one numeric type; a host that reports `exitCode: 1.5` keeps that value
/// instead of being silently truncated.
num _toNumberOr(num defaultValue, Object? value) =>
    value is num && value.isFinite ? value : defaultValue;

/// Formats a [num] the way JS template interpolation would, so an integral
/// double decoded from JSON renders as `1` rather than Dart's `1.0`.
String _jsNumberToString(num value) =>
    value is double && value.isFinite && value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toString();

final RegExp _leadingVersionV = RegExp('^v', caseSensitive: false);

// ---------------------------------------------------------------------------
// daemon-management-error.ts
// ---------------------------------------------------------------------------

/// The built-in daemon started, but Paseo could not register the resulting
/// localhost connection.
///
/// This is the one management failure that leaves the on-screen daemon status
/// out of date, which is why it is a distinct type rather than a message.
final class DaemonConnectionRegistrationError implements Exception {
  const DaemonConnectionRegistrationError(this.message);

  final String message;

  /// Upstream sets `this.name` so the error is recognisable in logs; kept for
  /// the same reason.
  String get name => 'DaemonConnectionRegistrationError';

  @override
  String toString() => '$name: $message';
}

/// Wraps a failure raised part-way through a daemon-management toggle together
/// with the management state that was in effect *before* the toggle ran.
///
/// The pre-mutation flag is what decides the message: by the time the UI
/// catches the error the settings have usually already flipped, so asking the
/// current state would describe the wrong operation.
final class DaemonManagementOperationError implements Exception {
  const DaemonManagementOperationError(
    this.originalError,
    this.wasManagingDaemon,
  );

  /// Upstream's `originalError`, also assigned to `cause`.
  final Object originalError;

  /// Whether daemon management was on when the failed operation started.
  final bool wasManagingDaemon;

  /// Upstream sets `this.cause = error`; Dart has no built-in cause slot, so it
  /// is exposed as an alias of [originalError] like upstream does.
  Object get cause => originalError;

  /// Upstream calls `super(error.message)`, adopting the wrapped error's text.
  ///
  /// Deviation note: Dart errors have no `message` property, so the wrapped
  /// object's `toString()` stands in — except for the two error types declared
  /// here, whose `message` is read directly.
  String get message => daemonManagementErrorMessage(originalError);

  /// Upstream assigns `this.name = error.name`, so the wrapper impersonates the
  /// wrapped error rather than announcing itself.
  String get name => daemonManagementErrorName(originalError);

  @override
  String toString() => '$name: $message';
}

/// Best-effort analogue of JS `error.message` for an arbitrary thrown object.
///
/// Exposed because [DaemonManagementOperationError] adopts the wrapped error's
/// text and callers reproducing that need the same rule.
String daemonManagementErrorMessage(Object error) => switch (error) {
  DaemonConnectionRegistrationError() => error.message,
  DaemonManagementOperationError() => error.message,
  _ => error.toString(),
};

/// Best-effort analogue of JS `error.name` for an arbitrary thrown object.
String daemonManagementErrorName(Object error) => switch (error) {
  DaemonConnectionRegistrationError() => error.name,
  DaemonManagementOperationError() => error.name,
  _ => error.runtimeType.toString(),
};

/// What the settings screen shows after a daemon-management failure.
final class DaemonManagementErrorPresentation {
  const DaemonManagementErrorPresentation({
    required this.message,
    required this.refreshStatus,
  });

  /// User-facing explanation of the failure.
  final String message;

  /// Whether the daemon status on screen must be re-fetched, because the
  /// failure happened *after* the daemon itself changed state.
  final bool refreshStatus;

  @override
  bool operator ==(Object other) =>
      other is DaemonManagementErrorPresentation &&
      other.message == message &&
      other.refreshStatus == refreshStatus;

  @override
  int get hashCode => Object.hash(message, refreshStatus);

  @override
  String toString() =>
      'DaemonManagementErrorPresentation(message: $message, '
      'refreshStatus: $refreshStatus)';
}

/// Chooses the message and the status-refresh decision for a failed
/// daemon-management operation.
///
/// A [DaemonManagementOperationError] is unwrapped exactly one level — its
/// payload decides the branch and its captured flag overrides
/// [isManagingDaemon], because the caller's live flag has usually already been
/// flipped by the time the error surfaces.
///
/// [t] is the translator, injected because this repo has no localization layer
/// yet (`i18n/*` is tracked separately); upstream reaches for the `i18n`
/// singleton directly at the same three keys.
DaemonManagementErrorPresentation getDaemonManagementErrorPresentation({
  required Object error,
  required bool isManagingDaemon,
  required ComposerTranslator t,
}) {
  final presentationError = error is DaemonManagementOperationError
      ? error.originalError
      : error;
  final wasManagingDaemon = error is DaemonManagementOperationError
      ? error.wasManagingDaemon
      : isManagingDaemon;

  if (presentationError is DaemonConnectionRegistrationError) {
    return DaemonManagementErrorPresentation(
      message: t('desktop.daemon.management.registrationFailed'),
      refreshStatus: true,
    );
  }
  if (wasManagingDaemon) {
    return DaemonManagementErrorPresentation(
      message: t('desktop.daemon.management.pausedStopFailed'),
      refreshStatus: false,
    );
  }
  return DaemonManagementErrorPresentation(
    message: t('desktop.daemon.management.updateFailed'),
    refreshStatus: false,
  );
}

// ---------------------------------------------------------------------------
// daemon-management-toggle.ts
// ---------------------------------------------------------------------------

/// The four side effects the "manage built-in daemon" switch may perform.
///
/// Upstream's `DaemonManagementToggleDeps`; taken as a value object so the
/// ordering rule below can be tested without a settings store or a live daemon.
final class DaemonManagementTogglePorts {
  const DaemonManagementTogglePorts({
    required this.confirm,
    required this.persistSettings,
    required this.startDaemon,
    required this.stopDaemon,
  });

  /// Asks the user to confirm pausing management (which stops the daemon).
  final Future<bool> Function() confirm;

  /// Writes the new `manageBuiltInDaemon` preference.
  final Future<void> Function({required bool manageBuiltInDaemon})
  persistSettings;

  final Future<DaemonStatus> Function() startDaemon;
  final Future<DaemonStatus> Function() stopDaemon;
}

/// Outcome of [executeDaemonManagementToggle].
///
/// Upstream's discriminated union `{ kind: "cancelled" | "enabled" |
/// "disabled" }` becomes a sealed hierarchy so the "disabled without a stop"
/// case keeps its distinct null status.
sealed class DaemonManagementToggleResult {
  const DaemonManagementToggleResult();
}

/// The user declined the confirmation, so nothing was persisted or stopped.
final class DaemonManagementToggleCancelled
    extends DaemonManagementToggleResult {
  const DaemonManagementToggleCancelled();

  @override
  bool operator ==(Object other) => other is DaemonManagementToggleCancelled;

  @override
  int get hashCode => (DaemonManagementToggleCancelled).hashCode;

  @override
  String toString() => 'DaemonManagementToggleCancelled()';
}

/// Management was turned on and the daemon was started.
final class DaemonManagementToggleEnabled extends DaemonManagementToggleResult {
  const DaemonManagementToggleEnabled(this.newStatus);

  final DaemonStatus newStatus;

  @override
  bool operator ==(Object other) =>
      other is DaemonManagementToggleEnabled &&
      identical(other.newStatus, newStatus);

  @override
  int get hashCode => Object.hash(DaemonManagementToggleEnabled, newStatus);

  @override
  String toString() => 'DaemonManagementToggleEnabled($newStatus)';
}

/// Management was turned off.
///
/// [newStatus] is null when no stop was needed — the daemon was not running, or
/// was not ours to stop.
final class DaemonManagementToggleDisabled
    extends DaemonManagementToggleResult {
  const DaemonManagementToggleDisabled(this.newStatus);

  final DaemonStatus? newStatus;

  @override
  bool operator ==(Object other) =>
      other is DaemonManagementToggleDisabled &&
      identical(other.newStatus, newStatus);

  @override
  int get hashCode => Object.hash(DaemonManagementToggleDisabled, newStatus);

  @override
  String toString() => 'DaemonManagementToggleDisabled($newStatus)';
}

/// Runs the "manage built-in daemon" switch.
///
/// Enabling never asks for confirmation: it persists first, then starts.
/// Disabling asks first and bails out untouched on a decline. When it does
/// proceed, the setting is persisted *before* the stop is attempted, so a
/// failing stop still leaves persisted state describing what was actually
/// applied — the caller then surfaces it via
/// [getDaemonManagementErrorPresentation] with `wasManagingDaemon: true`.
///
/// The stop is skipped unless the daemon is both running and desktop-managed;
/// a daemon the user started by hand is not ours to kill.
///
/// [daemonStatus] reuses this repo's [DaemonStatus]. Deviation note: upstream
/// takes `Pick<DesktopDaemonStatus, "status" | "desktopManaged">` where
/// `status` is one of `starting | running | stopped | errored`, whereas
/// [DaemonHealth] only distinguishes running from stopped. The rule compares
/// against `running` only, so all three non-running upstream states already
/// collapse to the same branch and the observable behaviour is unchanged.
/// `desktopManaged` lives on the daemon's `ServerHello`, and is absent (thus
/// false) whenever there is no live handshake.
Future<DaemonManagementToggleResult> executeDaemonManagementToggle({
  required bool currentlyManaging,
  required DaemonStatus? daemonStatus,
  required DaemonManagementTogglePorts ports,
}) async {
  if (!currentlyManaging) {
    await ports.persistSettings(manageBuiltInDaemon: true);
    final newStatus = await ports.startDaemon();
    return DaemonManagementToggleEnabled(newStatus);
  }

  final confirmed = await ports.confirm();
  if (!confirmed) {
    return const DaemonManagementToggleCancelled();
  }

  // Settings must persist before the daemon is stopped so the persisted
  // state reflects what was actually applied if the stop fails.
  await ports.persistSettings(manageBuiltInDaemon: false);

  final isDesktopManagedAndRunning =
      daemonStatus != null &&
      daemonStatus.isRunning &&
      (daemonStatus.hello?.desktopManaged ?? false);
  if (isDesktopManagedAndRunning) {
    final newStatus = await ports.stopDaemon();
    return DaemonManagementToggleDisabled(newStatus);
  }

  return const DaemonManagementToggleDisabled(null);
}

// ---------------------------------------------------------------------------
// resolve-update-callout.ts
// ---------------------------------------------------------------------------

/// Upstream `DesktopAppUpdateStatus` from `desktop/updates/
/// desktop-app-updater.ts`.
///
/// Declared locally because that updater state machine is not ported yet; this
/// repo's `DesktopAppUpdateService` models the *transport* side of updates, not
/// the UI-facing status. Each value carries its upstream wire spelling because
/// the status is interpolated verbatim into the callout's dismissal key.
enum DesktopAppUpdateStatus {
  idle('idle'),
  checking('checking'),
  pending('pending'),
  upToDate('up-to-date'),
  available('available'),
  installing('installing'),
  installed('installed'),
  error('error');

  const DesktopAppUpdateStatus(this.wireName);

  /// The literal upstream string union member, used in the dismissal key.
  final String wireName;
}

/// The body of the update callout — one of three mutually exclusive shapes.
sealed class UpdateCalloutBody {
  const UpdateCalloutBody();
}

/// An update is ready to install.
///
/// [versionLabel] is null when the host never reported a version; the callout
/// then says a new version is ready without naming it.
final class UpdateCalloutAvailableBody extends UpdateCalloutBody {
  const UpdateCalloutAvailableBody(this.versionLabel);

  final String? versionLabel;

  @override
  bool operator ==(Object other) =>
      other is UpdateCalloutAvailableBody && other.versionLabel == versionLabel;

  @override
  int get hashCode => Object.hash(UpdateCalloutAvailableBody, versionLabel);

  @override
  String toString() => 'UpdateCalloutAvailableBody($versionLabel)';
}

/// The install is in flight.
final class UpdateCalloutInstallingBody extends UpdateCalloutBody {
  const UpdateCalloutInstallingBody();

  @override
  bool operator ==(Object other) => other is UpdateCalloutInstallingBody;

  @override
  int get hashCode => (UpdateCalloutInstallingBody).hashCode;

  @override
  String toString() => 'UpdateCalloutInstallingBody()';
}

/// The update failed; [message] is the host's reason or a generic fallback.
final class UpdateCalloutErrorBody extends UpdateCalloutBody {
  const UpdateCalloutErrorBody(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is UpdateCalloutErrorBody && other.message == message;

  @override
  int get hashCode => Object.hash(UpdateCalloutErrorBody, message);

  @override
  String toString() => 'UpdateCalloutErrorBody($message)';
}

/// What a callout button does, kept separate from its label so the presenter
/// wires handlers without matching on translated text.
enum UpdateCalloutActionRole { changelog, install, retry }

/// One button in the update callout.
final class UpdateCalloutActionDescriptor {
  const UpdateCalloutActionDescriptor({
    required this.role,
    required this.label,
    this.variant,
    this.disabled,
  });

  final UpdateCalloutActionRole role;
  final String label;

  /// Reuses [SidebarCalloutActionVariant], the variant enum the sidebar callout
  /// renderer already consumes.
  ///
  /// Deviation note: upstream's `variant?` is optional and genuinely absent on
  /// the changelog action, so null is meaningful here and is not defaulted to
  /// `secondary`.
  final SidebarCalloutActionVariant? variant;

  /// Upstream's optional `disabled?`. Absent (null) on the changelog action,
  /// explicitly `false` on an enabled install action — the distinction is
  /// preserved rather than collapsed to a non-nullable bool.
  final bool? disabled;

  @override
  bool operator ==(Object other) =>
      other is UpdateCalloutActionDescriptor &&
      other.role == role &&
      other.label == label &&
      other.variant == variant &&
      other.disabled == disabled;

  @override
  int get hashCode => Object.hash(role, label, variant, disabled);

  @override
  String toString() =>
      'UpdateCalloutActionDescriptor(role: $role, label: $label, '
      'variant: $variant, disabled: $disabled)';
}

/// A fully resolved desktop-update callout, ready to hand to the sidebar
/// callout host.
final class UpdateCalloutDescriptor {
  const UpdateCalloutDescriptor({
    required this.dismissalKey,
    required this.title,
    required this.body,
    required this.showGiftIcon,
    required this.variant,
    required this.actions,
    this.id = calloutId,
    this.priority = calloutPriority,
    this.testId = calloutTestId,
  });

  /// Upstream's literal `id: "desktop-update"` — stable so re-resolving
  /// replaces the callout in place instead of stacking duplicates.
  static const String calloutId = 'desktop-update';

  /// Upstream's literal `testID: "update-callout"`.
  static const String calloutTestId = 'update-callout';

  /// Upstream's literal `priority: 200`, above the suggestion-grade callouts.
  static const int calloutPriority = 200;

  final String id;

  /// Encodes status *and* version, so dismissing "0.1.5 available" does not
  /// also suppress the callout for the next release.
  final String dismissalKey;

  final int priority;
  final String title;
  final UpdateCalloutBody body;

  /// Only the plain "an update is waiting" state gets the celebratory icon.
  final bool showGiftIcon;

  /// Reuses [SidebarCalloutVariant]; upstream's union is `"default" | "error"`,
  /// a subset of this repo's enum (which also has `success`).
  final SidebarCalloutVariant variant;

  final List<UpdateCalloutActionDescriptor> actions;
  final String testId;

  @override
  String toString() =>
      'UpdateCalloutDescriptor(id: $id, dismissalKey: $dismissalKey, '
      'priority: $priority, title: $title, body: $body, '
      'showGiftIcon: $showGiftIcon, variant: $variant, actions: $actions, '
      'testId: $testId)';
}

/// Everything [resolveUpdateCalloutDescriptor] needs from the updater hook.
final class ResolveUpdateCalloutInput {
  const ResolveUpdateCalloutInput({
    required this.isDesktopApp,
    required this.status,
    required this.isInstalling,
    required this.availableUpdate,
    required this.errorMessage,
  });

  /// False on web and mobile, where there is nothing to self-update.
  final bool isDesktopApp;

  final DesktopAppUpdateStatus status;

  /// Tracked separately from [status] because an install can be in flight while
  /// the status still reads `available`.
  final bool isInstalling;

  /// The last successful check, if any. Only `latestVersion` is read.
  final DesktopAppUpdateCheckPayload? availableUpdate;

  final String? errorMessage;
}

/// Renders a raw version for display: `1.2.3` and `v1.2.3` both become
/// `v1.2.3`; a missing or blank version yields null so the caller omits the
/// label entirely.
///
/// Deviation note: upstream's guard is JS falsiness, so the empty string is
/// treated as "no version" — reproduced here rather than only null-checking.
String? formatUpdateCalloutVersionLabel(String? latestVersion) {
  if (latestVersion == null || latestVersion.isEmpty) return null;
  return 'v${latestVersion.replaceFirst(_leadingVersionV, '')}';
}

/// Decides whether the sidebar shows an app-update callout, and builds it.
///
/// Returns null off the desktop app, and for every status that is not
/// `available`, `installing` or `error` — idle/checking/up-to-date/pending are
/// all "nothing to tell the user yet".
///
/// Note the two flags are not redundant: [ResolveUpdateCalloutInput.status]
/// picks the dismissal key while [ResolveUpdateCalloutInput.isInstalling] picks
/// the title and body, so an install started from an `available` status shows
/// installing chrome under an `available` key. Where they disagree, upstream's
/// branch order wins: `isInstalling` decides the title and body, but the
/// *actions* still switch on `error`.
///
/// [t] is the translator, injected because this repo has no localization layer
/// yet (`i18n/*` is tracked separately); upstream reaches for the `i18n`
/// singleton directly at the same six keys.
UpdateCalloutDescriptor? resolveUpdateCalloutDescriptor(
  ResolveUpdateCalloutInput input, {
  required ComposerTranslator t,
}) {
  if (!input.isDesktopApp) return null;
  if (input.status != DesktopAppUpdateStatus.available &&
      input.status != DesktopAppUpdateStatus.installing &&
      input.status != DesktopAppUpdateStatus.error) {
    return null;
  }

  final isError = input.status == DesktopAppUpdateStatus.error;
  final isInstalling = input.isInstalling;
  final isAvailable = !isInstalling && !isError;

  final latestVersion = input.availableUpdate?.latestVersion;
  final dismissalKey =
      'desktop-update:${input.status.wireName}:${latestVersion ?? 'unknown'}';

  final String title;
  final UpdateCalloutBody body;
  if (isInstalling) {
    title = t('desktop.updates.callout.installingTitle');
    body = const UpdateCalloutInstallingBody();
  } else if (isError) {
    title = t('desktop.updates.callout.failedTitle');
    body = UpdateCalloutErrorBody(
      input.errorMessage ?? t('desktop.updates.callout.genericError'),
    );
  } else {
    title = t('desktop.updates.callout.availableTitle');
    body = UpdateCalloutAvailableBody(
      formatUpdateCalloutVersionLabel(latestVersion),
    );
  }

  final actions = <UpdateCalloutActionDescriptor>[
    UpdateCalloutActionDescriptor(
      role: UpdateCalloutActionRole.changelog,
      label: t('desktop.updates.callout.whatsNew'),
    ),
    if (isError)
      UpdateCalloutActionDescriptor(
        role: UpdateCalloutActionRole.retry,
        label: t('common.actions.retry'),
        variant: SidebarCalloutActionVariant.primary,
      )
    else
      UpdateCalloutActionDescriptor(
        role: UpdateCalloutActionRole.install,
        label: isInstalling
            ? t('desktop.updates.callout.installingAction')
            : t('desktop.updates.callout.installAndRestart'),
        variant: SidebarCalloutActionVariant.primary,
        disabled: isInstalling,
      ),
  ];

  return UpdateCalloutDescriptor(
    dismissalKey: dismissalKey,
    title: title,
    body: body,
    showGiftIcon: isAvailable,
    variant: isError
        ? SidebarCalloutVariant.error
        : SidebarCalloutVariant.defaultVariant,
    actions: List.unmodifiable(actions),
  );
}

// ---------------------------------------------------------------------------
// desktop-updates.ts
// ---------------------------------------------------------------------------

const String _releaseDownloadBaseUrl =
    'https://github.com/getpaseo/paseo/releases/download';

/// Upstream's "no version available" display placeholder (an em dash).
const String desktopVersionUnavailableLabel = '—';

/// The host's reply to `check_app_update`.
///
/// Deviation note: this repo already has a `DesktopAppUpdateCheckResult` in
/// `core/desktop/desktop_app_update_service.dart`, but that one models an
/// in-process updater where `currentVersion`/`latestVersion` are always known
/// and therefore non-nullable. This payload is a defensive parse of an IPC
/// reply from a separately shipped host process, where *every* field can be
/// missing — collapsing null to `''` would be an observable behaviour change,
/// so the two types are kept distinct.
final class DesktopAppUpdateCheckPayload {
  const DesktopAppUpdateCheckPayload({
    required this.hasUpdate,
    required this.readyToInstall,
    required this.currentVersion,
    required this.latestVersion,
    required this.body,
    required this.date,
    required this.errorMessage,
  });

  final bool hasUpdate;
  final bool readyToInstall;
  final String? currentVersion;
  final String? latestVersion;

  /// Release notes, when the host supplies them.
  final String? body;

  /// Release date as the host formatted it; never parsed here.
  final String? date;

  final String? errorMessage;

  @override
  bool operator ==(Object other) =>
      other is DesktopAppUpdateCheckPayload &&
      other.hasUpdate == hasUpdate &&
      other.readyToInstall == readyToInstall &&
      other.currentVersion == currentVersion &&
      other.latestVersion == latestVersion &&
      other.body == body &&
      other.date == date &&
      other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
    hasUpdate,
    readyToInstall,
    currentVersion,
    latestVersion,
    body,
    date,
    errorMessage,
  );

  @override
  String toString() =>
      'DesktopAppUpdateCheckPayload(hasUpdate: $hasUpdate, '
      'readyToInstall: $readyToInstall, currentVersion: $currentVersion, '
      'latestVersion: $latestVersion, body: $body, date: $date, '
      'errorMessage: $errorMessage)';
}

/// Facts about the running desktop shell that the settings screen displays.
final class DesktopRuntimeInfo {
  const DesktopRuntimeInfo({
    required this.appVersion,
    required this.runningUnderARM64Translation,
  });

  final String? appVersion;

  /// True when an Intel build is running under Rosetta on Apple Silicon, which
  /// is what triggers the "download the native build" callout.
  final bool runningUnderARM64Translation;

  @override
  bool operator ==(Object other) =>
      other is DesktopRuntimeInfo &&
      other.appVersion == appVersion &&
      other.runningUnderARM64Translation == runningUnderARM64Translation;

  @override
  int get hashCode => Object.hash(appVersion, runningUnderARM64Translation);

  @override
  String toString() =>
      'DesktopRuntimeInfo(appVersion: $appVersion, '
      'runningUnderARM64Translation: $runningUnderARM64Translation)';
}

/// Raw result of shelling out to the local daemon's self-update command.
///
/// Kept as raw streams rather than a parsed outcome so the settings screen can
/// offer the whole transcript for copy-paste when the update fails.
final class LocalDaemonUpdateResult {
  const LocalDaemonUpdateResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// A [num] rather than an `int` — see `_toNumberOr`. Defaults to 1 (failure)
  /// when the host omits it, so a malformed reply is never read as success.
  final num exitCode;

  final String stdout;
  final String stderr;

  @override
  bool operator ==(Object other) =>
      other is LocalDaemonUpdateResult &&
      other.exitCode == exitCode &&
      other.stdout == stdout &&
      other.stderr == stderr;

  @override
  int get hashCode => Object.hash(exitCode, stdout, stderr);

  @override
  String toString() =>
      'LocalDaemonUpdateResult(exitCode: $exitCode, stdout: $stdout, '
      'stderr: $stderr)';
}

/// The locally installed daemon's version, or why it could not be determined.
final class LocalDaemonVersionResult {
  const LocalDaemonVersionResult({required this.version, required this.error});

  final String? version;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is LocalDaemonVersionResult &&
      other.version == version &&
      other.error == error;

  @override
  int get hashCode => Object.hash(version, error);

  @override
  String toString() =>
      'LocalDaemonVersionResult(version: $version, error: $error)';
}

/// Parses the reply to `get_local_daemon_version`.
///
/// Unlike the other parsers this one never throws: a missing local daemon is an
/// expected, displayable state rather than a bug, so a malformed reply becomes
/// an error *string*.
LocalDaemonVersionResult parseLocalDaemonVersionResult(Object? raw) {
  final record = _asRecord(raw);
  if (record == null) {
    return const LocalDaemonVersionResult(
      version: null,
      error: 'Unexpected response from version check.',
    );
  }

  return LocalDaemonVersionResult(
    version: _toStringOrNull(record['version']),
    error: _toStringOrNull(record['error']),
  );
}

/// Parses the reply to `desktop_get_runtime_info`.
///
/// Also non-throwing: the settings screen must still render when the host is
/// older than the app and does not know this command.
DesktopRuntimeInfo parseDesktopRuntimeInfo(Object? raw) {
  final record = _asRecord(raw);
  if (record == null) {
    return const DesktopRuntimeInfo(
      appVersion: null,
      runningUnderARM64Translation: false,
    );
  }

  return DesktopRuntimeInfo(
    appVersion: _toStringOrNull(record['appVersion']),
    // Strict `=== true`: anything else, including a truthy string, is false.
    runningUnderARM64Translation:
        record['runningUnderARM64Translation'] == true,
  );
}

/// Parses the reply to `check_app_update`. Throws when the reply is not an
/// object at all, because there is no sensible "no update" reading of garbage.
DesktopAppUpdateCheckPayload parseDesktopAppUpdateCheckResult(Object? raw) {
  final record = _asRecord(raw);
  if (record == null) {
    throw Exception('Unexpected response while checking desktop updates.');
  }

  return DesktopAppUpdateCheckPayload(
    hasUpdate: record['hasUpdate'] == true,
    readyToInstall: record['readyToInstall'] == true,
    currentVersion: _toStringOrNull(record['currentVersion']),
    latestVersion: _toStringOrNull(record['latestVersion']),
    body: _toStringOrNull(record['body']),
    date: _toStringOrNull(record['date']),
    errorMessage: _toStringOrNull(record['errorMessage']),
  );
}

/// Parses the reply to `install_app_update`.
///
/// Reuses this repo's [DesktopAppUpdateInstallResult], whose field shapes
/// already match upstream exactly. [t] supplies the fallback confirmation text
/// for a host that installed successfully but said nothing.
DesktopAppUpdateInstallResult parseDesktopAppUpdateInstallResult(
  Object? raw, {
  required ComposerTranslator t,
}) {
  final record = _asRecord(raw);
  if (record == null) {
    throw Exception('Unexpected response while installing desktop update.');
  }

  return DesktopAppUpdateInstallResult(
    installed: record['installed'] == true,
    version: _toStringOrNull(record['version']),
    message:
        _toStringOrNull(record['message']) ??
        t('desktop.updates.status.installed'),
  );
}

/// Parses the reply to `run_local_daemon_update`.
LocalDaemonUpdateResult parseLocalDaemonUpdateResult(Object? raw) {
  final record = _asRecord(raw);
  if (record == null) {
    throw Exception('Unexpected response while updating local daemon.');
  }

  return LocalDaemonUpdateResult(
    exitCode: _toNumberOr(1, record['exitCode']),
    stdout: _toStringOrEmpty(record['stdout']),
    stderr: _toStringOrEmpty(record['stderr']),
  );
}

/// Strips a leading `v` (either case) and surrounding whitespace so two version
/// strings from different sources can be compared as equals.
///
/// Blank input yields null rather than an empty string, which is what makes
/// [isVersionMismatch] fail open on unknown versions.
String? normalizeVersionForComparison(String? version) {
  final value = version?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }

  return value.replaceFirst(_leadingVersionV, '');
}

/// Whether the app and the daemon are on different versions.
///
/// Deliberately false when either side is unknown: an absent version is not
/// evidence of a mismatch, and warning about it would be noise.
bool isVersionMismatch(String? appVersion, String? daemonVersion) {
  final app = normalizeVersionForComparison(appVersion);
  final daemon = normalizeVersionForComparison(daemonVersion);

  if (app == null || daemon == null) {
    return false;
  }

  return app != daemon;
}

/// Renders a version for display, adding the `v` prefix if it is missing and
/// falling back to an em dash when there is nothing to show.
///
/// Deviation note: the prefix check is case-*sensitive* upstream while
/// [normalizeVersionForComparison] is not, so `"V1.0"` renders as `"vV1.0"`.
/// Reproduced rather than fixed, since this is frozen behaviour.
String formatVersionWithPrefix(String? version) {
  final value = version?.trim();
  if (value == null || value.isEmpty) {
    return desktopVersionUnavailableLabel;
  }

  return value.startsWith('v') ? value : 'v$value';
}

/// Direct download URL for the Apple Silicon build, used by the Rosetta callout
/// where in-app update cannot switch architectures.
///
/// Null when the version is unknown, because a guessed URL would 404.
String? buildMacAppleSiliconDownloadUrl(String? version) {
  final normalizedVersion = normalizeVersionForComparison(version);
  if (normalizedVersion == null) {
    return null;
  }

  return '$_releaseDownloadBaseUrl/v$normalizedVersion/'
      'Paseo-$normalizedVersion-arm64.dmg';
}

/// Formats a failed daemon update as a single copy-pasteable block.
///
/// Empty streams are spelled `(empty)` so a bug report cannot be misread as
/// truncated output.
String buildDaemonUpdateDiagnostics(LocalDaemonUpdateResult result) {
  final stdout = result.stdout.isNotEmpty ? result.stdout : '(empty)';
  final stderr = result.stderr.isNotEmpty ? result.stderr : '(empty)';

  return [
    'Exit code: ${_jsNumberToString(result.exitCode)}',
    '',
    'STDOUT:',
    stdout,
    '',
    'STDERR:',
    stderr,
  ].join('\n');
}

/// Typed façade over the desktop host's update commands.
///
/// Upstream these are free functions closing over the module-global
/// `invokeDesktopCommand`; here they hang off an injected [DesktopHostBridge]
/// so the command names, argument shapes and reply parsing can all be asserted
/// against a fake.
final class DesktopUpdatesGateway {
  const DesktopUpdatesGateway(this.host);

  final DesktopHostBridge host;

  /// Whether the settings screen shows its desktop-update section at all.
  ///
  /// Both conditions matter: the Electron check alone would be true in a host
  /// process with no DOM, and the web check alone would be true in a plain
  /// browser tab that has no updater to talk to.
  bool shouldShowDesktopUpdateSection() =>
      host.isWebRuntime && host.isElectronRuntime;

  Future<LocalDaemonVersionResult> getLocalDaemonVersion() async =>
      parseLocalDaemonVersionResult(
        await host.invokeCommand('get_local_daemon_version'),
      );

  Future<DesktopRuntimeInfo> getDesktopRuntimeInfo() async =>
      parseDesktopRuntimeInfo(
        await host.invokeCommand('desktop_get_runtime_info'),
      );

  /// [intent] reaches the host so it can distinguish a background poll from a
  /// user pressing "check now" (rate limiting, telemetry).
  Future<DesktopAppUpdateCheckPayload> checkDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
    required DesktopAppUpdateCheckIntent intent,
  }) async => parseDesktopAppUpdateCheckResult(
    await host.invokeCommand('check_app_update', {
      'releaseChannel': releaseChannel.name,
      'intent': intent.name,
    }),
  );

  Future<DesktopAppUpdateInstallResult> installDesktopAppUpdate({
    required DesktopAppReleaseChannel releaseChannel,
    required ComposerTranslator t,
  }) async => parseDesktopAppUpdateInstallResult(
    await host.invokeCommand('install_app_update', {
      'releaseChannel': releaseChannel.name,
    }),
    t: t,
  );

  Future<LocalDaemonUpdateResult> runLocalDaemonUpdate() async =>
      parseLocalDaemonUpdateResult(
        await host.invokeCommand('run_local_daemon_update'),
      );
}
