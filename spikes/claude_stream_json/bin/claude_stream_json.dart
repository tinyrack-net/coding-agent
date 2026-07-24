// Spike: drive the Claude Code CLI in stream-json mode from Dart, including
// the stdin/stdout control protocol used by the official TS Agent SDK.
//
// Phases:
//   1. Fresh run: ask Claude to write hello.txt; answer the can_use_tool
//      permission control_request over stdin with an "allow" response.
//   2. Resume run: --resume <session_id>, ask what file was created.
//   3. Interrupt run: start a long task, then send a control_request
//      {subtype: interrupt} and verify the process winds down.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const claudeExe =
    r'C:\Users\winetree94\AppData\Local\Microsoft\WinGet\Links\claude.exe';

int _requestCounter = 0;

String nextRequestId() =>
    'req_${++_requestCounter}_${DateTime.now().microsecondsSinceEpoch}';

void log(String phase, String msg) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  stdout.writeln('[$ts][$phase] $msg');
}

String trunc(Object? v, [int max = 300]) {
  final s = jsonEncode(v);
  return s.length <= max ? s : '${s.substring(0, max)}...(${s.length} chars)';
}

class ClaudeRunResult {
  String? sessionId;
  Map<String, dynamic>? result;
  final List<String> seenTypes = [];
  int exitCode = -1;
}

class ClaudeProcess {
  final Process process;
  final String phase;
  final ClaudeRunResult run = ClaudeRunResult();
  final _resultCompleter = Completer<void>();
  final _initCompleter = Completer<String>();
  bool autoAllowPermissions;
  bool interruptSent = false;

  ClaudeProcess(this.process, this.phase, {this.autoAllowPermissions = true}) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => log(phase, 'stdout closed'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => log(phase, 'STDERR: $l'));
  }

  static Future<ClaudeProcess> spawn({
    required String phase,
    required String cwd,
    List<String> extraArgs = const [],
    bool autoAllowPermissions = true,
  }) async {
    final args = <String>[
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      // Route permission prompts to the stdin control protocol (can_use_tool
      // control_requests) instead of failing/denying. This is what the TS SDK
      // passes when `canUseTool` is provided.
      '--permission-prompt-tool', 'stdio',
      ...extraArgs,
    ];
    log(phase, 'spawning: claude ${args.join(' ')} (cwd=$cwd)');
    final proc = await Process.start(
      claudeExe,
      args,
      workingDirectory: cwd,
      environment: {
        ...Platform.environment,
        'CLAUDE_CODE_ENTRYPOINT': 'sdk-ts',
      },
    );
    return ClaudeProcess(proc, phase,
        autoAllowPermissions: autoAllowPermissions);
  }

  void sendJson(Map<String, dynamic> obj) {
    final line = jsonEncode(obj);
    log(phase, '>> ${trunc(obj, 200)}');
    process.stdin.add(utf8.encode('$line\n'));
  }

  /// Handshake used by the TS SDK before the first user message.
  void sendInitialize() {
    sendJson({
      'type': 'control_request',
      'request_id': nextRequestId(),
      'request': {'subtype': 'initialize', 'hooks': null},
    });
  }

  void sendUserMessage(String text) {
    sendJson({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text}
        ],
      },
      'parent_tool_use_id': null,
      'session_id': run.sessionId ?? '',
    });
  }

  void sendInterrupt() {
    interruptSent = true;
    sendJson({
      'type': 'control_request',
      'request_id': nextRequestId(),
      'request': {'subtype': 'interrupt'},
    });
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      log(phase,
          '<< NON-JSON line: ${line.length > 200 ? line.substring(0, 200) : line}');
      return;
    }
    final type = msg['type'] as String? ?? '?';
    final subtype = msg['subtype'] ??
        (msg['request'] is Map ? msg['request']['subtype'] : null) ??
        (msg['response'] is Map ? msg['response']['subtype'] : null) ??
        (msg['event'] is Map ? msg['event']['type'] : null);
    run.seenTypes.add(subtype == null ? type : '$type/$subtype');
    log(phase,
        '<< type=$type${subtype != null ? ' subtype=$subtype' : ''} ${trunc(msg, 240)}');

    switch (type) {
      case 'system':
        if (msg['subtype'] == 'init') {
          run.sessionId = msg['session_id'] as String?;
          if (!_initCompleter.isCompleted) {
            _initCompleter.complete(run.sessionId ?? '');
          }
        }
        break;
      case 'control_request':
        _handleControlRequest(msg);
        break;
      case 'result':
        run.result = msg;
        if (!_resultCompleter.isCompleted) _resultCompleter.complete();
        break;
    }
  }

  void _handleControlRequest(Map<String, dynamic> msg) {
    final requestId = msg['request_id'] as String?;
    final request = (msg['request'] as Map?)?.cast<String, dynamic>() ?? {};
    final subtype = request['subtype'] as String?;
    if (subtype == 'can_use_tool') {
      final toolName = request['tool_name'];
      final input = request['input'];
      log(phase,
          '** PERMISSION REQUEST for tool=$toolName input=${trunc(input, 200)}');
      final Map<String, dynamic> response;
      if (autoAllowPermissions) {
        response = {'behavior': 'allow', 'updatedInput': input};
      } else {
        response = {'behavior': 'deny', 'message': 'denied by spike harness'};
      }
      sendJson({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': response,
        },
      });
    } else {
      // Ack anything else (e.g. hook callbacks) with an empty success.
      sendJson({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': {},
        },
      });
    }
  }

  Future<String> waitForInit(Duration timeout) =>
      _initCompleter.future.timeout(timeout);

  Future<void> waitForResult(Duration timeout) =>
      _resultCompleter.future.timeout(timeout);

  Future<int> close() async {
    await process.stdin.close();
    final code = await process.exitCode
        .timeout(const Duration(seconds: 30), onTimeout: () {
      log(phase, 'exit timeout -> kill');
      process.kill(ProcessSignal.sigterm);
      return -99;
    });
    run.exitCode = code;
    log(phase, 'process exited with code $code');
    return code;
  }
}

