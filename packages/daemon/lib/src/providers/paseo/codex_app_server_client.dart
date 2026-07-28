import 'dart:async';

import 'jsonl_rpc_process.dart';

const codexAppServerDefaultTimeout = Duration(days: 14);

typedef CodexAppServerRequestHandler =
    FutureOr<Object?> Function(Object? params, int requestId);
typedef CodexAppServerNotificationHandler =
    void Function(String method, Object? params);

abstract interface class CodexAppServerConnection {
  bool get isClosed;

  void setNotificationHandler(CodexAppServerNotificationHandler handler);

  void setRequestHandler(String method, CodexAppServerRequestHandler handler);

  void Function() onExit(void Function(JsonlRpcExit exit) handler);

  Future<Object?> request(String method, [Object? params, Duration? timeout]);

  void notify(String method, [Object? params]);

  Future<CodexThreadForkResponse> forkThread(CodexThreadForkParams params);

  Future<CodexThreadRollbackResponse> rollbackThread(
    CodexThreadRollbackParams params,
  );

  Future<void> dispose();
}

final class CodexThreadSummary {
  const CodexThreadSummary({
    required this.id,
    this.sessionId,
    this.forkedFromId,
    this.turns,
  });

  factory CodexThreadSummary.fromJson(Object? value) {
    final json = _requiredRecord(value, 'thread');
    final turns = json['turns'];
    return CodexThreadSummary(
      id: _requiredString(json, 'id', 'thread'),
      sessionId: _optionalString(json, 'sessionId', 'thread'),
      forkedFromId: _optionalNullableString(json, 'forkedFromId', 'thread'),
      turns: turns == null
          ? null
          : turns is List
          ? List<Object?>.unmodifiable(turns)
          : throw FormatException('thread.turns must be an array'),
    );
  }

  final String id;
  final String? sessionId;
  final String? forkedFromId;
  final List<Object?>? turns;
}

final class CodexThreadForkParams {
  const CodexThreadForkParams({
    required this.threadId,
    this.path,
    this.model,
    this.modelProvider,
    this.serviceTier,
    this.cwd,
    this.runtimeWorkspaceRoots,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.sandbox,
    this.permissions,
    this.config,
    this.baseInstructions,
    this.developerInstructions,
    this.ephemeral,
    this.threadSource,
    this.excludeTurns,
    this.persistExtendedHistory,
    this.includeNullValues = false,
  });

  final String threadId;
  final String? path;
  final String? model;
  final String? modelProvider;
  final String? serviceTier;
  final String? cwd;
  final List<String>? runtimeWorkspaceRoots;
  final Object? approvalPolicy;
  final Object? approvalsReviewer;
  final Object? sandbox;
  final String? permissions;
  final Map<String, Object?>? config;
  final String? baseInstructions;
  final String? developerInstructions;
  final bool? ephemeral;
  final Object? threadSource;
  final bool? excludeTurns;
  final bool? persistExtendedHistory;
  final bool includeNullValues;

  Map<String, Object?> toJson() {
    return {
      'threadId': threadId,
      if (includeNullValues || path != null) 'path': path,
      if (includeNullValues || model != null) 'model': model,
      if (includeNullValues || modelProvider != null)
        'modelProvider': modelProvider,
      if (includeNullValues || serviceTier != null) 'serviceTier': serviceTier,
      if (includeNullValues || cwd != null) 'cwd': cwd,
      if (includeNullValues || runtimeWorkspaceRoots != null)
        'runtimeWorkspaceRoots': runtimeWorkspaceRoots,
      if (approvalPolicy != null) 'approvalPolicy': approvalPolicy,
      if (approvalsReviewer != null) 'approvalsReviewer': approvalsReviewer,
      if (sandbox != null) 'sandbox': sandbox,
      if (permissions != null) 'permissions': permissions,
      if (config != null) 'config': config,
      if (baseInstructions != null) 'baseInstructions': baseInstructions,
      if (developerInstructions != null)
        'developerInstructions': developerInstructions,
      if (ephemeral != null) 'ephemeral': ephemeral,
      if (threadSource != null) 'threadSource': threadSource,
      if (excludeTurns != null) 'excludeTurns': excludeTurns,
      if (persistExtendedHistory != null)
        'persistExtendedHistory': persistExtendedHistory,
    };
  }
}

