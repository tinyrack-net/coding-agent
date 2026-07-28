enum PullRequestTimelineReviewState {
  approved,
  changesRequested,
  commented;

  String get wireName => switch (this) {
    approved => 'approved',
    changesRequested => 'changes_requested',
    commented => 'commented',
  };

  static PullRequestTimelineReviewState fromWire(Object? value) =>
      switch (value) {
        'approved' => approved,
        'changes_requested' => changesRequested,
        'commented' || null => commented,
        _ => throw FormatException('Unknown pull request review state: $value'),
      };
}

enum PullRequestTimelineErrorKind {
  notFound,
  forbidden,
  unknown;

  String get wireName => switch (this) {
    notFound => 'not_found',
    forbidden => 'forbidden',
    unknown => 'unknown',
  };

  static PullRequestTimelineErrorKind fromWire(Object? value) =>
      switch (value) {
        'not_found' => notFound,
        'forbidden' => forbidden,
        'unknown' || null => unknown,
        _ => unknown,
      };
}

final class PullRequestTimelineError {
  const PullRequestTimelineError({required this.kind, required this.message});
  final PullRequestTimelineErrorKind kind;
  final String message;

  factory PullRequestTimelineError.fromJson(Map<String, Object?> json) =>
      PullRequestTimelineError(
        kind: PullRequestTimelineErrorKind.fromWire(json['kind']),
        message: _stringOr(json['message'], ''),
      );

  Map<String, Object?> toJson() => {'kind': kind.wireName, 'message': message};
}

final class PullRequestTimelineCommentLocation {
  const PullRequestTimelineCommentLocation({
    required this.path,
    this.line,
    this.startLine,
    this.threadId,
    this.isResolved,
    this.isOutdated,
  });

  final String path;
  final num? line;
  final num? startLine;
  final String? threadId;
  final bool? isResolved;
  final bool? isOutdated;

  factory PullRequestTimelineCommentLocation.fromJson(
    Map<String, Object?> json,
  ) => PullRequestTimelineCommentLocation(
    path: _requiredString(json['path'], 'location.path'),
    line: _optionalNumber(json['line'], 'location.line'),
    startLine: _optionalNumber(json['startLine'], 'location.startLine'),
    threadId: _optionalString(json['threadId'], 'location.threadId'),
    isResolved: _optionalBool(json['isResolved'], 'location.isResolved'),
    isOutdated: _optionalBool(json['isOutdated'], 'location.isOutdated'),
  );

  Map<String, Object?> toJson() => {
    'path': path,
    if (line != null) 'line': line,
    if (startLine != null) 'startLine': startLine,
    if (threadId != null) 'threadId': threadId,
    if (isResolved != null) 'isResolved': isResolved,
    if (isOutdated != null) 'isOutdated': isOutdated,
  };
}

sealed class PullRequestTimelineItem {
  const PullRequestTimelineItem({
    required this.id,
    required this.author,
    required this.authorUrl,
    required this.avatarUrl,
    required this.body,
    required this.createdAt,
    required this.url,
  });

  final String id;
  final String author;
  final String? authorUrl;
  final String? avatarUrl;
  final String body;
  final num createdAt;
  final String url;

  factory PullRequestTimelineItem.fromJson(Map<String, Object?> json) =>
      json['kind'] == 'review'
      ? PullRequestTimelineReview.fromJson(json)
      : PullRequestTimelineComment.fromJson(json);

  Map<String, Object?> toJson();

  Map<String, Object?> baseJson(String kind) => {
    'id': id,
    'kind': kind,
    'author': author,
    'authorUrl': authorUrl,
    'avatarUrl': avatarUrl,
    'body': body,
    'createdAt': createdAt,
    'url': url,
  };
}

final class PullRequestTimelineReview extends PullRequestTimelineItem {
  const PullRequestTimelineReview({
    required super.id,
    required super.author,
    required super.authorUrl,
    required super.avatarUrl,
    required super.body,
    required super.createdAt,
    required super.url,
    required this.reviewState,
  });

  final PullRequestTimelineReviewState reviewState;

  factory PullRequestTimelineReview.fromJson(Map<String, Object?> json) =>
      PullRequestTimelineReview(
        id: _stringOr(json['id'], ''),
        author: _stringOr(json['author'], 'unknown'),
        authorUrl: _optionalString(json['authorUrl'], 'authorUrl'),
        avatarUrl: _optionalString(json['avatarUrl'], 'avatarUrl'),
        body: _stringOr(json['body'], ''),
        createdAt: _numberOr(json['createdAt'], 0),
        url: _stringOr(json['url'], ''),
        reviewState: PullRequestTimelineReviewState.fromWire(
          json['reviewState'],
        ),
      );

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('review'),
    'reviewState': reviewState.wireName,
  };
}

final class PullRequestTimelineComment extends PullRequestTimelineItem {
  const PullRequestTimelineComment({
    required super.id,
    required super.author,
    required super.authorUrl,
    required super.avatarUrl,
    required super.body,
    required super.createdAt,
    required super.url,
    this.reviewId,
    this.threadId,
    this.threadIsResolved,
    this.location,
  });

