enum ForgeSearchKind {
  issue,
  changeRequest;

  String get wireName => switch (this) {
    issue => 'issue',
    changeRequest => 'change_request',
  };

  static ForgeSearchKind fromWire(Object? value) => switch (value) {
    'issue' || 'github-issue' => issue,
    'change_request' || 'github-pr' || 'pr' => changeRequest,
    _ => throw FormatException('Unknown forge search kind: $value'),
  };
}

final class ForgeSearchItem {
  const ForgeSearchItem({
    required this.kind,
    required this.number,
    required this.title,
    required this.url,
    required this.state,
    required this.body,
    required this.labels,
    this.forge,
    this.projectPath,
    this.baseRefName,
    this.headRefName,
    this.updatedAt,
  });

  final ForgeSearchKind kind;
  final String? forge;
  final int number;
  final String title;
  final String url;
  final String state;
  final String? body;
  final List<String> labels;
  final String? projectPath;
  final String? baseRefName;
  final String? headRefName;
  final String? updatedAt;

  factory ForgeSearchItem.fromJson(Map<String, Object?> json) =>
      ForgeSearchItem(
        kind: ForgeSearchKind.fromWire(json['kind']),
        forge: _optionalString(json['forge'], 'forge'),
        number: _positiveInt(json['number'], 'number'),
        title: _string(json['title'], 'title'),
        url: _string(json['url'], 'url'),
        state: _string(json['state'], 'state'),
        body: _optionalString(json['body'], 'body'),
        labels: _stringList(json['labels'], 'labels'),
        projectPath: _optionalString(json['projectPath'], 'projectPath'),
        baseRefName: _optionalString(json['baseRefName'], 'baseRefName'),
        headRefName: _optionalString(json['headRefName'], 'headRefName'),
        updatedAt: _optionalString(json['updatedAt'], 'updatedAt'),
      );

  Map<String, Object?> toJson() => {
    'kind': kind.wireName,
    if (forge != null) 'forge': forge,
    'number': number,
    'title': title,
    'url': url,
    'state': state,
    'body': body,
    'labels': labels,
    if (projectPath != null) 'projectPath': projectPath,
    if (baseRefName != null) 'baseRefName': baseRefName,
    if (headRefName != null) 'headRefName': headRefName,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };
}

final class ForgeSearchRequest {
  const ForgeSearchRequest({
    required this.cwd,
    required this.query,
    required this.requestId,
    this.limit,
    this.kinds,
  });

  static const type = 'forge.search.request';
  final String cwd;
  final String query;
  final int? limit;
  final List<ForgeSearchKind>? kinds;
  final String requestId;

  factory ForgeSearchRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw FormatException('Expected $type');
    }
    final limit = json['limit'];
    if (limit != null && (limit is! int || limit < 1 || limit > 50)) {
      throw const FormatException('limit must be between 1 and 50');
    }
    final rawKinds = json['kinds'];
    if (rawKinds != null && rawKinds is! List) {
      throw const FormatException('kinds must be an array');
    }
    final kindValues = rawKinds as List?;
    return ForgeSearchRequest(
      cwd: _string(json['cwd'], 'cwd'),
      query: _string(json['query'], 'query', allowEmpty: true),
      limit: limit as int?,
      kinds: kindValues == null
          ? null
          : List.unmodifiable(kindValues.map(ForgeSearchKind.fromWire)),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'query': query,
    if (limit != null) 'limit': limit,
    if (kinds != null) 'kinds': kinds!.map((kind) => kind.wireName).toList(),
    'requestId': requestId,
  };
}

final class ForgeSearchResponse {
  const ForgeSearchResponse({
    required this.items,
    required this.authState,
    required this.error,
    required this.requestId,
  });

  static const type = 'forge.search.response';
  final List<ForgeSearchItem> items;
  final String? authState;
  final String? error;
  final String requestId;

  factory ForgeSearchResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type || json['payload'] is! Map) {
      throw const FormatException('Invalid forge.search.response');
    }
    final payload = Map<String, Object?>.from(json['payload']! as Map);
    final rawItems = payload['items'];
    if (rawItems is! List || rawItems.any((item) => item is! Map)) {
      throw const FormatException('items must be an array of objects');
    }
    return ForgeSearchResponse(
      items: List.unmodifiable(
        rawItems.map(
          (item) =>
              ForgeSearchItem.fromJson(Map<String, Object?>.from(item as Map)),
        ),
      ),
      authState: _optionalString(payload['authState'], 'authState'),
      error: _optionalString(payload['error'], 'error'),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'items': items.map((item) => item.toJson()).toList(),
      if (authState != null) 'authState': authState,
      'error': error,
      'requestId': requestId,
    },
  };
}

String _string(Object? value, String field, {bool allowEmpty = false}) {
  if (value is String && (allowEmpty || value.isNotEmpty)) return value;
  throw FormatException('$field must be a string');
}

String? _optionalString(Object? value, String field) {
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$field must be a string or null');
}

int _positiveInt(Object? value, String field) {
  if (value is int && value > 0) return value;
  throw FormatException('$field must be a positive integer');
}

List<String> _stringList(Object? value, String field) {
  if (value is List && value.every((item) => item is String)) {
    return List.unmodifiable(value.cast<String>());
  }
  throw FormatException('$field must be an array of strings');
}