final class CodexThreadForkResponse {
  const CodexThreadForkResponse({
    required this.thread,
    required this.model,
    required this.modelProvider,
    required this.serviceTier,
    required this.cwd,
    required this.runtimeWorkspaceRoots,
    required this.instructionSources,
    required this.approvalPolicy,
    required this.approvalsReviewer,
    required this.sandbox,
    this.activePermissionProfile,
    this.reasoningEffort,
  });

  factory CodexThreadForkResponse.fromJson(Object? value) {
    final json = _requiredRecord(value, 'thread/fork response');
    for (final key in [
      'serviceTier',
      'approvalPolicy',
      'approvalsReviewer',
      'sandbox',
    ]) {
      if (!json.containsKey(key)) {
        throw FormatException('thread/fork response.$key is required');
      }
    }
    return CodexThreadForkResponse(
      thread: CodexThreadSummary.fromJson(json['thread']),
      model: _requiredString(json, 'model', 'thread/fork response'),
      modelProvider: _requiredString(
        json,
        'modelProvider',
        'thread/fork response',
      ),
      serviceTier: _optionalNullableString(
        json,
        'serviceTier',
        'thread/fork response',
      ),
      cwd: _requiredString(json, 'cwd', 'thread/fork response'),
      runtimeWorkspaceRoots: _optionalStringList(
        json,
        'runtimeWorkspaceRoots',
        'thread/fork response',
      ),
      instructionSources: _optionalStringList(
        json,
        'instructionSources',
        'thread/fork response',
      ),
      approvalPolicy: json['approvalPolicy'],
      approvalsReviewer: json['approvalsReviewer'],
      sandbox: json['sandbox'],
      activePermissionProfile: json['activePermissionProfile'],
      reasoningEffort: _optionalNullableString(
        json,
        'reasoningEffort',
        'thread/fork response',
      ),
    );
  }

  final CodexThreadSummary thread;
  final String model;
  final String modelProvider;
  final String? serviceTier;
  final String cwd;
  final List<String> runtimeWorkspaceRoots;
  final List<String> instructionSources;
  final Object? approvalPolicy;
  final Object? approvalsReviewer;
  final Object? sandbox;
  final Object? activePermissionProfile;
  final String? reasoningEffort;
}

final class CodexThreadRollbackParams {
  const CodexThreadRollbackParams({
    required this.threadId,
    required this.numTurns,
  });

  final String threadId;
  final int numTurns;

  Map<String, Object?> toJson() {
    return {'threadId': threadId, 'numTurns': numTurns};
  }
}

final class CodexThreadRollbackResponse {
  const CodexThreadRollbackResponse({required this.thread});

  factory CodexThreadRollbackResponse.fromJson(Object? value) {
    final json = _requiredRecord(value, 'thread/rollback response');
    return CodexThreadRollbackResponse(
      thread: CodexThreadSummary.fromJson(json['thread']),
    );
  }

  final CodexThreadSummary thread;
}

final class _PendingCodexRequest {
  _PendingCodexRequest(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer? timer;
}

/// Paseo-compatible bidirectional JSON-RPC client for `codex app-server`.
final class CodexAppServerClient implements CodexAppServerConnection {
  CodexAppServerClient(JsonlRpcProcess transport) : _transport = transport {
    _unsubscribeMessage = transport.onMessage((message) {
      unawaited(_handleMessage(message));
    });
    _unsubscribeExit = transport.onExit((exit) {
      _failAll(exit.error);
    });
  }

  static Future<CodexAppServerClient> start({
    required JsonlRpcLaunch launch,
    JsonlRpcWarningSink? onWarning,
    JsonlRpcProcessStarter? spawn,
  }) async {
    final transport = await JsonlRpcProcess.start(
      launch: launch,
      diagnosticName: 'Codex app-server',
      onWarning: onWarning,
      spawn: spawn,
    );
    return CodexAppServerClient(transport);
  }

  final JsonlRpcProcess _transport;
  final Map<int, _PendingCodexRequest> _pending = {};
  final Map<String, CodexAppServerRequestHandler> _requestHandlers = {};
  late final void Function() _unsubscribeMessage;
  late final void Function() _unsubscribeExit;

