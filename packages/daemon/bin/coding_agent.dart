import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/pair_command.dart';
import 'package:agent_daemon/src/cli/agent_attach_command.dart';
import 'package:agent_daemon/src/cli/agent_import_command.dart';
import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/cli/agent_logs_command.dart';
import 'package:agent_daemon/src/cli/agent_run_command.dart';
import 'package:agent_daemon/src/cli/hub_command.dart';
import 'package:agent_daemon/src/cli/heartbeat_command.dart';
import 'package:agent_daemon/src/cli/provider_command.dart';
import 'package:agent_daemon/src/cli/schedule_command.dart';
import 'package:agent_daemon/src/cli/script_command.dart';
import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:agent_daemon/src/cli/workspace_command.dart';
import 'package:agent_daemon/src/cli/worktree_command.dart';
import 'package:agent_daemon/src/terminal/terminal_activity_hook.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments[0] == 'run') {
    exitCode = await runAgentRunCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.length >= 2 &&
      arguments[0] == 'agent' &&
      arguments[1] == 'run') {
    exitCode = await runAgentRunCommand(arguments: arguments.sublist(2));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'import') {
    exitCode = await runAgentImportCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.length >= 2 &&
      arguments[0] == 'agent' &&
      arguments[1] == 'import') {
    exitCode = await runAgentImportCommand(arguments: arguments.sublist(2));
    return;
  }
  if (arguments.length >= 2 &&
      arguments[0] == 'agent' &&
      arguments[1] == 'logs') {
    exitCode = await runAgentLogsCommand(arguments: arguments.sublist(2));
    return;
  }
  if (arguments.length >= 2 &&
      arguments[0] == 'agent' &&
      arguments[1] == 'attach') {
    exitCode = await runAgentAttachCommand(arguments: arguments.sublist(2));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'agent') {
    exitCode = await runAgentCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty &&
      (arguments[0] == 'ls' ||
          arguments[0] == 'attach' ||
          arguments[0] == 'inspect' ||
          arguments[0] == 'logs' ||
          arguments[0] == 'stop' ||
          arguments[0] == 'send' ||
          arguments[0] == 'wait' ||
          arguments[0] == 'archive' ||
          arguments[0] == 'delete')) {
    if (arguments[0] == 'logs') {
      exitCode = await runAgentLogsCommand(arguments: arguments.sublist(1));
      return;
    }
    if (arguments[0] == 'attach') {
      exitCode = await runAgentAttachCommand(arguments: arguments.sublist(1));
      return;
    }
    exitCode = await runAgentCommand(arguments: arguments);
    return;
  }
  if (arguments.length >= 2 &&
      arguments[0] == 'daemon' &&
      arguments[1] == 'pair') {
    final options = _parsePairOptions(arguments.sublist(2));
    if (options == null) {
      stderr.writeln(
        'Usage: coding-agent daemon pair [--home <path>] [--json]',
      );
      exitCode = 64;
      return;
    }
    exitCode = await runPairCommand(
      options: options,
      terminalColumns: stdout.hasTerminal ? stdout.terminalColumns : null,
    );
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'hub') {
    exitCode = await runHubCliCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'schedule') {
    exitCode = await runScheduleCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'heartbeat') {
    exitCode = await runHeartbeatCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'script') {
    exitCode = await runScriptCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'provider') {
    exitCode = await runProviderCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'terminal') {
    exitCode = await runTerminalCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'workspace') {
    exitCode = await runWorkspaceCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'worktree') {
    exitCode = await runWorktreeCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.length >= 3 && arguments.first == 'hooks') {
    final input = stdin.hasTerminal ? null : await _readHookInput();
    await reportTerminalHookActivity(
      provider: arguments[1],
      event: arguments[2],
      environment: Platform.environment,
      input: input,
      inputIsTerminal: stdin.hasTerminal,
    );
    return;
  }

  stderr.writeln(
    'Usage: coding-agent daemon pair [--home <path>] [--json]\n'
    '       coding-agent run [options] <prompt>\n'
    '       coding-agent agent run [options] <prompt>\n'
    '       coding-agent import --provider <provider> <id> [options]\n'
    '       coding-agent agent import --provider <provider> <id> [options]\n'
    '       coding-agent agent '
    '<run|ls|inspect|mode|stop|send|wait|archive|delete|detach|reload|update|open|'
    'attach> '
    '...\n'
    '       coding-agent agent logs <id> [options]\n'
    '       coding-agent <ls|inspect|logs|attach|stop|send|wait|archive|delete> '
    '...\n'
    '       coding-agent hub connect <url> [--token <token>] '
    '[--host <host>] [--json]\n'
    '       coding-agent hub status [--host <host>] [--json]\n'
    '       coding-agent hub disconnect [--force] [--host <host>] [--json]\n'
    '       coding-agent schedule <create|ls|inspect|logs|pause|resume|'
    'delete|run-once|update> ...\n'
    '       coding-agent heartbeat <create|update|delete> ...\n'
    '       coding-agent script <ls|start|stop> ...\n'
    '       coding-agent provider <ls|models> ...\n'
    '       coding-agent workspace <create|ls|archive> ...\n'
    '       coding-agent worktree <create|ls|archive> ...\n'
    '       coding-agent terminal <ls|create|capture|send-keys|kill> ...\n'
    '       coding-agent hooks <agent> <event>',
  );
  exitCode = 64;
}

PairCommandOptions? _parsePairOptions(List<String> arguments) {
  String? home;
  var json = false;
  for (var index = 0; index < arguments.length; index++) {
    switch (arguments[index]) {
      case '--json':
        json = true;
      case '--home':
        if (index + 1 >= arguments.length) return null;
        home = arguments[++index];
      default:
        return null;
    }
  }
  return PairCommandOptions(home: home, json: json);
}

Future<String?> _readHookInput() async {
  final iterator = StreamIterator<List<int>>(stdin);
  final bytes = <int>[];
  try {
    while (await iterator.moveNext().timeout(
      const Duration(milliseconds: 100),
    )) {
      bytes.addAll(iterator.current);
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on TimeoutException {
    await iterator.cancel();
    return null;
  }
}
