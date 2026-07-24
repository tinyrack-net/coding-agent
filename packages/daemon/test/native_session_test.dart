import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_daemon/src/providers/native/native_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// A backend whose responses are scripted per-call via factory functions, so
/// tests can return controlled or never-ending streams (for interrupt tests).
class ScriptedLlmBackend implements LlmBackend {
  ScriptedLlmBackend(this.responses);

  final List<Stream<LlmStreamEvent> Function()> responses;
  final List<List<LlmMessage>> capturedMessages = [];
  int _callIndex = 0;

  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) {
    capturedMessages.add(messages);
    final factory = responses[_callIndex.clamp(0, responses.length - 1)];
    _callIndex++;
    return factory();
  }

  @override
  Future<bool> testCredential(String apiKey) async => true;
}

Stream<LlmStreamEvent> _fixed(List<LlmStreamEvent> events) =>
    Stream.fromIterable(events);

/// Collects events until [ProviderEvent] `stop(event)` returns true.
Future<List<ProviderEvent>> _collectUntil(
  Stream<ProviderEvent> events,
  bool Function(ProviderEvent) stop,
) async {
  final collected = <ProviderEvent>[];
  final completer = Completer<void>();
  late final StreamSubscription<ProviderEvent> sub;
  sub = events.listen((event) {
    collected.add(event);
    if (stop(event)) {
      completer.complete();
    }
  });
  await completer.future;
  await sub.cancel();
  return collected;
}

