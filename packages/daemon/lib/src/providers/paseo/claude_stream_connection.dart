import 'jsonl_rpc_process.dart';

abstract interface class ClaudeStreamConnection {
  bool get isClosed;

  void send(Map<String, Object?> message);
  void Function() onMessage(
    void Function(Map<String, Object?> message) handler,
  );
  void Function() onExit(void Function(JsonlRpcExit exit) handler);
  Future<void> dispose();
}

final class ClaudeJsonlConnection implements ClaudeStreamConnection {
  ClaudeJsonlConnection._(this._process);

  static Future<ClaudeJsonlConnection> start({
    required JsonlRpcLaunch launch,
    JsonlRpcProcessStarter? spawn,
  }) async {
    final process = await JsonlRpcProcess.start(
      launch: launch,
      diagnosticName: 'Claude Code',
      spawn: spawn,
    );
    return ClaudeJsonlConnection._(process);
  }

  final JsonlRpcProcess _process;

  @override
  bool get isClosed => _process.isClosed;

  @override
  void send(Map<String, Object?> message) => _process.send(message);

  @override
  void Function() onMessage(
    void Function(Map<String, Object?> message) handler,
  ) => _process.onMessage(handler);

  @override
  void Function() onExit(void Function(JsonlRpcExit exit) handler) =>
      _process.onExit(handler);

  @override
  Future<void> dispose() => _process.close();
}
