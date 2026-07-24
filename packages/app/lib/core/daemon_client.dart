import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' as lifecycle;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum DaemonConnectionState {
  disconnected,
  connecting,
  connected,

  /// Remote daemon has an incompatible major version; no auto-reconnect.
  versionMismatch,
}

bool isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1';

/// Remote version gate: a non-loopback daemon must share our major version.
/// Loopback daemons are managed by the lifecycle supervisor instead.
bool shouldRejectHello(
  Uri uri,
  ServerHello hello, {
  String appDaemonVersion = lifecycle.daemonVersion,
}) {
  if (isLoopbackHost(uri.host)) return false;
  return lifecycle.majorOf(hello.daemonVersion) !=
      lifecycle.majorOf(appDaemonVersion);
}

/// User guidance shown when a remote daemon fails the version gate.
String versionMismatchMessage(
  ServerHello hello, {
  String appDaemonVersion = lifecycle.daemonVersion,
}) {
  final major = lifecycle.majorOf(appDaemonVersion);
  return '원격 데몬 v${hello.daemonVersion} — 이 앱은 v$major.x만 지원합니다. '
      '데몬 또는 앱을 업데이트하세요.';
}

/// WebSocket client for the daemon: correlates request/response by requestId,
/// exposes broadcast events as a stream, reconnects with backoff.
class DaemonClient {
  DaemonClient({required this.uri, this.token});

  final Uri uri;
  final String? token;

  final _uuid = const Uuid();
  final Map<String, Completer<RpcResponse>> _pending = {};
  final _events = StreamController<RpcEvent>.broadcast();
  final _terminalFrames = StreamController<TerminalFrame>.broadcast();
  final _state = StreamController<DaemonConnectionState>.broadcast();

  WebSocketChannel? _channel;
  DaemonConnectionState _current = DaemonConnectionState.disconnected;
  ServerHello? serverHello;

  /// Hello of a remote daemon rejected by the major-version gate.
  ServerHello? rejectedHello;
  bool _disposed = false;
  int _retrySeconds = 1;

  Stream<RpcEvent> get events => _events.stream;

  /// Decoded binary terminal frames (output/snapshot) from the daemon.
  Stream<TerminalFrame> get terminalFrames => _terminalFrames.stream;
  Stream<DaemonConnectionState> get connectionState => _state.stream;
  DaemonConnectionState get currentState => _current;

  Future<void> connect() async {
    if (_disposed) return;
    _setState(DaemonConnectionState.connecting);
    try {
      final channel = WebSocketChannel.connect(uri);
      await channel.ready;
      _channel = channel;
      channel.stream.listen(_onFrame, onDone: _onClosed, onError: (_) {});
      final hello = await request(
        MessageTypes.clientHelloRequest,
        ClientHello(
          clientName: 'coding-agent-app',
          clientVersion: '0.1.0',
          token: token,
        ).toJson(),
      );
      final parsed = ServerHello.fromJson(hello);
      if (shouldRejectHello(uri, parsed)) {
        // Incompatible remote daemon: drop the socket and stay put — the
        // user must update the daemon or the app, retrying won't help.
        rejectedHello = parsed;
        serverHello = null;
        _channel = null;
        _setState(DaemonConnectionState.versionMismatch);
        channel.sink.close(1000);
        return;
      }
      serverHello = parsed;
      rejectedHello = null;
      _retrySeconds = 1;
      _setState(DaemonConnectionState.connected);
    } catch (_) {
      _onClosed();
    }
  }

  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('not connected');
    }
    final requestId = _uuid.v4();
    final completer = Completer<RpcResponse>();
    _pending[requestId] = completer;
    channel.sink.add(jsonEncode(
      RpcRequest(type: type, requestId: requestId, payload: payload).toJson(),
    ));
    final response = await completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(requestId);
      throw TimeoutException('no response to $type');
    });
    final error = response.error;
    if (error != null) throw DaemonRpcException(error);
    return response.payload;
  }

  /// Sends a binary terminal frame (input/resize) to the daemon.
  void sendTerminalFrame(TerminalFrame frame) {
    _channel?.sink.add(frame.encode());
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) {
      // Binary frame: terminal output/snapshot.
      if (frame is List<int>) {
        final decoded = TerminalFrame.decode(
          frame is Uint8List ? frame : Uint8List.fromList(frame),
        );
        if (decoded != null) _terminalFrames.add(decoded);
      }
      return;
    }
    final RpcFrame decoded;
    try {
      decoded = RpcFrame.fromJson(jsonDecode(frame) as Map<String, Object?>);
    } catch (_) {
      return;
    }
    switch (decoded) {
      case RpcResponse():
        _pending.remove(decoded.requestId)?.complete(decoded);
      case RpcEvent():
        _events.add(decoded);
      case RpcRequest():
        break; // daemon never sends requests in the MVP
    }
  }

  void _onClosed() {
    _channel = null;
    for (final pending in _pending.values) {
      pending.completeError(StateError('connection closed'));
    }
    _pending.clear();
    if (_disposed) return;
    // A version-rejected connection must not enter the reconnect loop.
    if (_current == DaemonConnectionState.versionMismatch) return;
    _setState(DaemonConnectionState.disconnected);
    final delay = Duration(seconds: _retrySeconds);
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
    Timer(delay, connect);
  }

  void _setState(DaemonConnectionState state) {
    _current = state;
    _state.add(state);
  }

  void dispose() {
    _disposed = true;
    _channel?.sink.close(1000);
    _events.close();
    _terminalFrames.close();
    _state.close();
  }
}

class DaemonRpcException implements Exception {
  DaemonRpcException(this.error);
  final RpcError error;

  @override
  String toString() => error.toString();
}
