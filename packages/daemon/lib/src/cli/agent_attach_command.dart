import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_timeline.dart';
import 'terminal_command.dart';

typedef AgentAttachRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef AgentAttachMessageReceiver = Future<Map<String, Object?>> Function();

Future<int> runAgentAttachCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  AgentAttachRpcRequester? request,
  AgentAttachMessageReceiver? receiveMessage,
  Stream<void>? stopSignals,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_attachHelp);
    return 0;
  }

  late final AgentAttachInvocation invocation;
  try {
    invocation = AgentAttachInvocation.parse(arguments);
  } on _MissingAgentId {
    errorOutput(
      'Error: Agent ID required\n'
      'Usage: coding-agent attach <id>\n',
    );
    return 1;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentAttachUsage\n');
    return 64;
  }

  final env = environment ?? Platform.environment;
  DaemonCliSocketClient? client;
  var send = request;
  var receive = receiveMessage;
  if (send == null) {
    final config = loadDaemonRuntimeConfig(environment: env);
    try {
      client = await DaemonCliSocketClient.connect(
        config,
        hostOverride: invocation.host,
        environment: env,
      );
      send = client.request;
      receive = client.nextSessionMessage;
    } on Object catch (error) {
      final host = invocation.host ?? '${config.host}:${config.port}';
      errorOutput(
        'Error: Cannot connect to daemon at $host: ${_errorText(error)}\n'
        'Start the daemon with: coding-agent daemon start\n',
      );
      return 1;
    }
  }

  try {
    final resolvedId = await _resolveAgent(send, invocation.agentId);
    output(
      'Attaching to agent ${_shortId(resolvedId)}...\n'
      '(Press Ctrl+C to detach)\n\n',
    );

    try {
      final existing = await fetchProjectedTimelineItems(
        send,
        resolvedId,
        timeoutMs: liveHistoryFetchTimeoutMs,
      );
      for (final item in existing) {
        _printTimelineItem(item, output, errorOutput);
      }
    } on Object catch (error) {
      errorOutput(
        'Warning: failed to fetch existing timeline ${_errorText(error)}\n',
      );
    }

    if (receive == null) {
      throw StateError('Attach mode requires a daemon event stream');
    }
    final stop = (stopSignals ?? _processStopSignals()).first;
    while (true) {
      final outcome =
          await Future.any<({bool stopped, Map<String, Object?>? message})>([
            receive().then((message) => (stopped: false, message: message)),
            stop.then((_) => (stopped: true, message: null)),
          ]);
      if (outcome.stopped) {
        output('\n\nDetaching from agent...\n');
        return 0;
      }
      _printStreamMessage(
        outcome.message!,
        agentId: resolvedId,
        writeOutput: output,
        writeError: errorOutput,
      );
    }
  } on _AgentAttachDirectException catch (error) {
    errorOutput(
      'Error: ${error.message}\n'
      '${error.details == null ? '' : '${error.details}\n'}',
    );
    return 1;
  } on Object catch (error) {
    errorOutput('Error: Failed to attach to agent: ${_errorText(error)}\n');
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentAttachInvocation {
  const AgentAttachInvocation({required this.agentId, required this.host});

  final String agentId;
  final String? host;

  static AgentAttachInvocation parse(List<String> arguments) {
    final positionals = <String>[];
    String? host;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--host':
          if (++index >= arguments.length) {
            throw const FormatException('--host requires a value');
          }
          host = arguments[index];
        default:
          if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          }
          positionals.add(argument);
      }
    }
    if (positionals.isEmpty || positionals.singleOrNull?.isEmpty == true) {
      throw const _MissingAgentId();
    }
    if (positionals.length != 1) {
      throw const FormatException('agent attach accepts exactly one Agent ID');
    }
    return AgentAttachInvocation(agentId: positionals.single, host: host);
  }
}

Future<String> _resolveAgent(
  AgentAttachRpcRequester request,
  String identifier,
) async {
  final payload = await request(
    FetchAgentRequest(
      requestId: _requestId('agent_attach_resolve'),
      agentId: identifier,
    ).toJson(),
  );
  final error = payload['error'];
  if (error is String && error.isNotEmpty) {
    throw _AgentAttachDirectException(
      'No agent found matching: $identifier',
      details: 'Use `coding-agent ls` to list available agents',
    );
  }
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw _AgentAttachDirectException(
      'No agent found matching: $identifier',
      details: 'Use `coding-agent ls` to list available agents',
    );
  }
  if (rawAgent is! Map) throw StateError('Invalid fetch agent response');
  final snapshot = Map<String, Object?>.from(rawAgent);
  final agent = PaseoAgentSnapshotCodec.decode(snapshot);
  return agent.agentId;
}

