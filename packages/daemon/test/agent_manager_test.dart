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

  @override
  Stream<ProviderEvent> get events => _controller.stream;

  @override
  Future<void> prompt(String text) async => prompts.add(text);

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

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
  }) async {
    createCalls.add(
      (cwd: cwd, model: model, mode: mode, sessionId: sessionId),
    );
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
}
