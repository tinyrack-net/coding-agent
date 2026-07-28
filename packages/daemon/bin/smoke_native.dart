// Manual smoke test against a real native LLM provider (not run by
// `dart test`). Requires a real API key via environment variable for the
// chosen provider:
//
//   OPENAI_API_KEY / DEEPSEEK_API_KEY / OPENROUTER_API_KEY
//
// Creates an agent in a temp dir, prompts it to write a file via the
// write_file tool, auto-allows the resulting permission request, and prints
// the resulting timeline.
//
//   dart run agent_daemon:smoke_native openai
//   dart run agent_daemon:smoke_native deepseek
//   dart run agent_daemon:smoke_native openrouter

import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/native/native_client.dart';
import 'package:agent_daemon/src/providers/native/openai_compatible_backend.dart';
import 'package:agent_daemon/src/providers/native/provider_catalog.dart';
import 'package:agent_protocol/agent_protocol.dart';

Future<void> main(List<String> args) async {
  final providerName = args.isNotEmpty ? args.first : 'openai';
  final ProviderId providerId;
  try {
    providerId = ProviderId.fromWire(providerName);
  } catch (_) {
    stderr.writeln(
      'unknown provider "$providerName" (expected openai/deepseek/openrouter)',
    );
    exit(2);
  }

  final envVar = switch (providerId) {
    ProviderId.openai => 'OPENAI_API_KEY',
    ProviderId.deepseek => 'DEEPSEEK_API_KEY',
    ProviderId.openrouter => 'OPENROUTER_API_KEY',
  };
  final apiKey = Platform.environment[envVar];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('$envVar is not set; skipping smoke_native ($providerName)');
    exit(1);
  }

  final scratch = Directory.systemTemp.createTempSync('smoke_native_');
  final dataDir = Directory.systemTemp.createTempSync('smoke_native_data_');
  stdout.writeln('cwd: ${scratch.path}');

  final credentials = CredentialStore(dataDir: dataDir.path);
  await credentials.set(providerId.name, apiKey);

  final catalogEntry = ProviderCatalog.byId(providerId);
  final model = catalogEntry.models.first.id;
  stdout.writeln('provider: ${providerId.name}, model: $model');

  final idle = Completer<void>();
  late final AgentManager manager;
  manager = AgentManager(
    clients: {
      providerId.name: NativeClient(
        providerId: providerId,
        backend: OpenAiCompatibleBackend(catalogEntry: catalogEntry),
        credentials: credentials,
      ),
    },
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
        TodoItem(:final items) => 'todo ${items.length} items',
        CompactionItem(:final status) => 'compaction ${status.name}',
        ErrorItem(:final message) => 'error $message',
      };
      stdout.writeln('[seq ${payload.seq}] ${item.kind}: $desc');
    },
    onState: (payload) {
      stdout.writeln('== state: ${payload.agent.runState.name}');
      if (!idle.isCompleted && payload.agent.runState == AgentRunState.idle) {
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
    provider: providerId.name,
    model: model,
    mode: AgentMode.normal,
    title: 'smoke-native',
  );
  stdout.writeln('agent ${agent.agentId} created');

  await manager.prompt(
    agent.agentId,
    'Do the following in order, using your tools (not just describing it): '
    '1) Create a file named hello.txt in the current directory containing '
    'exactly "hi", using the write_file tool. '
    '2) Edit hello.txt with the edit_file tool, replacing "hi" with '
    '"hi there". '
    '3) Run the bash tool with the command `echo done` and report its '
    'output. '
    'Finally reply with one short sentence summarizing what you did.',
  );

  // Wait for the turn to finish (state back to idle/error after running).
  final done = Completer<void>();
  Timer.periodic(const Duration(milliseconds: 200), (t) {
    final state = manager.list().single.runState;
    if (state == AgentRunState.idle || state == AgentRunState.error) {
      final timeline = manager.fetchTimeline(agent.agentId);
      final hasTurnEnd = timeline.items.whereType<TurnItem>().any(
        (i) => i.phase != TurnPhase.started,
      );
      if (hasTurnEnd) {
        t.cancel();
        done.complete();
      }
    }
  });
  await done.future.timeout(const Duration(minutes: 3));

  final hello = File('${scratch.path}${Platform.pathSeparator}hello.txt');
  final timeline = manager.fetchTimeline(agent.agentId).items;
  stdout.writeln('--- timeline snapshot ---');
  for (final item in timeline) {
    stdout.writeln('${item.kind}: ${_trunc(item.toJson().toString(), 200)}');
  }

  final wroteFile = hello.existsSync();
  final content = wroteFile ? hello.readAsStringSync() : '-';
  final editedFile = content.trim() == 'hi there';
  final ranBash = timeline.whereType<ToolCallItem>().any(
    (i) => i.toolName == 'bash' && i.status == ToolCallStatus.success,
  );
  final gotAssistantReply = timeline.whereType<AssistantMessageItem>().any(
    (i) => i.complete && i.text.trim().isNotEmpty,
  );

  stdout.writeln('--- results ---');
  stdout.writeln('assistant replied: $gotAssistantReply');
  stdout.writeln('hello.txt written: $wroteFile (content: "$content")');
  stdout.writeln('hello.txt edited to "hi there": $editedFile');
  stdout.writeln('bash tool ran successfully: $ranBash');

  await manager.dispose();
  exit(wroteFile && editedFile && ranBash && gotAssistantReply ? 0 : 1);
}

String _trunc(String s, [int max = 80]) =>
    s.length <= max ? s.replaceAll('\n', ' ') : '${s.substring(0, max)}...';
