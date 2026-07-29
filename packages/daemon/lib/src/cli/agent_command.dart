import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../server/daemon_config.dart';
import 'agent_logs_command.dart';
import 'terminal_command.dart';

typedef AgentRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runAgentCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  AgentRpcRequester? request,
  DateTime Function()? now,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_agentHelp(arguments.firstOrNull));
    return 0;
  }
  try {
    final invocation = AgentCliInvocation.parse(arguments);
    String? resolvedSendPrompt;
    ({int timeoutMs, String? timeoutLabel})? resolvedWaitTimeout;
    if (invocation.action == 'mode' &&
        !invocation.listModes &&
        (invocation.modeId == null || invocation.modeId!.isEmpty)) {
      throw const AgentCommandException(
        'MISSING_ARGUMENT',
        'Mode argument required unless --list is specified',
        details:
            'Usage: coding-agent agent mode <id> <mode> | '
            'coding-agent agent mode --list <id>',
      );
    }
    if (invocation.action == 'stop' &&
        invocation.agentId == null &&
        !invocation.stopAll &&
        invocation.cwd == null) {
      throw const AgentCommandException(
        'MISSING_ARGUMENT',
        'Agent ID required unless --all or --cwd is specified',
        details: 'Usage: coding-agent agent stop <id> | --all | --cwd <path>',
      );
    }
    if (invocation.action == 'send') {
      if (invocation.agentId == null || invocation.agentId!.trim().isEmpty) {
        throw const AgentCommandException(
          'MISSING_AGENT_ID',
          'Agent ID is required',
          details: 'Usage: coding-agent agent send [options] <id> [prompt]',
        );
      }
      resolvedSendPrompt = await _resolveSendPrompt(invocation);
    }
    if (invocation.action == 'wait') {
      if (invocation.agentId == null || invocation.agentId!.trim().isEmpty) {
        throw const AgentCommandException(
          'MISSING_AGENT_ID',
          'Agent ID is required',
          details: 'Usage: coding-agent agent wait <id>',
        );
      }
      resolvedWaitTimeout = _parseWaitTimeout(invocation.timeout);
    }
    if (invocation.action == 'archive' &&
        (invocation.agentId == null || invocation.agentId!.trim().isEmpty)) {
      throw const AgentCommandException(
        'MISSING_AGENT_ID',
        'Agent ID is required',
        details: 'Usage: coding-agent agent archive <id-or-name>',
      );
    }
    final env = environment ?? Platform.environment;
    var send = request;
    if (send == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
        send = (message) {
          if (message['type'] != WaitForFinishRequest.type) {
            return client!.request(message);
          }
          final timeoutMs = message['timeoutMs'];
          return client!.request(
            message,
            timeout: timeoutMs is int
                ? Duration(milliseconds: timeoutMs + 5000)
                : null,
          );
        };
      } on Object catch (error) {
        final host = invocation.host ?? '${config.host}:${config.port}';
        throw AgentCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          details: invocation.action == 'ls'
              ? 'Start the daemon with: coding-agent daemon start\n'
                    'For a remote daemon, pass --host <host:port> or set '
                    'TINYRACK_HOST.'
              : 'Start the daemon with: coding-agent daemon start',
        );
      }
    }
    final result = await _execute(
      invocation,
      send,
      env,
      (now ?? DateTime.now)().toUtc(),
      errorOutput,
      resolvedSendPrompt,
      resolvedWaitTimeout,
    );
    output(_render(result, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentUsage\n');
    return 64;
  } on AgentCommandException catch (error) {
    _writeCommandError(errorOutput, error, arguments);
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      AgentCommandException('AGENT_ERROR', _errorText(error)),
      arguments,
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentCliInvocation {
  const AgentCliInvocation({
    required this.action,
    required this.agentId,
    required this.modeId,
    required this.listModes,
    required this.stopAll,
    required this.cwd,
    required this.promptArgument,
    required this.promptOption,
    required this.promptFile,
    required this.images,
    required this.wait,
    required this.timeout,
    required this.force,
    required this.includeArchived,
    required this.global,
    required this.labels,
    required this.thinking,
    required this.host,
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String action;
  final String? agentId;
  final String? modeId;
  final bool listModes;
  final bool stopAll;
  final String? cwd;
  final String? promptArgument;
  final String? promptOption;
  final String? promptFile;
  final List<String> images;
  final bool wait;
  final String? timeout;
  final bool force;
  final bool includeArchived;
  final bool global;
  final List<String> labels;
  final String? thinking;
  final String? host;
  final String format;
  final bool quiet;
  final bool headers;

  static AgentCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing agent action');
    }
    final action = arguments.first;
    if (!const {
      'ls',
      'inspect',
      'mode',
      'stop',
      'send',
      'wait',
      'archive',
    }.contains(action)) {
      throw FormatException('Unknown agent action: $action');
    }
    final positionals = <String>[];
    final labels = <String>[];
    var includeArchived = false;
    var global = false;
    var listModes = false;
    var stopAll = false;
    String? cwd;
    String? promptOption;
    String? promptFile;
    final images = <String>[];
    var wait = true;
    String? timeout;
    var force = false;
    String? thinking;
    String? host;
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '-a':
          _onlyList(action, argument);
          includeArchived = true;
        case '--all':
          if (action == 'ls') {
            includeArchived = true;
          } else if (action == 'stop') {
            stopAll = true;
          } else {
            throw FormatException('$argument is only valid for agent ls/stop');
          }
        case '-g' || '--global':
          _onlyList(action, argument);
          global = true;
        case '-ag' || '-ga':
          _onlyList(action, argument);
          includeArchived = true;
          global = true;
        case '--list':
          if (action != 'mode') {
            throw FormatException('$argument is only valid for agent mode');
          }
          listModes = true;
        case '--cwd':
          if (action != 'stop') {
            throw FormatException('$argument is only valid for agent stop');
          }
          cwd = _requiredValue(arguments, ++index, argument);
        case '--prompt':
          _onlySend(action, argument);
          promptOption = _requiredValue(arguments, ++index, argument);
        case '--prompt-file':
          _onlySend(action, argument);
          promptFile = _requiredValue(arguments, ++index, argument);
        case '--image':
          _onlySend(action, argument);
          images.add(_requiredValue(arguments, ++index, argument));
        case '--no-wait':
          _onlySend(action, argument);
          wait = false;
        case '--timeout':
          _onlyWait(action, argument);
          timeout = _requiredValue(arguments, ++index, argument);
        case '--force':
          _onlyArchive(action, argument);
          force = true;
        case '--label':
          _onlyList(action, argument);
          labels.add(_requiredValue(arguments, ++index, argument));
        case '--thinking':
          _onlyList(action, argument);
          thinking = _requiredValue(arguments, ++index, argument);
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
        case '-o' || '--format':
          format = _requiredValue(
            arguments,
            ++index,
            argument,
          ).trim().toLowerCase();
          if (format == 'cli') format = 'table';
          if (!const {'table', 'json', 'yaml'}.contains(format)) {
            throw FormatException('Unknown output format: $format');
          }
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          break;
        default:
          if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          }
          positionals.add(argument);
      }
    }
    if (action == 'ls' && positionals.isNotEmpty) {
      throw const FormatException('agent ls does not accept an argument');
    }
    if (action == 'inspect' &&
        (positionals.length != 1 || positionals.single.trim().isEmpty)) {
      throw const FormatException('Agent ID is required');
    }
    if (action == 'mode' &&
        (positionals.isEmpty ||
            positionals.length > 2 ||
            positionals.first.trim().isEmpty)) {
      throw const FormatException('Agent ID is required');
    }
    if (action == 'stop' && positionals.length > 1) {
      throw const FormatException('agent stop accepts at most one Agent ID');
    }
    if (action == 'send' && positionals.length > 2) {
      throw const FormatException(
        'agent send accepts an Agent ID and optional prompt',
      );
    }
    if (action == 'wait' && positionals.length > 1) {
      throw const FormatException('agent wait accepts exactly one Agent ID');
    }
    if (action == 'archive' && positionals.length > 1) {
      throw const FormatException('agent archive accepts exactly one Agent ID');
    }
    final normalizedThinking = thinking?.trim();
    return AgentCliInvocation(
      action: action,
      agentId: action == 'send' || action == 'wait' || action == 'archive'
          ? positionals.firstOrNull
          : positionals.firstOrNull?.trim(),
      modeId: action == 'mode' && positionals.length == 2
          ? positionals[1].trim()
          : null,
      listModes: listModes,
      stopAll: stopAll,
      cwd: cwd == null || cwd.isEmpty ? null : cwd,
      promptArgument: action == 'send' && positionals.length == 2
          ? positionals[1]
          : null,
      promptOption: promptOption,
      promptFile: promptFile,
      images: List.unmodifiable(images),
      wait: wait,
      timeout: timeout,
      force: force,
      includeArchived: includeArchived,
      global: global,
      labels: List.unmodifiable(labels),
      thinking: normalizedThinking,
      host: host,
      format: json ? 'json' : format,
      quiet: quiet,
      headers: headers,
    );
  }
}

