import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

import 'ws_server.dart';

abstract interface class RelayTransportSocket {
  Stream<Object> get frames;
  int? get closeCode;
  String? get closeReason;
  void send(Object data);
  Future<void> close([int? code, String? reason]);
}

typedef RelayWebSocketConnector =
    Future<RelayTransportSocket> Function(String url);

final class IoRelayTransportSocket implements RelayTransportSocket {
  IoRelayTransportSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object> get frames => _socket.cast<Object>();

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  void send(Object data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}

Future<RelayTransportSocket> connectIoRelayWebSocket(String url) async {
  final socket = await WebSocket.connect(
    url,
    compression: CompressionOptions.compressionOff,
  );
  return IoRelayTransportSocket(socket);
}

final class RelayTransportController {
  RelayTransportController({
    required this.server,
    required this.relayEndpoint,
    required this.relayUseTls,
    required this.serverId,
    required this.daemonKeyPair,
    this.connect = connectIoRelayWebSocket,
    this.controlPingInterval = const Duration(seconds: 10),
    this.controlStaleTimeout = const Duration(seconds: 30),
    this.controlReadyTimeout = const Duration(seconds: 8),
    this.connectTimeout = const Duration(seconds: 10),
    this.dataOpenTimeout = const Duration(seconds: 15),
    this.reconnectUnit = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 30),
    this.log,
  }) {
    unawaited(_connectControl());
  }

  final WsServer server;
  final String relayEndpoint;
  final bool relayUseTls;
  final String serverId;
  final RelayKeyPair daemonKeyPair;
  final RelayWebSocketConnector connect;
  final Duration controlPingInterval;
  final Duration controlStaleTimeout;
  final Duration controlReadyTimeout;
  final Duration connectTimeout;
  final Duration dataOpenTimeout;
  final Duration reconnectUnit;
  final Duration maxReconnectDelay;
  final void Function(String message)? log;

  final Map<String, RelayTransportSocket> _dataSockets = {};
  final Set<String> _pendingDataSockets = {};
  RelayTransportSocket? _controlSocket;
  StreamSubscription<Object>? _controlSubscription;
  Timer? _keepaliveTimer;
  Timer? _readyTimer;
  Timer? _reconnectTimer;
  var _reconnectAttempt = 0;
  var _controlSequence = 0;
  var _controlLastSeenAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _controlReady = false;
  var _stopped = false;

