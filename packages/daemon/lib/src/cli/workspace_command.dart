import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'terminal_command.dart';

typedef WorkspaceRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runWorkspaceCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  WorkspaceRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_workspaceHelp(arguments.firstOrNull));
    return 0;
  }
  try {
    final invocation = WorkspaceCliInvocation.parse(arguments);
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
        throw WorkspaceCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
        );
      }
    }
    final result = await _execute(
      invocation,
      send,
      currentDirectory ?? Directory.current.path,
    );
    output(_render(result, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$workspaceUsage\n');
    return 64;
  } on WorkspaceCommandException catch (error) {
    _writeCommandError(errorOutput, error, arguments);
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      WorkspaceCommandException('WORKSPACE_ERROR', _errorText(error)),
      arguments,
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class WorkspaceCliInvocation {
  const WorkspaceCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.format,
    required this.quiet,
    required this.headers,
    required this.host,
  });

  final String action;
  final List<String> positionals;
  final Map<String, String> values;
  final String format;
  final bool quiet;
  final bool headers;
  final String? host;

  static WorkspaceCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing workspace action');
    }
    final action = arguments.first;
    if (!const {'create', 'ls', 'archive'}.contains(action)) {
      throw FormatException('Unknown workspace action: $action');
    }
    const createOptions = {
      '--isolation',
      '--path',
      '--project',
      '--title',
      '--mode',
      '--worktree-slug',
      '--new-branch',
      '--base',
      '--branch',
      '--pr-number',
      '--forge',
    };
    final positionals = <String>[];
    final values = <String, String>{};
    var format = 'table';
    var quiet = false;
    var headers = true;
    String? host;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          format = 'json';
        case '-o' || '--format':
          format = _requiredValue(arguments, ++index, argument);
          if (!const {'table', 'json', 'yaml'}.contains(format)) {
            throw FormatException('Unknown output format: $format');
          }
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          break;
        default:
          if (createOptions.contains(argument)) {
            if (action != 'create') {
              throw FormatException(
                '$argument is only valid for workspace create',
              );
            }
            values[argument] = _requiredValue(arguments, ++index, argument);
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            positionals.add(argument);
          }
      }
    }
    if (action == 'create') {
      if (positionals.isNotEmpty) {
        throw const FormatException(
          'workspace create does not accept an argument',
        );
      }
      if ((values['--isolation']?.trim().isEmpty ?? true)) {
        throw const FormatException('--isolation is required');
      }
    } else if (action == 'ls') {
      if (positionals.isNotEmpty) {
        throw const FormatException('workspace ls does not accept an argument');
      }
    } else if (positionals.length != 1 || positionals.single.trim().isEmpty) {
      throw const FormatException(
        'workspace archive requires one workspace id',
      );
    }
    return WorkspaceCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      format: format,
      quiet: quiet,
      headers: headers,
      host: host,
    );
  }
}

Map<String, Object?> buildWorkspaceCreateSource(
  WorkspaceCliInvocation invocation,
  String currentDirectory,
) {
  final values = invocation.values;
  final isolation = values['--isolation']?.trim();
  final path = _nonEmpty(values['--path']);
  final project = _nonEmpty(values['--project']);
  if (isolation == 'local') {
    _assertAbsent(values, const [
      '--mode',
      '--worktree-slug',
      '--new-branch',
      '--base',
      '--branch',
      '--pr-number',
      '--forge',
    ], 'Worktree options require --isolation worktree');
    return {
      'kind': 'directory',
      'path': path ?? currentDirectory,
      if (project != null) 'projectId': project,
    };
  }
  if (isolation != 'worktree') {
    throw FormatException(
      'Unsupported workspace isolation: ${isolation ?? 'null'}',
    );
  }
  final source = <String, Object?>{
    'kind': 'worktree',
    if (path != null)
      'cwd': path
    else if (project == null)
      'cwd': currentDirectory,
    if (project != null) 'projectId': project,
    if (_nonEmpty(values['--worktree-slug']) case final slug?)
      'worktreeSlug': slug,
  };
  switch (_nonEmpty(values['--mode']) ?? 'branch-off') {
    case 'branch-off':
      _assertAbsent(values, const [
        '--branch',
        '--pr-number',
        '--forge',
      ], '--branch, --pr-number, and --forge require a checkout mode');
      return {
        ...source,
        'action': 'branch-off',
        if (_nonEmpty(values['--new-branch']) case final branch?)
          'branchName': branch,
        if (_nonEmpty(values['--base']) case final base?) 'baseBranch': base,
      };
    case 'checkout-branch':
      final branch = _nonEmpty(values['--branch']);
      if (branch == null) {
        throw const FormatException(
          '--branch is required for --mode checkout-branch',
        );
      }
      _assertAbsent(
        values,
        const ['--new-branch', '--base', '--pr-number', '--forge'],
        '--new-branch, --base, --pr-number, and --forge are not valid for '
        '--mode checkout-branch',
      );
      return {...source, 'action': 'checkout', 'refName': branch};
    case 'checkout-pr':
      final rawNumber = _nonEmpty(values['--pr-number']);
      if (rawNumber == null) {
        throw const FormatException(
          '--pr-number is required for --mode checkout-pr',
        );
      }
      final number = int.tryParse(rawNumber);
      if (number == null || number <= 0) {
        throw const FormatException('--pr-number must be a positive integer');
      }
      _assertAbsent(
        values,
        const ['--new-branch', '--base', '--branch'],
        '--new-branch, --base, and --branch are not valid for '
        '--mode checkout-pr',
      );
      return {
        ...source,
        'action': 'checkout',
        'checkoutSource': {
          'kind': 'change_request',
          if (_nonEmpty(values['--forge']) case final forge?) 'forge': forge,
          'number': number,
        },
      };
    case final mode:
      throw FormatException('Unsupported worktree mode: $mode');
  }
}

