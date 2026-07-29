import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/terminal_providers.dart';
import 'package:coding_agent_app/state/workspace_terminal_session.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/terminal_pane.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:xterm/xterm.dart' hide TerminalState;

const _worktreePath = '/work/demo';

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Demo agent',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

const _tabId = 'tab-1';
const _key = (worktreePath: _worktreePath, tabId: _tabId, workspaceId: null);

List<String> _terminalTabIds(ProviderContainer container) => container
    .read(worktreeTabsProvider(_worktreePath))
    .layout
    .tabs
    .where((t) => t.kind == WorktreeTabKind.terminal)
    .map((t) => t.tabId)
    .toList();

/// Scriptable in-memory daemon: answers terminal RPCs and records frames
/// the client would have sent over the socket.
class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
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
  String? subscribeError;

  /// When set, `terminal.create.request` resolves from this completer
  /// instead of immediately, so a test can rebuild the provider (bumping its
  /// generation) while the request is still in flight.
  Completer<Map<String, Object?>>? pendingCreate;
  Completer<Map<String, Object?>>? pendingSubscribe;

  int _terminalCounter = 0;
  int _slotCounter = 0;

  @override
  Stream<TerminalFrame> get terminalFrames => frames.stream;

  @override
  Stream<RpcEvent> get events => fakeEvents.stream;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  void sendTerminalFrame(TerminalFrame frame) => sentFrames.add(frame);

  @override
  void sendSessionMessage(Map<String, Object?> message) {
    requests.add((message['type']! as String, message));
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type']! as String;
    requests.add((type, message));
    if (type == CreateTerminalRequest.type) {
      final error = createError;
      if (error != null) throw error;
      final pending = pendingCreate;
      if (pending != null) return pending.future;
      if (malformedCreateResponse) {
        return {
          'type': 'create_terminal_response',
          'payload': {
            'terminal': {'name': 'Terminal 1'},
            'requestId': message['requestId'],
          },
        };
      }
      _terminalCounter++;
      return {
        'type': 'create_terminal_response',
        'payload': {
          'terminal': {
            'id': 'term-$_terminalCounter',
            'name': 'Terminal $_terminalCounter',
            'cwd': message['cwd'],
            if (message['workspaceId'] != null)
              'workspaceId': message['workspaceId'],
          },
          'error': null,
          'requestId': message['requestId'],
        },
      };
    }
    if (type == SubscribeTerminalRequest.type) {
      final pending = pendingSubscribe;
      if (pending != null) return pending.future;
      final error = subscribeError;
      if (error != null) {
        return {
          'type': 'subscribe_terminal_response',
          'payload': {
            'terminalId': message['terminalId'],
            'error': error,
            'requestId': message['requestId'],
          },
        };
      }
      if (malformedSubscribeResponse) {
        return {
          'type': 'subscribe_terminal_response',
          'payload': {'requestId': message['requestId']},
        };
      }
      _slotCounter++;
      return {
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': message['terminalId'],
          'slot': _slotCounter,
          'error': null,
          'requestId': message['requestId'],
        },
      };
    }
    if (type == KillTerminalRequest.type) {
      return {
        'type': 'kill_terminal_response',
        'payload': {
          'terminalId': message['terminalId'],
          'success': true,
          'requestId': message['requestId'],
        },
      };
    }
    if (type == 'file_explorer_request') {
      return {
        'type': 'file_explorer_response',
        'payload': {
          'cwd': message['cwd'],
          'path': message['path'],
          'mode': 'file',
          'directory': null,
          'file': {
            'path': message['path'],
            'kind': 'text',
            'encoding': 'utf-8',
            'content': 'void main() {}',
            'mimeType': 'text/plain',
            'size': 14,
            'modifiedAt': '2026-07-27T00:00:00.000Z',
            'revision': 'revision',
          },
          'error': null,
          'requestId': message['requestId'],
        },
      };
    }
    return {'type': '${type}_response', 'payload': const {}};
  }

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
    if (type == MessageTypes.terminalSubscribeRequest) {
      if (malformedSubscribeResponse) return const {};
      _slotCounter++;
      return {'slotId': _slotCounter};
    }
    if (type == MessageTypes.terminalListRequest) {
      return {
        'terminals': [
          for (var i = 1; i <= _terminalCounter; i++)
            {'terminalId': 'term-$i', 'cwd': _worktreePath, 'shell': 'bash'},
        ],
      };
    }
    return switch (type) {
      MessageTypes.agentListRequest => {
        'agents': [_agent.toJson()],
      },
      _ => const {},
    };
  }
}

