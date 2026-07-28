import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../providers/paseo/provider_manifest.dart';
import '../server/daemon_config.dart';
import 'terminal_command.dart';

typedef ProviderRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runProviderCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  ProviderRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_providerHelp(arguments.firstOrNull));
    return 0;
  }
  try {
    final invocation = ProviderCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    ProviderRpcRequester? rpc = request;
    if (rpc == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
        rpc = client.request;
      } catch (error) {
        if (invocation.action != 'ls') {
          final daemonHost = invocation.host ?? '${config.host}:${config.port}';
          throw ProviderCommandException(
            'DAEMON_NOT_RUNNING',
            'Cannot connect to daemon at $daemonHost: ${_errorText(error)}',
            details: 'Start the daemon with: coding-agent daemon start',
          );
        }
      }
    }

    final rows = invocation.action == 'ls'
        ? await _listProviders(invocation, rpc)
        : await _listModels(invocation, rpc!);
    output(_renderRows(rows, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$providerUsage\n');
    return 64;
  } on ProviderCommandException catch (error) {
    _writeCommandError(errorOutput, error, arguments);
    return 1;
  } on Object catch (error) {
    errorOutput('PROVIDER_ERROR: ${_errorText(error)}\n');
    return 1;
  } finally {
    await client?.close();
  }
}

final class ProviderCliInvocation {
  const ProviderCliInvocation({
    required this.action,
    required this.provider,
    required this.host,
    required this.format,
    required this.quiet,
    required this.headers,
    required this.thinking,
  });

  final String action;
  final String? provider;
  final String? host;
  final String format;
  final bool quiet;
  final bool headers;
  final bool thinking;

  static ProviderCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing provider action');
    }
    final action = arguments.first;
    if (action != 'ls' && action != 'models') {
      throw FormatException('Unknown provider action: $action');
    }
    String? provider;
    String? host;
    var format = 'table';
    var quiet = false;
    var headers = true;
    var thinking = false;
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
        case '--thinking' when action == 'models':
          thinking = true;
        default:
          if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          }
          if (provider != null) {
            throw const FormatException('Only one provider may be specified');
          }
          provider = argument;
      }
    }
    if (action == 'ls' && provider != null) {
      throw const FormatException('provider ls does not accept a provider');
    }
    final normalizedProvider = provider?.trim().toLowerCase();
    if (action == 'models' &&
        (normalizedProvider == null || normalizedProvider.isEmpty)) {
      throw const FormatException('Provider is required');
    }
    return ProviderCliInvocation(
      action: action,
      provider: normalizedProvider,
      host: host,
      format: format,
      quiet: quiet,
      headers: headers,
      thinking: thinking,
    );
  }
}

Future<List<Map<String, Object?>>> _listProviders(
  ProviderCliInvocation invocation,
  ProviderRpcRequester? request,
) async {
  if (request != null) {
    try {
      final response = await request(
        GetProvidersSnapshotRequest(
          requestId: _requestId('provider_ls'),
        ).toJson(),
      );
      final entries = _mapList(
        response,
        'entries',
        ProviderSnapshotEntry.fromJson,
      );
      return [
        for (final entry in entries)
          {
            'provider': entry.provider,
            'label': entry.label ?? entry.provider,
            'status': entry.status == ProviderCatalogStatus.ready
                ? 'available'
                : entry.status.name,
            'enabled': entry.enabled ? 'Enabled' : 'Disabled',
            'defaultMode': entry.defaultModeId ?? 'default',
            'modes': (entry.modes ?? const <ProviderMode>[])
                .map((mode) => mode.label)
                .join(', '),
          },
      ];
    } catch (_) {
      // Paseo intentionally falls back to its static provider manifest when
      // the daemon or snapshot request is unavailable.
    }
  }
  return [
    for (final definition in PaseoProviderManifest.definitions)
      {
        'provider': definition.id,
        'label': definition.label,
        'status': 'available',
        'enabled': definition.enabledByDefault ? 'Enabled' : 'Disabled',
        'defaultMode': definition.defaultModeId ?? '-',
        'modes': definition.modes.isEmpty
            ? '-'
            : definition.modes.map((mode) => mode.mode.label).join(', '),
      },
  ];
}

