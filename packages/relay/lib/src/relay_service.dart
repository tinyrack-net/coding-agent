import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'relay_types.dart';

typedef RelayConnectionIdFactory = String Function();
typedef RelayClock = int Function();
typedef RelayLog = void Function(String message);

abstract interface class RelaySocket {
  void send(Object frame);
  void close(int code, String reason);
}

final class RelayAttachRequest {
  const RelayAttachRequest({
    required this.serverId,
    required this.role,
    required this.version,
    this.connectionId,
  });

  final String serverId;
  final RelayConnectionRole role;
  final String version;
  final String? connectionId;
}

/// In-memory equivalent of Paseo's version-isolated Relay Durable Object.
///
/// One instance owns one `(relayVersion, serverId)` session. The outer HTTP
/// adapter is responsible for isolating those keys exactly as the Cloudflare
/// worker does.
final class RelaySession implements DisposableRelaySession {
  RelaySession({
    RelayConnectionIdFactory? connectionIdFactory,
    RelayClock? clock,
    RelayLog? log,
    this.initialControlNudgeDelay = const Duration(seconds: 10),
    this.controlResetDelay = const Duration(seconds: 5),
    this.maxPendingFrames = 200,
  }) : _connectionIdFactory = connectionIdFactory ?? _randomConnectionId,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _log = log ?? _discardLog;

  final Duration initialControlNudgeDelay;
  final Duration controlResetDelay;
  final int maxPendingFrames;
  final RelayConnectionIdFactory _connectionIdFactory;
  final RelayClock _clock;
  final RelayLog _log;

  final Map<RelaySocket, RelaySessionAttachment> _attachments = Map.identity();
  final Map<String, List<Object>> _pendingFrames = {};
  final Map<String, Timer> _nudgeTimers = {};
  bool _disposed = false;

  int get connectionCount => _attachments.length;

  Iterable<RelaySessionAttachment> get attachments =>
      List.unmodifiable(_attachments.values);

  RelaySessionAttachment? attachmentOf(RelaySocket socket) =>
      _attachments[socket];

  RelaySessionAttachment attach(
    RelaySocket socket,
    RelayAttachRequest request,
  ) {
    if (_disposed) throw StateError('Relay session is disposed');
    if (request.version != '1' && request.version != '2') {
      throw const FormatException('Relay version must be "1" or "2"');
    }
    if (request.serverId.trim().isEmpty) {
      throw const FormatException('serverId is required');
    }

    if (request.version == '1') {
      _replaceWhere(
        (attachment) => attachment.role == request.role,
        1008,
        'Replaced by new connection',
      );
      final attachment = RelaySessionAttachment(
        serverId: request.serverId,
        role: request.role,
        version: '1',
        connectionId: null,
        createdAt: _clock(),
      );
      _attachments[socket] = attachment;
      _log('v1:${request.role.wireValue} connected');
      return attachment;
    }

    final requestedConnectionId = request.connectionId?.trim() ?? '';
    final connectionId =
        request.role == RelayConnectionRole.client &&
            requestedConnectionId.isEmpty
        ? _connectionIdFactory()
        : requestedConnectionId;
    final isServerControl =
        request.role == RelayConnectionRole.server && connectionId.isEmpty;
    final isServerData =
        request.role == RelayConnectionRole.server && connectionId.isNotEmpty;

    if (isServerControl) {
      _replaceWhere(
        (attachment) =>
            attachment.version == '2' &&
            attachment.role == RelayConnectionRole.server &&
            attachment.connectionId == null,
        1008,
        'Replaced by new connection',
      );
    } else if (isServerData) {
      _replaceWhere(
        (attachment) =>
            attachment.version == '2' &&
            attachment.role == RelayConnectionRole.server &&
            attachment.connectionId == connectionId,
        1008,
        'Replaced by new connection',
      );
    }

    final attachment = RelaySessionAttachment(
      serverId: request.serverId,
      role: request.role,
      version: '2',
      connectionId: connectionId.isEmpty ? null : connectionId,
      createdAt: _clock(),
    );
    _attachments[socket] = attachment;

    if (request.role == RelayConnectionRole.client) {
      _notifyControls({'type': 'connected', 'connectionId': connectionId});
      _scheduleControlNudge(connectionId);
    } else if (isServerControl) {
      _safeSend(socket, {
        'type': 'sync',
        'connectionIds': _connectedConnectionIds(),
      });
    } else if (isServerData) {
      _flushFrames(connectionId, socket);
    }

    _log(
      'v2:${request.role.wireValue}'
      '${connectionId.isEmpty ? '(control)' : '($connectionId)'} connected',
    );
    return attachment;
  }