Future<_AgentCommandResult> _execute(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
  DateTime now,
  void Function(String value) writeWarning,
  String? resolvedSendPrompt,
  ({int timeoutMs, String? timeoutLabel})? resolvedWaitTimeout,
) async {
  return switch (invocation.action) {
    'ls' => _listAgents(invocation, request, environment, now),
    'inspect' => _inspectAgent(invocation, request, environment),
    'mode' => _modeAgent(invocation, request),
    'stop' => _stopAgents(invocation, request, writeWarning),
    'send' => _sendAgent(invocation, resolvedSendPrompt!, request),
    'wait' => _waitAgent(invocation, resolvedWaitTimeout!, request),
    'archive' => _archiveAgent(invocation, request),
    _ => throw StateError('Unhandled agent action'),
  };
}

Future<_AgentCommandResult> _listAgents(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
  DateTime now,
) async {
  if (invocation.thinking != null && invocation.thinking!.isEmpty) {
    throw const AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: [object Object]',
    );
  }
  final labels = _parseLabelFilters(invocation.labels);
  final filter = AgentDirectoryFilter(
    labels: labels,
    includeArchived: invocation.includeArchived ? true : null,
    thinkingOptionId: invocation.thinking,
    hasThinkingOptionId: invocation.thinking != null,
  );
  Map<String, Object?> payload;
  try {
    payload = await request(
      FetchAgentsRequest(
        requestId: _requestId('agent_ls'),
        activeScope: !invocation.global,
        filter: filter.toJson().isEmpty ? null : filter,
      ).toJson(),
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: ${_errorText(error)}',
    );
  }
  final entries = payload['entries'];
  if (entries is! List) {
    throw const AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: response is missing entries',
    );
  }
  final snapshots = <Map<String, Object?>>[];
  for (final rawEntry in entries) {
    if (rawEntry is! Map) {
      throw const AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: response contains an invalid entry',
      );
    }
    final entry = Map<String, Object?>.from(rawEntry);
    final rawAgent = entry['agent'];
    if (rawAgent is! Map) {
      throw const AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: response entry is missing agent',
      );
    }
    final snapshot = Map<String, Object?>.from(rawAgent);
    try {
      PaseoAgentSnapshotCodec.decode(snapshot);
    } on Object catch (error) {
      throw AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: ${_errorText(error)}',
      );
    }
    if (!invocation.includeArchived && snapshot['archivedAt'] != null) {
      continue;
    }
    final agentLabels = _mapOrNull(snapshot['labels']) ?? const {};
    if (labels.entries.any((entry) => agentLabels[entry.key] != entry.value)) {
      continue;
    }
    snapshots.add(snapshot);
  }
  snapshots.sort((left, right) {
    final statusComparison =
        _statusOrder(_string(left, 'status')) -
        _statusOrder(_string(right, 'status'));
    if (statusComparison != 0) return statusComparison;
    return _date(right, 'createdAt').compareTo(_date(left, 'createdAt'));
  });
  return _AgentCommandResult.list([
    for (final snapshot in snapshots) _agentListRow(snapshot, environment, now),
  ]);
}

Future<_AgentCommandResult> _inspectAgent(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
) async {
  Map<String, Object?> payload;
  try {
    payload = await request(
      FetchAgentRequest(
        requestId: _requestId('agent_inspect'),
        agentId: invocation.agentId!,
      ).toJson(),
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: ${_errorText(error)}',
    );
  }
  final responseError = payload['error'];
  if (responseError is String && responseError.isNotEmpty) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: $responseError',
    );
  }
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw AgentCommandException(
      'AGENT_NOT_FOUND',
      'Agent not found: ${invocation.agentId}',
      details: 'Use "coding-agent ls" to list available agents',
    );
  }
  if (rawAgent is! Map) {
    throw const AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: response contains an invalid agent',
    );
  }
  final snapshot = Map<String, Object?>.from(rawAgent);
  try {
    PaseoAgentSnapshotCodec.decode(snapshot);
  } on Object catch (error) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: ${_errorText(error)}',
    );
  }
  final data = _agentInspectData(snapshot);
  return _AgentCommandResult.inspect(
    rows: _agentInspectRows(data, environment),
    structured: data,
  );
}

