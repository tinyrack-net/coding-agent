/// Frozen Paseo 0.2.0 checkout/worktree compatibility messages.
///
/// These messages intentionally keep the pre-namespaced wire names used by
/// Paseo desktop clients.  They remain separate from the newer checkout
/// messages so callers can explicitly select the contract they negotiated.
library;

import 'checkout_pr.dart';

final class CheckoutCommitRequest {
  const CheckoutCommitRequest({
    required this.cwd,
    required this.requestId,
    this.message,
    this.addAll,
  });

  static const type = 'checkout_commit_request';

  final String cwd;
  final String? message;
  final bool? addAll;
  final String requestId;

  factory CheckoutCommitRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutCommitRequest(
      cwd: _requiredString(json, 'cwd'),
      message: _optionalString(json, 'message'),
      addAll: _optionalBool(json, 'addAll'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (message != null) 'message': message,
    if (addAll != null) 'addAll': addAll,
    'requestId': requestId,
  };
}

final class CheckoutCommitResponse {
  const CheckoutCommitResponse({
    required this.cwd,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout_commit_response';

  final String cwd;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutCommitResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return CheckoutCommitResponse(
      cwd: _requiredString(payload, 'cwd'),
      success: _requiredBool(payload, 'success'),
      error: _optionalCheckoutError(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
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

final class ValidateBranchRequest {
  const ValidateBranchRequest({
    required this.cwd,
    required this.branchName,
    required this.requestId,
  });

  static const type = 'validate_branch_request';

  final String cwd;
  final String branchName;
  final String requestId;

  factory ValidateBranchRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ValidateBranchRequest(
      cwd: _requiredString(json, 'cwd'),
      branchName: _requiredString(json, 'branchName'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'branchName': branchName,
    'requestId': requestId,
  };
}

final class ValidateBranchResponse {
  const ValidateBranchResponse({
    required this.exists,
    required this.resolvedRef,
    required this.isRemote,
    required this.error,
    required this.requestId,
  });

  static const type = 'validate_branch_response';

  final bool exists;
  final String? resolvedRef;
  final bool isRemote;
  final String? error;
  final String requestId;

  factory ValidateBranchResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return ValidateBranchResponse(
      exists: _requiredBool(payload, 'exists'),
      resolvedRef: _optionalString(payload, 'resolvedRef'),
      isRemote: _requiredBool(payload, 'isRemote'),
      error: _optionalString(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'exists': exists,
      'resolvedRef': resolvedRef,
      'isRemote': isRemote,
      'error': error,
      'requestId': requestId,
    },
  };
}

final class BranchSuggestionsRequest {
  const BranchSuggestionsRequest({
    required this.cwd,
    required this.requestId,
    this.query,
    this.limit,
  });

  static const type = 'branch_suggestions_request';

  final String cwd;
  final String? query;
  final int? limit;
  final String requestId;

  factory BranchSuggestionsRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final limit = _optionalInt(json, 'limit');
    if (limit != null && (limit < 1 || limit > 200)) {
      throw const FormatException('limit must be an integer from 1 to 200');
    }
    return BranchSuggestionsRequest(
      cwd: _requiredString(json, 'cwd'),
      query: _optionalString(json, 'query'),
      limit: limit,
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (query != null) 'query': query,
    if (limit != null) 'limit': limit,
    'requestId': requestId,
  };
}

final class BranchSuggestionDetail {
  const BranchSuggestionDetail({
    required this.name,
    required this.committerDate,
    this.hasLocal,
    this.hasRemote,
  });

  final String name;
  final num committerDate;
  final bool? hasLocal;
  final bool? hasRemote;

  factory BranchSuggestionDetail.fromJson(Map<String, Object?> json) {
    final rawDate = json['committerDate'];
    if (rawDate is! num || !rawDate.isFinite) {
      throw const FormatException('committerDate must be a finite number');
    }
    return BranchSuggestionDetail(
      name: _requiredString(json, 'name'),
      committerDate: rawDate,
      hasLocal: _optionalBool(json, 'hasLocal'),
      hasRemote: _optionalBool(json, 'hasRemote'),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'committerDate': committerDate,
    if (hasLocal != null) 'hasLocal': hasLocal,
    if (hasRemote != null) 'hasRemote': hasRemote,
  };
}

final class BranchSuggestionsResponse {
  const BranchSuggestionsResponse({
    required this.branches,
    required this.branchDetails,
    required this.error,
    required this.requestId,
  });

  static const type = 'branch_suggestions_response';

  final List<String> branches;
  final List<BranchSuggestionDetail>? branchDetails;
  final String? error;
  final String requestId;

  factory BranchSuggestionsResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    final rawBranches = payload['branches'];
    if (rawBranches is! List) {
      throw const FormatException('payload.branches must be an array');
    }
    final branches = rawBranches
        .map((value) {
          if (value is! String) {
            throw const FormatException(
              'payload.branches entries must be strings',
            );
          }
          return value;
        })
        .toList(growable: false);
    final rawDetails = payload['branchDetails'];
    final details = rawDetails == null
        ? null
        : _maps(
            rawDetails,
            'payload.branchDetails',
          ).map(BranchSuggestionDetail.fromJson).toList(growable: false);
    return BranchSuggestionsResponse(
      branches: List.unmodifiable(branches),
      branchDetails: details == null ? null : List.unmodifiable(details),
      error: _optionalString(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'branches': branches,
      if (branchDetails != null)
        'branchDetails': branchDetails!
            .map((detail) => detail.toJson())
            .toList(growable: false),
      'error': error,
      'requestId': requestId,
    },
  };
}

final class StashSaveRequest {
  const StashSaveRequest({
    required this.cwd,
    required this.requestId,
    this.branch,
  });

  static const type = 'stash_save_request';
  final String cwd;
  final String? branch;
  final String requestId;

  factory StashSaveRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return StashSaveRequest(
      cwd: _requiredString(json, 'cwd'),
      branch: _optionalString(json, 'branch'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (branch != null) 'branch': branch,
    'requestId': requestId,
  };
}

final class StashPopRequest {
  const StashPopRequest({
    required this.cwd,
    required this.stashIndex,
    required this.requestId,
  });

  static const type = 'stash_pop_request';
  final String cwd;
  final int stashIndex;
  final String requestId;

  factory StashPopRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final stashIndex = _requiredInt(json, 'stashIndex');
    if (stashIndex < 0) {
      throw const FormatException('stashIndex must be non-negative');
    }
    return StashPopRequest(
      cwd: _requiredString(json, 'cwd'),
      stashIndex: stashIndex,
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'stashIndex': stashIndex,
    'requestId': requestId,
  };
}

final class StashListRequest {
  const StashListRequest({
    required this.cwd,
    required this.requestId,
    this.paseoOnly,
  });

  static const type = 'stash_list_request';
  final String cwd;
  final bool? paseoOnly;
  final String requestId;

  factory StashListRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return StashListRequest(
      cwd: _requiredString(json, 'cwd'),
      paseoOnly: _optionalBool(json, 'paseoOnly'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (paseoOnly != null) 'paseoOnly': paseoOnly,
    'requestId': requestId,
  };
}

final class StashSaveResponse {
  const StashSaveResponse({
    required this.cwd,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const type = 'stash_save_response';
  final String cwd;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory StashSaveResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return StashSaveResponse(
      cwd: _requiredString(payload, 'cwd'),
      success: _requiredBool(payload, 'success'),
      error: _optionalCheckoutError(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => _simpleCheckoutResponse(
    type: type,
    cwd: cwd,
    success: success,
    error: error,
    requestId: requestId,
  );
}

final class StashPopResponse {
  const StashPopResponse({
    required this.cwd,
    required this.success,
    required this.error,
    required this.requestId,
  });

  static const type = 'stash_pop_response';
  final String cwd;
  final bool success;
  final CheckoutError? error;
  final String requestId;

  factory StashPopResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return StashPopResponse(
      cwd: _requiredString(payload, 'cwd'),
      success: _requiredBool(payload, 'success'),
      error: _optionalCheckoutError(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => _simpleCheckoutResponse(
    type: type,
    cwd: cwd,
    success: success,
    error: error,
    requestId: requestId,
  );
}

final class StashEntry {
  const StashEntry({
    required this.index,
    required this.message,
    required this.branch,
    required this.isPaseo,
  });

  final int index;
  final String message;
  final String? branch;
  final bool isPaseo;

  factory StashEntry.fromJson(Map<String, Object?> json) {
    final index = _requiredInt(json, 'index');
    if (index < 0) throw const FormatException('index must be non-negative');
    return StashEntry(
      index: index,
      message: _requiredString(json, 'message'),
      branch: _optionalString(json, 'branch'),
      isPaseo: _requiredBool(json, 'isPaseo'),
    );
  }

  Map<String, Object?> toJson() => {
    'index': index,
    'message': message,
    'branch': branch,
    'isPaseo': isPaseo,
  };
}

final class StashListResponse {
  const StashListResponse({
    required this.cwd,
    required this.entries,
    required this.error,
    required this.requestId,
  });

  static const type = 'stash_list_response';
  final String cwd;
  final List<StashEntry> entries;
  final CheckoutError? error;
  final String requestId;

  factory StashListResponse.fromJson(Map<String, Object?> json) {
    final payload = _payload(json, type);
    return StashListResponse(
      cwd: _requiredString(payload, 'cwd'),
      entries: List.unmodifiable(
        _maps(payload['entries'], 'payload.entries').map(StashEntry.fromJson),
      ),
      error: _optionalCheckoutError(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

Map<String, Object?> _simpleCheckoutResponse({
  required String type,
  required String cwd,
  required bool success,
  required CheckoutError? error,
  required String requestId,
}) => {
  'type': type,
  'payload': {
    'cwd': cwd,
    'success': success,
    'error': error?.toJson(),
    'requestId': requestId,
  },
};

Map<String, Object?> _payload(Map<String, Object?> json, String type) {
  _expectType(json, type);
  final value = json['payload'];
  if (value is Map) return Map<String, Object?>.from(value);
  throw const FormatException('payload must be an object');
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) throw FormatException('Expected $expected');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

List<Map<String, Object?>> _maps(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be an array');
  return value.map((entry) => _map(entry, '$field[]')).toList(growable: false);
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

bool _requiredBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

int _requiredInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

int? _optionalInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

CheckoutError? _optionalCheckoutError(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  return CheckoutError.fromJson(_map(value, field));
}
