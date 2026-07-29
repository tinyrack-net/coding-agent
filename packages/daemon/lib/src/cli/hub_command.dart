import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'hub_device_authorization.dart';
import 'schedule_command.dart';

const hubDaemonRpcTimeout = Duration(seconds: 15);

enum HubCommandAction { connect, status, disconnect }

final class HubCommandOptions {
  const HubCommandOptions({
    required this.action,
    this.home,
    this.hubUrl,
    this.token,
    this.host,
    this.force = false,
    this.json = false,
  });

  final HubCommandAction action;
  final String? home;
  final String? hubUrl;
  final String? token;
  final String? host;
  final bool force;
  final bool json;
}

final class HubCommandResult {
  const HubCommandResult({required this.status, this.warning});
  final HubRelationshipStatus status;
  final String? warning;
}

typedef HubManagementRequester =
    Future<HubCommandResult> Function(
      DaemonRuntimeConfig config,
      HubCommandOptions options,
    );

Future<int> runHubCommand({
  required HubCommandOptions options,
  Map<String, String>? environment,
  HubManagementRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final env = environment ?? Platform.environment;
  final config = loadDaemonRuntimeConfig(home: options.home, environment: env);
  try {
    final requester =
        request ??
        (config, options) => requestRunningDaemonHubManagement(
          config,
          options,
          environment: env,
        );
    final result = await requester(config, options);
    final output = _formatHubResult(result, json: options.json);
    (writeOutput ?? stdout.write)(output);
    return 0;
  } catch (error) {
    (writeError ?? stderr.write)('Hub command failed: $error\n');
    return 1;
  }
}

typedef HubDeviceAuthorizer =
    Future<String> Function(String hubUrl, String displayName);

Future<int> runHubCliCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  HubManagementRequester? request,
  HubDeviceAuthorizer? authorize,
  String Function()? displayName,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (_hasOptionBeforeTerminator(arguments, const {'--help', '-h'})) {
    output(hubHelp(arguments.isEmpty ? null : arguments.first));
    return 0;
  }
  final jsonOutput = _hasOptionBeforeTerminator(arguments, const {'--json'});
  try {
    final invocation = HubCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    final config = loadDaemonRuntimeConfig(environment: env);
    final requester =
        request ??
        (config, options) => requestRunningDaemonHubManagement(
          config,
          options,
          environment: env,
        );
    final result = await _executeHubCli(
      invocation,
      config,
      requester,
      authorize: authorize ?? (url, name) => authorizeHubDevice(url, name),
      displayName: displayName ?? () => Platform.localHostname,
    );
    output(_formatHubResult(result, json: invocation.json));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$_hubUsage\n');
    return 64;
  } on Object catch (error, stackTrace) {
    final message = _errorText(error);
    if (jsonOutput) {
      errorOutput(
        '${const JsonEncoder.withIndent('  ').convert({
          'error': {'code': 'UNKNOWN_ERROR', 'message': message, 'details': stackTrace.toString()},
        })}\n',
      );
    } else {
      errorOutput('Error: $message\n$stackTrace');
    }
    return 1;
  }
}

final class HubCliInvocation {
  const HubCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.flags,
    required this.json,
    required this.host,
  });

  final HubCommandAction action;
  final List<String> positionals;
  final Map<String, String> values;
  final Set<String> flags;
  final bool json;
  final String? host;

  static HubCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) throw const FormatException('Missing hub action');
    final action = switch (arguments.first) {
      'connect' => HubCommandAction.connect,
      'status' => HubCommandAction.status,
      'disconnect' => HubCommandAction.disconnect,
      final value => throw FormatException('Unknown hub action: $value'),
    };
    final valueOptions = {
      '--host',
      if (action == HubCommandAction.connect) '--token',
    };
    final booleanOptions = {
      '--json',
      if (action == HubCommandAction.disconnect) '--force',
    };
    final positionals = <String>[];
    final values = <String, String>{};
    final flags = <String>{};
    var positionalOnly = false;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly && argument == '--') {
        positionalOnly = true;
      } else if (positionalOnly) {
        positionals.add(argument);
      } else if (booleanOptions.contains(argument)) {
        flags.add(argument);
      } else if (valueOptions.contains(argument)) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        values[argument] = arguments[++index];
      } else if (_splitLongOption(argument) case (
        final option,
        final value,
      ) when valueOptions.contains(option)) {
        values[option] = value;
      } else if (argument.startsWith('-')) {
        throw FormatException('Unknown option: $argument');
      } else {
        positionals.add(argument);
      }
    }
    final expected = action == HubCommandAction.connect ? 1 : 0;
    if (positionals.length != expected) {
      throw FormatException(
        action == HubCommandAction.connect
            ? 'hub connect requires one Hub URL'
            : 'hub ${action.name} does not accept an argument',
      );
    }
    return HubCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      flags: Set.unmodifiable(flags),
      json: flags.contains('--json'),
      host: values['--host'],
    );
  }
}

