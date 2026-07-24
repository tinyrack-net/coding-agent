import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import 'connection.dart';

typedef RpcHandler = FutureOr<Map<String, Object?>> Function(
  Connection connection,
  Map<String, Object?> payload,
);

/// Maps request `type` strings to handlers and turns thrown errors into
/// `rpc_error`-style responses.
class RpcRouter {
  final Map<String, RpcHandler> _handlers = {};

  void on(String requestType, RpcHandler handler) {
    assert(requestType.endsWith('.request'), 'not a request type: $requestType');
    _handlers[requestType] = handler;
  }

  Future<RpcResponse> dispatch(Connection connection, RpcRequest request) async {
    final handler = _handlers[request.type];
    if (handler == null) {
      return request.fail(RpcError(
        code: RpcErrorCodes.unknownType,
        message: 'no handler for ${request.type}',
      ));
    }
    try {
      return request.respond(await handler(connection, request.payload));
    } on RpcException catch (e) {
      return request.fail(e.error);
    } catch (e) {
      return request.fail(
        RpcError(code: RpcErrorCodes.internal, message: e.toString()),
      );
    }
  }
}

/// Throw from a handler to return a typed error to the client.
class RpcException implements Exception {
  RpcException(String code, String message)
      : error = RpcError(code: code, message: message);

  final RpcError error;

  @override
  String toString() => error.toString();
}
