import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

class MockAgentSession implements AgentSession {
  final _controller = StreamController<ProviderEvent>.broadcast();
  final List<String> prompts = [];
  bool interrupted = false;
  bool disposed = false;

  /// When set, the next call to [prompt] throws this instead of recording.
  Object? promptError;

  @override
  Stream<ProviderEvent> get events => _controller.stream;

  @override
  Future<void> prompt(String text) async {
    final error = promptError;
    if (error != null) {
      promptError = null;
      throw error;
    }
    prompts.add(text);
  }

  @override
  Future<void> interrupt() async => interrupted = true;

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(ProviderEvent event) => _controller.add(event);

  Future<void> exit([int code = 0]) async {
    emit(SessionExited(exitCode: code));
    await pumpEventQueue();
    await _controller.close();
  }
}

class MockAgentClient implements AgentClient {
  final List<MockAgentSession> sessions = [];
  final List<({String cwd, String model, AgentMode mode, String? sessionId})>
      createCalls = [];

  /// When set, the next call to [createSession] throws this instead of
  /// creating a session.
  Object? createSessionError;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    createCalls.add(
      (cwd: cwd, model: model, mode: mode, sessionId: sessionId),
    );
    final error = createSessionError;
    if (error != null) {
      createSessionError = null;
      throw error;
    }
    final session = MockAgentSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  late Directory tempDir;
  late MockAgentClient client;
  late AgentManager manager;
  late List<AgentStreamPayload> streamed;
  late List<AgentStatePayload> states;
  late List<(String, String, String, ToolCallDetail)> permissionRequests;
  late List<(String, PermissionDecision)> permissionResolutions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_manager_test_');
    client = MockAgentClient();
    streamed = [];
    states = [];
    permissionRequests = [];
    permissionResolutions = [];
    manager = AgentManager(
      clients: {'claude': client},
      store: AgentStore(dataDir: tempDir.path),
      onStream: streamed.add,
      onState: states.add,
      onPermissionRequested: (agentId, permissionId, toolName, detail) =>
          permissionRequests.add((agentId, permissionId, toolName, detail)),
      onPermissionResolved: (permissionId, decision) =>
          permissionResolutions.add((permissionId, decision)),
    );
  });

  tearDown(() async {
    await manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AgentSummary> createAgent() => manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
        title: 'Test',
      );

  test('rejects unsupported providers', () async {
    await expectLater(
      manager.createAgent(
        cwd: tempDir.path,
        provider: 'codex',
        model: 'gpt-5.4',
        mode: AgentMode.normal,
      ),
      throwsA(isA<RpcException>()),
    );
  });

  test('full flow: create -> prompt -> stream -> permission -> complete',
      () async {
    final agent = await createAgent();
    expect(agent.runState, AgentRunState.initializing);
    expect(client.createCalls.single.sessionId, isNull);
    final session = client.sessions.single;

    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.idle);
    expect(states.last.agent.sessionId, 'sess-1');

    // -- prompt --
    await manager.prompt(agent.agentId, 'create hello.txt');
    expect(session.prompts, ['create hello.txt']);
    expect(states.last.agent.runState, AgentRunState.running);
    expect(
      streamed.map((s) => s.item).whereType<UserMessageItem>().single.text,
      'create hello.txt',
    );
    final turnStart =
        streamed.map((s) => s.item).whereType<TurnItem>().single;
    expect(turnStart.phase, TurnPhase.started);

    // -- streaming assistant text (coalesced: leading edge immediate) --
    session.emit(const AssistantTextDelta(itemId: 'm1_0', text: 'Wri'));
    session.emit(const AssistantTextDelta(itemId: 'm1_0', text: 'ting'));
    await pumpEventQueue();
    final firstText = streamed
        .map((s) => s.item)
        .whereType<AssistantMessageItem>()
        .first;
    expect(firstText.text, 'Wri');
    expect(firstText.complete, isFalse);

    session.emit(const AssistantMessageComplete(
      itemId: 'm1_0',
      fullText: 'Writing hello.txt now.',
    ));
    await pumpEventQueue();
    final finalText = streamed
        .map((s) => s.item)
        .whereType<AssistantMessageItem>()
        .last;
    expect(finalText.text, 'Writing hello.txt now.');
    expect(finalText.complete, isTrue);

    // -- permission round-trip --
    PermissionDecision? decided;
    session.emit(PermissionRequested(
      permissionId: 'perm-req-1',
      toolName: 'Write',
      detail: const WriteDetail(path: 'hello.txt', contentPreview: 'hi'),
      respond: (decision, {String? message}) async => decided = decision,
    ));
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.awaitingPermission);
    expect(permissionRequests.single.$1, agent.agentId);
    expect(permissionRequests.single.$2, 'perm-req-1');
    expect(permissionRequests.single.$3, 'Write');
    final pendingItem =
        streamed.map((s) => s.item).whereType<PermissionItem>().last;
    expect(pendingItem.status, PermissionStatus.pending);

    await manager.respondPermission('perm-req-1', 'allow_always');
    expect(decided, PermissionDecision.allow);
    expect(permissionResolutions.single,
        ('perm-req-1', PermissionDecision.allow));
    final resolvedItem =
        streamed.map((s) => s.item).whereType<PermissionItem>().last;
    expect(resolvedItem.status, PermissionStatus.allowed);
    expect(states.last.agent.runState, AgentRunState.running);

    // -- tool call lifecycle --
    session.emit(const ToolCallStarted(
      itemId: 'toolu_1',
      toolName: 'Write',
      status: ToolCallStatus.pending,
      detail: GenericDetail(input: {}),
    ));
    session.emit(const ToolCallUpdated(
      itemId: 'toolu_1',
      toolName: 'Write',
      status: ToolCallStatus.success,
      detail: WriteDetail(path: 'hello.txt', contentPreview: 'hi'),
    ));
    await pumpEventQueue();
    final toolItem =
        streamed.map((s) => s.item).whereType<ToolCallItem>().last;
    expect(toolItem.status, ToolCallStatus.success);

    // -- turn complete --
    session.emit(const TurnCompleted());
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.idle);
    final closedTurn = streamed
        .map((s) => s.item)
        .whereType<TurnItem>()
        .where((t) => t.id == turnStart.id)
        .last;
    expect(closedTurn.phase, TurnPhase.completed);

    // -- fetch catch-up --
    final full = manager.fetchTimeline(agent.agentId);
    expect(full.epoch, 1);
    // user, turn, assistant, permission, tool = 5 distinct items
    expect(full.items, hasLength(5));

    final midSeq = streamed[streamed.length - 3].seq;
    final catchUp = manager.fetchTimeline(
      agent.agentId,
      epoch: 1,
      afterSeq: midSeq,
    );
    expect(catchUp.items.length, lessThan(full.items.length));
    expect(catchUp.lastSeq, full.lastSeq);
    // Every streamed payload seq is unique and increasing.
    final seqs = streamed.map((s) => s.seq).toList();
    expect(seqs, orderedEquals([...seqs]..sort()));
    expect(seqs.toSet().length, seqs.length);

    // Stale epoch falls back to the full snapshot.
    final stale = manager.fetchTimeline(agent.agentId, epoch: 99, afterSeq: 3);
    expect(stale.items, hasLength(full.items.length));
  });

  test('turn failure marks turn failed and state error', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();

    await manager.prompt(agent.agentId, 'do a thing');
    session.emit(const TurnFailed(error: 'boom'));
    await pumpEventQueue();

    expect(states.last.agent.runState, AgentRunState.error);
    final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
    expect(turn.phase, TurnPhase.failed);
    expect(turn.errorMessage, 'boom');
  });

  test('interrupt marks turn canceled and returns to idle', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();

    await manager.prompt(agent.agentId, 'long task');
    await manager.interrupt(agent.agentId);
    expect(session.interrupted, isTrue);
    session.emit(const TurnFailed(error: 'interrupted'));
    await pumpEventQueue();

    expect(states.last.agent.runState, AgentRunState.idle);
    final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
    expect(turn.phase, TurnPhase.canceled);
  });

  test('prompt after session death recreates session with --resume', () async {
    final agent = await createAgent();
    final first = client.sessions.single;
    first.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await first.exit();

    await manager.prompt(agent.agentId, 'still there?');
    expect(client.sessions, hasLength(2));
    expect(client.createCalls.last.sessionId, 'sess-1');
    expect(client.sessions.last.prompts, ['still there?']);
    expect(states.last.agent.runState, AgentRunState.running);
  });

  test('session exit auto-denies pending permissions', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await manager.prompt(agent.agentId, 'write stuff');

    PermissionDecision? decided;
    session.emit(PermissionRequested(
      permissionId: 'perm-2',
      toolName: 'Write',
      detail: const WriteDetail(path: 'x.txt'),
      respond: (decision, {String? message}) async => decided = decision,
    ));
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.awaitingPermission);

    await session.exit(1);
    await pumpEventQueue();
    expect(decided, PermissionDecision.deny);
    expect(permissionResolutions.single.$2, PermissionDecision.deny);
    final item =
        streamed.map((s) => s.item).whereType<PermissionItem>().last;
    expect(item.status, PermissionStatus.denied);
    // Responding again is an error: nothing pending.
    await expectLater(
      manager.respondPermission('perm-2', 'allow'),
      throwsA(isA<RpcException>()),
    );
  });

  test('archive disposes session and hides agent from list', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    expect(manager.list(), hasLength(1));

    await manager.archive(agent.agentId);
    expect(session.disposed, isTrue);
    expect(manager.list(), isEmpty);
    await expectLater(
      manager.prompt(agent.agentId, 'hi'),
      throwsA(isA<RpcException>()),
    );
  });

  test('setMode stores the mode for the next session', () async {
    final agent = await createAgent();
    final updated = await manager.setMode(agent.agentId, AgentMode.plan);
    expect(updated.mode, AgentMode.plan);
    expect(states.last.agent.mode, AgentMode.plan);
  });

  test('persists and reloads agents across manager restarts', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await manager.prompt(agent.agentId, 'hello');
    session.emit(const AssistantMessageComplete(
      itemId: 'm1_0',
      fullText: 'hi back',
    ));
    session.emit(const TurnCompleted());
    await pumpEventQueue();
    await manager.dispose();

    final manager2 = AgentManager(
      clients: {'claude': client},
      store: AgentStore(dataDir: tempDir.path),
    );
    await manager2.load();
    final restored = manager2.list().single;
    expect(restored.agentId, agent.agentId);
    expect(restored.sessionId, 'sess-1');
    expect(restored.runState, AgentRunState.idle);
    final timeline = manager2.fetchTimeline(agent.agentId);
    expect(
      timeline.items.whereType<AssistantMessageItem>().single.text,
      'hi back',
    );
    // Prompting the restored agent resumes the provider session.
    await manager2.prompt(agent.agentId, 'welcome back');
    expect(client.createCalls.last.sessionId, 'sess-1');
    await manager2.dispose();
  });

  test('createAgent propagates a session-start failure as RpcException',
      () async {
    client.createSessionError = StateError('spawn failed');
    await expectLater(
      manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
      ),
      throwsA(isA<RpcException>()),
    );
    expect(manager.list(), isEmpty);
  });

  test('prompt after session death marks the agent as error when restart '
      'also fails', () async {
    final agent = await createAgent();
    final first = client.sessions.single;
    first.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await first.exit();

    client.createSessionError = StateError('restart failed');
    await manager.prompt(agent.agentId, 'still there?');

    expect(states.last.agent.runState, AgentRunState.error);
    final error = streamed.map((s) => s.item).whereType<ErrorItem>().last;
    expect(error.message, contains('failed to restart session'));
  });

  test('session.prompt() throwing marks the turn failed and state error',
      () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();

    session.promptError = StateError('provider rejected the prompt');
    await manager.prompt(agent.agentId, 'do a thing');

    expect(states.last.agent.runState, AgentRunState.error);
    final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
    expect(turn.phase, TurnPhase.failed);
    final error = streamed.map((s) => s.item).whereType<ErrorItem>().last;
    expect(error.message, contains('prompt failed'));
  });

  test('SessionStarted while already running just persists (no state '
      'transition)', () async {
    final agent = await createAgent();
    final first = client.sessions.single;
    first.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await first.exit();

    await manager.prompt(agent.agentId, 'still there?');
    expect(states.last.agent.runState, AgentRunState.running);

    // The recreated session's own SessionStarted arrives while the agent is
    // already running (not initializing): should just update sessionId.
    client.sessions.last.emit(const SessionStarted(sessionId: 'sess-2'));
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.running);
    expect(states.last.agent.sessionId, 'sess-2');
  });

  test('reasoning deltas and completion map to reasoning timeline items',
      () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await manager.prompt(agent.agentId, 'think about it');

    session.emit(const ReasoningDelta(itemId: 'r1', text: 'pon'));
    session.emit(const ReasoningDelta(itemId: 'r1', text: 'dering'));
    await pumpEventQueue();
    final partial = streamed
        .map((s) => s.item)
        .whereType<ReasoningItem>()
        .first;
    expect(partial.text, 'pon');
    expect(partial.complete, isFalse);

    session.emit(const ReasoningComplete(itemId: 'r1', fullText: 'pondering'));
    await pumpEventQueue();
    final complete =
        streamed.map((s) => s.item).whereType<ReasoningItem>().last;
    expect(complete.text, 'pondering');
    expect(complete.complete, isTrue);
  });

  test('SessionExited while interrupted and a turn is open cancels the turn',
      () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();

    await manager.prompt(agent.agentId, 'long task');
    await manager.interrupt(agent.agentId);
    await session.exit();
    await pumpEventQueue();

    expect(states.last.agent.runState, AgentRunState.idle);
    final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
    expect(turn.phase, TurnPhase.canceled);
  });

  test('clearConversations() wipes every agent, nulls sessionId, persists',
      () async {
    final a = await createAgent();
    final b = await createAgent();
    final sa = client.sessions.first;
    final sb = client.sessions.last;
    sa.emit(const SessionStarted(sessionId: 'sess-a'));
    sb.emit(const SessionStarted(sessionId: 'sess-b'));
    await pumpEventQueue();
    await manager.prompt(a.agentId, 'hi A');
    await manager.prompt(b.agentId, 'hi B');
    sa.emit(const AssistantMessageComplete(itemId: 'x', fullText: 'reply A'));
    sb.emit(const AssistantMessageComplete(itemId: 'y', fullText: 'reply B'));
    await pumpEventQueue();

    // Pre-condition: both agents have populated timelines and session ids.
    expect(manager.fetchTimeline(a.agentId).items, isNotEmpty);
    expect(manager.fetchTimeline(b.agentId).items, isNotEmpty);
    expect(
      manager.list().map((s) => s.sessionId).toSet(),
      {'sess-a', 'sess-b'},
    );
    final stateCountBefore = states.length;

    final cleared = await manager.clearConversations();
    expect(cleared, 2);

    // Sessions are torn down.
    expect(sa.disposed, isTrue);
    expect(sb.disposed, isTrue);

    // Each agent's timeline is empty under a fresh epoch.
    for (final id in [a.agentId, b.agentId]) {
      final snapshot = manager.fetchTimeline(id);
      expect(snapshot.items, isEmpty);
      expect(snapshot.epoch, greaterThan(1));
      expect(snapshot.lastSeq, 0);
    }

    // Summary session ids are nulled and run state is idle.
    final after = {for (final s in manager.list()) s.agentId: s};
    expect(after[a.agentId]!.sessionId, isNull);
    expect(after[b.agentId]!.sessionId, isNull);
    expect(after[a.agentId]!.runState, AgentRunState.idle);
    expect(after[b.agentId]!.runState, AgentRunState.idle);

    // A state broadcast was emitted for each agent.
    final newStates = states.sublist(stateCountBefore);
    expect(newStates.map((s) => s.agent.agentId).toSet(), {a.agentId, b.agentId});

    // A fresh manager reading from the same dataDir sees the wiped state:
    // both agents still exist (createdAtMs preserved) but timelines are empty
    // and session ids are gone.
    final manager2 = AgentManager(
      clients: {'claude': client},
      store: AgentStore(dataDir: tempDir.path),
    );
    await manager2.load();
    expect(manager2.list(), hasLength(2));
    for (final s in manager2.list()) {
      expect(s.sessionId, isNull);
      expect(manager2.fetchTimeline(s.agentId).items, isEmpty);
    }
    await manager2.dispose();
  });

  test('clearConversations(agentId:) only wipes the matching agent', () async {
    final a = await createAgent();
    final b = await createAgent();
    final sa = client.sessions.first;
    final sb = client.sessions.last;
    sa.emit(const SessionStarted(sessionId: 'sess-a'));
    sb.emit(const SessionStarted(sessionId: 'sess-b'));
    await pumpEventQueue();
    await manager.prompt(a.agentId, 'hi A');
    await manager.prompt(b.agentId, 'hi B');
    await pumpEventQueue();
    expect(manager.fetchTimeline(a.agentId).items, isNotEmpty);
    expect(manager.fetchTimeline(b.agentId).items, isNotEmpty);

    final cleared = await manager.clearConversations(agentId: a.agentId);
    expect(cleared, 1);
    expect(sa.disposed, isTrue);
    expect(sb.disposed, isFalse);
    expect(manager.fetchTimeline(a.agentId).items, isEmpty);
    expect(manager.fetchTimeline(b.agentId).items, isNotEmpty);
  });

  test('clearConversations() with no agents returns 0 and is a no-op',
      () async {
    expect(await manager.clearConversations(), 0);
    expect(states, isEmpty);
    expect(streamed, isEmpty);
  });
}