Future<_WorkspaceCommandResult> _execute(
  WorkspaceCliInvocation invocation,
  WorkspaceRpcRequester request,
  String currentDirectory,
) async {
  switch (invocation.action) {
    case 'create':
      final requestId = _requestId('workspace_create');
      Map<String, Object?> source;
      try {
        source = buildWorkspaceCreateSource(invocation, currentDirectory);
      } on Object catch (error) {
        throw WorkspaceCommandException(
          'WORKSPACE_CREATE_FAILED',
          _errorText(error),
        );
      }
      final payload = await _request(
        request,
        WorkspaceCreateRequest(
          requestId: requestId,
          source: WorkspaceCreateSource.fromJson(source),
          title: _nonEmpty(invocation.values['--title']),
        ).toJson(),
        code: 'WORKSPACE_CREATE_FAILED',
      );
      final error = _nonEmpty(payload['error']?.toString());
      final workspace = _mapOrNull(payload['workspace']);
      if (workspace == null) {
        throw WorkspaceCommandException(
          'WORKSPACE_CREATE_FAILED',
          error ?? 'Workspace creation failed',
        );
      }
      return _WorkspaceCommandResult.single(_workspaceRow(workspace));
    case 'ls':
      final rows = <Map<String, Object?>>[];
      String? cursor;
      do {
        final requestId = _requestId('workspace_ls');
        final payload = await _request(
          request,
          FetchWorkspacesRequest(
            requestId: requestId,
            limit: 200,
            cursor: cursor,
          ).toJson(),
          code: 'WORKSPACE_LIST_FAILED',
        );
        final entries = payload['entries'];
        if (entries is! List) {
          throw const WorkspaceCommandException(
            'WORKSPACE_LIST_FAILED',
            'Workspace list response is missing entries',
          );
        }
        for (final entry in entries) {
          if (entry is! Map) {
            throw const WorkspaceCommandException(
              'WORKSPACE_LIST_FAILED',
              'Workspace list contains an invalid entry',
            );
          }
          rows.add(_workspaceRow(entry.cast<String, Object?>()));
        }
        final pageInfo = _mapOrNull(payload['pageInfo']);
        cursor = _nonEmpty(pageInfo?['nextCursor']?.toString());
      } while (cursor != null);
      return _WorkspaceCommandResult.list(rows);
    case 'archive':
      final workspaceId = invocation.positionals.single.trim();
      final requestId = _requestId('workspace_archive');
      final payload = await _request(
        request,
        ArchiveWorkspaceRequest(
          workspaceId: workspaceId,
          requestId: requestId,
        ).toJson(),
        code: 'WORKSPACE_ARCHIVE_FAILED',
      );
      final error = _nonEmpty(payload['error']?.toString());
      if (error != null) {
        throw WorkspaceCommandException('WORKSPACE_ARCHIVE_FAILED', error);
      }
      final archivedAt = _nonEmpty(payload['archivedAt']?.toString());
      if (archivedAt == null) {
        throw const WorkspaceCommandException(
          'WORKSPACE_ARCHIVE_FAILED',
          'Workspace archive did not return an archive timestamp',
        );
      }
      return _WorkspaceCommandResult.single({
        'workspaceId': workspaceId,
        'status': 'archived',
        'archivedAt': archivedAt,
      }, archive: true);
  }
  throw StateError('Unhandled workspace action');
}

Future<Map<String, Object?>> _request(
  WorkspaceRpcRequester request,
  Map<String, Object?> message, {
  required String code,
}) async {
  try {
    return await request(message);
  } on WorkspaceCommandException {
    rethrow;
  } on Object catch (error) {
    throw WorkspaceCommandException(code, _errorText(error));
  }
}