Future<_AgentCommandResult> _modeAgent(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
) async {
  final operation = invocation.listModes ? 'list modes' : 'set mode';
  Map<String, Object?> payload;
  try {
    payload = await request(
      FetchAgentRequest(
        requestId: _requestId('agent_mode_resolve'),
        agentId: invocation.agentId!,
      ).toJson(),
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'MODE_OPERATION_FAILED',
      'Failed to $operation: ${_errorText(error)}',
    );
  }
  final responseError = payload['error'];
  if (responseError is String && responseError.isNotEmpty) {
    throw AgentCommandException(
      'MODE_OPERATION_FAILED',
      'Failed to $operation: $responseError',
    );
  }
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw AgentCommandException(
      'AGENT_NOT_FOUND',
      'No agent found matching: ${invocation.agentId}',
      details: 'Use `coding-agent ls` to list available agents',
    );
  }
  if (rawAgent is! Map) {
    throw AgentCommandException(
      'MODE_OPERATION_FAILED',
      'Failed to $operation: response contains an invalid agent',
    );
  }
  final snapshot = Map<String, Object?>.from(rawAgent);
  try {
    PaseoAgentSnapshotCodec.decode(snapshot);
  } on Object catch (error) {
    throw AgentCommandException(
      'MODE_OPERATION_FAILED',
      'Failed to $operation: ${_errorText(error)}',
    );
  }
  final resolvedId = _string(snapshot, 'id');
  if (invocation.listModes) {
    final modes = snapshot['availableModes'];
    return _AgentCommandResult.modes([
      for (final rawMode in modes is List ? modes : const <Object?>[])
        if (rawMode is Map)
          {
            'id': _string(Map<String, Object?>.from(rawMode), 'id'),
            'label': _string(Map<String, Object?>.from(rawMode), 'label'),
            if (rawMode['description'] is String)
              'description': rawMode['description'],
          },
    ]);
  }

  try {
    final responsePayload = await request(
      SetAgentModeRequest(
        agentId: resolvedId,
        modeId: invocation.modeId!,
        requestId: _requestId('agent_mode_set'),
      ).toJson(),
    );
    final response = AgentConfigResponse.fromJson({
      'type': 'set_agent_mode_response',
      'payload': responsePayload,
    });
    if (!response.accepted) {
      throw StateError(response.error ?? 'setAgentMode rejected');
    }
  } on Object catch (error) {
    throw AgentCommandException(
      'MODE_OPERATION_FAILED',
      'Failed to set mode: ${_errorText(error)}',
    );
  }
  return _AgentCommandResult.modeSet({
    'agentId': resolvedId.substring(0, resolvedId.length.clamp(0, 7)),
    'mode': invocation.modeId!,
  });
}

Future<String> _resolveSendPrompt(AgentCliInvocation invocation) async {
  final argument = invocation.promptArgument?.trim();
  final option = invocation.promptOption?.trim();
  final filePath = invocation.promptFile?.trim();
  final sourceCount = [
    argument,
    option,
    filePath,
  ].where((value) => value != null && value.isNotEmpty).length;
  if (sourceCount > 1) {
    throw const AgentCommandException(
      'CONFLICTING_PROMPT_INPUT',
      'Provide exactly one of prompt argument, --prompt, or --prompt-file',
    );
  }
  if (argument != null && argument.isNotEmpty) {
    return invocation.promptArgument!;
  }
  if (option != null && option.isNotEmpty) {
    return invocation.promptOption!;
  }
  if (filePath == null || filePath.isEmpty) {
    throw const AgentCommandException(
      'MISSING_PROMPT',
      'A prompt is required',
      details:
          'Usage: coding-agent agent send [options] <id> [prompt] | '
          '--prompt <text> | --prompt-file <path>',
    );
  }
  try {
    return await File(filePath).absolute.readAsString();
  } on Object catch (error) {
    throw AgentCommandException(
      'PROMPT_FILE_READ_ERROR',
      'Failed to read prompt file: $filePath',
      details: _errorText(error),
    );
  }
}

Future<_AgentCommandResult> _sendAgent(
  AgentCliInvocation invocation,
  String prompt,
  AgentRpcRequester request,
) async {
  try {
    final images = await Future.wait([
      for (final path in invocation.images) _readPromptImage(path),
    ]);
    final sendPayload = await request(
      SendAgentMessageRequest(
        requestId: _requestId('agent_send'),
        agentId: invocation.agentId!,
        text: prompt,
        messageId: const Uuid().v4(),
        images: images,
      ).toJson(),
    );
    final sendResponse = SendAgentMessageResponse.fromJson({
      'type': SendAgentMessageResponse.type,
      'payload': sendPayload,
    });
    if (!sendResponse.accepted) {
      throw StateError(sendResponse.error ?? 'sendAgentMessage rejected');
    }
    if (!invocation.wait) {
      return _AgentCommandResult.send({
        'agentId': invocation.agentId!,
        'status': 'sent',
        'message': 'Message sent, not waiting for completion',
      });
    }

    final waitPayload = await request(
      WaitForFinishRequest(
        requestId: _requestId('agent_send_wait'),
        agentId: invocation.agentId!,
        timeoutMs: 600000,
      ).toJson(),
    );
    final waitResponse = WaitForFinishResponse.fromJson({
      'type': WaitForFinishResponse.type,
      'payload': waitPayload,
    });
    final finalId = waitResponse.finalAgent == null
        ? invocation.agentId!
        : _string(waitResponse.finalAgent!, 'id');
    return switch (waitResponse.status) {
      WaitForFinishStatus.timeout => _AgentCommandResult.send({
        'agentId': finalId,
        'status': 'timeout',
        'message': 'Timed out waiting for agent to finish',
      }),
      WaitForFinishStatus.permission => _AgentCommandResult.send({
        'agentId': finalId,
        'status': 'permission',
        'message': 'Agent is waiting for permission',
      }),
      WaitForFinishStatus.error => _AgentCommandResult.send({
        'agentId': finalId,
        'status': 'error',
        'message': waitResponse.error ?? 'Agent finished with error',
      }),
      WaitForFinishStatus.idle => _AgentCommandResult.send({
        'agentId': finalId,
        'status': 'completed',
        'message': 'Agent completed processing the message',
      }),
    };
  } on AgentCommandException {
    rethrow;
  } on Object catch (error) {
    throw AgentCommandException(
      'SEND_FAILED',
      'Failed to send message: ${_errorText(error)}',
    );
  }
}

