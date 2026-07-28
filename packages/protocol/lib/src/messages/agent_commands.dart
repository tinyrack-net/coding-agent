enum AgentSlashCommandKind {
  command,
  skill;

  static AgentSlashCommandKind fromWire(Object? value) => switch (value) {
    null || 'command' => command,
    'skill' => skill,
    _ => command,
  };
}

final class AgentSlashCommand {
  const AgentSlashCommand({
    required this.name,
    required this.description,
    required this.argumentHint,
    this.kind = AgentSlashCommandKind.command,
  });

  final String name;
  final String description;
  final String argumentHint;
  final AgentSlashCommandKind kind;

  factory AgentSlashCommand.fromJson(Map<String, Object?> json) =>
      AgentSlashCommand(
        name: _requiredString(json, 'name'),
        description: _requiredString(json, 'description'),
        argumentHint: _requiredString(json, 'argumentHint'),
        kind: AgentSlashCommandKind.fromWire(json['kind']),
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'argumentHint': argumentHint,
    'kind': kind.name,
  };
}

final class ListCommandsDraftConfig {
  const ListCommandsDraftConfig({
    required this.provider,
    required this.cwd,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.featureValues,
  });

  final String provider;
  final String cwd;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final Map<String, Object?>? featureValues;

  factory ListCommandsDraftConfig.fromJson(Map<String, Object?> json) =>
      ListCommandsDraftConfig(
        provider: _requiredString(json, 'provider'),
        cwd: _requiredString(json, 'cwd'),
        modeId: _optionalString(json, 'modeId'),
        model: _optionalString(json, 'model'),
        thinkingOptionId: _optionalString(json, 'thinkingOptionId'),
        featureValues: _optionalMap(json, 'featureValues'),
      );

  Map<String, Object?> toJson() => {
    'provider': provider,
    'cwd': cwd,
    if (modeId != null) 'modeId': modeId,
    if (model != null) 'model': model,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
    if (featureValues != null) 'featureValues': featureValues,
  };
}

final class ListCommandsRequest {
  const ListCommandsRequest({
    required this.agentId,
    required this.requestId,
    this.draftConfig,
  });

  static const type = 'list_commands_request';

  final String agentId;
  final ListCommandsDraftConfig? draftConfig;
  final String requestId;

  factory ListCommandsRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final draft = json['draftConfig'];
    if (draft != null && draft is! Map) {
      throw const FormatException('draftConfig must be an object');
    }
    return ListCommandsRequest(
      agentId: _requiredString(json, 'agentId'),
      draftConfig: draft == null
          ? null
          : ListCommandsDraftConfig.fromJson(
              Map<String, Object?>.from(draft as Map),
            ),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    if (draftConfig != null) 'draftConfig': draftConfig!.toJson(),
    'requestId': requestId,
  };
}

final class ListCommandsResponse {
  const ListCommandsResponse({
    required this.agentId,
    required this.commands,
    required this.requestId,
    this.error,
  });

  static const type = 'list_commands_response';

  final String agentId;
  final List<AgentSlashCommand> commands;
  final String? error;
  final String requestId;

  factory ListCommandsResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = json['payload'];
    if (payload is! Map)
      throw const FormatException('payload must be an object');
    final body = Map<String, Object?>.from(payload);
    final rawCommands = body['commands'];
    if (rawCommands is! List) {
      throw const FormatException('commands must be an array');
    }
    return ListCommandsResponse(
      agentId: _requiredString(body, 'agentId'),
      commands: List.unmodifiable([
        for (final command in rawCommands)
          if (command is Map)
            AgentSlashCommand.fromJson(Map<String, Object?>.from(command))
          else
            throw const FormatException('commands entries must be objects'),
      ]),
      error: _nullableString(body, 'error'),
      requestId: _requiredString(body, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'agentId': agentId,
      'commands': commands.map((command) => command.toJson()).toList(),
      'error': error,
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('expected type "$expected"');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) =>
    _optionalString(json, key);

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return Map.unmodifiable(Map<String, Object?>.from(value));
}
