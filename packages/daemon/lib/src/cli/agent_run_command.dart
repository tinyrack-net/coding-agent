import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/structured_generation.dart';
import '../server/daemon_config.dart';
import 'agent_output_schemas.dart';
import 'cli_duration.dart';
import 'cli_output.dart';
import 'provider_model.dart';
import 'terminal_command.dart';
import 'workspace_command.dart';

typedef AgentRunRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef AgentRunFileReader = List<int> Function(String path);

Future<int> runAgentRunCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  AgentRunRpcRequester? request,
  AgentRunFileReader? readFile,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(agentRunHelp);
    return 0;
  }
  AgentRunInvocation? invocation;
  try {
    invocation = AgentRunInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    final cwd = currentDirectory ?? Directory.current.path;
    var send = request;
    if (send == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
        send = (message) {
          if (message['type'] != WaitForFinishRequest.type) {
            return client!.request(message);
          }
          final timeoutMs = message['timeoutMs'];
          return client!.request(
            message,
            timeout: timeoutMs is int
                ? Duration(milliseconds: timeoutMs + 5000)
                : null,
          );
        };
      } on Object catch (error) {
        final host = invocation.host ?? '${config.host}:${config.port}';
        throw AgentRunCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          details: 'Start the daemon with: coding-agent daemon start',
        );
      }
    }
    final result = await _execute(
      invocation,
      send,
      env,
      cwd,
      readFile ?? (path) => File(path).readAsBytesSync(),
      errorOutput,
    );
    final rendered = renderCliOutput(
      CliOutputResult.single(
        row: result.row,
        schema: agentRunOutputSchema(
          serialize: result.structuredOutput == null
              ? null
              : (_) => result.structuredOutput,
        ),
      ),
      invocation.effectiveOutput,
    );
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on ProviderModelFormatException catch (error) {
    _writeCommandError(
      errorOutput,
      AgentRunCommandException(
        error.code,
        error.message,
        details: error.details,
      ),
      invocation?.effectiveOutput ?? _recoverRunOutputOptions(arguments),
    );
    return 1;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentRunUsage\n');
    return 64;
  } on AgentRunCommandException catch (error) {
    _writeCommandError(
      errorOutput,
      error,
      invocation?.effectiveOutput ?? _recoverRunOutputOptions(arguments),
    );
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      AgentRunCommandException(
        'AGENT_CREATE_FAILED',
        'Failed to create agent: ${_errorText(error)}',
      ),
      invocation?.effectiveOutput ?? _recoverRunOutputOptions(arguments),
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentRunInvocation {
  const AgentRunInvocation({
    required this.prompt,
    required this.background,
    required this.detach,
    required this.title,
    required this.name,
    required this.provider,
    required this.model,
    required this.thinking,
    required this.mode,
    required this.newWorkspace,
    required this.worktree,
    required this.worktreeMode,
    required this.worktreeSlug,
    required this.newBranch,
    required this.base,
    required this.branch,
    required this.prNumber,
    required this.forge,
    required this.workspace,
    required this.images,
    required this.cwd,
    required this.env,
    required this.labels,
    required this.waitTimeout,
    required this.outputSchema,
    required this.host,
    required this.output,
  });

  final String prompt;
  final bool background;
  final bool detach;
  final String? title;
  final String? name;
  final String? provider;
  final String? model;
  final String? thinking;
  final String? mode;
  final String? newWorkspace;
  final String? worktree;
  final String? worktreeMode;
  final String? worktreeSlug;
  final String? newBranch;
  final String? base;
  final String? branch;
  final String? prNumber;
  final String? forge;
  final String? workspace;
  final List<String> images;
  final String? cwd;
  final List<String> env;
  final List<String> labels;
  final String? waitTimeout;
  final String? outputSchema;
  final String? host;
  final CliOutputOptions output;

  bool get runsInBackground => background || detach;

  CliOutputOptions get effectiveOutput =>
      outputSchema?.trim().isNotEmpty == true
      ? output.copyWith(format: 'json', quiet: false)
      : output;

  String? get newWorkspaceKind =>
      newWorkspace ?? (worktree == null ? null : 'worktree');

  static AgentRunInvocation parse(List<String> arguments) {
    final positionals = <String>[];
    final values = <String, String>{};
    final images = <String>[];
    final env = <String>[];
    final labels = <String>[];
    var background = false;
    var detach = false;
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    var positionalOnly = false;
    String? host;
    const valueOptions = {
      '--title',
      '--name',
      '--provider',
      '--model',
      '--thinking',
      '--mode',
      '--new-workspace',
      '--worktree',
      '--worktree-mode',
      '--worktree-slug',
      '--new-branch',
      '--base',
      '--branch',
      '--pr-number',
      '--forge',
      '--workspace',
      '--cwd',
      '--wait-timeout',
      '--output-schema',
    };
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly) {
        final longOption = _splitLongOption(argument);
        if (longOption != null) {
          final (option, value) = longOption;
          switch (option) {
            case '--image':
              images.add(value);
              continue;
            case '--env':
              env.add(value);
              continue;
            case '--label':
              labels.add(value);
              continue;
            case '--host':
              host = value;
              continue;
            case '--format':
              format = _normalizeRunOutputFormat(value);
              continue;
            default:
              if (valueOptions.contains(option)) {
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
        case '-d' || '--background':
          background = true;
        case '--detach':
          detach = true;
        case '--image':
          images.add(_requiredValue(arguments, ++index, argument));
        case '--env':
          env.add(_requiredValue(arguments, ++index, argument));
        case '--label':
          labels.add(_requiredValue(arguments, ++index, argument));
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
        case '-o' || '--format':
          format = _normalizeRunOutputFormat(
            _requiredValue(arguments, ++index, argument),
          );
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          color = false;
        default:
          if (valueOptions.contains(argument)) {
            values[argument] = _requiredValue(arguments, ++index, argument);
          } else if (argument.startsWith('-o') && argument.length > 2) {
            format = _normalizeRunOutputFormat(argument.substring(2));
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            positionals.add(argument);
          }
      }
    }
    if (positionals.isEmpty ||
        positionals.singleOrNull?.trim().isEmpty == true) {
      throw const AgentRunCommandException(
        'MISSING_PROMPT',
        'A prompt is required',
        details: 'Usage: paseo agent run [options] <prompt>',
      );
    }
    if (positionals.length != 1) {
      throw const FormatException('agent run accepts exactly one prompt');
    }
    return AgentRunInvocation(
      prompt: positionals.single,
      background: background,
      detach: detach,
      title: values['--title'],
      name: values['--name'],
      provider: values['--provider'],
      model: values['--model'],
      thinking: values['--thinking'],
      mode: values['--mode'],
      newWorkspace: values['--new-workspace'],
      worktree: values['--worktree'],
      worktreeMode: values['--worktree-mode'],
      worktreeSlug: values['--worktree-slug'],
      newBranch: values['--new-branch'],
      base: values['--base'],
      branch: values['--branch'],
      prNumber: values['--pr-number'],
      forge: values['--forge'],
      workspace: values['--workspace'],
      images: List.unmodifiable(images),
      cwd: values['--cwd'],
      env: List.unmodifiable(env),
      labels: List.unmodifiable(labels),
      waitTimeout: values['--wait-timeout'],
      outputSchema: values['--output-schema'],
      host: host,
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
    );
  }
}

Future<_AgentRunResult> _execute(
  AgentRunInvocation invocation,
  AgentRunRpcRequester request,
  Map<String, String> environment,
  String currentDirectory,
  AgentRunFileReader readFile,
  void Function(String value) writeError,
) async {
  final outputSchema = invocation.outputSchema == null
      ? null
      : _loadOutputSchema(invocation.outputSchema!, currentDirectory, readFile);
  _validateWorkspaceOptions(invocation, currentDirectory);
  if (outputSchema != null && invocation.runsInBackground) {
    throw const AgentRunCommandException(
      'INVALID_OPTIONS',
      '--output-schema cannot be used with --background',
      details: 'Structured output requires waiting for the agent to finish',
    );
  }
  final waitTimeoutMs = _parseWaitTimeout(invocation.waitTimeout);
  final providerModel = resolveProviderAndModel(
    provider: invocation.provider,
    model: invocation.model,
  );
  final thinking = invocation.thinking?.trim();
  if (invocation.thinking != null && (thinking == null || thinking.isEmpty)) {
    throw const AgentRunCommandException(
      'INVALID_THINKING_OPTION',
      '--thinking cannot be empty',
      details:
          'Provide a thinking option ID. Use "coding-agent provider models '
          '<provider> --thinking" to list valid IDs.',
    );
  }
  final labels = _parseKeyValueFlags(
    invocation.labels,
    flagName: '--label',
    code: 'INVALID_LABEL',
    noun: 'label',
    pluralNoun: 'Labels',
  );
  final runEnv = _parseKeyValueFlags(
    invocation.env,
    flagName: '--env',
    code: 'INVALID_ENV',
    noun: 'environment variable',
    pluralNoun: 'Environment variables',
  );
  final images = _loadImages(invocation.images, currentDirectory, readFile);
  final requestedCwd = invocation.cwd ?? currentDirectory;
  final workspace = await _resolveWorkspace(
    invocation,
    request,
    environment,
    requestedCwd,
    writeError,
  );
  final title = invocation.title ?? invocation.name;
  final callerAgentId = _nonEmpty(environment['PASEO_AGENT_ID']);

  Future<Map<String, Object?>> create(String prompt) async {
    final requestId = _requestId('agent_run_create');
    final payload = await request(
      CreateAgentRequest(
        requestId: requestId,
        config: CreateAgentSessionConfig(
          provider: providerModel.provider,
          cwd: workspace.cwd,
          modeId: invocation.mode,
          model: providerModel.model,
          thinkingOptionId: thinking,
          title: title,
          hasTitle: title != null,
        ),
        env: runEnv.isEmpty ? null : runEnv,
        workspaceId: workspace.id,
        callerAgentId: callerAgentId,
        initialPrompt: prompt,
        outputSchema: outputSchema,
        images: images,
        labels: labels,
      ).toJson(),
    );
    final status = CreateAgentStatus.fromJson({
      'type': 'status',
      'payload': payload,
    });
    if (status is AgentCreateFailedStatus) {
      throw StateError(status.error);
    }
    return (status as AgentCreatedStatus).agent;
  }

  if (outputSchema != null) {
    Map<String, Object?>? structuredAgent;
    try {
      final structured = await getStructuredAgentResponse(
        prompt: invocation.prompt,
        jsonSchema: outputSchema,
        maxRetries: 2,
        caller: (structuredPrompt) async {
          if (structuredAgent == null) {
            structuredAgent = await create(structuredPrompt);
          } else {
            final sent = SendAgentMessageResponse.fromJson({
              'type': SendAgentMessageResponse.type,
              'payload': await request(
                SendAgentMessageRequest(
                  requestId: _requestId('agent_run_retry'),
                  agentId: _requiredString(structuredAgent!, 'id'),
                  text: structuredPrompt,
                ).toJson(),
              ),
            });
            if (!sent.accepted) {
              throw _StructuredRunStatusError(
                sent.error ?? 'Agent failed before producing structured output',
              );
            }
          }
          final wait = await _wait(
            request,
            _requiredString(structuredAgent!, 'id'),
            waitTimeoutMs,
          );
          switch (wait.status) {
            case WaitForFinishStatus.timeout:
              throw const _StructuredRunStatusError(
                'Timed out waiting for structured output',
              );
            case WaitForFinishStatus.permission:
              throw const _StructuredRunStatusError(
                'Agent is waiting for permission before producing structured output',
              );
            case WaitForFinishStatus.error:
              throw _StructuredRunStatusError(
                wait.error ?? 'Agent failed before producing structured output',
              );
            case WaitForFinishStatus.idle:
              final direct = wait.lastMessage?.trim();
              if (direct != null && direct.isNotEmpty) return direct;
              final fallback = await _lastAssistantMessage(
                request,
                _requiredString(structuredAgent!, 'id'),
              );
              if (fallback == null) {
                throw const _StructuredRunStatusError(
                  'Agent finished without a structured output message',
                );
              }
              return fallback;
          }
        },
      );
      return _AgentRunResult(
        row: _runRow(structuredAgent!, 'completed'),
        structuredOutput: structured,
      );
    } on _StructuredRunStatusError catch (error) {
      throw AgentRunCommandException('OUTPUT_SCHEMA_FAILED', error.message);
    } on StructuredAgentResponseError catch (error) {
      throw AgentRunCommandException(
        'OUTPUT_SCHEMA_FAILED',
        'Agent response did not match the required output schema',
        details: error.validationErrors.isNotEmpty
            ? error.validationErrors.join('\n')
            : (error.lastResponse.isEmpty ? 'No response' : error.lastResponse),
      );
    }
  }

  try {
    final agent = await create(invocation.prompt);
    if (invocation.runsInBackground) {
      return _AgentRunResult(row: _runRow(agent));
    }
    final wait = await _wait(
      request,
      _requiredString(agent, 'id'),
      waitTimeoutMs,
    );
    final finalAgent = wait.finalAgent ?? agent;
    return _AgentRunResult(
      row: _runRow(
        finalAgent,
        wait.status == WaitForFinishStatus.idle
            ? 'completed'
            : wait.status.name,
      ),
    );
  } on AgentRunCommandException {
    rethrow;
  } on Object catch (error) {
    throw AgentRunCommandException(
      'AGENT_CREATE_FAILED',
      'Failed to create agent: ${_errorText(error)}',
    );
  }
}

Future<WaitForFinishResponse> _wait(
  AgentRunRpcRequester request,
  String agentId,
  int waitTimeoutMs,
) async {
  final payload = await request(
    WaitForFinishRequest(
      requestId: _requestId('agent_run_wait'),
      agentId: agentId,
      timeoutMs: waitTimeoutMs == 0 ? null : waitTimeoutMs,
    ).toJson(),
  );
  return WaitForFinishResponse.fromJson({
    'type': WaitForFinishResponse.type,
    'payload': payload,
  });
}

Future<String?> _lastAssistantMessage(
  AgentRunRpcRequester request,
  String agentId,
) async {
  try {
    final payload = await request(
      FetchAgentTimelineRequest(
        agentId: agentId,
        requestId: _requestId('agent_run_timeline'),
        direction: AgentTimelineDirection.tail,
        limit: 200,
        projection: AgentTimelineProjection.projected,
      ).toJson(),
    );
    final page = AgentTimelinePage.fromResponseJson({
      'type': AgentTimelinePage.responseType,
      'payload': payload,
    });
    for (final entry in page.entries.reversed) {
      final item = entry.item;
      if (item is AssistantMessageItem && item.text.trim().isNotEmpty) {
        return item.text.trim();
      }
    }
  } on Object {
    // The frozen command turns timeline fallback failures into an empty result.
  }
  return null;
}

Future<_RunWorkspace> _resolveWorkspace(
  AgentRunInvocation invocation,
  AgentRunRpcRequester request,
  Map<String, String> environment,
  String cwd,
  void Function(String value) writeError,
) async {
  final newWorkspace = invocation.newWorkspaceKind;
  final explicit = newWorkspace == null
      ? _nonEmpty(invocation.workspace)
      : null;
  if (explicit != null) {
    writeError('Using workspace $explicit\n');
    return _findWorkspace(request, explicit);
  }
  if (newWorkspace == null &&
      _nonEmpty(environment['PASEO_AGENT_ID']) != null) {
    return _RunWorkspace(cwd: cwd);
  }
  final ambient = newWorkspace == null
      ? _nonEmpty(environment['PASEO_WORKSPACE_ID'])
      : null;
  if (ambient != null) {
    writeError('Using workspace $ambient\n');
    return _findWorkspace(request, ambient);
  }
  final source = _buildWorkspaceSource(invocation, cwd);
  final requestId = _requestId('agent_run_workspace');
  final response = WorkspaceCreateResponse.fromJson({
    'type': 'workspace.create.response',
    'payload': await request(
      WorkspaceCreateRequest(
        requestId: requestId,
        source: WorkspaceCreateSource.fromJson(source),
      ).toJson(),
    ),
  });
  final workspace = response.workspace;
  if (workspace == null) {
    throw AgentRunCommandException(
      'WORKSPACE_CREATE_FAILED',
      response.error ?? 'Failed to create workspace for this run',
    );
  }
  final branch = workspace.gitRuntime?.currentBranch;
  final label = branch == null ? workspace.name : '${workspace.name} ($branch)';
  writeError('Created workspace ${workspace.id} - $label\n');
  writeError(
    'Tip: pass --workspace <id> (or set PASEO_WORKSPACE_ID) '
    'to run in an existing workspace.\n',
  );
  return _RunWorkspace(id: workspace.id, cwd: workspace.workspaceDirectory);
}

Future<_RunWorkspace> _findWorkspace(
  AgentRunRpcRequester request,
  String id,
) async {
  final requestId = _requestId('agent_run_workspace_find');
  final response = FetchWorkspacesResponse.fromJson({
    'type': 'fetch_workspaces_response',
    'payload': await request(
      FetchWorkspacesRequest(
        requestId: requestId,
        query: id,
        limit: 200,
      ).toJson(),
    ),
  });
  final workspace = response.entries
      .where((entry) => entry.id == id)
      .firstOrNull;
  if (workspace == null) {
    throw AgentRunCommandException(
      'WORKSPACE_NOT_FOUND',
      'Workspace not found: $id',
    );
  }
  return _RunWorkspace(id: workspace.id, cwd: workspace.workspaceDirectory);
}

void _validateWorkspaceOptions(
  AgentRunInvocation invocation,
  String currentDirectory,
) {
  final kind = invocation.newWorkspaceKind;
  if (invocation.newWorkspace != null &&
      !const {'local', 'worktree'}.contains(invocation.newWorkspace)) {
    throw AgentRunCommandException(
      'INVALID_OPTIONS',
      'Unsupported new workspace kind: ${invocation.newWorkspace}',
      details: 'Use --new-workspace local or --new-workspace worktree',
    );
  }
  if (invocation.newWorkspace != null && invocation.worktree != null) {
    throw const AgentRunCommandException(
      'INVALID_OPTIONS',
      '--new-workspace and --worktree cannot be combined',
      details:
          'Use --new-workspace worktree and the supported worktree options',
    );
  }
  final hasWorktreeOptions = [
    invocation.worktreeMode,
    invocation.worktreeSlug,
    invocation.newBranch,
    invocation.base,
    invocation.branch,
    invocation.prNumber,
    invocation.forge,
  ].any((value) => value != null);
  if (hasWorktreeOptions && kind != 'worktree') {
    throw const AgentRunCommandException(
      'INVALID_OPTIONS',
      'Worktree options require --new-workspace worktree',
      details:
          'Usage: paseo run --new-workspace worktree '
          '[worktree options] <prompt>',
    );
  }
  if (kind == 'worktree') {
    try {
      _buildWorkspaceSource(invocation, invocation.cwd ?? currentDirectory);
    } on Object catch (error) {
      throw AgentRunCommandException('INVALID_OPTIONS', _errorText(error));
    }
  }
  if (invocation.newWorkspace != null && invocation.workspace != null) {
    throw const AgentRunCommandException(
      'INVALID_OPTIONS',
      '--new-workspace and --workspace cannot be combined',
      details: 'Select an existing workspace or explicitly create a new one',
    );
  }
  if (invocation.worktree != null && invocation.workspace != null) {
    throw const AgentRunCommandException(
      'INVALID_OPTIONS',
      '--worktree and --workspace cannot be combined',
      details:
          'Use --new-workspace worktree instead of the legacy --worktree flag',
    );
  }
}

Map<String, Object?> _buildWorkspaceSource(
  AgentRunInvocation invocation,
  String cwd,
) {
  final values = <String, String>{
    '--isolation': invocation.newWorkspaceKind ?? 'local',
    '--path': cwd,
    if (invocation.worktreeMode != null) '--mode': invocation.worktreeMode!,
    if (invocation.worktreeSlug ?? invocation.worktree case final slug?)
      '--worktree-slug': slug,
    if (invocation.newBranch != null) '--new-branch': invocation.newBranch!,
    if (invocation.base != null) '--base': invocation.base!,
    if (invocation.branch != null) '--branch': invocation.branch!,
    if (invocation.prNumber != null) '--pr-number': invocation.prNumber!,
    if (invocation.forge != null) '--forge': invocation.forge!,
  };
  return buildWorkspaceCreateSource(
    WorkspaceCliInvocation(
      action: 'create',
      positionals: const [],
      values: values,
      output: const CliOutputOptions(),
      host: invocation.host,
    ),
    cwd,
  );
}

Map<String, Object?> _loadOutputSchema(
  String value,
  String currentDirectory,
  AgentRunFileReader readFile,
) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw const AgentRunCommandException(
      'INVALID_OUTPUT_SCHEMA',
      '--output-schema cannot be empty',
      details: 'Provide a JSON schema file path or inline JSON object',
    );
  }
  String source = trimmed;
  if (!trimmed.startsWith('{')) {
    final path = p.normalize(p.absolute(currentDirectory, trimmed));
    try {
      source = utf8.decode(readFile(path));
    } on Object catch (error) {
      throw AgentRunCommandException(
        'INVALID_OUTPUT_SCHEMA',
        'Failed to read output schema file: $trimmed',
        details: _errorText(error),
      );
    }
  }
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on Object catch (error) {
    throw AgentRunCommandException(
      'INVALID_OUTPUT_SCHEMA',
      'Failed to parse output schema JSON',
      details: _errorText(error),
    );
  }
  if (decoded is! Map) {
    throw const AgentRunCommandException(
      'INVALID_OUTPUT_SCHEMA',
      'Output schema must be a JSON object',
    );
  }
  return Map<String, Object?>.from(decoded);
}

