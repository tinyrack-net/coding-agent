import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_config.dart';
import 'cli_output.dart';
import 'terminal_command.dart';

typedef WorktreeRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runWorktreeCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  WorktreeRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_worktreeHelp(arguments.firstOrNull));
    return 0;
  }
  WorktreeCliInvocation? invocation;
  try {
    invocation = WorktreeCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    var send = request;
    if (send == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
        send = client.request;
      } on Object catch (error) {
        final host = invocation.host ?? '${config.host}:${config.port}';
        throw WorktreeCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          details: 'Start the daemon with: coding-agent daemon start',
        );
      }
    }
    final result = await _execute(
      invocation,
      send,
      currentDirectory ?? Directory.current.path,
      env,
    );
    final schema = switch (result.kind) {
      _WorktreeResultKind.create => _worktreeCreateSchema,
      _WorktreeResultKind.list => _worktreeListSchema,
      _WorktreeResultKind.archive => _worktreeArchiveSchema,
    };
    final cliResult = result.single
        ? CliOutputResult.single(row: result.rows.single, schema: schema)
        : CliOutputResult.list(rows: result.rows, schema: schema);
    final rendered = renderCliOutput(cliResult, invocation.output);
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$worktreeUsage\n');
    return 64;
  } on WorktreeCommandException catch (error) {
    _writeCommandError(
      errorOutput,
      error,
      invocation?.output ?? _recoverWorktreeOutputOptions(arguments),
    );
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      WorktreeCommandException('WORKTREE_ERROR', _errorText(error)),
      invocation?.output ?? _recoverWorktreeOutputOptions(arguments),
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class WorktreeCliInvocation {
  const WorktreeCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.output,
    required this.host,
  });

  final String action;
  final List<String> positionals;
  final Map<String, String> values;
  final CliOutputOptions output;
  final String? host;

  static WorktreeCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing worktree action');
    }
    final action = arguments.first;
    if (!const {'create', 'ls', 'archive'}.contains(action)) {
      throw FormatException('Unknown worktree action: $action');
    }
    const createOptions = {
      '--cwd',
      '--mode',
      '--new-branch',
      '--base',
      '--branch',
      '--pr-number',
    };
    final positionals = <String>[];
    final values = <String, String>{};
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    var positionalOnly = false;
    String? host;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly) {
        final longOption = _splitLongOption(argument);
        if (longOption != null) {
          final (option, value) = longOption;
          switch (option) {
            case '--host':
              host = value;
              continue;
            case '--format':
              format = normalizeCliOutputFormat(value);
              continue;
            default:
              if (createOptions.contains(option)) {
                if (action != 'create') {
                  throw FormatException(
                    '$option is only valid for worktree create',
                  );
                }
                values[option] = value;
                continue;
              }
          }
        }
      }
      if (!positionalOnly && argument == '--') {
        positionalOnly = true;
        continue;
      }
      if (positionalOnly) {
        positionals.add(argument);
        continue;
      }
      switch (argument) {
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
        case '-o' || '--format':
          format = normalizeCliOutputFormat(
            _requiredValue(arguments, ++index, argument),
          );
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          color = false;
        default:
          if (createOptions.contains(argument)) {
            if (action != 'create') {
              throw FormatException(
                '$argument is only valid for worktree create',
              );
            }
            values[argument] = _requiredValue(arguments, ++index, argument);
          } else if (argument.startsWith('-o') && argument.length > 2) {
            format = normalizeCliOutputFormat(argument.substring(2));
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            positionals.add(argument);
          }
      }
    }
    if (action == 'create' && positionals.isNotEmpty) {
      throw const FormatException(
        'worktree create does not accept an argument',
      );
    }
    if (action == 'ls' && positionals.isNotEmpty) {
      throw const FormatException('worktree ls does not accept an argument');
    }
    if (action == 'archive' &&
        (positionals.length != 1 || positionals.single.trim().isEmpty)) {
      throw const FormatException(
        'worktree archive requires one worktree name',
      );
    }
    return WorktreeCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
      host: host,
    );
  }
}

