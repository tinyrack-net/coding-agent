enum HubConnectionState {
  notConnected('not_connected'),
  connecting('connecting'),
  connected('connected'),
  reconnecting('reconnecting'),
  disconnecting('disconnecting'),
  revoked('revoked');

  const HubConnectionState(this.wireValue);
  final String wireValue;

  static HubConnectionState fromWire(Object? value) {
    for (final state in values) {
      if (state.wireValue == value) return state;
    }
    throw FormatException('Unknown Hub connection state: $value');
  }
}

final class HubRelationshipStatus {
  const HubRelationshipStatus({
    required this.state,
    required this.daemonId,
    required this.hubOrigin,
    required this.scopes,
    required this.connectedAt,
    required this.lastError,
  });

  const HubRelationshipStatus.notConnected()
    : state = HubConnectionState.notConnected,
      daemonId = null,
      hubOrigin = null,
      scopes = const [],
      connectedAt = null,
      lastError = null;

  final HubConnectionState state;
  final String? daemonId;
  final String? hubOrigin;
  final List<String> scopes;
  final String? connectedAt;
  final String? lastError;

  factory HubRelationshipStatus.fromJson(Map<String, Object?> json) {
    final daemonId = json['daemonId'];
    final hubOrigin = json['hubOrigin'];
    final scopes = json['scopes'];
    final connectedAt = json['connectedAt'];
    final lastError = json['lastError'];
    if ((daemonId != null && daemonId is! String) ||
        (hubOrigin != null && hubOrigin is! String) ||
        scopes is! List ||
        scopes.any((scope) => scope is! String) ||
        (connectedAt != null && connectedAt is! String) ||
        (lastError != null && lastError is! String)) {
      throw const FormatException('Invalid Hub relationship status');
    }
    return HubRelationshipStatus(
      state: HubConnectionState.fromWire(json['state']),
      daemonId: daemonId as String?,
      hubOrigin: hubOrigin as String?,
      scopes: List<String>.unmodifiable(scopes.cast<String>()),
      connectedAt: connectedAt as String?,
      lastError: lastError as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'state': state.wireValue,
    'daemonId': daemonId,
    'hubOrigin': hubOrigin,
    'scopes': scopes,
    'connectedAt': connectedAt,
    'lastError': lastError,
  };
}

sealed class HubManagementDaemonRequest {
  const HubManagementDaemonRequest({required this.requestId});
  final String requestId;

  factory HubManagementDaemonRequest.fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    return switch (json['type']) {
      HubManagementDaemonConnectRequest.type =>
        HubManagementDaemonConnectRequest.fromJson(json),
      HubManagementDaemonGetStatusRequest.type =>
        HubManagementDaemonGetStatusRequest(requestId: requestId),
      HubManagementDaemonDisconnectRequest.type =>
        HubManagementDaemonDisconnectRequest.fromJson(json),
      _ => throw const FormatException(
        'Unknown Hub relationship management request',
      ),
    };
  }

  Map<String, Object?> toJson();
}

