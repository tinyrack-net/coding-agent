/// Port of Paseo 0.2.0's cold-start cluster — the two frozen modules that
/// decide what happens between "the app process exists" and "a host route is
/// on screen":
///
/// - `runtime/daemon-start-service.ts` — the managed (desktop-owned) daemon's
///   startup state machine. It evaluates whether the app should manage a daemon
///   at all, launches it, validates what the launch reported, registers the
///   resulting connection, and publishes a single `isRunning`/`lastError` pair
///   that startup chrome subscribes to.
/// - `navigation/host-runtime-bootstrap.ts` — the startup navigation policy. It
///   kicks the host registry and the daemon decision off as one operation, then
///   answers, frame by frame, whether the app may navigate yet, whether the
///   give-up timer should run, and which route the `/` and `/h/:serverId`
///   boundaries resolve to.
///
/// The two are ported together because the navigation policy is a pure function
/// of the daemon service's published state: `daemonStartIsRunning` and
/// `daemonStartError` are exactly [DaemonStartService.isRunning] and
/// [DaemonStartService.lastError]. Splitting them would put the contract between
/// them in neither file.
///
/// Everything here is pure or takes its side effects as injected ports — there
/// is no clock, no timer and no transport in this library, so the whole cluster
/// is exercisable with no daemon, no desktop shell and no widget tree.
///
/// ## Reuse
///
/// This library deliberately declares no type that the app already has:
///
/// - `DesktopDaemonStatus` / `DesktopDaemonState` come from
///   `core/paseo_platform_rules.dart`.
/// - `connectionFromListen` — the listen-address validator — comes from
///   `package:agent_protocol`.
/// - `ActiveWorkspaceSelection` (upstream `stores/last-workspace-selection.ts`)
///   is the app's [HostWorkspaceRoute].
/// - `resolveWorkspaceSelectionStatus`, [WorkspaceSelectionStatus] and
///   `resolveHostIndexRoute` were already ported into
///   `core/host_routes.dart`; they are re-exported here rather
///   than duplicated, so this library still presents the full upstream module
///   surface. (Seam note: those three are pure rules that belong beside these
///   ones rather than inside a screen file. Moving them is a separate change.)
/// - The `/h/:serverId` known-host decision reuses `resolveKnownHostRoute` from
///   `core/host_routes.dart`.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart' show connectionFromListen;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/host_routes.dart'
    show
        HostWorkspaceRoute,
        KnownHostRouteResolution,
        WorkspaceSelectionStatus,
        buildHostRootRoute,
        buildOpenProjectRoute,
        resolveKnownHostRoute;
import '../core/paseo_platform_rules.dart'
    show DesktopDaemonStatus, describeDiagnosticError;

// Re-exported because they appear in this library's public signatures (or are
// part of the upstream module surface), so callers should not need to know
// which existing module each was reused from.
export '../core/host_routes.dart'
    show
        HostWorkspaceRoute,
        WorkspaceSelectionStatus,
        resolveHostIndexRoute,
        resolveWorkspaceSelectionStatus;
export '../core/paseo_platform_rules.dart'
    show DesktopDaemonState, DesktopDaemonStatus;

/// JS truthiness for a nullable string.
///
/// Upstream guards read `if (input.anyOnlineHostServerId)`, which is false for
/// both `null` and `""`. Dart's `!= null` would accept the empty string and
/// change the decision, so every upstream truthiness test goes through here.
bool _isTruthy(String? value) => value != null && value.isNotEmpty;

// ---------------------------------------------------------------------------
// daemon-start-service.ts
// ---------------------------------------------------------------------------

/// The outcome of one managed-daemon start attempt.
///
/// Upstream's `{ ok: true } | { ok: false; error: string }`. Modelled as a
/// sealed pair rather than a nullable error so "succeeded" and "failed with an
/// empty message" stay distinguishable, and so exhaustive `switch` is available
/// at call sites.
sealed class DaemonStartResult {
  const DaemonStartResult();

