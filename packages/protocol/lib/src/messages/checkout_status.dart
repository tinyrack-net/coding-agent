import 'checkout_pr.dart';
import 'checkout_pr_status.dart';

final class CheckoutAheadBehind {
  const CheckoutAheadBehind({required this.ahead, required this.behind});

  final num ahead;
  final num behind;

  factory CheckoutAheadBehind.fromJson(Map<String, Object?> json) =>
      CheckoutAheadBehind(
        ahead: _finiteNum(json['ahead'], 'ahead'),
        behind: _finiteNum(json['behind'], 'behind'),
      );

  Map<String, Object?> toJson() => {'ahead': ahead, 'behind': behind};
}

sealed class CheckoutStatusPayload {
  const CheckoutStatusPayload({
    required this.cwd,
    required this.error,
    required this.requestId,
  });

  final String cwd;
  final CheckoutError? error;
  final String requestId;

  bool get isGit;
  bool get isPaseoOwnedWorktree;
  String? get repoRoot;
  String? get mainRepoRoot;
  String? get currentBranch;
  bool? get isDirty;
  String? get baseRef;
  CheckoutAheadBehind? get aheadBehind;
  num? get aheadOfOrigin;
  num? get behindOfOrigin;
  bool get hasRemote;
  String? get remoteUrl;

  factory CheckoutStatusPayload.fromJson(Map<String, Object?> json) {
    _requireFields(json, const {
      'cwd',
      'isGit',
      'isPaseoOwnedWorktree',
      'repoRoot',
      'currentBranch',
      'isDirty',
      'baseRef',
      'aheadBehind',
      'aheadOfOrigin',
      'behindOfOrigin',
      'hasRemote',
      'remoteUrl',
      'error',
      'requestId',
    });
    final isGit = _bool(json['isGit'], 'isGit');
    final owned = _bool(json['isPaseoOwnedWorktree'], 'isPaseoOwnedWorktree');
    final error = json['error'] == null
        ? null
        : CheckoutError.fromJson(_map(json['error'], 'error'));
    if (!isGit) {
      if (owned ||
          json['repoRoot'] != null ||
          json['currentBranch'] != null ||
          json['isDirty'] != null ||
          json['baseRef'] != null ||
          json['aheadBehind'] != null ||
          json['aheadOfOrigin'] != null ||
          json['behindOfOrigin'] != null ||
          json['remoteUrl'] != null) {
        throw const FormatException('Invalid non-Git checkout status');
      }
      return CheckoutStatusNotGit(
        cwd: _string(json['cwd'], 'cwd'),
        hasRemote: _bool(json['hasRemote'], 'hasRemote'),
        error: error,
        requestId: _string(json['requestId'], 'requestId'),
      );
    }

    final common = (
      cwd: _string(json['cwd'], 'cwd'),
      repoRoot: _string(json['repoRoot'], 'repoRoot'),
      currentBranch: _nullableString(json['currentBranch'], 'currentBranch'),
      isDirty: _bool(json['isDirty'], 'isDirty'),
      aheadBehind: json['aheadBehind'] == null
          ? null
          : CheckoutAheadBehind.fromJson(
              _map(json['aheadBehind'], 'aheadBehind'),
            ),
      aheadOfOrigin: _nullableFiniteNum(json['aheadOfOrigin'], 'aheadOfOrigin'),
      behindOfOrigin: _nullableFiniteNum(
        json['behindOfOrigin'],
        'behindOfOrigin',
      ),
      hasRemote: _bool(json['hasRemote'], 'hasRemote'),
      remoteUrl: _nullableString(json['remoteUrl'], 'remoteUrl'),
      error: error,
      requestId: _string(json['requestId'], 'requestId'),
    );
    if (owned) {
      _requireFields(json, const {'mainRepoRoot'});
      return CheckoutStatusGitPaseo(
        cwd: common.cwd,
        repoRoot: common.repoRoot,
        mainRepoRoot: _string(json['mainRepoRoot'], 'mainRepoRoot'),
        currentBranch: common.currentBranch,
        isDirty: common.isDirty,
        baseRef: _string(json['baseRef'], 'baseRef'),
        aheadBehind: common.aheadBehind,
        aheadOfOrigin: common.aheadOfOrigin,
        behindOfOrigin: common.behindOfOrigin,
        hasRemote: common.hasRemote,
        remoteUrl: common.remoteUrl,
        error: common.error,
        requestId: common.requestId,
      );
    }
    return CheckoutStatusGitNonPaseo(
      cwd: common.cwd,
      repoRoot: common.repoRoot,
      mainRepoRoot: _nullableString(json['mainRepoRoot'], 'mainRepoRoot'),
      currentBranch: common.currentBranch,
      isDirty: common.isDirty,
      baseRef: _nullableString(json['baseRef'], 'baseRef'),
      aheadBehind: common.aheadBehind,
      aheadOfOrigin: common.aheadOfOrigin,
      behindOfOrigin: common.behindOfOrigin,
      hasRemote: common.hasRemote,
      remoteUrl: common.remoteUrl,
      error: common.error,
      requestId: common.requestId,
    );
  }

  Map<String, Object?> toJson();

  Map<String, Object?> commonJson() => {
    'cwd': cwd,
    'isGit': isGit,
    'isPaseoOwnedWorktree': isPaseoOwnedWorktree,
    'repoRoot': repoRoot,
    'currentBranch': currentBranch,
    'isDirty': isDirty,
    'baseRef': baseRef,
    'aheadBehind': aheadBehind?.toJson(),
    'aheadOfOrigin': aheadOfOrigin,
    'behindOfOrigin': behindOfOrigin,
    'hasRemote': hasRemote,
    'remoteUrl': remoteUrl,
    'error': error?.toJson(),
    'requestId': requestId,
  };
}