  bool get stopped => _stopped;
  bool get controlReady => _controlReady;
  int get dataSocketCount => _dataSockets.length;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _readyTimer?.cancel();
    _readyTimer = null;
    await _controlSubscription?.cancel();
    _controlSubscription = null;
    final control = _controlSocket;
    _controlSocket = null;
    if (control != null) {
      await _safeClose(control, 1000, 'Daemon shutting down');
    }
    final data = _dataSockets.values.toList();
    _dataSockets.clear();
    _pendingDataSockets.clear();
    for (final socket in data) {
      await _safeClose(socket, 1000, 'Daemon shutting down');
    }
  }

  Future<void> _connectControl() async {
    if (_stopped) return;
    final sequence = ++_controlSequence;
    final url = buildRelayWebSocketUrl(
      endpoint: relayEndpoint,
      useTls: relayUseTls,
      serverId: serverId,
      role: RelayRole.server,
    );
    RelayTransportSocket socket;
    try {
      socket = await connect(url).timeout(connectTimeout);
    } on Object catch (error) {
      log?.call('relay control connection failed: $error');
      _scheduleReconnect();
      return;
    }
    if (_stopped || sequence != _controlSequence) {
      await _safeClose(socket, 1000, 'Superseded');
      return;
    }
    _controlSocket = socket;
    _controlReady = false;
    _controlLastSeenAt = DateTime.now();
    _readyTimer?.cancel();
    _readyTimer = Timer(controlReadyTimeout, () {
      if (!_stopped && identical(_controlSocket, socket) && !_controlReady) {
        log?.call('relay control ready timeout');
        unawaited(_safeClose(socket, 1011, 'Relay control ready timeout'));
      }
    });
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(controlPingInterval, (_) {
      if (_stopped || !identical(_controlSocket, socket)) return;
      final staleFor = DateTime.now().difference(_controlLastSeenAt);
      if (staleFor > controlStaleTimeout) {
        log?.call('relay control stale for ${staleFor.inMilliseconds}ms');
        unawaited(_safeClose(socket, 1011, 'Relay control stale'));
        return;
      }
      try {
        socket.send(jsonEncode({'type': 'ping'}));
      } on Object catch (error) {
        log?.call('relay control ping failed: $error');
        unawaited(_safeClose(socket, 1011, 'Relay control ping failed'));
      }
    });
    _controlSubscription = socket.frames.listen(
      (frame) => _onControlFrame(socket, frame),
      onError: (Object error) {
        if (identical(_controlSocket, socket)) {
          log?.call('relay control error: $error');
        }
      },
      onDone: () => _onControlDone(socket),
    );
    try {
      socket.send(jsonEncode({'type': 'ping'}));
    } on Object catch (error) {
      log?.call('relay control initial ping failed: $error');
      await _safeClose(socket, 1011, 'Relay control ping failed');
    }
  }

  void _onControlFrame(RelayTransportSocket socket, Object frame) {
    if (!identical(_controlSocket, socket)) return;
    _controlLastSeenAt = DateTime.now();
    final message = _parseControlMessage(frame);
    if (message == null) return;
    if (!_controlReady) {
      _controlReady = true;
      _reconnectAttempt = 0;
      _readyTimer?.cancel();
      _readyTimer = null;
      log?.call('relay control connected');
    }
    switch (message.type) {
      case _ControlMessageType.ping:
        socket.send(jsonEncode({'type': 'pong'}));
        return;
      case _ControlMessageType.pong:
        return;
      case _ControlMessageType.sync:
        for (final connectionId in message.connectionIds) {
          unawaited(_ensureClientDataSocket(connectionId));
        }
        return;
      case _ControlMessageType.connected:
        unawaited(_ensureClientDataSocket(message.connectionId!));
        return;
      case _ControlMessageType.disconnected:
        final connectionId = message.connectionId!;
        final existing = _dataSockets.remove(connectionId);
        if (existing != null) {
          unawaited(_safeClose(existing, 1001, 'Client disconnected'));
        }
        return;
    }
  }

  void _onControlDone(RelayTransportSocket socket) {
    if (!identical(_controlSocket, socket)) return;
    log?.call(
      'relay control disconnected: ${socket.closeCode} ${socket.closeReason ?? ''}',
    );
    _controlSocket = null;
    _controlReady = false;
    _readyTimer?.cancel();
    _readyTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _controlSubscription = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped || _reconnectTimer != null) return;
    _reconnectAttempt += 1;
    final calculated = reconnectUnit * _reconnectAttempt;
    final delay = calculated > maxReconnectDelay
        ? maxReconnectDelay
        : calculated;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectControl());
    });
  }

  Future<void> _ensureClientDataSocket(String connectionId) async {
    final normalized = connectionId.trim();
    if (_stopped ||
        normalized.isEmpty ||
        _dataSockets.containsKey(normalized) ||
        !_pendingDataSockets.add(normalized)) {
      return;
    }
    final url = buildRelayWebSocketUrl(
      endpoint: relayEndpoint,
      useTls: relayUseTls,
      serverId: serverId,
      role: RelayRole.server,
      connectionId: normalized,
    );
    RelayTransportSocket socket;
    try {
      socket = await connect(url).timeout(dataOpenTimeout);
    } on Object catch (error) {
      _pendingDataSockets.remove(normalized);
      log?.call('relay data $normalized connection failed: $error');
      return;
    }
    _pendingDataSockets.remove(normalized);
    if (_stopped) {
      await _safeClose(socket, 1000, 'Daemon shutting down');
      return;
    }
    if (_dataSockets.containsKey(normalized)) {
      await _safeClose(socket, 1000, 'Duplicate relay data socket');
      return;
    }
    _dataSockets[normalized] = socket;
    log?.call('relay data connected: $normalized');
    await _attachEncryptedDataSocket(normalized, socket);
  }

  Future<void> _attachEncryptedDataSocket(
    String connectionId,
    RelayTransportSocket socket,
  ) async {
    final plaintext = StreamController<Object>();
    late final RelayE2eeDaemonChannel channel;
    channel = RelayE2eeDaemonChannel(
      daemonKeyPair: daemonKeyPair,
      transportSend: socket.send,
      transportClose: (code, reason) => socket.close(code, reason),
      onMessage: plaintext.add,
      onError: (error) => log?.call('relay E2EE $connectionId error: $error'),
    );
    final subscription = socket.frames.listen(
      channel.handleFrame,
      onError: (Object error) {
        log?.call('relay data $connectionId error: $error');
        if (!plaintext.isClosed) plaintext.addError(error);
      },
      onDone: () {
        channel.transportClosed(
          socket.closeCode ?? 1006,
          socket.closeReason ?? '',
        );
        if (!plaintext.isClosed) unawaited(plaintext.close());
        if (identical(_dataSockets[connectionId], socket)) {
          _dataSockets.remove(connectionId);
        }
      },
    );
    try {
      await channel.ready.timeout(dataOpenTimeout);
      if (_stopped || !identical(_dataSockets[connectionId], socket)) {
        await subscription.cancel();
        channel.close(1000, 'Relay data no longer active');
        if (!plaintext.isClosed) await plaintext.close();
        return;
      }
      server.attachExternal(
        frames: plaintext.stream,
        send: channel.send,
        close: (code, reason) {
          channel.close(code ?? 1000, reason ?? 'Normal closure');
        },
        transport: 'relay',
        externalSessionKey: 'session:$connectionId',
        relayConnectionId: connectionId,
      );
    } on Object catch (error) {
      log?.call('relay E2EE handshake failed for $connectionId: $error');
      if (identical(_dataSockets[connectionId], socket)) {
        _dataSockets.remove(connectionId);
      }
      await subscription.cancel();
      channel.close(1011, 'E2EE handshake failed');
      if (!plaintext.isClosed) await plaintext.close();
    }
  }
}