  /// Whether the attempt succeeded. Mirrors upstream's `ok` discriminant for
  /// call sites that only need the boolean.
  bool get ok;
}

/// The start attempt completed. Also returned when management is disabled and
/// nothing was started at all — upstream treats "correctly did nothing" as
/// success so startup is not blocked on an opted-out daemon.
final class DaemonStartOk extends DaemonStartResult {
  /// Creates the success result.
  const DaemonStartOk();

  @override
  bool get ok => true;

  @override
  bool operator ==(Object other) => other is DaemonStartOk;

  @override
  int get hashCode => (DaemonStartOk).hashCode;

  @override
  String toString() => 'DaemonStartOk()';
}

/// The start attempt failed; [error] is the message the startup surface shows.
final class DaemonStartFailure extends DaemonStartResult {
  /// Creates the failure result carrying a user-facing [error].
  const DaemonStartFailure(this.error);

  /// The failure message, already resolved to plain text.
  final String error;

  @override
  bool get ok => false;

  @override
  bool operator ==(Object other) =>
      other is DaemonStartFailure && other.error == error;

  @override
  int get hashCode => Object.hash(DaemonStartFailure, error);

  @override
  String toString() => 'DaemonStartFailure($error)';
}

/// Whether the app should manage a daemon on this launch.
///
/// Upstream's `boolean | (() => boolean | Promise<boolean>)`. The two arms are
/// kept distinct because the difference is observable: a constant is read
/// without suspending, whereas a callback is awaited, and everything it throws
/// is reported as a *settings* failure rather than a daemon failure.
sealed class DaemonStartCondition {
  const DaemonStartCondition();
}

/// A decision that is already known — upstream's `boolean` arm.
final class FixedDaemonStartCondition extends DaemonStartCondition {
  /// Creates a condition that always answers [value].
  const FixedDaemonStartCondition(this.value);

  /// The answer.
  final bool value;
}

/// A decision that must be computed, typically by reading desktop settings —
/// upstream's `() => boolean | Promise<boolean>` arm.
///
/// [evaluate] returns `FutureOr<bool>` so a synchronous settings read stays
/// synchronous, matching upstream's untyped callback.
final class ComputedDaemonStartCondition extends DaemonStartCondition {
  /// Creates a condition evaluated by calling [evaluate].
  const ComputedDaemonStartCondition(this.evaluate);

  /// Computes the answer. Anything it throws becomes a settings failure.
  final FutureOr<bool> Function() evaluate;
}

/// The host-runtime slice [DaemonStartService] writes to.
///
/// Upstream is `Pick<HostRuntimeStore, "upsertConnectionFromListen">` — a
/// one-method structural slice of a much larger store. Declared as an interface
/// so the app's `HostRegistryNotifier` can adopt it without this library
/// depending on Riverpod, and so tests need no registry at all.
abstract interface class DaemonConnectionStore {
  /// Registers (or updates) the host reachable at [listenAddress].
  ///
  /// The raw listen address is handed over rather than a parsed connection
  /// because upstream's store owns that parse; [connectionFromListen] is used
  /// here only to reject an address the store could not have used.
  Future<void> upsertConnectionFromListen({
    required String listenAddress,
    required String serverId,
    required String? hostname,
  });
}

/// Validates a desktop daemon's self-report and registers it as a host.
///
/// Split out from [DaemonStartService] upstream because the same validation
/// runs for a daemon this app just launched and for one it merely discovered.
/// Each rejection is a distinct message so the startup error surface can say
/// which half of the handshake the daemon got wrong, and no rejection reaches
/// the store — a half-valid daemon must not land in the registry.
Future<DaemonStartResult> upsertDesktopDaemonConnection(
  DaemonConnectionStore store,
  DesktopDaemonStatus daemon,
) async {
  final listenAddress = daemon.listen?.trim() ?? '';
  final serverId = daemon.serverId.trim();
  if (listenAddress.isEmpty) {
    return const DaemonStartFailure(
      'Desktop daemon did not return a listen address.',
    );
  }
  if (serverId.isEmpty) {
    return const DaemonStartFailure(
      'Desktop daemon did not return a server id.',
    );
  }
  if (connectionFromListen(listenAddress) == null) {
    return DaemonStartFailure(
      'Desktop daemon returned an unsupported listen address: $listenAddress',
    );
  }
  await store.upsertConnectionFromListen(
    listenAddress: listenAddress,
    serverId: serverId,
    hostname: daemon.hostname,
  );
  return const DaemonStartOk();
}