final class CheckoutStatusNotGit extends CheckoutStatusPayload {
  const CheckoutStatusNotGit({
    required super.cwd,
    this.hasRemote = false,
    required super.error,
    required super.requestId,
  });

  @override
  bool get isGit => false;
  @override
  bool get isPaseoOwnedWorktree => false;
  @override
  String? get repoRoot => null;
  @override
  String? get mainRepoRoot => null;
  @override
  String? get currentBranch => null;
  @override
  bool? get isDirty => null;
  @override
  String? get baseRef => null;
  @override
  CheckoutAheadBehind? get aheadBehind => null;
  @override
  num? get aheadOfOrigin => null;
  @override
  num? get behindOfOrigin => null;
  @override
  final bool hasRemote;
  @override
  String? get remoteUrl => null;

  @override
  Map<String, Object?> toJson() => commonJson();
}

sealed class CheckoutStatusGit extends CheckoutStatusPayload {
  const CheckoutStatusGit({
    required super.cwd,
    required this.repoRoot,
    required this.currentBranch,
    required this.isDirty,
    required this.aheadBehind,
    required this.aheadOfOrigin,
    required this.behindOfOrigin,
    required this.hasRemote,
    required this.remoteUrl,
    required super.error,
    required super.requestId,
  });

  @override
  bool get isGit => true;
  @override
  final String repoRoot;
  @override
  final String? currentBranch;
  @override
  final bool isDirty;
  @override
  final CheckoutAheadBehind? aheadBehind;
  @override
  final num? aheadOfOrigin;
  @override
  final num? behindOfOrigin;
  @override
  final bool hasRemote;
  @override
  final String? remoteUrl;

  @override
  Map<String, Object?> toJson() => {
    ...commonJson(),
    'mainRepoRoot': mainRepoRoot,
  };
}

final class CheckoutStatusGitNonPaseo extends CheckoutStatusGit {
  const CheckoutStatusGitNonPaseo({
    required super.cwd,
    required super.repoRoot,
    required this.mainRepoRoot,
    required super.currentBranch,
    required super.isDirty,
    required this.baseRef,
    required super.aheadBehind,
    required super.aheadOfOrigin,
    required super.behindOfOrigin,
    required super.hasRemote,
    required super.remoteUrl,
    required super.error,
    required super.requestId,
  });

  @override
  bool get isPaseoOwnedWorktree => false;
  @override
  final String? mainRepoRoot;
  @override
  final String? baseRef;
}

final class CheckoutStatusGitPaseo extends CheckoutStatusGit {
  const CheckoutStatusGitPaseo({
    required super.cwd,
    required super.repoRoot,
    required this.mainRepoRoot,
    required super.currentBranch,
    required super.isDirty,
    required this.baseRef,
    required super.aheadBehind,
    required super.aheadOfOrigin,
    required super.behindOfOrigin,
    required super.hasRemote,
    required super.remoteUrl,
    required super.error,
    required super.requestId,
  });

  @override
  bool get isPaseoOwnedWorktree => true;
  @override
  final String mainRepoRoot;
  @override
  final String baseRef;
}

final class CheckoutStatusRequest {
  const CheckoutStatusRequest({required this.cwd, required this.requestId});

  static const type = 'checkout_status_request';
  final String cwd;
  final String requestId;

  factory CheckoutStatusRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutStatusRequest(
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

final class CheckoutStatusResponse {
  const CheckoutStatusResponse(this.payload);

  static const type = 'checkout_status_response';
  final CheckoutStatusPayload payload;

  factory CheckoutStatusResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutStatusResponse(
      CheckoutStatusPayload.fromJson(_map(json['payload'], 'payload')),
    );
  }

  Map<String, Object?> toJson() => {'type': type, 'payload': payload.toJson()};
}

final class CheckoutStatusUpdate {
  const CheckoutStatusUpdate({required this.payload, this.prStatus});

  static const type = 'checkout_status_update';
  final CheckoutStatusPayload payload;
  final CheckoutPrStatusResponse? prStatus;

  factory CheckoutStatusUpdate.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json['payload'], 'payload');
    final rawPrStatus = payload.remove('prStatus');
    return CheckoutStatusUpdate(
      payload: CheckoutStatusPayload.fromJson(payload),
      prStatus: rawPrStatus == null
          ? null
          : CheckoutPrStatusResponse.fromJson({
              'type': CheckoutPrStatusResponse.type,
              'payload': _map(rawPrStatus, 'prStatus'),
            }),
    );
  }

  Map<String, Object?> toJson() {
    final prPayload = prStatus?.toJson()['payload'];
    return {
      'type': type,
      'payload': {
        ...payload.toJson(),
        if (prPayload != null) 'prStatus': prPayload,
      },
    };
  }
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

void _requireFields(Map<String, Object?> json, Set<String> fields) {
  for (final field in fields) {
    if (!json.containsKey(field)) {
      throw FormatException('$field is required');
    }
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String? _nullableString(Object? value, String field) =>
    value == null ? null : _string(value, field);

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}

num _finiteNum(Object? value, String field) {
  if (value is num && value.isFinite) return value;
  throw FormatException('$field must be a finite number');
}

num? _nullableFiniteNum(Object? value, String field) =>
    value == null ? null : _finiteNum(value, field);
