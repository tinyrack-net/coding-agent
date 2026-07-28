import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('SessionStarted carries the session id', () {
    const event = SessionStarted(sessionId: 'sess-1');
    expect(event, isA<ProviderEvent>());
    expect(event.sessionId, 'sess-1');
  });

  test('AssistantTextDelta carries itemId and text', () {
    const event = AssistantTextDelta(itemId: 'm1', text: 'hi');
    expect(event.itemId, 'm1');
    expect(event.text, 'hi');
  });

  test('ReasoningDelta carries itemId and text', () {
    const event = ReasoningDelta(itemId: 'r1', text: 'thinking');
    expect(event.itemId, 'r1');
    expect(event.text, 'thinking');
  });

  test('AssistantMessageComplete carries itemId and fullText', () {
    const event = AssistantMessageComplete(
      itemId: 'm1',
      fullText: 'hello world',
    );
    expect(event.itemId, 'm1');
    expect(event.fullText, 'hello world');
  });

  test('ReasoningComplete carries itemId and fullText', () {
    const event = ReasoningComplete(itemId: 'r1', fullText: 'done thinking');
    expect(event.itemId, 'r1');
    expect(event.fullText, 'done thinking');
  });

  test('ToolCallStarted carries itemId, toolName, status and detail', () {
    const event = ToolCallStarted(
      itemId: 't1',
      toolName: 'Bash',
      status: ToolCallStatus.pending,
      detail: ShellDetail(command: 'ls'),
    );
    expect(event.itemId, 't1');
    expect(event.toolName, 'Bash');
    expect(event.status, ToolCallStatus.pending);
    expect((event.detail as ShellDetail).command, 'ls');
  });

  test('ToolCallUpdated carries itemId, toolName, status and detail', () {
    const event = ToolCallUpdated(
      itemId: 't1',
      toolName: 'Bash',
      status: ToolCallStatus.success,
      detail: ShellDetail(command: 'ls', output: 'a.txt', exitCode: 0),
    );
    expect(event.status, ToolCallStatus.success);
    expect((event.detail as ShellDetail).exitCode, 0);
  });

  test('PermissionRequested carries permissionId, toolName, detail and a '
      'callable respond function', () async {
    PermissionDecision? decided;
    String? capturedMessage;
    final event = PermissionRequested(
      permissionId: 'perm-1',
      toolName: 'Write',
      detail: const WriteDetail(path: 'a.txt'),
      respond: (decision, {String? message}) async {
        decided = decision;
        capturedMessage = message;
      },
    );
    expect(event.permissionId, 'perm-1');
    expect(event.toolName, 'Write');
    expect((event.detail as WriteDetail).path, 'a.txt');
    await event.respond(PermissionDecision.deny, message: 'no thanks');
    expect(decided, PermissionDecision.deny);
    expect(capturedMessage, 'no thanks');
  });

  test('TurnCompleted is a plain marker event', () {
    const event = TurnCompleted();
    expect(event, isA<ProviderEvent>());
  });

  test('UsageUpdated carries context and request token usage', () {
    const event = UsageUpdated(
      usage: AgentUsage(
        inputTokens: 10,
        contextWindowMaxTokens: 200000,
        contextWindowUsedTokens: 50000,
      ),
    );
    expect(event.usage.inputTokens, 10);
    expect(event.usage.contextWindowUsedTokens, 50000);
  });

  test('CompactionUpdated carries lifecycle metadata', () {
    const event = CompactionUpdated(
      itemId: 'compact',
      status: CompactionStatus.loading,
      trigger: CompactionTrigger.auto,
      preTokens: 190000,
    );
    expect(event.itemId, 'compact');
    expect(event.status, CompactionStatus.loading);
    expect(event.trigger, CompactionTrigger.auto);
    expect(event.preTokens, 190000);
  });

  test('TurnFailed carries the error message', () {
    const event = TurnFailed(error: 'boom');
    expect(event.error, 'boom');
  });

  test('SessionExited carries an optional exit code', () {
    const withCode = SessionExited(exitCode: 1);
    expect(withCode.exitCode, 1);
    const withoutCode = SessionExited();
    expect(withoutCode.exitCode, isNull);
  });

  test('PermissionDecision has exactly allow and deny values', () {
    expect(PermissionDecision.values, [
      PermissionDecision.allow,
      PermissionDecision.deny,
    ]);
  });
}