bool _isTerminal(ProviderEvent e) => e is TurnCompleted || e is TurnFailed;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('native_session_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  NativeSession makeSession(
    ScriptedLlmBackend backend, {
    AgentMode mode = AgentMode.fullAccess,
  }) =>
      NativeSession(
        backend: backend,
        model: 'test-model',
        cwd: tempDir.path,
        mode: mode,
        apiKey: 'sk-test',
      );

  test('text-only turn emits deltas, a completed message, then TurnCompleted',
      () async {
    final backend = ScriptedLlmBackend([
      () => _fixed([
            const LlmTextDelta('Hello'),
            const LlmTextDelta(', world'),
            const LlmStreamDone(LlmFinishReason.stop),
          ]),
    ]);
    final session = makeSession(backend);

    final future = _collectUntil(session.events, _isTerminal);
    await session.prompt('hi');
    final events = await future;

    expect(events.whereType<SessionStarted>(), hasLength(1));
    expect(events.whereType<AssistantTextDelta>().map((e) => e.text),
        ['Hello', ', world']);
    final complete = events.whereType<AssistantMessageComplete>().single;
    expect(complete.fullText, 'Hello, world');
    expect(events.last, isA<TurnCompleted>());
  });

  test('fullAccess mode auto-executes a read_file tool call with no '
      'permission prompt', () async {
    File('${tempDir.path}/a.txt').writeAsStringSync('file contents');
    final backend = ScriptedLlmBackend([
      () => _fixed([
            const LlmToolCallDelta(
              index: 0,
              id: 'call_1',
              name: 'read_file',
              argumentsChunk: '{"path":"a.txt"}',
            ),
            const LlmStreamDone(LlmFinishReason.toolCalls),
          ]),
      () => _fixed([
            const LlmTextDelta('done'),
            const LlmStreamDone(LlmFinishReason.stop),
          ]),
    ]);
    final session = makeSession(backend);

    final future = _collectUntil(session.events, _isTerminal);
    await session.prompt('read a.txt');
    final events = await future;

    expect(events.whereType<PermissionRequested>(), isEmpty);
    final toolEvents = events.whereType<ToolCallUpdated>().toList();
    expect(toolEvents.last.status, ToolCallStatus.success);
    expect((toolEvents.last.detail as ReadDetail).path, 'a.txt');
    expect(events.last, isA<TurnCompleted>());

    // Second backend call should have received the tool result message.
    expect(backend.capturedMessages, hasLength(2));
    final secondCallMessages = backend.capturedMessages[1];
    final toolResult =
        secondCallMessages.whereType<LlmToolResultMessage>().single;
    expect(toolResult.toolCallId, 'call_1');
    expect(toolResult.content, 'file contents');
  });

  test('normal mode requests permission for a mutating tool; approving runs it',
      () async {
    final backend = ScriptedLlmBackend([
      () => _fixed([
            const LlmToolCallDelta(
              index: 0,
              id: 'call_1',
              name: 'write_file',
              argumentsChunk: '{"path":"out.txt","content":"hi"}',
            ),
            const LlmStreamDone(LlmFinishReason.toolCalls),
          ]),
      () => _fixed([const LlmStreamDone(LlmFinishReason.stop)]),
    ]);
    final session = makeSession(backend, mode: AgentMode.normal);

    final events = <ProviderEvent>[];
    final done = Completer<void>();
    session.events.listen((e) {
      events.add(e);
      if (e is PermissionRequested) {
        e.respond(PermissionDecision.allow);
      }
      if (_isTerminal(e) && !done.isCompleted) done.complete();
    });

    await session.prompt('write out.txt');
    await done.future;

    expect(events.whereType<PermissionRequested>(), hasLength(1));
    expect(File('${tempDir.path}/out.txt').existsSync(), isTrue);
    expect(File('${tempDir.path}/out.txt').readAsStringSync(), 'hi');
    final toolUpdate = events.whereType<ToolCallUpdated>().last;
    expect(toolUpdate.status, ToolCallStatus.success);
  });

  test('denying a permission request skips execution and reports denial',
      () async {
    final backend = ScriptedLlmBackend([
      () => _fixed([
            const LlmToolCallDelta(
              index: 0,
              id: 'call_1',
              name: 'write_file',
              argumentsChunk: '{"path":"out.txt","content":"hi"}',
            ),
            const LlmStreamDone(LlmFinishReason.toolCalls),
          ]),
      () => _fixed([const LlmStreamDone(LlmFinishReason.stop)]),
    ]);
    final session = makeSession(backend, mode: AgentMode.normal);

    final done = Completer<void>();
    session.events.listen((e) {
      if (e is PermissionRequested) e.respond(PermissionDecision.deny);
      if (_isTerminal(e) && !done.isCompleted) done.complete();
    });

    await session.prompt('write out.txt');
    await done.future;

    expect(File('${tempDir.path}/out.txt').existsSync(), isFalse);
    final toolResult =
        backend.capturedMessages[1].whereType<LlmToolResultMessage>().single;
    expect(toolResult.content, 'denied by user');
  });

  test('plan mode blocks mutating tools without a permission prompt',
      () async {
    final backend = ScriptedLlmBackend([
      () => _fixed([
            const LlmToolCallDelta(
              index: 0,
              id: 'call_1',
              name: 'bash',
              argumentsChunk: '{"command":"echo hi"}',
            ),
            const LlmStreamDone(LlmFinishReason.toolCalls),
          ]),
      () => _fixed([const LlmStreamDone(LlmFinishReason.stop)]),
    ]);
    final session = makeSession(backend, mode: AgentMode.plan);

    final future = _collectUntil(session.events, _isTerminal);
    await session.prompt('run echo');
    final events = await future;

    expect(events.whereType<PermissionRequested>(), isEmpty);
    final toolResult =
        backend.capturedMessages[1].whereType<LlmToolResultMessage>().single;
    expect(toolResult.content, contains('not allowed in plan mode'));
  });

  test('interrupt() stops an in-flight turn with TurnFailed', () async {
    final controller = StreamController<LlmStreamEvent>();
    final backend = ScriptedLlmBackend([() => controller.stream]);
    final session = makeSession(backend);

    final future = _collectUntil(session.events, _isTerminal);
    final promptFuture = session.prompt('hang forever');
    controller.add(const LlmTextDelta('partial'));
    await Future<void>.delayed(Duration.zero);

    await session.interrupt();
    final events = await future;
    await promptFuture;

    expect(events.last, isA<TurnFailed>());
    expect((events.last as TurnFailed).error, 'interrupted');
    await controller.close();
  });

  test('dispose() closes the event stream after SessionExited', () async {
    final backend = ScriptedLlmBackend([
      () => _fixed([const LlmStreamDone(LlmFinishReason.stop)]),
    ]);
    final session = makeSession(backend);
    final events = <ProviderEvent>[];
    final sub = session.events.listen(events.add);
    await session.prompt('hi');
    await session.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(events.last, isA<SessionExited>());
    await sub.cancel();
  });
}
