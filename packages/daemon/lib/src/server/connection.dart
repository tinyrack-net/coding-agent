import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One connected client. Text frames are JSON RPC; binary frames are reserved
/// for terminal streams (M5).
class Connection {
  Connection(this._channel, {required this.id, this.isLoopback = false});

  final String id;
  final WebSocketChannel _channel;

  /// True when the peer connected from a loopback address. Gates
  /// lifecycle-sensitive RPCs (e.g. daemon shutdown).
  final bool isLoopback;

  /// Set once the client has sent a valid `client.hello.request`.
  bool authenticated = false;
  String clientName = 'unknown';

  Stream<dynamic> get frames => _channel.stream;

  void sendFrame(RpcFrame frame) {
    _channel.sink.add(jsonEncode(frame.toJson()));
  }

  void sendBinary(Uint8List bytes) {
    _channel.sink.add(bytes);
  }

  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);
}
