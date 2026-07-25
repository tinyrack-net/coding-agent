import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/composer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Demo',
  cwd: '/work',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  /// Only prompt/interrupt calls the test cares about; the incidental
  /// `agent.list.request` that `AgentsNotifier` issues on connect is handled
  /// separately below so it doesn't pollute assertions.
  final requests = <(String, Map<String, Object?>)>[];
  Object? requestError;
  AgentSummary? knownAgent;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentListRequest) {
      final agent = knownAgent;
      return {
        'agents': agent == null ? const [] : [agent.toJson()],
      };
    }
    requests.add((type, payload));
    final error = requestError;
    if (error != null) throw error;
    return const {};
  }
}

Future<ProviderContainer> pumpComposer(
  WidgetTester tester,
  FakeDaemonClient client, {
  AgentSummary agent = _agent,
}) async {
  client.knownAgent = agent;
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  container.read(agentsProvider.notifier).upsert(agent);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const FluentApp(
        home: ScaffoldPage(content: Composer(agentId: 'a1')),
      ),
    ),
  );
  // Let AgentsNotifier's connect-triggered agent.list.request refresh settle.
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('typing and sending a message prompts the agent and clears '
      'the field', (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'hello agent');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (type, payload) = client.requests.single;
    expect(type, MessageTypes.agentPromptRequest);
    expect(payload, <String, Object?>{'agentId': 'a1', 'text': 'hello agent'});

    final textField = tester.widget<TextBox>(find.byType(TextBox));
    expect(textField.controller!.text, isEmpty);
  });

  testWidgets('leading/trailing whitespace is trimmed before sending',
      (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '  hi  ');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (_, payload) = client.requests.single;
    expect(payload['text'], 'hi');
  });

  testWidgets('sending with empty/whitespace-only text does nothing',
      (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '   ');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.requests, isEmpty);
  });

  testWidgets('a failed send restores the text and shows a snackbar',
      (tester) async {
    final client = FakeDaemonClient()..requestError = StateError('offline');
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'will fail');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final textField = tester.widget<TextBox>(find.byType(TextBox));
    expect(textField.controller!.text, 'will fail');
    expect(find.textContaining('Failed to send prompt'), findsOneWidget);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('busy (running) agent shows a stop button instead of send',
      (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );

    expect(find.byIcon(FluentIcons.stop), findsOneWidget);
    expect(find.byIcon(FluentIcons.send), findsNothing);
  });

  testWidgets('tapping stop while busy sends an interrupt request',
      (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.awaitingPermission),
    );

    await tester.tap(find.byIcon(FluentIcons.stop));
    await tester.pump(const Duration(milliseconds: 150));

    final (type, payload) = client.requests.single;
    expect(type, MessageTypes.agentInterruptRequest);
    expect(payload, <String, Object?>{'agentId': 'a1'});
  });

  testWidgets('Enter sends the message; Shift+Enter inserts a newline',
      (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), 'line one');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 150));

    // Shift+Enter must not have sent a prompt.
    expect(client.requests, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.requests, hasLength(1));
    expect(client.requests.single.$1, MessageTypes.agentPromptRequest);
  });

  testWidgets('a failed interrupt shows a snackbar', (tester) async {
    final client = FakeDaemonClient()..requestError = StateError('offline');
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );

    await tester.tap(find.byIcon(FluentIcons.stop));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to interrupt'), findsOneWidget);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });
}
