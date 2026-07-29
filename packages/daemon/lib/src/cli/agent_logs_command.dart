import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/agent_mcp_tools.dart' show curateAgentActivity;
import '../server/daemon_config.dart';
import 'cli_timeline.dart';
import 'terminal_command.dart';

typedef AgentLogsRpcRequester = CliTimelineRpcRequester;
typedef AgentLogsMessageReceiver = Future<Map<String, Object?>> Function();

Future<int> runAgentLogsCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  AgentLogsRpcRequester? request,
  AgentLogsMessageReceiver? receiveMessage,
  Stream<void>? stopSignals,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_logsHelp);
    return 0;
  }

  AgentLogsInvocation invocation;
  try {
    invocation = AgentLogsInvocation.parse(arguments);
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentLogsUsage\n');
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
    final snapshot = await _fetchAgent(send, invocation.agentId);
    final resolvedId = _requiredString(snapshot, 'id');
    final tail = _parseTailCount(invocation.tail);
    if (invocation.tail != null && tail == null) {
      throw _AgentLogsDirectException(
        'Invalid --tail value: ${invocation.tail}',
        details: 'Usage: --tail <n> (where n is >= 0)',
      );
    }
    if (invocation.follow) {
      if (receive == null) {
        throw StateError('Follow mode requires a daemon event stream');
      }
      await _runFollowMode(
        request: send,
        receiveMessage: receive,
        stopSignals: stopSignals ?? _processStopSignals(),
        agentId: resolvedId,
        tailCount: tail ?? 10,
        filter: invocation.filter,
        writeOutput: output,
        writeError: errorOutput,
      );
      return 0;
    }

    var items = await fetchAgentTimelineItems(send, resolvedId);
    if (invocation.filter != null) {
      items = items
          .where((item) => matchesAgentLogsFilter(item, invocation.filter))
          .toList(growable: false);
    }
    if (tail == 0) return 0;
    output('${formatAgentActivityTranscript(items, tail)}\n');
    return 0;
  } on _AgentLogsDirectException catch (error) {
    errorOutput(
      'Error: ${error.message}\n'
      '${error.details == null ? '' : '${error.details}\n'}',
    );
    return 1;
  } on Object catch (error) {
    errorOutput('Error: Failed to get logs: ${_errorText(error)}\n');
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentLogsInvocation {
  const AgentLogsInvocation({
    required this.agentId,
    required this.follow,
    required this.tail,
    required this.filter,
    required this.since,
    required this.host,
  });

  final String agentId;
  final bool follow;
  final String? tail;
  final String? filter;
  final String? since;
  final String? host;

  static AgentLogsInvocation parse(List<String> arguments) {
    final positionals = <String>[];
    var follow = false;
    String? tail;
    String? filter;
    String? since;
    String? host;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '-f' || '--follow':
          follow = true;
        case '--tail':
          tail = _requiredValue(arguments, ++index, argument);
        case '--filter':
          filter = _requiredValue(arguments, ++index, argument);
        case '--since':
          since = _requiredValue(arguments, ++index, argument);
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        default:
          if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          }
          positionals.add(argument);
      }
    }
    if (positionals.length != 1 || positionals.single.isEmpty) {
      throw const FormatException('Agent ID required');
    }
    return AgentLogsInvocation(
      agentId: positionals.single,
      follow: follow,
      tail: tail,
      filter: filter,
      since: since,
      host: host,
    );
  }
}

Future<Map<String, Object?>> _fetchAgent(
  AgentLogsRpcRequester request,
  String identifier,
) async {
  final payload = await request(
    FetchAgentRequest(
      requestId: _requestId('agent_logs_resolve'),
      agentId: identifier,
    ).toJson(),
  );
  final error = payload['error'];
  if (error is String && error.isNotEmpty) throw StateError(error);
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw _AgentLogsDirectException(
      'No agent found matching: $identifier',
      details: 'Use `coding-agent ls` to list available agents',
    );
  }
  if (rawAgent is! Map) throw StateError('Invalid fetch agent response');
  final snapshot = Map<String, Object?>.from(rawAgent);
  PaseoAgentSnapshotCodec.decode(snapshot);
  return snapshot;
}