TerminalFrame _daemonFrame(TerminalOpcode opcode, int slotId, String text) {
  if (opcode == TerminalOpcode.snapshot) {
    final chars = text.replaceAll('\r', '').replaceAll('\n', '').split('');
    return TerminalFrame.snapshot(
      slotId,
      TerminalState(
        rows: 1,
        cols: chars.length,
        grid: [
          [for (final char in chars) TerminalCell(char: char)],
        ],
        scrollback: const [],
        cursor: TerminalCursor(row: 0, col: chars.length),
      ),
    );
  }
  return TerminalFrame(
    opcode: opcode,
    slotId: slotId,
    payload: Uint8List.fromList(utf8.encode(text)),
  );
}

void main() {
  testWidgets(
    'resolved terminal file links hover as clickable and Ctrl-open in side pane',
    (tester) async {
      final fake = FakeDaemonClient();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      final opened = <WorkspaceFileOpenRequest>[];
      getWorkspaceTerminalSession('ws://fake|$_worktreePath').snapshots.set(
        'term-1',
        const TerminalState(
          rows: 1,
          cols: 16,
          grid: [
            [
              TerminalCell(char: 'l'),
              TerminalCell(char: 'i'),
              TerminalCell(char: 'b'),
              TerminalCell(char: '/'),
              TerminalCell(char: 'm'),
              TerminalCell(char: 'a'),
              TerminalCell(char: 'i'),
              TerminalCell(char: 'n'),
              TerminalCell(char: '.'),
              TerminalCell(char: 'd'),
              TerminalCell(char: 'a'),
              TerminalCell(char: 'r'),
              TerminalCell(char: 't'),
              TerminalCell(char: ':'),
              TerminalCell(char: '4'),
              TerminalCell(char: '2'),
            ],
          ],
          scrollback: [],
          cursor: TerminalCursor(row: 0, col: 16),
        ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: FluentApp(
            home: ScaffoldPage(
              content: TerminalPane(
                worktreePath: _worktreePath,
                tabId: _tabId,
                onOpenWorkspaceFile: opened.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final viewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );
      final renderTerminal = viewState.renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final linkPoint = renderTerminal.localToGlobal(
        renderTerminal.getOffset(const CellOffset(4, 0)) +
            Offset(cellSize.width / 2, cellSize.height / 2),
      );

      await tester.sendEventToBinding(PointerHoverEvent(position: linkPoint));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).mouseCursor,
        SystemMouseCursors.click,
      );
      expect(
        fake.requests.where((request) => request.$1 == 'file_explorer_request'),
        isNotEmpty,
      );

      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .onTapUp
          ?.call(
            TapUpDetails(
              globalPosition: linkPoint,
              localPosition: linkPoint,
              kind: PointerDeviceKind.mouse,
            ),
            const CellOffset(4, 0),
          );
      await tester.pump();
      await tester.pump();
      await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(opened, hasLength(1));
      expect(opened.single.disposition, OpenFileDisposition.side);
      expect(
        opened.single.location,
        const WorkspaceFileLocation(path: 'lib/main.dart', lineStart: 42),
      );
    },
  );

  testWidgets('terminal pane streams daemon output and sends input frames', (
    tester,
  ) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);
    getWorkspaceTerminalSession('ws://fake|$_worktreePath').snapshots.set(
      'term-1',
      const TerminalState(
        rows: 1,
        cols: 6,
        grid: [
          [
            TerminalCell(char: 'c'),
            TerminalCell(char: 'a'),
            TerminalCell(char: 'c'),
            TerminalCell(char: 'h'),
            TerminalCell(char: 'e'),
            TerminalCell(char: 'd'),
          ],
        ],
        scrollback: [],
        cursor: TerminalCursor(row: 0, col: 6),
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
          ),
        ),
      ),
    );
    // Let create + subscribe complete.
    await tester.pump();
    await tester.pump();

    final types = fake.requests.map((r) => r.$1).toList();
    expect(types, contains(CreateTerminalRequest.type));
    expect(types, contains(SubscribeTerminalRequest.type));

    final session = container.read(terminalSessionProvider(_key));
    expect(session.status, TerminalSessionStatus.running);
    expect(session.terminal.buffer.getText(), contains('cached'));
    expect(
      container
          .read(terminalSessionProvider(_key).notifier)
          .sendModifiedEnter(ctrl: false, shift: true, alt: false, meta: false),
      isFalse,
    );

    // Daemon replays scrollback (snapshot), then live output.
    fake.frames.add(
      _daemonFrame(TerminalOpcode.snapshot, 1, 'hello-snapshot\r\n'),
    );
    fake.frames.add(_daemonFrame(TerminalOpcode.output, 1, 'live-output'));
    fake.frames.add(_daemonFrame(TerminalOpcode.restore, 1, 'restored-output'));
    fake.frames.add(_daemonFrame(TerminalOpcode.input, 1, 'ignored-input'));
    fake.frames.add(_daemonFrame(TerminalOpcode.resize, 1, 'ignored-resize'));
    fake.frames.add(_daemonFrame(TerminalOpcode.output, 1, '\x1b[=1;1u'));
    await tester.pump();

    final bufferText = session.terminal.buffer.getText();
    expect(bufferText, contains('restored-output'));
    expect(
      getWorkspaceTerminalSession(
        'ws://fake|$_worktreePath',
      ).snapshots.get('term-1'),
      isNotNull,
    );

    // Typing into the terminal produces an input frame with the slotId.
    fake.sentFrames.clear();
    session.terminal.textInput('ls');
    final inputs = fake.sentFrames
        .where((f) => f.opcode == TerminalOpcode.input)
        .toList();
    expect(inputs, hasLength(1));
    expect(inputs.single.slotId, 1);
    expect(utf8.decode(inputs.single.payload), 'ls');

    fake.sentFrames.clear();
    expect(
      container
          .read(terminalSessionProvider(_key).notifier)
          .sendRawInput(r'"C:\Program Files\tool.exe"'),
      isTrue,
    );
    expect(
      utf8.decode(fake.sentFrames.single.payload),
      r'"C:\Program Files\tool.exe"',
    );
    expect(
      container.read(terminalSessionProvider(_key).notifier).sendRawInput(''),
      isFalse,
    );

    final dropTarget = tester.widget<DropTarget>(find.byType(DropTarget));
    final dragDetails = DropEventDetails(
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    );
    dropTarget.onDragEntered!(dragDetails);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('terminal-drop-overlay')),
          )
          .opacity,
      1,
    );
    dropTarget.onDragEntered!(dragDetails);
    dropTarget.onDragExited!(dragDetails);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('terminal-drop-overlay')),
          )
          .opacity,
      0,
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    fake.sentFrames.clear();
    dropTarget.onDragEntered!(dragDetails);
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(r'C:\Program Files\tool.exe')],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();
    final droppedInputs = fake.sentFrames
        .where((frame) => frame.opcode == TerminalOpcode.input)
        .toList();
    expect(
      utf8.decode(droppedInputs.single.payload),
      r'"C:\Program Files\tool.exe"',
    );
    expect(
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    dropTarget.onDragDone!(
      const DropDoneDetails(
        files: [],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    debugDefaultTargetPlatformOverride = null;

    fake.sentFrames.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final modifiedEnter = fake.sentFrames
        .where((frame) => frame.opcode == TerminalOpcode.input)
        .toList();
    expect(modifiedEnter, hasLength(1));
    expect(utf8.decode(modifiedEnter.single.payload), '\x1b[13;2u');

    // The daemon terminal was created in the agent's cwd.
    final createPayload = fake.requests
        .firstWhere((r) => r.$1 == CreateTerminalRequest.type)
        .$2;
    expect(createPayload['cwd'], '/work/demo');
    expect(createPayload, isNot(contains('workspaceId')));

    // The native stream-exit notification shows the banner with a restart
    // action even though it does not carry a process exit code.
    fake.fakeEvents.add(
      const RpcEvent(
        type: 'terminal_stream_exit',
        payload: {'terminalId': 'term-1'},
      ),
    );
    await tester.pump();
    expect(find.textContaining('Terminal exited'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    fake.sentFrames.clear();
    session.terminal.textInput('ignored-after-exit');
    expect(fake.sentFrames, isEmpty);
    expect(
      getWorkspaceTerminalSession(
        'ws://fake|$_worktreePath',
      ).snapshots.get('term-1'),
      isNull,
    );

    // Tapping Restart invalidates the session, which starts a brand-new
    // daemon terminal.
    fake.requests.clear();
    await tester.tap(find.text('Restart'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(
      fake.requests.any((r) => r.$1 == CreateTerminalRequest.type),
      isTrue,
    );
    final restarted = container.read(terminalSessionProvider(_key));
    expect(restarted.status, TerminalSessionStatus.running);
  });

  testWidgets(
    'attach overlay waits for both subscription and current renderer readiness',
    (tester) async {
      final fake = FakeDaemonClient();
      fake.pendingSubscribe = Completer<Map<String, Object?>>();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FluentApp(
            home: ScaffoldPage(
              content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        container.read(terminalSessionProvider(_key)).status,
        TerminalSessionStatus.starting,
      );
      expect(
        find.byKey(const ValueKey('terminal-attach-loading')),
        findsOneWidget,
      );

      fake.pendingSubscribe!.complete({
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': 'term-1',
          'slot': 1,
          'error': null,
          'requestId': 'subscribe',
        },
      });
      await tester.pump();

      final attached = container.read(terminalSessionProvider(_key));
      expect(attached.status, TerminalSessionStatus.running);
      expect(attached.terminalId, 'term-1');
      expect(
        find.byKey(const ValueKey('terminal-attach-loading')),
        findsOneWidget,
      );

      await tester.pump();
      expect(
        find.byKey(const ValueKey('terminal-attach-loading')),
        findsNothing,
      );
    },
  );

  testWidgets('attach overlay stays hidden for an unfocused workspace', (
    tester,
  ) async {
    final fake = FakeDaemonClient();
    fake.pendingSubscribe = Completer<Map<String, Object?>>();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(
              worktreePath: _worktreePath,
              tabId: _tabId,
              isWorkspaceFocused: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      container.read(terminalSessionProvider(_key)).status,
      TerminalSessionStatus.starting,
    );
    expect(find.byKey(const ValueKey('terminal-attach-loading')), findsNothing);
  });

  testWidgets(
    'mobile virtual keyboard consumes one-shot modifiers and sends keys',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final fake = FakeDaemonClient();
        final container = ProviderContainer(
          overrides: [daemonClientProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);
        container.read(agentsProvider.notifier).upsert(_agent);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const FluentApp(
              home: ScaffoldPage(
                content: TerminalPane(
                  worktreePath: _worktreePath,
                  tabId: _tabId,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const ValueKey('terminal-virtual-keyboard')),
          findsOneWidget,
        );
        fake.sentFrames.clear();

        await tester.tap(find.byKey(const ValueKey('terminal-key-ctrl')));
        await tester.pump();
        container.read(terminalSessionProvider(_key)).terminal.textInput('c');
        await tester.pump();

        var inputs = fake.sentFrames
            .where((frame) => frame.opcode == TerminalOpcode.input)
            .toList();
        expect(inputs, hasLength(1));
        expect(utf8.decode(inputs.single.payload), '\x03');
        expect(
          container.read(terminalSessionProvider(_key)).pendingModifiers.hasAny,
          isFalse,
        );

        fake.sentFrames.clear();
        await tester.tap(find.byKey(const ValueKey('terminal-key-ctrl')));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
        await tester.pump();

        inputs = fake.sentFrames
            .where((frame) => frame.opcode == TerminalOpcode.input)
            .toList();
        expect(inputs, hasLength(1));
        expect(utf8.decode(inputs.single.payload), '\x03');

        fake.sentFrames.clear();
        await tester.tap(find.byKey(const ValueKey('terminal-key-up')));
        await tester.pump();
        inputs = fake.sentFrames
            .where((frame) => frame.opcode == TerminalOpcode.input)
            .toList();
        expect(inputs, hasLength(1));
        expect(utf8.decode(inputs.single.payload), '\x1b[A');
        await tester.pump(const Duration(milliseconds: 120));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('terminal create carries its Paseo workspace identity', (
    tester,
  ) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(
              worktreePath: _worktreePath,
              tabId: 'workspace-terminal',
              workspaceId: 'workspace-1',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final createPayload = fake.requests
        .firstWhere((r) => r.$1 == CreateTerminalRequest.type)
        .$2;
    expect(createPayload['workspaceId'], 'workspace-1');
  });

  testWidgets('terminal open intent restores by id without creating a PTY', (
    tester,
  ) async {
    final fake = FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final tabId = container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusOpenIntentTarget(
          const WorkspaceTerminalTabTarget(terminalId: 'terminal-existing'),
        )!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: tabId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      fake.requests.any((request) => request.$1 == CreateTerminalRequest.type),
      isFalse,
    );
    final subscribe = fake.requests.firstWhere(
      (request) => request.$1 == SubscribeTerminalRequest.type,
    );
    expect(subscribe.$2['terminalId'], 'terminal-existing');
    expect(
      container
          .read(
            terminalSessionProvider((
              worktreePath: _worktreePath,
              tabId: tabId,
              workspaceId: null,
            )),
          )
          .status,
      TerminalSessionStatus.running,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 1));
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
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider(_key));
    expect(session.status, TerminalSessionStatus.error);
    expect(find.textContaining('Terminal failed'), findsOneWidget);
    expect(find.textContaining('malformed create response'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    // Restarting retries (still malformed, so it stays in the error state,
    // but a fresh create request is issued).
    fake.requests.clear();
    await tester.tap(find.text('Restart'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(
      fake.requests.any((r) => r.$1 == CreateTerminalRequest.type),
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
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider(_key));
    expect(session.status, TerminalSessionStatus.error);
    expect(find.textContaining('malformed subscribe response'), findsOneWidget);
  });

  testWidgets('a native subscribe error is surfaced without rewriting it', (
    tester,
  ) async {
    final fake = FakeDaemonClient()..subscribeError = 'Terminal not found';
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(agentsProvider.notifier).upsert(_agent);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider(_key));
    expect(session.status, TerminalSessionStatus.error);
    expect(session.errorMessage, 'Terminal not found');
    expect(find.textContaining('Terminal not found'), findsOneWidget);
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
        child: const FluentApp(
          home: ScaffoldPage(
            content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final session = container.read(terminalSessionProvider(_key));
    expect(session.status, TerminalSessionStatus.error);
    expect(session.errorMessage, contains('daemon down'));
  });

  testWidgets(
    'a create response that lands after the session was rebuilt (stale '
    'generation) kills the leaked daemon-side terminal instead of adopting '
    'it',
    (tester) async {
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
          child: const FluentApp(
            home: ScaffoldPage(
              content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
            ),
          ),
        ),
      );
      // Let the build-time `Future.microtask(() => _start(...))` run and reach
      // (and suspend on) the pending create request.
      await tester.pump();

      // Rebuild the session before the create request resolves (bumping the
      // generation counter), the same way `restart()` does.
      fake.pendingCreate = null;
      container.read(terminalSessionProvider(_key).notifier).restart();
      await tester.pump();
      await tester.pump();

      // Now let the stale request resolve with a terminalId from the old
      // generation.
      pending.complete({
        'type': 'create_terminal_response',
        'payload': {
          'terminal': {
            'id': 'stale-term',
            'name': 'Terminal stale',
            'cwd': '/work/demo',
          },
          'requestId': 'stale',
        },
      });
      await tester.pump();
      await tester.pump();

      final killRequest = fake.requests.firstWhere(
        (r) => r.$1 == KillTerminalRequest.type,
      );
      expect(killRequest.$2['terminalId'], 'stale-term');
    },
  );

  testWidgets(
    'a subscribe response from a stale generation detaches and kills its '
    'created terminal',
    (tester) async {
      final fake = FakeDaemonClient();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      container.read(agentsProvider.notifier).upsert(_agent);

      final pending = Completer<Map<String, Object?>>();
      fake.pendingSubscribe = pending;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FluentApp(
            home: ScaffoldPage(
              content: TerminalPane(worktreePath: _worktreePath, tabId: _tabId),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        fake.requests.where(
          (request) => request.$1 == SubscribeTerminalRequest.type,
        ),
        hasLength(1),
      );

      fake.pendingSubscribe = null;
      container.read(terminalSessionProvider(_key).notifier).restart();
      await tester.pump();
      await tester.pump();
      pending.complete({
        'type': 'subscribe_terminal_response',
        'payload': {
          'terminalId': 'term-1',
          'slot': 99,
          'error': null,
          'requestId': 'stale-subscribe',
        },
      });
      await tester.pump();
      await tester.pump();

      expect(
        fake.requests.any(
          (request) =>
              request.$1 == UnsubscribeTerminalRequest.type &&
              request.$2['terminalId'] == 'term-1',
        ),
        isTrue,
      );
      expect(
        fake.requests.any(
          (request) =>
              request.$1 == KillTerminalRequest.type &&
              request.$2['terminalId'] == 'term-1',
        ),
        isTrue,
      );
      expect(
        container.read(terminalSessionProvider(_key)).status,
        TerminalSessionStatus.running,
      );
    },
  );

  testWidgets(
    'archiving an agent does not touch terminal sessions (terminals are '
    'worktree-scoped, not agent-scoped)',
    (tester) async {
      final fake = FakeDaemonClient();
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      container.read(agentsProvider.notifier).upsert(_agent);
      container
          .read(worktreeTabsProvider(_worktreePath).notifier)
          .addTab(WorktreeTabKind.terminal);
      final tabId = _terminalTabIds(container).single;
      final key = (
        worktreePath: _worktreePath,
        tabId: tabId,
        workspaceId: null,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: FluentApp(
            home: ScaffoldPage(
              content: TerminalPane(worktreePath: _worktreePath, tabId: tabId),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(container.exists(terminalSessionProvider(key)), isTrue);

      fake.requests.clear();
      await container.read(agentActionsProvider).archive('a1');
      // Archiving triggers a WorktreeTabsNotifier rebuild (it watches
      // agentsProvider), which re-checks pending terminal verification and
      // fires an async terminal.list.request round-trip — give it a few extra
      // ticks to fully settle before the test ends.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        fake.requests.any(
          (r) => r.$1 == MessageTypes.terminalUnsubscribeRequest,
        ),
        isFalse,
      );
      expect(
        fake.requests.any((r) => r.$1 == KillTerminalRequest.type),
        isFalse,
      );
      expect(
        container.read(terminalSessionProvider(key)).status,
        TerminalSessionStatus.running,
      );
    },
  );
}