/// The port used to launch the desktop-managed daemon.
///
/// Upstream defaults this dependency to the real `startDesktopDaemon()` IPC
/// call. Deviation: it is required here, because a Dart default would bind this
/// library to a desktop host and make "never open a real connection in logic"
/// impossible to guarantee. Production wiring supplies the real launcher; tests
/// supply a fake.
typedef DesktopDaemonLauncher = Future<DesktopDaemonStatus> Function();

/// The dependencies [DaemonStartService] is constructed from.
final class DaemonStartServiceDeps {
  /// Creates a dependency bundle.
  const DaemonStartServiceDeps({
    required this.store,
    required this.startDesktopDaemon,
  });

  /// Where a successfully started daemon is registered.
  final DaemonConnectionStore store;

  /// How the daemon process is launched. See [DesktopDaemonLauncher].
  final DesktopDaemonLauncher startDesktopDaemon;
}

/// The subset of [DaemonStartService] that [startHostRuntimeBootstrap] needs.
///
/// Upstream declares this narrow interface separately so the bootstrap can be
/// driven without constructing a real service, and so the bootstrap cannot
/// accidentally reach for the service's mutable state.
abstract interface class HostRuntimeBootstrapDaemonStartService {
  /// Runs the managed-daemon decision. Must not throw: [startHostRuntimeBootstrap]
  /// does not await the result, so a thrown error would surface as an unhandled
  /// async error rather than reaching any caller.
  Future<DaemonStartResult> startIfEnabled({
    required DaemonStartCondition shouldStart,
  });
}

/// Owns the managed daemon's startup attempt and publishes its state.
///
/// The published state is deliberately two scalars — [isRunning] and
/// [lastError] — plus a change notification, because startup chrome must be
/// able to render "starting", "failed" and "neither" without knowing anything
/// about daemons. [resolveStartupBlocker] consumes exactly those two values.
///
/// Reentrancy is counted rather than rejected: a retry issued while an earlier
/// attempt is still in flight keeps `isRunning` true until *both* settle, so
/// the UI never flickers back to a non-starting state mid-retry.
class DaemonStartService implements HostRuntimeBootstrapDaemonStartService {
  /// Creates a service from [deps].
  DaemonStartService(DaemonStartServiceDeps deps)
    : _store = deps.store,
      _startDesktopDaemon = deps.startDesktopDaemon;

  final DaemonConnectionStore _store;
  final DesktopDaemonLauncher _startDesktopDaemon;
  final Set<void Function()> _listeners = <void Function()>{};
  String? _lastError;
  int _inFlightCount = 0;

  /// Starts the managed daemon unconditionally.
  Future<DaemonStartResult> start() =>
      startIfEnabled(shouldStart: const FixedDaemonStartCondition(true));

