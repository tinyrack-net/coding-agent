/// Codex CLI session speaking the `codex app-server` stdio JSON-RPC protocol.
///
/// Protocol facts verified by the spike in `spikes/codex_app_server`:
/// - spawn `codex app-server`; line-delimited JSON-RPC over stdio.
/// - handshake: `initialize` request + `initialized` notification.
/// - `thread/start` (or `thread/resume` with a prior thread id) establishes
///   the conversation; `thread.id` is the resumable session id.
/// - `turn/start` sends a user turn; streaming arrives as notifications
///   (`item/agentMessage/delta`, `item/reasoning/summaryTextDelta`,
///   `item/started|updated|completed`, `turn/started`, `turn/completed`).
/// - approvals are server->client REQUESTS
///   (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`)
///   answered with `{"result": {"decision": "accept"|"decline"}}`.
/// - `turn/interrupt` takes `{threadId, turnId}`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_session.dart';
import '../provider_event.dart';

class CodexSession implements AgentSession {
  CodexSession._({
    required Stream<String> lines,
    required void Function(String line) sendLine,
    required String cwd,
    required String model,
    required AgentMode mode,
    String? resumeSessionId,
    Process? process,
  })  : _sendLine = sendLine,
        _process = process,
        _cwd = cwd,
        _model = model,
        _mode = mode,
        _resumeSessionId = resumeSessionId {
    _linesSub = lines.listen(_onLine, onDone: () {
      // With a real process, exitCode drives SessionExited; for the
      // fake-transport case (tests) stream closure is the exit signal.
      if (_process == null) _onExit(null);
    });
    _process?.exitCode.then(_onExit);
    _ready = _initialize();
    // Surface handshake failures on prompt(); don't let them go unhandled.
    _ready.catchError((_) {});
  }

  /// Test seam: drive the session with a scripted transport instead of a
  /// real `codex app-server` process.
  factory CodexSession.forTransport({
    required Stream<String> lines,
    required void Function(String line) sendLine,
    required String cwd,
    String model = '',
    AgentMode mode = AgentMode.normal,
    String? sessionId,
  }) =>
      CodexSession._(
        lines: lines,
        sendLine: sendLine,
        cwd: cwd,
        model: model,
        mode: mode,
        resumeSessionId: sessionId,
      );

