import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../git/worktree_metadata.dart';

typedef WorkspaceSetupBroadcast = void Function(Map<String, Object?> message);
typedef WorkspaceSetupConfigLoader =
    Future<List<String>> Function(String workspacePath);
typedef WorkspaceSetupEnvironmentResolver =
    Future<Map<String, String>> Function(
      String workspacePath,
      String branchName,
      String sourceCheckoutPath,
    );
typedef WorkspaceSetupCommandExecutor =
    Future<WorkspaceSetupExecutionResult> Function(
      String command,
      String cwd,
      Map<String, String> environment,
      void Function(String output) onOutput,
    );
typedef WorkspaceSetupEnvironmentRegistrar =
    void Function(String cwd, Map<String, String> environment);

final class WorkspaceSetupExecutionResult {
  const WorkspaceSetupExecutionResult({
    required this.exitCode,
    required this.output,
  });

  final int exitCode;
  final String output;
}

final class WorkspaceSetupRunResult {
  const WorkspaceSetupRunResult({
    required this.status,
    required this.setupStarted,
  });

  final WorkspaceSetupStatus status;
  final bool setupStarted;
}

const int _maxSetupCommandOutputBytes = 64 * 1024;
const String _setupTruncationMarker =
    '\n...<output truncated in the middle>...\n';

/// In-memory setup snapshot cache and Paseo 0.2.0 status handler.
///
/// The original daemon keeps these snapshots for the lifetime of the process:
/// clients that missed live progress can request the latest state after
/// reconnecting. Worktree bootstrap execution feeds [upsert] as commands run.
final class WorkspaceSetupService {
  WorkspaceSetupService({
    required WorkspaceSetupBroadcast broadcast,
    WorkspaceSetupConfigLoader? loadCommands,
    WorkspaceSetupEnvironmentResolver? resolveEnvironment,
    WorkspaceSetupCommandExecutor? executeCommand,
    WorkspaceSetupEnvironmentRegistrar? registerEnvironment,
  }) : _broadcast = broadcast,
       _loadCommands = loadCommands ?? _loadWorkspaceSetupCommands,
       _resolveEnvironment =
           resolveEnvironment ?? _resolveWorkspaceSetupEnvironment,
       _executeCommand = executeCommand ?? _executeWorkspaceSetupCommand,
       _registerEnvironment = registerEnvironment;

  final WorkspaceSetupBroadcast _broadcast;
  final WorkspaceSetupConfigLoader _loadCommands;
  final WorkspaceSetupEnvironmentResolver _resolveEnvironment;
  final WorkspaceSetupCommandExecutor _executeCommand;
  final WorkspaceSetupEnvironmentRegistrar? _registerEnvironment;
  final Map<String, WorkspaceSetupSnapshot> _snapshots = {};

  WorkspaceSetupSnapshot? snapshotFor(String workspaceId) =>
      _snapshots[workspaceId];

  Map<String, WorkspaceSetupSnapshot> get snapshots =>
      Map.unmodifiable(_snapshots);

  Map<String, Object?>? handle(Map<String, Object?> message) {
    if (message['type'] != WorkspaceSetupStatusRequest.type) return null;
    final request = WorkspaceSetupStatusRequest.fromJson(message);
    return WorkspaceSetupStatusResponse(
      requestId: request.requestId,
      workspaceId: request.workspaceId,
      snapshot: _snapshots[request.workspaceId],
    ).toJson();
  }

  void upsert(String workspaceId, WorkspaceSetupSnapshot snapshot) {
    _snapshots[workspaceId] = snapshot;
    _broadcast(
      WorkspaceSetupProgress(
        workspaceId: workspaceId,
        snapshot: snapshot,
      ).toJson(),
    );
  }

