import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';

const hubDaemonRpcTimeout = Duration(seconds: 5);

enum HubCommandAction { connect, status, disconnect }

final class HubCommandOptions {
  const HubCommandOptions({
    required this.action,
    this.home,
    this.hubUrl,
    this.token,
    this.force = false,
    this.json = false,
  });

  final HubCommandAction action;
  final String? home;
  final String? hubUrl;
  final String? token;
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
  HubManagementRequester request = requestRunningDaemonHubManagement,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: environment ?? Platform.environment,
  );
  try {
    final result = await request(config, options);
    final output = options.json
        ? '${const JsonEncoder.withIndent('  ').convert({'status': result.status.toJson(), if (result.warning != null) 'warning': result.warning})}\n'
        : _formatHuman(result);
    (writeOutput ?? stdout.write)(output);
    return 0;
  } catch (error) {
    (writeError ?? stderr.write)('Hub command failed: $error\n');
    return 1;
  }
}

Future<HubCommandResult> requestRunningDaemonHubManagement(
  DaemonRuntimeConfig config,
  HubCommandOptions options,
) async {
  final host = switch (config.host) {
    '0.0.0.0' || '::' => '127.0.0.1',
    final value => value,
  };
  final password = Platform.environment['TINYRACK_PASSWORD']?.trim();
  final socket = await WebSocket.connect(
    Uri(scheme: 'ws', host: host, port: config.port, path: '/ws').toString(),
    protocols: password == null || password.isEmpty
        ? null
        : ['tinyrack.bearer.$password'],
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

String _formatHuman(HubCommandResult result) {
  final status = result.status;
  final lines = <String>[
    'State: ${status.state.wireValue}',
    'Daemon: ${status.daemonId ?? '-'}',
    'Hub: ${status.hubOrigin ?? '-'}',
    'Scopes: ${status.scopes.isEmpty ? '-' : status.scopes.join(', ')}',
    'Connected at: ${status.connectedAt ?? '-'}',
    'Last error: ${status.lastError ?? '-'}',
    if (result.warning != null) 'Warning: ${result.warning}',
  ];
  return '${lines.join('\n')}\n';
}
