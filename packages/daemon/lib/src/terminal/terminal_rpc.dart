/// RPC handlers for M5 terminal features.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../server/rpc_router.dart';
import 'terminal_manager.dart';

/// Wires terminal request types into [router].
void registerTerminalHandlers(
  RpcRouter router, {
  required TerminalManager terminals,
}) {
  router.on(MessageTypes.terminalCreateRequest, (connection, payload) {
    final cwd = payload['cwd'] as String?;
    if (cwd == null || cwd.isEmpty) {
      throw RpcException(RpcErrorCodes.invalidPayload, 'cwd is required');
    }
    final workspaceId = payload['workspaceId'];
    if (workspaceId != null && workspaceId is! String) {
      throw RpcException(
        RpcErrorCodes.invalidPayload,
        'workspaceId must be a string',
      );
    }
    final terminal = terminals.create(
      cwd: cwd,
      workspaceId: workspaceId as String?,
      cols: (payload['cols'] as num?)?.toInt(),
      rows: (payload['rows'] as num?)?.toInt(),
    );
    return {'terminal': terminal};
  });

  router.on(MessageTypes.terminalListRequest, (connection, payload) {
    return {'terminals': terminals.list()};
  });

  router.on(MessageTypes.terminalKillRequest, (connection, payload) {
    _known(() => terminals.kill(_requireString(payload, 'terminalId')));
    return const <String, Object?>{};
  });

  router.on(MessageTypes.terminalSubscribeRequest, (connection, payload) {
    final slotId = _known(
      () => terminals.subscribe(
        connection.id,
        _requireString(payload, 'terminalId'),
      ),
    );
    return {'slotId': slotId};
  });

  router.on(MessageTypes.terminalUnsubscribeRequest, (connection, payload) {
    _known(
      () => terminals.unsubscribe(
        connection.id,
        _requireString(payload, 'terminalId'),
      ),
    );
    return const <String, Object?>{};
  });
}

/// Maps the manager's unknown-terminal [StateError] to an RPC notFound.
T _known<T>(T Function() body) {
  try {
    return body();
  } on StateError catch (e) {
    throw RpcException(RpcErrorCodes.notFound, e.message);
  }
}

String _requireString(Map<String, Object?> payload, String key) {
  final value = payload[key] as String?;
  if (value == null || value.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, '$key is required');
  }
  return value;
}