  /// Evaluates [shouldStart] and, if it says yes, starts and registers the
  /// daemon.
  ///
  /// Settings evaluation is deliberately inside the running window: upstream
  /// publishes `isRunning` *before* the first suspension so restored app chrome
  /// cannot appear in the gap between "deciding" and "starting". The Dart
  /// equivalent holds because an `async` body runs synchronously up to its
  /// first `await`, and `_beginRequest` is above every `await` here.
  ///
  /// A [FixedDaemonStartCondition] is read without suspending, matching
  /// upstream's `typeof … === "boolean"` short-circuit.
  @override
  Future<DaemonStartResult> startIfEnabled({
    required DaemonStartCondition shouldStart,
  }) async {
    _beginRequest();
    try {
      final bool enabled;
      try {
        switch (shouldStart) {
          case FixedDaemonStartCondition(:final value):
            enabled = value;
          case ComputedDaemonStartCondition(:final evaluate):
            enabled = await evaluate();
        }
      } on Object catch (error) {
        return _fail(
          'Failed to evaluate desktop daemon settings: '
          '${describeDiagnosticError(error)}',
        );
      }

      if (!enabled) {
        return const DaemonStartOk();
      }

      final daemon = await _startDesktopDaemon();
      final result = await upsertDesktopDaemonConnection(_store, daemon);
      return switch (result) {
        DaemonStartOk() => result,
        DaemonStartFailure(:final error) => _fail(error),
      };
    } on Object catch (error) {
      return _fail(describeDiagnosticError(error));
    } finally {
      _endRequest();
    }
  }

  /// The most recent failure, or `null` when the last attempt succeeded or a
  /// new attempt has begun.
  ///
  /// Deviation: upstream is the method `getLastError()`; a getter is the Dart
  /// equivalent of the same zero-argument read.
  String? get lastError => _lastError;

  /// Whether any attempt is currently in flight.
  ///
  /// Deviation: upstream is the method `isRunning()`; see [lastError].
  bool get isRunning => _inFlightCount > 0;

  /// Registers [listener], returning its unsubscribe callback.
  ///
  /// Listeners take no arguments: they are a "something changed, re-read me"
  /// signal, which is what lets the same service back both a widget rebuild and
  /// a plain poll without the two disagreeing about ordering.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  DaemonStartResult _fail(String message) {
    _setLastError(message);
    return DaemonStartFailure(message);
  }

  /// Publishes [value] only when it actually differs, so a repeated identical
  /// failure does not wake every subscriber.
  void _setLastError(String? value) {
    if (_lastError == value) {
      return;
    }
    _lastError = value;
    _notify();
  }

  /// Enters the running window and clears any stale error.
  ///
  /// Notifies when either visible fact changed, which is what makes a retry
  /// clear the old message on screen the moment it starts rather than when it
  /// finishes.
  void _beginRequest() {
    final becameRunning = _inFlightCount == 0;
    _inFlightCount += 1;
    final errorChanged = _lastError != null;
    _lastError = null;
    if (becameRunning || errorChanged) {
      _notify();
    }
  }

  /// Leaves the running window, notifying only when the last attempt settles.
  void _endRequest() {
    _inFlightCount = _inFlightCount > 0 ? _inFlightCount - 1 : 0;
    if (_inFlightCount == 0) {
      _notify();
    }
  }

  /// Fans a change out to subscribers.
  ///
  /// Deviation: JS iterates the live `Set`, so a listener that unsubscribes
  /// during a notification is skipped and one that subscribes during a
  /// notification is called. Dart forbids mutating a `Set` while iterating it,
  /// so this snapshots and re-checks membership: unsubscribe-during-notify
  /// behaves exactly as upstream, subscribe-during-notify defers the new
  /// listener to the next notification instead of calling it immediately.
  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      if (!_listeners.contains(listener)) {
        continue;
      }
      listener();
    }
  }
}

DaemonStartService? _singletonDaemonStartService;

/// The process-wide [DaemonStartService], created on first use.
///
/// The daemon may be started at most once per app process, so every caller must
/// observe the same `isRunning`/`lastError`. Upstream additionally stashes the
/// instance on `globalThis` to survive the bundler's module re-evaluation on
/// hot reload; Dart never re-evaluates a library, so the library-level cache
/// alone is the faithful equivalent and the `globalThis` key has no analogue.
///
/// [deps] is ignored once an instance exists — again matching upstream, where
/// the second caller's dependencies are silently discarded.
DaemonStartService getDaemonStartService(DaemonStartServiceDeps deps) =>
    _singletonDaemonStartService ??= DaemonStartService(deps);

