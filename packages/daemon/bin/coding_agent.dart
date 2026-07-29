import 'dart:io';

import 'package:agent_daemon/src/cli/daemon_command.dart';
import 'package:agent_daemon/src/cli/chat_command.dart';
import 'package:agent_daemon/src/cli/clone_command.dart';
import 'package:agent_daemon/src/cli/cli_invocation.dart';
import 'package:agent_daemon/src/cli/cli_version.dart';
import 'package:agent_daemon/src/cli/hooks_command.dart';
import 'package:agent_daemon/src/cli/open_command.dart';
import 'package:agent_daemon/src/cli/onboard_command.dart';
import 'package:agent_daemon/src/cli/agent_attach_command.dart';
import 'package:agent_daemon/src/cli/agent_import_command.dart';
import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/cli/agent_logs_command.dart';
import 'package:agent_daemon/src/cli/agent_run_command.dart';
import 'package:agent_daemon/src/cli/hub_command.dart';
import 'package:agent_daemon/src/cli/heartbeat_command.dart';
import 'package:agent_daemon/src/cli/loop_command.dart';
import 'package:agent_daemon/src/cli/permit_command.dart';
import 'package:agent_daemon/src/cli/provider_command.dart';
import 'package:agent_daemon/src/cli/schedule_command.dart';
import 'package:agent_daemon/src/cli/script_command.dart';
import 'package:agent_daemon/src/cli/speech_command.dart';
import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:agent_daemon/src/cli/workspace_command.dart';
import 'package:agent_daemon/src/cli/worktree_command.dart';

Future<void> main(List<String> arguments) async {
  final invocation = classifyCliInvocation(
    arguments: arguments,
    knownCommands: codingAgentKnownCommands,
    currentDirectory: Directory.current.path,
  );
  if (invocation case OpenProjectCliInvocation(:final resolvedPath)) {
    exitCode = await runOpenProjectInvocation(projectPath: resolvedPath);
    return;
  }
  arguments = defaultEmptyCliArguments(arguments);
  final normalizedRoot = normalizeRootCliArguments(arguments);
  arguments = normalizedRoot.forward();
  if (arguments.isEmpty) {
    exitCode = 0;
    return;
  }
  if (arguments.first == 'help') {
    if (arguments.length == 1) {
      stdout.write(_rootHelp);
      exitCode = 0;
      return;
    }
    arguments = [...arguments.sublist(1), '--help'];
  }
  if (arguments.first == '--help' || arguments.first == '-h') {
    stdout.write(_rootHelp);
    exitCode = 0;
    return;
  }
  if (arguments.first == '--version' || arguments.first == '-v') {
    stdout.writeln(resolveCliVersion());
    exitCode = 0;
    return;
  }
  if (arguments.first == 'onboard') {
    exitCode = await runOnboardCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments.first == 'hooks') {
    exitCode = await runHooksCommand(arguments: arguments.sublist(1));
    return;
  }
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
  if (const {'start', 'status', 'restart'}.contains(arguments.first)) {
    exitCode = await runDaemonCommand(arguments: arguments, topLevel: true);
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'daemon') {
    exitCode = await runDaemonCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'chat') {
    exitCode = await runChatCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'clone') {
    exitCode = await runCloneCommand(arguments: arguments.sublist(1));
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
  if (arguments.isNotEmpty && arguments[0] == 'loop') {
    exitCode = await runLoopCommand(arguments: arguments.sublist(1));
    return;
  }
  if (arguments.isNotEmpty && arguments[0] == 'permit') {
    exitCode = await runPermitCommand(arguments: arguments.sublist(1));
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
  if (arguments.isNotEmpty && arguments[0] == 'speech') {
    exitCode = await runSpeechCommand(arguments: arguments.sublist(1));
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
  stderr.writeln(
    'Usage: coding-agent onboard [options]\n'
    '       coding-agent <start|status|restart> ...\n'
    '       coding-agent daemon '
    '<start|status|stop|restart|set-password|pair> ...\n'
    '       coding-agent chat '
    '<create|ls|inspect|delete|post|read|wait> ...\n'
    '       coding-agent clone <repo> --dir <path> '
    '[--protocol <https|ssh>] ...\n'
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
    '       coding-agent loop <run|ls|inspect|logs|stop> ...\n'
    '       coding-agent permit <ls|allow|deny> ...\n'
    '       coding-agent script <ls|start|stop> ...\n'
    '       coding-agent provider <ls|models> ...\n'
    '       coding-agent speech [options]\n'
    '       coding-agent workspace <create|ls|archive> ...\n'
    '       coding-agent worktree <create|ls|archive> ...\n'
    '       coding-agent terminal <ls|create|capture|send-keys|kill> ...\n'
    '       coding-agent hooks <agent> <event>',
  );
  exitCode = 64;
}

const _rootHelp =
    'Usage: coding-agent [options] [command]\n'
    '\n'
    'Tinyrack CLI - control your AI coding agents from the command line\n'
    '\n'
    'Options:\n'
    '  -v, --version        output the version number\n'
    '  -o, --format <format>  output format: table, json, yaml (default: "table")\n'
    '  --json               output in JSON format (alias for --format json)\n'
    '  -q, --quiet          minimal output (IDs only)\n'
    '  --no-headers         omit table headers\n'
    '  --no-color           disable colored output\n'
    '  -h, --help           display help for command\n'
    '\n'
    'Commands:\n'
    '  ls\n'
    '  run\n'
    '  import\n'
    '  clone\n'
    '  attach\n'
    '  logs\n'
    '  stop\n'
    '  delete\n'
    '  send\n'
    '  inspect\n'
    '  wait\n'
    '  archive\n'
    '  onboard\n'
    '  start\n'
    '  hooks\n'
    '  status\n'
    '  restart\n'
    '  agent\n'
    '  daemon\n'
    '  hub\n'
    '  chat\n'
    '  terminal\n'
    '  script\n'
    '  loop\n'
    '  schedule\n'
    '  heartbeat\n'
    '  permit\n'
    '  provider\n'
    '  speech              Speech commands\n'
    '  workspace\n'
    '  help [command]      display help for command\n';
