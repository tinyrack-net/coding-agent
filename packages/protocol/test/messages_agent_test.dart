import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('AgentSummary', () {
    const full = AgentSummary(
      agentId: 'a1',
      title: 'Fix bug',
      cwd: 'C:/repo',
      provider: 'claude',
      model: 'sonnet',
      mode: AgentMode.plan,
      runState: AgentRunState.running,
      createdAtMs: 123,
      updatedAt: '2026-07-26T01:02:03.000Z',
      sessionId: 's1',
      workspaceId: 'wks_1',
      parentAgentId: 'parent-1',
      requiresAttention: true,
      attentionReason: AgentAttentionReason.error,
      attentionTimestamp: '2026-07-25T23:59:00.000Z',
      archivedAt: '2026-07-26T00:00:00.000Z',
      currentModeId: 'acceptEdits',
      featureValues: {'fast_mode': true},
      lastUserMessageAt: '2026-07-26T01:01:00.000Z',
      lastError: 'provider failed',
      labels: {'source': 'schedule'},
    );

    test('round-trips with all fields', () {
      final decoded = AgentSummary.fromJson(roundTrip(full.toJson()));
      expect(decoded.agentId, 'a1');
      expect(decoded.title, 'Fix bug');
      expect(decoded.cwd, 'C:/repo');
      expect(decoded.provider, 'claude');
      expect(decoded.model, 'sonnet');
      expect(decoded.mode, AgentMode.plan);
      expect(decoded.runState, AgentRunState.running);
      expect(decoded.createdAtMs, 123);
      expect(decoded.updatedAt, '2026-07-26T01:02:03.000Z');
      expect(decoded.sessionId, 's1');
      expect(decoded.workspaceId, 'wks_1');
      expect(decoded.parentAgentId, 'parent-1');
      expect(decoded.requiresAttention, isTrue);
      expect(decoded.attentionReason, AgentAttentionReason.error);
      expect(decoded.attentionTimestamp, '2026-07-25T23:59:00.000Z');
      expect(decoded.archivedAt, '2026-07-26T00:00:00.000Z');
      expect(decoded.currentModeId, 'acceptEdits');
      expect(decoded.featureValues, {'fast_mode': true});
      expect(decoded.lastUserMessageAt, '2026-07-26T01:01:00.000Z');
      expect(decoded.lastError, 'provider failed');
      expect(decoded.labels, {'source': 'schedule'});
    });

    test('omits sessionId from json when null', () {
      const noSession = AgentSummary(
        agentId: 'a2',
        title: 't',
        cwd: 'c',
        provider: 'codex',
        model: 'm',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
      );
      expect(noSession.toJson().containsKey('sessionId'), isFalse);
      final decoded = AgentSummary.fromJson(noSession.toJson());
      expect(decoded.sessionId, isNull);
      expect(decoded.workspaceId, isNull);
    });

    test('fromJson applies defaults for missing optional fields', () {
      final decoded = AgentSummary.fromJson({'agentId': 'a3'});
      expect(decoded.agentId, 'a3');
      expect(decoded.title, '');
      expect(decoded.cwd, '');
      expect(decoded.provider, 'claude');
      expect(decoded.model, '');
      expect(decoded.mode, AgentMode.normal);
      expect(decoded.runState, AgentRunState.idle);
      expect(decoded.createdAtMs, 0);
      expect(decoded.updatedAt, isNull);
      expect(decoded.sessionId, isNull);
      expect(decoded.projectPath, isNull);
      expect(decoded.branch, isNull);
      expect(decoded.isWorktree, isFalse);
      expect(decoded.parentAgentId, isNull);
      expect(decoded.requiresAttention, isFalse);
      expect(decoded.attentionReason, isNull);
      expect(decoded.attentionTimestamp, isNull);
      expect(decoded.archivedAt, isNull);
      expect(decoded.currentModeId, isNull);
      expect(decoded.featureValues, isEmpty);
      expect(decoded.lastUserMessageAt, isNull);
      expect(decoded.lastError, isNull);
      expect(decoded.labels, isEmpty);
    });

    test('round-trips worktree fields and omits isWorktree when false', () {
      const worktreeAgent = AgentSummary(
        agentId: 'a4',
        title: 'Worktree agent',
        cwd: 'C:/worktrees/repo-feature-x',
        provider: 'claude',
        model: 'sonnet',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
        workspaceId: 'wks_4',
        projectPath: 'C:/repo',
        branch: 'feature/x',
        isWorktree: true,
      );
      final json = worktreeAgent.toJson();
      expect(json['projectPath'], 'C:/repo');
      expect(json['workspaceId'], 'wks_4');
      expect(json['branch'], 'feature/x');
      expect(json['isWorktree'], isTrue);

      final decoded = AgentSummary.fromJson(roundTrip(json));
      expect(decoded.projectPath, 'C:/repo');
      expect(decoded.workspaceId, 'wks_4');
      expect(decoded.branch, 'feature/x');
      expect(decoded.isWorktree, isTrue);

      expect(full.toJson().containsKey('isWorktree'), isFalse);
    });

    test('fromJson throws when agentId missing', () {
      expect(() => AgentSummary.fromJson(const {}), throwsA(anything));
    });

    test('fromJson throws on unknown enum value', () {
      expect(
        () => AgentSummary.fromJson({'agentId': 'a', 'mode': 'bogus'}),
        throwsArgumentError,
      );
    });

    test('copyWith overrides only given fields', () {
      final updated = full.copyWith(
        runState: AgentRunState.error,
        sessionId: 's2',
      );
      expect(updated.agentId, full.agentId);
      expect(updated.title, full.title);
      expect(updated.runState, AgentRunState.error);
      expect(updated.sessionId, 's2');
      expect(updated.parentAgentId, 'parent-1');
      expect(updated.requiresAttention, isTrue);
      expect(updated.attentionReason, AgentAttentionReason.error);
      expect(updated.lastError, 'provider failed');
    });

    test('copyWith with no args keeps original values', () {
      final same = full.copyWith();
      expect(same.title, full.title);
      expect(same.mode, full.mode);
      expect(same.runState, full.runState);
      expect(same.sessionId, full.sessionId);
      expect(same.parentAgentId, full.parentAgentId);
      expect(same.attentionReason, full.attentionReason);
      expect(same.lastUserMessageAt, full.lastUserMessageAt);
      expect(same.lastError, full.lastError);
      expect(same.labels, full.labels);
    });

    test('copyWith can detach a child and update attention', () {
      final detached = full.copyWith(
        clearParentAgentId: true,
        requiresAttention: false,
        clearAttention: true,
      );
      expect(detached.parentAgentId, isNull);
      expect(detached.requiresAttention, isFalse);
      expect(detached.attentionReason, isNull);
      expect(detached.attentionTimestamp, isNull);
      final recovered = detached.copyWith(lastError: null);
      expect(recovered.lastError, isNull);
    });

    test('serializes cleared attention as explicit null wire fields', () {
      const summary = AgentSummary(
        agentId: 'clear',
        title: '',
        cwd: '',
        provider: 'codex',
        model: '',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
      );
      expect(summary.toJson()['requiresAttention'], isFalse);
      expect(summary.toJson().containsKey('attentionReason'), isTrue);
      expect(summary.toJson()['attentionReason'], isNull);
      expect(summary.toJson()['attentionTimestamp'], isNull);
    });
  });

  group('AgentStreamPayload', () {
    test('round-trips with a timeline item', () {
      const payload = AgentStreamPayload(
        agentId: 'a1',
        epoch: 2,
        seq: 5,
        item: UserMessageItem(id: 'i1', text: 'hi'),
      );
      final decoded = AgentStreamPayload.fromJson(roundTrip(payload.toJson()));
      expect(decoded.agentId, 'a1');
      expect(decoded.epoch, 2);
      expect(decoded.seq, 5);
      expect(decoded.item, isA<UserMessageItem>());
      expect((decoded.item as UserMessageItem).text, 'hi');
    });

    test('fromJson defaults epoch/seq to 0 when missing', () {
      final decoded = AgentStreamPayload.fromJson({
        'agentId': 'a1',
        'item': {'id': 'i1', 'kind': 'user_message', 'text': 'x'},
      });
      expect(decoded.epoch, 0);
      expect(decoded.seq, 0);
    });

    test('fromJson throws when item is missing', () {
      expect(
        () => AgentStreamPayload.fromJson({'agentId': 'a1'}),
        throwsA(anything),
      );
    });
  });

  group('AgentStatePayload', () {
    test('round-trips agent summary', () {
      const summary = AgentSummary(
        agentId: 'a1',
        title: 't',
        cwd: 'c',
        provider: 'claude',
        model: 'm',
        mode: AgentMode.fullAccess,
        runState: AgentRunState.awaitingPermission,
        createdAtMs: 42,
      );
      const payload = AgentStatePayload(agent: summary);
      final decoded = AgentStatePayload.fromJson(roundTrip(payload.toJson()));
      expect(decoded.agent.agentId, 'a1');
      expect(decoded.agent.mode, AgentMode.fullAccess);
      expect(decoded.agent.runState, AgentRunState.awaitingPermission);
    });

    test('round-trips complete Paseo usage on the agent summary', () {
      const usage = AgentUsage(
        inputTokens: 10,
        cachedInputTokens: 3,
        outputTokens: 4,
        totalCostUsd: 0.012,
        contextWindowMaxTokens: 200000,
        contextWindowUsedTokens: 42000,
      );
      const summary = AgentSummary(
        agentId: 'usage',
        title: 'Usage',
        cwd: '/work',
        provider: 'codex',
        model: 'gpt',
        mode: AgentMode.normal,
        runState: AgentRunState.running,
        createdAtMs: 1,
        lastUsage: usage,
      );
      final decoded = AgentSummary.fromJson(roundTrip(summary.toJson()));
      expect(decoded.lastUsage?.inputTokens, 10);
      expect(decoded.lastUsage?.cachedInputTokens, 3);
      expect(decoded.lastUsage?.outputTokens, 4);
      expect(decoded.lastUsage?.totalCostUsd, 0.012);
      expect(decoded.lastUsage?.contextWindowMaxTokens, 200000);
      expect(decoded.lastUsage?.contextWindowUsedTokens, 42000);
      expect(decoded.copyWith(title: 'new').lastUsage?.inputTokens, 10);
    });

    test('fromJson throws when agent key missing', () {
      expect(() => AgentStatePayload.fromJson(const {}), throwsA(anything));
    });
  });

  group('TimelineFetchResponse', () {
    test('round-trips with multiple items', () {
      const response = TimelineFetchResponse(
        epoch: 1,
        lastSeq: 10,
        items: [
          UserMessageItem(id: 'i1', text: 'hi'),
          ErrorItem(id: 'i2', message: 'boom'),
        ],
      );
      final decoded = TimelineFetchResponse.fromJson(
        roundTrip(response.toJson()),
      );
      expect(decoded.epoch, 1);
      expect(decoded.lastSeq, 10);
      expect(decoded.items, hasLength(2));
      expect(decoded.items[0], isA<UserMessageItem>());
      expect(decoded.items[1], isA<ErrorItem>());
    });

    test('fromJson defaults to empty items list when missing', () {
      final decoded = TimelineFetchResponse.fromJson(const {});
      expect(decoded.epoch, 0);
      expect(decoded.lastSeq, 0);
      expect(decoded.items, isEmpty);
    });
  });

  group('AgentConversationClearResponse', () {
    test('round-trips the cleared count', () {
      const response = AgentConversationClearResponse(cleared: 3);
      final decoded = AgentConversationClearResponse.fromJson(
        roundTrip(response.toJson()),
      );
      expect(decoded.cleared, 3);
    });

    test('fromJson defaults to 0 when cleared is missing', () {
      final decoded = AgentConversationClearResponse.fromJson(const {});
      expect(decoded.cleared, 0);
    });
  });
}
