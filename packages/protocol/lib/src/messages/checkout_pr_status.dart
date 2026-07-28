import 'checkout_pr.dart';

final class CheckoutPrCheck {
  const CheckoutPrCheck({
    required this.name,
    required this.status,
    required this.url,
    this.workflow,
    this.duration,
    this.checkRunId,
    this.workflowRunId,
  });

  final String name;
  final String status;
  final String? url;
  final String? workflow;
  final String? duration;
  final num? checkRunId;
  final num? workflowRunId;

  factory CheckoutPrCheck.fromJson(Map<String, Object?> json) =>
      CheckoutPrCheck(
        name: _string(json['name'], 'check.name'),
        status: _string(json['status'], 'check.status'),
        url: _nullableString(json['url'], 'check.url'),
        workflow: _optionalString(json['workflow'], 'check.workflow'),
        duration: _optionalString(json['duration'], 'check.duration'),
        checkRunId: _optionalNumber(json['checkRunId'], 'check.checkRunId'),
        workflowRunId: _optionalNumber(
          json['workflowRunId'],
          'check.workflowRunId',
        ),
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    'url': url,
    if (workflow != null) 'workflow': workflow,
    if (duration != null) 'duration': duration,
    if (checkRunId != null) 'checkRunId': checkRunId,
    if (workflowRunId != null) 'workflowRunId': workflowRunId,
  };
}

final class CheckoutPrStatus {
  const CheckoutPrStatus({
    required this.forge,
    required this.url,
    required this.title,
    required this.state,
    required this.baseRefName,
    required this.headRefName,
    required this.isMerged,
    required this.isDraft,
    required this.mergeable,
    required this.checks,
    this.projectPath,
    this.number,
    this.checksStatus,
    this.reviewDecision,
    this.repoOwner,
    this.repoName,
    this.github,
    this.forgeSpecific,
  });

  final String forge;
  final String? projectPath;
  final num? number;
  final String url;
  final String title;
  final String state;
  final String baseRefName;
  final String headRefName;
  final bool isMerged;
  final bool isDraft;
  final String mergeable;
  final List<CheckoutPrCheck> checks;
  final String? checksStatus;
  final String? reviewDecision;
  final String? repoOwner;
  final String? repoName;
  final Map<String, Object?>? github;
  final Object? forgeSpecific;

  factory CheckoutPrStatus.fromJson(Map<String, Object?> json) {
    final rawChecks = json['checks'];
    final checks = rawChecks == null
        ? const <CheckoutPrCheck>[]
        : _list(rawChecks, 'checks')
              .map((item) => CheckoutPrCheck.fromJson(_map(item, 'check')))
              .toList(growable: false);
    final rawMergeable = json['mergeable'];
    final mergeable =
        rawMergeable == 'MERGEABLE' ||
            rawMergeable == 'CONFLICTING' ||
            rawMergeable == 'UNKNOWN'
        ? rawMergeable! as String
        : 'UNKNOWN';
    final rawGithub = json['github'];
    return CheckoutPrStatus(
      forge: _optionalString(json['forge'], 'forge') ?? 'github',
      projectPath: _optionalString(json['projectPath'], 'projectPath'),
      number: _optionalNumber(json['number'], 'number'),
      url: _string(json['url'], 'url'),
      title: _string(json['title'], 'title'),
      state: _string(json['state'], 'state'),
      baseRefName: _string(json['baseRefName'], 'baseRefName'),
      headRefName: _string(json['headRefName'], 'headRefName'),
      isMerged: _bool(json['isMerged'], 'isMerged'),
      isDraft: _optionalBool(json['isDraft'], 'isDraft') ?? false,
      mergeable: mergeable,
      checks: checks,
      checksStatus: _optionalString(json['checksStatus'], 'checksStatus'),
      reviewDecision: _optionalString(json['reviewDecision'], 'reviewDecision'),
      repoOwner: _optionalString(json['repoOwner'], 'repoOwner'),
      repoName: _optionalString(json['repoName'], 'repoName'),
      github: rawGithub == null ? null : _map(rawGithub, 'github'),
      forgeSpecific: json['forgeSpecific'],
    );
  }

  Map<String, Object?> toJson() => {
    'forge': forge,
    if (projectPath != null) 'projectPath': projectPath,
    if (number != null) 'number': number,
    'url': url,
    'title': title,
    'state': state,
    'baseRefName': baseRefName,
    'headRefName': headRefName,
    'isMerged': isMerged,
    'isDraft': isDraft,
    'mergeable': mergeable,
    'checks': checks.map((check) => check.toJson()).toList(growable: false),
    if (checksStatus != null) 'checksStatus': checksStatus,
    if (reviewDecision != null) 'reviewDecision': reviewDecision,
    if (repoOwner != null) 'repoOwner': repoOwner,
    if (repoName != null) 'repoName': repoName,
    if (github != null) 'github': github,
    if (forgeSpecific != null) 'forgeSpecific': forgeSpecific,
  };
}

final class CheckoutPrStatusRequest {
  const CheckoutPrStatusRequest({required this.cwd, required this.requestId});

  static const type = 'checkout_pr_status_request';
  final String cwd;
  final String requestId;

  factory CheckoutPrStatusRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutPrStatusRequest(
      cwd: _string(json['cwd'], 'cwd'),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'requestId': requestId,
  };
}

final class CheckoutPrStatusResponse {
  const CheckoutPrStatusResponse({
    required this.cwd,
    required this.status,
    required this.githubFeaturesEnabled,
    required this.authState,
    String? forge,
    required this.error,
    required this.requestId,
  }) : _forge = forge;

  static const type = 'checkout_pr_status_response';
  final String cwd;
  final CheckoutPrStatus? status;
  final bool githubFeaturesEnabled;
  final Object? authState;
  final String? _forge;
  String get forge => _forge ?? 'github';
  bool get hasExplicitForge => _forge != null;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutPrStatusResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json['payload'], 'payload');
    final rawStatus = payload['status'];
    final rawError = payload['error'];
    return CheckoutPrStatusResponse(
      cwd: _string(payload['cwd'], 'cwd'),
      status: rawStatus == null
          ? null
          : CheckoutPrStatus.fromJson(_map(rawStatus, 'status')),
      githubFeaturesEnabled: _bool(
        payload['githubFeaturesEnabled'],
        'githubFeaturesEnabled',
      ),
      authState: payload['authState'],
      forge: _optionalString(payload['forge'], 'forge'),
      error: rawError == null
          ? null
          : CheckoutError.fromJson(_map(rawError, 'error')),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'status': status?.toJson(),
      'githubFeaturesEnabled': githubFeaturesEnabled,
      if (authState != null) 'authState': authState,
      if (_forge != null) 'forge': _forge,
      'error': error?.toJson(),
      'requestId': requestId,
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

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _string(value, field);

String? _nullableString(Object? value, String field) =>
    value == null ? null : _string(value, field);

num? _optionalNumber(Object? value, String field) {
  if (value == null) return null;
  if (value is num && value.isFinite) return value;
  throw FormatException('$field must be a finite number');
}

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}

bool? _optionalBool(Object? value, String field) =>
    value == null ? null : _bool(value, field);