List<AgentPromptImage> _loadImages(
  List<String> paths,
  String currentDirectory,
  AgentRunFileReader readFile,
) => [for (final path in paths) _loadImage(path, currentDirectory, readFile)];

AgentPromptImage _loadImage(
  String path,
  String currentDirectory,
  AgentRunFileReader readFile,
) {
  final absolute = p.normalize(p.absolute(currentDirectory, path));
  try {
    final data = readFile(absolute);
    final mimeType = switch (p.extension(absolute).toLowerCase()) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' || '.jpe' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.bmp' => 'image/bmp',
      '.tif' || '.tiff' => 'image/tiff',
      '.svg' => 'image/svg+xml',
      '.avif' => 'image/avif',
      '.heic' || '.heif' => 'image/heic',
      _ => 'application/octet-stream',
    };
    if (!mimeType.startsWith('image/')) {
      throw StateError(
        'File is not an image: $path (detected type: $mimeType)',
      );
    }
    return AgentPromptImage(data: base64Encode(data), mimeType: mimeType);
  } on Object catch (error) {
    throw StateError('Failed to read image $path: ${_errorText(error)}');
  }
}

Map<String, String> _parseKeyValueFlags(
  List<String> flags, {
  required String flagName,
  required String code,
  required String noun,
  required String pluralNoun,
}) {
  final values = <String, String>{};
  for (final flag in flags) {
    final separator = flag.indexOf('=');
    if (separator == -1) {
      throw AgentRunCommandException(
        code,
        'Invalid $noun format: $flag',
        details: '$pluralNoun must be in key=value format',
      );
    }
    values[flag.substring(0, separator)] = flag.substring(separator + 1);
  }
  return values;
}