enum _ControlMessageType { sync, connected, disconnected, ping, pong }

final class _ControlMessage {
  const _ControlMessage(
    this.type, {
    this.connectionId,
    this.connectionIds = const [],
  });

  final _ControlMessageType type;
  final String? connectionId;
  final List<String> connectionIds;
}

_ControlMessage? _parseControlMessage(Object raw) {
  try {
    final text = switch (raw) {
      String value => value,
      List<int> value => utf8.decode(value, allowMalformed: false),
      _ => raw.toString(),
    };
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    switch (decoded['type']) {
      case 'ping':
        return const _ControlMessage(_ControlMessageType.ping);
      case 'pong':
        return const _ControlMessage(_ControlMessageType.pong);
      case 'sync':
        final rawIds = decoded['connectionIds'];
        if (rawIds is! List) return null;
        return _ControlMessage(
          _ControlMessageType.sync,
          connectionIds: [
            for (final id in rawIds)
              if (id is String && id.trim().isNotEmpty) id.trim(),
          ],
        );
      case 'connected':
      case 'disconnected':
        final id = decoded['connectionId'];
        if (id is! String || id.trim().isEmpty) return null;
        return _ControlMessage(
          decoded['type'] == 'connected'
              ? _ControlMessageType.connected
              : _ControlMessageType.disconnected,
          connectionId: id.trim(),
        );
      default:
        return null;
    }
  } on Object {
    return null;
  }
}

Future<void> _safeClose(
  RelayTransportSocket socket,
  int code,
  String reason,
) async {
  try {
    await socket.close(code, reason);
  } on Object {
    // Closing a socket is best-effort during relay recovery.
  }
}
