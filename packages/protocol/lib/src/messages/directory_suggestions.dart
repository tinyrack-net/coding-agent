enum DirectorySuggestionKind {
  file,
  directory;

  static DirectorySuggestionKind fromWire(Object? value) => switch (value) {
    'file' => file,
    'directory' => directory,
    _ => throw const FormatException('Invalid directory suggestion kind'),
  };
}

enum DirectorySuggestionMatchMode {
  fuzzy,
  suffix;

  static DirectorySuggestionMatchMode fromWire(Object? value) =>
      switch (value) {
        'fuzzy' => fuzzy,
        'suffix' => suffix,
        _ => throw const FormatException(
          'Invalid directory suggestion match mode',
        ),
      };
}

final class DirectorySuggestionEntry {
  const DirectorySuggestionEntry({required this.path, required this.kind});

  final String path;
  final DirectorySuggestionKind kind;

  factory DirectorySuggestionEntry.fromJson(Map<String, Object?> json) =>
      DirectorySuggestionEntry(
        path: _requiredString(json, 'path'),
        kind: DirectorySuggestionKind.fromWire(json['kind']),
      );

  Map<String, Object?> toJson() => {'path': path, 'kind': kind.name};
}

final class DirectorySuggestionsRequest {
  const DirectorySuggestionsRequest({
    required this.query,
    required this.requestId,
    this.cwd,
    this.includeFiles,
    this.includeDirectories,
    this.matchMode,
    this.limit,
  });

  static const type = 'directory_suggestions_request';

  final String query;
  final String? cwd;
  final bool? includeFiles;
  final bool? includeDirectories;
  final DirectorySuggestionMatchMode? matchMode;
  final int? limit;
  final String requestId;

  factory DirectorySuggestionsRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Invalid directory suggestions request type');
    }
    final rawLimit = json['limit'];
    if (rawLimit != null &&
        (rawLimit is! num ||
            rawLimit.toInt() != rawLimit ||
            rawLimit < 1 ||
            rawLimit > 100)) {
      throw const FormatException('limit must be an integer from 1 to 100');
    }
    return DirectorySuggestionsRequest(
      query: _requiredString(json, 'query'),
      cwd: _optionalString(json, 'cwd'),
      includeFiles: _optionalBool(json, 'includeFiles'),
      includeDirectories: _optionalBool(json, 'includeDirectories'),
      matchMode: json['matchMode'] == null
          ? null
          : DirectorySuggestionMatchMode.fromWire(json['matchMode']),
      limit: rawLimit == null ? null : (rawLimit as num).toInt(),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'query': query,
    if (cwd != null) 'cwd': cwd,
    if (includeFiles != null) 'includeFiles': includeFiles,
    if (includeDirectories != null) 'includeDirectories': includeDirectories,
    if (matchMode != null) 'matchMode': matchMode!.name,
    if (limit != null) 'limit': limit,
    'requestId': requestId,
  };
}

final class DirectorySuggestionsResponse {
  const DirectorySuggestionsResponse({
    required this.directories,
    required this.entries,
    required this.requestId,
    this.error,
  });

  static const type = 'directory_suggestions_response';

  final List<String> directories;
  final List<DirectorySuggestionEntry> entries;
  final String? error;
  final String requestId;

  factory DirectorySuggestionsResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException(
        'Invalid directory suggestions response type',
      );
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('payload must be an object');
    }
    final body = Map<String, Object?>.from(payload);
    final rawDirectories = body['directories'];
    final rawEntries = body['entries'] ?? const <Object?>[];
    if (rawDirectories is! List || rawEntries is! List) {
      throw const FormatException('directories and entries must be arrays');
    }
    return DirectorySuggestionsResponse(
      directories: List.unmodifiable(
        rawDirectories.map(
          (value) => value is String
              ? value
              : throw const FormatException(
                  'directories entries must be strings',
                ),
        ),
      ),
      entries: List.unmodifiable(
        rawEntries.map(
          (value) => value is Map
              ? DirectorySuggestionEntry.fromJson(
                  Map<String, Object?>.from(value),
                )
              : throw const FormatException(
                  'directory suggestion entries must be objects',
                ),
        ),
      ),
      error: _optionalString(body, 'error'),
      requestId: _requiredString(body, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'directories': directories,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'error': error,
      'requestId': requestId,
    },
  };
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

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}