Map<String, Object?> _workspaceRow(Map<String, Object?> workspace) {
  String requiredString(String field) {
    final value = workspace[field];
    if (value is! String || value.isEmpty) {
      throw WorkspaceCommandException(
        'WORKSPACE_ERROR',
        'Workspace response is missing $field',
      );
    }
    return value;
  }

  final kind = requiredString('workspaceKind');
  return {
    'workspaceId': requiredString('id'),
    'project': requiredString('projectDisplayName'),
    'name': requiredString('name'),
    'isolation': kind == 'worktree' ? 'worktree' : 'local',
    'cwd': requiredString('workspaceDirectory'),
  };
}

final class _WorkspaceCommandResult {
  const _WorkspaceCommandResult._({
    required this.rows,
    required this.single,
    required this.archive,
  });

  factory _WorkspaceCommandResult.list(List<Map<String, Object?>> rows) =>
      _WorkspaceCommandResult._(
        rows: List.unmodifiable(rows),
        single: false,
        archive: false,
      );

  factory _WorkspaceCommandResult.single(
    Map<String, Object?> row, {
    bool archive = false,
  }) => _WorkspaceCommandResult._(
    rows: [Map.unmodifiable(row)],
    single: true,
    archive: archive,
  );

  final List<Map<String, Object?>> rows;
  final bool single;
  final bool archive;
}

String _render(
  _WorkspaceCommandResult result,
  WorkspaceCliInvocation invocation,
) {
  final idField = result.archive ? 'workspaceId' : 'workspaceId';
  if (invocation.quiet) {
    return result.rows.map((row) => '${row[idField]}').join('\n') +
        (result.rows.isEmpty ? '' : '\n');
  }
  final value = result.single ? result.rows.single : result.rows;
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(value)}\n';
  }
  if (invocation.format == 'yaml') {
    return result.single
        ? _yamlMap(result.rows.single)
        : _yamlList(result.rows);
  }
  final columns = result.archive
      ? const [
          ('WORKSPACE ID', 'workspaceId', 20),
          ('STATUS', 'status', 10),
          ('ARCHIVED AT', 'archivedAt', 26),
        ]
      : const [
          ('WORKSPACE ID', 'workspaceId', 20),
          ('PROJECT', 'project', 20),
          ('NAME', 'name', 22),
          ('ISOLATION', 'isolation', 10),
          ('CWD', 'cwd', 42),
        ];
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in result.rows) '${row[column.$2] ?? ''}'.length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return [
        if (invocation.headers) line([for (final column in columns) column.$1]),
        for (final row in result.rows)
          line([for (final column in columns) '${row[column.$2] ?? ''}']),
      ].join('\n') +
      (invocation.headers || result.rows.isNotEmpty ? '\n' : '');
}

String _yamlList(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlMap(Map<String, Object?> row) =>
    '${[for (final entry in row.entries) '${entry.key}: ${_yamlScalar(entry.value)}'].join('\n')}\n';

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  final text = '$value';
  if (text.isNotEmpty &&
      !RegExp(
        r'''[:#\[\]{},&*!|>'"%@`]|^\s|\s$|^(null|true|false|~)$''',
        caseSensitive: false,
      ).hasMatch(text)) {
    return text;
  }
  return jsonEncode(text);
}

void _assertAbsent(
  Map<String, String> values,
  List<String> options,
  String message,
) {
  if (options.any(values.containsKey)) throw FormatException(message);
}

void _writeCommandError(
  void Function(String value) write,
  WorkspaceCommandException error,
  List<String> arguments,
) {
  if (arguments.contains('--json')) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message},
      })}\n',
    );
  } else {
    write('Error: ${error.message}\n');
  }
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class WorkspaceCommandException implements Exception {
  const WorkspaceCommandException(this.code, this.message);

  final String code;
  final String message;
}

const workspaceUsage =
    'Usage: coding-agent workspace create --isolation <local|worktree> '
    '[options]\n'
    '       coding-agent workspace ls [--host <host>] [--json]\n'
    '       coding-agent workspace archive <workspace-id> '
    '[--host <host>] [--json]';

String _workspaceHelp(String? action) => switch (action) {
  'create' =>
    'Usage: coding-agent workspace create [options]\n'
        'Create a workspace\n',
  'ls' =>
    'Usage: coding-agent workspace ls [options]\n'
        'List active workspaces\n',
  'archive' =>
    'Usage: coding-agent workspace archive [options] <workspace-id>\n'
        'Archive a workspace and everything it owns\n',
  _ =>
    'Usage: coding-agent workspace [command]\n'
        'Manage workspaces\n\n'
        'Commands:\n'
        '  create  Create a workspace\n'
        '  ls      List active workspaces\n'
        '  archive Archive a workspace and everything it owns\n',
};
