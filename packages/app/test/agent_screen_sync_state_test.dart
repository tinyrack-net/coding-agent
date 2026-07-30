import 'package:coding_agent_app/screens/agent_screen_sync_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sync state priority matches the frozen ready-screen machine', () {
    AgentScreenSyncState resolve({
      bool connected = true,
      bool catchUpPending = false,
      bool hasSyncError = false,
    }) => resolveAgentScreenSyncState(
      archived: false,
      connected: connected,
      catchUpPending: catchUpPending,
      hasSyncError: hasSyncError,
      optimisticCreate: false,
      hasHydratedTimeline: false,
      visibilityCatchUpPending: true,
      hadInitialSyncFailure: false,
    );

    expect(
      resolve(
        connected: false,
        catchUpPending: true,
        hasSyncError: true,
      ).status,
      AgentScreenSyncStatus.reconnecting,
    );
    expect(
      resolve(catchUpPending: true, hasSyncError: true).status,
      AgentScreenSyncStatus.syncError,
    );
    expect(
      resolve(catchUpPending: true).status,
      AgentScreenSyncStatus.catchingUp,
    );
    expect(resolve().status, AgentScreenSyncStatus.idle);
    expect(
      resolveAgentScreenSyncState(
        archived: true,
        connected: false,
        catchUpPending: true,
        hasSyncError: true,
        optimisticCreate: false,
        hasHydratedTimeline: false,
        visibilityCatchUpPending: true,
        hadInitialSyncFailure: false,
      ).status,
      AgentScreenSyncStatus.idle,
    );
  });

  test('catch-up overlay is silent for optimistic or hydrated history', () {
    AgentCatchUpPresentation resolve({
      bool optimisticCreate = false,
      bool hasHydratedTimeline = false,
      bool visibilityCatchUpPending = false,
      bool hadInitialSyncFailure = false,
    }) => resolveAgentCatchUpPresentation(
      optimisticCreate: optimisticCreate,
      hasHydratedTimeline: hasHydratedTimeline,
      visibilityCatchUpPending: visibilityCatchUpPending,
      hadInitialSyncFailure: hadInitialSyncFailure,
    );

    expect(resolve(optimisticCreate: true), AgentCatchUpPresentation.silent);
    expect(resolve(hasHydratedTimeline: true), AgentCatchUpPresentation.silent);
    expect(
      resolve(hadInitialSyncFailure: true),
      AgentCatchUpPresentation.silent,
    );
    expect(
      resolve(visibilityCatchUpPending: true),
      AgentCatchUpPresentation.overlay,
    );
    expect(
      resolve(visibilityCatchUpPending: true, hadInitialSyncFailure: true),
      AgentCatchUpPresentation.overlay,
    );
    expect(resolve(), AgentCatchUpPresentation.overlay);
  });

  test('route memory resets only when agent identity changes', () {
    final memory = AgentScreenRouteMemory();
    expect(memory.enterRoute('server-a:agent-a'), isTrue);
    memory.markInitialSyncFailure();
    memory.markReady();

    expect(memory.enterRoute('server-a:agent-a'), isFalse);
    expect(memory.hasRenderedReady, isTrue);
    expect(memory.hadInitialSyncFailure, isFalse);

    expect(memory.enterRoute('server-a:agent-b'), isTrue);
    expect(memory.hasRenderedReady, isFalse);
    expect(memory.hadInitialSyncFailure, isFalse);
    memory.markReady();
    memory.markInitialSyncFailure();
    expect(memory.hadInitialSyncFailure, isFalse);
  });
}
