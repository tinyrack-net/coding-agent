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
    return switch (type) {
      MessageTypes.agentListRequest => {
          'agents': [_agent.toJson()],
        },
      MessageTypes.terminalCreateRequest => {
          'terminal': {
            'terminalId': 'term-1',
            'cwd': payload['cwd'],
            'shell': 'bash',
          },
        },
      MessageTypes.terminalSubscribeRequest => {'slotId': 7},
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
  });
}
