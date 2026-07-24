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
      sessionId: 's1',
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
      expect(decoded.sessionId, 's1');
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
      expect(decoded.sessionId, isNull);
      expect(decoded.projectPath, isNull);
      expect(decoded.branch, isNull);
      expect(decoded.isWorktree, isFalse);
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
        projectPath: 'C:/repo',
        branch: 'feature/x',
        isWorktree: true,
      );
      final json = worktreeAgent.toJson();
      expect(json['projectPath'], 'C:/repo');
      expect(json['branch'], 'feature/x');
      expect(json['isWorktree'], isTrue);

      final decoded = AgentSummary.fromJson(roundTrip(json));
      expect(decoded.projectPath, 'C:/repo');
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
    });

    test('copyWith with no args keeps original values', () {
      final same = full.copyWith();
      expect(same.title, full.title);
      expect(same.mode, full.mode);
      expect(same.runState, full.runState);
      expect(same.sessionId, full.sessionId);
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
      final decoded =
          TimelineFetchResponse.fromJson(roundTrip(response.toJson()));
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
      final decoded =
          AgentConversationClearResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.cleared, 3);
    });

    test('fromJson defaults to 0 when cleared is missing', () {
      final decoded = AgentConversationClearResponse.fromJson(const {});
      expect(decoded.cleared, 0);
    });
  });
}