CreatePaseoWorktreeRequest buildCreateWorktreeRequest(
  WorktreeCliInvocation invocation,
  String currentDirectory, {
  String requestId = 'request',
}) {
  final cwd = _nonEmpty(invocation.values['--cwd']) ?? currentDirectory;
  final mode = _nonEmpty(invocation.values['--mode']);
  if (mode == null) {
    throw const WorktreeCommandException(
      'MISSING_MODE',
      '--mode is required',
      details: 'Expected one of: branch-off, checkout-branch, checkout-pr',
    );
  }
  switch (mode) {
    case 'branch-off':
      final branch = _nonEmpty(invocation.values['--new-branch']);
      if (branch == null) {
        throw const WorktreeCommandException(
          'MISSING_NEW_BRANCH',
          '--new-branch is required for --mode branch-off',
        );
      }
      return CreatePaseoWorktreeRequest(
        requestId: requestId,
        cwd: cwd,
        worktreeSlug: branch,
        action: 'branch-off',
        refName: _nonEmpty(invocation.values['--base']),
      );
    case 'checkout-branch':
      final branch = _nonEmpty(invocation.values['--branch']);
      if (branch == null) {
        throw const WorktreeCommandException(
          'MISSING_BRANCH',
          '--branch is required for --mode checkout-branch',
        );
      }
      return CreatePaseoWorktreeRequest(
        requestId: requestId,
        cwd: cwd,
        action: 'checkout',
        refName: branch,
      );
    case 'checkout-pr':
      final raw = invocation.values['--pr-number'];
      if (raw == null || raw.isEmpty) {
        throw const WorktreeCommandException(
          'MISSING_PR_NUMBER',
          '--pr-number is required for --mode checkout-pr',
        );
      }
      final number = int.tryParse(raw);
      if (number == null || number <= 0) {
        throw WorktreeCommandException(
          'INVALID_PR_NUMBER',
          'Invalid --pr-number: $raw',
          details: 'Expected a positive integer',
        );
      }
      return CreatePaseoWorktreeRequest(
        requestId: requestId,
        cwd: cwd,
        action: 'checkout',
        githubPrNumber: number,
      );
    default:
      throw WorktreeCommandException(
        'INVALID_MODE',
        'Invalid --mode: $mode',
        details: 'Expected one of: branch-off, checkout-branch, checkout-pr',
      );
  }
}

Future<_WorktreeCommandResult> _execute(
  WorktreeCliInvocation invocation,
  WorktreeRpcRequester request,
  String currentDirectory,
  Map<String, String> environment,
) async {
  switch (invocation.action) {
    case 'create':
      CreatePaseoWorktreeRequest message;
      try {
        message = buildCreateWorktreeRequest(
          invocation,
          currentDirectory,
          requestId: _requestId('worktree_create'),
        );
      } on WorktreeCommandException {
        rethrow;
      }
      final payload = await _request(
        request,
        message.toJson(),
        code: 'WORKTREE_CREATE_FAILED',
      );
      final workspace = _mapOrNull(payload['workspace']);
      final error = payload['error']?.toString();
      if (workspace == null) {
        throw WorktreeCommandException(
          'WORKTREE_CREATE_FAILED',
          'Failed to create worktree: ${_nonEmpty(error) ?? 'no workspace returned'}',
        );
      }
      final path = _requiredString(workspace, 'workspaceDirectory');
      return _WorktreeCommandResult.single({
        'name': p.basename(path),
        'branchName': _requiredString(workspace, 'name'),
        'worktreePath': path,
      }, kind: _WorktreeResultKind.create);
    case 'ls':
      final agentByCwd = await _fetchManagedAgentMap(request, environment);
      final payload = await _request(
        request,
        PaseoWorktreeListRequest(requestId: _requestId('worktree_ls')).toJson(),
        code: 'WORKTREE_LIST_FAILED',
      );
      if (_mapOrNull(payload['error']) case final error?) {
        throw WorktreeCommandException(
          'WORKTREE_LIST_FAILED',
          'Failed to list worktrees: ${error['message']}',
        );
      }
      final rows = <Map<String, Object?>>[];
      for (final entry in _maps(payload['worktrees'])) {
        final path = _requiredString(entry, 'worktreePath');
        rows.add({
          'name': p.basename(path),
          'branch': _nonEmpty(entry['branchName']?.toString()) ?? '-',
          'cwd': _shortenHome(path, environment),
          'agent': agentByCwd[_pathKey(path)] ?? '-',
        });
      }
      return _WorktreeCommandResult.list(rows);
    case 'archive':
      final name = invocation.positionals.single;
      final listPayload = await _request(
        request,
        PaseoWorktreeListRequest(
          requestId: _requestId('worktree_archive_list'),
        ).toJson(),
        code: 'WORKTREE_LIST_FAILED',
      );
      if (_mapOrNull(listPayload['error']) case final error?) {
        throw WorktreeCommandException(
          'WORKTREE_LIST_FAILED',
          'Failed to list worktrees: ${error['message']}',
        );
      }
      Map<String, Object?>? match;
      for (final worktree in _maps(listPayload['worktrees'])) {
        final path = _requiredString(worktree, 'worktreePath');
        if (p.basename(path) == name || worktree['branchName'] == name) {
          match = worktree;
          break;
        }
      }
      if (match == null) {
        throw WorktreeCommandException(
          'WORKTREE_NOT_FOUND',
          'Worktree not found: $name',
          details: 'Use "coding-agent worktree ls" to list available worktrees',
        );
      }
      final path = _requiredString(match, 'worktreePath');
      final archivePayload = await _request(
        request,
        PaseoWorktreeArchiveRequest(
          requestId: _requestId('worktree_archive'),
          worktreePath: path,
          scope: 'worktree',
        ).toJson(),
        code: 'WORKTREE_ARCHIVE_FAILED',
      );
      if (_mapOrNull(archivePayload['error']) case final error?) {
        throw WorktreeCommandException(
          'WORKTREE_ARCHIVE_FAILED',
          'Failed to archive worktree: ${error['message']}',
        );
      }
      return _WorktreeCommandResult.single({
        'name': p.basename(path).isEmpty ? name : p.basename(path),
        'status': 'archived',
        'removedAgents': _strings(archivePayload['removedAgents']),
      }, kind: _WorktreeResultKind.archive);
  }
  throw StateError('Unhandled worktree action');
}

