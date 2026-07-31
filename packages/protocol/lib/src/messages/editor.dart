/// Legacy desktop editor bridge messages retained for Paseo 0.2.0 clients.
library;

final class AvailableEditor {
  const AvailableEditor({required this.id, required this.label});

  final String id;
  final String label;

  factory AvailableEditor.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('editor.id must be a non-empty string');
    }
    final label = json['label'];
    if (label is! String) {
      throw const FormatException('editor.label must be a string');
    }
    return AvailableEditor(id: id, label: label);
  }

  Map<String, Object?> toJson() => {'id': id, 'label': label};
}

final class ListAvailableEditorsRequest {
  const ListAvailableEditorsRequest({required this.requestId});

  static const type = 'list_available_editors_request';
  final String requestId;

  factory ListAvailableEditorsRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ListAvailableEditorsRequest(
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class ListAvailableEditorsResponse {
  const ListAvailableEditorsResponse({
    required this.requestId,
    required this.editors,
    required this.error,
  });

  static const type = 'list_available_editors_response';
  final String requestId;
  final List<AvailableEditor> editors;
  final String? error;

  factory ListAvailableEditorsResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _payload(json);
    final rawEditors = payload['editors'];
    if (rawEditors is! List) {
      throw const FormatException('payload.editors must be an array');
    }
    return ListAvailableEditorsResponse(
      requestId: _requiredString(payload, 'requestId'),
      editors: List.unmodifiable(
        rawEditors.map((value) {
          if (value is! Map) {
            throw const FormatException(
              'payload.editors entries must be objects',
            );
          }
          return AvailableEditor.fromJson(Map<String, Object?>.from(value));
        }),
      ),
      error: _optionalString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'editors': editors
          .map((editor) => editor.toJson())
          .toList(growable: false),
      'error': error,
    },
  };
}

enum EditorOpenMode {
  open,
  reveal;

  static EditorOpenMode fromWire(Object? value) => switch (value) {
    'open' => open,
    'reveal' => reveal,
    _ => throw FormatException('Unknown editor open mode: $value'),
  };
}

final class OpenInEditorRequest {
  const OpenInEditorRequest({
    required this.path,
    required this.editorId,
    required this.requestId,
    this.mode,
    this.cwd,
  });

  static const type = 'open_in_editor_request';
  final String path;
  final String editorId;
  final EditorOpenMode? mode;
  final String? cwd;
  final String requestId;

  factory OpenInEditorRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final editorId = _requiredString(json, 'editorId');
    if (editorId.trim().isEmpty) {
      throw const FormatException('editorId must not be empty');
    }
    return OpenInEditorRequest(
      path: _requiredString(json, 'path'),
      editorId: editorId,
      mode: json['mode'] == null ? null : EditorOpenMode.fromWire(json['mode']),
      cwd: _optionalString(json, 'cwd'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'path': path,
    'editorId': editorId,
    if (mode != null) 'mode': mode!.name,
    if (cwd != null) 'cwd': cwd,
    'requestId': requestId,
  };
}

final class OpenInEditorResponse {
  const OpenInEditorResponse({required this.requestId, required this.error});

  static const type = 'open_in_editor_response';
  final String requestId;
  final String? error;

  factory OpenInEditorResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _payload(json);
    return OpenInEditorResponse(
      requestId: _requiredString(payload, 'requestId'),
      error: _optionalString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'requestId': requestId, 'error': error},
  };
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) throw FormatException('Expected $expected');
}

Map<String, Object?> _payload(Map<String, Object?> json) {
  final raw = json['payload'];
  if (raw is Map) return Map<String, Object?>.from(raw);
  throw const FormatException('payload must be an object');
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}