  static Future<CodexSession> spawn({
    required String exePath,
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
  }) async {
    final isBatchShim = exePath.toLowerCase().endsWith('.cmd') ||
        exePath.toLowerCase().endsWith('.bat');
    final process = await Process.start(
      isBatchShim ? 'cmd' : exePath,
      isBatchShim ? ['/c', exePath, 'app-server'] : ['app-server'],
      workingDirectory: cwd,
      environment: Platform.environment,
    );
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {}); // drain; codex logs startup noise here.
    return CodexSession._(
      lines: process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
      sendLine: (line) {
        try {
          process.stdin.add(utf8.encode('$line\n'));
        } catch (_) {
          // Process already gone; SessionExited follows via exitCode.
        }
      },
      cwd: cwd,
      model: model,
      mode: mode,
      resumeSessionId: sessionId,
      process: process,
    );
  }

  final void Function(String line) _sendLine;
  final Process? _process;
  final String _cwd;
  final String _model;
  final AgentMode _mode;
  final String? _resumeSessionId;

  final _events = StreamController<ProviderEvent>.broadcast();
  late final StreamSubscription<String> _linesSub;
  late final Future<void> _ready;

  int _nextRequestId = 0;
  final Map<int, Completer<Object?>> _pending = {};

  String? _threadId;
  String? _turnId;
  bool _disposed = false;
  bool _sessionStartedEmitted = false;

  /// Latest known shell command per commandExecution item id (approval params
  /// carry the command; item/completed does too, but keep begin info around).
  final Map<String, String> _commands = {};

  /// Permission request ids already answered (guards double respond).
  final Set<Object> _answeredPermissions = {};

  @override
  Stream<ProviderEvent> get events => _events.stream;

  // -- approval policy / sandbox mapping (enum values from the codex
  // app-server protocol, see spikes/codex_app_server/FINDINGS.md) -----------

  String get _approvalPolicy =>
      _mode == AgentMode.fullAccess ? 'never' : 'on-request';

  String get _sandboxName => switch (_mode) {
        AgentMode.plan => 'read-only',
        AgentMode.normal => 'workspace-write',
        AgentMode.fullAccess => 'danger-full-access',
      };

  Map<String, Object?> get _sandboxPolicy => switch (_mode) {
        AgentMode.plan => {'type': 'readOnly'},
        AgentMode.normal => {'type': 'workspaceWrite', 'networkAccess': false},
        AgentMode.fullAccess => {'type': 'dangerFullAccess'},
      };

  // -- lifecycle -------------------------------------------------------------

  Future<void> _initialize() async {
    await _request('initialize', {
      'clientInfo': {
        'name': 'tinyrack_daemon',
        'title': 'Tinyrack Daemon',
        'version': '0.1.0',
      },
    });
    _sendJson({'method': 'initialized', 'params': const <String, Object?>{}});
    if (_resumeSessionId != null) {
      final result = await _request('thread/resume', {
        'threadId': _resumeSessionId,
      });
      _threadId = _threadIdFrom(result) ?? _resumeSessionId;
    } else {
      final result = await _request('thread/start', {
        'cwd': _cwd,
        'approvalPolicy': _approvalPolicy,
        'sandbox': _sandboxName,
        if (_model.isNotEmpty) 'model': _model,
      });
      _threadId = _threadIdFrom(result);
      if (_threadId == null) {
        throw StateError('codex app-server did not return a thread id');
      }
    }
    _emitSessionStarted(_threadId!);
  }

  static String? _threadIdFrom(Object? result) {
    if (result is! Map) return null;
    final thread = result['thread'];
    if (thread is! Map) return null;
    return thread['id'] as String?;
  }

  void _emitSessionStarted(String threadId) {
    if (_sessionStartedEmitted) return;
    _sessionStartedEmitted = true;
    _threadId = threadId;
    _emit(SessionStarted(sessionId: threadId));
  }

  @override
  Future<void> prompt(String text) async {
    await _ready;
    final result = await _request('turn/start', {
      'threadId': _threadId,
      'input': [
        {'type': 'text', 'text': text},
      ],
      'approvalPolicy': _approvalPolicy,
      'sandboxPolicy': _sandboxPolicy,
      'cwd': _cwd,
      if (_model.isNotEmpty) 'model': _model,
    });
    // The response resolves as soon as the turn is registered; capture the
    // turn id early in case turn/started is delayed.
    if (result is Map) {
      final turn = result['turn'];
      if (turn is Map) _turnId ??= turn['id'] as String?;
    }
  }

  @override
  Future<void> interrupt() async {
    final threadId = _threadId;
    final turnId = _turnId;
    if (threadId == null || turnId == null) return;
    try {
      await _request('turn/interrupt', {
        'threadId': threadId,
        'turnId': turnId,
      });
    } catch (_) {
      // Turn may already be over; the notification stream settles state.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('session disposed'));
      }
    }
    _pending.clear();
    final process = _process;
    if (process != null) {
      // Kill the whole tree; codex spawns sandbox helpers.
      if (Platform.isWindows) {
        try {
          await Process.run(
            'taskkill',
            ['/T', '/F', '/PID', '${process.pid}'],
          );
        } catch (_) {}
      } else {
        process.kill(ProcessSignal.sigkill);
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    } else {
      _onExit(null);
    }
  }

  // -- JSON-RPC plumbing -----------------------------------------------------

  Future<Object?> _request(String method, Map<String, Object?> params) {
    final id = ++_nextRequestId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _sendJson({'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  void _sendJson(Map<String, Object?> obj) {
    if (_disposed) return;
    _sendLine(jsonEncode(obj));
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, Object?> msg;
    try {
      msg = jsonDecode(line) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final id = msg['id'];
    final method = msg['method'];
    if (id != null && method is String) {
      _onServerRequest(id, method, _asMap(msg['params']));
      return;
    }
    if (id is num) {
      final pending = _pending.remove(id.toInt());
      if (pending == null || pending.isCompleted) return;
      final error = msg['error'];
      if (error != null) {
        final message =
            (error is Map ? error['message'] as String? : null) ?? '$error';
        pending.completeError(StateError(message));
      } else {
        pending.complete(msg['result']);
      }
      return;
    }
    if (method is String) {
      _onNotification(method, _asMap(msg['params']));
    }
  }

  void _onExit(int? code) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('codex app-server exited'));
      }
    }
    _pending.clear();
    _emit(SessionExited(exitCode: code));
    _linesSub.cancel();
    _events.close();
  }

  void _emit(ProviderEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static Map<String, Object?> _asMap(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  // -- notifications ---------------------------------------------------------

  void _onNotification(String method, Map<String, Object?> params) {
    switch (method) {
      case 'thread/started':
        final threadId = _threadIdFrom(params);
        if (threadId != null) _emitSessionStarted(threadId);
      case 'turn/started':
        final turn = _asMap(params['turn']);
        _turnId = (turn['id'] as String?) ?? _turnId;
      case 'turn/completed':
        final turn = _asMap(params['turn']);
        final status = turn['status'] as String?;
        _turnId = null;
        if (status == 'completed') {
          _emit(const TurnCompleted());
        } else {
          final error = _asMap(turn['error']);
          _emit(TurnFailed(
            error: (error['message'] as String?) ?? status ?? 'turn failed',
          ));
        }
      case 'turn/failed':
        final error = _asMap(_asMap(params['turn'])['error']);
        _turnId = null;
        _emit(TurnFailed(
          error: (error['message'] as String?) ?? 'turn failed',
        ));
      case 'item/agentMessage/delta':
        _emit(AssistantTextDelta(
          itemId: (params['itemId'] as String?) ?? 'agent_message',
          text: (params['delta'] as String?) ?? '',
        ));
      case 'item/reasoning/summaryTextDelta':
        _emit(ReasoningDelta(
          itemId: (params['itemId'] as String?) ?? 'reasoning',
          text: (params['delta'] as String?) ?? '',
        ));
      case 'item/started':
        _onItem(_asMap(params['item']), phase: _ItemPhase.started);
      case 'item/updated':
        _onItem(_asMap(params['item']), phase: _ItemPhase.updated);
      case 'item/completed':
        _onItem(_asMap(params['item']), phase: _ItemPhase.completed);
      default:
      // mcpServer/startupStatus/updated, thread/status/changed,
      // account/rateLimits/updated, turn/diff/updated, error, ... — ignore.
    }
  }

  void _onItem(Map<String, Object?> item, {required _ItemPhase phase}) {
    final type = item['type'] as String?;
    final itemId = (item['id'] as String?) ??
        'item_${DateTime.now().microsecondsSinceEpoch}';
    switch (type) {
      case 'agentMessage':
        if (phase == _ItemPhase.completed) {
          _emit(AssistantMessageComplete(
            itemId: itemId,
            fullText: (item['text'] as String?) ?? '',
          ));
        }
      case 'reasoning':
        if (phase == _ItemPhase.completed) {
          _emit(ReasoningComplete(
            itemId: itemId,
            fullText: _reasoningText(item),
          ));
        }
      case 'commandExecution':
        _onCommandExecutionItem(item, itemId, phase);
      case 'fileChange':
        _onFileChangeItem(item, itemId, phase);
      case 'webSearch':
        _emitTool(
          phase: phase,
          itemId: itemId,
          toolName: 'web_search',
          status: _itemStatus(item, phase),
          detail: SearchDetail(query: (item['query'] as String?) ?? ''),
        );
      case 'mcpToolCall':
        _emitTool(
          phase: phase,
          itemId: itemId,
          toolName: (item['tool'] as String?) ?? 'mcp_tool',
          status: _itemStatus(item, phase),
          detail: GenericDetail(input: _asMap(item['arguments'])),
        );
      case 'userMessage':
      case 'plan':
      case 'contextCompaction':
        break; // not represented as timeline tool calls.
      default:
        if (type == null) return;
        _emitTool(
          phase: phase,
          itemId: itemId,
          toolName: type,
          status: _itemStatus(item, phase),
          detail: GenericDetail(input: item),
        );
    }
  }

  void _onCommandExecutionItem(
    Map<String, Object?> item,
    String itemId,
    _ItemPhase phase,
  ) {
    final command = _commandText(item['command']) ?? _commands[itemId] ?? '';
    if (command.isNotEmpty) _commands[itemId] = command;
    if (phase != _ItemPhase.completed) {
      _emitTool(
        phase: phase,
        itemId: itemId,
        toolName: 'shell',
        status: ToolCallStatus.running,
        detail: ShellDetail(command: command),
      );
      return;
    }
    final exitCode = (item['exitCode'] as num?)?.toInt();
    final status = item['status'] as String?;
    final failed = status == 'failed' || (exitCode != null && exitCode != 0);
    final output = (item['aggregatedOutput'] as String?) ??
        (item['aggregated_output'] as String?);
    _emit(ToolCallUpdated(
      itemId: itemId,
      toolName: 'shell',
      status: failed ? ToolCallStatus.error : ToolCallStatus.success,
      detail: ShellDetail(
        command: command,
        output: output == null ? null : _truncate(output, 4096),
        exitCode: exitCode,
      ),
    ));
  }

  void _onFileChangeItem(
    Map<String, Object?> item,
    String itemId,
    _ItemPhase phase,
  ) {
    final changes = _parseChanges(item['changes']);
    final status = _itemStatus(item, phase);
    if (changes.isEmpty) {
      _emitTool(
        phase: phase,
        itemId: itemId,
        toolName: 'apply_patch',
        status: status,
        detail: GenericDetail(input: item),
      );
      return;
    }
    for (var i = 0; i < changes.length; i++) {
      final change = changes[i];
      final fileItemId = changes.length == 1 ? itemId : '${itemId}_$i';
      final kind = change.kind?.toLowerCase();
      final isWrite = kind == 'add' || kind == 'create' || kind == 'new';
      _emitTool(
        phase: phase,
        itemId: fileItemId,
        toolName: 'apply_patch',
        status: status,
        detail: isWrite
            ? WriteDetail(
                path: change.path,
                contentPreview: change.content == null
                    ? null
                    : _truncate(change.content!, 500),
              )
            : EditDetail(
                path: change.path,
                diff: change.content == null
                    ? null
                    : _truncate(change.content!, 4096),
              ),
      );
    }
  }

  void _emitTool({
    required _ItemPhase phase,
    required String itemId,
    required String toolName,
    required ToolCallStatus status,
    required ToolCallDetail detail,
  }) {
    if (phase == _ItemPhase.started) {
      _emit(ToolCallStarted(
        itemId: itemId,
        toolName: toolName,
        status: status,
        detail: detail,
      ));
    } else {
      _emit(ToolCallUpdated(
        itemId: itemId,
        toolName: toolName,
        status: status,
        detail: detail,
      ));
    }
  }

  static ToolCallStatus _itemStatus(
    Map<String, Object?> item,
    _ItemPhase phase,
  ) {
    if (phase != _ItemPhase.completed) return ToolCallStatus.running;
    return item['status'] == 'failed'
        ? ToolCallStatus.error
        : ToolCallStatus.success;
  }

  static String _reasoningText(Map<String, Object?> item) {
    final summary = item['summary'];
    if (summary is List && summary.isNotEmpty) {
      return summary.whereType<String>().join('\n');
    }
    final content = item['content'];
    if (content is List && content.isNotEmpty) {
      return content.whereType<String>().join('\n');
    }
    return (item['text'] as String?) ?? '';
  }

  /// Codex sends commands as either a string or an argv list, often wrapped
  /// in `bash -lc <cmd>`; unwrap for display.
  static String? _commandText(Object? value) {
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is List) {
      final parts = value.whereType<String>().toList();
      if (parts.isEmpty) return null;
      if (parts.length >= 3 && (parts[1] == '-lc' || parts[1] == '-c')) {
        return parts[2];
      }
      return parts.join(' ');
    }
    return null;
  }

  static List<({String path, String? kind, String? content})> _parseChanges(
    Object? changes,
  ) {
    String? patchText(Map<String, Object?> record) =>
        (record['diff'] as String?) ??
        (record['unified_diff'] as String?) ??
        (record['unifiedDiff'] as String?) ??
        (record['patch'] as String?) ??
        (record['content'] as String?);

    final result = <({String path, String? kind, String? content})>[];
    if (changes is List) {
      for (final raw in changes) {
        if (raw is! Map) continue;
        final record = raw.cast<String, Object?>();
        final path = (record['path'] as String?) ??
            (record['file_path'] as String?) ??
            (record['filePath'] as String?);
        if (path == null || path.trim().isEmpty) continue;
        result.add((
          path: path,
          kind: (record['kind'] as String?) ?? (record['type'] as String?),
          content: patchText(record),
        ));
      }
    } else if (changes is Map) {
      // Older shape: {"<path>": {type, unified_diff|content}}.
      for (final entry in changes.entries) {
        final path = entry.key;
        if (path is! String || path.trim().isEmpty) continue;
        final value = entry.value;
        final record =
            value is Map ? value.cast<String, Object?>() : <String, Object?>{};
        result.add((
          path: path,
          kind: (record['kind'] as String?) ?? (record['type'] as String?),
          content: patchText(record),
        ));
      }
    }
    return result;
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  // -- server -> client requests (approvals) ---------------------------------

  void _onServerRequest(
    Object requestId,
    String method,
    Map<String, Object?> params,
  ) {
    switch (method) {
      case 'item/commandExecution/requestApproval':
        final itemId = (params['itemId'] as String?) ?? '$requestId';
        final command = _commandText(params['command']) ?? _commands[itemId];
        _emitPermission(
          requestId: requestId,
          permissionId: itemId,
          toolName: 'shell',
          detail: ShellDetail(command: command ?? ''),
        );
      case 'item/fileChange/requestApproval':
        final itemId = (params['itemId'] as String?) ?? '$requestId';
        _emitPermission(
          requestId: requestId,
          permissionId: itemId,
          toolName: 'apply_patch',
          detail: GenericDetail(input: {
            if (params['reason'] != null) 'reason': params['reason'],
          }),
        );
      default:
        // e.g. item/tool/requestUserInput — ack so the server does not hang.
        _sendJson({'id': requestId, 'result': const <String, Object?>{}});
    }
  }

  void _emitPermission({
    required Object requestId,
    required String permissionId,
    required String toolName,
    required ToolCallDetail detail,
  }) {
    _emit(PermissionRequested(
      permissionId: permissionId,
      toolName: toolName,
      detail: detail,
      respond: (decision, {String? message}) async {
        if (!_answeredPermissions.add(requestId)) return;
        _sendJson({
          'id': requestId,
          'result': {
            'decision':
                decision == PermissionDecision.allow ? 'accept' : 'decline',
          },
        });
      },
    ));
  }
}

enum _ItemPhase { started, updated, completed }