Future<AgentPromptImage> _readPromptImage(String path) async {
  try {
    final data = await File(path).readAsBytes();
    final normalized = path.toLowerCase();
    final mimeType = switch (normalized) {
      _ when normalized.endsWith('.png') => 'image/png',
      _ when normalized.endsWith('.gif') => 'image/gif',
      _ when normalized.endsWith('.webp') => 'image/webp',
      _ => 'image/jpeg',
    };
    return AgentPromptImage(data: base64Encode(data), mimeType: mimeType);
  } on Object catch (error) {
    throw AgentCommandException(
      'IMAGE_READ_ERROR',
      'Failed to read image file: $path',
      details: _errorText(error),
    );
  }
}

({int timeoutMs, String? timeoutLabel}) _parseWaitTimeout(String? raw) {
  if (raw == null || raw.isEmpty) {
    return (timeoutMs: 0, timeoutLabel: null);
  }
  try {
    final timeoutMs = _parsePaseoDuration(raw);
    if (timeoutMs <= 0) throw StateError('Timeout must be positive');
    final seconds = timeoutMs ~/ 1000;
    return (
      timeoutMs: timeoutMs,
      timeoutLabel: '$seconds second${seconds == 1 ? '' : 's'}',
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'INVALID_TIMEOUT',
      'Invalid timeout value',
      details: _errorText(error),
    );
  }
}

int _parsePaseoDuration(String input) {
  final trimmed = input.trim();
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    return int.parse(trimmed) * 1000;
  }
  if (!RegExp(r'^(?:\d+[smhd])+$').hasMatch(trimmed)) {
    throw FormatException(
      'Invalid duration format: $input. '
      'Use formats like: 5m, 30s, 1h, 2h30m, 1d',
    );
  }
  var totalMs = 0;
  for (final match in RegExp(r'(\d+)([smhd])').allMatches(trimmed)) {
    final value = int.parse(match.group(1)!);
    totalMs += switch (match.group(2)) {
      's' => value * 1000,
      'm' => value * 60 * 1000,
      'h' => value * 60 * 60 * 1000,
      'd' => value * 24 * 60 * 60 * 1000,
      _ => throw StateError('unreachable duration unit'),
    };
  }
  return totalMs;
}

Future<_AgentCommandResult> _waitAgent(
  AgentCliInvocation invocation,
  ({int timeoutMs, String? timeoutLabel}) timeout,
  AgentRpcRequester request,
) async {
  try {
    final payload = await request(
      WaitForFinishRequest(
        requestId: _requestId('agent_wait'),
        agentId: invocation.agentId!,
        timeoutMs: timeout.timeoutMs > 0 ? timeout.timeoutMs : null,
      ).toJson(),
    );
    final response = WaitForFinishResponse.fromJson({
      'type': WaitForFinishResponse.type,
      'payload': payload,
    });
    final resolvedId = response.finalAgent == null
        ? invocation.agentId!
        : _string(response.finalAgent!, 'id');
    final recentActivity =
        response.status == WaitForFinishStatus.timeout ||
            response.status == WaitForFinishStatus.idle
        ? await _recentAgentActivity(request, resolvedId)
        : null;
    final result = switch (response.status) {
      WaitForFinishStatus.timeout => {
        'agentId': resolvedId,
        'status': 'timeout',
        'message': _appendRecentActivity(
          timeout.timeoutLabel == null
              ? 'Agent wait timed out. Run `coding-agent wait $resolvedId` '
                    'again to keep waiting.'
              : 'Agent did not finish within ${timeout.timeoutLabel}. '
                    'Run `coding-agent wait $resolvedId` again to keep waiting.',
          recentActivity,
        ),
      },
      WaitForFinishStatus.permission => {
        'agentId': resolvedId,
        'status': 'permission',
        'message': _waitPermissionMessage(response.finalAgent),
      },
      WaitForFinishStatus.error => {
        'agentId': resolvedId,
        'status': 'error',
        'message': response.error ?? 'Agent finished with error',
      },
      WaitForFinishStatus.idle => {
        'agentId': resolvedId,
        'status': 'idle',
        'message': _appendRecentActivity('Agent is idle.', recentActivity),
      },
    };
    return _AgentCommandResult.wait(result);
  } on AgentCommandException {
    rethrow;
  } on Object catch (error) {
    throw AgentCommandException(
      'WAIT_FAILED',
      'Failed to wait for agent: ${_errorText(error)}',
    );
  }
}

Future<String?> _recentAgentActivity(
  AgentRpcRequester request,
  String agentId,
) async {
  try {
    final items = await fetchAgentTimelineItems(
      request,
      agentId,
      timeoutMs: 2000,
    );
    return formatAgentActivityTranscript(items, 5);
  } on Object {
    return null;
  }
}

String _appendRecentActivity(String message, String? transcript) {
  if (transcript == null || transcript.trim().isEmpty) return message;
  return '$message\nLast 5 activity items:\n$transcript';
}

String _waitPermissionMessage(Map<String, Object?>? finalAgent) {
  final pending = finalAgent?['pendingPermissions'];
  final permission = pending is List ? pending.firstOrNull : null;
  final kind = permission is Map ? permission['kind'] : null;
  return kind is String && kind.isNotEmpty
      ? 'Agent is waiting for permission: $kind'
      : 'Agent is waiting for permission';
}

