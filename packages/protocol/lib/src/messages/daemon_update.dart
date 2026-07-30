enum DaemonUpdatePhase {
  starting,
  downloading,
  installing,
  complete;

  static DaemonUpdatePhase parse(Object? value) => switch (value) {
    'starting' => starting,
    'downloading' => downloading,
    'installing' => installing,
    'complete' => complete,
    _ => throw FormatException('Unknown daemon update phase: $value'),
  };
}

final class DaemonUpdateRequest {
  const DaemonUpdateRequest({required this.requestId});

  static const type = 'daemon.update.request';

  final String requestId;

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class DaemonUpdateProgress {
  const DaemonUpdateProgress({required this.requestId, required this.phase});

  static const type = 'daemon.update.progress';

  final String requestId;
  final DaemonUpdatePhase phase;

  factory DaemonUpdateProgress.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected daemon.update.progress');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('Daemon update progress payload is required');
    }
    final values = Map<String, Object?>.from(payload);
    final requestId = values['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw const FormatException('Daemon update requestId is required');
    }
    return DaemonUpdateProgress(
      requestId: requestId,
      phase: DaemonUpdatePhase.parse(values['phase']),
    );
  }
}

final class DaemonUpdateResponse {
  const DaemonUpdateResponse({
    required this.requestId,
    required this.success,
    this.error,
    this.previousVersion,
    this.newVersion,
  });

  static const type = 'daemon.update.response';

  final String requestId;
  final bool success;
  final String? error;
  final String? previousVersion;
  final String? newVersion;

  factory DaemonUpdateResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected daemon.update.response');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('Daemon update response payload is required');
    }
    final values = Map<String, Object?>.from(payload);
    final requestId = values['requestId'];
    final success = values['success'];
    if (requestId is! String || requestId.isEmpty) {
      throw const FormatException('Daemon update requestId is required');
    }
    if (success is! bool) {
      throw const FormatException('Daemon update success is required');
    }
    return DaemonUpdateResponse(
      requestId: requestId,
      success: success,
      error: values['error'] as String?,
      previousVersion: values['previousVersion'] as String?,
      newVersion: values['newVersion'] as String?,
    );
  }
}