Future<List<TimelineItem>> fetchAgentTimelineItems(
  AgentLogsRpcRequester request,
  String agentId, {
  int? timeoutMs,
}) => fetchProjectedTimelineItems(request, agentId, timeoutMs: timeoutMs);

String formatAgentActivityTranscript(List<TimelineItem> items, int? tailCount) {
  if (tailCount == 0) return '';
  return curateAgentActivity(items, maxItems: tailCount);
}

bool matchesAgentLogsFilter(TimelineItem item, String? filter) {
  if (filter == null) return true;
  final normalized = filter.toLowerCase();
  final type = item.kind.toLowerCase();
  return switch (normalized) {
    'tools' => type == 'tool_call',
    'text' =>
      type == 'user_message' ||
          type == 'assistant_message' ||
          type == 'reasoning',
    'errors' => type == 'error',
    'permissions' => type.contains('permission'),
    _ => type.contains(normalized),
  };
}

Future<void> _runFollowMode({
  required AgentLogsRpcRequester request,
  required AgentLogsMessageReceiver receiveMessage,
  required Stream<void> stopSignals,
  required String agentId,
  required int tailCount,
  required String? filter,
  required void Function(String value) writeOutput,
  required void Function(String value) writeError,
}) async {
  var existing = <TimelineItem>[];
  try {
    existing = await fetchAgentTimelineItems(
      request,
      agentId,
      timeoutMs: liveHistoryFetchTimeoutMs,
    );
  } on Object catch (error) {
    writeError(
      'Warning: failed to fetch existing timeline ${_errorText(error)}\n',
    );
  }
  if (filter != null) {
    existing = existing
        .where((item) => matchesAgentLogsFilter(item, filter))
        .toList(growable: false);
  }
  if (tailCount > 0) {
    final transcript = formatAgentActivityTranscript(existing, tailCount);
    if (transcript != 'No activity to display.') {
      writeOutput('$transcript\n');
    }
  }

  final tailLabel = tailCount == 0
      ? 'no history'
      : 'last $tailCount ${tailCount == 1 ? 'entry' : 'entries'}';
  writeOutput('\n--- Following logs ($tailLabel; Ctrl+C to stop) ---\n\n');

  final stop = stopSignals.first;
  while (true) {
    final outcome =
        await Future.any<({bool stopped, Map<String, Object?>? message})>([
          receiveMessage().then(
            (message) => (stopped: false, message: message),
          ),
          stop.then((_) => (stopped: true, message: null)),
        ]);
    if (outcome.stopped) return;
    final message = outcome.message!;
    if (message['type'] != 'agent_stream') continue;
    final payload = _map(message, 'payload');
    if (payload['agentId'] != agentId) continue;
    final event = _map(payload, 'event');
    if (event['type'] != 'timeline') continue;
    final item = PaseoTimelineCodec.decode(
      _map(event, 'item'),
      fallbackId: 'stream:${payload['epoch']}:${payload['seq']}',
    );
    if (!matchesAgentLogsFilter(item, filter)) continue;
    final transcript = formatAgentActivityTranscript([item], null);
    if (transcript != 'No activity to display.') {
      writeOutput('$transcript\n');
    }
  }
}

int? _parseTailCount(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^[+-]?\d+').firstMatch(raw.trimLeft());
  if (match == null) return null;
  final parsed = int.tryParse(match.group(0)!);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

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

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw StateError('$key must be an object');
  return Map<String, Object?>.from(value);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError('$key must be a non-empty string');
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => '$message',
  FormatException(message: final message) => '$message',
  TimeoutException() => 'Timeline request timed out',
  _ => '$error',
};

final class _AgentLogsDirectException implements Exception {
  const _AgentLogsDirectException(this.message, {this.details});

  final String message;
  final String? details;
}

const agentLogsUsage =
    'Usage: coding-agent agent logs <id> [options]\n'
    '       coding-agent logs <id> [options]';

const _logsHelp =
    'Usage: coding-agent agent logs [options] <id>\n'
    'View agent activity/timeline\n';
