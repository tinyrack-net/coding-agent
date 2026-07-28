final class DiagnosticsRequest {
  const DiagnosticsRequest({required this.requestId});
  static const type = 'diagnostics.request';
  final String requestId;

  factory DiagnosticsRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type || json['requestId'] is! String) {
      throw const FormatException('Invalid diagnostics request');
    }
    return DiagnosticsRequest(requestId: json['requestId'] as String);
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class DiagnosticsResponse {
  const DiagnosticsResponse({
    required this.requestId,
    required this.diagnostic,
  });
  static const type = 'diagnostics.response';
  final String requestId;
  final String diagnostic;

  factory DiagnosticsResponse.fromJson(Map<String, Object?> json) {
    final payload = json['payload'];
    if (json['type'] != type ||
        payload is! Map<String, Object?> ||
        payload['requestId'] is! String ||
        payload['diagnostic'] is! String) {
      throw const FormatException('Invalid diagnostics response');
    }
    return DiagnosticsResponse(
      requestId: payload['requestId'] as String,
      diagnostic: payload['diagnostic'] as String,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'requestId': requestId, 'diagnostic': diagnostic},
  };
}