/// Drops the cached singleton so a test can build a fresh one.
///
/// Added for the port: upstream's suite runs in a fresh module registry per
/// file, which Dart's shared library state does not give us.
@visibleForTesting
void resetDaemonStartServiceSingleton() {
  _singletonDaemonStartService = null;
}

// ---------------------------------------------------------------------------
// host-runtime-bootstrap.ts
// ---------------------------------------------------------------------------

/// The host registry slice [startHostRuntimeBootstrap] needs.
///
/// Upstream's `boot()` is the registry store's "hydrate yourself from disk and
/// start connecting" entry point; only that one call is required here.
abstract interface class HostRuntimeBootstrapStore {
  /// Hydrates the host registry and brings its runtimes up.
  void boot();
}

/// Starts the host registry and the managed-daemon decision as one operation.
///
/// The ordering is load-bearing and is why this is a function rather than two
/// call sites: the registry must be booting before the daemon decision runs, so
/// that a daemon which registers itself lands in a registry that is already
/// listening. The daemon attempt is intentionally not awaited — startup
/// navigation is driven by [resolveStartupBlocker] reading the service's
/// published state, not by this future.
void startHostRuntimeBootstrap({
  required HostRuntimeBootstrapStore store,
  required HostRuntimeBootstrapDaemonStartService daemonStartService,
  required DaemonStartCondition shouldStartDaemon,
}) {
  store.boot();
  // Upstream's `void promise`: the result is discarded and a rejection becomes
  // an unhandled rejection rather than reaching this caller. `unawaited` has the
  // same shape in Dart — the error goes to the ambient Zone.
  unawaited(daemonStartService.startIfEnabled(shouldStart: shouldStartDaemon));
}

/// The startup route that is shown when nothing else is reachable.
const String startupWelcomeRoute = '/welcome';

/// Why startup is (or is not) holding navigation back.
///
/// A union rather than a pair of booleans because the three states are mutually
/// exclusive and each drives a different surface: nothing, a splash, or an error
/// panel carrying a message.
sealed class StartupBlocker {
  const StartupBlocker();
}

/// Nothing is blocking startup.
final class NoStartupBlocker extends StartupBlocker {
  /// Creates the unblocked state.
  const NoStartupBlocker();

  @override
  bool operator ==(Object other) => other is NoStartupBlocker;

  @override
  int get hashCode => (NoStartupBlocker).hashCode;

  @override
  String toString() => 'NoStartupBlocker()';
}

/// The desktop app is launching the daemon it manages.
final class ManagedDaemonStartingBlocker extends StartupBlocker {
  /// Creates the starting state.
  const ManagedDaemonStartingBlocker();

  @override
  bool operator ==(Object other) => other is ManagedDaemonStartingBlocker;

  @override
  int get hashCode => (ManagedDaemonStartingBlocker).hashCode;

  @override
  String toString() => 'ManagedDaemonStartingBlocker()';
}

/// The managed daemon failed to start; [message] is what the user is shown.
final class ManagedDaemonErrorBlocker extends StartupBlocker {
  /// Creates the failed state.
  const ManagedDaemonErrorBlocker(this.message);

  /// The daemon's failure message.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ManagedDaemonErrorBlocker && other.message == message;

  @override
  int get hashCode => Object.hash(ManagedDaemonErrorBlocker, message);

  @override
  String toString() => 'ManagedDaemonErrorBlocker($message)';
}

