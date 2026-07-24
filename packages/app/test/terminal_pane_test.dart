import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/terminal_providers.dart';
import 'package:coding_agent_app/widgets/terminal_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Demo agent',
  cwd: '/work/demo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

/// Scriptable in-memory daemon: answers terminal RPCs and records frames
/// the client would have sent over the socket.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final frames = StreamController<TerminalFrame>.broadcast();
  final fakeEvents = StreamController<RpcEvent>.broadcast();
  final sentFrames = <TerminalFrame>[];
  final requests = <(String, Map<String, Object?>)>[];

  /// When set, `terminal.create.request` throws this instead of responding.
  Object? createError;

  /// When true, the create response omits `terminalId` (malformed).
  bool malformedCreateResponse = false;

  /// When true, the subscribe response omits `slotId` (malformed).
  bool malformedSubscribeResponse = false;

  /// When set, `terminal.create.request` resolves from this completer
  /// instead of immediately, so a test can rebuild the provider (bumping its
  /// generation) while the request is still in flight.
  Completer<Map<String, Object?>>? pendingCreate;

  int _terminalCounter = 0;

  @override
  Stream<TerminalFrame> get terminalFrames => frames.stream;

  @override
  Stream<RpcEvent> get events => fakeEvents.stream;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  void sendTerminalFrame(TerminalFrame frame) => sentFrames.add(frame);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.terminalCreateRequest) {
      final error = createError;
      if (error != null) throw error;
      final pending = pendingCreate;
      if (pending != null) return pending.future;
      if (malformedCreateResponse) {
        return {
          'terminal': {'shell': 'bash'},
        };
      }
      _terminalCounter++;
      return {
        'terminal': {
          'terminalId': 'term-$_terminalCounter',
          'cwd': payload['cwd'],
          'shell': 'bash',
        },
      };
    }
    return switch (type) {
      MessageTypes.agentListRequest => {
          'agents': [_agent.toJson()],
        },
      MessageTypes.terminalSubscribeRequest =>
        malformedSubscribeResponse ? const {} : {'slotId': 7},
      _ => const {},
    };
  }
}

TerminalFrame _daemonFrame(TerminalOpcode opcode, String text) => TerminalFrame(
      opcode: opcode,
      slotId: 7,
      payload: Uint8List.fromList(utf8.encode(text)),
    );

void main() {
  testWidgets('terminal pane streams daemon output and sends input frames',
      (tester) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    // Let create + subscribe complete.
    await tester.pump();
    await tester.pump();

    final types = fake.requests.map((r) => r.$1).toList();
    expect(types, contains(MessageTypes.terminalCreateRequest));
    expect(types, contains(MessageTypes.terminalSubscribeRequest));

    final session = container.read(terminalSessionProvider('a1'));
    expect(session.status, TerminalSessionStatus.running);

    // Daemon replays scrollback (snapshot), then live output.
    fake.frames.add(_daemonFrame(TerminalOpcode.snapshot, 'hello-snapshot\r\n'));
    fake.frames.add(_daemonFrame(TerminalOpcode.output, 'live-output'));
    await tester.pump();

    final bufferText = session.terminal.buffer.getText();
    expect(bufferText, contains('hello-snapshot'));
    expect(bufferText, contains('live-output'));

    // Typing into the terminal produces an input frame with the slotId.
    fake.sentFrames.clear();
    session.terminal.textInput('ls');
    final inputs = fake.sentFrames
        .where((f) => f.opcode == TerminalOpcode.input)
        .toList();
    expect(inputs, hasLength(1));
    expect(inputs.single.slotId, 7);
    expect(utf8.decode(inputs.single.payload), 'ls');

    // The daemon terminal was created in the agent's cwd.
    final createPayload = fake.requests
        .firstWhere((r) => r.$1 == MessageTypes.terminalCreateRequest)
        .$2;
    expect(createPayload['cwd'], '/work/demo');

    // A terminal.exited broadcast shows the banner with a restart action.
    fake.fakeEvents.add(const RpcEvent(
      type: MessageTypes.terminalExitedEvent,
      payload: {'terminalId': 'term-1', 'exitCode': 0},
    ));
    await tester.pump();
    expect(find.textContaining('Terminal exited'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    // Tapping Restart invalidates the session, which starts a brand-new
    // daemon terminal.
    fake.requests.clear();
    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.pump();

    expect(
      fake.requests.any((r) => r.$1 == MessageTypes.terminalCreateRequest),
      isTrue,
    );
    final restarted = container.read(terminalSessionProvider('a1'));
    expect(restarted.status, TerminalSessionStatus.running);
  });

  testWidgets('a malformed create response (missing terminalId) surfaces as '
      'an error banner with a restart action', (tester) async {
    final fake = FakeDaemonClient()..malformedCreateResponse = true;
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider('a1'));
    expect(session.status, TerminalSessionStatus.error);
    expect(find.textContaining('Terminal failed'), findsOneWidget);
    expect(find.textContaining('malformed create response'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    // Restarting retries (still malformed, so it stays in the error state,
    // but a fresh create request is issued).
    fake.requests.clear();
    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.pump();
    expect(
      fake.requests.any((r) => r.$1 == MessageTypes.terminalCreateRequest),
      isTrue,
    );
  });

  testWidgets('a malformed subscribe response (missing slotId) surfaces as '
      'an error', (tester) async {
    final fake = FakeDaemonClient()..malformedSubscribeResponse = true;
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider('a1'));
    expect(session.status, TerminalSessionStatus.error);
    expect(find.textContaining('malformed subscribe response'), findsOneWidget);
  });

  testWidgets('an exception from the daemon while creating the terminal '
      'surfaces as an error', (tester) async {
    final fake = FakeDaemonClient()..createError = StateError('daemon down');
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider('a1'));
    expect(session.status, TerminalSessionStatus.error);
    expect(session.errorMessage, contains('daemon down'));
  });

  testWidgets(
      'a create response that lands after the session was rebuilt (stale '
      'generation) kills the leaked daemon-side terminal instead of adopting '
      'it', (tester) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    final pending = Completer<Map<String, Object?>>();
    fake.pendingCreate = pending;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    // Let the build-time `Future.microtask(() => _start(...))` run and reach
    // (and suspend on) the pending create request.
    await tester.pump();

    // Rebuild the session before the create request resolves (bumping the
    // generation counter), the same way `restart()` does.
    fake.pendingCreate = null;
    container.read(terminalSessionProvider('a1').notifier).restart();
    await tester.pump();
    await tester.pump();

    // Now let the stale request resolve with a terminalId from the old
    // generation.
    pending.complete({
      'terminal': {'terminalId': 'stale-term', 'cwd': '/work/demo'},
    });
    await tester.pump();
    await tester.pump();

    final killRequest = fake.requests.firstWhere(
      (r) => r.$1 == MessageTypes.terminalKillRequest,
    );
    expect(killRequest.$2['terminalId'], 'stale-term');
  });

  testWidgets(
      'archiving the agent shuts down its terminal session (unsubscribe + '
      'kill) and invalidates the provider', (tester) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalPane(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.exists(terminalSessionProvider('a1')), isTrue);

    fake.requests.clear();
    await container.read(agentActionsProvider).archive('a1');

    expect(
      fake.requests.any((r) => r.$1 == MessageTypes.terminalUnsubscribeRequest),
      isTrue,
    );
    expect(
      fake.requests.any((r) => r.$1 == MessageTypes.terminalKillRequest),
      isTrue,
    );
  });
}