int _parseWaitTimeout(String? raw) {
  if (raw == null || raw.isEmpty) return 0;
  try {
    final milliseconds = parseCliDurationMilliseconds(raw);
    if (milliseconds <= 0) throw StateError('Timeout must be positive');
    return milliseconds;
  } on Object catch (error) {
    throw AgentRunCommandException(
      'INVALID_TIMEOUT',
      'Invalid wait timeout value',
      details: _errorText(error),
    );
  }
}

Map<String, Object?> _runRow(
  Map<String, Object?> agent, [
  String? statusOverride,
]) => {
  'agentId': _requiredString(agent, 'id'),
  'status':
      statusOverride ?? (agent['status'] == 'running' ? 'running' : 'created'),
  'provider': _requiredString(agent, 'provider'),
  'cwd': _requiredString(agent, 'cwd'),
  'title': agent['title'] as String?,
};

void _writeCommandError(
  void Function(String value) write,
  AgentRunCommandException error,
  CliOutputOptions options,
) {
  write(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
}

String _normalizeRunOutputFormat(String raw) {
  try {
    return normalizeCliOutputFormat(raw);
  } on FormatException {
    throw AgentRunCommandException(
      'INVALID_FORMAT',
      'Unsupported output format: $raw',
      details: 'Supported formats: table, json, yaml',
    );
  }
}

CliOutputOptions _recoverRunOutputOptions(List<String> arguments) {
  var format = 'table';
  var json = false;
  var quiet = false;
  var noHeaders = false;
  var noColor = false;
  var structured = false;
  for (var index = 0; index < arguments.length; index++) {
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
        format = _safeRunOutputFormat(arguments[++index], format);
      }
    } else if (argument.startsWith('--format=')) {
      format = _safeRunOutputFormat(
        argument.substring('--format='.length),
        format,
      );
    } else if (argument.startsWith('-o') && argument.length > 2) {
      format = _safeRunOutputFormat(argument.substring(2), format);
    } else if (argument == '--output-schema') {
      if (index + 1 < arguments.length) {
        structured = arguments[++index].trim().isNotEmpty;
      }
    } else if (argument.startsWith('--output-schema=')) {
      structured = argument
          .substring('--output-schema='.length)
          .trim()
          .isNotEmpty;
    }
  }
  return CliOutputOptions(
    format: structured || json ? 'json' : format,
    quiet: structured ? false : quiet,
    noHeaders: noHeaders,
    noColor: noColor,
  );
}