  Future<WorkspaceSetupRunResult> run({
    required String workspaceId,
    required String workspacePath,
    required String branchName,
    required bool shouldBootstrap,
    String? sourceCheckoutPath,
  }) async {
    final commands = <_SetupCommandState>[];

    WorkspaceSetupDetail detail() {
      final renderedCommands = [
        for (final command in commands) command.toWire(),
      ];
      return WorkspaceSetupDetail(
        worktreePath: workspacePath,
        branchName: branchName,
        log: _buildSetupLog(renderedCommands),
        commands: renderedCommands,
        truncated: commands.any((command) => command.output.truncated),
      );
    }

    void emit(WorkspaceSetupStatus status, String? error) {
      upsert(
        workspaceId,
        WorkspaceSetupSnapshot(status: status, detail: detail(), error: error),
      );
    }

    emit(WorkspaceSetupStatus.running, null);
    if (!shouldBootstrap) {
      emit(WorkspaceSetupStatus.completed, null);
      return const WorkspaceSetupRunResult(
        status: WorkspaceSetupStatus.completed,
        setupStarted: false,
      );
    }

    var setupStarted = false;
    try {
      final configured = await _loadCommands(workspacePath);
      if (configured.isEmpty) {
        setupStarted = true;
        emit(WorkspaceSetupStatus.completed, null);
        return const WorkspaceSetupRunResult(
          status: WorkspaceSetupStatus.completed,
          setupStarted: true,
        );
      }
      final environment = await _resolveEnvironment(
        workspacePath,
        branchName,
        sourceCheckoutPath ?? workspacePath,
      );
      _registerEnvironment?.call(workspacePath, environment);
      setupStarted = true;
      for (var offset = 0; offset < configured.length; offset++) {
        final command = configured[offset];
        final index = offset + 1;
        final startedAt = Stopwatch()..start();
        final state = _SetupCommandState(
          index: index,
          command: command,
          cwd: workspacePath,
        );
        commands.add(state);
        emit(WorkspaceSetupStatus.running, null);
        final result = await _executeCommand(
          command,
          workspacePath,
          environment,
          (output) {
            state
              ..output.append(_stripAnsi(output))
              ..durationMs = startedAt.elapsedMilliseconds;
            emit(WorkspaceSetupStatus.running, null);
          },
        );
        startedAt.stop();
        if (result.output.isNotEmpty && state.output.isEmpty) {
          state.output.append(_stripAnsi(result.output));
        }
        final failed = result.exitCode != 0;
        state
          ..status = failed
              ? WorkspaceSetupCommandStatus.failed
              : WorkspaceSetupCommandStatus.completed
          ..exitCode = result.exitCode
          ..durationMs = startedAt.elapsedMilliseconds;
        if (failed) {
          emit(
            WorkspaceSetupStatus.failed,
            'Worktree setup command failed: $command'
            '${result.output.trim().isEmpty ? '' : '\n${result.output.trim()}'}',
          );
          return WorkspaceSetupRunResult(
            status: WorkspaceSetupStatus.failed,
            setupStarted: setupStarted,
          );
        }
      }
      emit(WorkspaceSetupStatus.completed, null);
      return WorkspaceSetupRunResult(
        status: WorkspaceSetupStatus.completed,
        setupStarted: setupStarted,
      );
    } on Object catch (error) {
      emit(WorkspaceSetupStatus.failed, '$error');
      return WorkspaceSetupRunResult(
        status: WorkspaceSetupStatus.failed,
        setupStarted: setupStarted,
      );
    }
  }

  void remove(String workspaceId) {
    _snapshots.remove(workspaceId);
  }

  void clear() {
    _snapshots.clear();
  }
}

final class _SetupCommandState {
  _SetupCommandState({
    required this.index,
    required this.command,
    required this.cwd,
  });

  final int index;
  final String command;
  final String cwd;
  final _MiddleTruncationAccumulator output = _MiddleTruncationAccumulator();
  WorkspaceSetupCommandStatus status = WorkspaceSetupCommandStatus.running;
  int? exitCode;
  int durationMs = 0;

  WorkspaceSetupCommand toWire() => WorkspaceSetupCommand(
    index: index,
    command: command,
    cwd: cwd,
    log: _processCarriageReturns(output.render()),
    status: status,
    exitCode: exitCode,
    durationMs: durationMs,
  );
}

final class _MiddleTruncationAccumulator {
  String _head = '';
  String _tail = '';
  bool truncated = false;

  bool get isEmpty => _head.isEmpty && _tail.isEmpty;

  void append(String chunk) {
    if (chunk.isEmpty) return;
    final markerBytes = utf8.encode(_setupTruncationMarker).length;
    final available = _maxSetupCommandOutputBytes - markerBytes;
    final headBudget = available ~/ 2;
    final tailBudget = available - headBudget;
    if (!truncated) {
      final combined = '$_head$chunk';
      final bytes = utf8.encode(combined);
      if (bytes.length <= _maxSetupCommandOutputBytes) {
        _head = combined;
        return;
      }
      _head = _firstUtf8Bytes(bytes, headBudget);
      _tail = _lastUtf8Bytes(bytes, tailBudget);
      truncated = true;
      return;
    }
    _tail = _lastUtf8Bytes(utf8.encode('$_tail$chunk'), tailBudget);
  }

  String render() => truncated ? '$_head$_setupTruncationMarker$_tail' : _head;
}

String _buildSetupLog(List<WorkspaceSetupCommand> commands) {
  if (commands.isEmpty) return '';
  final lines = <String>[];
  for (final command in commands) {
    lines.add(
      '==> [${command.index}/${commands.length}] Running: '
      '${command.command}',
    );
    if (command.log.isNotEmpty) {
      lines.add(
        command.log.endsWith('\n')
            ? command.log.substring(0, command.log.length - 1)
            : command.log,
      );
    }
    if (command.exitCode != null) {
      lines.add(
        '<== [${command.index}/${commands.length}] Exit ${command.exitCode} '
        'in ${(command.durationMs! / 1000).toStringAsFixed(2)}s',
      );
    }
  }
  return lines.join('\n');
}