  final String? reviewId;
  final String? threadId;
  final bool? threadIsResolved;
  final PullRequestTimelineCommentLocation? location;

  factory PullRequestTimelineComment.fromJson(Map<String, Object?> json) {
    final rawLocation = json['location'];
    return PullRequestTimelineComment(
      id: _stringOr(json['id'], ''),
      author: _stringOr(json['author'], 'unknown'),
      authorUrl: _optionalString(json['authorUrl'], 'authorUrl'),
      avatarUrl: _optionalString(json['avatarUrl'], 'avatarUrl'),
      body: _stringOr(json['body'], ''),
      createdAt: _numberOr(json['createdAt'], 0),
      url: _stringOr(json['url'], ''),
      reviewId: _optionalString(json['reviewId'], 'reviewId'),
      threadId: _optionalString(json['threadId'], 'threadId'),
      threadIsResolved: _optionalBool(
        json['threadIsResolved'],
        'threadIsResolved',
      ),
      location: rawLocation == null
          ? null
          : PullRequestTimelineCommentLocation.fromJson(
              _map(rawLocation, 'location'),
            ),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('comment'),
    if (reviewId != null) 'reviewId': reviewId,
    if (threadId != null) 'threadId': threadId,
    if (threadIsResolved != null) 'threadIsResolved': threadIsResolved,
    if (location != null) 'location': location!.toJson(),
  };
}

final class PullRequestTimelineRequest {
  const PullRequestTimelineRequest({
    required this.cwd,
    required this.prNumber,
    required this.repoOwner,
    required this.repoName,
    required this.requestId,
  });

  static const type = 'pull_request_timeline_request';
  final String cwd;
  final num prNumber;
  final String repoOwner;
  final String repoName;
  final String requestId;

  factory PullRequestTimelineRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return PullRequestTimelineRequest(
      cwd: _requiredString(json['cwd'], 'cwd'),
      prNumber: _requiredNumber(json['prNumber'], 'prNumber'),
      repoOwner: _requiredString(json['repoOwner'], 'repoOwner'),
      repoName: _requiredString(json['repoName'], 'repoName'),
      requestId: _requiredString(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'prNumber': prNumber,
    'repoOwner': repoOwner,
    'repoName': repoName,
    'requestId': requestId,
  };
}

final class PullRequestTimelineResponse {
  const PullRequestTimelineResponse({
    required this.cwd,
    required this.prNumber,
    required this.items,
    required this.truncated,
    required this.error,
    required this.requestId,
    required this.githubFeaturesEnabled,
    required this.authState,
  });

  static const type = 'pull_request_timeline_response';
  final String cwd;
  final num? prNumber;
  final List<PullRequestTimelineItem> items;
  final bool truncated;
  final PullRequestTimelineError? error;
  final String requestId;
  final bool githubFeaturesEnabled;
  final String? authState;

  factory PullRequestTimelineResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = json['payload'] == null
        ? const <String, Object?>{}
        : _map(json['payload'], 'payload');
    final rawItems = payload['items'];
    final items = rawItems == null
        ? const <PullRequestTimelineItem>[]
        : _list(rawItems, 'items')
              .map(
                (item) => PullRequestTimelineItem.fromJson(_map(item, 'item')),
              )
              .toList(growable: false);
    final rawError = payload['error'];
    return PullRequestTimelineResponse(
      cwd: _stringOr(payload['cwd'], ''),
      prNumber: _optionalNumber(payload['prNumber'], 'prNumber'),
      items: items,
      truncated: _boolOr(payload['truncated'], false),
      error: rawError == null
          ? null
          : PullRequestTimelineError.fromJson(_map(rawError, 'error')),
      requestId: _stringOr(payload['requestId'], ''),
      githubFeaturesEnabled: _boolOr(payload['githubFeaturesEnabled'], true),
      authState: _optionalString(payload['authState'], 'authState'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'prNumber': prNumber,
      'items': items.map((item) => item.toJson()).toList(growable: false),
      'truncated': truncated,
      'error': error?.toJson(),
      'requestId': requestId,
      'githubFeaturesEnabled': githubFeaturesEnabled,
      if (authState != null) 'authState': authState,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

List<Object?> _list(Object? value, String field) {
  if (value is List) return List<Object?>.from(value);
  throw FormatException('$field must be an array');
}

String _requiredString(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String _stringOr(Object? value, String fallback) {
  if (value == null) return fallback;
  if (value is String) return value;
  throw const FormatException('value must be a string');
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _requiredString(value, field);

num _requiredNumber(Object? value, String field) {
  if (value is num && value.isFinite) return value;
  throw FormatException('$field must be a finite number');
}

num _numberOr(Object? value, num fallback) =>
    value == null ? fallback : _requiredNumber(value, 'value');

num? _optionalNumber(Object? value, String field) =>
    value == null ? null : _requiredNumber(value, field);

bool _boolOr(Object? value, bool fallback) {
  if (value == null) return fallback;
  if (value is bool) return value;
  throw const FormatException('value must be a boolean');
}

bool? _optionalBool(Object? value, String field) {
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}
