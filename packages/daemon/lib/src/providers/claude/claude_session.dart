/// Claude Code CLI session speaking the stream-json stdin/stdout protocol.
///
/// Protocol facts verified by the spike in `spikes/claude_stream_json`:
/// - spawn `claude -p --input-format stream-json --output-format stream-json
///   --verbose --include-partial-messages --permission-prompt-tool stdio`
/// - stdout is JSONL: `system/init` (session id), `stream_event` (raw
///   Anthropic events), `assistant` (full snapshots), `user` (tool results),
///   `control_request` (permissions), `result` (turn end).
/// - permission replies use the nested `control_response` envelope and MUST
///   include `updatedInput` on allow.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_session.dart';
import '../provider_event.dart';

class ClaudeSession implements AgentSession {
  ClaudeSession._({
    required Stream<String> lines,
    required void Function(String line) sendLine,
    Process? process,
  })  : _sendLine = sendLine,
        _process = process {
    _stdoutSub = lines.listen(_onLine, onDone: () {
      // With a real process, exitCode drives SessionExited; for the
      // fake-transport case (tests) stream closure is the exit signal.
      if (_process == null) _onExit(null);
    });
    _process?.exitCode.then(_onExit);
    _sendInitialize();
  }

  /// Test seam: drive the session with a scripted transport instead of a
  /// real `claude` process.
  factory ClaudeSession.forTransport({
    required Stream<String> lines,
    required void Function(String line) sendLine,
  }) =>
      ClaudeSession._(lines: lines, sendLine: sendLine);