Future<_AgentCommandResult> _archiveAgent(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
) async {
  try {
    final directoryPayload = await request(
      FetchAgentsRequest(
        requestId: _requestId('agent_archive_list'),
        filter: const AgentDirectoryFilter(includeArchived: true),
      ).toJson(),
    );
    final agents = _stopDirectoryAgents(directoryPayload);
    final agentId = _resolveArchiveAgentId(invocation.agentId!, agents);
    if (agentId == null) {
      throw AgentCommandException(
        'AGENT_NOT_FOUND',
        'Agent not found: ${invocation.agentId}',
        details: 'Use "coding-agent ls" to list available agents',
      );
    }
    final agent = agents.singleWhere(
      (candidate) => candidate['id'] == agentId,
      orElse: () => throw StateError(
        'Resolved agent missing from fetched agents: $agentId',
      ),
    );
    final archivedAt = agent['archivedAt'];
    if (archivedAt is String && archivedAt.isNotEmpty) {
      throw AgentCommandException(
        'AGENT_ALREADY_ARCHIVED',
        'Agent ${_shortAgentId(agentId)} is already archived',
        details: 'Archived at: $archivedAt',
      );
    }
    if (_string(agent, 'status') == 'running' && !invocation.force) {
      throw AgentCommandException(
        'AGENT_RUNNING',
        'Agent ${_shortAgentId(agentId)} is currently running',
        details:
            'Use --force to archive a running agent (it will interrupt the '
            'active run), or stop it first with: coding-agent agent stop. '
            'Use coding-agent agent delete to hard-delete it.',
      );
    }

    final payload = await request(
      ArchiveAgentRequest(
        requestId: _requestId('agent_archive'),
        agentId: agentId,
      ).toJson(),
    );
    final response = AgentArchivedResponse.fromJson({
      'type': AgentArchivedResponse.type,
      'payload': payload,
    });
    return _AgentCommandResult.archive({
      'agentId': agentId,
      'status': 'archived',
      'archivedAt': response.archivedAt,
    });
  } on AgentCommandException {
    rethrow;
  } on Object catch (error) {
    throw AgentCommandException(
      'ARCHIVE_FAILED',
      'Failed to archive agent: ${_errorText(error)}',
    );
  }
}

String? _resolveArchiveAgentId(
  String identifier,
  List<Map<String, Object?>> agents,
) {
  if (identifier.isEmpty || agents.isEmpty) return null;
  final query = identifier.toLowerCase();
  final exact = agents.where((agent) => agent['id'] == identifier).firstOrNull;
  if (exact != null) return _string(exact, 'id');
  final prefixMatches = agents
      .where((agent) => _string(agent, 'id').toLowerCase().startsWith(query))
      .toList(growable: false);
  if (prefixMatches.length == 1) return _string(prefixMatches.single, 'id');
  final exactTitleMatches = agents
      .where((agent) => _nullableString(agent['title'])?.toLowerCase() == query)
      .toList(growable: false);
  if (exactTitleMatches.length == 1) {
    return _string(exactTitleMatches.single, 'id');
  }
  final partialTitleMatches = agents
      .where(
        (agent) =>
            _nullableString(agent['title'])?.toLowerCase().contains(query) ==
            true,
      )
      .toList(growable: false);
  if (partialTitleMatches.length == 1) {
    return _string(partialTitleMatches.single, 'id');
  }
  final firstPrefix = prefixMatches.firstOrNull;
  return firstPrefix == null ? null : _string(firstPrefix, 'id');
}

Future<_AgentCommandResult> _stopAgents(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  void Function(String value) writeWarning,
) async {
  try {
    final directoryPayload = await request(
      FetchAgentsRequest(
        requestId: _requestId('agent_stop_list'),
        filter: const AgentDirectoryFilter(includeArchived: true),
      ).toJson(),
    );
    var agents = _stopDirectoryAgents(directoryPayload);
    if (invocation.stopAll) {
      agents = agents
          .where((agent) => agent['archivedAt'] == null)
          .toList(growable: false);
    } else if (invocation.cwd != null) {
      agents = agents
          .where(
            (agent) =>
                agent['archivedAt'] == null &&
                _isSameOrDescendantPath(invocation.cwd!, _string(agent, 'cwd')),
          )
          .toList(growable: false);
    } else {
      final payload = await request(
        FetchAgentRequest(
          requestId: _requestId('agent_stop_resolve'),
          agentId: invocation.agentId!,
        ).toJson(),
      );
      final responseError = payload['error'];
      if (responseError is String && responseError.isNotEmpty) {
        throw StateError(responseError);
      }
      final rawAgent = payload['agent'];
      if (rawAgent == null) {
        throw AgentCommandException(
          'AGENT_NOT_FOUND',
          'No agent found matching: ${invocation.agentId}',
          details: 'Use `coding-agent ls` to list available agents',
        );
      }
      if (rawAgent is! Map) {
        throw const FormatException(
          'fetch_agent_response contains an invalid agent',
        );
      }
      final agent = Map<String, Object?>.from(rawAgent);
      PaseoAgentSnapshotCodec.decode(agent);
      agents = [agent];
    }

    final results = await Future.wait([
      for (final agent in agents) _stopOneAgent(agent, request),
    ]);
    final stoppedIds = <String>[];
    for (final result in results) {
      if (result.error != null) {
        writeWarning(
          'Warning: Failed to stop agent '
          '${_shortAgentId(result.id)}: ${result.error}\n',
        );
      } else if (result.stopped) {
        stoppedIds.add(result.id);
      }
    }
    return _AgentCommandResult.stop({
      'stoppedCount': stoppedIds.length,
      'agentIds': stoppedIds,
    });
  } on AgentCommandException {
    rethrow;
  } on Object catch (error) {
    throw AgentCommandException(
      'STOP_AGENT_FAILED',
      'Failed to stop agent(s): ${_errorText(error)}',
    );
  }
}

List<Map<String, Object?>> _stopDirectoryAgents(Map<String, Object?> payload) {
  final entries = payload['entries'];
  if (entries is! List) {
    throw const FormatException('fetch_agents_response is missing entries');
  }
  final agents = <Map<String, Object?>>[];
  for (final rawEntry in entries) {
    if (rawEntry is! Map || rawEntry['agent'] is! Map) {
      throw const FormatException(
        'fetch_agents_response contains an invalid entry',
      );
    }
    final agent = Map<String, Object?>.from(rawEntry['agent'] as Map);
    PaseoAgentSnapshotCodec.decode(agent);
    agents.add(agent);
  }
  return agents;
}

