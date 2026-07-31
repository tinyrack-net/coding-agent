/// Port of Paseo 0.2.0's session-facing decision rules, grouped here because
/// each is a frozen, dependency-free rule that a widget or controller asks a
/// yes/no or which-value question of:
///
/// - `components/sidebar/sidebar-workspace-title.ts` — which string a sidebar
///   workspace row shows as its primary label, given the user's title-source
///   preference.
/// - `components/synced-loader-state.ts` — which frame the six-dot "synced"
///   loader is on. Driven by wall-clock time rather than per-widget animation
///   state so every loader on screen pulses in lockstep.
/// - `screens/settings/daemon-reconnect.ts` — whether the daemon we are now
///   talking to is a *new* connection rather than the one we were already on,
///   which is how the settings screen knows an update actually landed.
/// - `contexts/session-resume-revalidation.ts` — whether returning to the app
///   after time in the background is stale enough to warrant refetching, and
///   whether that refetch actually succeeded.
library;

// ---------------------------------------------------------------------------
// sidebar-workspace-title.ts
// ---------------------------------------------------------------------------

/// Upstream `WorkspaceTitleSource` from `hooks/use-settings/storage.ts`
/// (`"title" | "branch"`). Declared locally because the settings storage module
/// is not ported yet.
enum WorkspaceTitleSource { title, branch }

/// The primary label for a sidebar workspace row.
///
/// Upstream takes `Pick<SidebarWorkspaceEntry, "name" | "currentBranch">`;
/// `SidebarWorkspaceEntry` is not ported, so the two fields it actually reads
/// are passed directly: `name` -> [workspaceName], `currentBranch` ->
/// [workspaceCurrentBranch].
///
/// Branch mode falls back to the name only when there is no branch at all — a
/// workspace on an empty-string branch keeps the empty string, matching
/// upstream's `??` (nullish, not falsy) coalescing.
String resolveSidebarWorkspacePrimaryLabel({
  required String workspaceName,
  required String? workspaceCurrentBranch,
  required WorkspaceTitleSource workspaceTitleSource,
}) {
  if (workspaceTitleSource == WorkspaceTitleSource.branch) {
    return workspaceCurrentBranch ?? workspaceName;
  }
  return workspaceName;
}

// ---------------------------------------------------------------------------
// synced-loader-state.ts
// ---------------------------------------------------------------------------

const int _syncedLoaderDurationMs = 950;

/// How many dots the synced loader draws, and equally how many animation steps
/// one full cycle has.
const int syncedLoaderDotCount = 6;

const List<List<double>> _syncedLoaderOpacityStates = [
  [1, 0, 0.78, 0, 0.56, 0.34],
  [0.78, 1, 0.56, 0, 0.34, 0],
  [0.56, 0.78, 0.34, 1, 0, 0],
  [0.34, 0.56, 0, 0.78, 0, 1],
  [0, 0.34, 0, 0.56, 1, 0.78],
  [0, 0, 1, 0.34, 0.78, 0.56],
];

/// The loader step for a wall-clock instant, so independently mounted loaders
/// land on the same frame without sharing any state.
///
/// [nowMs] is the injected clock reading (upstream passes a UI-thread
/// timestamp), which keeps this pure and makes tests deterministic.
///
/// Uses [num.remainder] rather than `%` so a negative [nowMs] yields a negative
/// step exactly as JavaScript's `%` does; that out-of-range step then reads as
/// fully transparent in [getSyncedLoaderDotOpacity], same as upstream.
int getSyncedLoaderStep(num nowMs) {
  final elapsedMs = nowMs.remainder(_syncedLoaderDurationMs);
  return (elapsedMs * syncedLoaderDotCount / _syncedLoaderDurationMs).floor();
}

/// The opacity of one dot at one step. Any out-of-range index is fully
/// transparent, mirroring upstream's optional-index lookup with a `?? 0`.
double getSyncedLoaderDotOpacity(int step, int dot) {
  if (step < 0 || step >= _syncedLoaderOpacityStates.length) return 0;
  final state = _syncedLoaderOpacityStates[step];
  if (dot < 0 || dot >= state.length) return 0;
  return state[dot];
}

// ---------------------------------------------------------------------------
// daemon-reconnect.ts
// ---------------------------------------------------------------------------

/// Upstream's inline `connectionStatus` union on `DaemonConnectionSnapshot`.
enum DaemonConnectionStatus { idle, connecting, online, offline, error }

/// The identity of a particular daemon connection, captured before an action
/// that is expected to bounce the daemon.
final class DaemonConnectionMarker {
  const DaemonConnectionMarker({
    required this.clientGeneration,
    required this.lastOnlineAt,
  });

  final int clientGeneration;

  /// Kept as the raw ISO-8601 string upstream stores, because the comparison
  /// below is string inequality — parsing it to a `DateTime` would silently
  /// change which values count as different.
  final String? lastOnlineAt;
}

/// A live connection reading: a marker plus the current status.
final class DaemonConnectionSnapshot extends DaemonConnectionMarker {
  const DaemonConnectionSnapshot({
    required this.connectionStatus,
    required super.clientGeneration,
    required super.lastOnlineAt,
  });

  final DaemonConnectionStatus connectionStatus;
}

/// Whether the daemon has come back on a connection distinct from [start].
///
/// Anything short of `online` is not a reconnect yet. With no [start] marker
/// there is nothing to be newer than, so any online connection counts. A bumped
/// client generation covers the client reconnecting; a moved `lastOnlineAt`
/// covers the same client re-establishing its session, which is why either one
/// alone is enough.
bool hasDaemonReconnectedAfter({
  required DaemonConnectionSnapshot? snapshot,
  required DaemonConnectionMarker? start,
}) {
  if (snapshot == null ||
      snapshot.connectionStatus != DaemonConnectionStatus.online) {
    return false;
  }
  if (start == null) return true;
  return snapshot.clientGeneration != start.clientGeneration ||
      snapshot.lastOnlineAt != start.lastOnlineAt;
}

// ---------------------------------------------------------------------------
// session-resume-revalidation.ts
// ---------------------------------------------------------------------------

/// How long the app must have been backgrounded before what it has cached is
/// assumed stale.
const int sessionStaleAfterMs = 60000;

/// Revalidates a session after the app returns to the foreground, returning
/// whether a refresh actually happened.
///
/// A short trip away leaves everything alone — the live subscription will have
/// kept up. Past the threshold both the timeline history generation and the
/// directory listing are refreshed, in that order.
///
/// A throw means the host is not reachable (typically "Host server is not
/// connected"), so this reports `false` and leaves the caller to try again
/// later rather than surfacing an error the user cannot act on. The history
/// bump is deliberately inside the guarded region too, matching upstream.
///
/// Upstream's `refreshDirectories` returns `Promise<unknown>`; the result is
/// never read, so it maps to `Future<void> Function()` here.
Future<bool> revalidateSessionAfterResume({
  required num awayMs,
  required String serverId,
  required void Function(String serverId) bumpHistorySyncGeneration,
  required Future<void> Function() refreshDirectories,
}) async {
  if (awayMs < sessionStaleAfterMs) {
    return false;
  }

  try {
    bumpHistorySyncGeneration(serverId);
    await refreshDirectories();
    return true;
  } catch (_) {
    return false;
  }
}
