import 'checkout_pr.dart';

/// Frozen Paseo 0.2.0 manual checkout refresh request.
final class CheckoutRefreshRequest {
  const CheckoutRefreshRequest({required this.cwd, required this.requestId});

  static const type = 'checkout.refresh.request';

  final String cwd;
  final String requestId;

  factory CheckoutRefreshRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutRefreshRequest(
      cwd: _string(json['cwd'], 'cwd'),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'requestId': requestId,
  };
}

/// Frozen Paseo 0.2.0 manual checkout refresh response.
final class CheckoutRefreshResponse {
  const CheckoutRefreshResponse({
    required this.cwd,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout.refresh.response';

  final String cwd;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutRefreshResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json['payload'], 'payload');
    if (!payload.containsKey('error')) {
      throw const FormatException('payload.error is required');
    }
    final rawError = payload['error'];
    return CheckoutRefreshResponse(
      cwd: _string(payload['cwd'], 'payload.cwd'),
      success: _bool(payload['success'], 'payload.success'),
      error: rawError == null
          ? null
          : CheckoutError.fromJson(_map(rawError, 'payload.error')),
      requestId: _string(payload['requestId'], 'payload.requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'success': success,
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}