Future<HubCommandResult> _executeHubCli(
  HubCliInvocation invocation,
  DaemonRuntimeConfig config,
  HubManagementRequester request, {
  required HubDeviceAuthorizer authorize,
  required String Function() displayName,
}) async {
  switch (invocation.action) {
    case HubCommandAction.connect:
      final url = invocation.positionals.single;
      var token = invocation.values['--token'];
      if (token == null) {
        final existing = await request(
          config,
          HubCommandOptions(
            action: HubCommandAction.status,
            host: invocation.host,
          ),
        );
        if (existing.status.state != HubConnectionState.notConnected &&
            existing.status.state != HubConnectionState.revoked) {
          throw StateError('This daemon already has a Hub relationship');
        }
        token = await authorize(url, suggestedHubDisplayName(displayName()));
      }
      return request(
        config,
        HubCommandOptions(
          action: HubCommandAction.connect,
          hubUrl: url,
          token: token,
          host: invocation.host,
        ),
      );
    case HubCommandAction.status:
      return request(
        config,
        HubCommandOptions(
          action: HubCommandAction.status,
          host: invocation.host,
        ),
      );
    case HubCommandAction.disconnect:
      return request(
        config,
        HubCommandOptions(
          action: HubCommandAction.disconnect,
          host: invocation.host,
          force: invocation.flags.contains('--force'),
        ),
      );
  }
}

String suggestedHubDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'Tinyrack daemon';
  return trimmed.substring(0, trimmed.length.clamp(0, 100));
}

Future<HubCommandResult> requestRunningDaemonHubManagement(
  DaemonRuntimeConfig config,
  HubCommandOptions options, {
  Map<String, String>? environment,
}) async {
  final endpoint = resolveScheduleDaemonEndpoint(
    config,
    hostOverride: options.host,
    environment: environment ?? Platform.environment,
  );
  final socket = await WebSocket.connect(
    endpoint.webSocketUri.toString(),
    protocols: endpoint.password == null
        ? null
        : ['tinyrack.bearer.${endpoint.password}'],
    compression: CompressionOptions.compressionOff,
  ).timeout(hubDaemonRpcTimeout);
  final frames = StreamIterator<dynamic>(socket);
  try {
    socket.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'coding-agent-cli',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await _nextSessionMessage(
      frames,
      (message) => message['status'] == 'server_info',
      allowEnvelope: false,
    );
    final requestId = 'hub_${DateTime.now().microsecondsSinceEpoch}';
    final request = switch (options.action) {
      HubCommandAction.connect => HubManagementDaemonConnectRequest(
        requestId: requestId,
        hubUrl: options.hubUrl!,
        token: options.token!,
      ).toJson(),
      HubCommandAction.status => HubManagementDaemonGetStatusRequest(
        requestId: requestId,
      ).toJson(),
      HubCommandAction.disconnect => HubManagementDaemonDisconnectRequest(
        requestId: requestId,
        force: options.force,
      ).toJson(),
    };
    socket.add(jsonEncode({'type': 'session', 'message': request}));
    final response = await _nextSessionMessage(frames, (message) {
      final payload = message['payload'];
      return payload is Map && payload['requestId'] == requestId;
    });
    if (response['type'] == 'rpc_error') {
      final payload = response['payload'] as Map;
      throw StateError(payload['error'] as String? ?? 'Hub RPC failed');
    }
    return switch (options.action) {
      HubCommandAction.connect => HubCommandResult(
        status: HubManagementDaemonConnectResponse.fromJson(response).status,
      ),
      HubCommandAction.status => HubCommandResult(
        status: HubManagementDaemonGetStatusResponse.fromJson(response).status,
      ),
      HubCommandAction.disconnect => () {
        final decoded = HubManagementDaemonDisconnectResponse.fromJson(
          response,
        );
        return HubCommandResult(
          status: decoded.status,
          warning: decoded.warning,
        );
      }(),
    };
  } finally {
    await frames.cancel();
    await socket.close();
  }
}

