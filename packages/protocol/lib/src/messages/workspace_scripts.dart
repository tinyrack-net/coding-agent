import 'workspace_v2.dart';

sealed class WorkspaceScriptRequest {
  const WorkspaceScriptRequest({
    required this.workspaceId,
    required this.requestId,
  });

  final String workspaceId;
  final String requestId;
  String get type;

  Map<String, Object?> toJson();

  static WorkspaceScriptRequest fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'start_workspace_script_request' => StartWorkspaceScriptRequest(
          workspaceId: _string(json, 'workspaceId'),
          scriptName: _string(json, 'scriptName'),
          requestId: _string(json, 'requestId'),
        ),
        'workspace.script.list.request' => WorkspaceScriptListRequest(
          workspaceId: _string(json, 'workspaceId'),
          requestId: _string(json, 'requestId'),
        ),
        'workspace.script.start.request' => WorkspaceScriptStartRequest(
          workspaceId: _string(json, 'workspaceId'),
          scriptName: _string(json, 'scriptName'),
          requestId: _string(json, 'requestId'),
        ),
        'workspace.script.stop.request' => WorkspaceScriptStopRequest(
          workspaceId: _string(json, 'workspaceId'),
          scriptName: _string(json, 'scriptName'),
          requestId: _string(json, 'requestId'),
        ),
        _ => throw FormatException(
          'Unknown workspace script request: ${json['type']}',
        ),
      };
}

final class StartWorkspaceScriptRequest extends WorkspaceScriptRequest {
  const StartWorkspaceScriptRequest({
    required super.workspaceId,
    required this.scriptName,
    required super.requestId,
  });

  final String scriptName;
  @override
  String get type => 'start_workspace_script_request';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'workspaceId': workspaceId,
    'scriptName': scriptName,
    'requestId': requestId,
  };
}

final class WorkspaceScriptListRequest extends WorkspaceScriptRequest {
  const WorkspaceScriptListRequest({
    required super.workspaceId,
    required super.requestId,
  });

  @override
  String get type => 'workspace.script.list.request';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

final class WorkspaceScriptStartRequest extends WorkspaceScriptRequest {
  const WorkspaceScriptStartRequest({
    required super.workspaceId,
    required this.scriptName,
    required super.requestId,
  });

  final String scriptName;
  @override
  String get type => 'workspace.script.start.request';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'workspaceId': workspaceId,
    'scriptName': scriptName,
    'requestId': requestId,
  };
}

final class WorkspaceScriptStopRequest extends WorkspaceScriptRequest {
  const WorkspaceScriptStopRequest({
    required super.workspaceId,
    required this.scriptName,
    required super.requestId,
  });

  final String scriptName;
  @override
  String get type => 'workspace.script.stop.request';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'workspaceId': workspaceId,
    'scriptName': scriptName,
    'requestId': requestId,
  };
}

final class StartWorkspaceScriptResponse {
  const StartWorkspaceScriptResponse({
    required this.requestId,
    required this.workspaceId,
    required this.scriptName,
    required this.terminalId,
    required this.error,
  });

  final String requestId;
  final String workspaceId;
  final String scriptName;
  final String? terminalId;
  final String? error;

  factory StartWorkspaceScriptResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'start_workspace_script_response');
    final payload = _map(json, 'payload');
    return StartWorkspaceScriptResponse(
      requestId: _string(payload, 'requestId'),
      workspaceId: _string(payload, 'workspaceId'),
      scriptName: _string(payload, 'scriptName'),
      terminalId: _nullableString(payload, 'terminalId'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'start_workspace_script_response',
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'scriptName': scriptName,
      'terminalId': terminalId,
      'error': error,
    },
  };
}

final class WorkspaceScriptOperationResponse {
  const WorkspaceScriptOperationResponse({
    required this.type,
    required this.requestId,
    required this.workspaceId,
    required this.error,
    this.scriptName,
    this.script,
    this.scripts,
  });

  final String type;
  final String requestId;
  final String workspaceId;
  final String? scriptName;
  final WorkspaceScript? script;
  final List<WorkspaceScript>? scripts;
  final String? error;

  factory WorkspaceScriptOperationResponse.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type != 'workspace.script.list.response' &&
        type != 'workspace.script.start.response' &&
        type != 'workspace.script.stop.response') {
      throw FormatException('Unknown workspace script response: $type');
    }
    final payload = _map(json, 'payload');
    final rawScripts = payload['scripts'];
    if (rawScripts != null && rawScripts is! List) {
      throw const FormatException('Invalid workspace scripts');
    }
    return WorkspaceScriptOperationResponse(
      type: type! as String,
      requestId: _string(payload, 'requestId'),
      workspaceId: _string(payload, 'workspaceId'),
      scriptName: _nullableString(payload, 'scriptName'),
      script: payload['script'] == null
          ? null
          : WorkspaceScript.fromJson(_map(payload, 'script')),
      scripts: rawScripts == null
          ? null
          : [
              for (final value in rawScripts as List)
                WorkspaceScript.fromJson(_objectMap(value)),
            ],
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      if (scriptName != null) 'scriptName': scriptName,
      if (script != null) 'script': script!.toJson(),
      if (scripts != null)
        'scripts': scripts!.map((value) => value.toJson()).toList(),
      'error': error,
    },
  };
}

final class WorkspaceScriptStatusUpdate {
  const WorkspaceScriptStatusUpdate({
    required this.workspaceId,
    required this.scripts,
  });

  final String workspaceId;
  final List<WorkspaceScript> scripts;

  factory WorkspaceScriptStatusUpdate.fromJson(Map<String, Object?> json) {
    _expectType(json, 'script_status_update');
    final payload = _map(json, 'payload');
    final scripts = payload['scripts'];
    if (scripts is! List) {
      throw const FormatException('Invalid workspace script status');
    }
    return WorkspaceScriptStatusUpdate(
      workspaceId: _string(payload, 'workspaceId'),
      scripts: [
        for (final value in scripts)
          WorkspaceScript.fromJson(_objectMap(value)),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'script_status_update',
    'payload': {
      'workspaceId': workspaceId,
      'scripts': scripts.map((value) => value.toJson()).toList(),
    },
  };
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Expected string $key');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('Expected nullable string $key');
  }
  return value as String?;
}

Map<String, Object?> _map(Map<String, Object?> json, String key) =>
    _objectMap(json[key]);

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected object');
  return value.cast<String, Object?>();
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}