Future<List<Map<String, Object?>>> _listModels(
  ProviderCliInvocation invocation,
  ProviderRpcRequester request,
) async {
  final provider = invocation.provider!;
  final response = await request(
    ListProviderModelsRequest(
      provider: provider,
      requestId: _requestId('provider_models'),
    ).toJson(),
  );
  final error = response['error'];
  if (error is String && error.isNotEmpty) {
    throw ProviderCommandException(
      'PROVIDER_ERROR',
      'Failed to fetch models for $provider: $error',
    );
  }
  final List<ProviderModelDefinition> models;
  try {
    models = response['models'] == null
        ? const <ProviderModelDefinition>[]
        : _mapList(response, 'models', ProviderModelDefinition.fromJson);
  } on FormatException catch (error) {
    throw ProviderCommandException('PROVIDER_ERROR', error.message);
  }
  return [
    for (final model in models)
      {
        'id': model.id,
        'model': model.label,
        'description': model.description ?? '',
        'thinkingOptionIds': [
          for (final option
              in model.thinkingOptions ?? const <ProviderSelectOption>[])
            option.id,
        ],
        'defaultThinkingOptionId': model.defaultThinkingOptionId,
        'thinkingOptions':
            (model.thinkingOptions ?? const <ProviderSelectOption>[])
                .map((option) => option.id)
                .join(', ')
                .isEmpty
            ? 'none'
            : (model.thinkingOptions ?? const <ProviderSelectOption>[])
                  .map((option) => option.id)
                  .join(', '),
      },
  ];
}

String _renderRows(
  List<Map<String, Object?>> rows,
  ProviderCliInvocation invocation,
) {
  final idField = invocation.action == 'ls' ? 'provider' : 'id';
  if (invocation.quiet) {
    return rows.map((row) => '${row[idField]}').join('\n') +
        (rows.isEmpty ? '' : '\n');
  }
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(rows)}\n';
  }
  if (invocation.format == 'yaml') return _yamlList(rows);
  final columns = invocation.action == 'ls'
      ? const [
          ('PROVIDER', 'provider', 12),
          ('LABEL', 'label', 16),
          ('STATUS', 'status', 12),
          ('ENABLED', 'enabled', 10),
          ('DEFAULT MODE', 'defaultMode', 14),
          ('MODES', 'modes', 30),
        ]
      : invocation.thinking
      ? const [
          ('ID', 'id', 30),
          ('MODEL', 'model', 30),
          ('THINKING IDS', 'thinkingOptions', 40),
          ('DEFAULT THINKING', 'defaultThinkingOptionId', 18),
        ]
      : const [
          ('ID', 'id', 30),
          ('MODEL', 'model', 30),
          ('DESCRIPTION', 'description', 40),
        ];
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in rows) _cell(row, column.$2, invocation).length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String render(List<String> values) => [
    for (var index = 0; index < values.length; index++)
      values[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return [
        if (invocation.headers)
          render([for (final column in columns) column.$1]),
        for (final item in rows)
          render([
            for (final column in columns) _cell(item, column.$2, invocation),
          ]),
      ].join('\n') +
      (invocation.headers || rows.isNotEmpty ? '\n' : '');
}

String _cell(
  Map<String, Object?> row,
  String field,
  ProviderCliInvocation invocation,
) {
  final value = row[field];
  if (field == 'defaultThinkingOptionId' && value == null) return 'auto';
  return value == null ? '' : '$value';
}

String _yamlList(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  if (value is List) {
    return '[${value.map(_yamlScalar).join(', ')}]';
  }
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

List<T> _mapList<T>(
  Map<String, Object?> json,
  String field,
  T Function(Map<String, Object?> value) decode,
) {
  final value = json[field];
  if (value is! List) throw FormatException('$field must be a list');
  return [
    for (final entry in value)
      if (entry is Map)
        decode(entry.cast<String, Object?>())
      else
        throw FormatException('$field entries must be objects'),
  ];
}

void _writeCommandError(
  void Function(String value) write,
  ProviderCommandException error,
  List<String> arguments,
) {
  final json = arguments.contains('--json');
  if (json) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
      })}\n',
    );
    return;
  }
  write('Error: ${error.message}\n');
  if (error.details != null) write('${error.details}\n');
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class ProviderCommandException implements Exception {
  const ProviderCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const providerUsage =
    'Usage: coding-agent provider ls [--host <host>] [--json]\n'
    '       coding-agent provider models <provider> [--thinking] '
    '[--host <host>] [--json]';

String _providerHelp(String? action) => switch (action) {
  'ls' =>
    'Usage: coding-agent provider ls [options]\n'
        'List available providers and status\n',
  'models' =>
    'Usage: coding-agent provider models [options] <provider>\n'
        'List models for a provider\n',
  _ =>
    'Usage: coding-agent provider [command]\n'
        'Manage agent providers\n\n'
        'Commands:\n'
        '  ls                 List available providers and status\n'
        '  models <provider>  List models for a provider\n',
};