void _printStreamMessage(
  Map<String, Object?> message, {
  required String agentId,
  required void Function(String value) writeOutput,
  required void Function(String value) writeError,
}) {
  if (message['type'] != 'agent_stream') return;
  final payload = _mapOrNull(message['payload']);
  if (payload == null || payload['agentId'] != agentId) return;
  final event = _mapOrNull(payload['event']);
  if (event == null) return;
  switch (event['type']) {
    case 'timeline':
      final rawItem = _mapOrNull(event['item']);
      if (rawItem == null) return;
      final item = PaseoTimelineCodec.decode(
        rawItem,
        fallbackId: 'stream:${payload['epoch']}:${payload['seq']}',
      );
      _printTimelineItem(item, writeOutput, writeError);
    case 'permission_requested':
      final request = _mapOrNull(event['request']);
      if (request == null) return;
      writeOutput('\n[Permission Required] ${request['name']}\n');
      final description = request['description'];
      if (description is String && description.isNotEmpty) {
        writeOutput('  $description\n');
      }
    case 'permission_resolved':
      final resolution = _mapOrNull(event['resolution']);
      if (resolution == null) return;
      writeOutput('\n[Permission ${resolution['behavior']}]\n');
    case 'turn_failed':
      writeError('\n[Turn Failed] ${event['error']}\n');
    case 'attention_required':
      writeOutput('\n[Attention Required: ${event['reason']}]\n');
  }
}

void _printTimelineItem(
  TimelineItem item,
  void Function(String value) writeOutput,
  void Function(String value) writeError,
) {
  switch (item) {
    case AssistantMessageItem():
      writeOutput(item.text);
    case ReasoningItem():
      writeOutput('\n[Reasoning] ${item.text}\n');
    case ToolCallItem():
      final display = buildToolCallDisplayModel(
        ToolCallDisplayInput.fromItem(item),
      );
      final displayName = tinyrackToolCallDisplayName(
        item.toolName,
        display.displayName,
      );
      final summary = display.summary == null ? '' : ' — ${display.summary}';
      writeOutput(
        '\n[Tool: $displayName] '
        '${_toolStatus(item.status)}$summary\n',
      );
    case TodoItem():
      final completed = item.items.where((entry) => entry.completed).length;
      writeOutput('\n[Todo] $completed/${item.items.length} completed\n');
    case ErrorItem():
      writeError('\n[Error] ${item.message}\n');
    case UserMessageItem():
      writeOutput('\n[User] ${item.text}\n');
    default:
      break;
  }
}

String _toolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => 'running',
  ToolCallStatus.success => 'completed',
  ToolCallStatus.error => 'failed',
  ToolCallStatus.canceled => 'canceled',
};

String _shortId(String agentId) =>
    agentId.substring(0, agentId.length < 7 ? agentId.length : 7);

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

Stream<void> _processStopSignals() {
  late final StreamController<void> controller;
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  controller = StreamController<void>(
    onListen: () {
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
        try {
          subscriptions.add(
            signal.watch().listen(
              (_) => controller.add(null),
              onError: controller.addError,
            ),
          );
        } on Object {
          // Some platforms do not expose every POSIX signal.
        }
      }
    },
    onCancel: () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );
  return controller.stream;
}

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => '$message',
  FormatException(message: final message) => '$message',
  TimeoutException() => 'Timeline request timed out',
  _ => '$error',
};

final class _MissingAgentId implements Exception {
  const _MissingAgentId();
}

final class _AgentAttachDirectException implements Exception {
  const _AgentAttachDirectException(this.message, {this.details});

  final String message;
  final String? details;
}

const agentAttachUsage =
    'Usage: coding-agent agent attach <id> [options]\n'
    '       coding-agent attach <id> [options]';

const _attachHelp =
    'Usage: coding-agent agent attach [options] <id>\n'
    "Attach to a running agent's output stream\n";