final class HubManagementDaemonConnectRequest
    extends HubManagementDaemonRequest {
  const HubManagementDaemonConnectRequest({
    required super.requestId,
    required this.hubUrl,
    required this.token,
  });

  static const type = 'hub.management.daemon.connect.request';
  final String hubUrl;
  final String token;

  factory HubManagementDaemonConnectRequest.fromJson(
    Map<String, Object?> json,
  ) {
    if (json['type'] != type ||
        json['requestId'] is! String ||
        json['hubUrl'] is! String ||
        json['token'] is! String) {
      throw const FormatException('Invalid Hub connect request');
    }
    return HubManagementDaemonConnectRequest(
      requestId: json['requestId'] as String,
      hubUrl: json['hubUrl'] as String,
      token: json['token'] as String,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'hubUrl': hubUrl,
    'token': token,
  };
}

final class HubManagementDaemonGetStatusRequest
    extends HubManagementDaemonRequest {
  const HubManagementDaemonGetStatusRequest({required super.requestId});
  static const type = 'hub.management.daemon.get_status.request';

  @override
  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class HubManagementDaemonDisconnectRequest
    extends HubManagementDaemonRequest {
  const HubManagementDaemonDisconnectRequest({
    required super.requestId,
    this.force = false,
  });

  static const type = 'hub.management.daemon.disconnect.request';
  final bool force;

  factory HubManagementDaemonDisconnectRequest.fromJson(
    Map<String, Object?> json,
  ) {
    if (json['type'] != type ||
        json['requestId'] is! String ||
        (json['force'] != null && json['force'] is! bool)) {
      throw const FormatException('Invalid Hub disconnect request');
    }
    return HubManagementDaemonDisconnectRequest(
      requestId: json['requestId'] as String,
      force: json['force'] as bool? ?? false,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (force) 'force': true,
  };
}

sealed class HubManagementDaemonResponse {
  const HubManagementDaemonResponse({
    required this.requestId,
    required this.status,
  });

  final String requestId;
  final HubRelationshipStatus status;
  Map<String, Object?> toJson();

  static ({String requestId, HubRelationshipStatus status}) parsePayload(
    Map<String, Object?> json,
    String type,
  ) {
    if (json['type'] != type || json['payload'] is! Map<String, Object?>) {
      throw const FormatException('Invalid Hub management response envelope');
    }
    final payload = json['payload'] as Map<String, Object?>;
    if (payload['requestId'] is! String ||
        payload['status'] is! Map<String, Object?>) {
      throw const FormatException('Invalid Hub management response payload');
    }
    return (
      requestId: payload['requestId'] as String,
      status: HubRelationshipStatus.fromJson(
        payload['status'] as Map<String, Object?>,
      ),
    );
  }
}

final class HubManagementDaemonConnectResponse
    extends HubManagementDaemonResponse {
  const HubManagementDaemonConnectResponse({
    required super.requestId,
    required super.status,
  });
  static const type = 'hub.management.daemon.connect.response';

  factory HubManagementDaemonConnectResponse.fromJson(
    Map<String, Object?> json,
  ) {
    final parsed = HubManagementDaemonResponse.parsePayload(json, type);
    return HubManagementDaemonConnectResponse(
      requestId: parsed.requestId,
      status: parsed.status,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'requestId': requestId, 'status': status.toJson()},
  };
}

final class HubManagementDaemonGetStatusResponse
    extends HubManagementDaemonResponse {
  const HubManagementDaemonGetStatusResponse({
    required super.requestId,
    required super.status,
  });
  static const type = 'hub.management.daemon.get_status.response';

  factory HubManagementDaemonGetStatusResponse.fromJson(
    Map<String, Object?> json,
  ) {
    final parsed = HubManagementDaemonResponse.parsePayload(json, type);
    return HubManagementDaemonGetStatusResponse(
      requestId: parsed.requestId,
      status: parsed.status,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'requestId': requestId, 'status': status.toJson()},
  };
}

final class HubManagementDaemonDisconnectResponse
    extends HubManagementDaemonResponse {
  const HubManagementDaemonDisconnectResponse({
    required super.requestId,
    required super.status,
    this.warning,
  });
  static const type = 'hub.management.daemon.disconnect.response';
  final String? warning;

  factory HubManagementDaemonDisconnectResponse.fromJson(
    Map<String, Object?> json,
  ) {
    final parsed = HubManagementDaemonResponse.parsePayload(json, type);
    final payload = json['payload'] as Map<String, Object?>;
    if (payload['warning'] != null && payload['warning'] is! String) {
      throw const FormatException('warning must be a string');
    }
    return HubManagementDaemonDisconnectResponse(
      requestId: parsed.requestId,
      status: parsed.status,
      warning: payload['warning'] as String?,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'status': status.toJson(),
      if (warning != null) 'warning': warning,
    },
  };
}