/// Whether startup is waiting on the app's own daemon, and why.
///
/// Only the desktop runtime manages a daemon, so every other runtime is
/// unblocked outright. An already-online host short-circuits everything else:
/// once the user can reach *a* host, the managed daemon's own progress stops
/// mattering, which is what keeps a slow local daemon from holding up a session
/// on a remote host.
///
/// The error is checked before the running flag so a retry that has re-entered
/// the running state still surfaces the previous failure rather than silently
/// reverting to a splash.
StartupBlocker resolveStartupBlocker({
  required bool isDesktopRuntime,
  required String? anyOnlineHostServerId,
  required bool daemonStartIsRunning,
  required String? daemonStartError,
}) {
  if (!isDesktopRuntime) {
    return const NoStartupBlocker();
  }
  if (_isTruthy(anyOnlineHostServerId)) {
    return const NoStartupBlocker();
  }
  if (_isTruthy(daemonStartError)) {
    return ManagedDaemonErrorBlocker(daemonStartError!);
  }
  if (daemonStartIsRunning) {
    return const ManagedDaemonStartingBlocker();
  }
  return const NoStartupBlocker();
}

/// Whether startup navigation may run.
///
/// Only the *starting* state holds navigation: a daemon error must still let the
/// app route, because the error surface itself lives on a route.
bool resolveStartupNavigationReady({required StartupBlocker startupBlocker}) =>
    startupBlocker is! ManagedDaemonStartingBlocker;

/// Whether the "give up waiting for a host" timer should be running.
///
/// The timer exists to escape an indefinite splash, so it is pointless once a
/// host is online or once it has already fired. It is also suppressed while any
/// blocker is active: a daemon that is starting will likely produce a host, and
/// a daemon that errored has already given the user something to act on — in
/// both cases a give-up timeout would replace real information with a welcome
/// screen.
bool shouldRunStartupGiveUpTimer({
  required StartupBlocker startupBlocker,
  required String? anyOnlineHostServerId,
  required bool hasGivenUpWaitingForHost,
}) {
  if (_isTruthy(anyOnlineHostServerId)) {
    return false;
  }
  if (hasGivenUpWaitingForHost) {
    return false;
  }
  return startupBlocker is NoStartupBlocker;
}

/// Whether the host registry has finished hydrating.
///
/// Upstream's `"loading" | "ready"`. Kept as a named status rather than a
/// boolean because "loading" is a distinct startup answer — an empty registry
/// that is still loading must never be mistaken for a registry with no hosts.
enum StartupRegistryStatus {
  /// The registry has not hydrated yet; its emptiness proves nothing.
  loading,

  /// The registry is authoritative.
  ready,
}

/// Which route boundary is asking for a startup decision.
sealed class StartupRouteTarget {
  const StartupRouteTarget();
}

/// The app root. [pathname] decides whether this really is the index: the root
/// layout also mounts for deeper paths, which must render rather than be
/// redirected.
final class IndexStartupRouteTarget extends StartupRouteTarget {
  /// Creates an index target for [pathname].
  const IndexStartupRouteTarget(this.pathname);

  /// The current path, as the router reports it.
  final String pathname;
}

/// A `/h/:serverId` boundary. [serverId] is nullable because the route param
/// may be absent or unparsable.
final class HostStartupRouteTarget extends StartupRouteTarget {
  /// Creates a host target for [serverId].
  const HostStartupRouteTarget(this.serverId);

  /// The host the route addresses, or `null` when the param is missing.
  final String? serverId;
}

/// The startup question, as asked by one of the two route boundaries.
///
/// Upstream is a discriminated union whose arms carry different fields; the
/// index arm needs the whole workspace-restore picture, the host arm needs none
/// of it. Sealed subclasses keep that asymmetry instead of making index-only
/// fields nullable on a shared shape.
sealed class ResolveStartupRouteInput {
  const ResolveStartupRouteInput({
    required this.startupBlocker,
    required this.hostRegistryStatus,
    required this.serverIds,
  });

  /// The current blocker; see [resolveStartupBlocker].
  final StartupBlocker startupBlocker;

  /// Whether [serverIds] is authoritative yet.
  final StartupRegistryStatus hostRegistryStatus;

  /// The saved hosts, in registry order. Upstream passes
  /// `readonly { serverId: string }[]`; only the ids are read, so the ids are
  /// what this takes — matching `resolveKnownHostRoute`.
  final List<String> serverIds;
}

