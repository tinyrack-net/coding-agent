// Manual smoke test against the real Claude CLI (not run by `dart test`).
//
// Creates an agent in a temp dir, prompts it to create hello.txt, auto-allows
// every permission request, and prints the resulting timeline.
//
//   dart run agent_daemon:smoke_claude

import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/claude/claude_client.dart';
import 'package:agent_protocol/agent_protocol.dart';

Future<void> main() async {
  final scratch = Directory.systemTemp.createTempSync('smoke_claude_');
  final dataDir = Directory.systemTemp.createTempSync('smoke_claude_data_');
  stdout.writeln('cwd: ${scratch.path}');

  final idle = Completer<void>();
  late final AgentManager manager;
  manager = AgentManager(
    clients: {'claude': ClaudeClient()},
    store: AgentStore(dataDir: dataDir.path),
    onStream: (payload) {
      final item = payload.item;
      final desc = switch (item) {
        AssistantMessageItem(:final text, :final complete) =>
          'assistant(complete=$complete) ${_trunc(text)}',
        ReasoningItem(:final text) => 'reasoning ${_trunc(text)}',
        ToolCallItem(:final toolName, :final status) =>
          'tool $toolName [${status.name}]',
        PermissionItem(:final toolName, :final status) =>
          'permission $toolName [${status.name}]',
        TurnItem(:final phase) => 'turn ${phase.name}',
        UserMessageItem(:final text) => 'user ${_trunc(text)}',
        ErrorItem(:final message) => 'error $message',
      };
      stdout.writeln('[seq ${payload.seq}] ${item.kind}: $desc');
    },
    onState: (payload) {
      stdout.writeln('== state: ${payload.agent.runState.name}');
      if (payload.agent.runState == AgentRunState.idle &&
          !idle.isCompleted &&
          payload.agent.sessionId != null) {
        idle.complete();
      }
    },
    onPermissionRequested: (agentId, permissionId, toolName, detail) {
      stdout.writeln('** auto-allowing permission $permissionId ($toolName)');
      unawaited(manager.respondPermission(permissionId, 'allow'));
    },
    onPermissionResolved: (permissionId, decision) =>
        stdout.writeln('** permission $permissionId -> ${decision.name}'),
  );

  final agent = await manager.createAgent(
    cwd: scratch.path,
    provider: 'claude',
    model: '',
    mode: AgentMode.normal,
    title: 'smoke',
  );
  stdout.writeln('agent ${agent.agentId} created');

  await manager.prompt(
    agent.agentId,
    'Create a file named hello.txt in the current directory containing '
    'exactly "hi". Use the Write tool.',
  );

  // Wait for the turn to finish (state back to idle after running).
  final done = Completer<void>();
  Timer.periodic(const Duration(milliseconds: 200), (t) {
    final state = manager.list().single.runState;
    if (state == AgentRunState.idle || state == AgentRunState.error) {
      final timeline = manager.fetchTimeline(agent.agentId);
      final hasTurnEnd = timeline.items
          .whereType<TurnItem>()
          .any((i) => i.phase != TurnPhase.started);
      if (hasTurnEnd) {
        t.cancel();
        done.complete();
      }
    }
  });
  await done.future.timeout(const Duration(minutes: 3));

  final hello = File('${scratch.path}${Platform.pathSeparator}hello.txt');
  stdout.writeln('--- timeline snapshot ---');
  for (final item in manager.fetchTimeline(agent.agentId).items) {
    stdout.writeln('${item.kind}: ${_trunc(item.toJson().toString(), 200)}');
  }
  stdout.writeln('hello.txt exists: ${hello.existsSync()} '
      'content: ${hello.existsSync() ? hello.readAsStringSync() : '-'}');

  await manager.dispose();
  exit(hello.existsSync() ? 0 : 1);
}

String _trunc(String s, [int max = 80]) =>
    s.length <= max ? s.replaceAll('\n', ' ') : '${s.substring(0, max)}...';