Future<({String id, bool stopped, String? error})> _stopOneAgent(
  Map<String, Object?> agent,
  AgentRpcRequester request,
) async {
  final id = _string(agent, 'id');
  if (_string(agent, 'status') != 'running') {
    return (id: id, stopped: false, error: null);
  }
  try {
    final payload = await request(
      CancelAgentRequest(
        agentId: id,
        requestId: _requestId('agent_stop_cancel'),
      ).toJson(),
    );
    final response = CancelAgentResponse.fromJson({
      'type': CancelAgentResponse.type,
      'payload': payload,
    });
    if (response.error case final error?) throw StateError(error);
    if (response.agent case final agent?) {
      PaseoAgentSnapshotCodec.decode(agent);
    }
    return (id: id, stopped: true, error: null);
  } on Object catch (error) {
    return (id: id, stopped: false, error: _errorText(error));
  }
}

bool _isSameOrDescendantPath(String basePath, String candidatePath) {
  var base = basePath.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
  var candidate = candidatePath
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/$'), '');
  final windowsPath =
      RegExp(r'^[a-zA-Z]:/').hasMatch(base) ||
      RegExp(r'^[a-zA-Z]:/').hasMatch(candidate);
  if (windowsPath) {
    base = base.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  return candidate == base || candidate.startsWith('$base/');
}

String _shortAgentId(String id) => id.substring(0, id.length.clamp(0, 7));

Map<String, Object?> _agentListRow(
  Map<String, Object?> snapshot,
  Map<String, String> environment,
  DateTime now,
) {
  final id = _string(snapshot, 'id');
  final runtimeInfo = _mapOrNull(snapshot['runtimeInfo']);
  final model =
      _normalizeModel(runtimeInfo?['model']) ??
      _normalizeModel(snapshot['model']);
  final provider = _string(snapshot, 'provider');
  return {
    'id': id,
    'shortId': id.substring(0, id.length < 7 ? id.length : 7),
    'name': _nullableString(snapshot['title']) ?? '-',
    'provider': model == null ? provider : '$provider/$model',
    'thinking':
        _nullableString(snapshot['effectiveThinkingOptionId']) ?? 'auto',
    'status': _string(snapshot, 'status'),
    'cwd': _shortenPath(_string(snapshot, 'cwd'), environment),
    'created': _relativeTime(_date(snapshot, 'createdAt'), now),
  };
}

Map<String, Object?> _agentInspectData(Map<String, Object?> snapshot) {
  final runtimeInfo = _mapOrNull(snapshot['runtimeInfo']);
  final model =
      _normalizeModel(runtimeInfo?['model']) ??
      _normalizeModel(snapshot['model']);
  final usage = _mapOrNull(snapshot['lastUsage']);
  final capabilities = _mapOrNull(snapshot['capabilities']);
  final modes = snapshot['availableModes'];
  final pending = snapshot['pendingPermissions'];
  final labels = _mapOrNull(snapshot['labels']) ?? const {};
  return {
    'Id': _string(snapshot, 'id'),
    'Name': _nullableString(snapshot['title']) ?? '-',
    'Provider': _string(snapshot, 'provider'),
    'Model': model ?? '-',
    'Thinking':
        _nullableString(snapshot['effectiveThinkingOptionId']) ?? 'auto',
    'Status': _string(snapshot, 'status'),
    'Archived': snapshot['archivedAt'] != null,
    'ArchivedAt': snapshot['archivedAt'],
    'Mode': _nullableString(snapshot['currentModeId']) ?? 'default',
    'Cwd': _string(snapshot, 'cwd'),
    'CreatedAt': _string(snapshot, 'createdAt'),
    'UpdatedAt': _string(snapshot, 'updatedAt'),
    'LastUsage': usage == null
        ? null
        : {
            'InputTokens': _intOrZero(usage['inputTokens']),
            'OutputTokens': _intOrZero(usage['outputTokens']),
            'CachedTokens': _intOrZero(usage['cachedInputTokens']),
            'CostUsd': _numOrZero(usage['totalCostUsd']),
          },
    'Capabilities': capabilities == null
        ? null
        : {
            'Streaming': capabilities['supportsStreaming'] == true,
            'Persistence': capabilities['supportsSessionPersistence'] == true,
            'DynamicModes': capabilities['supportsDynamicModes'] == true,
            'McpServers': capabilities['supportsMcpServers'] == true,
          },
    'AvailableModes': modes is! List
        ? null
        : [
            for (final rawMode in modes)
              if (rawMode is Map)
                {
                  'id': _string(Map<String, Object?>.from(rawMode), 'id'),
                  'label': _string(Map<String, Object?>.from(rawMode), 'label'),
                },
          ],
    'PendingPermissions': pending is! List
        ? <Object?>[]
        : [
            for (final rawPermission in pending)
              if (rawPermission is Map)
                {
                  'id': _string(Map<String, Object?>.from(rawPermission), 'id'),
                  'tool':
                      _nullableString(
                        Map<String, Object?>.from(rawPermission)['name'],
                      ) ??
                      'unknown',
                },
          ],
    'Worktree': _nullableString(labels['paseo.worktree']),
    'ParentAgentId': _nullableString(labels[paseoParentAgentIdLabel]),
  };
}

List<Map<String, Object?>> _agentInspectRows(
  Map<String, Object?> data,
  Map<String, String> environment,
) {
  final rows = <Map<String, Object?>>[
    for (final key in const [
      'Id',
      'Name',
      'Provider',
      'Model',
      'Thinking',
      'Status',
      'Archived',
      'ArchivedAt',
      'Mode',
      'Cwd',
      'CreatedAt',
      'UpdatedAt',
    ])
      {
        'key': key,
        'value': switch (key) {
          'Cwd' => _shortenPath('${data[key]}', environment),
          _ => data[key]?.toString() ?? 'null',
        },
      },
  ];
  if (data['LastUsage'] case final Map usage) {
    final cost = (usage['CostUsd'] as num).toDouble();
    rows.add({
      'key': 'LastUsage',
      'value':
          'InputTokens: ${usage['InputTokens']}, '
          'OutputTokens: ${usage['OutputTokens']}, '
          'CachedTokens: ${usage['CachedTokens']}, '
          'CostUsd: ${_formatCost(cost)}',
    });
  }
  if (data['Capabilities'] case final Map capabilities) {
    rows.add({
      'key': 'Capabilities',
      'value':
          'Streaming: ${capabilities['Streaming']}, '
          'Persistence: ${capabilities['Persistence']}, '
          'DynamicModes: ${capabilities['DynamicModes']}, '
          'McpServers: ${capabilities['McpServers']}',
    });
  }
  final modes = data['AvailableModes'];
  if (modes is List && modes.isNotEmpty) {
    rows.add({
      'key': 'AvailableModes',
      'value': modes
          .whereType<Map>()
          .map((mode) => '${mode['id']} (${mode['label']})')
          .join(', '),
    });
  }
  final permissions = (data['PendingPermissions'] as List).whereType<Map>();
  rows.add({
    'key': 'PendingPermissions',
    'value': permissions.isEmpty
        ? '[]'
        : permissions
              .map(
                (permission) => '${permission['id']} (${permission['tool']})',
              )
              .join(', '),
  });
  rows.add({
    'key': 'Worktree',
    'value': data['Worktree']?.toString() ?? 'null',
  });
  rows.add({
    'key': 'ParentAgentId',
    'value': data['ParentAgentId']?.toString() ?? 'null',
  });
  return rows;
}

final class _AgentCommandResult {
  const _AgentCommandResult._({
    required this.rows,
    required this.kind,
    this.structured,
  });

  factory _AgentCommandResult.list(List<Map<String, Object?>> rows) =>
      _AgentCommandResult._(
        rows: List.unmodifiable(rows),
        kind: _AgentResultKind.agents,
      );

  factory _AgentCommandResult.inspect({
    required List<Map<String, Object?>> rows,
    required Map<String, Object?> structured,
  }) => _AgentCommandResult._(
    rows: List.unmodifiable(rows),
    kind: _AgentResultKind.inspect,
    structured: Map.unmodifiable(structured),
  );

  factory _AgentCommandResult.modes(List<Map<String, Object?>> rows) =>
      _AgentCommandResult._(
        rows: List.unmodifiable(rows),
        kind: _AgentResultKind.modes,
      );

  factory _AgentCommandResult.modeSet(Map<String, Object?> data) =>
      _AgentCommandResult._(
        rows: [Map.unmodifiable(data)],
        kind: _AgentResultKind.modeSet,
        structured: Map.unmodifiable(data),
      );

  factory _AgentCommandResult.stop(Map<String, Object?> data) =>
      _AgentCommandResult._(
        rows: [Map.unmodifiable(data)],
        kind: _AgentResultKind.stop,
        structured: Map.unmodifiable(data),
      );

  factory _AgentCommandResult.send(Map<String, Object?> data) =>
      _AgentCommandResult._(
        rows: [Map.unmodifiable(data)],
        kind: _AgentResultKind.send,
        structured: Map.unmodifiable(data),
      );

  factory _AgentCommandResult.wait(Map<String, Object?> data) =>
      _AgentCommandResult._(
        rows: [Map.unmodifiable(data)],
        kind: _AgentResultKind.wait,
        structured: Map.unmodifiable(data),
      );

  factory _AgentCommandResult.archive(Map<String, Object?> data) =>
      _AgentCommandResult._(
        rows: [Map.unmodifiable(data)],
        kind: _AgentResultKind.archive,
        structured: Map.unmodifiable(data),
      );

  final List<Map<String, Object?>> rows;
  final _AgentResultKind kind;
  final Object? structured;
}

enum _AgentResultKind {
  agents,
  inspect,
  modes,
  modeSet,
  stop,
  send,
  wait,
  archive,
}

String _render(_AgentCommandResult result, AgentCliInvocation invocation) {
  if (invocation.quiet) {
    final field = switch (result.kind) {
      _AgentResultKind.agents => 'shortId',
      _AgentResultKind.inspect => 'key',
      _AgentResultKind.modes => 'id',
      _AgentResultKind.modeSet => 'agentId',
      _AgentResultKind.stop => 'agentIds',
      _AgentResultKind.send => 'agentId',
      _AgentResultKind.wait => 'agentId',
      _AgentResultKind.archive => 'agentId',
    };
    if (result.kind == _AgentResultKind.stop) {
      final ids = result.rows.single['agentIds'];
      if (ids is! List || ids.isEmpty) return '';
      return '${ids.join('\n')}\n';
    }
    return result.rows.map((row) => row[field]).join('\n') +
        (result.rows.isEmpty ? '' : '\n');
  }
  final structured = result.structured ?? result.rows;
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(structured)}\n';
  }
  if (invocation.format == 'yaml') {
    return structured is Map
        ? _yamlMap(structured.cast<String, Object?>())
        : _yamlList(result.rows);
  }
  if (result.rows.isEmpty) return '';
  final columns = switch (result.kind) {
    _AgentResultKind.inspect => const [
      ('KEY', 'key', 3),
      ('VALUE', 'value', 5),
    ],
    _AgentResultKind.modes => const [
      ('MODE', 'id', 15),
      ('LABEL', 'label', 25),
      ('DESCRIPTION', 'description', 40),
    ],
    _AgentResultKind.modeSet => const [
      ('AGENT ID', 'agentId', 12),
      ('MODE', 'mode', 20),
    ],
    _AgentResultKind.stop => const [('INTERRUPTED', 'stoppedCount', 0)],
    _AgentResultKind.send || _AgentResultKind.wait => const [
      ('AGENT ID', 'agentId', 12),
      ('STATUS', 'status', 12),
      ('MESSAGE', 'message', 40),
    ],
    _AgentResultKind.archive => const [
      ('AGENT ID', 'agentId', 12),
      ('STATUS', 'status', 12),
      ('ARCHIVED AT', 'archivedAt', 24),
    ],
    _AgentResultKind.agents => const [
      ('AGENT ID', 'shortId', 12),
      ('NAME', 'name', 20),
      ('PROVIDER', 'provider', 15),
      ('THINKING', 'thinking', 12),
      ('STATUS', 'status', 10),
      ('CWD', 'cwd', 30),
      ('CREATED', 'created', 15),
    ],
  };
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in result.rows) '${row[column.$2] ?? ''}'.length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ');
  return [
        if (invocation.headers) line([for (final column in columns) column.$1]),
        for (final row in result.rows)
          line([for (final column in columns) '${row[column.$2] ?? ''}']),
      ].join('\n') +
      (invocation.headers || result.rows.isNotEmpty ? '\n' : '');
}