String _safeRunOutputFormat(String raw, String fallback) {
  try {
    return normalizeCliOutputFormat(raw);
  } on FormatException {
    return fallback;
  }
}

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _requiredString(Map<String, Object?> value, String key) {
  final item = value[key];
  if (item is! String || item.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return item;
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

final class _RunWorkspace {
  const _RunWorkspace({this.id, required this.cwd});
  final String? id;
  final String cwd;
}

final class _AgentRunResult {
  const _AgentRunResult({required this.row, this.structuredOutput});
  final Map<String, Object?> row;
  final Map<String, Object?>? structuredOutput;
}

final class _StructuredRunStatusError implements Exception {
  const _StructuredRunStatusError(this.message);
  final String message;
}

final class AgentRunCommandException implements Exception {
  const AgentRunCommandException(this.code, this.message, {this.details});
  final String code;
  final String message;
  final String? details;
}

const agentRunUsage =
    'Usage: coding-agent run [options] <prompt>\n'
    '       coding-agent agent run [options] <prompt>';

const agentRunHelp =
    'Usage: coding-agent run [options] <prompt>\n'
    '       coding-agent agent run [options] <prompt>\n'
    'Create and start an agent with a task\n\n'
    'Options:\n'
    '  -d, --background                 Run in background\n'
    '  --title <title>                  Assign a title to the agent\n'
    '  --provider <provider>            Agent provider or provider/model\n'
    '  --model <model>                  Model to use\n'
    '  --thinking <id>                  Thinking option ID\n'
    '  --mode <mode>                    Provider-specific mode\n'
    '  --new-workspace <local|worktree> Create a separate workspace\n'
    '  --workspace <id>                 Run in an existing workspace\n'
    '  --image <path>                   Attach an image (repeatable)\n'
    '  --cwd <path>                     Working directory\n'
    '  --env <key=value>                Set environment (repeatable)\n'
    '  --label <key=value>              Add a label (repeatable)\n'
    '  --wait-timeout <duration>        Maximum foreground wait\n'
    '  --output-schema <schema>         Require JSON matching a schema\n';
