/// Wire envelopes for the daemon WebSocket protocol.
///
/// Text frames carry one JSON object each, in one of three shapes:
/// - request:  `{"type": "<domain>.<name>.request",  "requestId": "...", "payload": {...}}`
/// - response: `{"type": "<domain>.<name>.response", "requestId": "...", "payload": {...}}`
///             or `{"type": ..., "requestId": ..., "error": {"code": ..., "message": ...}}`
/// - event:    `{"type": "<domain>.<name>", "payload": {...}}` (no requestId)
library;

sealed class RpcFrame {
  const RpcFrame();

  Map<String, Object?> toJson();

  static RpcFrame fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    if (type == null) {
      throw FormatException('frame missing "type": $json');
    }
    final requestId = json['requestId'] as String?;
    final payload = (json['payload'] as Map<String, Object?>?) ?? const {};
    if (requestId == null) {
      return RpcEvent(type: type, payload: payload);
    }
    if (type.endsWith('.request')) {
      return RpcRequest(type: type, requestId: requestId, payload: payload);
    }
    final errorJson = json['error'] as Map<String, Object?>?;
    return RpcResponse(
      type: type,
      requestId: requestId,
      payload: payload,
      error: errorJson == null ? null : RpcError.fromJson(errorJson),
    );
  }
}

final class RpcRequest extends RpcFrame {
  const RpcRequest({
    required this.type,
    required this.requestId,
    this.payload = const {},
  });

  final String type;
  final String requestId;
  final Map<String, Object?> payload;

  /// `agent.create.request` -> `agent.create.response`
  String get responseType =>
      '${type.substring(0, type.length - '.request'.length)}.response';

  RpcResponse respond(Map<String, Object?> payload) =>
      RpcResponse(type: responseType, requestId: requestId, payload: payload);

  RpcResponse fail(RpcError error) =>
      RpcResponse(type: responseType, requestId: requestId, error: error);

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'payload': payload,
      };
}

final class RpcResponse extends RpcFrame {
  const RpcResponse({
    required this.type,
    required this.requestId,
    this.payload = const {},
    this.error,
  });

  final String type;
  final String requestId;
  final Map<String, Object?> payload;
  final RpcError? error;

  bool get isError => error != null;

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        if (error == null) 'payload': payload,
        if (error != null) 'error': error!.toJson(),
      };
}

final class RpcEvent extends RpcFrame {
  const RpcEvent({required this.type, this.payload = const {}});

  final String type;
  final Map<String, Object?> payload;

  @override
  Map<String, Object?> toJson() => {'type': type, 'payload': payload};
}

final class RpcError {
  const RpcError({required this.code, required this.message});

  final String code;
  final String message;

  static RpcError fromJson(Map<String, Object?> json) => RpcError(
        code: (json['code'] as String?) ?? 'unknown',
        message: (json['message'] as String?) ?? '',
      );

  Map<String, Object?> toJson() => {'code': code, 'message': message};

  @override
  String toString() => 'RpcError($code: $message)';
}

/// Well-known error codes.
abstract final class RpcErrorCodes {
  static const unknownType = 'unknown_type';
  static const invalidPayload = 'invalid_payload';
  static const notFound = 'not_found';
  static const internal = 'internal';
  static const unauthorized = 'unauthorized';

  /// The request conflicts with current state and needs explicit
  /// confirmation to proceed (e.g. archiving a worktree with uncommitted
  /// changes without `force`).
  static const conflict = 'conflict';
}