Map<String, String> _parseLabelFilters(List<String> labels) {
  final result = <String, String>{};
  for (final label in labels) {
    final separator = label.indexOf('=');
    if (separator >= 0) {
      result[label.substring(0, separator)] = label.substring(separator + 1);
    }
  }
  return result;
}

int _statusOrder(String status) => switch (status) {
  'running' => 0,
  'idle' => 1,
  _ => 999,
};

String _relativeTime(DateTime value, DateTime now) {
  final seconds = now.difference(value.toUtc()).inSeconds;
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return '${seconds ~/ 60} minutes ago';
  if (seconds < 86400) return '${seconds ~/ 3600} hours ago';
  return '${seconds ~/ 86400} days ago';
}

String _shortenPath(String path, Map<String, String> environment) {
  final home = environment['HOME'];
  if (home != null && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

String? _normalizeModel(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.toLowerCase() == 'default') return null;
  return normalized;
}

String _formatCost(double cost) {
  if (cost == 0) return r'$0.00';
  if (cost < 0.01) return '\$${cost.toStringAsFixed(4)}';
  return '\$${cost.toStringAsFixed(2)}';
}

String _yamlList(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlMap(Map<String, Object?> map, [int indent = 0]) {
  final prefix = ' ' * indent;
  final lines = <String>[];
  for (final entry in map.entries) {
    final value = entry.value;
    if (value is Map) {
      lines
        ..add('$prefix${entry.key}:')
        ..add(
          _yamlMap(Map<String, Object?>.from(value), indent + 2).trimRight(),
        );
    } else if (value is List) {
      if (value.isEmpty) {
        lines.add('$prefix${entry.key}: []');
      } else {
        lines.add('$prefix${entry.key}:');
        for (final item in value) {
          if (item is Map) {
            final itemMap = Map<String, Object?>.from(item);
            final first = itemMap.entries.first;
            lines.add(
              '${' ' * (indent + 2)}- ${first.key}: '
              '${_yamlScalar(first.value)}',
            );
            for (final nested in itemMap.entries.skip(1)) {
              lines.add(
                '${' ' * (indent + 4)}${nested.key}: '
                '${_yamlScalar(nested.value)}',
              );
            }
          } else {
            lines.add('${' ' * (indent + 2)}- ${_yamlScalar(item)}');
          }
        }
      }
    } else {
      lines.add('$prefix${entry.key}: ${_yamlScalar(value)}');
    }
  }
  return '${lines.join('\n')}\n';
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  final text = '$value';
  if (text.isNotEmpty &&
      !RegExp(
        r'''[:#\[\]{},&*!|>'"%@`]|^\s|\s$|^(null|true|false|~)$''',
        caseSensitive: false,
      ).hasMatch(text)) {
    return text;
  }
  return jsonEncode(text);
}

void _writeCommandError(
  void Function(String value) write,
  AgentCommandException error,
  List<String> arguments,
) {
  final json = arguments.contains('--json');
  final yaml =
      !json &&
      (arguments.contains('yaml') &&
          (arguments.contains('--format') || arguments.contains('-o')));
  if (json) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
      })}\n',
    );
  } else if (yaml) {
    write(
      _yamlMap({
        'error': {
          'code': error.code,
          'message': error.message,
          if (error.details != null) 'details': error.details,
        },
      }),
    );
  } else {
    write(
      'Error: ${error.message}\n'
      '${error.details == null ? '' : '${error.details}\n'}',
    );
  }
}