  void handleMessage(RelaySocket socket, Object message) {
    if (_disposed) return;
    final attachment = _attachments[socket];
    if (attachment == null) {
      _log('message_without_attachment');
      return;
    }

    if (attachment.version == '1') {
      final targetRole = attachment.role == RelayConnectionRole.server
          ? RelayConnectionRole.client
          : RelayConnectionRole.server;
      for (final target in _socketsWhere(
        (candidate) => candidate.version == '1' && candidate.role == targetRole,
      )) {
        _safeSend(target, message);
      }
      return;
    }

    final connectionId = attachment.connectionId;
    if (connectionId == null) {
      if (message is String) _handleControlKeepalive(socket, message);
      return;
    }

    if (attachment.role == RelayConnectionRole.client) {
      final servers = _socketsWhere(
        (candidate) =>
            candidate.version == '2' &&
            candidate.role == RelayConnectionRole.server &&
            candidate.connectionId == connectionId,
      ).toList();
      if (servers.isEmpty) {
        _bufferFrame(connectionId, message);
        return;
      }
      for (final target in servers) {
        _safeSend(target, message);
      }
      return;
    }

    for (final target in _socketsWhere(
      (candidate) =>
          candidate.version == '2' &&
          candidate.role == RelayConnectionRole.client &&
          candidate.connectionId == connectionId,
    )) {
      _safeSend(target, message);
    }
  }

  void handleClose(
    RelaySocket socket, {
    required int code,
    required String reason,
  }) {
    final attachment = _attachments.remove(socket);
    if (attachment == null) return;
    _log(
      'v${attachment.version}:${attachment.role.wireValue}'
      '${attachment.connectionId == null ? '' : '(${attachment.connectionId})'} '
      'disconnected ($code: $reason)',
    );

    if (attachment.version == '1') return;
    final connectionId = attachment.connectionId;
    if (connectionId == null) return;

    if (attachment.role == RelayConnectionRole.client) {
      final hasRemainingClient = _attachments.values.any(
        (candidate) =>
            candidate.version == '2' &&
            candidate.role == RelayConnectionRole.client &&
            candidate.connectionId == connectionId,
      );
      if (hasRemainingClient) return;

      _cancelNudge(connectionId);
      _pendingFrames.remove(connectionId);
      _closeWhere(
        (candidate) =>
            candidate.version == '2' &&
            candidate.role == RelayConnectionRole.server &&
            candidate.connectionId == connectionId,
        1001,
        'Client disconnected',
      );
      _notifyControls({'type': 'disconnected', 'connectionId': connectionId});
      return;
    }

    _closeWhere(
      (candidate) =>
          candidate.version == '2' &&
          candidate.role == RelayConnectionRole.client &&
          candidate.connectionId == connectionId,
      1012,
      'Server disconnected',
    );
  }

  void handleError(RelaySocket socket, Object error) {
    final attachment = _attachments[socket];
    _log('websocket_error:${attachment?.role.wireValue ?? 'unknown'}:$error');
  }

