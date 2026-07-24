import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Closes [channel] without ever blocking the caller. `sink.close()` waits on
/// the underlying connection, which can hang indefinitely if it never
/// finished connecting (e.g. probing a closed/firewalled port) — the WS
/// handshake never resolves, so close() has nothing to complete against.
void _closeFireAndForget(WebSocketChannel? channel) {
  if (channel == null) return;
  unawaited(Future(() => channel.sink.close(1000)).catchError((_) {}));
}

/// Opens a WebSocket to the daemon and performs the hello handshake.
/// Returns null when the daemon is unreachable or does not answer in time.
/// A successful probe is authoritative over any pid-file liveness guess.
Future<ServerHello?> probeDaemon(
  String host,
  int port, {
  String? token,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  WebSocketChannel? channel;
  try {
    channel = WebSocketChannel.connect(Uri.parse('ws://$host:$port'));
    await channel.ready.timeout(timeout);
    channel.sink.add(jsonEncode(RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'probe',
      payload: ClientHello(
        clientName: 'lifecycle-probe',
        clientVersion: '0',
        token: token,
      ).toJson(),
    ).toJson()));
    final raw = await channel.stream
        .firstWhere((frame) => frame is String)
        .timeout(timeout);
    final decoded = RpcFrame.fromJson(
        jsonDecode(raw as String) as Map<String, Object?>);
    if (decoded is RpcResponse && !decoded.isError) {
      return ServerHello.fromJson(decoded.payload);
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    _closeFireAndForget(channel);
  }
}

/// Sends a single loopback RPC (e.g. daemon.shutdown.request) and waits for
/// the response. Returns true on a non-error response.
Future<bool> sendLifecycleRequest(
  String host,
  int port,
  String type, {
  String? token,
  Duration timeout = const Duration(seconds: 5),
}) async {
  WebSocketChannel? channel;
  try {
    channel = WebSocketChannel.connect(Uri.parse('ws://$host:$port'));
    await channel.ready.timeout(timeout);
    final frames = channel.stream
        .where((f) => f is String)
        .map((f) => RpcFrame.fromJson(
            jsonDecode(f as String) as Map<String, Object?>))
        .asBroadcastStream();

    channel.sink.add(jsonEncode(RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'hello',
      payload: ClientHello(
        clientName: 'lifecycle',
        clientVersion: '0',
        token: token,
      ).toJson(),
    ).toJson()));
    await frames
        .firstWhere((f) => f is RpcResponse && f.requestId == 'hello')
        .timeout(timeout);

    channel.sink.add(jsonEncode(
        RpcRequest(type: type, requestId: 'req').toJson()));
    final response = await frames
        .firstWhere((f) => f is RpcResponse && f.requestId == 'req')
        .timeout(timeout) as RpcResponse;
    return !response.isError;
  } catch (_) {
    return false;
  } finally {
    _closeFireAndForget(channel);
  }
}