/// The `/` boundary's startup question.
final class IndexStartupRouteInput extends ResolveStartupRouteInput {
  /// Creates an index question.
  const IndexStartupRouteInput({
    required this.route,
    required super.startupBlocker,
    required super.hostRegistryStatus,
    required super.serverIds,
    required this.anyOnlineHostServerId,
    required this.workspaceSelection,
    required this.workspaceSelectionStatus,
    required this.isWorkspaceSelectionLoaded,
    required this.hasGivenUpWaitingForHost,
  });

  /// The index target, carrying the current pathname.
  final IndexStartupRouteTarget route;

  /// Any host that is already online, or `null`.
  final String? anyOnlineHostServerId;

  /// The persisted workspace to restore, or `null`.
  final HostWorkspaceRoute? workspaceSelection;

  /// Whether [workspaceSelection] is known to still exist.
  final WorkspaceSelectionStatus workspaceSelectionStatus;

  /// Whether the persisted selection has finished loading. Distinct from it
  /// being `null`: an unloaded selection is unknown, not absent.
  final bool isWorkspaceSelectionLoaded;

  /// Whether the give-up timer has already fired.
  final bool hasGivenUpWaitingForHost;
}

/// The `/h/:serverId` boundary's startup question.
final class HostStartupRouteInput extends ResolveStartupRouteInput {
  /// Creates a host question.
  const HostStartupRouteInput({
    required this.route,
    required super.startupBlocker,
    required super.hostRegistryStatus,
    required super.serverIds,
  });

  /// The host target.
  final HostStartupRouteTarget route;
}

/// What a route boundary should do this frame.
sealed class StartupRouteDecision {
  const StartupRouteDecision();
}

/// Render the route's own content.
final class RenderStartupRoute extends StartupRouteDecision {
  /// Creates the render decision.
  const RenderStartupRoute();

  @override
  bool operator ==(Object other) => other is RenderStartupRoute;

  @override
  int get hashCode => (RenderStartupRoute).hashCode;

  @override
  String toString() => 'RenderStartupRoute()';
}

/// Hold the splash: the answer is not knowable yet.
final class SplashStartupRoute extends StartupRouteDecision {
  /// Creates the splash decision.
  const SplashStartupRoute();

  @override
  bool operator ==(Object other) => other is SplashStartupRoute;

  @override
  int get hashCode => (SplashStartupRoute).hashCode;

  @override
  String toString() => 'SplashStartupRoute()';
}

/// Navigate to [href].
final class RedirectStartupRoute extends StartupRouteDecision {
  /// Creates a redirect to [href].
  const RedirectStartupRoute(this.href);

  /// The destination route.
  final String href;

  @override
  bool operator ==(Object other) =>
      other is RedirectStartupRoute && other.href == href;

  @override
  int get hashCode => Object.hash(RedirectStartupRoute, href);

  @override
  String toString() => 'RedirectStartupRoute($href)';
}

/// Whether the router is sitting on the app root.
///
/// The empty string counts because some routers report the root that way.
bool _isIndexPathname(String pathname) => pathname == '/' || pathname == '';

/// Whether [serverId] names one of [serverIds].
///
/// A blank id is treated as absent, matching upstream's `if (!serverId)` guard —
/// this is what stops a workspace selection with no host from "matching" the
/// registry.
bool _hostExists(List<String> serverIds, String? serverId) {
  if (!_isTruthy(serverId)) {
    return false;
  }
  return serverIds.contains(serverId);
}

/// Whether the persisted workspace selection is still worth restoring.
///
/// `unknown` counts as restorable: before the host's workspace list hydrates
/// there is no evidence against the selection, and refusing to restore until
/// then would bounce every cold launch through project selection.
bool _shouldRestoreWorkspaceSelection({
  required HostWorkspaceRoute? workspaceSelection,
  required WorkspaceSelectionStatus workspaceSelectionStatus,
}) =>
    workspaceSelection != null &&
    workspaceSelectionStatus != WorkspaceSelectionStatus.missing;

