import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
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

/// Scriptable fake covering everything AgentChatScreen's three tabs touch:
/// agent list (for the header), the timeline fetch, the diff fetch, and the
/// terminal create/subscribe handshake (so the Terminal tab doesn't hang).
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final eventsController = StreamController<RpcEvent>.broadcast();
  final requests = <(String, Map<String, Object?>)>[];

  /// When true, the next `permission.respond.request` throws instead of
  /// responding (consumed after one use).
  bool failNextRespond = false;

  @override
  Stream<RpcEvent> get events => eventsController.stream;

  @override
  Stream<TerminalFrame> get terminalFrames => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  void sendTerminalFrame(TerminalFrame frame) {}

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.permissionRespondRequest && failNextRespond) {
      failNextRespond = false;
      throw StateError('permission service unavailable');
    }
    return switch (type) {
      MessageTypes.agentListRequest => {
          'agents': [_agent.toJson()],
        },
      MessageTypes.agentTimelineFetchRequest => const TimelineFetchResponse(
          epoch: 0,
          lastSeq: 0,
          items: [],
        ).toJson(),
      MessageTypes.diffGetRequest => const DiffResponse(files: []).toJson(),
      MessageTypes.terminalCreateRequest => {
          'terminal': {'terminalId': 'term-1', 'shell': 'bash'},
        },
      MessageTypes.terminalSubscribeRequest => {'slotId': 1},
      _ => const {},
    };
  }
}

Future<ProviderContainer> pumpChatScreen(
  WidgetTester tester, {
  FakeDaemonClient? client,
}) async {
  client ??= FakeDaemonClient();
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  container.read(agentsProvider.notifier).upsert(_agent);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: AgentChatScreen(agentId: 'a1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('shows the agent header and empty-timeline placeholder',
      (tester) async {
    await pumpChatScreen(tester);

    expect(find.text('Demo agent'), findsOneWidget);
    expect(find.textContaining('claude · sonnet · normal · /work/demo'),
        findsOneWidget);
    expect(find.text('No messages yet. Say something below.'), findsOneWidget);
  });

  testWidgets('a agent.stream event renders the new timeline item',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 1,
        item: UserMessageItem(id: 'm1', text: 'hello world'),
      ).toJson(),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('hello world'), findsOneWidget);
    expect(find.text('No messages yet. Say something below.'), findsNothing);
  });

  testWidgets('switching to the Diff tab fetches and renders the diff',
      (tester) async {
    await pumpChatScreen(tester);

    await tester.tap(find.text('Diff'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('No changes'), findsOneWidget);
    expect(find.text('/work/demo'), findsOneWidget);
  });

  testWidgets('switching to the Terminal tab creates a daemon terminal',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.text('Terminal'));
    await tester.pump();
    await tester.pump();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.terminalCreateRequest),
      isTrue,
    );
  });

  testWidgets('archiving the agent requests agent.archive and deselects it',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;
    container.read(selectedAgentProvider.notifier).select('a1');

    await tester.tap(find.byTooltip('Archive agent'));
    await tester.pump();
    await tester.pump();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentArchiveRequest),
      isTrue,
    );
    expect(container.read(selectedAgentProvider), isNull);
    expect(container.read(agentsProvider).containsKey('a1'), isFalse);
  });

  testWidgets('a failed archive shows a snackbar and keeps the agent selected',
      (tester) async {
    final client = FailingArchiveClient()..failArchive = true;
    final container = await pumpChatScreen(tester, client: client);
    container.read(selectedAgentProvider.notifier).select('a1');

    await tester.tap(find.byTooltip('Archive agent'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Failed to archive'), findsOneWidget);
    expect(container.read(selectedAgentProvider), 'a1');
    expect(container.read(agentsProvider).containsKey('a1'), isTrue);
  });

  testWidgets(
      'scrolling away from the bottom shows a "jump to latest" button; '
      'tapping it scrolls back down and re-sticks', (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    // Populate enough messages to make the list scrollable.
    for (var i = 0; i < 40; i++) {
      client.eventsController.add(RpcEvent(
        type: MessageTypes.agentStreamEvent,
        payload: AgentStreamPayload(
          agentId: 'a1',
          epoch: 0,
          seq: i + 1,
          item: UserMessageItem(id: 'm$i', text: 'message number $i'),
        ).toJson(),
      ));
    }
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.arrow_downward), findsNothing);

    // Manually scroll away from the bottom to trigger _onScroll.
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();

    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.arrow_downward), findsNothing);
  });

  testWidgets('the Diff tab refresh button re-issues diff.get.request',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    await tester.tap(find.text('Diff'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    client.requests.clear();
    await tester.tap(find.byTooltip('Refresh diff'));
    await tester.pump();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.diffGetRequest),
      isTrue,
    );
  });

  testWidgets('a diff fetch failure shows an inline error', (tester) async {
    final client = FailingDiffClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: AgentChatScreen(agentId: 'a1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Diff'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Failed to load diff'), findsOneWidget);
  });

  testWidgets(
      'responding to a permission via the timeline dispatches '
      'permission.respond.request, and a failure shows a snackbar',
      (tester) async {
    final container = await pumpChatScreen(tester);
    final client = container.read(daemonClientProvider) as FakeDaemonClient;

    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 1,
        item: PermissionItem(
          id: 'perm-item',
          permissionId: 'perm-1',
          toolName: 'Bash',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'rm -rf /'),
        ),
      ).toJson(),
    ));
    await tester.pump();
    await tester.pump();

    // Success case.
    await tester.tap(find.text('Always allow'));
    await tester.pump();
    await tester.pump();
    expect(
      client.requests.any(
        (r) =>
            r.$1 == MessageTypes.permissionRespondRequest &&
            r.$2['decision'] == 'allow_always',
      ),
      isTrue,
    );

    // Failure case: script the next respond call to throw.
    client.failNextRespond = true;
    client.eventsController.add(RpcEvent(
      type: MessageTypes.agentStreamEvent,
      payload: const AgentStreamPayload(
        agentId: 'a1',
        epoch: 0,
        seq: 2,
        item: PermissionItem(
          id: 'perm-item-2',
          permissionId: 'perm-2',
          toolName: 'Bash',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'echo hi'),
        ),
      ).toJson(),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Deny').last);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Failed to respond'), findsOneWidget);
  });
}

/// Variant of [FakeDaemonClient] whose `agent.archive.request` can be made to
/// fail, so the chat screen's failure-snackbar branch is exercisable.
class FailingArchiveClient extends FakeDaemonClient {
  bool failArchive = false;

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentArchiveRequest && failArchive) {
      throw StateError('archive rejected');
    }
    return super.request(type, payload, timeout: timeout);
  }
}

/// Variant of [FakeDaemonClient] whose `diff.get.request` always fails.
class FailingDiffClient extends FakeDaemonClient {
  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.diffGetRequest) {
      throw StateError('diff unavailable');
    }
    return super.request(type, payload, timeout: timeout);
  }
}