Future<Map<String, Object?>> _nextSessionMessage(
  StreamIterator<dynamic> frames,
  bool Function(Map<String, Object?> message) predicate, {
  bool allowEnvelope = true,
}) async {
  final deadline = DateTime.now().add(hubDaemonRpcTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (!await frames.moveNext().timeout(remaining)) {
      throw StateError('Daemon closed during Hub request');
    }
    final frame = frames.current;
    if (frame is! String) continue;
    final decoded = jsonDecode(frame);
    if (decoded is! Map<String, Object?>) continue;
    final candidate =
        allowEnvelope &&
            decoded['type'] == 'session' &&
            decoded['message'] is Map
        ? (decoded['message'] as Map).cast<String, Object?>()
        : decoded;
    if (predicate(candidate)) return candidate;
  }
  throw TimeoutException('Daemon Hub request timed out');
}

String _formatHubResult(HubCommandResult result, {required bool json}) {
  final status = result.status;
  final row = <String, Object?>{
    'state': status.state.wireValue,
    'daemonId': status.daemonId,
    'hub': status.hubOrigin,
    'scopes': status.scopes.join(', '),
    'connectedAt': status.connectedAt,
    'error': status.lastError,
    if (result.warning != null) 'warning': result.warning,
  };
  if (json) {
    return '${const JsonEncoder.withIndent('  ').convert([row])}\n';
  }
  return _table(
    const ['STATE', 'HUB', 'DAEMON', 'SCOPES', 'CONNECTED', 'ERROR', 'WARNING'],
    [
      [
        '${row['state'] ?? ''}',
        '${row['hub'] ?? ''}',
        '${row['daemonId'] ?? ''}',
        '${row['scopes'] ?? ''}',
        '${row['connectedAt'] ?? ''}',
        '${row['error'] ?? ''}',
        '${row['warning'] ?? ''}',
      ],
    ],
  );
}

String _table(List<String> headers, List<List<String>> rows) {
  final widths = [
    for (var column = 0; column < headers.length; column++)
      [
        headers[column].length,
        for (final row in rows) row[column].length,
      ].reduce((left, right) => left > right ? left : right),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ');
  return '${[line(headers), for (final row in rows) line(row)].join('\n')}\n';
}

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

String hubHelp(String? action) => switch (action) {
  'connect' =>
    'Usage: coding-agent hub connect <url> [options]\n'
        "Connect this daemon to Tinyrack Hub\n\n"
        'Options:\n'
        '  --token <token>  Enrollment token '
        '(opens browser authorization when omitted)\n'
        '  --host <host>    Daemon host target\n'
        '  --json           Output in JSON format\n',
  'status' =>
    'Usage: coding-agent hub status [options]\n'
        'Show this daemon Hub relationship\n\n'
        'Options:\n'
        '  --host <host>    Daemon host target\n'
        '  --json           Output in JSON format\n',
  'disconnect' =>
    'Usage: coding-agent hub disconnect [options]\n'
        'Disconnect this daemon from Tinyrack Hub\n\n'
        'Options:\n'
        '  --force          Remove local authority even if the Hub is offline\n'
        '  --host <host>    Daemon host target\n'
        '  --json           Output in JSON format\n',
  _ =>
    'Usage: coding-agent hub <command> [options]\n'
        "Manage this daemon's Tinyrack Hub relationship\n\n"
        'Commands: connect, status, disconnect\n',
};

bool _hasOptionBeforeTerminator(List<String> arguments, Set<String> options) {
  for (final argument in arguments) {
    if (argument == '--') return false;
    if (options.contains(argument)) return true;
  }
  return false;
}

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

const _hubUsage = 'Usage: coding-agent hub <connect|status|disconnect> ...';
