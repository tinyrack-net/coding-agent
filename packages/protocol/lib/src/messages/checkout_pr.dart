enum CheckoutPrMergeMethod {
  merge,
  squash,
  rebase;

  static CheckoutPrMergeMethod fromWire(Object? value) => switch (value) {
    'merge' => merge,
    'squash' => squash,
    'rebase' => rebase,
    _ => throw FormatException('Unknown checkout PR merge method: $value'),
  };
}

enum CheckoutErrorCode {
  notGitRepo('NOT_GIT_REPO'),
  notAllowed('NOT_ALLOWED'),
  mergeConflict('MERGE_CONFLICT'),
  unknown('UNKNOWN');

  const CheckoutErrorCode(this.wireName);
  final String wireName;

  static CheckoutErrorCode fromWire(Object? value) => switch (value) {
    'NOT_GIT_REPO' => notGitRepo,
    'NOT_ALLOWED' => notAllowed,
    'MERGE_CONFLICT' => mergeConflict,
    'UNKNOWN' => unknown,
    _ => throw FormatException('Unknown checkout error code: $value'),
  };
}

final class CheckoutError {
  const CheckoutError({required this.code, required this.message});
  final CheckoutErrorCode code;
  final String message;

  factory CheckoutError.fromJson(Map<String, Object?> json) => CheckoutError(
    code: CheckoutErrorCode.fromWire(json['code']),
    message: _string(json['message'], 'message'),
  );

  Map<String, Object?> toJson() => {'code': code.wireName, 'message': message};
}

final class CheckoutPrCreateRequest {
  const CheckoutPrCreateRequest({
    required this.cwd,
    required this.requestId,
    this.title,
    this.body,
    this.baseRef,
  });

  static const type = 'checkout_pr_create_request';
  final String cwd;
  final String? title;
  final String? body;
  final String? baseRef;
  final String requestId;

  factory CheckoutPrCreateRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutPrCreateRequest(
      cwd: _string(json['cwd'], 'cwd'),
      title: _optionalString(json['title'], 'title'),
      body: _optionalString(json['body'], 'body'),
      baseRef: _optionalString(json['baseRef'], 'baseRef'),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (title != null) 'title': title,
    if (body != null) 'body': body,
    if (baseRef != null) 'baseRef': baseRef,
    'requestId': requestId,
  };
}

final class CheckoutPrCreateResponse {
  const CheckoutPrCreateResponse({
    required this.cwd,
    required this.url,
    required this.number,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout_pr_create_response';
  final String cwd;
  final String? url;
  final int? number;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutPrCreateResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return CheckoutPrCreateResponse(
      cwd: _string(payload['cwd'], 'cwd'),
      url: _optionalString(payload['url'], 'url'),
      number: _optionalNumber(payload['number'], 'number'),
      error: _optionalError(payload['error']),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'url': url,
      'number': number,
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

final class CheckoutPrMergeRequest {
  const CheckoutPrMergeRequest({
    required this.cwd,
    required this.mergeMethod,
    required this.requestId,
  });

  static const type = 'checkout_pr_merge_request';
  final String cwd;
  final CheckoutPrMergeMethod mergeMethod;
  final String requestId;

  factory CheckoutPrMergeRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutPrMergeRequest(
      cwd: _string(json['cwd'], 'cwd'),
      mergeMethod: CheckoutPrMergeMethod.fromWire(json['mergeMethod']),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'mergeMethod': mergeMethod.name,
    'requestId': requestId,
  };
}

final class CheckoutPrMergeResponse {
  const CheckoutPrMergeResponse({
    required this.cwd,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout_pr_merge_response';
  final String cwd;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutPrMergeResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return CheckoutPrMergeResponse(
      cwd: _string(payload['cwd'], 'cwd'),
      success: _boolean(payload['success'], 'success'),
      error: _optionalError(payload['error']),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'success': success,
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

final class CheckoutForgeSetAutoMergeRequest {
  const CheckoutForgeSetAutoMergeRequest({
    required this.type,
    required this.cwd,
    required this.enabled,
    required this.requestId,
    this.mergeMethod,
  });

  static const modernType = 'checkout.forge.set_auto_merge.request';
  static const legacyGithubType = 'checkout.github.set_auto_merge.request';
  final String type;
  final String cwd;
  final bool enabled;
  final CheckoutPrMergeMethod? mergeMethod;
  final String requestId;

  factory CheckoutForgeSetAutoMergeRequest.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type != modernType && type != legacyGithubType) {
      throw const FormatException('Invalid checkout auto-merge request type');
    }
    final rawMethod = json['mergeMethod'];
    return CheckoutForgeSetAutoMergeRequest(
      type: type! as String,
      cwd: _string(json['cwd'], 'cwd'),
      enabled: _boolean(json['enabled'], 'enabled'),
      mergeMethod: rawMethod == null
          ? null
          : CheckoutPrMergeMethod.fromWire(rawMethod),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  String get responseType => type == modernType
      ? CheckoutForgeSetAutoMergeResponse.modernType
      : CheckoutForgeSetAutoMergeResponse.legacyGithubType;

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'enabled': enabled,
    if (mergeMethod != null) 'mergeMethod': mergeMethod!.name,
    'requestId': requestId,
  };
}

final class CheckoutForgeSetAutoMergeResponse {
  const CheckoutForgeSetAutoMergeResponse({
    required this.type,
    required this.cwd,
    required this.enabled,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const modernType = 'checkout.forge.set_auto_merge.response';
  static const legacyGithubType = 'checkout.github.set_auto_merge.response';
  final String type;
  final String cwd;
  final bool enabled;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutForgeSetAutoMergeResponse.fromJson(
    Map<String, Object?> json,
  ) {
    final type = json['type'];
    if (type != modernType && type != legacyGithubType) {
      throw const FormatException('Invalid checkout auto-merge response type');
    }
    final payload = _payload(json, type! as String);
    return CheckoutForgeSetAutoMergeResponse(
      type: type as String,
      cwd: _string(payload['cwd'], 'cwd'),
      enabled: _boolean(payload['enabled'], 'enabled'),
      success: _boolean(payload['success'], 'success'),
      error: _optionalError(payload['error']),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'enabled': enabled,
      'success': success,
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _payload(Map<String, Object?> json, String type) {
  _expectType(json, type);
  final value = json['payload'];
  if (value is! Map) throw const FormatException('payload must be an object');
  return Map<String, Object?>.from(value);
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _string(value, field);

int? _optionalNumber(Object? value, String field) {
  if (value == null) return null;
  if (value is num && value.isFinite) return value.toInt();
  throw FormatException('$field must be a number or null');
}

bool _boolean(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}

CheckoutError? _optionalError(Object? value) {
  if (value == null) return null;
  if (value is Map) {
    return CheckoutError.fromJson(Map<String, Object?>.from(value));
  }
  throw const FormatException('error must be an object or null');
}
