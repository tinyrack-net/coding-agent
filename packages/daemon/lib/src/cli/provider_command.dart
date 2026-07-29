import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../providers/paseo/provider_manifest.dart';
import '../server/daemon_config.dart';
import 'cli_output.dart';
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
  ProviderCliInvocation? invocation;
  try {
    invocation = ProviderCliInvocation.parse(arguments);
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
    final schema = invocation.action == 'ls'
        ? _providerListSchema
        : invocation.thinking
        ? _providerModelsThinkingSchema
        : _providerModelsSchema;
    final rendered = renderCliOutput(
      CliOutputResult.list(rows: rows, schema: schema),
      invocation.output,
    );
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$providerUsage\n');
    return 64;
  } on ProviderCommandException catch (error) {
    _writeCommandError(
      errorOutput,
      error,
      options: invocation?.output ?? const CliOutputOptions(),
    );
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      ProviderCommandException('PROVIDER_ERROR', _errorText(error)),
      options: invocation?.output ?? const CliOutputOptions(),
    );
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
    required this.output,
    required this.thinking,
  });

  final String action;
  final String? provider;
  final String? host;
  final CliOutputOptions output;
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
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    var thinking = false;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (_splitLongOption(argument) case (final option, final value)) {
        switch (option) {
          case '--host':
            host = value;
            continue;
          case '--format':
            format = normalizeCliOutputFormat(value);
            continue;
        }
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
        case '--thinking' when action == 'models':
          thinking = true;
        default:
          if (argument.startsWith('-o') && argument.length > 2) {
            format = normalizeCliOutputFormat(argument.substring(2));
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            if (provider != null) {
              throw const FormatException('Only one provider may be specified');
            }
            provider = argument;
          }
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
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
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

final _providerListSchema = CliOutputSchema(
  idField: (row) => '${row['provider']}',
  columns: [
    CliOutputColumn(
      header: 'PROVIDER',
      field: (row) => row['provider'],
      width: 12,
    ),
    CliOutputColumn(header: 'LABEL', field: (row) => row['label'], width: 16),
    CliOutputColumn(
      header: 'STATUS',
      field: (row) => row['status'],
      width: 12,
      color: (value, _) => switch (value) {
        'available' => 'green',
        'unavailable' => 'red',
        _ => null,
      },
    ),
    CliOutputColumn(
      header: 'ENABLED',
      field: (row) => row['enabled'],
      width: 10,
    ),
    CliOutputColumn(
      header: 'DEFAULT MODE',
      field: (row) => row['defaultMode'],
      width: 14,
    ),
    CliOutputColumn(header: 'MODES', field: (row) => row['modes'], width: 30),
  ],
);

final _providerModelsSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'ID', field: (row) => row['id'], width: 30),
    CliOutputColumn(header: 'MODEL', field: (row) => row['model'], width: 30),
    CliOutputColumn(
      header: 'DESCRIPTION',
      field: (row) => row['description'],
      width: 40,
    ),
  ],
);

final _providerModelsThinkingSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'ID', field: (row) => row['id'], width: 30),
    CliOutputColumn(header: 'MODEL', field: (row) => row['model'], width: 30),
    CliOutputColumn(
      header: 'THINKING IDS',
      field: (row) => row['thinkingOptions'],
      width: 40,
    ),
    CliOutputColumn(
      header: 'DEFAULT THINKING',
      field: (row) => row['defaultThinkingOptionId'] ?? 'auto',
      width: 18,
    ),
  ],
);

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
  ProviderCommandException error, {
  required CliOutputOptions options,
}) {
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
