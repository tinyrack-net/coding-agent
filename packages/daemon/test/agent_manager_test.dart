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

class MockAgentSession
    implements
        HistoryRestoringAgentSession,
        ProviderSubagentRestoringAgentSession,
        ConfigurableAgentSession {
  MockAgentSession({
    this.restoredHistory,
    this.restoredProviderSubagents = const [],
  });

  final _controller = StreamController<ProviderEvent>.broadcast();
  final List<String> prompts = [];
  bool interrupted = false;
  bool disposed = false;
  String? configuredMode;
  String? configuredModel;
  String? configuredThinking;
  final Map<String, Object?> configuredFeatures = {};

  @override
  final List<TimelineItem>? restoredHistory;
  @override
  final List<RestoredProviderSubagent> restoredProviderSubagents;

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
  Future<AgentProviderNotice?> setMode(String modeId) async {
    configuredMode = modeId;
    return const AgentProviderNotice(
      type: AgentProviderNoticeType.info,
      message: 'mode changed',
    );
  }

  @override
  Future<void> setModel(String? modelId) async => configuredModel = modelId;

  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async {
    configuredThinking = thinkingOptionId;
    return null;
  }

  @override
  Future<void> setFeature(String featureId, Object? value) async {
    configuredFeatures[featureId] = value;
  }

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

class MockStructuredAgentSession extends MockAgentSession
    implements ImagePromptAgentSession {
  final structuredPrompts =
      <
        ({
          String text,
          List<AgentPromptImage> images,
          List<AgentAttachment> attachments,
        })
      >[];

  @override
  Future<void> promptWithAttachments(
    String text,
    List<AgentAttachment> attachments,
  ) => promptWithImagesAndAttachments(text, const [], attachments);

  @override
  Future<void> promptWithImagesAndAttachments(
    String text,
    List<AgentPromptImage> images,
    List<AgentAttachment> attachments,
  ) async => structuredPrompts.add((
    text: text,
    images: images,
    attachments: attachments,
  ));
}

class MockAgentClient implements AgentClient {
  final List<MockAgentSession> sessions = [];
  final List<
    ({
      String cwd,
      Map<String, Object?> featureValues,
      String model,
      AgentMode mode,
      String? modeId,
      String? sessionId,
      String? thinkingOptionId,
    })
  >
  createCalls = [];

  /// When set, the next call to [createSession] throws this instead of
  /// creating a session.
  Object? createSessionError;
  List<TimelineItem>? nextRestoredHistory;
  List<RestoredProviderSubagent> nextRestoredProviderSubagents = const [];
  bool useStructuredSession = false;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    createCalls.add((
      cwd: cwd,
      featureValues: featureValues,
      model: model,
      mode: mode,
      modeId: modeId,
      sessionId: sessionId,
      thinkingOptionId: thinkingOptionId,
    ));
    final error = createSessionError;
    if (error != null) {
      createSessionError = null;
      throw error;
    }
    final session = useStructuredSession
        ? MockStructuredAgentSession()
        : MockAgentSession(
            restoredHistory: nextRestoredHistory,
            restoredProviderSubagents: nextRestoredProviderSubagents,
          );
    nextRestoredHistory = null;
    nextRestoredProviderSubagents = const [];
    sessions.add(session);
    return session;
  }
}

PersistedAgent _storedAgent(
  String agentId, {
  required String title,
  bool archived = false,
  bool internal = false,
  String? sessionId,
  String? workspaceId,
  List<TimelineItem> items = const [],
}) => PersistedAgent(
  summary: AgentSummary(
    agentId: agentId,
    title: title,
    cwd: '/repo',
    provider: 'claude',
    model: 'claude-sonnet-5',
    mode: AgentMode.normal,
    runState: archived ? AgentRunState.closed : AgentRunState.idle,
    createdAtMs: 1,
    sessionId: sessionId,
    workspaceId: workspaceId,
    archivedAt: archived ? '2026-07-28T00:00:00.000Z' : null,
  ),
  archived: archived,
  epoch: 1,
  lastSeq: 0,
  items: items,
  internal: internal,
);

Matcher _rpcMessage(String message) => isA<RpcException>().having(
  (error) => error.error.message,
  'message',
  message,
);