String _stripAnsi(String value) => value.replaceAll(
  RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'),
  '',
);

String _processCarriageReturns(String value) {
  if (!value.contains('\r')) return value;
  final output = StringBuffer();
  var line = <int>[];
  var cursor = 0;
  void flush() {
    output.write(String.fromCharCodes(line));
    output.write('\n');
    line = [];
    cursor = 0;
  }

  final runes = value.runes.toList();
  for (var index = 0; index < runes.length; index++) {
    final rune = runes[index];
    if (rune == 13) {
      if (index + 1 < runes.length && runes[index + 1] == 10) {
        flush();
        index++;
      } else {
        cursor = 0;
      }
    } else if (rune == 10) {
      flush();
    } else {
      if (cursor < line.length) {
        line[cursor] = rune;
      } else {
        line.add(rune);
      }
      cursor++;
    }
  }
  output.write(String.fromCharCodes(line));
  return output.toString();
}

String _firstUtf8Bytes(List<int> bytes, int count) =>
    utf8.decode(bytes.take(count).toList(), allowMalformed: true);

String _lastUtf8Bytes(List<int> bytes, int count) => utf8.decode(
  bytes.skip(bytes.length > count ? bytes.length - count : 0).toList(),
  allowMalformed: true,
);

Future<List<String>> _loadWorkspaceSetupCommands(String workspacePath) async {
  final branded = File(p.join(workspacePath, 'tinyrack.json'));
  final compatible = File(p.join(workspacePath, 'paseo.json'));
  final file = await branded.exists()
      ? branded
      : await compatible.exists()
      ? compatible
      : null;
  if (file == null) return const [];
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Project config must be an object');
  }
  final worktree = decoded['worktree'];
  if (worktree == null) return const [];
  if (worktree is! Map) {
    throw const FormatException('Invalid worktree project config');
  }
  final setup = worktree['setup'];
  if (setup == null) return const [];
  if (setup is String) return [setup];
  if (setup is List && setup.every((entry) => entry is String)) {
    return List.unmodifiable(setup.cast<String>());
  }
  throw const FormatException('Invalid worktree setup commands');
}

Future<Map<String, String>> _resolveWorkspaceSetupEnvironment(
  String workspacePath,
  String branchName,
  String sourceCheckoutPath,
) async {
  WorktreeMetadata? metadata;
  try {
    metadata = readWorktreeMetadata(workspacePath);
  } on StateError {
    // Compatibility for injected/unit setup roots. Production worktree setup
    // has base metadata, while the frozen resolver simply skips persistence
    // when that metadata is absent.
  }
  var worktreePort = metadata?.worktreePort;
  if (worktreePort == null) {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    worktreePort = socket.port;
    await socket.close();
    if (metadata != null) {
      writeWorktreeRuntimeMetadata(workspacePath, worktreePort: worktreePort);
    }
  } else {
    final socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      worktreePort,
    );
    await socket.close();
  }
  final source = p.normalize(p.absolute(sourceCheckoutPath));
  final worktree = p.normalize(p.absolute(workspacePath));
  final port = '$worktreePort';
  return Map.unmodifiable({
    'TINYRACK_SOURCE_CHECKOUT_PATH': source,
    'TINYRACK_ROOT_PATH': source,
    'TINYRACK_WORKTREE_PATH': worktree,
    'TINYRACK_BRANCH_NAME': branchName,
    'TINYRACK_WORKTREE_PORT': port,
    // Compatibility aliases let frozen Paseo project setup scripts act as
    // black-box conformance oracles while Tinyrack remains the public surface.
    'PASEO_SOURCE_CHECKOUT_PATH': source,
    'PASEO_ROOT_PATH': source,
    'PASEO_WORKTREE_PATH': worktree,
    'PASEO_BRANCH_NAME': branchName,
    'PASEO_WORKTREE_PORT': port,
  });
}

Future<WorkspaceSetupExecutionResult> _executeWorkspaceSetupCommand(
  String command,
  String cwd,
  Map<String, String> environment,
  void Function(String output) onOutput,
) async {
  final process = await Process.start(
    Platform.isWindows ? 'cmd.exe' : '/bin/sh',
    Platform.isWindows ? ['/d', '/s', '/c', command] : ['-lc', command],
    workingDirectory: cwd,
    environment: environment,
  );
  final output = StringBuffer();
  void append(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    output.write(text);
    onOutput(text);
  }

  final stdoutDone = process.stdout.listen(append).asFuture<void>();
  final stderrDone = process.stderr.listen(append).asFuture<void>();
  final exitCode = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  return WorkspaceSetupExecutionResult(
    exitCode: exitCode,
    output: output.toString(),
  );
}