String? _firstServerId(List<String> serverIds) =>
    serverIds.isEmpty ? null : serverIds.first;

/// The index decision once nothing is blocking and the registry is authoritative.
StartupRouteDecision _resolveReadyIndexStartupRoute(
  IndexStartupRouteInput input,
) {
  if (!_isIndexPathname(input.route.pathname)) {
    return const RenderStartupRoute();
  }

  if (!input.isWorkspaceSelectionLoaded) {
    return const SplashStartupRoute();
  }

  final selection = input.workspaceSelection;
  if (_shouldRestoreWorkspaceSelection(
        workspaceSelection: selection,
        workspaceSelectionStatus: input.workspaceSelectionStatus,
      ) &&
      _hostExists(input.serverIds, selection!.serverId)) {
    // Native cold launch must enter the host boundary first. The host index
    // owns workspace restore after its local dynamic params exist.
    return RedirectStartupRoute(buildHostRootRoute(selection.serverId));
  }

  if (_isTruthy(input.anyOnlineHostServerId)) {
    return RedirectStartupRoute(
      buildHostRootRoute(input.anyOnlineHostServerId!),
    );
  }

  final savedHostServerId = _firstServerId(input.serverIds);
  if (_isTruthy(savedHostServerId)) {
    return RedirectStartupRoute(buildHostRootRoute(savedHostServerId!));
  }

  if (input.hasGivenUpWaitingForHost) {
    return const RedirectStartupRoute(startupWelcomeRoute);
  }

  return const SplashStartupRoute();
}

/// The host decision once nothing is blocking and the registry is authoritative.
///
/// Delegates to the app's existing [resolveKnownHostRoute] rather than
/// re-implementing the same three-way answer.
///
/// Deviation: [resolveKnownHostRoute] trims the route server id before matching
/// and upstream's `hostExists` compares it raw, so a whitespace-padded id
/// renders here where upstream would redirect. Inert in practice — every route
/// id in this app arrives via `parseServerIdFromPathname`, which already trims.
///
/// The `openProject` arm re-checks the first saved id because upstream falls
/// through to welcome when `hosts[0].serverId` is blank, whereas
/// [resolveKnownHostRoute] only asks whether the list is empty.
StartupRouteDecision _resolveReadyHostStartupRoute(
  HostStartupRouteInput input,
) => switch (resolveKnownHostRoute(
  routeServerId: input.route.serverId,
  serverIds: input.serverIds,
)) {
  KnownHostRouteResolution.render => const RenderStartupRoute(),
  KnownHostRouteResolution.openProject =>
    _isTruthy(_firstServerId(input.serverIds))
        ? RedirectStartupRoute(buildOpenProjectRoute())
        : const RedirectStartupRoute(startupWelcomeRoute),
  KnownHostRouteResolution.welcome => const RedirectStartupRoute(
    startupWelcomeRoute,
  ),
};

/// The startup decision for one route boundary, this frame.
///
/// The two boundaries answer an unknown state differently on purpose. A host
/// route *renders* while startup is blocked or the registry is loading, because
/// it is already mounted and tearing it down would drop the user's place. The
/// index has nothing mounted yet, so it *splashes* instead — showing a welcome
/// screen off a registry that has not hydrated would be a lie about the user
/// having no hosts.
StartupRouteDecision resolveStartupRoute(ResolveStartupRouteInput input) {
  switch (input) {
    case HostStartupRouteInput():
      if (input.startupBlocker is! NoStartupBlocker ||
          input.hostRegistryStatus == StartupRegistryStatus.loading) {
        return const RenderStartupRoute();
      }
      return _resolveReadyHostStartupRoute(input);
    case IndexStartupRouteInput():
      if (input.startupBlocker is! NoStartupBlocker) {
        return const SplashStartupRoute();
      }
      if (input.hostRegistryStatus == StartupRegistryStatus.loading) {
        return const SplashStartupRoute();
      }
      return _resolveReadyIndexStartupRoute(input);
  }
}