  void _handleControlKeepalive(RelaySocket socket, String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['type'] == 'ping') {
        _log('legacy_json_ping_received');
        _safeSend(socket, {'type': 'pong', 'ts': _clock()});
      }
    } on Object {
      // Ignore non-JSON control traffic.
    }
  }

  void _bufferFrame(String connectionId, Object message) {
    final frames = _pendingFrames.putIfAbsent(connectionId, () => []);
    frames.add(message);
    if (frames.length > maxPendingFrames) {
      frames.removeRange(0, frames.length - maxPendingFrames);
    }
  }

  void _flushFrames(String connectionId, RelaySocket serverSocket) {
    final frames = _pendingFrames.remove(connectionId);
    if (frames == null || frames.isEmpty) return;
    for (var index = 0; index < frames.length; index += 1) {
      try {
        serverSocket.send(frames[index]);
      } on Object {
        for (var pending = index; pending < frames.length; pending += 1) {
          _bufferFrame(connectionId, frames[pending]);
        }
        break;
      }
    }
  }

  List<String> _connectedConnectionIds() {
    final ids = <String>{};
    for (final attachment in _attachments.values) {
      if (attachment.version == '2' &&
          attachment.role == RelayConnectionRole.client &&
          attachment.connectionId != null) {
        ids.add(attachment.connectionId!);
      }
    }
    return ids.toList(growable: false);
  }

  void _notifyControls(Map<String, Object?> message) {
    for (final socket in _socketsWhere(
      (attachment) =>
          attachment.version == '2' &&
          attachment.role == RelayConnectionRole.server &&
          attachment.connectionId == null,
    )) {
      if (!_safeSend(socket, message)) {
        _safeClose(socket, 1011, 'Control send failed');
        _attachments.remove(socket);
      }
    }
  }

  void _scheduleControlNudge(String connectionId) {
    _cancelNudge(connectionId);
    _nudgeTimers[connectionId] = Timer(initialControlNudgeDelay, () {
      _nudgeTimers.remove(connectionId);
      if (!_hasClient(connectionId) || _hasServerData(connectionId)) return;
      _notifyControls({
        'type': 'sync',
        'connectionIds': _connectedConnectionIds(),
      });
      _nudgeTimers[connectionId] = Timer(controlResetDelay, () {
        _nudgeTimers.remove(connectionId);
        if (!_hasClient(connectionId) || _hasServerData(connectionId)) return;
        _closeWhere(
          (attachment) =>
              attachment.version == '2' &&
              attachment.role == RelayConnectionRole.server &&
              attachment.connectionId == null,
          1011,
          'Control unresponsive',
        );
      });
    });
  }

  bool _hasClient(String connectionId) => _attachments.values.any(
    (attachment) =>
        attachment.version == '2' &&
        attachment.role == RelayConnectionRole.client &&
        attachment.connectionId == connectionId,
  );

  bool _hasServerData(String connectionId) => _attachments.values.any(
    (attachment) =>
        attachment.version == '2' &&
        attachment.role == RelayConnectionRole.server &&
        attachment.connectionId == connectionId,
  );

  Iterable<RelaySocket> _socketsWhere(
    bool Function(RelaySessionAttachment attachment) predicate,
  ) sync* {
    for (final entry in _attachments.entries.toList(growable: false)) {
      if (predicate(entry.value)) yield entry.key;
    }
  }

  void _replaceWhere(
    bool Function(RelaySessionAttachment attachment) predicate,
    int code,
    String reason,
  ) {
    _closeWhere(predicate, code, reason);
  }

  void _closeWhere(
    bool Function(RelaySessionAttachment attachment) predicate,
    int code,
    String reason,
  ) {
    final sockets = _socketsWhere(predicate).toList(growable: false);
    for (final socket in sockets) {
      _safeClose(socket, code, reason);
      _attachments.remove(socket);
    }
  }

  bool _safeSend(RelaySocket socket, Object message) {
    try {
      socket.send(message is Map ? jsonEncode(message) : message);
      return true;
    } on Object catch (error) {
      _log('send_failed:$error');
      return false;
    }
  }

  void _safeClose(RelaySocket socket, int code, String reason) {
    try {
      socket.close(code, reason);
    } on Object catch (error) {
      _log('close_failed:$error');
    }
  }

  void _cancelNudge(String connectionId) {
    _nudgeTimers.remove(connectionId)?.cancel();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _nudgeTimers.values) {
      timer.cancel();
    }
    _nudgeTimers.clear();
    _pendingFrames.clear();
    _closeWhere((_) => true, 1001, 'Relay shutting down');
  }
}

abstract interface class DisposableRelaySession {
  void dispose();
}

String _randomConnectionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(8, (_) => random.nextInt(256));
  final suffix = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'conn_$suffix';
}

void _discardLog(String _) {}
