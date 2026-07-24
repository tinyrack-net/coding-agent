/// [AgentSession] is a pure abstract interface with no shared implementation;
/// these tests pin down the contract shape (method signatures, stream
/// semantics) using a minimal hand-written fake, mirroring how real provider
/// sessions (Claude/Codex) are expected to behave.
library;

import 'dart:async';

import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:test/test.dart';

class FakeAgentSession implements AgentSession {
  final _controller = StreamController<ProviderEvent>.broadcast();
  final List<String> prompts = [];
  int interruptCalls = 0;
  bool disposed = false;

  @override
  Stream<ProviderEvent> get events => _controller.stream;

  @override
  Future<void> prompt(String text) async => prompts.add(text);

  @override
  Future<void> interrupt() async => interruptCalls++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }

  void emit(ProviderEvent event) => _controller.add(event);
}

void main() {
  test('events is a broadcast-style stream that can be listened to '
      'independently of prompt/interrupt calls', () async {
    final session = FakeAgentSession();
    final received = <ProviderEvent>[];
    session.events.listen(received.add);

    session.emit(const SessionStarted(sessionId: 's1'));
    await session.prompt('hello');
    session.emit(const TurnCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(session.prompts, ['hello']);
    expect(received, [
      isA<SessionStarted>(),
      isA<TurnCompleted>(),
    ]);
  });

  test('interrupt can be called independent of prompt state', () async {
    final session = FakeAgentSession();
    await session.interrupt();
    expect(session.interruptCalls, 1);
  });

  test('dispose marks the session disposed and closes the events stream',
      () async {
    final session = FakeAgentSession();
    final done = session.events.drain<void>();
    await session.dispose();
    expect(session.disposed, isTrue);
    await done;
  });
}