Future<void> main(List<String> arguments) async {
  final scratch = Directory.systemTemp.createTempSync('claude_spike_');
  log('main', 'scratch dir: ${scratch.path}');

  // ---- Phase 1: streaming chat + permission round-trip -------------------
  final p1 = await ClaudeProcess.spawn(phase: 'P1', cwd: scratch.path);
  p1.sendInitialize();
  p1.sendUserMessage(
      'Create a file named hello.txt in the current directory with exactly the '
      'content "spike-ok" (no trailing newline needed). Use the Write tool.');
  String sessionId = '';
  try {
    sessionId = await p1.waitForInit(const Duration(seconds: 60));
    log('P1', 'captured session_id=$sessionId');
    await p1.waitForResult(const Duration(minutes: 3));
  } catch (e) {
    log('P1', 'ERROR: $e');
  }
  await p1.close();

  final helloFile = File('${scratch.path}\\hello.txt');
  final helloOk = helloFile.existsSync() &&
      helloFile.readAsStringSync().trim() == 'spike-ok';
  log('P1', 'hello.txt exists+correct: $helloOk');
  final permissionSeen =
      p1.run.seenTypes.any((t) => t == 'control_request/can_use_tool');
  log('P1', 'permission round-trip observed: $permissionSeen');

  // ---- Phase 2: resume ---------------------------------------------------
  bool resumeOk = false;
  if (sessionId.isNotEmpty) {
    final p2 = await ClaudeProcess.spawn(
      phase: 'P2',
      cwd: scratch.path,
      extraArgs: ['--resume', sessionId],
    );
    p2.sendInitialize();
    p2.sendUserMessage(
        'What file did you just create, and what was its content? Answer in one short sentence.');
    try {
      await p2.waitForResult(const Duration(minutes: 3));
      final resultText = p2.run.result?['result'] as String? ?? '';
      log('P2', 'result text: $resultText');
      resumeOk = resultText.toLowerCase().contains('hello.txt') ||
          resultText.contains('spike-ok');
    } catch (e) {
      log('P2', 'ERROR: $e');
    }
    await p2.close();
  } else {
    log('P2', 'SKIPPED: no session id from phase 1');
  }

  // ---- Phase 3: interrupt ------------------------------------------------
  bool interruptOk = false;
  final p3 = await ClaudeProcess.spawn(phase: 'P3', cwd: scratch.path);
  p3.sendInitialize();
  p3.sendUserMessage(
      'Please write a very long, detailed 3000-word essay about the history of '
      'operating systems. Do not use any tools, just write.');
  try {
    await p3.waitForInit(const Duration(seconds: 60));
    // Let it stream for a few seconds, then interrupt.
    await Future<void>.delayed(const Duration(seconds: 8));
    log('P3', 'sending interrupt control_request');
    p3.sendInterrupt();
    await p3.waitForResult(const Duration(seconds: 60));
    interruptOk = true;
  } catch (e) {
    log('P3', 'ERROR: $e');
  }
  final p3Exit = await p3.close();
  interruptOk = interruptOk || p3Exit == 0;

  // ---- Summary -----------------------------------------------------------
  log('main', '==================== SUMMARY ====================');
  log('main', 'P1 message types seen: ${p1.run.seenTypes.toSet().join(', ')}');
  log('main',
      '(a) streaming chat:        ${p1.run.result != null ? "PASS" : "FAIL"}');
  log('main',
      '(b) permission round-trip: ${permissionSeen && helloOk ? "PASS" : "FAIL"}');
  log('main', '(c) resume:                ${resumeOk ? "PASS" : "FAIL"}');
  log('main', '(d) interrupt:             ${interruptOk ? "PASS" : "FAIL"}');
  log('main', 'session_id: $sessionId');
  log('main', 'scratch: ${scratch.path}');
}
