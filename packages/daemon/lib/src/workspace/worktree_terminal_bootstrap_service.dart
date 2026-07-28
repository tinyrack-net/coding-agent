import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../terminal/terminal_manager.dart';

typedef WorktreeTerminalConfigLoader =
    Future<List<WorktreeTerminalSpec>> Function(String workspacePath);
typedef WorktreeTerminalCreator =
    Future<Map<String, Object?>> Function({
      required String cwd,
      required String workspaceId,
      required String? name,
    });
typedef WorktreeTerminalInputSender =
    void Function(String terminalId, String input);
typedef WorktreeTerminalReadinessWaiter =
    Future<void> Function(String terminalId);

final class WorktreeTerminalSpec {
  const WorktreeTerminalSpec({required this.command, this.name});

  final String command;
  final String? name;
}

final class WorktreeTerminalBootstrapResult {
  const WorktreeTerminalBootstrapResult({
    required this.name,
    required this.command,
    required this.status,
    required this.terminalId,
    required this.error,
  });

  final String? name;
  final String command;
  final String status;
  final String? terminalId;
  final String? error;

  Map<String, Object?> toJson() => {
    'name': name,
    'command': command,
    'status': status,
    'terminalId': terminalId,
    'error': error,
  };
}

final class WorktreeTerminalBootstrapService {
  WorktreeTerminalBootstrapService({
    required WorktreeTerminalCreator createTerminal,
    required WorktreeTerminalInputSender sendInput,
    WorktreeTerminalConfigLoader? loadSpecs,
    WorktreeTerminalReadinessWaiter? waitUntilReady,
  }) : _createTerminal = createTerminal,
       _sendInput = sendInput,
       _loadSpecs = loadSpecs ?? loadWorktreeTerminalSpecs,
       _waitUntilReady = waitUntilReady ?? _noReadinessWait;

  factory WorktreeTerminalBootstrapService.forManager(
    TerminalManager terminals, {
    Duration readinessTimeout = const Duration(milliseconds: 1500),
  }) => WorktreeTerminalBootstrapService(
    createTerminal:
        ({required cwd, required workspaceId, required name}) async =>
            terminals.create(cwd: cwd, workspaceId: workspaceId, name: name),
    sendInput: terminals.sendInput,
    waitUntilReady: (terminalId) =>
        _waitForManagerTerminal(terminals, terminalId, readinessTimeout),
  );

  final WorktreeTerminalCreator _createTerminal;
  final WorktreeTerminalInputSender _sendInput;
  final WorktreeTerminalConfigLoader _loadSpecs;
  final WorktreeTerminalReadinessWaiter _waitUntilReady;

  Future<List<WorktreeTerminalBootstrapResult>> run({
    required String workspacePath,
    required String workspaceId,
  }) async {
    final specs = await loadSpecs(workspacePath);
    return runSpecs(
      specs,
      workspacePath: workspacePath,
      workspaceId: workspaceId,
    );
  }

  Future<List<WorktreeTerminalSpec>> loadSpecs(String workspacePath) =>
      _loadSpecs(workspacePath);

  Future<List<WorktreeTerminalBootstrapResult>> runSpecs(
    List<WorktreeTerminalSpec> specs, {
    required String workspacePath,
    required String workspaceId,
  }) {
    return Future.wait([
      for (final spec in specs)
        _start(spec, workspacePath: workspacePath, workspaceId: workspaceId),
    ]);
  }

  Future<WorktreeTerminalBootstrapResult> _start(
    WorktreeTerminalSpec spec, {
    required String workspacePath,
    required String workspaceId,
  }) async {
    try {
      final terminal = await _createTerminal(
        cwd: workspacePath,
        workspaceId: workspaceId,
        name: spec.name,
      );
      final terminalId = terminal['terminalId'];
      if (terminalId is! String || terminalId.isEmpty) {
        throw const FormatException('Terminal create returned no terminalId');
      }
      await _waitUntilReady(terminalId);
      _sendInput(terminalId, '${spec.command}\r');
      return WorktreeTerminalBootstrapResult(
        name: (terminal['name'] as String?) ?? spec.name,
        command: spec.command,
        status: 'started',
        terminalId: terminalId,
        error: null,
      );
    } catch (error) {
      return WorktreeTerminalBootstrapResult(
        name: spec.name,
        command: spec.command,
        status: 'failed',
        terminalId: null,
        error: '$error',
      );
    }
  }
}

Future<List<WorktreeTerminalSpec>> loadWorktreeTerminalSpecs(
  String workspacePath,
) async {
  final branded = File('$workspacePath${Platform.pathSeparator}tinyrack.json');
  final compatible = File('$workspacePath${Platform.pathSeparator}paseo.json');
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
  final terminals = worktree['terminals'];
  if (terminals == null) return const [];
  if (terminals is! List) {
    throw const FormatException('Invalid worktree terminal config');
  }
  final specs = <WorktreeTerminalSpec>[];
  for (final terminal in terminals) {
    if (terminal is! Map) continue;
    final rawCommand = terminal['command'];
    if (rawCommand is! String || rawCommand.trim().isEmpty) continue;
    final rawName = terminal['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : null;
    specs.add(WorktreeTerminalSpec(command: rawCommand.trim(), name: name));
  }
  return List.unmodifiable(specs);
}

Future<void> _waitForManagerTerminal(
  TerminalManager terminals,
  String terminalId,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (terminals.capture(terminalId).lines.any((line) => line.isNotEmpty)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> _noReadinessWait(String _) async {}
