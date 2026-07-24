/// [AgentClient] is a pure abstract interface (factory for [AgentSession]s);
/// these tests pin down the contract shape using a minimal hand-written fake.
library;

import 'dart:async';

import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

class FakeSession implements AgentSession {
  final _controller = StreamController<ProviderEvent>.broadcast();
  @override
  Stream<ProviderEvent> get events => _controller.stream;
  @override
  Future<void> prompt(String text) async {}
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> dispose() async => _controller.close();
}

class FakeClient implements AgentClient {
  final List<({String cwd, String model, AgentMode mode, String? sessionId})>
      calls = [];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    calls.add((cwd: cwd, model: model, mode: mode, sessionId: sessionId));
    return FakeSession();
  }
}

void main() {
  test('createSession forwards all arguments and returns a session',
      () async {
    final client = FakeClient();
    final session = await client.createSession(
      cwd: '/tmp/work',
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
    );

    expect(session, isA<AgentSession>());
    expect(client.calls.single.cwd, '/tmp/work');
    expect(client.calls.single.model, 'claude-sonnet-5');
    expect(client.calls.single.mode, AgentMode.normal);
    expect(client.calls.single.sessionId, isNull);
  });

  test('createSession passes through an optional sessionId to resume',
      () async {
    final client = FakeClient();
    await client.createSession(
      cwd: '/tmp/work',
      model: 'gpt-5.4',
      mode: AgentMode.plan,
      sessionId: 'prior-session',
    );
    expect(client.calls.single.sessionId, 'prior-session');
    expect(client.calls.single.mode, AgentMode.plan);
  });
}