Future<Map<String, String>> _fetchManagedAgentMap(
  WorktreeRpcRequester request,
  Map<String, String> environment,
) async {
  final managedRoot = _managedWorktreesRoot(environment);
  final result = <String, String>{};
  String? cursor;
  do {
    final requestId = _requestId('worktree_agents');
    final payload = await _request(
      request,
      FetchAgentsRequest(
        requestId: requestId,
        filter: const AgentDirectoryFilter(includeArchived: true),
        limit: 200,
        cursor: cursor,
      ).toJson(),
      code: 'WORKTREE_LIST_FAILED',
    );
    for (final entry in _maps(payload['entries'])) {
      final agent = _mapOrNull(entry['agent']);
      if (agent == null) continue;
      final cwd = agent['cwd'];
      final id = agent['id'];
      if (cwd is! String || id is! String) continue;
      if (_sameOrDescendant(managedRoot, cwd)) {
        result[_pathKey(cwd)] = id.substring(0, id.length.clamp(0, 7));
      }
    }
    cursor = _nonEmpty(
      _mapOrNull(payload['pageInfo'])?['nextCursor']?.toString(),
    );
  } while (cursor != null);
  return result;
}

Future<Map<String, Object?>> _request(
  WorktreeRpcRequester request,
  Map<String, Object?> message, {
  required String code,
}) async {
  try {
    return await request(message);
  } on WorktreeCommandException {
    rethrow;
  } on Object catch (error) {
    throw WorktreeCommandException(code, _errorText(error));
  }
}

enum _WorktreeResultKind { create, list, archive }

final class _WorktreeCommandResult {
  const _WorktreeCommandResult._({
    required this.rows,
    required this.single,
    required this.kind,
  });

  factory _WorktreeCommandResult.list(List<Map<String, Object?>> rows) =>
      _WorktreeCommandResult._(
        rows: List.unmodifiable(rows),
        single: false,
        kind: _WorktreeResultKind.list,
      );

  factory _WorktreeCommandResult.single(
    Map<String, Object?> row, {
    required _WorktreeResultKind kind,
  }) => _WorktreeCommandResult._(
    rows: [Map.unmodifiable(row)],
    single: true,
    kind: kind,
  );

  final List<Map<String, Object?>> rows;
  final bool single;
  final _WorktreeResultKind kind;
}

final _worktreeCreateSchema = CliOutputSchema(
  idField: (row) => '${row['worktreePath']}',
  columns: [
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 24),
    CliOutputColumn(
      header: 'BRANCH',
      field: (row) => row['branchName'],
      width: 28,
    ),
    CliOutputColumn(
      header: 'PATH',
      field: (row) => row['worktreePath'],
      width: 50,
    ),
  ],
);

final _worktreeListSchema = CliOutputSchema(
  idField: (row) => '${row['name']}',
  columns: [
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 20),
    CliOutputColumn(header: 'BRANCH', field: (row) => row['branch'], width: 25),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 45),
    CliOutputColumn(header: 'AGENT', field: (row) => row['agent'], width: 10),
  ],
);