  CodexAppServerNotificationHandler? _notificationHandler;
  var _nextId = 1;
  var _disposed = false;

  @override
  bool get isClosed => _disposed;

  @override
  void setNotificationHandler(CodexAppServerNotificationHandler handler) {
    _notificationHandler = handler;
  }

  @override
  void setRequestHandler(String method, CodexAppServerRequestHandler handler) {
    _requestHandlers[method] = handler;
  }

  @override
  void Function() onExit(void Function(JsonlRpcExit exit) handler) {
    return _transport.onExit(handler);
  }

  @override
  Future<Object?> request(
    String method, [
    Object? params,
    Duration? timeout = codexAppServerDefaultTimeout,
  ]) {
    if (_disposed) {
      return Future.error(StateError('Codex app-server client is closed'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    Timer? timer;
    if (timeout != null && timeout > Duration.zero) {
      timer = Timer(timeout, () {
        _pending.remove(id);
        completer.completeError(
          StateError('Codex app-server request timed out for $method'),
        );
      });
    }
    _pending[id] = _PendingCodexRequest(completer, timer);
    _transport.send({'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  @override
  void notify(String method, [Object? params]) {
    if (_disposed) {
      return;
    }
    _transport.send({'method': method, 'params': params});
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    return CodexThreadForkResponse.fromJson(
      await request('thread/fork', params.toJson()),
    );
  }

  @override
  Future<CodexThreadRollbackResponse> rollbackThread(
    CodexThreadRollbackParams params,
  ) async {
    return CodexThreadRollbackResponse.fromJson(
      await request('thread/rollback', params.toJson()),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _failAll(StateError('Codex app-server client is closed'));
    _unsubscribeMessage();
    _unsubscribeExit();
    await _transport.close(StateError('Codex app-server client is closed'));
  }

  Future<void> _handleMessage(Map<String, Object?> message) async {
    final id = message['id'];
    if (id is int) {
      if (message.containsKey('result') || message['error'] != null) {
        _handleResponse(id, message);
        return;
      }

      final method = message['method'];
      if (method is String) {
        await _handleServerRequest(id, method, message['params']);
        return;
      }
    }

    final method = message['method'];
    if (method is String && !message.containsKey('id')) {
      _notificationHandler?.call(method, message['params']);
    }
  }

  void _handleResponse(int id, Map<String, Object?> response) {
    final pending = _pending.remove(id);
    if (pending == null) {
      return;
    }
    pending.timer?.cancel();
    final error = response['error'];
    if (error != null) {
      final message = error is Map && error['message'] is String
          ? error['message']! as String
          : 'Unknown error';
      pending.completer.completeError(StateError(message));
      return;
    }
    pending.completer.complete(response['result']);
  }

  Future<void> _handleServerRequest(
    int id,
    String method,
    Object? params,
  ) async {
    final handler = _requestHandlers[method];
    try {
      final result = handler == null
          ? <String, Object?>{}
          : await handler(params, id);
      _transport.send({'id': id, 'result': result});
    } on Object catch (error) {
      _transport.send({
        'id': id,
        'error': {'message': error.toString()},
      });
    }
  }

  void _failAll(StateError error) {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.completer.completeError(error);
    }
    _pending.clear();
  }
}

Map<String, Object?> _requiredRecord(Object? value, String path) {
  if (value is! Map) {
    throw FormatException('$path must be an object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _requiredString(Map<String, Object?> json, String key, String path) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('$path.$key must be a string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key, String path) {
  if (!json.containsKey(key)) {
    return null;
  }
  final value = json[key];
  if (value is! String) {
    throw FormatException('$path.$key must be a string');
  }
  return value;
}

String? _optionalNullableString(
  Map<String, Object?> json,
  String key,
  String path,
) {
  if (!json.containsKey(key) || json[key] == null) {
    return null;
  }
  return _optionalString(json, key, path);
}

List<String> _optionalStringList(
  Map<String, Object?> json,
  String key,
  String path,
) {
  if (!json.containsKey(key)) {
    return const [];
  }
  final value = json[key];
  if (value is! List || value.any((element) => element is! String)) {
    throw FormatException('$path.$key must be an array of strings');
  }
  return List<String>.unmodifiable(value.cast<String>());
}