void main() {
  late Directory tempDir;
  late MockAgentClient client;
  late AgentManager manager;
  late List<AgentStreamPayload> streamed;
  late List<AgentStatePayload> states;
  late List<(String, String, String, ToolCallDetail)> permissionRequests;
  late List<(String, PermissionDecision)> permissionResolutions;
  late List<(String, AgentAttentionReason, String)> attentionEvents;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_manager_test_');
    client = MockAgentClient();
    streamed = [];
    states = [];
    permissionRequests = [];
    permissionResolutions = [];
    attentionEvents = [];
    manager = AgentManager(
      clients: {'claude': client},
      store: AgentStore(dataDir: tempDir.path),
      onStream: streamed.add,
      onState: states.add,
      onPermissionRequested: (agentId, permissionId, toolName, detail) =>
          permissionRequests.add((agentId, permissionId, toolName, detail)),
      onPermissionResolved: (permissionId, decision) =>
          permissionResolutions.add((permissionId, decision)),
      onAttention: (agentId, reason, timestamp) =>
          attentionEvents.add((agentId, reason, timestamp)),
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

  test(
    'resolves provider clients dynamically from the daemon config surface',
    () async {
      await manager.dispose();
      final dynamicClient = MockAgentClient();
      var configured = true;
      manager = AgentManager(
        clients: const {},
        clientResolver: (provider) =>
            configured && provider == 'custom-acp' ? dynamicClient : null,
        providerIdsResolver: () =>
            configured ? const ['custom-acp'] : const <String>[],
        store: AgentStore(dataDir: tempDir.path),
      );

      expect(manager.isProviderAvailable('custom-acp'), isTrue);
      final created = await manager.createAgent(
        cwd: tempDir.path,
        provider: 'custom-acp',
        model: '',
        mode: AgentMode.normal,
        title: 'Dynamic ACP',
      );
      expect(created.provider, 'custom-acp');
      expect(dynamicClient.sessions, hasLength(1));

      configured = false;
      expect(manager.isProviderAvailable('custom-acp'), isFalse);
      await expectLater(
        manager.createAgent(
          cwd: tempDir.path,
          provider: 'custom-acp',
          model: '',
          mode: AgentMode.normal,
        ),
        throwsA(
          isA<RpcException>().having(
            (error) => error.error.message,
            'message',
            contains('unsupported provider "custom-acp"'),
          ),
        ),
      );
    },
  );

  test('imports provider history and serializes duplicate handles', () async {
    client.nextRestoredHistory = const [
      UserMessageItem(id: 'user-1', text: 'Imported prompt'),
      AssistantMessageItem(
        id: 'assistant-1',
        text: 'Imported answer',
        complete: true,
      ),
    ];
    final first = manager.importProviderSession(
      provider: 'claude',
      providerHandleId: 'native-1',
      cwd: tempDir.path,
      workspaceId: 'workspace-1',
      labels: const {'source': 'recent'},
    );
    final second = manager.importProviderSession(
      provider: 'claude',
      providerHandleId: 'native-1',
      cwd: tempDir.path,
      workspaceId: 'workspace-1',
    );

    final imported = await first;
    expect(imported.timelineSize, 2);
    expect(imported.reactivated, isFalse);
    expect(imported.summary.sessionId, 'native-1');
    expect(imported.summary.workspaceId, 'workspace-1');
    expect(imported.summary.labels, {'source': 'recent'});
    expect(client.createCalls.single.sessionId, 'native-1');
    await expectLater(
      second,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Provider session is already imported: native-1',
        ),
      ),
    );
  });

  test(
    'imports and clears the frozen parent-agent label on reimport',
    () async {
      client.nextRestoredHistory = const [];
      final first = await manager.importProviderSession(
        provider: 'claude',
        providerHandleId: 'delegated-native',
        cwd: tempDir.path,
        workspaceId: 'workspace-1',
        labels: const {paseoParentAgentIdLabel: ' parent-agent '},
      );
      expect(first.summary.parentAgentId, 'parent-agent');
      expect(first.summary.labels[paseoParentAgentIdLabel], ' parent-agent ');

      await manager.archive(first.summary.agentId);
      final reimported = await manager.importProviderSession(
        provider: 'claude',
        providerHandleId: 'delegated-native',
        cwd: tempDir.path,
        workspaceId: 'workspace-2',
      );
      expect(reimported.summary.parentAgentId, isNull);
      expect(
        reimported.summary.labels,
        isNot(contains(paseoParentAgentIdLabel)),
      );
    },
  );

  test(
    'reactivates archived provider import and rolls back failed resume',
    () async {
      final store = AgentStore(dataDir: tempDir.path);
      await store.save(
        _storedAgent(
          'archived-import',
          title: 'Archived import',
          archived: true,
          sessionId: 'native-archived',
          workspaceId: 'old-workspace',
          items: const [UserMessageItem(id: 'old', text: 'Old history')],
        ),
      );
      await manager.load();
      client.nextRestoredHistory = const [
        UserMessageItem(id: 'restored', text: 'Restored history'),
      ];

      final imported = await manager.importProviderSession(
        provider: 'claude',
        providerHandleId: 'native-archived',
        cwd: '/repo',
        workspaceId: 'new-workspace',
        labels: const {'imported': 'true'},
      );
      expect(imported.summary.agentId, 'archived-import');
      expect(imported.summary.archivedAt, isNull);
      expect(imported.summary.workspaceId, 'new-workspace');
      expect(imported.summary.labels, {'imported': 'true'});
      expect(imported.timelineSize, 1);

      await manager.archive('archived-import');
      client.createSessionError = StateError('resume failed');
      await expectLater(
        manager.importProviderSession(
          provider: 'claude',
          providerHandleId: 'native-archived',
          cwd: '/repo',
          workspaceId: 'failed-workspace',
        ),
        throwsA(isA<StateError>()),
      );
      final rolledBack = manager.get('archived-import');
      expect(rolledBack?.archivedAt, isNotNull);
      expect(rolledBack?.workspaceId, 'new-workspace');
      expect(rolledBack?.runState, AgentRunState.closed);
    },
  );

  test('rejects archived import with a different cwd', () async {
    await AgentStore(dataDir: tempDir.path).save(
      _storedAgent(
        'archived-cwd',
        title: 'Archived cwd',
        archived: true,
        sessionId: 'native-cwd',
      ),
    );
    await manager.load();
    await expectLater(
      manager.importProviderSession(
        provider: 'claude',
        providerHandleId: 'native-cwd',
        cwd: '/different',
        workspaceId: 'workspace-1',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Provider session cwd does not match import cwd: native-cwd',
        ),
      ),
    );
  });

  test(
    'resolves exact ids, unique prefixes, titles, and archived agents',
    () async {
      final store = AgentStore(dataDir: tempDir.path);
      for (final record in [
        _storedAgent('alpha-111111', title: 'Duplicate'),
        _storedAgent('alpha-222222', title: 'Duplicate'),
        _storedAgent('bravo-111111', title: 'Named Agent'),
        _storedAgent('closed-11111', title: 'Archived', archived: true),
      ]) {
        await store.save(record);
      }
      await manager.load();

      expect(manager.resolveIdentifier('alpha-111111').agentId, 'alpha-111111');
      expect(manager.resolveIdentifier('bravo').agentId, 'bravo-111111');
      expect(manager.resolveIdentifier('Named Agent').agentId, 'bravo-111111');
      expect(
        manager.resolveIdentifier('Archived').runState,
        AgentRunState.closed,
      );
      expect(manager.get('closed-11111')?.archivedAt, isNotNull);
      expect(
        () => manager.resolveIdentifier(''),
        throwsA(_rpcMessage('Agent identifier cannot be empty')),
      );
      expect(
        () => manager.resolveIdentifier('alpha'),
        throwsA(
          _rpcMessage(
            'Agent identifier "alpha" is ambiguous '
            '(alpha-11, alpha-22)',
          ),
        ),
      );
      expect(
        () => manager.resolveIdentifier('Duplicate'),
        throwsA(
          _rpcMessage(
            'Agent title "Duplicate" is ambiguous '
            '(alpha-11, alpha-22)',
          ),
        ),
      );
      expect(
        () => manager.resolveIdentifier('missing'),
        throwsA(_rpcMessage('Agent not found: missing')),
      );
      expect(manager.get('missing'), isNull);
    },
  );

  test(
    'persisted internal agents stay out of list and identifier lookup',
    () async {
      final store = AgentStore(dataDir: tempDir.path);
      await store.save(
        _storedAgent(
          'internal-1111',
          title: 'Hidden system task',
          internal: true,
        ),
      );
      await manager.load();

      expect(manager.get('internal-1111'), isNotNull);
      expect(manager.list(includeArchived: true), isEmpty);
      expect(
        () => manager.resolveIdentifier('internal-1111'),
        throwsA(_rpcMessage('Agent not found: internal-1111')),
      );
      expect(
        () => manager.resolveIdentifier('Hidden system task'),
        throwsA(_rpcMessage('Agent not found: Hidden system task')),
      );
    },
  );

  test(
    'live internal agents are runtime-only and suppress global events',
    () async {
      final internal = await manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
        title: 'Internal',
        internal: true,
      );
      final session = client.sessions.single;

      expect(manager.get(internal.agentId), isNotNull);
      expect(manager.list(includeArchived: true), isEmpty);
      expect(states, isEmpty);

      session.emit(const SessionStarted(sessionId: 'internal-session'));
      await pumpEventQueue();
      await manager.prompt(internal.agentId, 'system work');
      session
        ..emit(const AssistantTextDelta(itemId: 'answer', text: 'invisible'))
        ..emit(
          const ProviderSubagentUpserted(
            subagentId: 'hidden-child',
            status: ProviderSubagentStatus.running,
          ),
        )
        ..emit(const TurnCompleted());
      await pumpEventQueue();

      expect(streamed, isEmpty);
      expect(states, isEmpty);
      expect(attentionEvents, isEmpty);
      expect(manager.providerSubagents.list(internal.agentId), isEmpty);

      await manager.dispose();
      final records = await AgentStore(dataDir: tempDir.path).loadAll();
      expect(records, isEmpty);
    },
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

  test(
    'createAgent preserves and forwards exact provider configuration',
    () async {
      final agent = await manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-opus-4-1',
        mode: AgentMode.normal,
        modeId: 'accept-edits',
        thinkingOptionId: 'high',
        featureValues: const {'webSearch': true, 'effort': 'max'},
      );

      expect(agent.currentModeId, 'accept-edits');
      expect(agent.thinkingOptionId, 'high');
      expect(agent.featureValues, {'webSearch': true, 'effort': 'max'});
      expect(client.createCalls.single.modeId, 'accept-edits');
      expect(client.createCalls.single.thinkingOptionId, 'high');
      expect(client.createCalls.single.featureValues, {
        'webSearch': true,
        'effort': 'max',
      });
    },
  );

  test(
    'createAgent stores workspace and worktree ownership across reset',
    () async {
      final agent = await manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
        title: 'Worktree agent',
        workspaceId: 'wks_1',
        projectPath: '/repo/main',
        branch: 'feature/x',
        isWorktree: true,
      );
      expect(agent.workspaceId, 'wks_1');
      expect(agent.projectPath, '/repo/main');
      expect(agent.branch, 'feature/x');
      expect(agent.isWorktree, isTrue);

      final listed = manager.list().singleWhere(
        (a) => a.agentId == agent.agentId,
      );
      expect(listed.workspaceId, 'wks_1');
      expect(listed.projectPath, '/repo/main');
      expect(listed.branch, 'feature/x');
      expect(listed.isWorktree, isTrue);

      await manager.clearConversations(agentId: agent.agentId);
      final reset = manager.list().singleWhere(
        (a) => a.agentId == agent.agentId,
      );
      expect(reset.workspaceId, 'wks_1');
      expect(reset.projectPath, '/repo/main');
      expect(reset.branch, 'feature/x');
      expect(reset.isWorktree, isTrue);
    },
  );

  test('createAgent atomically starts the initial structured prompt', () async {
    client.useStructuredSession = true;
    const images = [AgentPromptImage(data: 'png', mimeType: 'image/png')];
    const attachments = [
      TextAgentAttachment(title: 'Context', text: 'Details'),
    ];

    final agent = await manager.createAgent(
      cwd: tempDir.path,
      provider: 'claude',
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
      initialPrompt: 'Start here',
      clientMessageId: 'client-message-1',
      images: images,
      attachments: attachments,
    );
    await pumpEventQueue();

    final session = client.sessions.single as MockStructuredAgentSession;
    expect(session.structuredPrompts, hasLength(1));
    expect(session.structuredPrompts.single.text, 'Start here');
    expect(session.structuredPrompts.single.images, same(images));
    expect(session.structuredPrompts.single.attachments, same(attachments));
    final userMessage = streamed
        .map((event) => event.item)
        .whereType<UserMessageItem>()
        .single;
    expect(userMessage.id, 'client-message-1');
    expect(userMessage.clientMessageId, 'client-message-1');
    expect(userMessage.text, 'Start here');
    expect(
      manager
          .list()
          .singleWhere((item) => item.agentId == agent.agentId)
          .runState,
      AgentRunState.running,
    );
  });

  test(
    'managed subagent parentage persists and detach is idempotent',
    () async {
      final parent = await createAgent();
      final child = await manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
        title: 'Child',
        parentAgentId: parent.agentId,
      );
      expect(child.parentAgentId, parent.agentId);
      await manager.dispose();

      final restored = AgentManager(
        clients: {'claude': client},
        store: AgentStore(dataDir: tempDir.path),
      );
      await restored.load();
      final restoredChild = restored.list().singleWhere(
        (agent) => agent.agentId == child.agentId,
      );
      expect(restoredChild.parentAgentId, parent.agentId);

      final detached = await restored.detach(child.agentId);
      expect(detached.parentAgentId, isNull);
      expect((await restored.detach(child.agentId)).parentAgentId, isNull);
      await restored.dispose();
    },
  );

  test('creating a child rejects a missing parent', () async {
    await expectLater(
      manager.createAgent(
        cwd: tempDir.path,
        provider: 'claude',
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
        parentAgentId: 'missing',
      ),
      throwsA(isA<RpcException>()),
    );
  });

  test('archiving a parent cascades through managed descendants', () async {
    final parent = await createAgent();
    final child = await manager.createAgent(
      cwd: tempDir.path,
      provider: 'claude',
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
      title: 'Child',
      parentAgentId: parent.agentId,
    );
    final grandchild = await manager.createAgent(
      cwd: tempDir.path,
      provider: 'claude',
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
      title: 'Grandchild',
      parentAgentId: child.agentId,
    );
    states.clear();

    await manager.archive(parent.agentId);

    expect(manager.list(), isEmpty);
    expect(
      client.sessions,
      everyElement(predicate<MockAgentSession>((s) => s.disposed)),
    );
    final records = await AgentStore(dataDir: tempDir.path).loadAll();
    expect(
      records
          .where(
            (record) =>
                record.summary.agentId == parent.agentId ||
                record.summary.agentId == child.agentId ||
                record.summary.agentId == grandchild.agentId,
          )
          .every(
            (record) => record.archived && record.summary.archivedAt != null,
          ),
      isTrue,
    );
    expect(
      states.map((state) => state.agent.agentId),
      containsAll([parent.agentId, child.agentId, grandchild.agentId]),
    );
  });

  test(
    'full flow: create -> prompt -> stream -> permission -> complete',
    () async {
      final agent = await createAgent();
      expect(agent.runState, AgentRunState.initializing);
      expect(agent.updatedAt, isNotNull);
      expect(DateTime.tryParse(agent.updatedAt!), isNotNull);
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
      expect(states.last.agent.updatedAt, isNotNull);
      expect(
        streamed.map((s) => s.item).whereType<UserMessageItem>().single.text,
        'create hello.txt',
      );
      final turnStart = streamed
          .map((s) => s.item)
          .whereType<TurnItem>()
          .single;
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

      session.emit(
        const AssistantMessageComplete(
          itemId: 'm1_0',
          fullText: 'Writing hello.txt now.',
        ),
      );
      await pumpEventQueue();
      final finalText = streamed
          .map((s) => s.item)
          .whereType<AssistantMessageItem>()
          .last;
      expect(finalText.text, 'Writing hello.txt now.');
      expect(finalText.complete, isTrue);

      // -- permission round-trip --
      PermissionDecision? decided;
      session.emit(
        PermissionRequested(
          permissionId: 'perm-req-1',
          toolName: 'Write',
          detail: const WriteDetail(path: 'hello.txt', contentPreview: 'hi'),
          respond:
              (
                decision, {
                message,
                selectedActionId,
                updatedInput,
                updatedPermissions,
                interrupt,
              }) async => decided = decision,
        ),
      );
      await pumpEventQueue();
      expect(states.last.agent.runState, AgentRunState.awaitingPermission);
      expect(permissionRequests.single.$1, agent.agentId);
      expect(permissionRequests.single.$2, 'perm-req-1');
      expect(permissionRequests.single.$3, 'Write');
      expect(attentionEvents.single.$2, AgentAttentionReason.permission);
      final pendingItem = streamed
          .map((s) => s.item)
          .whereType<PermissionItem>()
          .last;
      expect(pendingItem.status, PermissionStatus.pending);

      await manager.respondPermission('perm-req-1', 'allow_always');
      expect(decided, PermissionDecision.allow);
      expect(permissionResolutions.single, (
        'perm-req-1',
        PermissionDecision.allow,
      ));
      final resolvedItem = streamed
          .map((s) => s.item)
          .whereType<PermissionItem>()
          .last;
      expect(resolvedItem.status, PermissionStatus.allowed);
      expect(states.last.agent.runState, AgentRunState.running);

      // -- tool call lifecycle --
      session.emit(
        const ToolCallStarted(
          itemId: 'toolu_1',
          toolName: 'Write',
          status: ToolCallStatus.pending,
          detail: GenericDetail(input: {}),
        ),
      );
      session.emit(
        const ToolCallUpdated(
          itemId: 'toolu_1',
          toolName: 'Write',
          status: ToolCallStatus.success,
          detail: WriteDetail(path: 'hello.txt', contentPreview: 'hi'),
        ),
      );
      await pumpEventQueue();
      final toolItem = streamed
          .map((s) => s.item)
          .whereType<ToolCallItem>()
          .last;
      expect(toolItem.status, ToolCallStatus.success);

      // -- turn complete --
      session.emit(const TurnCompleted());
      await pumpEventQueue();
      expect(states.last.agent.runState, AgentRunState.idle);
      expect(states.last.agent.requiresAttention, isTrue);
      expect(states.last.agent.attentionReason, AgentAttentionReason.finished);
      expect(
        DateTime.tryParse(states.last.agent.attentionTimestamp ?? ''),
        isNotNull,
      );
      expect(attentionEvents.map((event) => event.$2), [
        AgentAttentionReason.permission,
        AgentAttentionReason.finished,
      ]);
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
      final stale = manager.fetchTimeline(
        agent.agentId,
        epoch: 99,
        afterSeq: 3,
      );
      expect(stale.items, hasLength(full.items.length));
    },
  );

  test(
    'prompt preserves attachments in timeline and renders text context',
    () async {
      final agent = await createAgent();
      final session = client.sessions.single;

      await manager.prompt(
        agent.agentId,
        'Please fix this',
        attachments: const [
          TextAgentAttachment(
            title: 'PR review',
            text: 'GitHub pull request review\nAuthor: reviewer',
          ),
        ],
      );

      expect(session.prompts, [
        'Please fix this\n\n'
            'GitHub pull request review\nAuthor: reviewer',
      ]);
      final message = streamed
          .map((event) => event.item)
          .whereType<UserMessageItem>()
          .single;
      expect(message.text, 'Please fix this');
      expect(message.attachments, hasLength(1));
      expect(
        (message.attachments.single as TextAgentAttachment).title,
        'PR review',
      );
    },
  );

  test(
    'prompt keeps structured attachments separate for capable sessions',
    () async {
      client.useStructuredSession = true;
      final agent = await createAgent();
      final session = client.sessions.single as MockStructuredAgentSession;
      const attachments = [
        TextAgentAttachment(
          title: 'Prior chat',
          text: 'Earlier context',
          contextKind: 'chat_history',
        ),
        TextAgentAttachment(title: 'Check logs', text: 'Assertion failed'),
      ];

      const images = [AgentPromptImage(data: 'png', mimeType: 'image/png')];
      await manager.prompt(
        agent.agentId,
        'Fix this',
        images: images,
        attachments: attachments,
      );

      expect(session.prompts, isEmpty);
      expect(session.structuredPrompts, hasLength(1));
      expect(session.structuredPrompts.single.text, 'Fix this');
      expect(session.structuredPrompts.single.images, same(images));
      expect(session.structuredPrompts.single.attachments, same(attachments));
    },
  );

  test('runAndWait returns the completed assistant output', () async {
    final agent = await createAgent();
    final session = client.sessions.single;

    final outcomeFuture = manager.runAndWait(agent.agentId, 'Scheduled task');
    await pumpEventQueue();
    expect(session.prompts, ['Scheduled task']);

    session.emit(
      const AssistantMessageComplete(
        itemId: 'answer',
        fullText: 'Schedule finished',
      ),
    );
    session.emit(const TurnCompleted());

    final outcome = await outcomeFuture;
    expect(outcome.summary.runState, AgentRunState.idle);
    expect(outcome.output, 'Schedule finished');
    expect(outcome.timeline.whereType<UserMessageItem>(), hasLength(1));
    expect(outcome.timeline.whereType<AssistantMessageItem>(), hasLength(1));
  });

  test('waitForAgentEvent returns completion and pending permission', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();

    await manager.prompt(agent.agentId, 'complete this');
    final completed = manager.waitForAgentEvent(
      agent.agentId,
      waitForActive: true,
      timeout: const Duration(seconds: 1),
    );
    session.emit(
      const AssistantMessageComplete(itemId: 'answer', fullText: 'All done'),
    );
    session.emit(const TurnCompleted());
    final completedResult = await completed;
    expect(completedResult.summary.runState, AgentRunState.idle);
    expect(completedResult.lastMessage, 'All done');
    expect(completedResult.permission, isNull);

    await manager.prompt(agent.agentId, 'write this');
    final permission = manager.waitForAgentEvent(
      agent.agentId,
      waitForActive: true,
      timeout: const Duration(seconds: 1),
    );
    session.emit(
      PermissionRequested(
        permissionId: 'wait-permission',
        toolName: 'Write',
        detail: const WriteDetail(path: 'README.md'),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {},
      ),
    );
    final permissionResult = await permission;
    expect(permissionResult.summary.runState, AgentRunState.awaitingPermission);
    expect(permissionResult.permission?.permissionId, 'wait-permission');
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
    expect(states.last.agent.lastUserMessageAt, isNotNull);
    expect(states.last.agent.lastError, 'boom');
    expect(states.last.agent.requiresAttention, isTrue);
    expect(states.last.agent.attentionReason, AgentAttentionReason.error);
    expect(attentionEvents.single.$2, AgentAttentionReason.error);
    final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
    expect(turn.phase, TurnPhase.failed);
    expect(turn.errorMessage, 'boom');
  });

  test(
    'attention clear is durable, idempotent, and resets on a new edge',
    () async {
      final agent = await createAgent();
      final session = client.sessions.single;
      session.emit(const SessionStarted(sessionId: 'sess-1'));
      await pumpEventQueue();

      await manager.prompt(agent.agentId, 'first failure');
      session.emit(const TurnFailed(error: 'boom'));
      await pumpEventQueue();
      expect(states.last.agent.attentionReason, AgentAttentionReason.error);

      final cleared = await manager.clearAttention(agent.agentId);
      expect(cleared.requiresAttention, isFalse);
      expect(cleared.attentionReason, isNull);
      expect(cleared.attentionTimestamp, isNull);
      final stateCount = states.length;
      await manager.clearAttention(agent.agentId);
      expect(states, hasLength(stateCount));

      final records = await AgentStore(dataDir: tempDir.path).loadAll();
      expect(records.single.summary.requiresAttention, isFalse);
      expect(records.single.summary.attentionReason, isNull);

      // Remaining in the same error state is not a new attention edge.
      session.emit(const TurnFailed(error: 'same edge'));
      await pumpEventQueue();
      expect(states, hasLength(stateCount));

      await manager.prompt(agent.agentId, 'second failure');
      session.emit(const TurnFailed(error: 'boom again'));
      await pumpEventQueue();
      expect(states.last.agent.requiresAttention, isTrue);
      expect(states.last.agent.attentionReason, AgentAttentionReason.error);
    },
  );

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
    expect(states.last.agent.lastError, isNull);
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
    session.emit(
      PermissionRequested(
        permissionId: 'perm-2',
        toolName: 'Write',
        detail: const WriteDetail(path: 'x.txt'),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async => decided = decision,
      ),
    );
    await pumpEventQueue();
    expect(states.last.agent.runState, AgentRunState.awaitingPermission);

    await session.exit(1);
    await pumpEventQueue();
    expect(decided, PermissionDecision.deny);
    expect(permissionResolutions.single.$2, PermissionDecision.deny);
    final item = streamed.map((s) => s.item).whereType<PermissionItem>().last;
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
    final archived = manager.list(includeArchived: true).single;
    expect(archived.runState, AgentRunState.closed);
    expect(archived.archivedAt, isNotNull);
    final persisted = (await AgentStore(
      dataDir: tempDir.path,
    ).loadAll()).single;
    expect(persisted.archived, isTrue);
    expect(persisted.summary.runState, AgentRunState.closed);
    await expectLater(
      manager.prompt(agent.agentId, 'hi'),
      throwsA(isA<RpcException>()),
    );
  });

  test(
    'close disposes the live session and retains a closed snapshot',
    () async {
      final agent = await createAgent();
      final session = client.sessions.single;
      session.emit(const SessionStarted(sessionId: 'sess-1'));
      await pumpEventQueue();
      await manager.prompt(agent.agentId, 'long task');

      await manager.close(agent.agentId);

      expect(session.disposed, isTrue);
      expect(manager.get(agent.agentId)?.runState, AgentRunState.closed);
      expect(manager.get(agent.agentId)?.archivedAt, isNull);
      final turn = manager
          .fetchCanonicalTimeline(agent.agentId)
          .rows
          .map((row) => row.item)
          .whereType<TurnItem>()
          .last;
      expect(turn.phase, TurnPhase.canceled);
      final persisted = (await AgentStore(
        dataDir: tempDir.path,
      ).loadAll()).single;
      expect(persisted.archived, isFalse);
      expect(persisted.summary.runState, AgentRunState.closed);
    },
  );

  test('setMode stores the mode for the next session', () async {
    final agent = await createAgent();
    final updated = await manager.setMode(agent.agentId, AgentMode.plan);
    expect(updated.mode, AgentMode.plan);
    expect(states.last.agent.mode, AgentMode.plan);
  });

  test('live config mutations update provider and durable summary', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    final notice = await manager.setModeId(agent.agentId, 'read-only');
    expect(notice!.message, 'mode changed');
    expect(session.configuredMode, 'read-only');
    expect(manager.list().single.mode, AgentMode.plan);
    expect(manager.list().single.currentModeId, 'read-only');

    await manager.setModelId(agent.agentId, '  gpt-next  ');
    expect(session.configuredModel, 'gpt-next');
    expect(manager.list().single.model, 'gpt-next');
    await manager.setModelId(agent.agentId, ' ');
    expect(session.configuredModel, isNull);
    expect(manager.list().single.model, isEmpty);

    expect(await manager.setThinkingOption(agent.agentId, ' high '), isNull);
    expect(session.configuredThinking, 'high');
    expect(manager.list().single.thinkingOptionId, 'high');
    await manager.setThinkingOption(agent.agentId, '');
    expect(manager.list().single.thinkingOptionId, isNull);

    await manager.setFeature(agent.agentId, 'webSearch', true);
    expect(session.configuredFeatures, {'webSearch': true});
    expect(manager.list().single.featureValues, {'webSearch': true});
    await manager.setModeId(agent.agentId, 'provider-dynamic-mode');
    expect(session.configuredMode, 'provider-dynamic-mode');
    expect(manager.list().single.mode, AgentMode.normal);
    expect(manager.list().single.currentModeId, 'provider-dynamic-mode');
  });

  test('rename stores the new title and broadcasts it', () async {
    final agent = await createAgent();
    final updated = await manager.rename(agent.agentId, 'Renamed agent');
    expect(updated.title, 'Renamed agent');
    expect(states.last.agent.title, 'Renamed agent');

    final listed = manager.list().singleWhere(
      (a) => a.agentId == agent.agentId,
    );
    expect(listed.title, 'Renamed agent');
  });

  test('persists and reloads agents across manager restarts', () async {
    final agent = await createAgent();
    final session = client.sessions.single;
    session.emit(const SessionStarted(sessionId: 'sess-1'));
    await pumpEventQueue();
    await manager.prompt(agent.agentId, 'hello');
    session.emit(
      const AssistantMessageComplete(itemId: 'm1_0', fullText: 'hi back'),
    );
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

  test(
    'createAgent propagates a session-start failure as RpcException',
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
    },
  );

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
    expect(states.last.agent.lastError, contains('failed to restart session'));
    final error = streamed.map((s) => s.item).whereType<ErrorItem>().last;
    expect(error.message, contains('failed to restart session'));
  });

  test(
    'session.prompt() throwing marks the turn failed and state error',
    () async {
      final agent = await createAgent();
      final session = client.sessions.single;
      session.emit(const SessionStarted(sessionId: 'sess-1'));
      await pumpEventQueue();

      session.promptError = StateError('provider rejected the prompt');
      await manager.prompt(agent.agentId, 'do a thing');

      expect(states.last.agent.runState, AgentRunState.error);
      expect(states.last.agent.lastError, contains('provider rejected'));
      final turn = streamed.map((s) => s.item).whereType<TurnItem>().last;
      expect(turn.phase, TurnPhase.failed);
      final error = streamed.map((s) => s.item).whereType<ErrorItem>().last;
      expect(error.message, contains('prompt failed'));
    },
  );

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

  test(
    'reasoning deltas and completion map to reasoning timeline items',
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

      session.emit(
        const ReasoningComplete(itemId: 'r1', fullText: 'pondering'),
      );
      await pumpEventQueue();
      final complete = streamed
          .map((s) => s.item)
          .whereType<ReasoningItem>()
          .last;
      expect(complete.text, 'pondering');
      expect(complete.complete, isTrue);
    },
  );

  test(
    'SessionExited while interrupted and a turn is open cancels the turn',
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
    },
  );

  test(
    'usage updates state and compaction lifecycle upserts timeline',
    () async {
      final agent = await createAgent();
      final session = client.sessions.single;
      session.emit(
        const UsageUpdated(
          usage: AgentUsage(
            inputTokens: 20,
            outputTokens: 8,
            contextWindowMaxTokens: 200000,
            contextWindowUsedTokens: 50000,
          ),
        ),
      );
      session.emit(
        const CompactionUpdated(
          itemId: 'compact',
          status: CompactionStatus.loading,
          trigger: CompactionTrigger.auto,
          preTokens: 190000,
        ),
      );
      session.emit(
        const CompactionUpdated(
          itemId: 'compact',
          status: CompactionStatus.completed,
          trigger: CompactionTrigger.auto,
          preTokens: 190000,
        ),
      );
      await pumpEventQueue();

      expect(manager.list().single.lastUsage?.inputTokens, 20);
      expect(states.last.agent.lastUsage?.contextWindowUsedTokens, 50000);
      final compactions = streamed
          .map((event) => event.item)
          .whereType<CompactionItem>()
          .toList();
      expect(compactions, hasLength(2));
      expect(compactions.first.status, CompactionStatus.loading);
      expect(compactions.last.status, CompactionStatus.completed);
      expect(compactions.last.trigger, CompactionTrigger.auto);

      await manager.dispose();
      final reloaded = AgentManager(
        clients: {'claude': client},
        store: AgentStore(dataDir: tempDir.path),
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.list().single.lastUsage?.outputTokens, 8);
      expect(
        reloaded
            .fetchTimeline(agent.agentId)
            .items
            .whereType<CompactionItem>()
            .single
            .status,
        CompactionStatus.completed,
      );
    },
  );

  test(
    'clearConversations() wipes every agent, nulls sessionId, persists',
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
      expect(manager.list().map((s) => s.sessionId).toSet(), {
        'sess-a',
        'sess-b',
      });
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
      expect(newStates.map((s) => s.agent.agentId).toSet(), {
        a.agentId,
        b.agentId,
      });

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
    },
  );

  test(
    'provider-native restored history authoritatively rebuilds the epoch',
    () async {
      final agent = await createAgent();
      final first = client.sessions.single;
      first.emit(
        const AssistantMessageComplete(
          itemId: 'stale',
          fullText: 'stale local',
        ),
      );
      await pumpEventQueue();
      final oldEpoch = manager.fetchTimeline(agent.agentId).epoch;
      await first.exit();

      client.nextRestoredHistory = const [
        UserMessageItem(id: 'native-user', text: 'native prompt'),
        AssistantMessageItem(
          id: 'native-assistant',
          text: 'native answer',
          complete: true,
        ),
      ];
      await manager.prompt(agent.agentId, 'continue');
      final rebuilt = manager.fetchTimeline(agent.agentId);

      expect(rebuilt.epoch, oldEpoch + 1);
      expect(rebuilt.items.where((item) => item.id == 'stale'), isEmpty);
      expect(
        rebuilt.items.where((item) => item.id == 'native-user'),
        hasLength(1),
      );
      expect(
        rebuilt.items.where((item) => item.id == 'native-assistant'),
        hasLength(1),
      );
      expect(rebuilt.items.whereType<UserMessageItem>().last.text, 'continue');
    },
  );

  test('restores and updates provider-managed subagent replicas', () async {
    client.nextRestoredProviderSubagents = const [
      RestoredProviderSubagent(
        id: 'child',
        title: 'Research',
        status: ProviderSubagentStatus.running,
        toolCallId: 'call',
        timeline: [
          AssistantMessageItem(id: 'answer', text: 'restored', complete: true),
        ],
      ),
    ];
    final agent = await createAgent();
    expect(
      manager.providerSubagents.list(agent.agentId).single.title,
      'Research',
    );
    expect(
      manager.providerSubagents.timeline(agent.agentId, 'child')!.rows,
      hasLength(1),
    );

    final session = client.sessions.single;
    session.emit(
      const ProviderSubagentUpserted(
        subagentId: 'child',
        status: ProviderSubagentStatus.completed,
      ),
    );
    session.emit(
      const ProviderSubagentTimelineChanged(
        subagentId: 'child',
        item: AssistantMessageItem(
          id: 'answer',
          text: 'live final',
          complete: true,
        ),
      ),
    );
    await pumpEventQueue();

    expect(
      manager.providerSubagents.list(agent.agentId).single.status,
      ProviderSubagentStatus.completed,
    );
    final rows = manager.providerSubagents
        .timeline(agent.agentId, 'child')!
        .rows;
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.seq), [1, 2]);
    expect((rows.last.item as AssistantMessageItem).text, 'live final');
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

  test(
    'clearConversations() with no agents returns 0 and is a no-op',
    () async {
      expect(await manager.clearConversations(), 0);
      expect(states, isEmpty);
      expect(streamed, isEmpty);
    },
  );
}