final _worktreeArchiveSchema = CliOutputSchema(
  idField: (row) => '${row['name']}',
  columns: [
    CliOutputColumn(header: 'NAME', field: (row) => row['name']),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status']),
    CliOutputColumn(
      header: 'REMOVED AGENTS',
      field: (row) {
        final agents = row['removedAgents'];
        return agents is List && agents.isNotEmpty ? agents.join(', ') : '-';
      },
    ),
  ],
);

String _managedWorktreesRoot(Map<String, String> environment) {
  final configured = _nonEmpty(environment['TINYRACK_HOME']);
  final home =
      _nonEmpty(environment['USERPROFILE']) ??
      _nonEmpty(environment['HOME']) ??
      Directory.current.path;
  return p.join(configured ?? p.join(home, '.tinyrack-agent'), 'worktrees');
}

String _shortenHome(String path, Map<String, String> environment) {
  final home = environment['HOME'];
  if (home != null && home.isNotEmpty && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

bool _sameOrDescendant(String root, String candidate) {
  final rootKey = _pathKey(root);
  final candidateKey = _pathKey(candidate);
  return candidateKey == rootKey ||
      candidateKey.startsWith('$rootKey${p.separator}');
}

String _pathKey(String value) {
  final normalized = p.normalize(p.absolute(value));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

List<Map<String, Object?>> _maps(Object? value) => [
  for (final entry in value is List ? value : const [])
    if (entry is Map) entry.cast<String, Object?>(),
];

List<String> _strings(Object? value) => [
  for (final entry in value is List ? value : const [])
    if (entry is String) entry,
];

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw WorktreeCommandException(
      'WORKTREE_ERROR',
      'Worktree response is missing $field',
    );
  }
  return value;
}

void _writeCommandError(
  void Function(String value) write,
  WorktreeCommandException error,
  CliOutputOptions options,
) {
  write(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

CliOutputOptions _recoverWorktreeOutputOptions(List<String> arguments) {
  var format = 'table';
  var json = false;
  var quiet = false;
  var noHeaders = false;
  var noColor = false;
  for (var index = 1; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--') {
      break;
    } else if (argument == '--json') {
      json = true;
    } else if (argument == '-q' || argument == '--quiet') {
      quiet = true;
    } else if (argument == '--no-headers') {
      noHeaders = true;
    } else if (argument == '--no-color') {
      noColor = true;
    } else if (argument == '-o' || argument == '--format') {
      if (index + 1 < arguments.length) {
        format = _safeWorktreeOutputFormat(arguments[++index], format);
      }
    } else if (argument.startsWith('--format=')) {
      format = _safeWorktreeOutputFormat(
        argument.substring('--format='.length),
        format,
      );
    } else if (argument.startsWith('-o') && argument.length > 2) {
      format = _safeWorktreeOutputFormat(argument.substring(2), format);
    }
  }
  return CliOutputOptions(
    format: json ? 'json' : format,
    quiet: quiet,
    noHeaders: noHeaders,
    noColor: noColor,
  );
}

String _safeWorktreeOutputFormat(String value, String fallback) {
  try {
    return normalizeCliOutputFormat(value);
  } on FormatException {
    return fallback;
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class WorktreeCommandException implements Exception {
  const WorktreeCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const worktreeUsage =
    'Usage: coding-agent worktree create --mode '
    '<branch-off|checkout-branch|checkout-pr> [options]\n'
    '       coding-agent worktree ls [--host <host>] [--json]\n'
    '       coding-agent worktree archive <name> '
    '[--host <host>] [--json]';

String _worktreeHelp(String? action) => switch (action) {
  'create' =>
    'Usage: coding-agent worktree create [options]\n'
        'Create a Tinyrack-managed git worktree\n',
  'ls' =>
    'Usage: coding-agent worktree ls [options]\n'
        'List Tinyrack-managed git worktrees\n',
  'archive' =>
    'Usage: coding-agent worktree archive [options] <name>\n'
        'Archive a worktree (removes worktree and associated branch)\n',
  _ =>
    'Usage: coding-agent worktree [command]\n'
        'Manage Tinyrack-managed git worktrees\n\n'
        'Commands:\n'
        '  create  Create a managed git worktree\n'
        '  ls      List managed git worktrees\n'
        '  archive Archive a worktree\n',
};
