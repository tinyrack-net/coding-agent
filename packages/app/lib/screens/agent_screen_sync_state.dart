enum AgentScreenSyncStatus { idle, reconnecting, catchingUp, syncError }

enum AgentCatchUpPresentation { silent, overlay }

final class AgentScreenSyncState {
  const AgentScreenSyncState._(this.status, this.catchUpPresentation);

  const AgentScreenSyncState.idle()
    : this._(AgentScreenSyncStatus.idle, AgentCatchUpPresentation.silent);

  const AgentScreenSyncState.reconnecting()
    : this._(
        AgentScreenSyncStatus.reconnecting,
        AgentCatchUpPresentation.silent,
      );

  const AgentScreenSyncState.syncError()
    : this._(AgentScreenSyncStatus.syncError, AgentCatchUpPresentation.silent);

  const AgentScreenSyncState.catchingUp(AgentCatchUpPresentation presentation)
    : this._(AgentScreenSyncStatus.catchingUp, presentation);

  final AgentScreenSyncStatus status;
  final AgentCatchUpPresentation catchUpPresentation;

  bool get showsCatchUpOverlay =>
      status == AgentScreenSyncStatus.catchingUp &&
      catchUpPresentation == AgentCatchUpPresentation.overlay;
}

AgentCatchUpPresentation resolveAgentCatchUpPresentation({
  required bool optimisticCreate,
  required bool hasHydratedTimeline,
  required bool visibilityCatchUpPending,
  required bool hadInitialSyncFailure,
}) {
  if (optimisticCreate || hasHydratedTimeline) {
    return AgentCatchUpPresentation.silent;
  }
  if (visibilityCatchUpPending) {
    return AgentCatchUpPresentation.overlay;
  }
  if (hadInitialSyncFailure) {
    return AgentCatchUpPresentation.silent;
  }
  return AgentCatchUpPresentation.overlay;
}

AgentScreenSyncState resolveAgentScreenSyncState({
  required bool archived,
  required bool connected,
  required bool catchUpPending,
  required bool hasSyncError,
  required bool optimisticCreate,
  required bool hasHydratedTimeline,
  required bool visibilityCatchUpPending,
  required bool hadInitialSyncFailure,
}) {
  if (archived) return const AgentScreenSyncState.idle();
  if (!connected) return const AgentScreenSyncState.reconnecting();
  if (hasSyncError) return const AgentScreenSyncState.syncError();
  if (!catchUpPending) return const AgentScreenSyncState.idle();
  return AgentScreenSyncState.catchingUp(
    resolveAgentCatchUpPresentation(
      optimisticCreate: optimisticCreate,
      hasHydratedTimeline: hasHydratedTimeline,
      visibilityCatchUpPending: visibilityCatchUpPending,
      hadInitialSyncFailure: hadInitialSyncFailure,
    ),
  );
}

/// Route-scoped memory retained across temporary connection and replica gaps.
final class AgentScreenRouteMemory {
  String? _routeKey;

  bool hasRenderedReady = false;
  bool hadInitialSyncFailure = false;

  void enterRoute(String routeKey) {
    if (_routeKey == routeKey) return;
    _routeKey = routeKey;
    hasRenderedReady = false;
    hadInitialSyncFailure = false;
  }

  void markReady() {
    hasRenderedReady = true;
    hadInitialSyncFailure = false;
  }

  void markInitialSyncFailure() {
    if (!hasRenderedReady) hadInitialSyncFailure = true;
  }
}