  static Future<ClaudeSession> spawn({
    required String exePath,
    required String cwd,
    required String model,
    required AgentMode mode,
    String? sessionId,
  }) async {
    final args = <String>[
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      if (mode == AgentMode.fullAccess)
        '--dangerously-skip-permissions'
      else ...[
        '--permission-prompt-tool', 'stdio',
        if (mode == AgentMode.plan) ...['--permission-mode', 'plan'],
      ],
      if (model.isNotEmpty) ...['--model', model],
      if (sessionId != null) ...['--resume', sessionId],
    ];
    final isBatchShim = exePath.toLowerCase().endsWith('.cmd') ||
        exePath.toLowerCase().endsWith('.bat');
    final process = await Process.start(
      isBatchShim ? 'cmd' : exePath,
      isBatchShim ? ['/c', exePath, ...args] : args,
      workingDirectory: cwd,
      environment: {
        ...Platform.environment,
        'CLAUDE_CODE_ENTRYPOINT': 'sdk-ts',
      },
    );
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {}); // stderr stays empty in normal operation.
    return ClaudeSession._(
      lines: process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
      sendLine: (line) {
        try {
          process.stdin.add(utf8.encode('$line\n'));
        } catch (_) {
          // Process already gone; SessionExited will follow via exitCode.
        }
      },
      process: process,
    );
  }

  final void Function(String line) _sendLine;
  final Process? _process;
  final _events = StreamController<ProviderEvent>.broadcast();
  late final StreamSubscription<String> _stdoutSub;

  String? _sessionId;
  bool _disposed = false;
  int _requestCounter = 0;

  /// Current assistant message id (from `message_start`).
  String? _messageId;

  /// Stream block index -> (itemId, blockType).
  final Map<int, ({String itemId, String blockType})> _blocks = {};

  /// tool_use id -> latest known (toolName, detail) so tool results can update.
  final Map<String, ({String toolName, ToolCallDetail detail})> _tools = {};

  /// Permission request_ids we have already answered (guards double respond).
  final Set<String> _answeredPermissions = {};

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    _sendJson({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
      'parent_tool_use_id': null,
      'session_id': _sessionId ?? '',
    });
  }

  @override
  Future<void> interrupt() async {
    _sendJson({
      'type': 'control_request',
      'request_id': _nextRequestId(),
      'request': {'subtype': 'interrupt'},
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final process = _process;
    if (process == null) {
      _onExit(null);
      return;
    }
    try {
      await process.stdin.close();
    } catch (_) {}
    // Kill the whole process tree; the CLI spawns helpers.
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
  }

  // -- stdin ----------------------------------------------------------------

  String _nextRequestId() =>
      'req_${++_requestCounter}_${DateTime.now().microsecondsSinceEpoch}';

  void _sendInitialize() {
    _sendJson({
      'type': 'control_request',
      'request_id': _nextRequestId(),
      'request': {'subtype': 'initialize', 'hooks': null},
    });
  }

  void _sendJson(Map<String, Object?> obj) {
    if (_disposed) return;
    _sendLine(jsonEncode(obj));
  }

  // -- stdout ---------------------------------------------------------------

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, Object?> msg;
    try {
      msg = jsonDecode(line) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'system':
        if (msg['subtype'] == 'init') {
          _sessionId = msg['session_id'] as String?;
          _emit(SessionStarted(sessionId: _sessionId ?? ''));
        }
      case 'stream_event':
        _onStreamEvent((msg['event'] as Map?)?.cast<String, Object?>() ?? {});
      case 'assistant':
        _onAssistantSnapshot(
          (msg['message'] as Map?)?.cast<String, Object?>() ?? {},
        );
      case 'user':
        _onUserMessage((msg['message'] as Map?)?.cast<String, Object?>() ?? {});
      case 'control_request':
        _onControlRequest(msg);
      case 'result':
        if (msg['is_error'] == true) {
          _emit(TurnFailed(
            error: (msg['result'] as String?) ??
                (msg['subtype'] as String?) ??
                'unknown error',
          ));
        } else {
          _emit(const TurnCompleted());
        }
      default:
      // rate_limit_event, control_response, system/status etc. — ignore.
    }
  }

  void _onStreamEvent(Map<String, Object?> event) {
    switch (event['type']) {
      case 'message_start':
        _messageId = ((event['message'] as Map?)?['id'] as String?) ??
            'msg_${DateTime.now().microsecondsSinceEpoch}';
        _blocks.clear();
      case 'content_block_start':
        final index = (event['index'] as num?)?.toInt() ?? 0;
        final block =
            (event['content_block'] as Map?)?.cast<String, Object?>() ?? {};
        final blockType = (block['type'] as String?) ?? 'text';
        final itemId = blockType == 'tool_use'
            ? (block['id'] as String? ?? '${_messageId}_$index')
            : '${_messageId}_$index';
        _blocks[index] = (itemId: itemId, blockType: blockType);
        if (blockType == 'tool_use') {
          final toolName = (block['name'] as String?) ?? 'unknown';
          final detail = mapToolDetail(toolName, const {});
          _tools[itemId] = (toolName: toolName, detail: detail);
          _emit(ToolCallStarted(
            itemId: itemId,
            toolName: toolName,
            status: ToolCallStatus.pending,
            detail: detail,
          ));
        }
      case 'content_block_delta':
        final index = (event['index'] as num?)?.toInt() ?? 0;
        final block = _blocks[index];
        if (block == null) return;
        final delta = (event['delta'] as Map?)?.cast<String, Object?>() ?? {};
        switch (delta['type']) {
          case 'text_delta':
            _emit(AssistantTextDelta(
              itemId: block.itemId,
              text: (delta['text'] as String?) ?? '',
            ));
          case 'thinking_delta':
            _emit(ReasoningDelta(
              itemId: block.itemId,
              text: (delta['thinking'] as String?) ?? '',
            ));
          // input_json_delta: tool input streams as partial JSON; we wait for
          // the parsed input in the `assistant` snapshot instead.
        }
    }
  }

  void _onAssistantSnapshot(Map<String, Object?> message) {
    final messageId = (message['id'] as String?) ?? _messageId ?? 'msg';
    final content = (message['content'] as List?) ?? const [];
    for (var i = 0; i < content.length; i++) {
      final block = (content[i] as Map?)?.cast<String, Object?>() ?? {};
      switch (block['type']) {
        case 'text':
          _emit(AssistantMessageComplete(
            itemId: '${messageId}_$i',
            fullText: (block['text'] as String?) ?? '',
          ));
        case 'thinking':
          _emit(ReasoningComplete(
            itemId: '${messageId}_$i',
            fullText: (block['thinking'] as String?) ?? '',
          ));
        case 'tool_use':
          final id = (block['id'] as String?) ?? '${messageId}_$i';
          final toolName =
              (block['name'] as String?) ?? _tools[id]?.toolName ?? 'unknown';
          final input =
              (block['input'] as Map?)?.cast<String, Object?>() ?? const {};
          final detail = mapToolDetail(toolName, input);
          _tools[id] = (toolName: toolName, detail: detail);
          _emit(ToolCallUpdated(
            itemId: id,
            toolName: toolName,
            status: ToolCallStatus.running,
            detail: detail,
          ));
      }
    }
  }

  void _onUserMessage(Map<String, Object?> message) {
    final content = (message['content'] as List?) ?? const [];
    for (final raw in content) {
      final block = (raw as Map?)?.cast<String, Object?>() ?? {};
      if (block['type'] != 'tool_result') continue;
      final toolUseId = block['tool_use_id'] as String?;
      if (toolUseId == null) continue;
      final tool = _tools[toolUseId];
      if (tool == null) continue;
      final isError = block['is_error'] == true;
      var detail = tool.detail;
      if (detail is ShellDetail) {
        detail = ShellDetail(
          command: detail.command,
          output: _truncate(_resultText(block['content']), 4096),
          exitCode: detail.exitCode,
        );
      }
      _tools[toolUseId] = (toolName: tool.toolName, detail: detail);
      _emit(ToolCallUpdated(
        itemId: toolUseId,
        toolName: tool.toolName,
        status: isError ? ToolCallStatus.error : ToolCallStatus.success,
        detail: detail,
      ));
    }
  }

  void _onControlRequest(Map<String, Object?> msg) {
    final requestId = msg['request_id'] as String? ?? '';
    final request = (msg['request'] as Map?)?.cast<String, Object?>() ?? {};
    if (request['subtype'] != 'can_use_tool') {
      // e.g. hook callbacks on startup — ack with an empty success.
      _sendControlResponse(requestId, const {});
      return;
    }
    final toolName = (request['tool_name'] as String?) ?? 'unknown';
    final input =
        (request['input'] as Map?)?.cast<String, Object?>() ?? const {};
    _emit(PermissionRequested(
      permissionId: requestId,
      toolName: toolName,
      detail: mapToolDetail(toolName, input),
      respond: (decision, {String? message}) async {
        if (!_answeredPermissions.add(requestId)) return;
        _sendControlResponse(
          requestId,
          decision == PermissionDecision.allow
              ? {'behavior': 'allow', 'updatedInput': input}
              : {
                  'behavior': 'deny',
                  'message': message ?? 'denied by user',
                },
        );
      },
    ));
  }

  void _sendControlResponse(String requestId, Map<String, Object?> response) {
    _sendJson({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': response,
      },
    });
  }

  void _onExit(int? code) {
    _emit(SessionExited(exitCode: code));
    _stdoutSub.cancel();
    _events.close();
  }

  void _emit(ProviderEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String? ?? '')
          .join('\n');
    }
    return '';
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  /// Maps a Claude tool invocation to a typed [ToolCallDetail].
  static ToolCallDetail mapToolDetail(
    String toolName,
    Map<String, Object?> input,
  ) {
    switch (toolName) {
      case 'Bash':
        return ShellDetail(command: (input['command'] as String?) ?? '');
      case 'Read':
        return ReadDetail(path: (input['file_path'] as String?) ?? '');
      case 'Edit':
      case 'MultiEdit':
        return EditDetail(path: (input['file_path'] as String?) ?? '');
      case 'Write':
        final content = (input['content'] as String?) ?? '';
        return WriteDetail(
          path: (input['file_path'] as String?) ?? '',
          contentPreview: _truncate(content, 500),
        );
      case 'Grep':
      case 'Glob':
        return SearchDetail(
          query: (input['pattern'] as String?) ?? '',
          path: input['path'] as String?,
        );
      default:
        return GenericDetail(input: input);
    }
  }
}