void _onlyList(String action, String option) {
  if (action != 'ls') {
    throw FormatException('$option is only valid for agent ls');
  }
}

void _onlySend(String action, String option) {
  if (action != 'send') {
    throw FormatException('$option is only valid for agent send');
  }
}

void _onlyWait(String action, String option) {
  if (action != 'wait') {
    throw FormatException('$option is only valid for agent wait');
  }
}

void _onlyArchive(String action, String option) {
  if (action != 'archive') {
    throw FormatException('$option is only valid for agent archive');
  }
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

String? _nullableString(Object? value) => value is String ? value : null;

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

DateTime _date(Map<String, Object?> json, String key) {
  final parsed = DateTime.tryParse(_string(json, key));
  if (parsed == null) throw FormatException('$key must be an ISO timestamp');
  return parsed;
}

int _intOrZero(Object? value) => value is num ? value.toInt() : 0;

num _numOrZero(Object? value) => value is num ? value : 0;

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class AgentCommandException implements Exception {
  const AgentCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const agentUsage =
    'Usage: coding-agent agent ls [options]\n'
    '       coding-agent agent inspect <id> [options]\n'
    '       coding-agent agent mode <id> <mode> [options]\n'
    '       coding-agent agent mode --list <id> [options]\n'
    '       coding-agent agent stop [<id>|--all|--cwd <path>] [options]\n'
    '       coding-agent agent send <id> [prompt] [options]\n'
    '       coding-agent agent wait <id> [options]\n'
    '       coding-agent agent archive <id-or-name> [options]\n'
    '       coding-agent ls [options]\n'
    '       coding-agent inspect <id> [options]';

String _agentHelp(String? action) => switch (action) {
  'ls' =>
    'Usage: coding-agent agent ls [options]\n'
        'List agents. By default excludes archived agents.\n',
  'inspect' =>
    'Usage: coding-agent agent inspect [options] <id>\n'
        'Show detailed information about an agent\n',
  'mode' =>
    'Usage: coding-agent agent mode [options] <id> [mode]\n'
        "Change an agent's operational mode\n",
  'stop' =>
    'Usage: coding-agent agent stop [options] [id]\n'
        'Interrupt an agent if it is running (no-op for idle agents)\n',
  'send' =>
    'Usage: coding-agent agent send [options] <id> [prompt]\n'
        'Send a message/task to an existing agent\n',
  'wait' =>
    'Usage: coding-agent agent wait [options] <id>\n'
        'Wait for an agent to become idle\n\n'
        '  --timeout <seconds>  Maximum wait time (default: no limit)\n',
  'archive' =>
    'Usage: coding-agent agent archive [options] <id>\n'
        'Archive an agent (soft-delete)\n\n'
        '  --force  Force archive running agent '
        '(interrupts active run first)\n',
  _ =>
    'Usage: coding-agent agent [command]\n'
        'Manage agents (advanced operations)\n\n'
        'Commands:\n'
        '  ls       List agents\n'
        '  inspect  Show detailed information about an agent\n'
        '  logs     View agent activity/timeline\n'
        '  mode     Change an agent\'s operational mode\n'
        '  stop     Interrupt a running agent\n'
        '  send     Send a message/task to an existing agent\n'
        '  wait     Wait for an agent to become idle\n'
        '  archive  Archive an agent (soft-delete)\n',
};
