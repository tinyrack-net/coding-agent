/// Owns all agent runtimes: lifecycle, provider sessions, timeline updates,
/// run-state transitions, persistence, and broadcast fan-out.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../permission/permission_broker.dart';
import '../providers/agent_client.dart';
import '../providers/agent_session.dart';
import '../providers/provider_event.dart';
import '../server/rpc_router.dart';
import 'agent_store.dart';
import 'timeline_store.dart';

typedef PermissionRequestedBroadcast = void Function(
  String agentId,
  String permissionId,
  String toolName,
  ToolCallDetail detail,
);
typedef PermissionResolvedBroadcast = void Function(
  String permissionId,
  PermissionDecision decision,
);

final class AgentRuntime {
  AgentRuntime({
    required this.summary,
    required this.timeline,
    this.archived = false,
  });

  AgentSummary summary;
  final TimelineStore timeline;
  bool archived;

  AgentSession? session;
  StreamSubscription<ProviderEvent>? sessionSub;

  /// id of the open TurnItem, if a turn is in flight.
  String? currentTurnId;
  bool interruptRequested = false;

  /// Accumulated streaming text per timeline item id.
  final Map<String, StringBuffer> textBuffers = {};
}

class AgentManager {
  AgentManager({
    required Map<String, AgentClient> clients,
    required AgentStore store,
    PermissionBroker? broker,
    this.onStream,
    this.onState,
    this.onPermissionRequested,
    this.onPermissionResolved,
  })  : _clients = clients,
        _store = store,
        broker = broker ?? PermissionBroker();

  final Map<String, AgentClient> _clients;
  final AgentStore _store;
  final PermissionBroker broker;
  final _uuid = const Uuid();

  void Function(AgentStreamPayload payload)? onStream;
  void Function(AgentStatePayload payload)? onState;
  PermissionRequestedBroadcast? onPermissionRequested;
  PermissionResolvedBroadcast? onPermissionResolved;

  final Map<String, AgentRuntime> _runtimes = {};

  /// Restore persisted agents (sessions are recreated lazily on next prompt).
  Future<void> load() async {
    for (final record in await _store.loadAll()) {
      final runtime = AgentRuntime(
        // A restored agent has no live session; coerce transient states.
        summary: record.summary.copyWith(runState: AgentRunState.idle),
        timeline: TimelineStore(
          agentId: record.summary.agentId,
          epoch: record.epoch,
          items: record.items,
        ),
        archived: record.archived,
      );
      runtime.timeline.onItem = _onTimelineItem;
      _runtimes[record.summary.agentId] = runtime;
    }
  }

  List<AgentSummary> list() => [
        for (final r in _runtimes.values)
          if (!r.archived) r.summary,
      ];

  AgentRuntime _runtime(String agentId) {
    final runtime = _runtimes[agentId];
    if (runtime == null || runtime.archived) {
      throw RpcException(RpcErrorCodes.notFound, 'no agent $agentId');
    }
    return runtime;
  }

