import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'agent_attention_policy.dart';

/// One connected client. Text frames are JSON RPC; binary frames are reserved
/// for terminal streams (M5).
class Connection {
  Connection(
    WebSocketChannel channel, {
    required this.id,
    this.isLoopback = false,
  }) : _frames = channel.stream,
       _send = channel.sink.add,
       _close = channel.sink.close,
       transport = 'direct',
       externalSessionKey = null,
       relayConnectionId = null,
       scopes = const ['*'];

  Connection.external({
    required Stream<dynamic> frames,
    required void Function(Object data) send,
    required FutureOr<void> Function(int? code, String? reason) close,
    required this.id,
    required this.transport,
    required this.externalSessionKey,
    required this.relayConnectionId,
    this.scopes = const ['*'],
  }) : _frames = frames,
       _send = send,
       _close = close,
       isLoopback = false;

  final String id;
  final Stream<dynamic> _frames;
  final void Function(Object data) _send;
  final FutureOr<void> Function(int? code, String? reason) _close;
  final String transport;
  final String? externalSessionKey;
  final String? relayConnectionId;
  final List<String> scopes;

  /// True when the peer connected from a loopback address. Gates
  /// lifecycle-sensitive RPCs (e.g. daemon shutdown).
  final bool isLoopback;

  /// Set once the client has sent a valid `client.hello.request`.
  bool authenticated = false;
  String clientName = 'unknown';
  String? appVersion;
  bool v2 = false;
  Map<String, Object?> clientCapabilities = const {};
  ClientPresenceState clientPresence = const ClientPresenceState(
    appVisible: false,
    lastActivityAtMs: null,
    focusedAgentId: null,
    focusedTerminalId: null,
  );
  void Function(Map<String, Object?> value)? onJsonSent;
  void Function()? onBinarySent;

  Stream<dynamic> get frames => _frames;

  void sendFrame(RpcFrame frame) {
    final value = frame.toJson();
    _send(jsonEncode(value));
    onJsonSent?.call(value);
  }

  void sendJson(Map<String, Object?> value) {
    _send(jsonEncode(value));
    onJsonSent?.call(value);
  }

  void sendBinary(Uint8List bytes) {
    _send(bytes);
    onBinarySent?.call();
  }

  Future<void> close([int? code, String? reason]) async {
    await _close(code, reason);
  }
}