  Future<AgentSummary> createAgent({
    required String cwd,
    required String provider,
    required String model,
    required AgentMode mode,
    String? title,
    String? projectPath,
    String? branch,
    bool isWorktree = false,
  }) async {
    final client = _clients[provider];
    if (client == null) {
      throw RpcException(
        RpcErrorCodes.invalidPayload,
        'unsupported provider "$provider" (supported: ${_clients.keys.join(', ')})',
      );
    }
    final agentId = _uuid.v4();
    final runtime = AgentRuntime(
      summary: AgentSummary(
        agentId: agentId,
        title: title ?? 'Agent',
        cwd: cwd,
        provider: provider,
        model: model,
        mode: mode,
        runState: AgentRunState.initializing,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        projectPath: projectPath,
        branch: branch,
        isWorktree: isWorktree,
      ),
      timeline: TimelineStore(agentId: agentId),
    );
    runtime.timeline.onItem = _onTimelineItem;
    _runtimes[agentId] = runtime;
    try {
      await _startSession(runtime);
    } catch (e) {
      _runtimes.remove(agentId);
      throw RpcException(RpcErrorCodes.internal, 'failed to start session: $e');
    }
    _persist(runtime);
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<void> _startSession(AgentRuntime runtime) async {
    final client = _clients[runtime.summary.provider]!;
    final session = await client.createSession(
      cwd: runtime.summary.cwd,
      model: runtime.summary.model,
      mode: runtime.summary.mode,
      sessionId: runtime.summary.sessionId,
      initialHistory: runtime.timeline.snapshot(),
    );
    runtime.session = session;
    runtime.sessionSub = session.events.listen(
      (event) => _onProviderEvent(runtime, event),
    );
  }

  Future<void> prompt(String agentId, String text) async {
    final runtime = _runtime(agentId);
    if (runtime.session == null) {
      // Session died earlier: recreate, resuming the provider conversation.
      try {
        await _startSession(runtime);
      } catch (e) {
        runtime.timeline.upsert(ErrorItem(
          id: _uuid.v4(),
          message: 'failed to restart session: $e',
        ));
        _setRunState(runtime, AgentRunState.error);
        return;
      }
    }
    runtime.interruptRequested = false;
    runtime.timeline.upsert(UserMessageItem(id: _uuid.v4(), text: text));
    final turnId = 'turn_${_uuid.v4()}';
    runtime.currentTurnId = turnId;
    runtime.timeline.upsert(TurnItem(id: turnId, phase: TurnPhase.started));
    _setRunState(runtime, AgentRunState.running);
    try {
      await runtime.session!.prompt(text);
    } catch (e) {
      runtime.timeline.upsert(
        ErrorItem(id: _uuid.v4(), message: 'prompt failed: $e'),
      );
      _closeTurn(runtime, TurnPhase.failed, errorMessage: '$e');
      _setRunState(runtime, AgentRunState.error);
    }
  }

  Future<void> interrupt(String agentId) async {
    final runtime = _runtime(agentId);
    runtime.interruptRequested = true;
    await runtime.session?.interrupt();
  }

  Future<AgentSummary> setMode(String agentId, AgentMode mode) async {
    final runtime = _runtime(agentId);
    // M1: stored only; the flag applies when the next session is spawned.
    runtime.summary = runtime.summary.copyWith(mode: mode);
    _persist(runtime);
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<AgentSummary> rename(String agentId, String title) async {
    final runtime = _runtime(agentId);
    runtime.summary = runtime.summary.copyWith(title: title);
    _persist(runtime);
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<void> archive(String agentId) async {
    final runtime = _runtime(agentId);
    runtime.archived = true;
    final session = runtime.session;
    runtime.session = null;
    await runtime.sessionSub?.cancel();
    runtime.sessionSub = null;
    await broker.autoDenyForAgent(agentId);
    await session?.dispose();
    runtime.timeline.flushAll();
    _persist(runtime);
    await _store.flush();
  }

  TimelineFetchResponse fetchTimeline(
    String agentId, {
    int? epoch,
    int? afterSeq,
  }) {
    final runtime = _runtime(agentId);
    final timeline = runtime.timeline;
    // Stale-epoch (or no-epoch) clients get the full snapshot.
    if (epoch == null || epoch != timeline.epoch) {
      return timeline.fetch();
    }
    return timeline.fetch(afterSeq: afterSeq ?? 0);
  }

  Future<void> respondPermission(String permissionId, String decision) =>
      broker.respond(permissionId, decision);

  /// Wipe the in-memory and persisted conversation state for one or every
  /// agent. Returns the number of agents actually affected.
  ///
  /// For each affected agent this: tears down its live session, cancels any
  /// pending permission prompts, drops the timeline (bumping the epoch so
  /// stale clients refetch an empty list), nulls the provider session id so
  /// the next prompt starts a fresh provider-side conversation, and writes
  /// the wiped state to disk.
  Future<int> clearConversations({String? agentId}) async {
    final targets = <AgentRuntime>[];
    for (final r in _runtimes.values) {
      if (agentId == null || r.summary.agentId == agentId) {
        targets.add(r);
      }
    }
    for (final runtime in targets) {
      // Tear down the live session, if any.
      await runtime.sessionSub?.cancel();
      runtime.sessionSub = null;
      final session = runtime.session;
      runtime.session = null;
      // Drop any pending permission prompts for this agent.
      await broker.autoDenyForAgent(runtime.summary.agentId);
      await session?.dispose();

      // Drop accumulated streaming text and turn state.
      runtime.textBuffers.clear();
      runtime.currentTurnId = null;
      runtime.interruptRequested = false;

      // Wipe the timeline (bumps epoch, clears items).
      runtime.timeline.clear();

      // Null the session id so the next prompt starts a fresh provider
      // session, and force run state back to idle. We can't go through
      // `copyWith` here because its `String? sessionId ?? this.sessionId`
      // pattern can't represent "clear the field" — build the summary
      // directly with all the original fields swapped.
      final s = runtime.summary;
      runtime.summary = AgentSummary(
        agentId: s.agentId,
        title: s.title,
        cwd: s.cwd,
        provider: s.provider,
        model: s.model,
        mode: s.mode,
        runState: AgentRunState.idle,
        createdAtMs: s.createdAtMs,
        sessionId: null,
      );

      _persist(runtime);
      _broadcastState(runtime);
    }
    // Flush debounced writes immediately so a quit right after the reset
    // doesn't lose the wiped state to disk.
    await _store.flush();
    return targets.length;
  }

  Future<void> dispose() async {
    for (final runtime in _runtimes.values) {
      await runtime.sessionSub?.cancel();
      await runtime.session?.dispose();
      runtime.timeline.dispose();
      _persist(runtime);
    }
    await _store.flush();
  }

  // -- provider event handling ----------------------------------------------

  void _onProviderEvent(AgentRuntime runtime, ProviderEvent event) {
    switch (event) {
      case SessionStarted(:final sessionId):
        runtime.summary = runtime.summary.copyWith(sessionId: sessionId);
        if (runtime.summary.runState == AgentRunState.initializing) {
          _setRunState(runtime, AgentRunState.idle);
        } else {
          _persist(runtime);
          _broadcastState(runtime);
        }

      case AssistantTextDelta(:final itemId, :final text):
        final buffer =
            runtime.textBuffers.putIfAbsent(itemId, StringBuffer.new)
              ..write(text);
        runtime.timeline.upsertCoalesced(AssistantMessageItem(
          id: itemId,
          text: buffer.toString(),
          complete: false,
        ));

      case ReasoningDelta(:final itemId, :final text):
        final buffer =
            runtime.textBuffers.putIfAbsent(itemId, StringBuffer.new)
              ..write(text);
        runtime.timeline.upsertCoalesced(ReasoningItem(
          id: itemId,
          text: buffer.toString(),
          complete: false,
        ));

      case AssistantMessageComplete(:final itemId, :final fullText):
        runtime.textBuffers.remove(itemId);
        runtime.timeline.upsert(AssistantMessageItem(
          id: itemId,
          text: fullText,
          complete: true,
        ));

      case ReasoningComplete(:final itemId, :final fullText):
        runtime.textBuffers.remove(itemId);
        runtime.timeline.upsert(ReasoningItem(
          id: itemId,
          text: fullText,
          complete: true,
        ));

      case ToolCallStarted(:final itemId, :final toolName, :final status, :final detail):
      case ToolCallUpdated(:final itemId, :final toolName, :final status, :final detail):
        runtime.timeline.upsert(ToolCallItem(
          id: itemId,
          toolName: toolName,
          status: status,
          detail: detail,
        ));

      case PermissionRequested(
          :final permissionId,
          :final toolName,
          :final detail,
          :final respond,
        ):
        _onPermissionRequested(runtime, permissionId, toolName, detail, respond);

      case TurnCompleted():
        runtime.timeline.flushAll();
        _closeTurn(runtime, TurnPhase.completed);
        _setRunState(runtime, AgentRunState.idle);

      case TurnFailed(:final error):
        runtime.timeline.flushAll();
        if (runtime.interruptRequested) {
          _closeTurn(runtime, TurnPhase.canceled);
          _setRunState(runtime, AgentRunState.idle);
        } else {
          _closeTurn(runtime, TurnPhase.failed, errorMessage: error);
          _setRunState(runtime, AgentRunState.error);
        }

      case SessionExited():
        _onSessionExited(runtime);
    }
  }

  void _onPermissionRequested(
    AgentRuntime runtime,
    String permissionId,
    String toolName,
    ToolCallDetail detail,
    PermissionRespond respond,
  ) {
    final itemId = 'perm_$permissionId';
    runtime.timeline.upsert(PermissionItem(
      id: itemId,
      permissionId: permissionId,
      toolName: toolName,
      status: PermissionStatus.pending,
      detail: detail,
    ));
    broker.register(
      permissionId: permissionId,
      agentId: runtime.summary.agentId,
      respond: respond,
      onResolved: (decision) {
        runtime.timeline.upsert(PermissionItem(
          id: itemId,
          permissionId: permissionId,
          toolName: toolName,
          status: decision == PermissionDecision.allow
              ? PermissionStatus.allowed
              : PermissionStatus.denied,
          detail: detail,
        ));
        if (runtime.summary.runState == AgentRunState.awaitingPermission) {
          _setRunState(runtime, AgentRunState.running);
        }
        onPermissionResolved?.call(permissionId, decision);
      },
    );
    _setRunState(runtime, AgentRunState.awaitingPermission);
    onPermissionRequested?.call(
      runtime.summary.agentId,
      permissionId,
      toolName,
      detail,
    );
  }

  void _onSessionExited(AgentRuntime runtime) {
    runtime.session = null;
    runtime.sessionSub?.cancel();
    runtime.sessionSub = null;
    runtime.timeline.flushAll();
    unawaited(broker.autoDenyForAgent(runtime.summary.agentId));
    if (runtime.currentTurnId != null) {
      // Turn still open: the process died mid-turn.
      if (runtime.interruptRequested) {
        _closeTurn(runtime, TurnPhase.canceled);
        _setRunState(runtime, AgentRunState.idle);
      } else {
        _closeTurn(runtime, TurnPhase.failed, errorMessage: 'session exited');
        _setRunState(runtime, AgentRunState.error);
      }
    } else if (runtime.summary.runState != AgentRunState.error) {
      _setRunState(runtime, AgentRunState.idle);
    }
  }

  void _closeTurn(
    AgentRuntime runtime,
    TurnPhase phase, {
    String? errorMessage,
  }) {
    final turnId = runtime.currentTurnId;
    runtime.currentTurnId = null;
    if (turnId == null) return;
    runtime.timeline.upsert(
      TurnItem(id: turnId, phase: phase, errorMessage: errorMessage),
    );
  }

  void _setRunState(AgentRuntime runtime, AgentRunState state) {
    if (runtime.summary.runState == state) return;
    runtime.summary = runtime.summary.copyWith(runState: state);
    _persist(runtime);
    _broadcastState(runtime);
  }

  void _broadcastState(AgentRuntime runtime) {
    onState?.call(AgentStatePayload(agent: runtime.summary));
  }

  void _onTimelineItem(String agentId, int epoch, int seq, TimelineItem item) {
    onStream?.call(AgentStreamPayload(
      agentId: agentId,
      epoch: epoch,
      seq: seq,
      item: item,
    ));
    final runtime = _runtimes[agentId];
    if (runtime != null) _persist(runtime);
  }

  void _persist(AgentRuntime runtime) {
    _store.scheduleSave(PersistedAgent(
      summary: runtime.summary,
      archived: runtime.archived,
      epoch: runtime.timeline.epoch,
      lastSeq: runtime.timeline.lastSeq,
      items: runtime.timeline.snapshot(),
    ));
  }
}
